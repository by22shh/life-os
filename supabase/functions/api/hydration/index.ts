import {
  enumerateLocalDates,
  localDateToday,
  parseLocalDateParam,
  parseLocalDateRange,
  pathnameTail,
  safeTimeZone,
} from "../../_shared/date_range.ts";
import { isLocalDate } from "../../_shared/datetime.ts";
import { jsonWithRequest } from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

interface HydrationLogRow {
  id: string;
  logged_at: string;
  logged_date: string;
  water_ml: number;
  source: string;
  notes: string | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST", "PATCH", "DELETE"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const tail = pathnameTail(new URL(request.url).pathname);
  const route = (tail[0] ?? "").toLowerCase();

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { userId, timezone, service } = userResult.context;

  if (request.method === "GET" && route === "daily") {
    return await handleDaily(request, service, userId, safeTimeZone(timezone));
  }

  if (request.method === "GET" && route === "history") {
    return await handleHistory(request, service, userId);
  }

  if (request.method === "POST" && (route === "log" || route === "")) {
    return await handleCreate(request, service, userId, safeTimeZone(timezone));
  }

  if (request.method === "PATCH") {
    const logId = route === "log" ? (tail[1] ?? "") : route;
    if (!isUUID(logId)) {
      return jsonWithRequest(request, { error: "invalid_log_id" }, 400);
    }
    return await handlePatch(request, service, userId, logId);
  }

  if (request.method === "DELETE") {
    const logId = route === "log" ? (tail[1] ?? "") : route;
    if (!isUUID(logId)) {
      return jsonWithRequest(request, { error: "invalid_log_id" }, 400);
    }
    return await handleDelete(request, service, userId, logId);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleCreate(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const logId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());

  const loggedAt = parseTimestamp(payload.logged_at) ?? new Date();
  const loggedDate = typeof payload.logged_date === "string" &&
      isLocalDate(payload.logged_date)
    ? payload.logged_date
    : localDateToday(timezone);

  const waterMl = parseWaterAmount(payload.water_ml ?? payload.amount_ml);
  if (waterMl == null) {
    return jsonWithRequest(request, { error: "invalid_water_ml" }, 400);
  }

  const source = typeof payload.source === "string"
    ? payload.source.trim()
    : "manual";
  if (!["manual", "wearable", "import", "other"].includes(source)) {
    return jsonWithRequest(request, { error: "invalid_source" }, 400);
  }

  const { data: existing } = await service
    .from("hydration_logs")
    .select("id")
    .eq("id", logId)
    .eq("user_id", userId)
    .maybeSingle<{ id: string }>();

  if (existing) {
    return jsonWithRequest(
      request,
      { ok: true, id: existing.id, idempotent_replay: true },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  const { error } = await service
    .from("hydration_logs")
    .insert({
      id: logId,
      user_id: userId,
      logged_at: loggedAt.toISOString(),
      logged_date: loggedDate,
      logged_timezone: optionalString(payload.logged_timezone) ?? timezone,
      logged_utc_offset_minutes: toIntegerOrNull(
        payload.logged_utc_offset_minutes,
      ),
      water_ml: waterMl,
      source,
      notes: optionalString(payload.notes),
    });

  if (error) {
    return jsonWithRequest(request, {
      error: "hydration_log_create_failed",
      detail: error.message,
    }, 500);
  }

  return jsonWithRequest(request, { ok: true, id: logId });
}

async function handleDaily(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string,
): Promise<Response> {
  const date = parseLocalDateParam(request, "date") ?? localDateToday(timezone);

  const { data: logs, error } = await service
    .from("hydration_logs")
    .select("id,logged_at,logged_date,water_ml,source,notes")
    .eq("user_id", userId)
    .eq("logged_date", date)
    .is("deleted_at", null)
    .order("logged_at", { ascending: true })
    .returns<HydrationLogRow[]>();

  if (error) {
    return jsonWithRequest(request, {
      error: "hydration_logs_fetch_failed",
      detail: error.message,
    }, 500);
  }

  const totalWaterMl = (logs ?? []).reduce(
    (acc, row) => acc + Number(row.water_ml ?? 0),
    0,
  );

  return jsonWithRequest(request, {
    date,
    total_water_ml: totalWaterMl,
    goal_ml: 2500,
    entries: (logs ?? []).map((row) => ({
      id: row.id,
      logged_at: row.logged_at,
      water_ml: Number(row.water_ml ?? 0),
      source: row.source,
      notes: row.notes,
    })),
  });
}

async function handleHistory(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const range = parseLocalDateRange(request, 62);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const { data: logs, error } = await service
    .from("hydration_logs")
    .select("logged_date,water_ml")
    .eq("user_id", userId)
    .gte("logged_date", range.from)
    .lte("logged_date", range.to)
    .is("deleted_at", null)
    .returns<Array<{ logged_date: string; water_ml: number }>>();

  if (error) {
    return jsonWithRequest(request, {
      error: "hydration_history_fetch_failed",
      detail: error.message,
    }, 500);
  }

  const totalByDate = new Map<string, number>();
  for (const row of logs ?? []) {
    totalByDate.set(
      row.logged_date,
      (totalByDate.get(row.logged_date) ?? 0) + Number(row.water_ml ?? 0),
    );
  }

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    days: enumerateLocalDates(range.from, range.to).map((date) => ({
      date,
      total_water_ml: totalByDate.get(date) ?? 0,
      goal_ml: 2500,
    })),
  });
}

async function handlePatch(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  logId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const updates: Record<string, unknown> = {};

  if (
    Object.prototype.hasOwnProperty.call(payload, "water_ml") ||
    Object.prototype.hasOwnProperty.call(payload, "amount_ml")
  ) {
    const parsed = parseWaterAmount(payload.water_ml ?? payload.amount_ml);
    if (parsed == null) {
      return jsonWithRequest(request, { error: "invalid_water_ml" }, 400);
    }
    updates.water_ml = parsed;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "source")) {
    const source = typeof payload.source === "string"
      ? payload.source.trim()
      : "";
    if (!["manual", "wearable", "import", "other"].includes(source)) {
      return jsonWithRequest(request, { error: "invalid_source" }, 400);
    }
    updates.source = source;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "notes")) {
    updates.notes = optionalString(payload.notes);
  }

  if (Object.prototype.hasOwnProperty.call(payload, "logged_date")) {
    if (
      typeof payload.logged_date !== "string" ||
      !isLocalDate(payload.logged_date)
    ) {
      return jsonWithRequest(request, { error: "invalid_logged_date" }, 400);
    }
    updates.logged_date = payload.logged_date;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "logged_timezone")) {
    updates.logged_timezone = optionalString(payload.logged_timezone);
  }

  if (Object.keys(updates).length === 0) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  const { data, error } = await service
    .from("hydration_logs")
    .update(updates)
    .eq("id", logId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .select("id,logged_at,logged_date,water_ml,source,notes")
    .maybeSingle<HydrationLogRow>();

  if (error) {
    return jsonWithRequest(request, {
      error: "hydration_log_update_failed",
      detail: error.message,
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(request, { error: "hydration_log_not_found" }, 404);
  }

  return jsonWithRequest(request, {
    id: data.id,
    logged_at: data.logged_at,
    logged_date: data.logged_date,
    water_ml: data.water_ml,
    source: data.source,
    notes: data.notes,
  });
}

async function handleDelete(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  logId: string,
): Promise<Response> {
  const { data, error } = await service
    .from("hydration_logs")
    .update({
      deleted_at: new Date().toISOString(),
      deleted_reason: "user_deleted",
    })
    .eq("id", logId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .select("id")
    .maybeSingle<{ id: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "hydration_log_delete_failed",
      detail: error.message,
    }, 500);
  }

  if (!data) {
    return jsonWithRequest(request, { error: "hydration_log_not_found" }, 404);
  }

  return jsonWithRequest(request, { deleted: true, id: data.id });
}

function parseTimestamp(value: unknown): Date | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed;
}

function parseWaterAmount(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const amount = Math.trunc(value);
  if (amount < 1 || amount > 5000) return null;
  return amount;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function toIntegerOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.trunc(value);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
