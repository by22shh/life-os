import { handleCors } from "../../../_shared/cors.ts";
import {
  jsonWithRequest,
  serviceRoleClient,
  validateInternalServiceRoleRequest,
} from "../../../_shared/supabase.ts";
import {
  cleanupMedicalScanStorage,
  deleteAuthPrincipalWithRetry,
  deletePostgresData,
  DELETION_JOB_SELECT,
  type DeletionFailureType,
  deletionJobCascadeDeletedAfterUserRemoval,
  type DeletionJobRow,
  recordFailure,
  updateDeletionJobState,
  upsertDeletionAudit,
  type UserRow,
  verifyVectorDeletion,
} from "../../../_shared/account_deletion.ts";

const DEFAULT_BATCH_SIZE = 25;
const MAX_BATCH_SIZE = 25;
const MAX_SCHEDULED_RETRY_ATTEMPTS = 5;
const WORKER_INVOCATION_HEADER = "X-Account-Deletion-Worker";
const WORKER_INVOCATION_VALUE = "scheduled";

interface WorkerBody {
  batch_size?: number;
}

interface DueDeletionJobResult {
  job_id: string;
  status: "completed" | "failed" | "retry_scheduled" | "skipped";
  detail: string | null;
  attempt_count: number;
}

interface ScheduledDeletionContext {
  reason: string;
  authUserId: string | null;
  user: UserRow | null;
}

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const internalAuth = validateInternalServiceRoleRequest(request, {
    invocationHeaderName: WORKER_INVOCATION_HEADER,
    invocationHeaderValue: WORKER_INVOCATION_VALUE,
  });
  if (!internalAuth.ok) {
    return jsonWithRequest(
      request,
      { error: internalAuth.error },
      internalAuth.status,
    );
  }

  let body: WorkerBody = {};
  try {
    body = await request.json();
  } catch {
    // optional body
  }

  const batchSize = clampBatchSize(body.batch_size);
  const service = serviceRoleClient();

  try {
    const jobs = await fetchDueScheduledDeletionJobs(service, batchSize);
    const results: DueDeletionJobResult[] = [];
    for (const job of jobs) {
      results.push(await processDueScheduledDeletionJob(service, job));
    }

    return jsonWithRequest(request, {
      processed: results.length,
      results,
    });
  } catch (error) {
    // Log the full detail internally; the response stays opaque per the
    // sanitized-error policy shared by all endpoints.
    console.error(
      JSON.stringify({
        event: "scheduled_deletion_worker_failed",
        detail: error instanceof Error ? error.message : String(error),
      }),
    );
    return jsonWithRequest(request, {
      error: "scheduled_deletion_worker_failed",
    }, 500);
  }
});

async function fetchDueScheduledDeletionJobs(
  service: ReturnType<typeof serviceRoleClient>,
  batchSize: number,
): Promise<DeletionJobRow[]> {
  const nowIso = new Date().toISOString();

  const { data: scheduledJobs, error: scheduledError } = await service
    .from("account_deletion_jobs")
    .select(DELETION_JOB_SELECT)
    .eq("mode", "scheduled")
    .eq("state", "scheduled")
    .lte("scheduled_for", nowIso)
    .order("scheduled_for", { ascending: true })
    .limit(batchSize)
    .returns<DeletionJobRow[]>();
  if (scheduledError) {
    throw new Error(`scheduled_job_fetch_failed:${scheduledError.message}`);
  }

  const remaining = Math.max(0, batchSize - (scheduledJobs?.length ?? 0));
  if (remaining === 0) {
    return scheduledJobs ?? [];
  }

  const { data: retryJobs, error: retryError } = await service
    .from("account_deletion_jobs")
    .select(DELETION_JOB_SELECT)
    .eq("mode", "scheduled")
    .eq("state", "retry_scheduled")
    .lte("next_retry_at", nowIso)
    .order("next_retry_at", { ascending: true })
    .limit(remaining)
    .returns<DeletionJobRow[]>();
  if (retryError) {
    throw new Error(`scheduled_retry_job_fetch_failed:${retryError.message}`);
  }

  return [...(scheduledJobs ?? []), ...(retryJobs ?? [])];
}

async function processDueScheduledDeletionJob(
  service: ReturnType<typeof serviceRoleClient>,
  job: DeletionJobRow,
): Promise<DueDeletionJobResult> {
  const context = await loadScheduledDeletionContext(service, job);
  const reason = context.reason;

  if (!context.authUserId) {
    return await handleScheduledFailure(
      service,
      job,
      reason,
      {
        failureType: "auth",
        error: "scheduled_deletion_auth_user_missing",
        storageDeleted: job.storage_cleanup_completed,
        postgresDeleted: false,
        vectorsDeleted: false,
        authDeleted: false,
      },
      context.user != null,
      false,
    );
  }

  try {
    job = await updateDeletionJobState(service, job, "data_deleting", {
      attempt_count: Math.max(0, job.attempt_count) + 1,
      auth_user_id: context.authUserId,
      reason,
      next_retry_at: null,
      last_error: null,
      last_failure_type: null,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    if (detail.startsWith("deletion_job_state_conflict:")) {
      return {
        job_id: job.id,
        status: "skipped",
        detail: "state_conflict",
        attempt_count: job.attempt_count,
      };
    }
    throw error;
  }

  if (context.user) {
    await service
      .from("users")
      .update({
        deletion_in_progress: true,
        deletion_reason: reason,
      })
      .eq("id", context.user.id);
  }

  const effectiveUser: UserRow = context.user ?? {
    id: job.user_id,
    auth_id: context.authUserId,
  };

  const storageDelete = await cleanupMedicalScanStorage(
    service,
    effectiveUser,
    job,
  );
  job = storageDelete.job;
  if (!storageDelete.ok) {
    return await handleScheduledFailure(
      service,
      job,
      reason,
      {
        failureType: storageDelete.failureType!,
        error: storageDelete.error!,
        storageDeleted: false,
        postgresDeleted: false,
        vectorsDeleted: false,
        authDeleted: false,
      },
      context.user != null,
    );
  }

  const postgresDelete = await deletePostgresData(service, effectiveUser.id);
  if (!postgresDelete.ok) {
    return await handleScheduledFailure(
      service,
      job,
      reason,
      {
        failureType: postgresDelete.failureType!,
        error: postgresDelete.error!,
        storageDeleted: true,
        postgresDeleted: false,
        vectorsDeleted: false,
        authDeleted: false,
      },
      context.user != null,
    );
  }

  const vectorsDelete = await verifyVectorDeletion(service, effectiveUser.id);
  if (!vectorsDelete.ok) {
    return await handleScheduledFailure(
      service,
      job,
      reason,
      {
        failureType: vectorsDelete.failureType!,
        error: vectorsDelete.error!,
        storageDeleted: true,
        postgresDeleted: true,
        vectorsDeleted: false,
        authDeleted: false,
      },
      false,
    );
  }

  const authDelete = await deleteAuthPrincipalWithRetry(
    service,
    context.authUserId,
  );
  if (!authDelete.ok) {
    return await handleScheduledFailure(
      service,
      job,
      reason,
      {
        failureType: authDelete.failureType!,
        error: authDelete.error!,
        storageDeleted: true,
        postgresDeleted: true,
        vectorsDeleted: true,
        authDeleted: false,
      },
      false,
    );
  }

  const auditLogId = job.audit_log_id ?? crypto.randomUUID();
  const auditError = await upsertDeletionAudit(service, {
    id: auditLogId,
    userId: effectiveUser.id,
    storageDeleted: true,
    vectorsDeleted: true,
    postgresDeleted: true,
    authDeleted: true,
    notes: null,
  });
  if (auditError) {
    return await handleScheduledFailure(
      service,
      job,
      reason,
      {
        failureType: "postgres",
        error: `scheduled_deletion_audit_failed:${auditError}`,
        storageDeleted: true,
        postgresDeleted: true,
        vectorsDeleted: true,
        authDeleted: true,
      },
      false,
    );
  }

  try {
    job = await updateDeletionJobState(service, job, "completed", {
      reason,
      audit_log_id: auditLogId,
      next_retry_at: null,
      last_error: null,
      last_failure_type: null,
    });
  } catch (error) {
    const cascadedAway = await deletionJobCascadeDeletedAfterUserRemoval(
      service,
      effectiveUser.id,
      auditLogId,
      error,
    );
    if (!cascadedAway) {
      throw error;
    }
  }

  return {
    job_id: job.id,
    status: "completed",
    detail: null,
    attempt_count: job.attempt_count,
  };
}

async function loadScheduledDeletionContext(
  service: ReturnType<typeof serviceRoleClient>,
  job: DeletionJobRow,
): Promise<ScheduledDeletionContext> {
  const { data: userRow, error } = await service
    .from("users")
    .select("id,auth_id,deletion_reason")
    .eq("id", job.user_id)
    .maybeSingle<{
      id: string;
      auth_id: string;
      deletion_reason: string | null;
    }>();
  if (error) {
    throw new Error(`scheduled_deletion_user_lookup_failed:${error.message}`);
  }

  const user = userRow
    ? {
      id: userRow.id,
      auth_id: userRow.auth_id,
    }
    : null;
  const authUserId = job.auth_user_id ?? userRow?.auth_id ?? null;
  const reason = job.reason ?? userRow?.deletion_reason ?? "user_requested";

  return {
    reason,
    authUserId,
    user,
  };
}

async function handleScheduledFailure(
  service: ReturnType<typeof serviceRoleClient>,
  job: DeletionJobRow,
  reason: string,
  options: {
    failureType: DeletionFailureType;
    error: string;
    storageDeleted: boolean;
    postgresDeleted: boolean;
    vectorsDeleted: boolean;
    authDeleted: boolean;
  },
  userExists: boolean,
  retryAllowed = true,
): Promise<DueDeletionJobResult> {
  await recordFailure(service, job.user_id, options.failureType, options.error);

  if (retryAllowed && job.attempt_count < MAX_SCHEDULED_RETRY_ATTEMPTS) {
    const retryDelay = scheduledRetryDelaySeconds(job.attempt_count);
    const nextRetryAt = new Date(Date.now() + retryDelay * 1000).toISOString();

    job = await updateDeletionJobState(service, job, "retry_scheduled", {
      reason,
      next_retry_at: nextRetryAt,
      last_error: options.error,
      last_failure_type: options.failureType,
    });

    if (userExists) {
      await service
        .from("users")
        .update({
          deletion_in_progress: false,
          deletion_reason: reason,
          deletion_scheduled_at: nextRetryAt,
        })
        .eq("id", job.user_id);
    }

    return {
      job_id: job.id,
      status: "retry_scheduled",
      detail: options.error,
      attempt_count: job.attempt_count,
    };
  }

  const auditLogId = job.audit_log_id ?? crypto.randomUUID();
  const auditError = await upsertDeletionAudit(service, {
    id: auditLogId,
    userId: job.user_id,
    storageDeleted: options.storageDeleted,
    vectorsDeleted: options.vectorsDeleted,
    postgresDeleted: options.postgresDeleted,
    authDeleted: options.authDeleted,
    notes: options.error,
  });

  const failedPatch: Record<string, unknown> = {
    reason,
    next_retry_at: null,
    last_error: options.error,
    last_failure_type: options.failureType,
  };
  if (!auditError) {
    failedPatch.audit_log_id = auditLogId;
  }

  try {
    job = await updateDeletionJobState(service, job, "failed", failedPatch);
  } catch (error) {
    const cascadedAway = await deletionJobCascadeDeletedAfterUserRemoval(
      service,
      job.user_id,
      auditLogId,
      error,
    );
    if (!cascadedAway) {
      throw error;
    }
  }

  if (userExists) {
    await service
      .from("users")
      .update({
        deletion_in_progress: false,
        deletion_reason: reason,
        deletion_scheduled_at: null,
      })
      .eq("id", job.user_id);
  }

  return {
    job_id: job.id,
    status: "failed",
    detail: auditError
      ? `scheduled_deletion_audit_failed:${auditError}`
      : options.error,
    attempt_count: job.attempt_count,
  };
}

function clampBatchSize(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_BATCH_SIZE;
  }

  return Math.min(
    MAX_BATCH_SIZE,
    Math.max(1, Math.trunc(value)),
  );
}

function scheduledRetryDelaySeconds(attemptCount: number): number {
  const safeAttempt = Math.max(1, attemptCount);
  const backoff = 300 * Math.pow(2, safeAttempt - 1);
  return Math.min(21600, Math.max(300, Math.round(backoff)));
}
