import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { InsightAcknowledgePayloadSchema } from "../../../_shared/payload_schemas.ts";

interface AcknowledgePayload {
  insight_id?: string;
  acknowledged_at?: string;
}

type UserRow = { id: string };

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

  const userClient = anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  let payloadRaw: unknown;
  try {
    payloadRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const payloadParse = parseWithSchema(
    InsightAcknowledgePayloadSchema,
    payloadRaw,
  );
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: AcknowledgePayload = payloadParse.output;

  const insightId = typeof payload.insight_id === "string"
    ? payload.insight_id.trim()
    : "";
  if (!insightId) {
    return jsonWithRequest(request, { error: "insight_id_required" }, 400);
  }
  if (!isUUID(insightId)) {
    return jsonWithRequest(request, { error: "invalid_insight_id" }, 400);
  }

  if (
    payload.acknowledged_at != null &&
    typeof payload.acknowledged_at !== "string"
  ) {
    return jsonWithRequest(request, { error: "invalid_acknowledged_at" }, 400);
  }
  const acknowledgedAtDate = typeof payload.acknowledged_at === "string"
    ? new Date(payload.acknowledged_at)
    : new Date();
  if (Number.isNaN(acknowledgedAtDate.getTime())) {
    return jsonWithRequest(request, { error: "invalid_acknowledged_at" }, 400);
  }

  const service = serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<UserRow>();

  if (userLookupError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userLookupError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }

  const { data: updatedRows, error: updateError } = await service
    .from("insights")
    .update({
      acknowledged: true,
      acknowledged_at: acknowledgedAtDate.toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", insightId)
    .eq("user_id", userRow.id)
    .select("id");

  if (updateError) {
    return jsonWithRequest(request, {
      error: "insight_acknowledge_failed",
      detail: sanitizedInternalDetail(request, "index", updateError),
    }, 500);
  }

  if (!updatedRows || updatedRows.length === 0) {
    return jsonWithRequest(request, { error: "insight_not_found" }, 404);
  }

  return jsonWithRequest(request, { ok: true });
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
