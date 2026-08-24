import { parseRequiredLocalDate } from "../../../_shared/date_range.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface FoodLogRow {
  id: string;
  logged_at: string;
  logged_date: string;
  meal_type: string | null;
  input_method: string;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
  ai_confidence: number | null;
  needs_review: boolean;
}

interface NutritionTargetRow {
  final_calories: number | null;
  final_protein_g: number | null;
  final_fat_g: number | null;
  final_carbs_g: number | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const dateRange = parseRequiredLocalDate(request, "date");
  if (!dateRange) {
    return jsonWithRequest(request, { error: "invalid_date" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  const { data: logs, error: logsError } = await service
    .from("food_logs")
    .select(
      "id,logged_at,logged_date,meal_type,input_method,calories,protein_g,fat_g,carbs_g,fiber_g,ai_confidence,needs_review",
    )
    .eq("user_id", userId)
    .eq("logged_date", dateRange.from)
    .is("deleted_at", null)
    .order("logged_at", { ascending: true })
    .returns<FoodLogRow[]>();

  if (logsError) {
    return jsonWithRequest(request, {
      error: "food_logs_fetch_failed",
      detail: logsError.message,
    }, 500);
  }

  const { data: target, error: targetError } = await service
    .from("daily_nutrition_targets")
    .select("final_calories,final_protein_g,final_fat_g,final_carbs_g")
    .eq("user_id", userId)
    .eq("date", dateRange.from)
    .maybeSingle<NutritionTargetRow>();

  if (targetError) {
    return jsonWithRequest(request, {
      error: "nutrition_target_fetch_failed",
      detail: targetError.message,
    }, 500);
  }

  const rows = logs ?? [];
  const totals = rows.reduce(
    (acc, row) => {
      acc.calories += Number(row.calories ?? 0);
      acc.protein_g += Number(row.protein_g ?? 0);
      acc.fat_g += Number(row.fat_g ?? 0);
      acc.carbs_g += Number(row.carbs_g ?? 0);
      acc.fiber_g += Number(row.fiber_g ?? 0);
      if (row.needs_review || (row.ai_confidence ?? 1) < 0.65) {
        acc.needs_review_count += 1;
      }
      return acc;
    },
    {
      calories: 0,
      protein_g: 0,
      fat_g: 0,
      carbs_g: 0,
      fiber_g: 0,
      needs_review_count: 0,
    },
  );

  return jsonWithRequest(request, {
    date: dateRange.from,
    meal_count: rows.length,
    totals,
    target: {
      calories: target?.final_calories ?? null,
      protein_g: target?.final_protein_g ?? null,
      fat_g: target?.final_fat_g ?? null,
      carbs_g: target?.final_carbs_g ?? null,
    },
    meals: rows,
    needs_review: totals.needs_review_count > 0,
  });
});
