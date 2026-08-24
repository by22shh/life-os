import { parseRequiredLocalDate } from "../../../_shared/date_range.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface WorkoutDailySessionRow {
  id: string;
  workout_type: string | null;
  duration_minutes: number | null;
  total_volume: number | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const range = parseRequiredLocalDate(request, "date");
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_date" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  const { data: sessions, error: sessionsError } = await service
    .from("workout_sessions")
    .select("id,workout_type,duration_minutes,total_volume")
    .eq("user_id", userId)
    .eq("session_date", range.from)
    .is("deleted_at", null)
    .order("started_at", { ascending: true })
    .returns<WorkoutDailySessionRow[]>();

  if (sessionsError) {
    return jsonWithRequest(request, {
      error: "workout_daily_fetch_failed",
      detail: sessionsError.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    date: range.from,
    sessions: sessions ?? [],
  });
});
