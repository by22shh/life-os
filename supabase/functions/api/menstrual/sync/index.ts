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
import { MenstrualPayloadSchema } from "../../../_shared/payload_schemas.ts";

type MenstrualFlow = "light" | "medium" | "heavy" | "spotting";

interface MenstrualPayload {
  id?: string;
  date?: string;
  flow?: MenstrualFlow | null;
  pain_level?: number | null;
  deleted?: boolean;
}

type UserRow = { id: string };

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (
    request.method !== "POST" && request.method !== "PUT" &&
    request.method !== "PATCH"
  ) {
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
  const payloadParse = parseWithSchema(MenstrualPayloadSchema, payloadRaw);
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: MenstrualPayload = payloadParse.output;

  const id = typeof payload.id === "string" ? payload.id.trim() : "";
  if (!id || !isUUID(id)) {
    return jsonWithRequest(request, { error: "invalid_id" }, 400);
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

  const rateLimited = await enforceRateLimit(
    request,
    userRow.id,
    "write_heavy",
    { allowOutboxReplayExemption: true },
  );
  if (rateLimited) {
    return rateLimited;
  }

  const { data: existingRow, error: existingLookupError } = await service
    .from("menstrual_logs")
    .select("id,user_id")
    .eq("id", id)
    .maybeSingle<{ id: string; user_id: string }>();

  if (existingLookupError) {
    return jsonWithRequest(request, {
      error: "menstrual_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", existingLookupError),
    }, 500);
  }
  if (existingRow && existingRow.user_id !== userRow.id) {
    return jsonWithRequest(request, { error: "forbidden_id_ownership" }, 403);
  }

  if (payload.deleted === true) {
    const { error: deleteError } = await service
      .from("menstrual_logs")
      .update({
        deleted_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      })
      .eq("id", id)
      .eq("user_id", userRow.id);

    if (deleteError) {
      return jsonWithRequest(request, {
        error: "menstrual_delete_failed",
        detail: sanitizedInternalDetail(request, "index", deleteError),
      }, 500);
    }
    return jsonWithRequest(request, { ok: true });
  }

  const date = typeof payload.date === "string" ? payload.date.trim() : "";
  if (!isIsoDate(date)) {
    return jsonWithRequest(request, { error: "invalid_date" }, 400);
  }

  const flow = payload.flow ?? null;
  if (flow != null && !isValidFlow(flow)) {
    return jsonWithRequest(request, { error: "invalid_flow" }, 400);
  }

  const painLevel = payload.pain_level ?? null;
  if (
    painLevel != null &&
    (!Number.isFinite(painLevel) || painLevel < 1 || painLevel > 5)
  ) {
    return jsonWithRequest(request, { error: "invalid_pain_level" }, 400);
  }

  const { error: upsertError } = await service
    .from("menstrual_logs")
    .upsert(
      {
        id,
        user_id: userRow.id,
        date,
        flow,
        pain_level: painLevel == null ? null : Math.round(painLevel),
        deleted_at: null,
      },
      { onConflict: "id" },
    );

  if (upsertError) {
    return jsonWithRequest(request, {
      error: "menstrual_sync_failed",
      detail: sanitizedInternalDetail(request, "index", upsertError),
    }, 500);
  }

  return jsonWithRequest(request, { ok: true });
});

function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime())) return false;
  return parsed.toISOString().slice(0, 10) === value;
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function isValidFlow(value: string): value is MenstrualFlow {
  return value === "light" || value === "medium" || value === "heavy" ||
    value === "spotting";
}
