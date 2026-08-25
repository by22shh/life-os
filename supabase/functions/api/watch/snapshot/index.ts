import { localDateToday, safeTimeZone } from "../../../_shared/date_range.ts";
import {
  adaptNextBestActionForWatch,
  computeNutritionAdherencePercent,
  determineNextBestAction,
  dueSupplementInWindow,
  dueSupplementsSummary,
  type WatchNextBestAction,
} from "../../../_shared/next_best_action.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { WatchSnapshotPostBodySchema } from "../../../_shared/payload_schemas.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import {
  buildSupplementDayResult,
  type SupplementLogRow,
  type UserSupplementRow,
} from "../../../_shared/supplements.ts";

interface RecoveryRow {
  date: string;
  recovery_score: number | null;
  confidence_score: number | null;
  sleep_duration_hours: number | null;
  sleep_quality_percent: number | null;
  updated_at: string | null;
}

interface FoodRow {
  logged_at: string;
  calories: number;
  protein_g: number;
  needs_review: boolean;
  ai_confidence: number | null;
}

interface TargetRow {
  final_calories: number | null;
  final_protein_g: number | null;
}

interface InsightRow {
  id: string;
}

interface MedicalScanRow {
  id: string;
}

interface CatalogRow {
  id: string;
  name: string;
}

type UserRow = { id: string; timezone: string | null };

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "GET" && request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const userClient = anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  let date = new URL(request.url).searchParams.get("date");
  if (!date && request.method === "POST") {
    try {
      const bodyRaw = await request.json();
      const bodyParse = parseWithSchema(WatchSnapshotPostBodySchema, bodyRaw);
      if (!bodyParse.ok) {
        return jsonWithRequest(request, {
          error: "invalid_payload",
          issues: bodyParse.issues,
        }, 400);
      }
      if (typeof bodyParse.output.date === "string") {
        date = bodyParse.output.date;
      }
    } catch {
      // no-op
    }
  }
  if (date && !isIsoDate(date)) {
    return jsonWithRequest(request, { error: "invalid_date" }, 400);
  }

  const service = serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id,timezone")
    .eq("auth_id", authData.user.id)
    .maybeSingle<UserRow>();

  if (userLookupError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userLookupError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }

  const timezone = safeTimeZone(userRow.timezone);
  const resolvedDate = date ?? localDateToday(timezone);
  const today = localDateToday(timezone);
  const isToday = resolvedDate === today;

  const [
    recoveryRes,
    foodRes,
    targetRes,
    supplementsRes,
    supplementLogsRes,
    insightRes,
    labsRes,
  ] = await Promise.all([
    service
      .from("physiological_states")
      .select(
        "date,recovery_score,confidence_score,sleep_duration_hours,sleep_quality_percent,updated_at",
      )
      .eq("user_id", userRow.id)
      .eq("date", resolvedDate)
      .maybeSingle<RecoveryRow>(),
    service
      .from("food_logs")
      .select("logged_at,calories,protein_g,needs_review,ai_confidence")
      .eq("user_id", userRow.id)
      .eq("logged_date", resolvedDate)
      .is("deleted_at", null)
      .order("logged_at", { ascending: true })
      .returns<FoodRow[]>(),
    service
      .from("daily_nutrition_targets")
      .select("final_calories,final_protein_g")
      .eq("user_id", userRow.id)
      .eq("date", resolvedDate)
      .maybeSingle<TargetRow>(),
    service
      .from("user_supplements")
      .select(
        "id,catalog_id,custom_name,frequency,scheduled_times,days_of_week,started_at,ended_at,active",
      )
      .eq("user_id", userRow.id)
      .eq("active", true)
      .returns<UserSupplementRow[]>(),
    service
      .from("supplement_logs")
      .select(
        "id,user_supplement_id,supplement_name,scheduled_time,taken_at,taken_date",
      )
      .eq("user_id", userRow.id)
      .eq("taken_date", resolvedDate)
      .is("deleted_at", null)
      .returns<SupplementLogRow[]>(),
    service
      .from("insights")
      .select("id")
      .eq("user_id", userRow.id)
      .eq("dismissed", false)
      .eq("acknowledged", false)
      .eq("read", false)
      .order("created_at", { ascending: false })
      .limit(1)
      .returns<InsightRow[]>(),
    service
      .from("medical_scans")
      .select("id")
      .eq("user_id", userRow.id)
      .is("deleted_at", null)
      .or(
        "needs_review.eq.true,status.eq.review_required,extraction_status.in.(pending,processing,needs_review,review_required)",
      )
      .returns<MedicalScanRow[]>(),
  ]);

  for (
    const pair of [
      [recoveryRes.error, "snapshot_fetch_failed"],
      [foodRes.error, "food_fetch_failed"],
      [targetRes.error, "nutrition_target_fetch_failed"],
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
    resolvedDate,
    supplements,
    supplementLogsRes.data ?? [],
    catalogNameById,
  );
  const meals = foodRes.data ?? [];
  const nutritionTotals = meals.reduce(
    (acc, row) => {
      acc.calories += Number(row.calories ?? 0);
      acc.proteinG += Number(row.protein_g ?? 0);
      return acc;
    },
    { calories: 0, proteinG: 0 },
  );
  const mealNeedsReview = meals.some((row) =>
    row.needs_review || (row.ai_confidence ?? 1) < 0.65
  );
  const needsReview = mealNeedsReview || (labsRes.data?.length ?? 0) > 0;
  const confidence = recoveryRes.data?.confidence_score ?? null;
  const lowConfidence = confidence != null && confidence < 0.65;
  const dueSoon = isToday
    ? dueSupplementInWindow(supplementResult.schedule, new Date(), timezone)
    : null;
  const diaryAction = determineNextBestAction({
    date: resolvedDate,
    needsReview,
    lowConfidence,
    supplementDueSoon: dueSoon,
    nutritionCurrentCalories: nutritionTotals.calories,
    nutritionTargetCalories: targetRes.data?.final_calories ?? null,
    lastMealAt: meals.length > 0 ? meals[meals.length - 1].logged_at : null,
    sleepNeedsPermission: recoveryRes.data?.sleep_duration_hours == null,
    unreadInsightId: insightRes.data?.[0]?.id ?? null,
    isToday,
    timezone,
  });
  const nextBestAction: WatchNextBestAction = adaptNextBestActionForWatch({
    action: diaryAction,
    date: resolvedDate,
    lowConfidence,
  });
  const response: Record<string, unknown> = {
    date: recoveryRes.data?.date ?? resolvedDate,
    last_updated_at: recoveryRes.data?.updated_at ?? new Date().toISOString(),
    recovery_score: recoveryRes.data?.recovery_score ?? null,
    recovery_zone: zoneFromScore(recoveryRes.data?.recovery_score ?? null),
    confidence_score: confidence,
    next_best_action: nextBestAction,
  };

  if (recoveryRes.data?.sleep_duration_hours != null) {
    response.sleep_duration_hours = recoveryRes.data.sleep_duration_hours;
  }
  if (recoveryRes.data?.sleep_quality_percent != null) {
    response.sleep_quality_percent = recoveryRes.data.sleep_quality_percent;
  }

  const nutritionAdherencePercent = computeNutritionAdherencePercent({
    currentCalories: nutritionTotals.calories,
    targetCalories: targetRes.data?.final_calories ?? null,
    currentProteinG: nutritionTotals.proteinG,
    targetProteinG: targetRes.data?.final_protein_g ?? null,
  });
  if (nutritionAdherencePercent != null) {
    response.nutrition_adherence_percent = nutritionAdherencePercent;
  }

  const supplementsDueSoon = isToday
    ? dueSupplementsSummary(supplementResult.schedule, new Date(), timezone)
    : null;
  if (supplementsDueSoon) {
    response.supplements_due_soon = supplementsDueSoon;
  }

  return jsonWithRequest(request, response);
});

function zoneFromScore(
  score: number | null,
): "optimal" | "ready" | "caution" | "critical" | null {
  if (score == null) return null;
  if (score >= 75) return "optimal";
  if (score >= 50) return "ready";
  if (score >= 25) return "caution";
  return "critical";
}

function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime())) return false;
  return parsed.toISOString().slice(0, 10) === value;
}
