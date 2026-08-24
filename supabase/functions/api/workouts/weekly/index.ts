import { parseLocalDateRange } from "../../../_shared/date_range.ts";
import { isLocalDate } from "../../../_shared/datetime.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

const MAX_WEEKS = 26;
const MAX_DAYS = MAX_WEEKS * 7;
const MS_PER_DAY = 86_400_000;

interface WorkoutSessionRow {
  session_date: string;
  duration_minutes: number | null;
  trimp_score: number | null;
}

interface WeeklyBucket {
  week_start: string;
  week_end: string;
  session_count: number;
  total_duration_minutes: number;
  total_trimp: number;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const range = parseLocalDateRange(request, MAX_DAYS);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  const { data: sessions, error: sessionsError } = await service
    .from("workout_sessions")
    .select("session_date,duration_minutes,trimp_score")
    .eq("user_id", userId)
    .gte("session_date", range.from)
    .lte("session_date", range.to)
    .is("deleted_at", null)
    .returns<WorkoutSessionRow[]>();

  if (sessionsError) {
    return jsonWithRequest(request, {
      error: "workout_weekly_fetch_failed",
      detail: sessionsError.message,
    }, 500);
  }

  const buckets = new Map<string, WeeklyBucket>();
  for (const session of sessions ?? []) {
    if (!isLocalDate(session.session_date)) continue;

    const weekStart = isoWeekStart(session.session_date);
    const bucket = buckets.get(weekStart) ?? {
      week_start: weekStart,
      week_end: addDays(weekStart, 6),
      session_count: 0,
      total_duration_minutes: 0,
      total_trimp: 0,
    };

    bucket.session_count += 1;
    bucket.total_duration_minutes += toNonNegativeNumber(
      session.duration_minutes,
    );
    bucket.total_trimp += toNonNegativeNumber(session.trimp_score);
    buckets.set(weekStart, bucket);
  }

  const weeks = [...buckets.values()]
    .sort((lhs, rhs) => lhs.week_start.localeCompare(rhs.week_start))
    .map((bucket) => ({
      ...bucket,
      total_trimp: roundOneDecimal(bucket.total_trimp),
      average_trimp: bucket.session_count > 0
        ? roundOneDecimal(bucket.total_trimp / bucket.session_count)
        : 0,
    }));

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    weeks,
  });
});

function isoWeekStart(date: string): string {
  const value = Date.parse(`${date}T00:00:00.000Z`);
  const day = new Date(value).getUTCDay();
  const offset = day === 0 ? -6 : 1 - day;
  return new Date(value + offset * MS_PER_DAY).toISOString().slice(0, 10);
}

function addDays(date: string, days: number): string {
  const value = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(value + days * MS_PER_DAY).toISOString().slice(0, 10);
}

function toNonNegativeNumber(value: number | null): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 0;
  return Math.max(0, value);
}

function roundOneDecimal(value: number): number {
  return Math.round(value * 10) / 10;
}
