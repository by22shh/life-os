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
import { PrivacyPayloadSchema } from "../../../_shared/payload_schemas.ts";
import { enforceMedicalScanPrivacyState } from "../../../_shared/medical_scan_privacy.ts";

interface PrivacyPayload {
  menstrual_local_only?: boolean;
  medical_scan_local_only?: boolean;
  vector_opt_in?: boolean;
  analytics_consent?: boolean;
  ai_processing_consent?: boolean;
  cloud_ocr_enabled?: boolean;
  cloud_backup_enabled?: boolean;
}

interface PrivacyRow {
  id: string;
  user_id: string;
  menstrual_local_only: boolean;
  medical_scan_local_only: boolean;
  vector_opt_in: boolean;
  analytics_consent: boolean;
  ai_processing_consent: boolean;
  cloud_ocr_enabled: boolean;
  cloud_backup_enabled?: boolean;
  created_at: string;
  updated_at: string;
}

const PRIVACY_SELECT =
  "id,user_id,menstrual_local_only,medical_scan_local_only,vector_opt_in,analytics_consent,ai_processing_consent,cloud_ocr_enabled,cloud_backup_enabled,created_at,updated_at";

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (
    request.method !== "GET" && request.method !== "PATCH" &&
    request.method !== "POST"
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

  const service = serviceRoleClient();
  const { data: userRow, error: userError } = await service
    .from("users")
    .select("id,auth_id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string; auth_id: string }>();

  if (userError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
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

  if (request.method === "GET") {
    let row: PrivacyRow;
    try {
      row = await fetchOrCreateSettings(service, userRow.id);
    } catch (error) {
      return jsonWithRequest(request, {
        error: "privacy_settings_fetch_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500);
    }
    return jsonWithRequest(request, toPublicSettings(row));
  }

  let payloadRaw: unknown;
  try {
    payloadRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const payloadParse = parseWithSchema(PrivacyPayloadSchema, payloadRaw);
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: PrivacyPayload = payloadParse.output;

  let existing: PrivacyRow;
  try {
    existing = await fetchOrCreateSettings(service, userRow.id);
    // deno-coverage-ignore-start -- both API error surfaces are covered; message extraction branch is defensive.
  } catch (error) {
    return jsonWithRequest(request, {
      error: "privacy_settings_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }
  // deno-coverage-ignore-stop
  const normalized = normalizePayload(payload);

  const { data: updated, error: upsertError } = await service
    .from("privacy_settings")
    .upsert(
      {
        id: existing.id,
        user_id: userRow.id,
        ...normalized,
      },
      { onConflict: "user_id" },
    )
    .select(PRIVACY_SELECT)
    .single<PrivacyRow>();

  if (upsertError) {
    return jsonWithRequest(request, {
      error: "privacy_settings_update_failed",
      detail: sanitizedInternalDetail(request, "index", upsertError),
    }, 500);
  }

  try {
    await applyPrivacySideEffects(
      service,
      userRow.id,
      userRow.auth_id,
      updated,
    );
  } catch (error) {
    // deno-coverage-ignore -- both side-effect error surfaces are covered; message extraction branch is defensive.
    return jsonWithRequest(request, {
      error: "privacy_settings_side_effects_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, toPublicSettings(updated));
});

async function fetchOrCreateSettings(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
): Promise<PrivacyRow> {
  const existing = await fetchPrivacyByUserId(service, userId);
  if (existing) {
    return existing;
  }

  const { data: created, error: createError } = await service
    .from("privacy_settings")
    .insert({
      id: crypto.randomUUID(),
      user_id: userId,
      menstrual_local_only: true,
      medical_scan_local_only: true,
      vector_opt_in: false,
      analytics_consent: false,
      ai_processing_consent: false,
      cloud_ocr_enabled: true,
    })
    .select(PRIVACY_SELECT)
    .single<PrivacyRow>();

  if (createError) {
    if (isUniqueViolation(createError)) {
      const racedRow = await fetchPrivacyByUserId(service, userId);
      if (racedRow) {
        return racedRow;
      }
    }
    throw createError;
  }

  return created;
}

async function fetchPrivacyByUserId(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
): Promise<PrivacyRow | null> {
  const { data, error } = await service
    .from("privacy_settings")
    .select(PRIVACY_SELECT)
    .eq("user_id", userId)
    .maybeSingle<PrivacyRow>();
  if (error) throw error;
  return data ?? null;
}

function isUniqueViolation(error: unknown): boolean {
  return readErrorCode(error) === "23505";
}

function readErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") return null;
  const code = Reflect.get(error, "code");
  return typeof code === "string" ? code : null;
}

function normalizePayload(payload: PrivacyPayload): PrivacyPayload {
  const normalized: PrivacyPayload = {};
  if (typeof payload.menstrual_local_only === "boolean") {
    normalized.menstrual_local_only = payload.menstrual_local_only;
  }
  if (typeof payload.medical_scan_local_only === "boolean") {
    normalized.medical_scan_local_only = payload.medical_scan_local_only;
  }
  if (typeof payload.vector_opt_in === "boolean") {
    normalized.vector_opt_in = payload.vector_opt_in;
  }
  if (typeof payload.analytics_consent === "boolean") {
    normalized.analytics_consent = payload.analytics_consent;
  }
  if (typeof payload.ai_processing_consent === "boolean") {
    normalized.ai_processing_consent = payload.ai_processing_consent;
  }
  if (typeof payload.cloud_ocr_enabled === "boolean") {
    normalized.cloud_ocr_enabled = payload.cloud_ocr_enabled;
  }
  if (typeof payload.cloud_backup_enabled === "boolean") {
    normalized.cloud_backup_enabled = payload.cloud_backup_enabled;
  }
  return normalized;
}

async function applyPrivacySideEffects(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
  authUserId: string,
  settings: PrivacyRow,
): Promise<void> {
  if ((settings.cloud_backup_enabled ?? false) === false) {
    const { error } = await service
      .from("user_health_flags")
      .delete()
      .eq("user_id", userId);
    if (error) {
      throw new Error(`user_health_flags_cleanup_failed:${error.message}`);
    }
  }

  await enforceMedicalScanPrivacyState(
    service,
    userId,
    authUserId,
    {
      forceLocalOnly: settings.medical_scan_local_only === true,
      clearCloudBackup: (settings.cloud_backup_enabled ?? false) === false,
    },
  );
}

function toPublicSettings(row: PrivacyRow) {
  return {
    menstrual_local_only: row.menstrual_local_only,
    medical_scan_local_only: row.medical_scan_local_only,
    vector_opt_in: row.vector_opt_in,
    analytics_consent: row.analytics_consent,
    ai_processing_consent: row.ai_processing_consent ?? false,
    cloud_ocr_enabled: row.cloud_ocr_enabled,
    cloud_backup_enabled: row.cloud_backup_enabled ?? false,
  };
}

export const __privacySettingsTestHooks = {
  applyPrivacySideEffects,
  fetchOrCreateSettings,
  fetchPrivacyByUserId,
  isUniqueViolation,
  normalizePayload,
  readErrorCode,
  toPublicSettings,
};
