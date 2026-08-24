import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  __medicalScanPrivacyTestHooks,
  computeMedicalScanScheduledDeletionAt,
  enforceMedicalScanPrivacyState,
  loadMedicalScanPrivacySettings,
  pruneExpiredMedicalScanArtifacts,
} from "../_shared/medical_scan_privacy.ts";

type PrivacySettingsRow = {
  medical_scan_local_only: boolean | null;
  cloud_backup_enabled: boolean | null;
};

type ScanRow = {
  id: string;
  image_url: string | null;
  original_image_url: string | null;
  scheduled_deletion_at?: string | null;
  pinned_by_user?: boolean | null;
};

interface MockPrivacyServiceConfig {
  privacySettings?: {
    data: PrivacySettingsRow | null;
    error: { message: string } | null;
  };
  medicalScans?: {
    data: ScanRow[] | null;
    error: { message: string } | null;
  };
  storageRemoveError?: { message: string } | null;
  storageObjects?: {
    data: Array<{ name: string | null }> | null;
    error: { message: string } | null;
  };
  storageList?: {
    data: Array<{ name: string | null }> | null;
    error: { message: string } | null;
  };
  updateError?: { message: string } | null;
}

function createMockPrivacyService(config: MockPrivacyServiceConfig = {}) {
  const calls = {
    removedBatches: [] as string[][],
    verifiedBatches: [] as string[][],
    listedSearches: [] as Array<
      { directory: string; search: string | undefined }
    >,
    updatePatches: [] as Array<Record<string, unknown>>,
    updateIds: [] as string[][],
  };

  const buildQuery = (table: string) => ({
    select: (_columns: string) => buildQuery(table),
    update: (patch: Record<string, unknown>) => {
      calls.updatePatches.push(patch);
      return buildQuery(`${table}:update`);
    },
    eq: (_column: string, _value: unknown) => buildQuery(table),
    in: (_column: string, values: string[]) => {
      if (table === "medical_scans:update") {
        calls.updateIds.push(values);
        return Promise.resolve({ error: config.updateError ?? null });
      }
      if (table === "storage.objects") {
        calls.verifiedBatches.push(values);
        return Promise.resolve(
          config.storageObjects ?? { data: [], error: null },
        );
      }
      return Promise.resolve({ error: null });
    },
    maybeSingle: () => {
      if (table === "privacy_settings") {
        return Promise.resolve(
          config.privacySettings ?? { data: null, error: null },
        );
      }
      return Promise.resolve({
        data: null,
        error: { message: `unsupported maybeSingle table: ${table}` },
      });
    },
    returns: () => {
      if (table === "medical_scans") {
        return Promise.resolve(
          config.medicalScans ?? { data: [], error: null },
        );
      }
      return Promise.resolve({
        data: null,
        error: { message: `unsupported returns table: ${table}` },
      });
    },
    then: (
      onFulfilled?: (value: { error: { message: string } | null }) => unknown,
      onRejected?: (reason: unknown) => unknown,
    ) =>
      Promise.resolve({
        error: table === "medical_scans:update"
          ? config.updateError ?? null
          : null,
      }).then(onFulfilled, onRejected),
  });

  return {
    from: (table: string) => buildQuery(table),
    schema: (_schema: string) => ({
      from: (table: string) => buildQuery(`storage.${table}`),
    }),
    storage: {
      from: (_bucket: string) => ({
        remove: (paths: string[]) => {
          calls.removedBatches.push(paths);
          return Promise.resolve({ error: config.storageRemoveError ?? null });
        },
        list: (
          directory: string,
          options: { limit: number; search?: string },
        ) => {
          void options.limit;
          calls.listedSearches.push({
            directory,
            search: options.search,
          });
          return Promise.resolve(
            config.storageList ?? { data: [], error: null },
          );
        },
      }),
    },
    __calls: calls,
  };
}

Deno.test("medical scan privacy settings default to local-only without cloud backup", async () => {
  assertEquals(
    await loadMedicalScanPrivacySettings(
      createMockPrivacyService() as never,
      "user-1",
    ),
    {
      medicalScanLocalOnly: true,
      cloudBackupEnabled: false,
    },
  );

  assertEquals(
    await loadMedicalScanPrivacySettings(
      createMockPrivacyService({
        privacySettings: {
          data: {
            medical_scan_local_only: false,
            cloud_backup_enabled: true,
          },
          error: null,
        },
      }) as never,
      "user-1",
    ),
    {
      medicalScanLocalOnly: false,
      cloudBackupEnabled: true,
    },
  );

  await assertRejects(
    () =>
      loadMedicalScanPrivacySettings(
        createMockPrivacyService({
          privacySettings: {
            data: null,
            error: { message: "settings_down" },
          },
        }) as never,
        "user-1",
      ),
    Error,
    "privacy_settings_lookup_failed:settings_down",
  );
});

Deno.test("medical scan retention deadline uses valid createdAt and falls back on invalid input", () => {
  assertEquals(
    computeMedicalScanScheduledDeletionAt("2026-01-01T00:00:00.000Z"),
    "2026-04-01T00:00:00.000Z",
  );

  const implicitNow = computeMedicalScanScheduledDeletionAt(null);
  assertEquals(Number.isNaN(new Date(implicitNow).getTime()), false);

  const fallback = computeMedicalScanScheduledDeletionAt("not-a-date");
  assertEquals(Number.isNaN(new Date(fallback).getTime()), false);
});

Deno.test("medical scan privacy hooks normalize only safe owned paths", () => {
  const hooks = __medicalScanPrivacyTestHooks;
  const authUserId = "22222222-2222-4222-8222-222222222222";

  assertEquals(hooks.sanitizeStorageObjectPath(" medical-scans/ "), null);
  assertEquals(hooks.sanitizeStorageObjectPath("medical-scans"), null);
  assertEquals(
    hooks.sanitizeStorageObjectPath("medical-scans/auth-user"),
    null,
  );
  assertEquals(hooks.extractStorageObjectPath(""), null);
  assertEquals(hooks.extractStorageObjectPath("https://%"), null);
  assertEquals(
    hooks.extractStorageObjectPath(
      "https://example.supabase.co/medical-scans/auth-user/scan/file.jpg",
    ),
    null,
  );
  assertEquals(
    hooks.normalizeMedicalScanStoragePath(
      "https://example.supabase.co/storage/v1/object/unknown/medical-scans/auth-user/scan/file.jpg",
      "auth-user",
    ),
    null,
  );
  assertEquals(
    hooks.normalizeMedicalScanStoragePath("https://bad url", "auth-user"),
    null,
  );
  assertEquals(
    hooks.normalizeMedicalScanStoragePath(
      "https://example.supabase.co/storage/v1/object/public/medical-scans/%E0%A4%A",
      "auth-user",
    ),
    null,
  );
  assertEquals(
    hooks.normalizeMedicalScanStoragePath(
      `${authUserId}/scan/file.jpg`,
      authUserId,
    ),
    `${authUserId}/scan/file.jpg`,
  );
  assertEquals(
    hooks.splitStorageObjectPath("plain-file.jpg"),
    { directory: "", filename: "plain-file.jpg" },
  );
  assertEquals(
    hooks.splitStorageObjectPath(`${authUserId}/scan/file.jpg`),
    { directory: `${authUserId}/scan`, filename: "file.jpg" },
  );
  assertEquals(
    hooks.isStorageSchemaUnavailable({ message: "INVALID SCHEMA name" }),
    true,
  );
  assertEquals(hooks.isStorageSchemaUnavailable({}), false);
});

Deno.test("pruneExpiredMedicalScanArtifacts removes expired unpinned cloud artifacts", async () => {
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const ownedOriginal = `${authUserId}/scan-a/original.pdf`;
  const ownedPreview = `${authUserId}/scan-a/preview.jpg`;
  const service = createMockPrivacyService({
    medicalScans: {
      data: [
        {
          id: "expired",
          original_image_url: `medical-scans/${ownedOriginal}`,
          image_url:
            `https://example.supabase.co/storage/v1/object/sign/medical-scans/${ownedPreview}?token=abc`,
          scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
          pinned_by_user: false,
        },
        {
          id: "pinned",
          original_image_url: `${authUserId}/scan-b/original.pdf`,
          image_url: null,
          scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
          pinned_by_user: true,
        },
        {
          id: "future",
          original_image_url: `${authUserId}/scan-c/original.pdf`,
          image_url: null,
          scheduled_deletion_at: "2026-04-01T00:00:00.000Z",
          pinned_by_user: false,
        },
        {
          id: "foreign",
          original_image_url:
            "33333333-3333-4333-8333-333333333333/scan/original.pdf",
          image_url: null,
          scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
          pinned_by_user: false,
        },
      ],
      error: null,
    },
  });

  await pruneExpiredMedicalScanArtifacts(
    service as never,
    "user-1",
    authUserId,
    new Date("2026-03-15T00:00:00.000Z"),
  );

  assertEquals(service.__calls.removedBatches, [[ownedOriginal, ownedPreview]]);
  assertEquals(service.__calls.verifiedBatches, [[
    ownedOriginal,
    ownedPreview,
  ]]);
  assertEquals(service.__calls.updateIds, [["expired", "foreign"]]);
  assertEquals(service.__calls.updatePatches[0], {
    image_url: null,
    original_image_url: null,
    image_uploaded_at: null,
    store_original_in_cloud: false,
    scheduled_deletion_at: null,
  });
});

Deno.test("pruneExpiredMedicalScanArtifacts surfaces storage verification failures", async () => {
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const ownedPath = `${authUserId}/scan/original.pdf`;
  const service = createMockPrivacyService({
    medicalScans: {
      data: [{
        id: "expired",
        original_image_url: ownedPath,
        image_url: null,
        scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
        pinned_by_user: false,
      }],
      error: null,
    },
    storageObjects: {
      data: [{ name: ownedPath }],
      error: null,
    },
  });

  await assertRejects(
    () =>
      pruneExpiredMedicalScanArtifacts(
        service as never,
        "user-1",
        authUserId,
        new Date("2026-03-15T00:00:00.000Z"),
      ),
    Error,
    `medical_scan_storage_objects_remaining:${ownedPath}`,
  );
});

Deno.test("medical scan storage verification falls back to storage API when schema access is unavailable", async () => {
  const hooks = __medicalScanPrivacyTestHooks;
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const ownedPath = `${authUserId}/scan/original.pdf`;
  const service = createMockPrivacyService({
    storageObjects: {
      data: null,
      error: { message: "invalid schema name storage" },
    },
    storageList: {
      data: [],
      error: null,
    },
  });

  await hooks.removeMedicalScanStorageObjects(
    service as never,
    authUserId,
    [ownedPath, null],
  );

  assertEquals(service.__calls.removedBatches, [[ownedPath]]);
  assertEquals(service.__calls.listedSearches, [{
    directory: `${authUserId}/scan`,
    search: "original.pdf",
  }]);
});

Deno.test("medical scan storage cleanup batches large owned manifests safely", async () => {
  const hooks = __medicalScanPrivacyTestHooks;
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const paths = Array.from(
    { length: 1001 },
    (_, index) => `${authUserId}/scan-${index}/original.pdf`,
  );
  const service = createMockPrivacyService();

  await hooks.removeMedicalScanStorageObjects(
    service as never,
    authUserId,
    paths,
  );

  assertEquals(service.__calls.removedBatches.length, 2);
  assertEquals(service.__calls.removedBatches[0].length, 1000);
  assertEquals(service.__calls.removedBatches[1], [
    `${authUserId}/scan-999/original.pdf`,
  ]);
  assertEquals(service.__calls.verifiedBatches.length, 2);
});

Deno.test("medical scan storage API verification surfaces list failures and remaining paths", async () => {
  const hooks = __medicalScanPrivacyTestHooks;

  await assertRejects(
    () =>
      hooks.verifyMedicalScanStorageObjectsRemovedViaStorageApi(
        createMockPrivacyService({
          storageList: {
            data: null,
            error: { message: "list_down" },
          },
        }) as never,
        ["auth-user/scan/file.jpg"],
      ),
    Error,
    "medical_scan_storage_verify_failed:list_down",
  );

  await assertRejects(
    () =>
      hooks.verifyMedicalScanStorageObjectsRemovedViaStorageApi(
        createMockPrivacyService({
          storageList: {
            data: [{ name: "file.jpg" }],
            error: null,
          },
        }) as never,
        ["auth-user/scan/file.jpg"],
      ),
    Error,
    "medical_scan_storage_objects_remaining:auth-user/scan/file.jpg",
  );
});

Deno.test("pruneExpiredMedicalScanArtifacts skips pinned invalid and future rows when nothing is deletable", async () => {
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const service = createMockPrivacyService({
    medicalScans: {
      data: [
        {
          id: "pinned",
          original_image_url: `${authUserId}/scan-a/original.pdf`,
          image_url: null,
          scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
          pinned_by_user: true,
        },
        {
          id: "invalid-date",
          original_image_url: `${authUserId}/scan-b/original.pdf`,
          image_url: null,
          scheduled_deletion_at: "not-a-date",
          pinned_by_user: false,
        },
        {
          id: "missing-date",
          original_image_url: `${authUserId}/scan-c/original.pdf`,
          image_url: null,
          scheduled_deletion_at: null,
          pinned_by_user: false,
        },
        {
          id: "future",
          original_image_url: `${authUserId}/scan-d/original.pdf`,
          image_url: null,
          scheduled_deletion_at: "2026-04-01T00:00:00.000Z",
          pinned_by_user: false,
        },
      ],
      error: null,
    },
  });

  await pruneExpiredMedicalScanArtifacts(
    service as never,
    "user-1",
    authUserId,
    new Date("2026-03-15T00:00:00.000Z"),
  );

  assertEquals(service.__calls.removedBatches, []);
  assertEquals(service.__calls.updatePatches.length, 0);
});

Deno.test("pruneExpiredMedicalScanArtifacts surfaces lookup, delete, and update failures", async (t) => {
  const authUserId = "22222222-2222-4222-8222-222222222222";

  await t.step("medical scan lookup failure", async () => {
    await assertRejects(
      () =>
        pruneExpiredMedicalScanArtifacts(
          createMockPrivacyService({
            medicalScans: {
              data: null,
              error: { message: "lookup_down" },
            },
          }) as never,
          "user-1",
          authUserId,
          new Date("2026-03-15T00:00:00.000Z"),
        ),
      Error,
      "medical_scan_retention_lookup_failed:lookup_down",
    );
  });

  await t.step("storage delete failure", async () => {
    await assertRejects(
      () =>
        pruneExpiredMedicalScanArtifacts(
          createMockPrivacyService({
            medicalScans: {
              data: [{
                id: "expired",
                original_image_url: `${authUserId}/scan/original.pdf`,
                image_url: null,
                scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
                pinned_by_user: false,
              }],
              error: null,
            },
            storageRemoveError: { message: "storage_down" },
          }) as never,
          "user-1",
          authUserId,
          new Date("2026-03-15T00:00:00.000Z"),
        ),
      Error,
      "medical_scan_storage_delete_failed:storage_down",
    );
  });

  await t.step("row update failure after cleanup", async () => {
    await assertRejects(
      () =>
        pruneExpiredMedicalScanArtifacts(
          createMockPrivacyService({
            medicalScans: {
              data: [{
                id: "expired",
                original_image_url:
                  `https://example.supabase.co/storage/v1/object/public/medical-scans/${authUserId}/scan/original.pdf`,
                image_url: `medical-scans/${authUserId}/scan/original.pdf`,
                scheduled_deletion_at: "2026-03-01T00:00:00.000Z",
                pinned_by_user: false,
              }],
              error: null,
            },
            updateError: { message: "update_failed" },
          }) as never,
          "user-1",
          authUserId,
          new Date("2026-03-15T00:00:00.000Z"),
        ),
      Error,
      "medical_scan_retention_update_failed:update_failed",
    );
  });
});

Deno.test("enforceMedicalScanPrivacyState clears cloud storage and local-only state", async () => {
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const ownedPath = `${authUserId}/scan/original.pdf`;
  const service = createMockPrivacyService({
    medicalScans: {
      data: [{
        id: "scan-1",
        original_image_url: ownedPath,
        image_url: null,
      }],
      error: null,
    },
  });

  await enforceMedicalScanPrivacyState(
    service as never,
    "user-1",
    authUserId,
    { forceLocalOnly: true, clearCloudBackup: true },
  );

  assertEquals(service.__calls.removedBatches, [[ownedPath]]);
  assertEquals(service.__calls.updatePatches[0], {
    image_url: null,
    original_image_url: null,
    image_uploaded_at: null,
    store_original_in_cloud: false,
    scheduled_deletion_at: null,
    storage_mode: "local_only",
  });

  const noopService = createMockPrivacyService();
  await enforceMedicalScanPrivacyState(
    noopService as never,
    "user-1",
    authUserId,
    { forceLocalOnly: false, clearCloudBackup: false },
  );
  assertEquals(noopService.__calls.updatePatches.length, 0);
});

Deno.test("enforceMedicalScanPrivacyState clears cloud backup without forcing storage_mode and surfaces failures", async (t) => {
  const authUserId = "22222222-2222-4222-8222-222222222222";

  await t.step("clear cloud backup keeps storage mode unchanged", async () => {
    const service = createMockPrivacyService({
      medicalScans: {
        data: [{
          id: "scan-1",
          original_image_url:
            `https://example.supabase.co/storage/v1/object/sign/medical-scans/${authUserId}/scan/original.pdf?token=abc`,
          image_url: `/${authUserId}/scan/preview.jpg/`,
        }],
        error: null,
      },
    });

    await enforceMedicalScanPrivacyState(
      service as never,
      "user-1",
      authUserId,
      { forceLocalOnly: false, clearCloudBackup: true },
    );

    assertEquals(service.__calls.removedBatches, [[
      `${authUserId}/scan/original.pdf`,
      `${authUserId}/scan/preview.jpg`,
    ]]);
    assertEquals(service.__calls.updatePatches[0], {
      image_url: null,
      original_image_url: null,
      image_uploaded_at: null,
      store_original_in_cloud: false,
      scheduled_deletion_at: null,
    });
  });

  await t.step("medical scan privacy lookup failure", async () => {
    await assertRejects(
      () =>
        enforceMedicalScanPrivacyState(
          createMockPrivacyService({
            medicalScans: {
              data: null,
              error: { message: "lookup_down" },
            },
          }) as never,
          "user-1",
          authUserId,
          { forceLocalOnly: true, clearCloudBackup: true },
        ),
      Error,
      "medical_scan_privacy_lookup_failed:lookup_down",
    );
  });

  await t.step("medical scan privacy update failure", async () => {
    await assertRejects(
      () =>
        enforceMedicalScanPrivacyState(
          createMockPrivacyService({
            medicalScans: {
              data: [{
                id: "scan-1",
                original_image_url: `${authUserId}/scan/original.pdf`,
                image_url: null,
              }],
              error: null,
            },
            updateError: { message: "update_down" },
          }) as never,
          "user-1",
          authUserId,
          { forceLocalOnly: true, clearCloudBackup: true },
        ),
      Error,
      "medical_scan_privacy_update_failed:update_down",
    );
  });
});

Deno.test("enforceMedicalScanPrivacyState skips deletion when no owned storage paths remain", async () => {
  const authUserId = "22222222-2222-4222-8222-222222222222";
  const service = createMockPrivacyService({
    medicalScans: {
      data: [{
        id: "scan-1",
        original_image_url:
          "https://project.supabase.co/storage/v1/object/public/medical-scans/other-user/scan/original.jpg",
        image_url: "medical-scans/.",
      }],
      error: null,
    },
  });

  await enforceMedicalScanPrivacyState(
    service as never,
    "user-1",
    authUserId,
    { forceLocalOnly: true, clearCloudBackup: true },
  );

  assertEquals(service.__calls.removedBatches, []);
  assertEquals(service.__calls.verifiedBatches, []);
  assertEquals(service.__calls.updatePatches[0]?.storage_mode, "local_only");
});
