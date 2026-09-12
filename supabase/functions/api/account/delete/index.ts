import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { DeleteAccountBodySchema } from "../../../_shared/payload_schemas.ts";
import {
  type DeletionJobMode,
  deletionStateIsTerminal,
} from "../../../_shared/account_deletion_state_machine.ts";
import {
  canonicalAuthUserId,
  cascadedFailureState,
  cleanupMedicalScanStorage,
  deleteAuthPrincipalWithRetry,
  deletePostgresData,
  type DeletionFailureType,
  deletionJobCascadeDeletedAfterUserRemoval,
  type DeletionJobRow,
  getOrCreateDeletionJob,
  normalizeIdempotencyKey,
  recordFailure,
  retryAfterSeconds,
  updateDeletionJobState,
  upsertDeletionAudit,
  type UserRow,
  verifyVectorDeletion,
} from "../../../_shared/account_deletion.ts";
import { deleteUserVectorMemory } from "../../../_shared/vector_memory.ts";
import { issueDeletionReceipt } from "../../../_shared/deletion_receipt.ts";

interface DeletionBody {
  immediate?: boolean;
  reason?: string;
}

const MAX_IMMEDIATE_RETRY_ATTEMPTS = 3;
const RETRY_BASE_SECONDS = 30;
const RETRY_MAX_SECONDS = 10 * 60;

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const idempotencyKey = normalizeIdempotencyKey(
    request.headers.get("Idempotency-Key"),
  );
  if (!idempotencyKey) {
    return jsonWithRequest(request, {
      error: "invalid_or_missing_idempotency_key",
    }, 400);
  }

  const authenticated = await resolveAuthenticatedUser(request);
  if (!authenticated.ok) return authenticated.response;
  const authData = authenticated.data;

  let body: DeletionBody = {};
  try {
    const bodyRaw = await request.json();
    const bodyParse = parseWithSchema(DeleteAccountBodySchema, bodyRaw);
    if (!bodyParse.ok) {
      return jsonWithRequest(request, {
        error: "invalid_payload",
        issues: bodyParse.issues,
      }, 400);
    }
    // Normalize schema output (reason may be null) into DeletionBody.
    body = {
      immediate: bodyParse.output.immediate === true ? true : undefined,
      reason: bodyParse.output.reason ?? undefined,
    };
  } catch {
    // optional body
  }

  const immediate = body.immediate === true;
  const reason = body.reason ?? "user_requested";
  const mode: DeletionJobMode = immediate ? "immediate" : "scheduled";

  const service = serviceRoleClient();
  const { data: user, error: userError } = await service
    .from("users")
    .select("id,auth_id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<UserRow>();

  if (userError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userError),
    }, 500);
  }
  if (!user) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(
    request,
    user.id,
    "delete_account",
  );
  if (rateLimited) {
    return rateLimited;
  }

  const scheduledFor = mode === "scheduled"
    ? new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
    : null;

  let job: DeletionJobRow;
  try {
    job = await getOrCreateDeletionJob(service, {
      userId: user.id,
      authUserId: user.auth_id,
      idempotencyKey,
      mode,
      reason,
      scheduledFor,
    });
  } catch (error) {
    return jsonWithRequest(request, {
      error: "deletion_job_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  if (job.mode !== mode) {
    return jsonWithRequest(request, {
      error: "idempotency_key_mode_conflict",
      existing_mode: job.mode,
      requested_mode: mode,
    }, 409);
  }

  let receipt: Awaited<ReturnType<typeof issueDeletionReceipt>>;
  try {
    receipt = await issueDeletionReceipt(
      service,
      job,
      request.headers.get("X-Deletion-Receipt"),
    );
  } catch {
    return jsonWithRequest(
      request,
      { error: "deletion_receipt_issue_failed" },
      500,
    );
  }
  const attachReceipt = async (response: Response) => {
    const payload = await response.json();
    return jsonWithRequest(
      request,
      { ...payload, ...receipt },
      response.status,
    );
  };

  if (mode === "scheduled") {
    try {
      return await attachReceipt(
        await handleScheduledDeletion(
          service,
          user.id,
          reason,
          job,
          request,
        ),
      );
    } catch (error) {
      return await attachReceipt(deletionUnhandledFailure(
        request,
        "deletion_schedule_flow_failed",
        error,
      ));
    }
  }

  try {
    return await attachReceipt(
      await handleImmediateDeletion(service, user, reason, job, request),
    );
  } catch (error) {
    return await attachReceipt(deletionUnhandledFailure(
      request,
      "deletion_immediate_flow_failed",
      error,
    ));
  }
});

async function handleScheduledDeletion(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
  reason: string,
  job: DeletionJobRow,
  request: Request,
): Promise<Response> {
  const wasReplay = job.state === "scheduled";

  if (job.state === "cancelled") {
    return jsonWithRequest(request, {
      error: "deletion_request_cancelled",
      deletion_state: job.state,
    }, 409);
  }

  if (job.state !== "scheduled" && deletionStateIsTerminal(job.state)) {
    return jsonWithRequest(request, {
      error: "deletion_terminal_state",
      deletion_state: job.state,
    }, 409);
  }

  if (job.state === "retry_scheduled") {
    const retryDate = job.next_retry_at ?? job.scheduled_for;
    return jsonWithRequest(request, {
      scheduled: true,
      deletion_date: retryDate,
      deletion_state: job.state,
      idempotency_key: job.idempotency_key,
      idempotent_replay: true,
      retry_after_seconds: retryAfterSeconds(job.next_retry_at),
    }, 202);
  }

  if (
    job.state === "auth_deleting" || job.state === "data_deleting" ||
    job.state === "vector_verifying"
  ) {
    return jsonWithRequest(request, {
      scheduled: false,
      deletion_date: null,
      deletion_state: job.state,
      deletion_in_progress: true,
      idempotency_key: job.idempotency_key,
      idempotent_replay: true,
    }, 202);
  }

  const nextScheduledFor = job.scheduled_for ??
    new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString();

  const { error: scheduleError } = await service
    .from("users")
    .update({
      deletion_scheduled_at: nextScheduledFor,
      deletion_reason: reason,
      deletion_in_progress: false,
    })
    .eq("id", userId);

  if (scheduleError) {
    return jsonWithRequest(request, {
      error: "deletion_schedule_failed",
      detail: sanitizedInternalDetail(request, "index", scheduleError),
    }, 500);
  }

  if (job.state !== "scheduled") {
    job = await updateDeletionJobState(service, job, "scheduled", {
      scheduled_for: nextScheduledFor,
      reason,
      next_retry_at: null,
      last_error: null,
      last_failure_type: null,
    });
  }

  return jsonWithRequest(request, {
    scheduled: true,
    deletion_date: nextScheduledFor,
    deletion_state: job.state,
    idempotency_key: job.idempotency_key,
    idempotent_replay: wasReplay,
  }, 202);
}

async function handleImmediateDeletion(
  service: ReturnType<typeof serviceRoleClient>,
  user: UserRow,
  reason: string,
  job: DeletionJobRow,
  request: Request,
): Promise<Response> {
  if (job.state === "completed") {
    return jsonWithRequest(request, {
      success: true,
      storage_deleted: true,
      vectors_deleted: true,
      postgres_deleted: true,
      auth_deleted: true,
      audit_log_id: job.audit_log_id,
      deletion_state: job.state,
      attempt_count: job.attempt_count,
      idempotency_key: job.idempotency_key,
      idempotent_replay: true,
    });
  }

  if (job.state === "cancelled") {
    return jsonWithRequest(request, {
      error: "deletion_request_cancelled",
      deletion_state: job.state,
    }, 409);
  }

  if (job.state === "retry_scheduled") {
    const retryAfter = retryAfterSeconds(job.next_retry_at);
    if (retryAfter > 0) {
      return jsonWithRequest(request, {
        success: false,
        error: job.last_error ?? "deletion_retry_scheduled",
        failure_type: job.last_failure_type,
        retry_after_seconds: retryAfter,
        deletion_state: job.state,
        attempt_count: job.attempt_count,
        idempotency_key: job.idempotency_key,
        idempotent_replay: true,
      }, 202);
    }
  }

  if (
    job.state === "failed" && job.attempt_count >= MAX_IMMEDIATE_RETRY_ATTEMPTS
  ) {
    return jsonWithRequest(request, {
      success: false,
      error: job.last_error ?? "deletion_failed",
      failure_type: job.last_failure_type,
      deletion_state: job.state,
      attempt_count: job.attempt_count,
      idempotency_key: job.idempotency_key,
      audit_log_id: job.audit_log_id,
    }, 500);
  }

  const { error: markInProgressError } = await service
    .from("users")
    .update({
      deletion_in_progress: true,
      deletion_reason: reason,
    })
    .eq("id", user.id);
  if (markInProgressError) {
    return jsonWithRequest(request, {
      error: "deletion_mark_in_progress_failed",
      detail: sanitizedInternalDetail(request, "index", markInProgressError),
    }, 500);
  }

  const attemptCount = Math.max(0, job.attempt_count) + 1;
  job = await updateDeletionJobState(service, job, "data_deleting", {
    attempt_count: attemptCount,
    reason,
    next_retry_at: null,
    last_error: null,
    last_failure_type: null,
  });

  const storageDelete = await cleanupMedicalScanStorage(service, user, job);
  job = storageDelete.job;
  if (!storageDelete.ok) {
    return await handleImmediateFailure(service, user.id, reason, job, {
      request,
      failureType: storageDelete.failureType!,
      error: storageDelete.error!,
      storageDeleted: false,
      authDeleted: false,
      postgresDeleted: false,
      vectorsDeleted: false,
    });
  }

  try {
    await deleteUserVectorMemory(service, user.id);
  } catch (error) {
    return await handleImmediateFailure(service, user.id, reason, job, {
      request,
      failureType: "pinecone",
      error: error instanceof Error ? error.message : "vector_delete_failed",
      storageDeleted: true,
      authDeleted: false,
      postgresDeleted: false,
      vectorsDeleted: false,
    });
  }
  const postgresDelete = await deletePostgresData(service, user.id);
  if (!postgresDelete.ok) {
    return await handleImmediateFailure(service, user.id, reason, job, {
      request,
      failureType: postgresDelete.failureType!,
      error: postgresDelete.error!,
      storageDeleted: true,
      authDeleted: false,
      postgresDeleted: false,
      vectorsDeleted: false,
    });
  }

  const vectorsDelete = await verifyVectorDeletion(service, user.id);
  if (!vectorsDelete.ok) {
    return await handlePostDeleteFailure(
      service,
      user.id,
      job,
      request,
      {
        failureType: vectorsDelete.failureType!,
        error: vectorsDelete.error!,
        storageDeleted: true,
        authDeleted: false,
        postgresDeleted: true,
        vectorsDeleted: false,
      },
    );
  }

  const authDelete = await deleteAuthPrincipalWithRetry(
    service,
    canonicalAuthUserId(user),
  );
  if (!authDelete.ok) {
    return await handlePostDeleteFailure(
      service,
      user.id,
      job,
      request,
      {
        failureType: authDelete.failureType!,
        error: authDelete.error!,
        storageDeleted: true,
        authDeleted: false,
        postgresDeleted: true,
        vectorsDeleted: true,
      },
    );
  }

  const auditLogId = job.audit_log_id ?? crypto.randomUUID();
  const auditError = await upsertDeletionAudit(service, {
    id: auditLogId,
    userId: user.id,
    storageDeleted: true,
    vectorsDeleted: true,
    postgresDeleted: true,
    authDeleted: true,
    notes: null,
  });
  if (auditError) {
    return await handlePostDeleteFailure(
      service,
      user.id,
      job,
      request,
      {
        failureType: "postgres",
        error: `deletion_audit_failed:${auditError}`,
        storageDeleted: true,
        authDeleted: true,
        postgresDeleted: true,
        vectorsDeleted: true,
      },
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
      user.id,
      auditLogId,
      error,
    );
    if (!cascadedAway) {
      throw error;
    }
  }

  return jsonWithRequest(request, {
    success: true,
    storage_deleted: true,
    vectors_deleted: true,
    postgres_deleted: true,
    auth_deleted: true,
    audit_log_id: auditLogId,
    attempt_count: job.attempt_count,
    idempotency_key: job.idempotency_key,
    idempotent_replay: false,
    // The job may have cascaded away with users before its final update.
    // All four deletion checks and the compliance audit above succeeded.
    deletion_state: "completed",
  });
}

async function handlePostDeleteFailure(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
  job: DeletionJobRow,
  request: Request,
  options: {
    failureType: DeletionFailureType;
    error: string;
    storageDeleted: boolean;
    authDeleted: boolean;
    postgresDeleted: boolean;
    vectorsDeleted: boolean;
  },
): Promise<Response> {
  await recordFailure(service, userId, options.failureType, options.error);

  const auditLogId = job.audit_log_id ?? crypto.randomUUID();
  const auditError = await upsertDeletionAudit(service, {
    id: auditLogId,
    userId,
    storageDeleted: options.storageDeleted,
    vectorsDeleted: options.vectorsDeleted,
    postgresDeleted: options.postgresDeleted,
    authDeleted: options.authDeleted,
    notes: options.error,
  });

  const failedPatch: Record<string, unknown> = {
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
      userId,
      auditLogId,
      error,
    );
    if (!cascadedAway) {
      throw error;
    }
  }

  if (auditError) {
    return jsonWithRequest(request, {
      error: "deletion_audit_failed",
      detail: sanitizedInternalDetail(request, "index", auditError),
      deletion_state: job.state,
      idempotency_key: job.idempotency_key,
    }, 500);
  }

  return jsonWithRequest(request, {
    success: false,
    manual_intervention_required: true,
    storage_deleted: options.storageDeleted,
    vectors_deleted: options.vectorsDeleted,
    postgres_deleted: options.postgresDeleted,
    auth_deleted: options.authDeleted,
    audit_log_id: auditLogId,
    error: "deletion_failed",
    failure_type: options.failureType,
    deletion_state: cascadedFailureState(job.state),
    attempt_count: job.attempt_count,
    idempotency_key: job.idempotency_key,
  }, 500);
}

function deletionUnhandledFailure(
  request: Request,
  errorCode: string,
  error: unknown,
): Response {
  const detail = error instanceof Error ? error.message : String(error);
  if (detail.startsWith("deletion_job_state_conflict:")) {
    return jsonWithRequest(request, { error: "deletion_state_conflict" }, 409);
  }

  return jsonWithRequest(request, {
    error: errorCode,
    detail: sanitizedInternalDetail(request, "index", error),
  }, 500);
}

async function handleImmediateFailure(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
  reason: string,
  job: DeletionJobRow,
  options: {
    request: Request;
    failureType: DeletionFailureType;
    error: string;
    storageDeleted: boolean;
    authDeleted: boolean;
    postgresDeleted: boolean;
    vectorsDeleted: boolean;
  },
): Promise<Response> {
  const request = options.request;
  await recordFailure(service, userId, options.failureType, options.error);

  const retryEligible = !options.authDeleted &&
    job.attempt_count < MAX_IMMEDIATE_RETRY_ATTEMPTS;
  if (retryEligible) {
    const retryDelay = retryDelaySeconds(job.attempt_count);
    const nextRetryAt = new Date(Date.now() + retryDelay * 1000).toISOString();

    job = await updateDeletionJobState(service, job, "retry_scheduled", {
      reason,
      next_retry_at: nextRetryAt,
      last_error: options.error,
      last_failure_type: options.failureType,
    });

    return jsonWithRequest(request, {
      success: false,
      error: options.error,
      failure_type: options.failureType,
      retry_after_seconds: retryDelay,
      deletion_state: job.state,
      attempt_count: job.attempt_count,
      idempotency_key: job.idempotency_key,
      storage_deleted: options.storageDeleted,
      auth_deleted: options.authDeleted,
      postgres_deleted: options.postgresDeleted,
      vectors_deleted: options.vectorsDeleted,
    }, 503);
  }

  await service
    .from("users")
    .update({
      deletion_in_progress: false,
      deletion_reason: reason,
    })
    .eq("id", userId);

  const auditLogId = job.audit_log_id ?? crypto.randomUUID();
  const auditError = await upsertDeletionAudit(service, {
    id: auditLogId,
    userId,
    storageDeleted: options.storageDeleted,
    vectorsDeleted: options.vectorsDeleted,
    postgresDeleted: options.postgresDeleted,
    authDeleted: options.authDeleted,
    notes: options.error,
  });
  if (auditError) {
    return jsonWithRequest(request, {
      error: "deletion_audit_failed",
      detail: sanitizedInternalDetail(request, "index", auditError),
    }, 500);
  }

  job = await updateDeletionJobState(service, job, "failed", {
    reason,
    audit_log_id: auditLogId,
    next_retry_at: null,
    last_error: options.error,
    last_failure_type: options.failureType,
  });

  return jsonWithRequest(request, {
    success: false,
    storage_deleted: options.storageDeleted,
    vectors_deleted: options.vectorsDeleted,
    postgres_deleted: options.postgresDeleted,
    auth_deleted: options.authDeleted,
    audit_log_id: auditLogId,
    error: options.error,
    failure_type: options.failureType,
    deletion_state: job.state,
    attempt_count: job.attempt_count,
    idempotency_key: job.idempotency_key,
  }, 500);
}

function retryDelaySeconds(attemptCount: number): number {
  const exponent = Math.max(0, attemptCount - 1);
  const backoff = RETRY_BASE_SECONDS * Math.pow(2, exponent);
  return Math.min(RETRY_MAX_SECONDS, Math.round(backoff));
}
