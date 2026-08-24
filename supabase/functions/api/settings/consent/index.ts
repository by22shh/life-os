import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { ConsentPayloadSchema } from "../../../_shared/payload_schemas.ts";

interface ConsentPayload {
  id?: string;
  consent_type?: string;
  granted?: boolean;
  version?: string;
  ip_address?: string | null;
  timestamp?: string;
}

const MAX_CONSENT_TYPE_LENGTH = 64;
const MAX_VERSION_LENGTH = 64;
const MAX_IP_ADDRESS_LENGTH = 64;
const CONSENT_TYPE_PATTERN = /^[a-z0-9._-]+$/i;

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
  const payloadParse = parseWithSchema(ConsentPayloadSchema, payloadRaw);
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: ConsentPayload = payloadParse.output;

  const consentType = sanitizeText(
    payload.consent_type,
    MAX_CONSENT_TYPE_LENGTH,
  );
  const version = sanitizeText(payload.version, MAX_VERSION_LENGTH);
  if (!consentType || !version || typeof payload.granted !== "boolean") {
    return jsonWithRequest(request, { error: "invalid_consent_payload" }, 400);
  }
  if (!CONSENT_TYPE_PATTERN.test(consentType)) {
    return jsonWithRequest(request, { error: "invalid_consent_type" }, 400);
  }
  if (payload.ip_address != null && typeof payload.ip_address !== "string") {
    return jsonWithRequest(request, { error: "invalid_ip_address" }, 400);
  }
  const ipAddressRaw = typeof payload.ip_address === "string"
    ? payload.ip_address.trim()
    : "";
  if (ipAddressRaw.length > MAX_IP_ADDRESS_LENGTH) {
    return jsonWithRequest(request, { error: "invalid_ip_address" }, 400);
  }
  const ipAddress = ipAddressRaw.length > 0 ? ipAddressRaw : null;

  const service = serviceRoleClient();
  const { data: userRow, error: userError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (userError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: userError.message,
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }

  const idFromPayload = typeof payload.id === "string" ? payload.id.trim() : "";
  if (idFromPayload && !isUUID(idFromPayload)) {
    return jsonWithRequest(request, { error: "invalid_id" }, 400);
  }
  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const idFromHeader = isUUID(idempotencyKey) ? idempotencyKey : "";
  if (
    idFromPayload && idFromHeader &&
    idFromPayload.toLowerCase() !== idFromHeader.toLowerCase()
  ) {
    return jsonWithRequest(request, { error: "idempotency_key_mismatch" }, 400);
  }
  const id = idFromPayload || idFromHeader || crypto.randomUUID();
  if (payload.timestamp != null && typeof payload.timestamp !== "string") {
    return jsonWithRequest(request, { error: "invalid_timestamp" }, 400);
  }
  const timestamp = typeof payload.timestamp === "string" &&
      !Number.isNaN(new Date(payload.timestamp).getTime())
    ? new Date(payload.timestamp).toISOString()
    : new Date().toISOString();

  const { data: existing, error: existingError } = await service
    .from("consent_records")
    .select("id,user_id")
    .eq("id", id)
    .maybeSingle<{ id: string; user_id: string }>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "consent_lookup_failed",
      detail: existingError.message,
    }, 500);
  }
  if (existing) {
    if (existing.user_id !== userRow.id) {
      return jsonWithRequest(request, { error: "consent_id_conflict" }, 409);
    }
    return jsonWithRequest(
      request,
      { id, status: "recorded", idempotent_replay: true },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  const { error: insertError } = await service.from("consent_records").insert({
    id,
    user_id: userRow.id,
    consent_type: consentType,
    granted: payload.granted,
    timestamp,
    version,
    ip_address: ipAddress,
    created_at: new Date().toISOString(),
  });

  if (insertError) {
    return jsonWithRequest(request, {
      error: "consent_record_failed",
      detail: insertError.message,
    }, 500);
  }

  return jsonWithRequest(request, { id, status: "recorded" }, 202);
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function sanitizeText(value: unknown, maxLength: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength) return null;
  return trimmed;
}
