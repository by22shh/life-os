import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";

type CancellableDeletionState = "requested" | "scheduled" | "retry_scheduled";

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

  const authenticated = await resolveAuthenticatedUser(request);
  if (!authenticated.ok) return authenticated.response;
  const authData = authenticated.data;

  const service = serviceRoleClient();
  const { data: userRow, error: userError } = await service
    .from("users")
    .select("id,deletion_scheduled_at,deletion_in_progress")
    .eq("auth_id", authData.user.id)
    .maybeSingle<
      {
        id: string;
        deletion_scheduled_at: string | null;
        deletion_in_progress: boolean | null;
      }
    >();

  if (userError) {
    return jsonWithRequest(request, {
      error: "deletion_cancel_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }
  if (!userRow.deletion_scheduled_at) {
    return jsonWithRequest(request, { error: "deletion_not_scheduled" }, 409);
  }
  if (userRow.deletion_in_progress) {
    return jsonWithRequest(
      request,
      { error: "deletion_already_in_progress" },
      409,
    );
  }

  const { error: cancelError } = await service
    .from("users")
    .update({
      deletion_scheduled_at: null,
      deletion_reason: null,
      deletion_in_progress: false,
    })
    .eq("id", userRow.id);

  if (cancelError) {
    return jsonWithRequest(request, {
      error: "deletion_cancel_failed",
      detail: sanitizedInternalDetail(request, "index", cancelError),
    }, 500);
  }

  const cancellableStates: CancellableDeletionState[] = [
    "requested",
    "scheduled",
    "retry_scheduled",
  ];
  const { error: jobCancelError } = await service
    .from("account_deletion_jobs")
    .update({
      state: "cancelled",
      next_retry_at: null,
      last_error: null,
      last_failure_type: null,
    })
    .eq("user_id", userRow.id)
    .eq("mode", "scheduled")
    .in("state", cancellableStates);

  if (jobCancelError) {
    return jsonWithRequest(request, {
      error: "deletion_cancel_job_update_failed",
      detail: sanitizedInternalDetail(request, "index", jobCancelError),
    }, 500);
  }

  return jsonWithRequest(request, {
    cancelled: true,
    deletion_state: "cancelled",
  });
});
