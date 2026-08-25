import {
  localDateToday,
  parseLocalDateParam,
  safeTimeZone,
} from "../../../_shared/date_range.ts";
import {
  buildSupplementDayResult,
  type SupplementLogRow,
  type UserSupplementRow,
} from "../../../_shared/supplements.ts";
import {
  determineNextBestAction,
  dueSupplementInWindow,
} from "../../../_shared/next_best_action.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface RecoveryRow {
  date: string;
  recovery_score: number | null;
  recovery_zone: string | null;
  data_completeness: number | null;
  confidence_score: number | null;
  sleep_duration_hours: number | null;
  deep_sleep_percent: number | null;
  rem_sleep_percent: number | null;
}

interface FoodRow {
  id: string;
  logged_at: string;
  meal_type: string | null;
  calories: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  needs_review: boolean;
  ai_confidence: number | null;
}

interface TargetRow {
  final_calories: number | null;
}

interface WorkoutRow {
  id: string;
  workout_type: string | null;
  duration_minutes: number | null;
  trimp_score: number | null;
}

interface PlannedRow {
  id: string;
  status: string;
}

interface CatalogRow {
  id: string;
  name: string;
}

interface InsightRow {
  id: string;
}

interface MedicalScanRow {
  id: string;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, timezone, service } = userResult.context;

  const resolvedTimezone = safeTimeZone(timezone);
  const date = parseLocalDateParam(request, "date") ??
    localDateToday(resolvedTimezone);

  const [
    recoveryRes,
    foodRes,
    targetRes,
    workoutRes,
    plannedRes,
    supplementsRes,
    supplementLogsRes,
    insightRes,
    labsRes,
  ] = await Promise.all([
    service
      .from("physiological_states")
      .select(
        "date,recovery_score,recovery_zone,data_completeness,confidence_score,sleep_duration_hours,deep_sleep_percent,rem_sleep_percent",
      )
      .eq("user_id", userId)
      .eq("date", date)
      .maybeSingle<RecoveryRow>(),
    service
      .from("food_logs")
      .select(
        "id,logged_at,meal_type,calories,protein_g,carbs_g,fat_g,needs_review,ai_confidence",
      )
      .eq("user_id", userId)
      .eq("logged_date", date)
      .is("deleted_at", null)
      .order("logged_at", { ascending: true })
      .returns<FoodRow[]>(),
    service
      .from("daily_nutrition_targets")
      .select("final_calories")
      .eq("user_id", userId)
      .eq("date", date)
      .maybeSingle<TargetRow>(),
    service
      .from("workout_sessions")
      .select("id,workout_type,duration_minutes,trimp_score")
      .eq("user_id", userId)
      .eq("session_date", date)
      .is("deleted_at", null)
      .returns<WorkoutRow[]>(),
    service
      .from("training_plan_sessions")
      .select("id,status")
      .eq("user_id", userId)
      .eq("planned_date", date)
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
      .eq("taken_date", date)
      .is("deleted_at", null)
      .returns<SupplementLogRow[]>(),
    service
      .from("insights")
      .select("id")
      .eq("user_id", userId)
      .eq("dismissed", false)
      .eq("read", false)
      .order("created_at", { ascending: false })
      .limit(1)
      .returns<InsightRow[]>(),
    service
      .from("medical_scans")
      .select("id")
      .eq("user_id", userId)
      .is("deleted_at", null)
      .or(
        "needs_review.eq.true,status.eq.review_required,extraction_status.in.(pending,processing,needs_review,review_required)",
      )
      .returns<MedicalScanRow[]>(),
  ]);

  for (
    const pair of [
      [recoveryRes.error, "recovery_fetch_failed"],
      [foodRes.error, "food_fetch_failed"],
      [targetRes.error, "nutrition_target_fetch_failed"],
      [workoutRes.error, "workout_fetch_failed"],
      [plannedRes.error, "planned_workout_fetch_failed"],
      [supplementsRes.error, "supplements_fetch_failed"],
      [supplementLogsRes.error, "supplement_logs_fetch_failed"],
      [insightRes.error, "insights_fetch_failed"],
      [labsRes.error, "labs_fetch_failed"],
    ] as const
  ) {
    if (pair[0]) {
      return jsonWithRequest(request, {
        error: pair[1],
        detail: sanitizedInternalDetail(request, "index", pair[0]),
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
        detail: sanitizedInternalDetail(request, "index", catalogError),
      }, 500);
    }

    for (const row of catalogRows ?? []) {
      catalogNameById.set(row.id, row.name);
    }
  }

  const supplementResult = buildSupplementDayResult(
    date,
    supplements,
    supplementLogsRes.data ?? [],
    catalogNameById,
  );

  const meals = foodRes.data ?? [];
  const nutritionTotals = meals.reduce(
    (acc, row) => {
      acc.calories += Number(row.calories ?? 0);
      acc.protein_g += Number(row.protein_g ?? 0);
      acc.carbs_g += Number(row.carbs_g ?? 0);
      acc.fat_g += Number(row.fat_g ?? 0);
      return acc;
    },
    {
      calories: 0,
      protein_g: 0,
      carbs_g: 0,
      fat_g: 0,
    },
  );

  const mealNeedsReview = meals.some((row) =>
    row.needs_review || (row.ai_confidence ?? 1) < 0.65
  );
  const confidenceScore = recoveryRes.data?.confidence_score ?? null;
  const lowConfidence = confidenceScore != null && confidenceScore < 0.65;
  const needsReview = mealNeedsReview || (labsRes.data?.length ?? 0) > 0;

  const hasRecovery = recoveryRes.data != null;
  const hasNutrition = meals.length > 0;
  const workouts = workoutRes.data ?? [];
  const plannedWorkouts = plannedRes.data ?? [];
  const hasTraining = workouts.length > 0 || plannedWorkouts.length > 0;
  const hasSupplements = supplementResult.scheduled_count > 0 ||
    supplementResult.unscheduled_logs.length > 0;

  const status = diaryStatus({
    hasRecovery,
    hasNutrition,
    hasTraining,
    hasSupplements,
    needsReview,
  });

  const now = new Date();
  const today = localDateToday(resolvedTimezone);
  const isToday = date === today;

  const nextAction = determineNextBestAction({
    date,
    needsReview,
    lowConfidence,
    sleepNeedsPermission: recoveryRes.data?.sleep_duration_hours == null,
    unreadInsightId: insightRes.data?.[0]?.id ?? null,
    supplementDueSoon: isToday
      ? dueSupplementInWindow(
        supplementResult.schedule,
        now,
        resolvedTimezone,
      )
      : null,
    nutritionCurrentCalories: nutritionTotals.calories,
    nutritionTargetCalories: targetRes.data?.final_calories ?? null,
    lastMealAt: meals.length > 0 ? meals[meals.length - 1].logged_at : null,
    isToday,
    timezone: resolvedTimezone,
  });

  const completedPlannedCount = plannedWorkouts.filter((row) =>
    row.status === "completed"
  ).length;

  return jsonWithRequest(request, {
    date,
    status,
    needs_review: needsReview,
    next_best_action: nextAction,
    recovery: {
      recovery_score: recoveryRes.data?.recovery_score ?? null,
      recovery_zone: recoveryRes.data?.recovery_zone ?? null,
      data_completeness: recoveryRes.data?.data_completeness ?? null,
      confidence_score: confidenceScore,
    },
    sleep: {
      duration_hours: recoveryRes.data?.sleep_duration_hours ?? null,
      deep_sleep_percent: recoveryRes.data?.deep_sleep_percent ?? null,
      rem_sleep_percent: recoveryRes.data?.rem_sleep_percent ?? null,
      needs_permission: recoveryRes.data?.sleep_duration_hours == null,
    },
    nutrition: {
      calories: {
        current: nutritionTotals.calories,
        target: targetRes.data?.final_calories ?? null,
      },
      macros: {
        protein_g: nutritionTotals.protein_g,
        carbs_g: nutritionTotals.carbs_g,
        fat_g: nutritionTotals.fat_g,
      },
      meals: meals.map((row) => ({
        id: row.id,
        meal_type: row.meal_type,
        logged_at: row.logged_at,
        calories: Number(row.calories ?? 0),
        needs_review: row.needs_review || (row.ai_confidence ?? 1) < 0.65,
      })),
    },
    training: {
      planned_count: plannedWorkouts.length,
      completed_count: Math.max(completedPlannedCount, workouts.length),
      sessions: workouts.map((row) => ({
        id: row.id,
        type: row.workout_type,
        duration_minutes: row.duration_minutes,
        daily_trimp: row.trimp_score,
        needs_review: false,
      })),
    },
    supplements: {
      adherence_today_percent: supplementResult.adherence_today_percent,
      schedule: supplementResult.schedule,
    },
    labs: {
      pending_review_count: (labsRes.data ?? []).length,
      recent_changes: [],
    },
  });
});

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
