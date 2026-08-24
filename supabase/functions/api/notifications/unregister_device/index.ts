import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { PushDevicePayloadSchema } from "../../../_shared/payload_schemas.ts";

interface PushDevicePayload {
  device_id?: string;
  push_token?: string;
}

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

  let payload: PushDevicePayload = {};
  try {
    const bodyRaw = await request.json();
    const bodyParse = parseWithSchema(PushDevicePayloadSchema, bodyRaw);
    if (!bodyParse.ok) {
      return jsonWithRequest(request, {
        error: "invalid_payload",
        issues: bodyParse.issues,
      }, 400);
    }
    payload = bodyParse.output;
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const deviceId = payload.device_id?.trim() ?? "";
  const pushToken = payload.push_token?.trim().toLowerCase() ?? "";
  if (!deviceId && !pushToken) {
    return jsonWithRequest(request, {
      error: "missing_device_identifier",
    }, 400);
  }

  const userClient = anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const service = serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (userLookupError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: userLookupError.message,
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  let query = service
    .from("push_devices")
    .update({
      revoked_at: new Date().toISOString(),
      last_seen_at: new Date().toISOString(),
    })
    .eq("user_id", userRow.id)
    .is("revoked_at", null);

  if (deviceId) {
    query = query.eq("device_id", deviceId);
  }
  if (pushToken) {
    query = query.eq("push_token", pushToken);
  }

  const { error: revokeError } = await query;
  if (revokeError) {
    return jsonWithRequest(request, {
      error: "push_device_unregister_failed",
      detail: revokeError.message,
    }, 500);
  }

  return jsonWithRequest(request, { status: "unregistered" });
});
