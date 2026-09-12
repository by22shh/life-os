import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";

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
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<
      {
        id: string;
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
  const { data: cancellation, error: cancelError } = await service.rpc(
    "cancel_scheduled_account_deletion",
    { p_user_id: userRow.id },
  );
  if (cancelError || typeof cancellation !== "string") {
    return jsonWithRequest(request, {
      error: "deletion_cancel_failed",
      detail: sanitizedInternalDetail(
        request,
        "index",
        cancelError ?? "invalid_response",
      ),
    }, 500);
  }

  if (cancellation === "not_scheduled") {
    return jsonWithRequest(request, { error: "deletion_not_scheduled" }, 409);
  }
  if (cancellation === "in_progress") {
    return jsonWithRequest(
      request,
      { error: "deletion_already_in_progress" },
      409,
    );
  }
  if (cancellation !== "cancelled") {
    return jsonWithRequest(request, { error: "deletion_cancel_failed" }, 500);
  }

  return jsonWithRequest(request, {
    cancelled: true,
    deletion_state: "cancelled",
  });
});
