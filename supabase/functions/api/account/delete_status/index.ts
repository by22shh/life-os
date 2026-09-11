import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import {
  deletionReceiptHash,
  readDeletionReceipt,
} from "../../../_shared/deletion_receipt.ts";

interface DeletionJobStatusRow {
  mode: "scheduled" | "immediate";
  state:
    | "requested"
    | "scheduled"
    | "auth_deleting"
    | "data_deleting"
    | "vector_verifying"
    | "retry_scheduled"
    | "completed"
    | "failed"
    | "cancelled";
  attempt_count: number;
  next_retry_at: string | null;
  idempotency_key: string;
  updated_at: string;
}

interface UserDeletionStatusRow {
  id: string;
  deletion_scheduled_at: string | null;
  deletion_in_progress: boolean | null;
  deletion_reason: string | null;
}

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "GET" && request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const receipt = request.headers.get("X-Deletion-Receipt");
  if (receipt) {
    // Per-receipt rate-limit bucket: a shared global bucket would let one
    // caller exhaust status polling for every client after a deletion.
    const receiptBucket = `deletion-receipt:${
      (await deletionReceiptHash(receipt))
        .slice(0, 32)
    }`;
    const rateLimited = await enforceRateLimit(
      request,
      receiptBucket,
      "standard",
    );
    if (rateLimited) return rateLimited;
    try {
      const state = await readDeletionReceipt(serviceRoleClient(), receipt);
      if (!state) {
        return jsonWithRequest(request, {
          error: "invalid_or_expired_deletion_receipt",
        }, 401);
      }
      return jsonWithRequest(request, {
        deletion_state: state,
        completed: state === "completed",
      });
    } catch {
      return jsonWithRequest(request, {
        error: "deletion_receipt_lookup_failed",
      }, 503);
    }
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const authenticated = await resolveAuthenticatedUser(request);
  if (!authenticated.ok) return authenticated.response;
  const authData = authenticated.data;

  const service = serviceRoleClient();
  const { data: userRow, error: userError } = await service
    .from("users")
    .select("id,deletion_scheduled_at,deletion_in_progress,deletion_reason")
    .eq("auth_id", authData.user.id)
    .maybeSingle<UserDeletionStatusRow>();

  if (userError) {
    return jsonWithRequest(request, {
      error: "deletion_status_failed",
      detail: sanitizedInternalDetail(request, "index", userError),
    }, 500);
  }

  let latestJob: DeletionJobStatusRow | null = null;
  let jobError: { message: string } | null = null;

  if (userRow) {
    const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
    if (rateLimited) {
      return rateLimited;
    }

    const result = await service
      .from("account_deletion_jobs")
      .select(
        "mode,state,attempt_count,next_retry_at,idempotency_key,updated_at",
      )
      .eq("user_id", userRow.id)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle<DeletionJobStatusRow>();
    latestJob = result.data ?? null;
    jobError = result.error;
  } else {
    const result = await service
      .from("account_deletion_jobs")
      .select(
        "mode,state,attempt_count,next_retry_at,idempotency_key,updated_at",
      )
      .eq("auth_user_id", authData.user.id)
      .order("updated_at", { ascending: false })
      .limit(1)
      .maybeSingle<DeletionJobStatusRow>();
    latestJob = result.data ?? null;
    jobError = result.error;
  }

  if (jobError) {
    return jsonWithRequest(request, {
      error: "deletion_status_job_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", jobError),
    }, 500);
  }

  if (!userRow && !latestJob) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const retryAfterSeconds = computeRetryAfterSeconds(latestJob?.next_retry_at);

  return jsonWithRequest(request, {
    scheduled: userRow?.deletion_scheduled_at != null ||
      latestJob?.state === "retry_scheduled",
    deletion_date: userRow?.deletion_scheduled_at ?? latestJob?.next_retry_at ??
      null,
    deletion_in_progress: userRow?.deletion_in_progress ??
      (latestJob?.state === "auth_deleting" ||
        latestJob?.state === "data_deleting" ||
        latestJob?.state === "vector_verifying"),
    reason: userRow?.deletion_reason ?? null,
    deletion_state: latestJob?.state ?? null,
    deletion_mode: latestJob?.mode ?? null,
    deletion_attempt_count: latestJob?.attempt_count ?? 0,
    retry_after_seconds: retryAfterSeconds > 0 ? retryAfterSeconds : null,
    idempotency_key: latestJob?.idempotency_key ?? null,
  });
});

function computeRetryAfterSeconds(
  nextRetryAt: string | null | undefined,
): number {
  if (!nextRetryAt) return 0;
  const retryAtMs = Date.parse(nextRetryAt);
  if (!Number.isFinite(retryAtMs)) return 0;
  return Math.max(0, Math.ceil((retryAtMs - Date.now()) / 1000));
}
