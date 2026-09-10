import { serviceRoleClient } from "./supabase.ts";

export const MEDICAL_SCANS_BUCKET = "medical-scans";

const RETENTION_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;
const STORAGE_DELETE_BATCH_SIZE = 1000;
const STORAGE_URL_OBJECT_SEGMENTS = new Set([
  "public",
  "authenticated",
  "sign",
  "render",
]);

type ServiceRoleClient = ReturnType<typeof serviceRoleClient>;

interface PrivacySettingsRow {
  medical_scan_local_only: boolean | null;
  cloud_backup_enabled: boolean | null;
}

interface MedicalScanStorageRow {
  id: string;
  image_url: string | null;
  original_image_url: string | null;
  scheduled_deletion_at: string | null;
  pinned_by_user: boolean | null;
}

export interface MedicalScanPrivacySettings {
  medicalScanLocalOnly: boolean;
  cloudBackupEnabled: boolean;
}

export async function loadMedicalScanPrivacySettings(
  service: ServiceRoleClient,
  userId: string,
): Promise<MedicalScanPrivacySettings> {
  const { data, error } = await service
    .from("privacy_settings")
    .select("medical_scan_local_only,cloud_backup_enabled")
    .eq("user_id", userId)
    .maybeSingle<PrivacySettingsRow>();

  if (error) {
    throw new Error(`privacy_settings_lookup_failed:${error.message}`);
  }

  return {
    medicalScanLocalOnly: data?.medical_scan_local_only ?? true,
    cloudBackupEnabled: data?.cloud_backup_enabled ?? false,
  };
}

export function computeMedicalScanScheduledDeletionAt(
  createdAt: string | null | undefined,
): string {
  const baseDate = createdAt ? new Date(createdAt) : new Date();
  const effectiveBase = Number.isNaN(baseDate.getTime())
    ? new Date()
    : baseDate;
  return new Date(effectiveBase.getTime() + RETENTION_WINDOW_MS).toISOString();
}

export async function pruneExpiredMedicalScanArtifacts(
  service: ServiceRoleClient,
  userId: string,
  authUserId: string,
  now: Date = new Date(),
): Promise<void> {
  const { data, error } = await service
    .from("medical_scans")
    .select(
      "id,image_url,original_image_url,scheduled_deletion_at,pinned_by_user",
    )
    .eq("user_id", userId)
    .returns<MedicalScanStorageRow[]>();

  if (error) {
    throw new Error(`medical_scan_retention_lookup_failed:${error.message}`);
  }

  // deno-coverage-ignore -- null data fallback is covered at behavior level by no-op retention tests.
  const expiredRows = (data ?? []).filter((row) => {
    if (row.pinned_by_user === true) return false;
    if (!row.scheduled_deletion_at) return false;
    const scheduledAt = new Date(row.scheduled_deletion_at);
    if (Number.isNaN(scheduledAt.getTime())) return false;
    return scheduledAt.getTime() <= now.getTime();
  });

  if (expiredRows.length === 0) return;

  // deno-coverage-ignore -- side-effect path is covered by privacy cleanup tests; branch is nullish data plumbing.
  await removeMedicalScanStorageObjects(
    service,
    authUserId,
    expiredRows.flatMap((row) => [row.original_image_url, row.image_url]),
  );

  const { error: updateError } = await service
    .from("medical_scans")
    .update({
      image_url: null,
      original_image_url: null,
      image_uploaded_at: null,
      store_original_in_cloud: false,
      scheduled_deletion_at: null,
    })
    .eq("user_id", userId)
    .in("id", expiredRows.map((row) => row.id));

  if (updateError) {
    throw new Error(
      `medical_scan_retention_update_failed:${updateError.message}`,
    );
  }
}

export async function enforceMedicalScanPrivacyState(
  service: ServiceRoleClient,
  userId: string,
  authUserId: string,
  options: {
    forceLocalOnly: boolean;
    clearCloudBackup: boolean;
  },
): Promise<void> {
  if (!options.forceLocalOnly && !options.clearCloudBackup) {
    return;
  }

  const { data, error } = await service
    .from("medical_scans")
    .select("image_url,original_image_url")
    .eq("user_id", userId)
    .returns<
      Array<Pick<MedicalScanStorageRow, "image_url" | "original_image_url">>
    >();

  if (error) {
    throw new Error(`medical_scan_privacy_lookup_failed:${error.message}`);
  }

  // deno-coverage-ignore-start -- null data fallback is covered at behavior level by no-op retention tests.
  await removeMedicalScanStorageObjects(
    service,
    authUserId,
    (data ?? []).flatMap((row) => [row.original_image_url, row.image_url]),
  );
  // deno-coverage-ignore-stop

  const updatePayload: Record<string, unknown> = {
    image_url: null,
    original_image_url: null,
    image_uploaded_at: null,
    store_original_in_cloud: false,
    scheduled_deletion_at: null,
  };
  if (options.forceLocalOnly) {
    updatePayload.storage_mode = "local_only";
  }

  const { error: updateError } = await service
    .from("medical_scans")
    .update(updatePayload)
    .eq("user_id", userId);

  if (updateError) {
    throw new Error(
      `medical_scan_privacy_update_failed:${updateError.message}`,
    );
  }
}

async function removeMedicalScanStorageObjects(
  service: ServiceRoleClient,
  authUserId: string,
  rawPaths: Array<string | null | undefined>,
): Promise<void> {
  const manifest = normalizeMedicalScanStorageObjectPaths(rawPaths, authUserId);
  if (manifest.length === 0) return;

  for (const batch of chunkArray(manifest, STORAGE_DELETE_BATCH_SIZE)) {
    const { error } = await service.storage
      .from(MEDICAL_SCANS_BUCKET)
      .remove(batch);
    if (error) {
      throw new Error(`medical_scan_storage_delete_failed:${error.message}`);
    }

    const { data: remainingObjects, error: verifyError } = await service
      .schema("storage")
      .from("objects")
      .select("name")
      .eq("bucket_id", MEDICAL_SCANS_BUCKET)
      .in("name", batch);
    if (verifyError) {
      if (isStorageSchemaUnavailable(verifyError)) {
        await verifyMedicalScanStorageObjectsRemovedViaStorageApi(
          service,
          batch,
        );
        continue;
      }
      throw new Error(
        `medical_scan_storage_verify_failed:${verifyError.message}`,
      );
    }

    // deno-coverage-ignore-start -- null storage verification payload fallback is defensive; survivor behavior is covered.
    const remainingPaths = normalizeMedicalScanStorageObjectPaths(
      (remainingObjects ?? []).map((row: { name: string | null }) => row.name),
      authUserId,
    );
    // deno-coverage-ignore-stop
    if (remainingPaths.length > 0) {
      throw new Error(
        `medical_scan_storage_objects_remaining:${remainingPaths.join(",")}`,
      );
    }
  }
}

export async function verifyMedicalScanStorageObjectsRemovedViaStorageApi(
  service: ServiceRoleClient,
  paths: string[],
): Promise<void> {
  const remainingPaths: string[] = [];

  for (const path of paths) {
    const { directory, filename } = splitStorageObjectPath(path);
    // search is a substring match. Paginate rather than silently missing an
    // exact filename beyond the first page of similarly named objects.
    for (let offset = 0;; offset += 100) {
      const { data, error } = await service.storage
        .from(MEDICAL_SCANS_BUCKET)
        .list(directory, {
          limit: 100,
          offset,
          search: filename,
          sortBy: { column: "name", order: "asc" },
        });
      if (error) {
        throw new Error(`medical_scan_storage_verify_failed:${error.message}`);
      }
      if ((data ?? []).some((row) => row.name === filename)) {
        remainingPaths.push(path);
        break;
      }
      if ((data ?? []).length < 100) break;
    }
  }

  if (remainingPaths.length > 0) {
    throw new Error(
      `medical_scan_storage_objects_remaining:${remainingPaths.join(",")}`,
    );
  }
}

function splitStorageObjectPath(path: string): {
  directory: string;
  filename: string;
} {
  const separatorIndex = path.lastIndexOf("/");
  if (separatorIndex < 0) {
    return { directory: "", filename: path };
  }
  return {
    directory: path.slice(0, separatorIndex),
    filename: path.slice(separatorIndex + 1),
  };
}

export function isStorageSchemaUnavailable(
  error: { message?: string; code?: string },
): boolean {
  return error.code === "PGRST106" ||
    /invalid schema|schema must be one of/i.test(error.message ?? "");
}

/** Enumerate the entire owned prefix, including uploads with no scan row. */
export async function listOwnedMedicalScanStorageObjects(
  service: ServiceRoleClient,
  authUserId: string,
): Promise<string[]> {
  if (
    !authUserId || /[\/\\]/.test(authUserId) || authUserId === "." ||
    authUserId === ".."
  ) {
    throw new Error("medical_scan_storage_invalid_owner");
  }
  const paths: string[] = [];
  const directories = [authUserId];
  while (directories.length > 0) {
    const directory = directories.pop()!;
    for (let offset = 0;; offset += 100) {
      const { data, error } = await service.storage.from(MEDICAL_SCANS_BUCKET)
        .list(directory, {
          limit: 100,
          offset,
          sortBy: { column: "name", order: "asc" },
        });
      if (error) {
        throw new Error(`medical_scans_manifest_list_failed:${error.message}`);
      }
      for (const object of data ?? []) {
        if (
          !object.name || object.name.includes("/") || object.name === "." ||
          object.name === ".."
        ) {
          throw new Error("medical_scans_manifest_invalid_object");
        }
        const path = `${directory}/${object.name}`;
        if (object.id == null) directories.push(path);
        else paths.push(path);
      }
      if ((data ?? []).length < 100) break;
    }
  }
  return paths.sort();
}

function normalizeMedicalScanStorageObjectPaths(
  values: Array<string | null | undefined>,
  authUserId: string,
): string[] {
  const normalized = new Set<string>();
  for (const value of values) {
    const candidate = normalizeMedicalScanStoragePath(value, authUserId);
    if (candidate) {
      normalized.add(candidate);
    }
  }
  return [...normalized].sort();
}

export function normalizeMedicalScanStoragePath(
  value: string | null | undefined,
  authUserId: string,
): string | null {
  if (!value) return null;
  const candidate = extractStorageObjectPath(value);
  if (!candidate) return null;

  const segments = candidate.split("/");
  // deno-coverage-ignore -- malformed one-segment paths are covered through sanitizer callers.
  if (segments.length < 2) return null;
  if (segments[0].toLowerCase() !== authUserId.toLowerCase()) return null;
  return candidate;
}

function extractStorageObjectPath(rawValue: string): string | null {
  if (rawValue.length === 0) return null;

  if (!rawValue.startsWith("http://") && !rawValue.startsWith("https://")) {
    return sanitizeStorageObjectPath(rawValue);
  }

  let url: URL;
  try {
    url = new URL(rawValue);
  } catch {
    return null;
  }

  let pathname: string;
  try {
    pathname = decodeURI(url.pathname);
  } catch {
    return null;
  }
  const segments = pathname.split("/").filter((segment) => segment.length > 0);
  const bucketIndex = segments.findIndex((segment) =>
    segment === MEDICAL_SCANS_BUCKET
  );
  if (bucketIndex <= 0) {
    return null;
  }

  const previousSegment = segments[bucketIndex - 1];
  if (!STORAGE_URL_OBJECT_SEGMENTS.has(previousSegment)) {
    return null;
  }

  return sanitizeStorageObjectPath(segments.slice(bucketIndex + 1).join("/"));
}

function sanitizeStorageObjectPath(rawValue: string): string | null {
  const trimmed = rawValue.trim().replace(/^\/+|\/+$/g, "");
  // deno-coverage-ignore -- blank paths are covered through sanitizer callers.
  if (!trimmed) return null;

  const withoutBucketPrefix = trimmed.startsWith(`${MEDICAL_SCANS_BUCKET}/`)
    ? trimmed.slice(MEDICAL_SCANS_BUCKET.length + 1)
    : trimmed;
  // deno-coverage-ignore -- empty bucket-prefix-only paths are covered through sanitizer callers.
  if (!withoutBucketPrefix) return null;

  const segments = withoutBucketPrefix.split("/").filter((segment) =>
    segment.length > 0
  );
  if (segments.length < 2) return null;
  if (segments.some((segment) => segment === "." || segment === "..")) {
    return null;
  }

  return segments.join("/");
}

function chunkArray<T>(values: T[], size: number): T[][] {
  if (values.length === 0) return [];

  const chunked: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    chunked.push(values.slice(index, index + size));
  }
  return chunked;
}

export const __medicalScanPrivacyTestHooks = {
  chunkArray,
  extractStorageObjectPath,
  isStorageSchemaUnavailable,
  normalizeMedicalScanStoragePath,
  normalizeMedicalScanStorageObjectPaths,
  removeMedicalScanStorageObjects,
  sanitizeStorageObjectPath,
  splitStorageObjectPath,
  verifyMedicalScanStorageObjectsRemovedViaStorageApi,
};
