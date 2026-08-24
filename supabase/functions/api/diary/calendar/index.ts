import {
  enumerateLocalDates,
  parseLocalDateRange,
} from "../../../_shared/date_range.ts";
import {
  buildSupplementDayResult,
  type SupplementLogRow,
  type UserSupplementRow,
} from "../../../_shared/supplements.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface RecoveryRow {
  date: string;
  recovery_zone: string | null;
  confidence_score: number | null;
}

interface FoodRow {
  logged_date: string;
  needs_review: boolean;
  ai_confidence: number | null;
}

interface WorkoutRow {
  session_date: string;
}

interface PlannedRow {
  planned_date: string;
}

interface CatalogRow {
  id: string;
  name: string;
}

function diaryStatus(input: {
  hasRecovery: boolean;
  hasNutrition: boolean;
  hasTraining: boolean;
  hasSupplements: boolean;
  needsReview: boolean;
}): "no_data" | "incomplete" | "needs_review" | "complete" {
  const coverage = [
    input.hasRecovery,
    input.hasNutrition,
    input.hasTraining,
    input.hasSupplements,
  ].filter(Boolean).length;

  if (coverage === 0) return "no_data";
  if (input.needsReview) return "needs_review";
  if (coverage >= 3) return "complete";
  return "incomplete";
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

  const [
    recoveryRes,
    foodRes,
    workoutRes,
    plannedRes,
    supplementsRes,
    supplementLogsRes,
  ] = await Promise.all([
    service
      .from("physiological_states")
      .select("date,recovery_zone,confidence_score")
      .eq("user_id", userId)
      .gte("date", range.from)
      .lte("date", range.to)
      .returns<RecoveryRow[]>(),
    service
      .from("food_logs")
      .select("logged_date,needs_review,ai_confidence")
      .eq("user_id", userId)
      .gte("logged_date", range.from)
      .lte("logged_date", range.to)
      .is("deleted_at", null)
      .returns<FoodRow[]>(),
    service
      .from("workout_sessions")
      .select("session_date")
      .eq("user_id", userId)
      .gte("session_date", range.from)
      .lte("session_date", range.to)
      .is("deleted_at", null)
      .returns<WorkoutRow[]>(),
    service
      .from("training_plan_sessions")
      .select("planned_date")
      .eq("user_id", userId)
      .gte("planned_date", range.from)
      .lte("planned_date", range.to)
      .returns<PlannedRow[]>(),
    service
      .from("user_supplements")
      .select(
        "id,catalog_id,custom_name,frequency,scheduled_times,days_of_week,started_at,ended_at,active",
      )
      .eq("user_id", userId)
      .eq("active", true)
      .returns<UserSupplementRow[]>(),
    service
      .from("supplement_logs")
      .select(
        "id,user_supplement_id,supplement_name,scheduled_time,taken_at,taken_date",
      )
      .eq("user_id", userId)
      .gte("taken_date", range.from)
      .lte("taken_date", range.to)
      .is("deleted_at", null)
      .returns<SupplementLogRow[]>(),
  ]);

  for (
    const pair of [
      [recoveryRes.error, "recovery_fetch_failed"],
      [foodRes.error, "food_fetch_failed"],
      [workoutRes.error, "workout_fetch_failed"],
      [plannedRes.error, "planned_workout_fetch_failed"],
      [supplementsRes.error, "supplements_fetch_failed"],
      [supplementLogsRes.error, "supplement_logs_fetch_failed"],
    ] as const
  ) {
    if (pair[0]) {
      return jsonWithRequest(request, {
        error: pair[1],
        detail: pair[0].message,
      }, 500);
    }
  }

  const supplements = supplementsRes.data ?? [];
  const catalogIds = supplements
    .map((row) => row.catalog_id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);

  const catalogNameById = new Map<string, string>();
  if (catalogIds.length > 0) {
    const { data: catalogRows, error: catalogError } = await service
      .from("supplement_catalog")
      .select("id,name")
      .in("id", catalogIds)
      .returns<CatalogRow[]>();

    if (catalogError) {
      return jsonWithRequest(request, {
        error: "supplement_catalog_fetch_failed",
        detail: catalogError.message,
      }, 500);
    }

    for (const row of catalogRows ?? []) {
      catalogNameById.set(row.id, row.name);
    }
  }

  const recoveryMap = new Map<string, RecoveryRow>();
  for (const row of recoveryRes.data ?? []) {
    recoveryMap.set(row.date, row);
  }

  const foodMap = new Map<string, FoodRow[]>();
  for (const row of foodRes.data ?? []) {
    const list = foodMap.get(row.logged_date) ?? [];
    list.push(row);
    foodMap.set(row.logged_date, list);
  }

  const trainingMap = new Map<string, number>();
  for (const row of workoutRes.data ?? []) {
    trainingMap.set(
      row.session_date,
      (trainingMap.get(row.session_date) ?? 0) + 1,
    );
  }
  for (const row of plannedRes.data ?? []) {
    trainingMap.set(
      row.planned_date,
      (trainingMap.get(row.planned_date) ?? 0) + 1,
    );
  }

  const logsByDate = new Map<string, SupplementLogRow[]>();
  for (const row of supplementLogsRes.data ?? []) {
    const list = logsByDate.get(row.taken_date) ?? [];
    list.push(row);
    logsByDate.set(row.taken_date, list);
  }

  const days = enumerateLocalDates(range.from, range.to).map((date) => {
    const recovery = recoveryMap.get(date) ?? null;
    const foods = foodMap.get(date) ?? [];
    const supplementResult = buildSupplementDayResult(
      date,
      supplements,
      logsByDate.get(date) ?? [],
      catalogNameById,
    );

    const needsReview = foods.some((row) =>
      row.needs_review || (row.ai_confidence ?? 1) < 0.65
    );

    return {
      date,
      status: diaryStatus({
        hasRecovery: recovery != null,
        hasNutrition: foods.length > 0,
        hasTraining: (trainingMap.get(date) ?? 0) > 0,
        hasSupplements: supplementResult.scheduled_count > 0 ||
          supplementResult.unscheduled_logs.length > 0,
        needsReview,
      }),
      needs_review: needsReview,
      recovery_zone: recovery?.recovery_zone ?? null,
    };
  });

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    days,
  });
});
