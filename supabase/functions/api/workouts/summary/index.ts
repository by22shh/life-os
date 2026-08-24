import { localDateToday } from "../../../_shared/date_range.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

const DEFAULT_DAYS = 30;
const MAX_DAYS = 90;
const MS_PER_DAY = 86_400_000;

interface WorkoutSummarySessionRow {
  total_volume: number | null;
  trimp_score: number | null;
}

interface TrainingLoadRow {
  acwr: number | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const days = parseDays(request);
  if (!days) {
    return jsonWithRequest(request, { error: "invalid_days" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, timezone, service } = userResult.context;

  const to = localDateToday(timezone ?? "UTC");
  const from = addDays(to, 1 - days);

  const { data: sessions, error: sessionsError } = await service
    .from("workout_sessions")
    .select("total_volume,trimp_score")
    .eq("user_id", userId)
    .gte("session_date", from)
    .lte("session_date", to)
    .is("deleted_at", null)
    .returns<WorkoutSummarySessionRow[]>();

  if (sessionsError) {
    return jsonWithRequest(request, {
      error: "workout_summary_fetch_failed",
      detail: sessionsError.message,
    }, 500);
  }

  const { data: latestLoad, error: loadError } = await service
    .from("training_loads")
    .select("acwr")
    .eq("user_id", userId)
    .gte("date", from)
    .lte("date", to)
    .order("date", { ascending: false })
    .limit(1)
    .maybeSingle<TrainingLoadRow>();

  if (loadError) {
    return jsonWithRequest(request, {
      error: "training_load_fetch_failed",
      detail: loadError.message,
    }, 500);
  }

  const rows = sessions ?? [];
  const totalTrimp = rows.reduce(
    (sum, row) => sum + toNonNegativeNumber(row.trimp_score),
    0,
  );

  return jsonWithRequest(request, {
    range_days: days,
    workout_count: rows.length,
    total_volume: roundOneDecimal(
      rows.reduce(
        (sum, row) => sum + toNonNegativeNumber(row.total_volume),
        0,
      ),
    ),
    average_trimp: rows.length > 0
      ? roundOneDecimal(totalTrimp / rows.length)
      : 0,
    acwr: toNullableRoundedNumber(latestLoad?.acwr ?? null),
  });
});

function parseDays(request: Request): number | null {
  const raw = new URL(request.url).searchParams.get("days")?.trim() ?? "";
  if (!raw) return DEFAULT_DAYS;
  if (!/^\d+$/.test(raw)) return null;

  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > MAX_DAYS) return null;
  return value;
}

function addDays(date: string, days: number): string {
  const value = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(value + days * MS_PER_DAY).toISOString().slice(0, 10);
}

function toNonNegativeNumber(value: number | null): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  return Math.max(0, value);
}

function toNullableRoundedNumber(value: number | null): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return roundOneDecimal(value);
}

function roundOneDecimal(value: number): number {
  return Math.round(value * 10) / 10;
}
