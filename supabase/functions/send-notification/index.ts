import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../_shared/supabase.ts";
import { enforceRateLimit } from "../_shared/rate_limit.ts";
import { handleCors } from "../_shared/cors.ts";
import { parseWithSchema } from "../_shared/runtime_schema.ts";
import { SendNotificationPayloadSchema } from "../_shared/payload_schemas.ts";
import { dispatchAPNsNotifications } from "../_shared/apns.ts";

const HARD_DAILY_CAP = 6;
const DEDUP_SECONDS = 2 * 60 * 60;

type NotificationCategory =
  | "MORNING_BRIEF"
  | "SUPPLEMENT_REMINDER"
  | "MEAL_REMINDER"
  | "RECOVERY_ALERT"
  | "INSIGHT"
  | "CELEBRATION"
  | "EXPERIMENT";

type NotificationPriority = "passive" | "active" | "time_sensitive";

interface NotificationPayload {
  user_id?: string;
  title: string;
  body: string;
  category: NotificationCategory;
  priority: NotificationPriority;
  deep_link?: string;
  scheduled_at_local?: string;
  delivery_mode?: "remote_only" | "local_scheduled";
}

interface NotificationSettingsRow {
  user_id: string;
  critical_only: boolean;
  morning_brief_enabled: boolean;
  positive_enabled: boolean;
  nudges_enabled: boolean;
  celebration_enabled: boolean;
  quiet_hours_start: string;
  quiet_hours_end: string;
  max_total_per_day: number;
}

interface PushDeviceRow {
  push_token: string;
  environment: "development" | "production";
}

interface NotificationDispatchResponse {
  configured: boolean;
  attempted: number;
  sent: number;
  failed: number;
  invalid_tokens: string[];
  detail?: string;
  delivery_state:
    | "sent"
    | "partial"
    | "dispatch_failed"
    | "no_devices"
    | "not_configured"
    | "lookup_failed";
}

Deno.serve(async (request) => {
  // P1 #7: CORS preflight
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

  let payloadRaw: unknown;
  try {
    payloadRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const payloadParse = parseWithSchema(
    SendNotificationPayloadSchema,
    payloadRaw,
  );
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: NotificationPayload = payloadParse.output;
  if (payload.title.trim().length === 0 || payload.body.trim().length === 0) {
    return jsonWithRequest(request, { error: "missing_required_fields" }, 400);
  }

  const supabase = serviceRoleClient();

  const { data: userRow, error: userRowError } = await supabase
    .from("users")
    .select("id,timezone")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string; timezone: string | null }>();

  if (userRowError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userRowError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }

  // Backward compatibility: ignore body-level user_id and reject spoof attempts.
  if (payload.user_id && payload.user_id !== userRow.id) {
    return jsonWithRequest(request, { error: "forbidden_user_mismatch" }, 403);
  }
  const userId = userRow.id;

  const { data: settingsRow, error: settingsError } = await supabase
    .from("notification_settings")
    .select(
      "user_id,critical_only,morning_brief_enabled,positive_enabled,nudges_enabled,celebration_enabled,quiet_hours_start,quiet_hours_end,max_total_per_day",
    )
    .eq("user_id", userId)
    .maybeSingle<NotificationSettingsRow>();

  if (settingsError) {
    return jsonWithRequest(request, {
      error: "settings_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", settingsError),
    }, 500);
  }

  const settings: NotificationSettingsRow = settingsRow ?? {
    user_id: userId,
    critical_only: false,
    morning_brief_enabled: true,
    positive_enabled: true,
    nudges_enabled: true,
    celebration_enabled: true,
    quiet_hours_start: "22:00",
    quiet_hours_end: "07:00",
    max_total_per_day: HARD_DAILY_CAP,
  };

  if (
    settings.critical_only &&
    !(payload.category === "RECOVERY_ALERT" &&
      payload.priority === "time_sensitive")
  ) {
    return jsonWithRequest(request, {
      status: "dropped",
      reason: "critical_only",
    }, 200);
  }

  if (!isCategoryEnabled(payload.category, settings)) {
    return jsonWithRequest(request, {
      status: "dropped",
      reason: "category_disabled",
    }, 200);
  }

  const timezone = safeTimeZone(userRow.timezone ?? "UTC");
  let scheduledAt = payload.scheduled_at_local
    ? new Date(payload.scheduled_at_local)
    : new Date();

  if (Number.isNaN(scheduledAt.getTime())) {
    scheduledAt = new Date();
  }

  if (
    isInQuietHours(
      scheduledAt,
      timezone,
      settings.quiet_hours_start,
      settings.quiet_hours_end,
    )
  ) {
    if (payload.category === "MORNING_BRIEF") {
      scheduledAt = moveToQuietEnd(
        scheduledAt,
        timezone,
        settings.quiet_hours_end,
      );
    } else {
      return jsonWithRequest(request, {
        status: "dropped",
        reason: "quiet_hours",
      }, 200);
    }
  }

  const deliveredDateLocal = localDate(scheduledAt, timezone);
  const maxPerDay = Math.max(
    1,
    Math.min(HARD_DAILY_CAP, settings.max_total_per_day ?? HARD_DAILY_CAP),
  );
  const bypassDailyCap = payload.category === "RECOVERY_ALERT" &&
    payload.priority === "time_sensitive";
  const idempotencyKey = request.headers.get("Idempotency-Key");
  const notificationId = idempotencyKey && isUUID(idempotencyKey)
    ? idempotencyKey
    : crypto.randomUUID();
  const { data: insertStatusData, error: insertStatusError } = await supabase
    .rpc(
      "attempt_insert_notification_log",
      {
        p_id: notificationId,
        p_user_id: userId,
        p_category: payload.category,
        p_priority: payload.priority,
        p_title: payload.title,
        p_body: payload.body,
        p_deep_link: payload.deep_link ?? null,
        p_delivered_at: scheduledAt.toISOString(),
        p_delivered_date_local: deliveredDateLocal,
        p_timezone: timezone,
        p_dedup_seconds: DEDUP_SECONDS,
        p_max_per_day: maxPerDay,
        p_bypass_daily_cap: bypassDailyCap,
      },
    );

  if (insertStatusError) {
    return jsonWithRequest(request, {
      error: "notification_insert_failed",
      detail: sanitizedInternalDetail(request, "index", insertStatusError),
    }, 500);
  }

  const insertStatus = Array.isArray(insertStatusData)
    ? insertStatusData[0]
    : insertStatusData;
  switch (insertStatus) {
    case "accepted": {
      const dispatchSummary = await dispatchNotificationToDevices(
        request,
        supabase,
        userId,
        payload,
      );
      return jsonWithRequest(request, {
        status: "accepted",
        id: notificationId,
        dispatch: dispatchSummary,
        delivery_state: dispatchSummary.delivery_state,
      }, 202);
    }
    case "category_dedup":
      return jsonWithRequest(request, {
        status: "dropped",
        reason: "category_dedup",
      }, 200);
    case "daily_cap":
      return jsonWithRequest(request, {
        status: "dropped",
        reason: "daily_cap",
      }, 200);
    case "id_conflict":
      return jsonWithRequest(
        request,
        { error: "notification_id_conflict" },
        409,
      );
    default:
      return jsonWithRequest(request, {
        error: "notification_insert_unexpected_status",
        detail: String(insertStatus),
      }, 500);
  }
});

async function dispatchNotificationToDevices(
  request: Request,
  supabase: ReturnType<typeof serviceRoleClient>,
  userId: string,
  payload: NotificationPayload,
): Promise<NotificationDispatchResponse> {
  const { data: devices, error: devicesError } = await supabase
    .from("push_devices")
    .select("push_token,environment")
    .eq("user_id", userId)
    .is("revoked_at", null);

  if (devicesError) {
    return {
      configured: false,
      attempted: 0,
      sent: 0,
      failed: 0,
      invalid_tokens: [] as string[],
      detail: sanitizedInternalDetail(request, "index", devicesError),
      delivery_state: "lookup_failed",
    };
  }

  if ((devices ?? []).length === 0) {
    return {
      configured: true,
      attempted: 0,
      sent: 0,
      failed: 0,
      invalid_tokens: [],
      delivery_state: "no_devices",
    };
  }

  const dispatchSummary = await dispatchAPNsNotifications(
    ((devices ?? []) as PushDeviceRow[]).map((device) => ({
      pushToken: device.push_token,
      environment: device.environment,
      title: payload.title,
      body: payload.body,
      deepLink: payload.deep_link,
      interruptionLevel: interruptionLevelName(payload.priority),
    })),
  );

  if (dispatchSummary.invalidTokens.length > 0) {
    await supabase
      .from("push_devices")
      .update({ revoked_at: new Date().toISOString() })
      .eq("user_id", userId)
      .in("push_token", dispatchSummary.invalidTokens);
  }

  return {
    configured: dispatchSummary.configured,
    attempted: dispatchSummary.attempted,
    sent: dispatchSummary.sent,
    failed: dispatchSummary.failed,
    invalid_tokens: dispatchSummary.invalidTokens,
    delivery_state: resolveDeliveryState(dispatchSummary),
  };
}

function resolveDeliveryState(
  dispatchSummary: {
    configured: boolean;
    attempted: number;
    sent: number;
    failed: number;
  },
): NotificationDispatchResponse["delivery_state"] {
  if (!dispatchSummary.configured) {
    return "not_configured";
  }
  if (dispatchSummary.attempted === 0) {
    return "no_devices";
  }
  if (dispatchSummary.sent > 0 && dispatchSummary.failed > 0) {
    return "partial";
  }
  if (dispatchSummary.sent > 0) {
    return "sent";
  }
  return "dispatch_failed";
}

function isCategoryEnabled(
  category: NotificationCategory,
  settings: NotificationSettingsRow,
): boolean {
  switch (category) {
    case "MORNING_BRIEF":
      return settings.morning_brief_enabled;
    case "SUPPLEMENT_REMINDER":
    case "MEAL_REMINDER":
      return settings.nudges_enabled;
    case "INSIGHT":
    case "EXPERIMENT":
      return settings.positive_enabled;
    case "CELEBRATION":
      return settings.celebration_enabled;
    case "RECOVERY_ALERT":
      return true;
  }
}

function interruptionLevelName(
  priority: NotificationPriority,
): "passive" | "active" | "time-sensitive" {
  switch (priority) {
    case "passive":
      return "passive";
    case "active":
      return "active";
    case "time_sensitive":
      return "time-sensitive";
  }
}

function parseHHMM(value: string): number | null {
  const trimmed = value.trim();
  const match = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(trimmed);
  if (!match) return null;

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3] ?? "0");
  if (
    !Number.isInteger(hours) || !Number.isInteger(minutes) ||
    !Number.isInteger(seconds) ||
    hours < 0 || hours > 23 ||
    minutes < 0 || minutes > 59 ||
    seconds < 0 || seconds > 59
  ) {
    return null;
  }

  return (hours * 60) + minutes;
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function localClockMinutes(date: Date, timezone: string): number {
  const formatter = new Intl.DateTimeFormat("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: timezone,
  });
  const [hours, minutes] = formatter.format(date).split(":").map(Number);
  return (hours ?? 0) * 60 + (minutes ?? 0);
}

function localDate(date: Date, timezone: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: timezone,
  }).format(date);
}

function safeTimeZone(value: string): string {
  try {
    new Intl.DateTimeFormat("en-GB", { timeZone: value }).format(new Date());
    return value;
  } catch {
    return "UTC";
  }
}

function isInQuietHours(
  date: Date,
  timezone: string,
  startHHMM: string,
  endHHMM: string,
): boolean {
  const now = localClockMinutes(date, timezone);
  const start = parseHHMM(startHHMM);
  const end = parseHHMM(endHHMM);
  if (start == null || end == null) return false;

  if (start <= end) {
    return now >= start && now < end;
  }
  return now >= start || now < end;
}

// P1 #10: DST-aware version — uses Intl to resolve the target wall-clock time
// in the user's timezone, avoiding ±1h drift on DST transitions.
function moveToQuietEnd(
  date: Date,
  timezone: string,
  quietEndHHMM: string,
): Date {
  const targetMinutes = parseHHMM(quietEndHHMM);
  if (targetMinutes == null) {
    return new Date(date.getTime() + 8 * 60 * 60 * 1000);
  }
  let candidate = new Date(date.getTime() + 60 * 1000);

  // Search up to 48h to handle DST transitions and timezone changes safely.
  for (let i = 0; i < 48 * 60; i++) {
    if (localClockMinutes(candidate, timezone) === targetMinutes) {
      candidate.setSeconds(0, 0);
      return candidate;
    }
    candidate = new Date(candidate.getTime() + 60 * 1000);
  }

  // Conservative fallback.
  return new Date(date.getTime() + 8 * 60 * 60 * 1000);
}
