import { isLocalDate } from "../../_shared/datetime.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

interface WeeklyStrategyReportRow {
  id: string;
  created_at: string;
  updated_at: string;
  week_start: string;
  week_end: string;
  report_markdown: string;
  summary_stats: Record<string, unknown>;
  model_used: string | null;
  prompt_version: string | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;

  const { userId, service } = userResult.context;
  const url = new URL(request.url);

  const weekStart = (url.searchParams.get("week_start") ?? "").trim();
  if (!isLocalDate(weekStart)) {
    return jsonWithRequest(request, { error: "invalid_week_start" }, 400);
  }

  const weekEnd = addDays(weekStart, 6);
  const reportModel = "local_heuristic";
  const promptVersion = "v1";

  const { data: existing, error: existingError } = await service
    .from("weekly_strategy_reports")
    .select(
      "id,created_at,updated_at,week_start,week_end,report_markdown,summary_stats,model_used,prompt_version",
    )
    .eq("user_id", userId)
    .eq("week_start", weekStart)
    .maybeSingle<WeeklyStrategyReportRow>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "weekly_strategy_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", existingError),
    }, 500);
  }

  const [recoveryRes, sleepRes, nutritionRes, workoutsRes] = await Promise.all([
    service
      .from("physiological_states")
      .select("date,recovery_score,recovery_zone,allostatic_load")
      .eq("user_id", userId)
      .gte("date", weekStart)
      .lte("date", weekEnd)
      .order("date", { ascending: true })
      .returns<
        Array<{
          date: string;
          recovery_score: number | null;
          recovery_zone: string | null;
          allostatic_load: number | null;
        }>
      >(),
    service
      .from("physiological_states")
      .select("date,sleep_duration_hours")
      .eq("user_id", userId)
      .gte("date", weekStart)
      .lte("date", weekEnd)
      .returns<Array<{ date: string; sleep_duration_hours: number | null }>>(),
    service
      .from("food_logs")
      .select("logged_date")
      .eq("user_id", userId)
      .gte("logged_date", weekStart)
      .lte("logged_date", weekEnd)
      .is("deleted_at", null)
      .returns<Array<{ logged_date: string }>>(),
    service
      .from("workout_sessions")
      .select("session_date,trimp_score")
      .eq("user_id", userId)
      .gte("session_date", weekStart)
      .lte("session_date", weekEnd)
      .is("deleted_at", null)
      .returns<Array<{ session_date: string; trimp_score: number | null }>>(),
  ]);

  for (
    const pair of [
      [recoveryRes.error, "recovery_fetch_failed"],
      [sleepRes.error, "sleep_fetch_failed"],
      [nutritionRes.error, "nutrition_fetch_failed"],
      [workoutsRes.error, "workouts_fetch_failed"],
    ] as const
  ) {
    if (pair[0]) {
      return jsonWithRequest(request, {
        error: pair[1],
        detail: sanitizedInternalDetail(request, "index", pair[0]),
      }, 500);
    }
  }

  const recoveryRows = recoveryRes.data ?? [];
  const sleepRows = sleepRes.data ?? [];
  const nutritionRows = nutritionRes.data ?? [];
  const workoutRows = workoutsRes.data ?? [];

  const recoveryScores = recoveryRows
    .map((row) => Number(row.recovery_score ?? 0))
    .filter((value) => Number.isFinite(value) && value > 0);

  const sleepValues = sleepRows
    .map((row) => Number(row.sleep_duration_hours ?? 0))
    .filter((value) => Number.isFinite(value) && value > 0);

  const nutritionDays = new Set(nutritionRows.map((row) => row.logged_date));
  const trainingVolume = workoutRows.reduce(
    (acc, row) => acc + Number(row.trimp_score ?? 0),
    0,
  );

  const avgRecovery = average(recoveryScores);
  const avgSleep = average(sleepValues);
  const allostaticLoad = average(
    recoveryRows
      .map((row) => Number(row.allostatic_load ?? 0))
      .filter((value) => Number.isFinite(value) && value > 0),
  );

  const daysInOptimal = recoveryRows.filter((row) =>
    row.recovery_zone === "optimal"
  ).length;
  const daysInCritical =
    recoveryRows.filter((row) => row.recovery_zone === "critical").length;

  const summaryStats = {
    avg_recovery_score: round2(avgRecovery),
    recovery_trend: trendLabel(recoveryScores),
    days_in_optimal_zone: daysInOptimal,
    days_in_critical_zone: daysInCritical,
    avg_sleep_duration: round2(avgSleep),
    sleep_consistency: round2(consistency(sleepValues)),
    nutrition_adherence: round2(nutritionDays.size / 7),
    training_volume: round2(trainingVolume),
    allostatic_load: round2(allostaticLoad),
  };

  const markdown = [
    `# Week ${weekStart} to ${weekEnd}`,
    "",
    "## Summary",
    `- Avg recovery score: ${summaryStats.avg_recovery_score}`,
    `- Recovery trend: ${summaryStats.recovery_trend}`,
    `- Avg sleep: ${summaryStats.avg_sleep_duration}h`,
    `- Nutrition adherence: ${
      Math.round(summaryStats.nutrition_adherence * 100)
    }%`,
    `- Training volume (TRIMP): ${summaryStats.training_volume}`,
    "",
    "## Focus",
    summaryStats.avg_recovery_score < 60
      ? "Prioritize rest days and sleep quality this week."
      : "Maintain current load while preserving sleep consistency.",
  ].join("\n");

  if (existing) {
    const { data: updated, error: updateError } = await service
      .from("weekly_strategy_reports")
      .update({
        week_end: weekEnd,
        summary_stats: summaryStats,
        report_markdown: markdown,
        model_used: reportModel,
        prompt_version: promptVersion,
      })
      .eq("id", existing.id)
      .eq("user_id", userId)
      .select(
        "id,created_at,updated_at,week_start,week_end,report_markdown,summary_stats,model_used,prompt_version",
      )
      .single<WeeklyStrategyReportRow>();

    if (updateError) {
      return jsonWithRequest(request, {
        error: "weekly_strategy_update_failed",
        detail: sanitizedInternalDetail(request, "index", updateError),
      }, 500);
    }
    if (!updated) {
      return jsonWithRequest(request, {
        error: "weekly_strategy_update_missing_row",
      }, 500);
    }

    return jsonWithRequest(request, makeResponse(updated));
  }

  const nowIso = new Date().toISOString();
  const { data: inserted, error: insertError } = await service
    .from("weekly_strategy_reports")
    .upsert({
      id: crypto.randomUUID(),
      user_id: userId,
      created_at: nowIso,
      updated_at: nowIso,
      week_start: weekStart,
      week_end: weekEnd,
      summary_stats: summaryStats,
      report_markdown: markdown,
      model_used: reportModel,
      prompt_version: promptVersion,
    }, { onConflict: "user_id,week_start" })
    .select(
      "id,created_at,updated_at,week_start,week_end,report_markdown,summary_stats,model_used,prompt_version",
    )
    .single<WeeklyStrategyReportRow>();

  if (insertError) {
    return jsonWithRequest(request, {
      error: "weekly_strategy_create_failed",
      detail: sanitizedInternalDetail(request, "index", insertError),
    }, 500);
  }
  if (!inserted) {
    return jsonWithRequest(request, {
      error: "weekly_strategy_create_missing_row",
    }, 500);
  }

  return jsonWithRequest(request, makeResponse(inserted));
});

function makeResponse(row: WeeklyStrategyReportRow) {
  return {
    report_id: row.id,
    created_at: row.created_at,
    updated_at: row.updated_at,
    week_start: row.week_start,
    week_end: row.week_end,
    report_markdown: row.report_markdown,
    summary_stats: row.summary_stats,
    model_used: row.model_used,
    prompt_version: row.prompt_version,
  };
}

function addDays(date: string, days: number): string {
  const parsed = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(parsed + days * 86_400_000).toISOString().slice(0, 10);
}

function average(values: number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((acc, value) => acc + value, 0) / values.length;
}

function consistency(values: number[]): number {
  if (values.length < 2) return 1;
  const avg = average(values);
  const variance = values.reduce((acc, value) => acc + (value - avg) ** 2, 0) /
    values.length;
  const stdDev = Math.sqrt(variance);
  return Math.max(0, Math.min(1, 1 - stdDev / 2));
}

function trendLabel(values: number[]): string {
  if (values.length < 2) return "stable";
  const first = values[0];
  const last = values[values.length - 1];
  if (last - first > 3) return "increasing";
  if (first - last > 3) return "decreasing";
  return "stable";
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
