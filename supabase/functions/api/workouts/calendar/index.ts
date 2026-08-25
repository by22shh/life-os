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

interface WorkoutSessionRow {
  session_date: string;
  duration_minutes: number | null;
  trimp_score: number | null;
}

interface PlannedSessionRow {
  planned_date: string;
  status: string;
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
      error: "workout_sessions_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", sessionsError),
    }, 500);
  }

  const { data: planned, error: plannedError } = await service
    .from("training_plan_sessions")
    .select("planned_date,status")
    .eq("user_id", userId)
    .gte("planned_date", range.from)
    .lte("planned_date", range.to)
    .returns<PlannedSessionRow[]>();

  if (plannedError) {
    return jsonWithRequest(request, {
      error: "planned_sessions_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", plannedError),
    }, 500);
  }

  const dayMap = new Map<string, {
    logged_count: number;
    planned_count: number;
    completed_planned_count: number;
    total_duration_minutes: number;
    total_trimp_score: number;
  }>();

  for (const row of sessions ?? []) {
    const entry = dayMap.get(row.session_date) ?? {
      logged_count: 0,
      planned_count: 0,
      completed_planned_count: 0,
      total_duration_minutes: 0,
      total_trimp_score: 0,
    };
    entry.logged_count += 1;
    entry.total_duration_minutes += Number(row.duration_minutes ?? 0);
    entry.total_trimp_score += Number(row.trimp_score ?? 0);
    dayMap.set(row.session_date, entry);
  }

  for (const row of planned ?? []) {
    const entry = dayMap.get(row.planned_date) ?? {
      logged_count: 0,
      planned_count: 0,
      completed_planned_count: 0,
      total_duration_minutes: 0,
      total_trimp_score: 0,
    };
    entry.planned_count += 1;
    if (row.status === "completed") {
      entry.completed_planned_count += 1;
    }
    dayMap.set(row.planned_date, entry);
  }

  const days = enumerateLocalDates(range.from, range.to).map((date) => {
    const entry = dayMap.get(date) ?? {
      logged_count: 0,
      planned_count: 0,
      completed_planned_count: 0,
      total_duration_minutes: 0,
      total_trimp_score: 0,
    };

    return {
      date,
      ...entry,
      has_logged_workout: entry.logged_count > 0,
      has_planned_workout: entry.planned_count > 0,
    };
  });

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    days,
  });
});
