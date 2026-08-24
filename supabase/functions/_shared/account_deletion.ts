import { serviceRoleClient } from "./supabase.ts";
import {
  assertDeletionStateTransition,
  type DeletionJobMode,
  type DeletionJobState,
} from "./account_deletion_state_machine.ts";

export type DeletionFailureType = "pinecone" | "postgres" | "auth" | "storage";

export interface UserRow {
  id: string;
  auth_id: string;
}

export interface DeletionJobRow {
  id: string;
  user_id: string;
  auth_user_id: string | null;
  idempotency_key: string;
  mode: DeletionJobMode;
  state: DeletionJobState;
  reason: string | null;
  attempt_count: number;
  next_retry_at: string | null;
  last_error: string | null;
  last_failure_type: DeletionFailureType | null;
  scheduled_for: string | null;
  audit_log_id: string | null;
  storage_object_paths: string[];
  storage_cleanup_completed: boolean;
  storage_cleanup_completed_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface DeletionAttemptResult {
  ok: boolean;
  failureType?: DeletionFailureType;
  error?: string;
}

type ServiceRoleClient = ReturnType<typeof serviceRoleClient>;

interface MedicalScanStorageRow {
  image_url: string | null;
  original_image_url: string | null;
}

export const AUTH_DELETE_RETRY_ATTEMPTS = 3;
export const AUTH_DELETE_RETRY_BACKOFF_MS = 250;
export const DELETION_JOB_SELECT =
  "id,user_id,auth_user_id,idempotency_key,mode,state,reason,attempt_count,next_retry_at,last_error,last_failure_type,scheduled_for,audit_log_id,storage_object_paths,storage_cleanup_completed,storage_cleanup_completed_at,created_at,updated_at";
export const MEDICAL_SCANS_BUCKET = "medical-scans";
const STORAGE_DELETE_BATCH_SIZE = 1000;
const STORAGE_URL_OBJECT_SEGMENTS = new Set([
  "public",
  "authenticated",
  "sign",
  "render",
]);

export function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function deleteAuthPrincipalWithRetry(
  service: ServiceRoleClient,
  authUserId: string,
): Promise<DeletionAttemptResult> {
  let latest: DeletionAttemptResult = {
    ok: false,
    failureType: "auth",
    error: "auth_delete_retry_exhausted",
  };

  for (let attempt = 1; attempt <= AUTH_DELETE_RETRY_ATTEMPTS; attempt++) {
    latest = await deleteAuthPrincipal(service, authUserId);
    if (latest.ok) {
      return latest;
    }

    if (attempt < AUTH_DELETE_RETRY_ATTEMPTS) {
      await delay(AUTH_DELETE_RETRY_BACKOFF_MS * attempt);
    }
  }

  return latest;
}

export async function deletePostgresData(
  service: ServiceRoleClient,
  userId: string,
): Promise<DeletionAttemptResult> {
  const { data: deleteData, error: deleteError } = await service.rpc(
    "delete_user_account",
    {
      user_uuid: userId,
    },
  );

  if (deleteError) {
    return {
      ok: false,
      failureType: "postgres",
      error: deleteError.message,
    };
  }

  if (deleteData === true) {
    return { ok: true };
  }

  const { data: remainingUser, error: remainingUserError } = await service
    .from("users")
    .select("id")
    .eq("id", userId)
    .maybeSingle<{ id: string }>();

  if (remainingUserError) {
    return {
      ok: false,
      failureType: "postgres",
      error: `delete_user_account_verify_failed: ${remainingUserError.message}`,
    };
  }

  if (!remainingUser) {
    return { ok: true };
  }

  return {
    ok: false,
    failureType: "postgres",
    error: "delete_user_account returned false",
  };
}

export async function verifyVectorDeletion(
  service: ServiceRoleClient,
  userId: string,
): Promise<DeletionAttemptResult> {
  const { count: remainingVectors, error: vectorsError } = await service
    .from("vector_memory")
    .select("id", { count: "exact", head: true })
    .eq("user_id", userId);

  if (vectorsError) {
    return {
      ok: false,
      failureType: "pinecone",
      error: `vector_verification_failed: ${vectorsError.message}`,
    };
  }

  if ((remainingVectors ?? 0) > 0) {
    return {
      ok: false,
      failureType: "pinecone",
      error: "vector_records_remaining_after_delete",
    };
  }

  return { ok: true };
}

export async function recordFailure(
  service: ServiceRoleClient,
  userId: string,
  failureType: DeletionFailureType,
  error: string,
): Promise<void> {
  await service.from("deletion_failures").insert({
    user_id: userId,
    failure_type: failureType,
    error,
    resolved: false,
    created_at: new Date().toISOString(),
  });
}

export async function upsertDeletionAudit(
  service: ServiceRoleClient,
  options: {
    id: string;
    userId: string;
    vectorsDeleted: boolean;
    postgresDeleted: boolean;
    authDeleted: boolean;
    storageDeleted: boolean;
    notes: string | null;
  },
): Promise<string | null> {
  const { error } = await service.from("deletion_audit_log").upsert(
    {
      id: options.id,
      user_id_deleted: options.userId,
      deleted_at: new Date().toISOString(),
      vectors_deleted: options.vectorsDeleted,
      postgres_deleted: options.postgresDeleted,
      storage_deleted: options.storageDeleted,
      compliance_verified: options.vectorsDeleted && options.postgresDeleted &&
        options.authDeleted && options.storageDeleted,
      notes: options.notes,
    },
    { onConflict: "id" },
  );
  return error?.message ?? null;
}

export async function getOrCreateDeletionJob(
  service: ServiceRoleClient,
  options: {
    userId: string;
    authUserId: string;
    idempotencyKey: string;
    mode: DeletionJobMode;
    reason: string;
    scheduledFor: string | null;
  },
): Promise<DeletionJobRow> {
  const existing = await fetchDeletionJobByKey(
    service,
    options.userId,
    options.idempotencyKey,
  );
  if (existing) {
    return existing;
  }

  const { data, error } = await service
    .from("account_deletion_jobs")
    .insert({
      user_id: options.userId,
      auth_user_id: options.authUserId,
      idempotency_key: options.idempotencyKey,
      mode: options.mode,
      state: "requested",
      reason: options.reason,
      attempt_count: 0,
      scheduled_for: options.scheduledFor,
      storage_object_paths: [],
      storage_cleanup_completed: false,
    })
    .select(DELETION_JOB_SELECT)
    .single<DeletionJobRow>();

  if (error) {
    if (isUniqueViolation(error)) {
      const raced = await fetchDeletionJobByKey(
        service,
        options.userId,
        options.idempotencyKey,
      );
      if (raced) {
        return raced;
      }
    }
    throw new Error(error.message);
  }

  return normalizeDeletionJobRow(data);
}

export async function fetchDeletionJobByKey(
  service: ServiceRoleClient,
  userId: string,
  idempotencyKey: string,
): Promise<DeletionJobRow | null> {
  const { data, error } = await service
    .from("account_deletion_jobs")
    .select(DELETION_JOB_SELECT)
    .eq("user_id", userId)
    .eq("idempotency_key", idempotencyKey)
    .maybeSingle<DeletionJobRow>();

  if (error) {
    throw new Error(error.message);
  }

  return data ? normalizeDeletionJobRow(data) : null;
}

export async function updateDeletionJobState(
  service: ServiceRoleClient,
  current: DeletionJobRow,
  nextState: DeletionJobState,
  patch: Record<string, unknown>,
): Promise<DeletionJobRow> {
  assertDeletionStateTransition(current.state, nextState);

  const { data, error } = await service
    .from("account_deletion_jobs")
    .update({
      state: nextState,
      ...patch,
    })
    .eq("id", current.id)
    .eq("state", current.state)
    .select(DELETION_JOB_SELECT)
    .maybeSingle<DeletionJobRow>();

  if (error) {
    throw new Error(error.message);
  }
  if (!data) {
    throw new Error(
      `deletion_job_state_conflict:${current.id}:${current.state}->${nextState}`,
    );
  }

  return normalizeDeletionJobRow(data);
}

export async function updateDeletionJob(
  service: ServiceRoleClient,
  current: DeletionJobRow,
  patch: Record<string, unknown>,
): Promise<DeletionJobRow> {
  const { data, error } = await service
    .from("account_deletion_jobs")
    .update(patch)
    .eq("id", current.id)
    .select(DELETION_JOB_SELECT)
    .maybeSingle<DeletionJobRow>();

  if (error) {
    throw new Error(error.message);
  }
  if (!data) {
    throw new Error(`deletion_job_not_found:${current.id}`);
  }

  return normalizeDeletionJobRow(data);
}

export async function deletionJobCascadeDeletedAfterUserRemoval(
  service: ServiceRoleClient,
  userId: string,
  auditLogId: string,
  error: unknown,
): Promise<boolean> {
  if (!isDeletionJobStateConflict(error)) {
    return false;
  }

  const { data: remainingUser, error: remainingUserError } = await service
    .from("users")
    .select("id")
    .eq("id", userId)
    .maybeSingle<{ id: string }>();
  if (remainingUserError || remainingUser) {
    return false;
  }

  const { data: auditRow, error: auditLookupError } = await service
    .from("deletion_audit_log")
    .select("id")
    .eq("id", auditLogId)
    .maybeSingle<{ id: string }>();
  if (auditLookupError || !auditRow) {
    return false;
  }

  return true;
}

export function isDeletionJobStateConflict(error: unknown): boolean {
  const detail = error instanceof Error ? error.message : String(error);
  return detail.startsWith("deletion_job_state_conflict:");
}

export function cascadedFailureState(
  state: DeletionJobState,
): DeletionJobState {
  return state === "failed" ? state : "failed";
}

export function normalizeIdempotencyKey(value: string | null): string | null {
  if (!value) return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  if (trimmed.length > 128) return null;
  if (!/^[A-Za-z0-9._:-]+$/.test(trimmed)) return null;
  return trimmed;
}

export function retryAfterSeconds(nextRetryAt: string | null): number {
  if (!nextRetryAt) return 0;
  const retryAtMs = Date.parse(nextRetryAt);
  if (!Number.isFinite(retryAtMs)) return 0;
  return Math.max(0, Math.ceil((retryAtMs - Date.now()) / 1000));
}

export function normalizeMedicalScanStoragePath(
  rawValue: string | null | undefined,
  userAuthId: string,
): string | null {
  const raw = rawValue?.trim();
  if (!raw) return null;

  const expectedPrefix = `${userAuthId.toLowerCase()}/`;
  const candidate = extractStorageObjectPath(raw);
  if (!candidate) return null;
  if (!candidate.toLowerCase().startsWith(expectedPrefix)) return null;

  return candidate;
}

export async function ensureDeletionJobStorageManifest(
  service: ServiceRoleClient,
  user: UserRow,
  job: DeletionJobRow,
): Promise<DeletionJobRow> {
  if (job.storage_cleanup_completed) {
    return job;
  }

  const normalizedExisting = normalizeStorageObjectPaths(
    job.storage_object_paths,
    user.auth_id,
  );
  if (normalizedExisting.length > 0) {
    if (
      normalizedExisting.length !== job.storage_object_paths.length ||
      normalizedExisting.some((path, index) =>
        path !== job.storage_object_paths[index]
      )
    ) {
      return await updateDeletionJob(service, job, {
        storage_object_paths: normalizedExisting,
      });
    }
    return job;
  }

  const { data, error } = await service
    .from("medical_scans")
    .select("image_url,original_image_url")
    .eq("user_id", user.id);
  if (error) {
    throw new Error(`medical_scans_manifest_failed:${error.message}`);
  }

  // deno-coverage-ignore-start -- null medical scan manifest fallback is defensive; manifest behavior is covered.
  const manifest = normalizeStorageObjectPaths(
    (data ?? []).flatMap((
      row: MedicalScanStorageRow,
    ) => [row.original_image_url, row.image_url]),
    user.auth_id,
  );
  // deno-coverage-ignore-stop

  return await updateDeletionJob(service, job, {
    auth_user_id: job.auth_user_id ?? user.auth_id,
    storage_object_paths: manifest,
  });
}

export async function cleanupMedicalScanStorage(
  service: ServiceRoleClient,
  user: UserRow,
  job: DeletionJobRow,
): Promise<DeletionAttemptResult & { job: DeletionJobRow }> {
  if (job.storage_cleanup_completed) {
    return { ok: true, job };
  }

  job = await ensureDeletionJobStorageManifest(service, user, job);
  const manifest = normalizeStorageObjectPaths(
    job.storage_object_paths,
    user.auth_id,
  );

  if (manifest.length > 0) {
    for (const batch of chunkArray(manifest, STORAGE_DELETE_BATCH_SIZE)) {
      const { error } = await service.storage
        .from(MEDICAL_SCANS_BUCKET)
        .remove(batch);
      if (error) {
        return {
          ok: false,
          job,
          failureType: "storage",
          error: `medical_scan_storage_delete_failed:${error.message}`,
        };
      }
    }

    const remainingPaths = new Set<string>();
    for (const batch of chunkArray(manifest, STORAGE_DELETE_BATCH_SIZE)) {
      const { data: remainingObjects, error: verifyError } = await service
        .schema("storage")
        .from("objects")
        .select("name")
        .eq("bucket_id", MEDICAL_SCANS_BUCKET)
        .in("name", batch);
      if (verifyError) {
        return {
          ok: false,
          job,
          failureType: "storage",
          error: `medical_scan_storage_verify_failed:${verifyError.message}`,
        };
      }

      // deno-coverage-ignore-start -- null storage verification payload fallback is defensive; survivor behavior is covered.
      const normalizedRemainingPaths = normalizeStorageObjectPaths(
        (remainingObjects ?? []).map((row: { name: string | null }) =>
          row.name
        ),
        user.auth_id,
      );
      // deno-coverage-ignore-stop
      for (const path of normalizedRemainingPaths) {
        remainingPaths.add(path);
      }
    }

    if (remainingPaths.size > 0) {
      return {
        ok: false,
        job,
        failureType: "storage",
        error: `medical_scan_storage_objects_remaining:${
          [...remainingPaths].join(",")
        }`,
      };
    }
  }

  job = await updateDeletionJob(service, job, {
    auth_user_id: job.auth_user_id ?? user.auth_id,
    storage_object_paths: manifest,
    storage_cleanup_completed: true,
    storage_cleanup_completed_at: new Date().toISOString(),
  });

  return {
    ok: true,
    job,
  };
}

export function isUniqueViolation(error: { code?: string }): boolean {
  return error.code === "23505";
}

function normalizeDeletionJobRow(row: DeletionJobRow): DeletionJobRow {
  return {
    ...row,
    auth_user_id: row.auth_user_id ?? null,
    storage_object_paths: Array.isArray(row.storage_object_paths)
      ? row.storage_object_paths.filter((value): value is string =>
        typeof value === "string" && value.length > 0
      )
      : [],
    storage_cleanup_completed: row.storage_cleanup_completed === true,
    storage_cleanup_completed_at: row.storage_cleanup_completed_at ?? null,
  };
}

function normalizeStorageObjectPaths(
  values: Array<string | null | undefined>,
  userAuthId: string,
): string[] {
  const normalized = new Set<string>();
  for (const value of values) {
    const candidate = normalizeMedicalScanStoragePath(value, userAuthId);
    if (candidate) {
      normalized.add(candidate);
    }
  }
  return [...normalized].sort();
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
  if (bucketIndex < 0) {
    return null;
  }

  if (bucketIndex === 0) {
    return null;
  }

  const previousSegment = segments[bucketIndex - 1];
  if (!STORAGE_URL_OBJECT_SEGMENTS.has(previousSegment)) {
    return null;
  }

  const objectPath = segments.slice(bucketIndex + 1).join("/");
  return sanitizeStorageObjectPath(objectPath);
}

function sanitizeStorageObjectPath(rawValue: string): string | null {
  const trimmed = rawValue.trim().replace(/^\/+|\/+$/g, "");
  if (!trimmed) return null;

  const withoutBucketPrefix = trimmed.startsWith(`${MEDICAL_SCANS_BUCKET}/`)
    ? trimmed.slice(MEDICAL_SCANS_BUCKET.length + 1)
    : trimmed;
  // deno-coverage-ignore -- bucket-prefix-only paths are covered through sanitizer behavior tests.
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

async function deleteAuthPrincipal(
  service: ServiceRoleClient,
  authUserId: string,
): Promise<DeletionAttemptResult> {
  const { error } = await service.auth.admin.deleteUser(authUserId);
  if (!error) {
    return { ok: true };
  }

  if (isAuthPrincipalMissing(error)) {
    return { ok: true };
  }

  return {
    ok: false,
    failureType: "auth",
    error: error.message,
  };
}

function isAuthPrincipalMissing(
  error: { message?: string; status?: number },
): boolean {
  const status = typeof error.status === "number" ? error.status : null;
  if (status === 404) {
    return true;
  }

  return (error.message ?? "").toLowerCase().includes("not found");
}

function chunkArray<T>(values: T[], size: number): T[][] {
  if (values.length === 0) return [];

  const chunked: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    chunked.push(values.slice(index, index + size));
  }
  return chunked;
}

export const __accountDeletionTestHooks = {
  chunkArray,
  extractStorageObjectPath,
  isAuthPrincipalMissing,
  normalizeStorageObjectPaths,
  sanitizeStorageObjectPath,
};
