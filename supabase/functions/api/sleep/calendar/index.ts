import {
  enumerateLocalDates,
  parseLocalDateRange,
} from "../../../_shared/date_range.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface SleepCalendarRow {
  date: string;
  sleep_score: number | null;
  sleep_duration_hours: number | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const range = parseLocalDateRange(request, 62);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  const { data, error } = await service
    .from("physiological_states")
    .select("date,sleep_score,sleep_duration_hours")
    .eq("user_id", userId)
    .gte("date", range.from)
    .lte("date", range.to)
    .returns<SleepCalendarRow[]>();

  if (error) {
    return jsonWithRequest(request, {
      error: "sleep_calendar_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  const byDate = new Map<string, SleepCalendarRow>();
  for (const row of data ?? []) {
    byDate.set(row.date, row);
  }

  const days = enumerateLocalDates(range.from, range.to).map((date) => {
    const row = byDate.get(date);
    const duration = row?.sleep_duration_hours ?? null;
    const score = row?.sleep_score ?? null;

    return {
      date,
      sleep_score: score,
      sleep_duration_hours: duration,
      status: sleepStatus(duration, score),
    };
  });

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    days,
  });
});

function sleepStatus(
  sleepDurationHours: number | null,
  sleepScore: number | null,
): "no_data" | "good" | "low" {
  if (sleepDurationHours == null) return "no_data";
  if ((sleepScore ?? 0) >= 70) return "good";
  return "low";
}
