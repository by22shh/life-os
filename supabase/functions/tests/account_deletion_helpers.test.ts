import {
  assertEquals,
  assertMatch,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  cascadedFailureState,
  cleanupMedicalScanStorage,
  deleteAuthPrincipalWithRetry,
  deletePostgresData,
  deletionJobCascadeDeletedAfterUserRemoval,
  type DeletionJobRow,
  ensureDeletionJobStorageManifest,
  fetchDeletionJobByKey,
  getOrCreateDeletionJob,
  isDeletionJobStateConflict,
  isUniqueViolation,
  normalizeIdempotencyKey,
  recordFailure,
  retryAfterSeconds,
  updateDeletionJob,
  updateDeletionJobState,
  upsertDeletionAudit,
  type UserRow,
  verifyVectorDeletion,
} from "../_shared/account_deletion.ts";

function makeUser(): UserRow {
  return {
    id: "11111111-1111-4111-8111-111111111111",
    auth_id: "22222222-2222-4222-8222-222222222222",
  };
}

function makeJob(overrides: Partial<DeletionJobRow> = {}): DeletionJobRow {
  return {
    id: "33333333-3333-4333-8333-333333333333",
    user_id: "11111111-1111-4111-8111-111111111111",
    auth_user_id: "22222222-2222-4222-8222-222222222222",
    idempotency_key: "delete-account-1",
    mode: "immediate",
    state: "requested",
    reason: "user_requested",
    attempt_count: 0,
    next_retry_at: null,
    last_error: null,
    last_failure_type: null,
    scheduled_for: null,
    audit_log_id: null,
    storage_object_paths: [],
    storage_cleanup_completed: false,
    storage_cleanup_completed_at: null,
    processing_started_at: null,
    created_at: "2026-03-15T00:00:00.000Z",
    updated_at: "2026-03-15T00:00:00.000Z",
    ...overrides,
  };
}

interface MockServiceConfig {
  rpcResult?: { data: unknown; error: { message: string } | null };
  usersMaybeSingle?: {
    data: { id: string } | null;
    error: { message: string } | null;
  };
  auditMaybeSingle?: {
    data: { id: string } | null;
    error: { message: string } | null;
  };
  medicalScansResult?: {
    data:
      | Array<{ image_url: string | null; original_image_url: string | null }>
      | null;
    error: { message: string } | null;
  };
  vectorMemoryResult?: {
    count: number | null;
    error: { message: string } | null;
  };
  jobUpdateResult?: {
    data: DeletionJobRow | null;
    error: { message: string } | null;
  };
  jobLookupResults?: Array<{
    data: DeletionJobRow | null;
    error: { message: string } | null;
  }>;
  jobInsertResult?: {
    data: DeletionJobRow | null;
    error: ({ message: string; code?: string }) | null;
  };
  failureInsertResult?: { error: { message: string } | null };
  auditUpsertResult?: { error: { message: string } | null };
  authDeleteResults?: Array<{
    error: ({ message?: string; status?: number }) | null;
  }>;
  storageRemoveResult?: { error: { message: string } | null };
  storageObjectsResult?: {
    data: Array<{ name: string | null }> | null;
    error: { message: string } | null;
  };
}

function createMockService(config: MockServiceConfig = {}) {
  const calls = {
    authDeletes: [] as string[],
    inserts: [] as Array<{ table: string; payload: unknown }>,
    upserts: [] as Array<{
      table: string;
      payload: unknown;
      options: unknown;
    }>,
    jobPatches: [] as Array<Record<string, unknown>>,
    removedBatches: [] as string[][],
    verifiedBatches: [] as string[][],
  };
  let jobLookupIndex = 0;
  let authDeleteIndex = 0;

  const buildQuery = (table: string) => ({
    select: (_columns: string, _options?: unknown) => buildQuery(table),
    insert: (payload: unknown) => {
      calls.inserts.push({ table, payload });
      if (table === "deletion_failures") {
        return Promise.resolve(
          config.failureInsertResult ?? { error: null },
        );
      }
      return buildQuery(`${table}:insert`);
    },
    upsert: (payload: unknown, options: unknown) => {
      calls.upserts.push({ table, payload, options });
      return Promise.resolve(config.auditUpsertResult ?? { error: null });
    },
    update: (patch: Record<string, unknown>) => {
      calls.jobPatches.push(patch);
      return buildQuery("account_deletion_jobs:update");
    },
    eq: (column: string, value: unknown) => {
      void column;
      void value;

      if (table === "medical_scans") {
        return Promise.resolve(
          config.medicalScansResult ?? {
            data: [],
            error: null,
          },
        );
      }

      if (table === "vector_memory") {
        return Promise.resolve(
          config.vectorMemoryResult ?? {
            count: 0,
            error: null,
          },
        );
      }

      return buildQuery(table);
    },
    in: (_column: string, values: string[]) => {
      calls.verifiedBatches.push(values);
      return Promise.resolve(
        config.storageObjectsResult ?? {
          data: [],
          error: null,
        },
      );
    },
    maybeSingle: () => {
      if (table === "users") {
        return Promise.resolve(
          config.usersMaybeSingle ?? {
            data: null,
            error: null,
          },
        );
      }

      if (table === "deletion_audit_log") {
        return Promise.resolve(
          config.auditMaybeSingle ?? {
            data: null,
            error: null,
          },
        );
      }

      if (table === "account_deletion_jobs") {
        const queued = config.jobLookupResults?.[jobLookupIndex++];
        return Promise.resolve(
          queued ?? {
            data: null,
            error: null,
          },
        );
      }

      if (table === "account_deletion_jobs:update") {
        return Promise.resolve(
          config.jobUpdateResult ?? {
            data: null,
            error: { message: "missing_job_update_result" },
          },
        );
      }

      return Promise.resolve({
        data: null,
        error: { message: `unsupported maybeSingle table: ${table}` },
      });
    },
    single: () => {
      if (table === "account_deletion_jobs:insert") {
        return Promise.resolve(
          config.jobInsertResult ?? {
            data: makeJob(),
            error: null,
          },
        );
      }

      return Promise.resolve({
        data: null,
        error: { message: `unsupported single table: ${table}` },
      });
    },
  });

  return {
    rpc: (_fn: string, _args: Record<string, unknown>) =>
      Promise.resolve(config.rpcResult ?? { data: true, error: null }),
    from: (table: string) => buildQuery(table),
    schema: (_schema: string) => ({
      from: (table: string) => buildQuery(`storage.${table}`),
    }),
    storage: {
      from: (_bucket: string) => ({
        list: () => Promise.resolve({ data: [], error: null }),
        remove: (paths: string[]) => {
          calls.removedBatches.push(paths);
          return Promise.resolve(config.storageRemoveResult ?? { error: null });
        },
      }),
    },
    auth: {
      admin: {
        deleteUser: (authUserId: string) => {
          calls.authDeletes.push(authUserId);
          const queued = config.authDeleteResults?.[authDeleteIndex++];
          return Promise.resolve(queued ?? { error: null });
        },
      },
    },
    __calls: calls,
  };
}

Deno.test("deleteAuthPrincipalWithRetry treats success and missing principals as complete", async () => {
  const service = createMockService();
  assertEquals(
    await deleteAuthPrincipalWithRetry(service as never, "auth-1"),
    { ok: true },
  );
  assertEquals(service.__calls.authDeletes, ["auth-1"]);

  const missingByStatus = createMockService({
    authDeleteResults: [{ error: { message: "missing", status: 404 } }],
  });
  assertEquals(
    await deleteAuthPrincipalWithRetry(missingByStatus as never, "auth-2"),
    { ok: true },
  );

  const missingByMessage = createMockService({
    authDeleteResults: [{ error: { message: "User not found" } }],
  });
  assertEquals(
    await deleteAuthPrincipalWithRetry(missingByMessage as never, "auth-3"),
    { ok: true },
  );
});

Deno.test("deleteAuthPrincipalWithRetry retries transient auth failures", async () => {
  const service = createMockService({
    authDeleteResults: [
      { error: { message: "temporary outage" } },
      { error: { message: "still down" } },
      { error: { message: "final failure" } },
    ],
  });

  assertEquals(
    await deleteAuthPrincipalWithRetry(service as never, "auth-1"),
    {
      ok: false,
      failureType: "auth",
      error: "final failure",
    },
  );
  assertEquals(service.__calls.authDeletes, ["auth-1", "auth-1", "auth-1"]);
});

Deno.test("account deletion helpers normalize retry and failure metadata", () => {
  const originalNow = Date.now;
  Date.now = () => Date.parse("2026-03-15T10:00:00.000Z");

  try {
    assertEquals(normalizeIdempotencyKey(null), null);
    assertEquals(
      normalizeIdempotencyKey("  delete.account:1  "),
      "delete.account:1",
    );
    assertEquals(normalizeIdempotencyKey(""), null);
    assertEquals(normalizeIdempotencyKey("   "), null);
    assertEquals(normalizeIdempotencyKey("has spaces"), null);
    assertEquals(normalizeIdempotencyKey("x".repeat(129)), null);
    assertEquals(cascadedFailureState("requested"), "failed");
    assertEquals(cascadedFailureState("failed"), "failed");
    assertEquals(
      isDeletionJobStateConflict(
        new Error("deletion_job_state_conflict:job-1:requested->failed"),
      ),
      true,
    );
    assertEquals(
      isDeletionJobStateConflict(new Error("different_error")),
      false,
    );
    assertEquals(
      isDeletionJobStateConflict("deletion_job_state_conflict:job-1"),
      true,
    );
    assertEquals(isUniqueViolation({ code: "23505" }), true);
    assertEquals(isUniqueViolation({ code: "22001" }), false);
    assertEquals(retryAfterSeconds(null), 0);
    assertEquals(retryAfterSeconds("2026-03-15T10:00:03.100Z"), 4);
    assertEquals(retryAfterSeconds("2026-03-15T09:59:59.000Z"), 0);
    assertEquals(retryAfterSeconds("not-a-date"), 0);
  } finally {
    Date.now = originalNow;
  }
});

Deno.test("recordFailure and upsertDeletionAudit persist compliance metadata", async () => {
  const service = createMockService();

  await recordFailure(service as never, "user-1", "storage", "remove_failed");
  assertEquals(service.__calls.inserts.length, 1);
  assertEquals(service.__calls.inserts[0].table, "deletion_failures");
  assertEquals(service.__calls.inserts[0].payload, {
    user_id: "user-1",
    failure_type: "storage",
    error: "remove_failed",
    resolved: false,
    created_at: String(
      (service.__calls.inserts[0].payload as Record<string, unknown>)
        .created_at,
    ),
  });

  const auditError = await upsertDeletionAudit(service as never, {
    id: "audit-1",
    userId: "user-1",
    vectorsDeleted: true,
    postgresDeleted: true,
    authDeleted: false,
    storageDeleted: true,
    notes: "auth pending",
  });

  assertEquals(auditError, null);
  assertEquals(service.__calls.upserts.length, 1);
  const auditPayload = service.__calls.upserts[0].payload as Record<
    string,
    unknown
  >;
  assertEquals(auditPayload.user_id_deleted, "user-1");
  assertEquals(auditPayload.compliance_verified, false);
  assertEquals(auditPayload.notes, "auth pending");

  const failingAudit = createMockService({
    auditUpsertResult: { error: { message: "audit_down" } },
  });
  assertEquals(
    await upsertDeletionAudit(failingAudit as never, {
      id: "audit-2",
      userId: "user-1",
      vectorsDeleted: true,
      postgresDeleted: true,
      authDeleted: true,
      storageDeleted: true,
      notes: null,
    }),
    "audit_down",
  );
});

Deno.test("deletePostgresData handles rpc success, verification, and remaining users", async () => {
  const rpcOk = createMockService({
    rpcResult: { data: true, error: null },
  });
  assertEquals(
    await deletePostgresData(rpcOk as never, "user-1"),
    { ok: true },
  );

  const verifyMissingUser = createMockService({
    rpcResult: { data: false, error: null },
    usersMaybeSingle: { data: null, error: null },
  });
  assertEquals(
    await deletePostgresData(verifyMissingUser as never, "user-1"),
    { ok: true },
  );

  const userStillPresent = createMockService({
    rpcResult: { data: false, error: null },
    usersMaybeSingle: { data: { id: "user-1" }, error: null },
  });
  assertEquals(
    await deletePostgresData(userStillPresent as never, "user-1"),
    {
      ok: false,
      failureType: "postgres",
      error: "delete_user_account returned false",
    },
  );
});

Deno.test("deletePostgresData surfaces rpc and verification errors", async () => {
  const rpcError = createMockService({
    rpcResult: { data: null, error: { message: "rpc_failed" } },
  });
  assertEquals(
    await deletePostgresData(rpcError as never, "user-1"),
    {
      ok: false,
      failureType: "postgres",
      error: "rpc_failed",
    },
  );

  const verifyError = createMockService({
    rpcResult: { data: false, error: null },
    usersMaybeSingle: { data: null, error: { message: "verify_failed" } },
  });
  assertEquals(
    await deletePostgresData(verifyError as never, "user-1"),
    {
      ok: false,
      failureType: "postgres",
      error: "delete_user_account_verify_failed: verify_failed",
    },
  );
});

Deno.test("fetch and getOrCreate deletion job cover existing, insert, and unique-race paths", async () => {
  const existing = makeJob({
    auth_user_id: null,
    storage_object_paths: ["", "scan.pdf"] as never,
    storage_cleanup_completed: null as never,
  });
  const existingService = createMockService({
    jobLookupResults: [{ data: existing, error: null }],
  });

  const fetched = await fetchDeletionJobByKey(
    existingService as never,
    existing.user_id,
    existing.idempotency_key,
  );
  assertEquals(fetched?.auth_user_id, null);
  assertEquals(fetched?.storage_object_paths, ["scan.pdf"]);
  assertEquals(fetched?.storage_cleanup_completed, false);
  const getExistingService = createMockService({
    jobLookupResults: [{ data: existing, error: null }],
  });
  assertEquals(
    (await getOrCreateDeletionJob(getExistingService as never, {
      userId: existing.user_id,
      authUserId: existing.auth_user_id ?? "auth-1",
      idempotencyKey: existing.idempotency_key,
      mode: "immediate",
      reason: "user_requested",
      scheduledFor: null,
    })).id,
    existing.id,
  );

  const malformedManifest = makeJob({
    id: "malformed-manifest-job",
    storage_object_paths: null as never,
  });
  const malformedManifestService = createMockService({
    jobLookupResults: [{ data: malformedManifest, error: null }],
  });
  assertEquals(
    (await fetchDeletionJobByKey(
      malformedManifestService as never,
      malformedManifest.user_id,
      malformedManifest.idempotency_key,
    ))?.storage_object_paths,
    [],
  );

  const inserted = makeJob({ id: "inserted-job" });
  const insertService = createMockService({
    jobLookupResults: [{ data: null, error: null }],
    jobInsertResult: { data: inserted, error: null },
  });
  assertEquals(
    await getOrCreateDeletionJob(insertService as never, {
      userId: inserted.user_id,
      authUserId: inserted.auth_user_id ?? "auth-1",
      idempotencyKey: inserted.idempotency_key,
      mode: "immediate",
      reason: "user_requested",
      scheduledFor: null,
    }),
    inserted,
  );
  assertEquals(insertService.__calls.inserts.length, 1);

  const raced = makeJob({ id: "raced-job" });
  const racedService = createMockService({
    jobLookupResults: [
      { data: null, error: null },
      { data: raced, error: null },
    ],
    jobInsertResult: {
      data: null,
      error: { message: "duplicate", code: "23505" },
    },
  });
  assertEquals(
    (await getOrCreateDeletionJob(racedService as never, {
      userId: raced.user_id,
      authUserId: raced.auth_user_id ?? "auth-1",
      idempotencyKey: raced.idempotency_key,
      mode: "immediate",
      reason: "user_requested",
      scheduledFor: null,
    })).id,
    "raced-job",
  );

  const duplicateWithoutRace = createMockService({
    jobLookupResults: [
      { data: null, error: null },
      { data: null, error: null },
    ],
    jobInsertResult: {
      data: null,
      error: { message: "duplicate still missing", code: "23505" },
    },
  });
  await assertRejects(
    () =>
      getOrCreateDeletionJob(duplicateWithoutRace as never, {
        userId: raced.user_id,
        authUserId: raced.auth_user_id ?? "auth-1",
        idempotencyKey: raced.idempotency_key,
        mode: "immediate",
        reason: "user_requested",
        scheduledFor: null,
      }),
    Error,
    "duplicate still missing",
  );

  const insertFailure = createMockService({
    jobLookupResults: [{ data: null, error: null }],
    jobInsertResult: {
      data: null,
      error: { message: "insert_failed", code: "22001" },
    },
  });
  await assertRejects(
    () =>
      getOrCreateDeletionJob(insertFailure as never, {
        userId: raced.user_id,
        authUserId: raced.auth_user_id ?? "auth-1",
        idempotencyKey: raced.idempotency_key,
        mode: "immediate",
        reason: "user_requested",
        scheduledFor: null,
      }),
    Error,
    "insert_failed",
  );

  const failingLookup = createMockService({
    jobLookupResults: [{ data: null, error: { message: "lookup_failed" } }],
  });
  await assertRejects(
    () =>
      fetchDeletionJobByKey(
        failingLookup as never,
        "user-1",
        "delete-account-1",
      ),
    Error,
    "lookup_failed",
  );
});

Deno.test("updateDeletionJob helpers normalize rows and report conflicts", async () => {
  const current = makeJob();
  const completed = makeJob({
    state: "data_deleting",
    auth_user_id: null,
    storage_cleanup_completed: null as never,
    storage_cleanup_completed_at: undefined as never,
  });
  const service = createMockService({
    jobUpdateResult: { data: completed, error: null },
  });

  const stateUpdated = await updateDeletionJobState(
    service as never,
    current,
    "data_deleting",
    { storage_cleanup_completed: true },
  );
  assertEquals(stateUpdated.auth_user_id, null);
  assertEquals(stateUpdated.storage_cleanup_completed, false);
  assertEquals(stateUpdated.storage_cleanup_completed_at, null);
  assertEquals(service.__calls.jobPatches[0].state, "data_deleting");

  const patched = await updateDeletionJob(service as never, current, {
    last_error: "retry later",
  });
  assertEquals(patched.id, completed.id);

  const conflict = createMockService({
    jobUpdateResult: { data: null, error: null },
  });
  await assertRejects(
    () =>
      updateDeletionJobState(
        conflict as never,
        current,
        "data_deleting",
        {},
      ),
    Error,
    `deletion_job_state_conflict:${current.id}:requested->data_deleting`,
  );

  await assertRejects(
    () => updateDeletionJob(conflict as never, current, {}),
    Error,
    `deletion_job_not_found:${current.id}`,
  );

  const updateError = createMockService({
    jobUpdateResult: { data: null, error: { message: "update_failed" } },
  });
  await assertRejects(
    () =>
      updateDeletionJobState(
        updateError as never,
        current,
        "data_deleting",
        {},
      ),
    Error,
    "update_failed",
  );
  await assertRejects(
    () => updateDeletionJob(updateError as never, current, {}),
    Error,
    "update_failed",
  );
});

Deno.test("verifyVectorDeletion reports remaining vectors and backend errors", async () => {
  const ok = createMockService({
    vectorMemoryResult: { count: 0, error: null },
  });
  assertEquals(
    await verifyVectorDeletion(ok as never, "user-1"),
    { ok: true },
  );

  const unknownCount = createMockService({
    vectorMemoryResult: { count: null, error: null },
  });
  assertEquals(
    await verifyVectorDeletion(unknownCount as never, "user-1"),
    { ok: true },
  );

  const remaining = createMockService({
    vectorMemoryResult: { count: 2, error: null },
  });
  assertEquals(
    await verifyVectorDeletion(remaining as never, "user-1"),
    {
      ok: false,
      failureType: "pinecone",
      error: "vector_records_remaining_after_delete",
    },
  );

  const errored = createMockService({
    vectorMemoryResult: { count: null, error: { message: "vector_down" } },
  });
  assertEquals(
    await verifyVectorDeletion(errored as never, "user-1"),
    {
      ok: false,
      failureType: "pinecone",
      error: "vector_verification_failed: vector_down",
    },
  );
});

Deno.test("deletionJobCascadeDeletedAfterUserRemoval only accepts true cascade cases", async () => {
  const cascaded = createMockService({
    usersMaybeSingle: { data: null, error: null },
    auditMaybeSingle: { data: { id: "audit-1" }, error: null },
  });
  assertEquals(
    await deletionJobCascadeDeletedAfterUserRemoval(
      cascaded as never,
      "user-1",
      "audit-1",
      new Error("deletion_job_state_conflict:job-1:requested->completed"),
    ),
    true,
  );

  const nonConflict = createMockService();
  assertEquals(
    await deletionJobCascadeDeletedAfterUserRemoval(
      nonConflict as never,
      "user-1",
      "audit-1",
      new Error("plain_error"),
    ),
    false,
  );

  const userStillPresent = createMockService({
    usersMaybeSingle: { data: { id: "user-1" }, error: null },
  });
  assertEquals(
    await deletionJobCascadeDeletedAfterUserRemoval(
      userStillPresent as never,
      "user-1",
      "audit-1",
      new Error("deletion_job_state_conflict:job-1:requested->completed"),
    ),
    false,
  );

  const auditMissing = createMockService({
    usersMaybeSingle: { data: null, error: null },
    auditMaybeSingle: { data: null, error: null },
  });
  assertEquals(
    await deletionJobCascadeDeletedAfterUserRemoval(
      auditMissing as never,
      "user-1",
      "audit-1",
      new Error("deletion_job_state_conflict:job-1:requested->completed"),
    ),
    false,
  );
});

Deno.test("ensureDeletionJobStorageManifest respects completed and already-normalized manifests", async () => {
  const user = makeUser();
  const completed = makeJob({ storage_cleanup_completed: true });
  const service = createMockService();

  assertEquals(
    await ensureDeletionJobStorageManifest(service as never, user, completed),
    completed,
  );

  const normalized = makeJob({
    storage_object_paths: [`${user.auth_id}/scan/original.pdf`],
  });
  assertEquals(
    await ensureDeletionJobStorageManifest(service as never, user, normalized),
    normalized,
  );
  assertEquals(service.__calls.jobPatches.length, 0);
});

Deno.test("ensureDeletionJobStorageManifest repairs dirty existing manifests", async () => {
  const user = makeUser();
  const repaired = makeJob({
    storage_object_paths: [`${user.auth_id}/scan/original.pdf`],
  });
  const service = createMockService({
    jobUpdateResult: { data: repaired, error: null },
  });

  const result = await ensureDeletionJobStorageManifest(
    service as never,
    user,
    makeJob({
      storage_object_paths: [
        `medical-scans/${user.auth_id}/scan/original.pdf`,
        "foreign/scan/original.pdf",
      ],
    }),
  );

  assertEquals(result.storage_object_paths, repaired.storage_object_paths);
  assertEquals(service.__calls.jobPatches[0].storage_object_paths, [
    `${user.auth_id}/scan/original.pdf`,
  ]);
});

Deno.test("ensureDeletionJobStorageManifest loads and saves normalized storage paths", async () => {
  const user = makeUser();
  const updatedJob = makeJob({
    storage_object_paths: [
      `${user.auth_id}/scan-1/original.pdf`,
      `${user.auth_id}/scan-2/preview.jpg`,
    ],
  });
  const service = createMockService({
    medicalScansResult: {
      data: [
        {
          original_image_url:
            `medical-scans/${user.auth_id}/scan-2/preview.jpg`,
          image_url:
            `https://example.supabase.co/storage/v1/object/sign/medical-scans/${user.auth_id}/scan-1/original.pdf?token=abc`,
        },
        {
          original_image_url:
            `https://example.com/not-storage/${user.auth_id}/foreign.pdf`,
          image_url: null,
        },
      ],
      error: null,
    },
    jobUpdateResult: { data: updatedJob, error: null },
  });

  const result = await ensureDeletionJobStorageManifest(
    service as never,
    user,
    makeJob({ storage_object_paths: [], auth_user_id: null }),
  );

  assertEquals(result.storage_object_paths, updatedJob.storage_object_paths);
  assertEquals(service.__calls.jobPatches.length, 1);
  assertEquals(service.__calls.jobPatches[0].auth_user_id, user.auth_id);
  assertEquals(service.__calls.jobPatches[0].storage_object_paths, [
    `${user.auth_id}/scan-1/original.pdf`,
    `${user.auth_id}/scan-2/preview.jpg`,
  ]);
});

Deno.test("ensureDeletionJobStorageManifest surfaces medical scan manifest lookup failures", async () => {
  const user = makeUser();
  const service = createMockService({
    medicalScansResult: {
      data: null,
      error: { message: "manifest_down" },
    },
  });

  await assertRejects(
    () =>
      ensureDeletionJobStorageManifest(
        service as never,
        user,
        makeJob({ storage_object_paths: [] }),
      ),
    Error,
    "medical_scans_manifest_failed:manifest_down",
  );
});

Deno.test("cleanupMedicalScanStorage deletes manifest objects and marks cleanup complete", async () => {
  const user = makeUser();
  const job = makeJob({
    storage_object_paths: [
      `${user.auth_id}/scan-1/original.pdf`,
      `${user.auth_id}/scan-2/preview.jpg`,
    ],
  });
  const service = createMockService({
    jobUpdateResult: {
      data: makeJob({
        storage_object_paths: job.storage_object_paths,
        storage_cleanup_completed: true,
        storage_cleanup_completed_at: "2026-03-15T10:00:00.000Z",
      }),
      error: null,
    },
    storageObjectsResult: { data: [], error: null },
  });

  const result = await cleanupMedicalScanStorage(
    service as never,
    user,
    job,
  );

  assertEquals(result.ok, true);
  assertEquals(result.job.storage_cleanup_completed, true);
  assertEquals(service.__calls.removedBatches, [job.storage_object_paths]);
  assertEquals(service.__calls.verifiedBatches, [job.storage_object_paths]);
  assertEquals(service.__calls.jobPatches.length, 1);
  assertEquals(service.__calls.jobPatches[0].storage_cleanup_completed, true);
  assertMatch(
    String(service.__calls.jobPatches[0].storage_cleanup_completed_at),
    /^\d{4}-\d{2}-\d{2}T/,
  );
});

Deno.test("cleanupMedicalScanStorage completes jobs with an empty manifest", async () => {
  const user = makeUser();
  const completedJob = makeJob({
    auth_user_id: user.auth_id,
    storage_object_paths: [],
    storage_cleanup_completed: true,
    storage_cleanup_completed_at: "2026-03-15T10:00:00.000Z",
  });
  const service = createMockService({
    medicalScansResult: { data: [], error: null },
    jobUpdateResult: { data: completedJob, error: null },
  });

  const result = await cleanupMedicalScanStorage(
    service as never,
    user,
    makeJob({ auth_user_id: null, storage_object_paths: [] }),
  );

  assertEquals(result.ok, true);
  assertEquals(result.job.storage_cleanup_completed, true);
  assertEquals(service.__calls.removedBatches, []);
  assertEquals(service.__calls.jobPatches[0].auth_user_id, user.auth_id);
  assertEquals(
    service.__calls.jobPatches.at(-1)?.storage_cleanup_completed,
    true,
  );
});

Deno.test("cleanupMedicalScanStorage short-circuits completed jobs and reports storage failures", async () => {
  const user = makeUser();
  const completed = makeJob({ storage_cleanup_completed: true });
  const completedService = createMockService();
  assertEquals(
    await cleanupMedicalScanStorage(completedService as never, user, completed),
    { ok: true, job: completed },
  );
  assertEquals(completedService.__calls.removedBatches.length, 0);

  const removeErrorService = createMockService({
    storageRemoveResult: { error: { message: "storage_down" } },
  });
  const removeResult = await cleanupMedicalScanStorage(
    removeErrorService as never,
    user,
    makeJob({ storage_object_paths: [`${user.auth_id}/scan/original.pdf`] }),
  );
  assertEquals(removeResult.ok, false);
  assertEquals(removeResult.failureType, "storage");
  assertEquals(
    removeResult.error,
    "medical_scan_storage_delete_failed:storage_down",
  );

  const verifyErrorService = createMockService({
    storageObjectsResult: { data: null, error: { message: "verify_down" } },
  });
  const verifyResult = await cleanupMedicalScanStorage(
    verifyErrorService as never,
    user,
    makeJob({ storage_object_paths: [`${user.auth_id}/scan/original.pdf`] }),
  );
  assertEquals(verifyResult.ok, false);
  assertEquals(verifyResult.failureType, "storage");
  assertEquals(
    verifyResult.error,
    "medical_scan_storage_verify_failed:verify_down",
  );
});

Deno.test("cleanupMedicalScanStorage reports remaining objects after verification", async () => {
  const user = makeUser();
  const job = makeJob({
    storage_object_paths: [`${user.auth_id}/scan-1/original.pdf`],
  });
  const service = createMockService({
    storageObjectsResult: {
      data: [{ name: `${user.auth_id}/scan-1/original.pdf` }],
      error: null,
    },
  });

  const result = await cleanupMedicalScanStorage(
    service as never,
    user,
    job,
  );

  assertEquals(result.ok, false);
  assertEquals(result.failureType, "storage");
  assertEquals(
    result.error,
    `medical_scan_storage_objects_remaining:${user.auth_id}/scan-1/original.pdf`,
  );
  assertEquals(service.__calls.jobPatches.length, 0);
});

Deno.test("account deletion verifies storage removal when PostgREST hides the storage schema", async () => {
  const user = makeUser();
  const job = makeJob({
    storage_object_paths: [`${user.auth_id}/scan/original.pdf`],
  });
  const service = createMockService({
    storageObjectsResult: {
      data: null,
      error: { message: "Invalid schema: storage" },
    },
    jobUpdateResult: {
      data: { ...job, storage_cleanup_completed: true },
      error: null,
    },
  });
  const result = await cleanupMedicalScanStorage(service as never, user, job);
  assertEquals(result.ok, true);
  assertEquals(result.job.storage_cleanup_completed, true);
  assertEquals(service.__calls.removedBatches, [job.storage_object_paths]);
});
