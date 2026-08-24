import {
  enumerateLocalDates,
  parseLocalDateRange,
} from "../../../_shared/date_range.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface FoodLogRow {
  logged_date: string;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  needs_review: boolean;
  ai_confidence: number | null;
}

interface TargetRow {
  date: string;
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

  const range = parseLocalDateRange(request, 62);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  const { data: logs, error: logsError } = await service
    .from("food_logs")
    .select(
      "logged_date,calories,protein_g,fat_g,carbs_g,needs_review,ai_confidence",
    )
    .eq("user_id", userId)
    .gte("logged_date", range.from)
    .lte("logged_date", range.to)
    .is("deleted_at", null)
    .returns<FoodLogRow[]>();

  if (logsError) {
    return jsonWithRequest(request, {
      error: "food_logs_fetch_failed",
      detail: logsError.message,
    }, 500);
  }

  const { data: targets, error: targetsError } = await service
    .from("daily_nutrition_targets")
    .select("date,final_calories,final_protein_g,final_fat_g,final_carbs_g")
    .eq("user_id", userId)
    .gte("date", range.from)
    .lte("date", range.to)
    .returns<TargetRow[]>();

  if (targetsError) {
    return jsonWithRequest(request, {
      error: "nutrition_targets_fetch_failed",
      detail: targetsError.message,
    }, 500);
  }

  const dayMap = new Map<string, {
    meal_count: number;
    total_calories: number;
    total_protein_g: number;
    total_fat_g: number;
    total_carbs_g: number;
    needs_review: boolean;
  }>();

  for (const row of logs ?? []) {
    const entry = dayMap.get(row.logged_date) ?? {
      meal_count: 0,
      total_calories: 0,
      total_protein_g: 0,
      total_fat_g: 0,
      total_carbs_g: 0,
      needs_review: false,
    };
    entry.meal_count += 1;
    entry.total_calories += Number(row.calories ?? 0);
    entry.total_protein_g += Number(row.protein_g ?? 0);
    entry.total_fat_g += Number(row.fat_g ?? 0);
    entry.total_carbs_g += Number(row.carbs_g ?? 0);
    entry.needs_review = entry.needs_review || row.needs_review ||
      (row.ai_confidence ?? 1) < 0.65;
    dayMap.set(row.logged_date, entry);
  }

  const targetMap = new Map<string, TargetRow>();
  for (const row of targets ?? []) {
    targetMap.set(row.date, row);
  }

  const days = enumerateLocalDates(range.from, range.to).map((date) => {
    const stats = dayMap.get(date) ?? {
      meal_count: 0,
      total_calories: 0,
      total_protein_g: 0,
      total_fat_g: 0,
      total_carbs_g: 0,
      needs_review: false,
    };
    const target = targetMap.get(date);

    return {
      date,
      ...stats,
      target_calories: target?.final_calories ?? null,
      target_protein_g: target?.final_protein_g ?? null,
      target_fat_g: target?.final_fat_g ?? null,
      target_carbs_g: target?.final_carbs_g ?? null,
    };
  });

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    days,
  });
});
