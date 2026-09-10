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
import { AnalyticsBatchRequestSchema } from "../../../_shared/payload_schemas.ts";

interface BatchEventInput {
  name?: string;
  timestamp?: string;
  properties?: Record<string, unknown>;
  session_id?: string;
}

interface BatchRequest {
  events?: BatchEventInput[];
  event_name?: string;
  properties_json?: string;
  created_at?: string;
  session_id?: string;
}

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const deviceId = request.headers.get("X-Device-Id");
  if (!deviceId) {
    return jsonWithRequest(request, { error: "missing_device_id" }, 400);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const authenticated = await resolveAuthenticatedUser(request);
  if (!authenticated.ok) return authenticated.response;
  const authData = authenticated.data;

  let payloadRaw: unknown;
  try {
    payloadRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const payloadParse = parseWithSchema(AnalyticsBatchRequestSchema, payloadRaw);
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: BatchRequest = payloadParse.output;

  let incomingEvents: unknown[] = Array.isArray(payload.events)
    ? payload.events
    : [];

  // Backward compatibility for legacy single-event outbox payloads.
  if (incomingEvents.length === 0 && typeof payload.event_name === "string") {
    let legacyProperties: Record<string, unknown> = {};
    if (typeof payload.properties_json === "string") {
      try {
        const parsed = JSON.parse(payload.properties_json);
        if (isJSONObject(parsed)) {
          legacyProperties = parsed;
        }
      } catch {
        // keep empty properties
      }
    }

    incomingEvents = [{
      name: payload.event_name,
      timestamp: payload.created_at,
      properties: legacyProperties,
      session_id: payload.session_id,
    }];
  }

  if (incomingEvents.length === 0) {
    return jsonWithRequest(request, { error: "events_required" }, 400);
  }
  if (incomingEvents.length > 50) {
    return jsonWithRequest(request, { error: "batch_too_large" }, 400);
  }

  const service = serviceRoleClient();
  const { data: userRow, error: userError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (userError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "analytics");
  if (rateLimited) {
    return rateLimited;
  }

  const { data: privacySettings, error: privacyError } = await service
    .from("privacy_settings")
    .select("analytics_consent")
    .eq("user_id", userRow.id)
    .maybeSingle<{ analytics_consent: boolean | null }>();

  if (privacyError) {
    return jsonWithRequest(request, {
      error: "privacy_settings_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", privacyError),
    }, 500);
  }

  if (!(privacySettings?.analytics_consent ?? false)) {
    return jsonWithRequest(request, {
      accepted: 0,
      rejected: incomingEvents.length,
      dropped_reason: "analytics_consent_disabled",
    }, 202);
  }

  const now = Date.now();
  const maxAgeMs = 7 * 24 * 60 * 60 * 1000;

  const acceptedRows: Array<Record<string, unknown>> = [];
  let rejected = 0;

  for (const event of incomingEvents) {
    if (!isJSONObject(event)) {
      rejected += 1;
      continue;
    }

    const eventName = typeof event.name === "string" ? event.name.trim() : "";
    if (eventName.length == 0 || eventName.length > 100) {
      rejected += 1;
      continue;
    }

    if (event.timestamp != null && typeof event.timestamp !== "string") {
      rejected += 1;
      continue;
    }
    const parsedTs = typeof event.timestamp === "string"
      ? new Date(event.timestamp)
      : new Date();

    if (Number.isNaN(parsedTs.getTime())) {
      rejected += 1;
      continue;
    }
    const ageMs = now - parsedTs.getTime();
    if (ageMs < 0 || ageMs > maxAgeMs) {
      rejected += 1;
      continue;
    }

    if (event.session_id != null && typeof event.session_id !== "string") {
      rejected += 1;
      continue;
    }
    const sessionId = typeof event.session_id === "string"
      ? event.session_id
      : null;
    if (sessionId && !isUUID(sessionId)) {
      rejected += 1;
      continue;
    }

    if (event.properties != null && !isJSONObject(event.properties)) {
      rejected += 1;
      continue;
    }
    const properties = isJSONObject(event.properties) ? event.properties : {};
    const serializedProperties = JSON.stringify(properties);
    if (serializedProperties.length > 1024) {
      rejected += 1;
      continue;
    }

    acceptedRows.push({
      id: crypto.randomUUID(),
      user_id: userRow.id,
      event_name: eventName,
      properties,
      session_id: sessionId,
      app_version: request.headers.get("X-App-Version") ?? null,
      os_version: request.headers.get("X-OS-Version") ?? null,
      device_model: request.headers.get("X-Device-Model") ?? null,
      created_at: parsedTs.toISOString(),
    });
  }

  if (acceptedRows.length > 0) {
    const { error: insertError } = await service.from("analytics_events")
      .insert(acceptedRows);
    if (insertError) {
      return jsonWithRequest(request, {
        error: "analytics_insert_failed",
        detail: sanitizedInternalDetail(request, "index", insertError),
      }, 500);
    }
  }

  return jsonWithRequest(request, {
    accepted: acceptedRows.length,
    rejected,
  }, 202);
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function isJSONObject(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}
