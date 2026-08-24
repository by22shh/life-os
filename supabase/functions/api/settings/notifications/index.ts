import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { NotificationSettingsPayloadSchema } from "../../../_shared/payload_schemas.ts";
import { normalizeWallClockTime } from "../../../_shared/datetime.ts";
import {
  isFeatureFlagEnabled,
  mergeResolvedFeatureFlags,
  type ResolvedFeatureFlagRow,
} from "../../../_shared/feature_flags.ts";

type ControlLevel = "advisory" | "protective" | "guardian";

interface NotificationSettingsPayload {
  morning_brief_enabled?: boolean;
  positive_enabled?: boolean;
  nudges_enabled?: boolean;
  celebration_enabled?: boolean;
  critical_only?: boolean;
  morning_brief_time_local?: string;
  quiet_hours_start?: string;
  quiet_hours_end?: string;
  max_positive_per_day?: number;
  max_nudges_per_day?: number;
  max_celebration_per_day?: number;
  max_total_per_day?: number;
  control_level?: ControlLevel;
  focus_control_enabled?: boolean;
}

interface SettingsRow {
  id: string;
  user_id: string;
  morning_brief_enabled: boolean;
  positive_enabled: boolean;
  nudges_enabled: boolean;
  celebration_enabled: boolean;
  critical_only: boolean;
  morning_brief_time_local: string;
  quiet_hours_start: string;
  quiet_hours_end: string;
  max_positive_per_day: number;
  max_nudges_per_day: number;
  max_celebration_per_day: number;
  max_total_per_day: number;
  control_level: ControlLevel;
  focus_control_enabled: boolean;
  focus_control_last_granted_at: string | null;
  created_at: string;
  updated_at: string;
}

const SETTINGS_SELECT =
  "id,user_id,morning_brief_enabled,positive_enabled,nudges_enabled,celebration_enabled,critical_only,morning_brief_time_local,quiet_hours_start,quiet_hours_end,max_positive_per_day,max_nudges_per_day,max_celebration_per_day,max_total_per_day,control_level,focus_control_enabled,focus_control_last_granted_at,created_at,updated_at";

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

  if (request.method === "GET") {
    let featureFlags: ResolvedFeatureFlagRow[];
    try {
      featureFlags = await resolveFeatureFlags(service, userRow.id);
    } catch (error) {
      // deno-coverage-ignore -- both API error surfaces are covered; message extraction branch is defensive.
      const message = error instanceof Error ? error.message : String(error);
      return jsonWithRequest(request, {
        error: "feature_flags_resolve_failed",
        detail: message,
      }, 500);
    }

    let row: SettingsRow;
    try {
      row = await fetchOrCreateSettings(service, userRow.id);
      row = await enforceGuardianFeatureFlag(service, row, featureFlags);
    } catch (error) {
      // deno-coverage-ignore -- both API error surfaces are covered; message extraction branch is defensive.
      const message = error instanceof Error ? error.message : String(error);
      return jsonWithRequest(request, {
        error: "settings_fetch_failed",
        detail: message,
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
  const payloadParse = parseWithSchema(
    NotificationSettingsPayloadSchema,
    payloadRaw,
  );
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: NotificationSettingsPayload = payloadParse.output;

  if (
    Object.prototype.hasOwnProperty.call(payload, "morning_brief_time_local")
  ) {
    const normalized = normalizeWallClockTime(payload.morning_brief_time_local);
    if (!normalized) {
      return jsonWithRequest(request, {
        error: "invalid_morning_brief_time_local",
      }, 400);
    }
  }
  if (Object.prototype.hasOwnProperty.call(payload, "quiet_hours_start")) {
    const normalized = normalizeWallClockTime(payload.quiet_hours_start);
    if (!normalized) {
      return jsonWithRequest(
        request,
        { error: "invalid_quiet_hours_start" },
        400,
      );
    }
  }
  if (Object.prototype.hasOwnProperty.call(payload, "quiet_hours_end")) {
    const normalized = normalizeWallClockTime(payload.quiet_hours_end);
    if (!normalized) {
      return jsonWithRequest(
        request,
        { error: "invalid_quiet_hours_end" },
        400,
      );
    }
  }

  let existing: SettingsRow;
  try {
    existing = await fetchOrCreateSettings(service, userRow.id);
  } catch (error) {
    // deno-coverage-ignore -- both API error surfaces are covered; message extraction branch is defensive.
    const message = error instanceof Error ? error.message : String(error);
    return jsonWithRequest(request, {
      error: "settings_fetch_failed",
      detail: message,
    }, 500);
  }

  const normalized = normalizePayload(payload);
  const nextCriticalOnly = normalized.critical_only ?? existing.critical_only;
  let featureFlags: ResolvedFeatureFlagRow[];
  try {
    featureFlags = await resolveFeatureFlags(service, userRow.id);
    // deno-coverage-ignore-start -- both API error surfaces are covered; message extraction branch is defensive.
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return jsonWithRequest(request, {
      error: "feature_flags_resolve_failed",
      detail: message,
    }, 500);
  }
  // deno-coverage-ignore-stop
  const guardianModeEnabled = isFeatureFlagEnabled(
    featureFlags,
    "guardian_mode_enabled",
  );

  // Invariant: critical-only mode always forces advisory + no Focus Control.
  if (nextCriticalOnly === true) {
    normalized.control_level = "advisory";
    normalized.focus_control_enabled = false;
  }

  let nextControlLevel = normalized.control_level ?? existing.control_level;
  let nextFocusControlEnabled = normalized.focus_control_enabled ??
    existing.focus_control_enabled;

  if (
    !guardianModeEnabled &&
    (nextControlLevel === "guardian" || nextFocusControlEnabled === true)
  ) {
    normalized.control_level = "protective";
    normalized.focus_control_enabled = false;
    nextControlLevel = "protective";
    nextFocusControlEnabled = false;
  }

  // Invariant: guardian requires Focus Control to be enabled.
  if (nextControlLevel === "guardian" && nextFocusControlEnabled !== true) {
    return jsonWithRequest(request, {
      error: "guardian_requires_focus_control",
    }, 400);
  }

  const { data: updated, error: upsertError } = await service
    .from("notification_settings")
    .upsert(
      {
        id: existing.id,
        user_id: userRow.id,
        ...normalized,
      },
      { onConflict: "user_id" },
    )
    .select(SETTINGS_SELECT)
    .single<SettingsRow>();

  if (upsertError) {
    return jsonWithRequest(request, {
      error: "settings_update_failed",
      detail: upsertError.message,
    }, 500);
  }

  return jsonWithRequest(request, toPublicSettings(updated));
});

async function fetchOrCreateSettings(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
): Promise<SettingsRow> {
  const existing = await fetchSettingsByUserId(service, userId);
  if (existing) {
    return existing;
  }

  const { data: created, error: createError } = await service
    .from("notification_settings")
    .insert({
      id: crypto.randomUUID(),
      user_id: userId,
      control_level: "advisory",
      focus_control_enabled: false,
    })
    .select(SETTINGS_SELECT)
    .single<SettingsRow>();

  if (createError) {
    if (isUniqueViolation(createError)) {
      const racedRow = await fetchSettingsByUserId(service, userId);
      if (racedRow) {
        return racedRow;
      }
    }
    throw createError;
  }

  return created;
}

async function resolveFeatureFlags(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
): Promise<ResolvedFeatureFlagRow[]> {
  const { data, error } = await service.rpc("resolve_feature_flags_for_user", {
    p_user_id: userId,
  });
  if (error) throw new Error(error.message);
  return mergeResolvedFeatureFlags((data ?? []) as ResolvedFeatureFlagRow[]);
}

async function enforceGuardianFeatureFlag(
  service: ReturnType<typeof serviceRoleClient>,
  row: SettingsRow,
  featureFlags: ResolvedFeatureFlagRow[],
): Promise<SettingsRow> {
  const guardianModeEnabled = isFeatureFlagEnabled(
    featureFlags,
    "guardian_mode_enabled",
  );

  if (
    guardianModeEnabled ||
    (row.control_level !== "guardian" && row.focus_control_enabled !== true)
  ) {
    return row;
  }

  const { data, error } = await service
    .from("notification_settings")
    .upsert(
      {
        id: row.id,
        user_id: row.user_id,
        control_level: "protective",
        focus_control_enabled: false,
      },
      { onConflict: "user_id" },
    )
    .select(SETTINGS_SELECT)
    .single<SettingsRow>();

  if (error) throw new Error(error.message);
  return data;
}

async function fetchSettingsByUserId(
  service: ReturnType<typeof serviceRoleClient>,
  userId: string,
): Promise<SettingsRow | null> {
  const { data, error } = await service
    .from("notification_settings")
    .select(SETTINGS_SELECT)
    .eq("user_id", userId)
    .maybeSingle<SettingsRow>();
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

function normalizePayload(
  payload: NotificationSettingsPayload,
): NotificationSettingsPayload {
  const normalized: NotificationSettingsPayload = {};

  if (typeof payload.morning_brief_enabled === "boolean") {
    normalized.morning_brief_enabled = payload.morning_brief_enabled;
  }
  if (typeof payload.positive_enabled === "boolean") {
    normalized.positive_enabled = payload.positive_enabled;
  }
  if (typeof payload.nudges_enabled === "boolean") {
    normalized.nudges_enabled = payload.nudges_enabled;
  }
  if (typeof payload.celebration_enabled === "boolean") {
    normalized.celebration_enabled = payload.celebration_enabled;
  }
  if (typeof payload.critical_only === "boolean") {
    normalized.critical_only = payload.critical_only;
  }

  const morningBrief = normalizeWallClockTime(payload.morning_brief_time_local);
  const quietStart = normalizeWallClockTime(payload.quiet_hours_start);
  const quietEnd = normalizeWallClockTime(payload.quiet_hours_end);
  if (morningBrief) normalized.morning_brief_time_local = morningBrief;
  if (quietStart) normalized.quiet_hours_start = quietStart;
  if (quietEnd) normalized.quiet_hours_end = quietEnd;

  if (typeof payload.max_positive_per_day === "number") {
    normalized.max_positive_per_day = Math.max(
      0,
      Math.min(3, Math.floor(payload.max_positive_per_day)),
    );
  }
  if (typeof payload.max_nudges_per_day === "number") {
    normalized.max_nudges_per_day = Math.max(
      0,
      Math.min(2, Math.floor(payload.max_nudges_per_day)),
    );
  }
  if (typeof payload.max_celebration_per_day === "number") {
    normalized.max_celebration_per_day = Math.max(
      0,
      Math.min(2, Math.floor(payload.max_celebration_per_day)),
    );
  }
  if (typeof payload.max_total_per_day === "number") {
    normalized.max_total_per_day = Math.max(
      1,
      Math.min(6, Math.floor(payload.max_total_per_day)),
    );
  }

  if (
    payload.control_level === "advisory" ||
    payload.control_level === "protective" ||
    payload.control_level === "guardian"
  ) {
    normalized.control_level = payload.control_level;
  }
  if (typeof payload.focus_control_enabled === "boolean") {
    normalized.focus_control_enabled = payload.focus_control_enabled;
  }

  return normalized;
}

function toPublicSettings(row: SettingsRow) {
  return {
    morning_brief_enabled: row.morning_brief_enabled,
    positive_enabled: row.positive_enabled,
    nudges_enabled: row.nudges_enabled,
    celebration_enabled: row.celebration_enabled,
    critical_only: row.critical_only,
    morning_brief_time_local: row.morning_brief_time_local,
    quiet_hours_start: row.quiet_hours_start,
    quiet_hours_end: row.quiet_hours_end,
    max_positive_per_day: row.max_positive_per_day,
    max_nudges_per_day: row.max_nudges_per_day,
    max_celebration_per_day: row.max_celebration_per_day,
    max_total_per_day: row.max_total_per_day,
    control_level: row.control_level,
    focus_control_enabled: row.focus_control_enabled,
    focus_control_last_granted_at: row.focus_control_last_granted_at,
  };
}

export const __notificationSettingsTestHooks = {
  enforceGuardianFeatureFlag,
  fetchOrCreateSettings,
  fetchSettingsByUserId,
  isUniqueViolation,
  normalizePayload,
  readErrorCode,
  resolveFeatureFlags,
  toPublicSettings,
};
