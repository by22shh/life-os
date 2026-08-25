import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { PushDevicePayloadSchema } from "../../../_shared/payload_schemas.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";

interface PushDevicePayload {
  device_id?: string;
  push_token?: string;
  platform?: string;
  environment?: string;
  locale?: string;
  timezone?: string;
  app_version?: string;
  build_number?: string;
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
  const platform = payload.platform?.trim().toLowerCase() ?? "";
  const environment = payload.environment?.trim().toLowerCase() ?? "";
  if (
    !deviceId || !pushToken || platform !== "ios" ||
    (environment !== "development" && environment !== "production")
  ) {
    return jsonWithRequest(request, {
      error: "missing_or_invalid_device_fields",
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
      detail: sanitizedInternalDetail(request, "index", userLookupError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(
    request,
    userRow.id,
    "write_heavy",
  );
  if (rateLimited) return rateLimited;

  // Re-own the token when the same physical device switches accounts. The
  // device_id match proves physical possession; revoking purely on a known
  // push_token would let an attacker silence another user's notifications.
  await service
    .from("push_devices")
    .update({ revoked_at: new Date().toISOString() })
    .eq("push_token", pushToken)
    .eq("device_id", deviceId)
    .neq("user_id", userRow.id)
    .is("revoked_at", null);

  const { data: existingDevice, error: existingError } = await service
    .from("push_devices")
    .select("id")
    .eq("user_id", userRow.id)
    .eq("device_id", deviceId)
    .maybeSingle<{ id: string }>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "push_device_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", existingError),
    }, 500);
  }

  const now = new Date().toISOString();
  const mutation = {
    user_id: userRow.id,
    device_id: deviceId,
    push_token: pushToken,
    platform: "ios",
    environment,
    locale: payload.locale ?? null,
    timezone: payload.timezone ?? null,
    app_version: payload.app_version ?? null,
    build_number: payload.build_number ?? null,
    registered_at: now,
    last_seen_at: now,
    revoked_at: null,
  };

  const { error: writeError } = existingDevice
    ? await service
      .from("push_devices")
      .update(mutation)
      .eq("id", existingDevice.id)
    : await service.from("push_devices").insert(mutation);

  if (writeError) {
    return jsonWithRequest(request, {
      error: "push_device_register_failed",
      detail: sanitizedInternalDetail(request, "index", writeError),
    }, 500);
  }

  return jsonWithRequest(request, {
    status: "registered",
    device_id: deviceId,
  });
});
