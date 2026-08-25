import {
  localDateToday,
  parseLocalDateParam,
  pathnameTail,
  safeTimeZone,
} from "../../../_shared/date_range.ts";
import { isLocalDate } from "../../../_shared/datetime.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface BatchRecipeRow {
  id: string;
  name: string;
  description: string | null;
  image_url: string | null;
  cooked_at: string | null;
  total_weight_g: number;
  total_portions: number | null;
  total_calories: number;
  total_protein_g: number;
  total_fat_g: number;
  total_carbs_g: number;
  total_fiber_g: number | null;
  calories_per_100g: number | null;
  protein_per_100g: number | null;
  fat_per_100g: number | null;
  carbs_per_100g: number | null;
  archived: boolean;
  times_used: number;
  last_used_at: string | null;
  updated_at: string;
}

interface BatchIngredientRow {
  id: string;
  batch_recipe_id: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  catalog_item_id: string | null;
  user_food_id: string | null;
  weight_g: number;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
  sort_order: number;
}

interface ConsumptionItemRow {
  batch_recipe_id: string | null;
  food_log_id: string;
  weight_g: number;
}

interface FoodLogStateRow {
  id: string;
  deleted_at: string | null;
}

interface FoodLogUsageRow {
  id: string;
  logged_at: string;
  deleted_at: string | null;
}

const VALID_MEAL_TYPES = new Set(["breakfast", "lunch", "dinner", "snack"]);
const VALID_CONTEXTS = new Set([
  "home",
  "restaurant",
  "party",
  "work",
  "other",
  "unknown",
]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST", "PATCH"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;
  const { userId, timezone, service } = userResult.context;

  const url = new URL(request.url);
  const tail = pathnameTail(url.pathname);
  const batchId = url.searchParams.get("id")?.trim() || (tail[0] ?? "");
  const action = (tail[1] ?? "").toLowerCase();

  if (request.method === "GET") {
    if (batchId) {
      if (!isUUID(batchId)) {
        return jsonWithRequest(request, { error: "invalid_batch_id" }, 400);
      }
      return await handleGetDetail(request, service, userId, batchId);
    }
    return await handleList(request, service, userId, url);
  }

  if (request.method === "PATCH") {
    if (!isUUID(batchId)) {
      return jsonWithRequest(request, { error: "invalid_batch_id" }, 400);
    }
    return await handlePatch(request, service, userId, batchId);
  }

  if (request.method === "POST" && isUUID(batchId) && action === "log") {
    return await handleLog(request, service, userId, timezone, batchId);
  }

  if (request.method === "POST" && isUUID(batchId) && action === "duplicate") {
    return await handleDuplicate(request, service, userId, timezone, batchId);
  }

  if (request.method === "POST" && tail.length === 0) {
    return await handleCreate(request, service, userId);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleList(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  url: URL,
): Promise<Response> {
  const status = (url.searchParams.get("status") ?? "active").trim()
    .toLowerCase();
  if (!["active", "archived"].includes(status)) {
    return jsonWithRequest(request, { error: "invalid_status" }, 400);
  }

  const rawLimit = Number(url.searchParams.get("limit") ?? "20");
  const limit = Number.isFinite(rawLimit)
    ? Math.max(1, Math.min(50, Math.floor(rawLimit)))
    : 20;

  let query = service
    .from("batch_recipes")
    .select(
      "id,name,description,image_url,cooked_at,total_weight_g,total_portions,total_calories,total_protein_g,total_fat_g,total_carbs_g,total_fiber_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,archived,times_used,last_used_at,updated_at",
    )
    .eq("user_id", userId)
    .eq("archived", status === "archived")
    .is("deleted_at", null)
    .returns<BatchRecipeRow[]>();

  if (status === "archived") {
    query = query.order("updated_at", { ascending: false });
  } else {
    query = query
      .order("cooked_at", { ascending: false, nullsFirst: false })
      .order("updated_at", { ascending: false });
  }

  query = query.limit(limit);

  const { data, error } = await query;
  if (error) {
    return jsonWithRequest(request, {
      error: "batch_list_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  const rows = (data ?? []).sort((lhs, rhs) =>
    compareBatchRows(lhs, rhs, status)
  );
  const consumed = await loadConsumedWeightMap(
    service,
    userId,
    rows.map((row) => row.id),
  );

  return jsonWithRequest(request, {
    results: rows.map((row) =>
      buildBatchSummary(row, consumed.get(row.id) ?? 0)
    ),
  });
}

async function handleGetDetail(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  batchId: string,
): Promise<Response> {
  const { data: row, error } = await service
    .from("batch_recipes")
    .select(
      "id,name,description,image_url,cooked_at,total_weight_g,total_portions,total_calories,total_protein_g,total_fat_g,total_carbs_g,total_fiber_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,archived,times_used,last_used_at,updated_at",
    )
    .eq("id", batchId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<BatchRecipeRow>();

  if (error) {
    return jsonWithRequest(request, {
      error: "batch_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }
  if (!row) {
    return jsonWithRequest(request, { error: "batch_not_found" }, 404);
  }

  const { data: ingredients, error: ingredientsError } = await service
    .from("batch_recipe_ingredients")
    .select(
      "id,batch_recipe_id,name,brand,barcode,catalog_item_id,user_food_id,weight_g,calories,protein_g,fat_g,carbs_g,fiber_g,sort_order",
    )
    .eq("batch_recipe_id", batchId)
    .order("sort_order", { ascending: true })
    .returns<BatchIngredientRow[]>();

  if (ingredientsError) {
    return jsonWithRequest(request, {
      error: "batch_ingredients_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", ingredientsError),
    }, 500);
  }

  const consumed = await loadConsumedWeightMap(service, userId, [batchId]);
  const response = buildBatchSummary(row, consumed.get(batchId) ?? 0);
  return jsonWithRequest(request, {
    ...response,
    description: row.description,
    image_url: row.image_url,
    ingredients: (ingredients ?? []).map(mapIngredientResponse),
  });
}

async function handleCreate(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const payload = await readJsonObject(request);
  if (!payload) {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const parsed = parseBatchDraft(payload);
  if (!parsed.ok) {
    return jsonWithRequest(request, { error: parsed.error }, 400);
  }

  const batchId = parsed.batchId;
  const { data: existing, error: existingLookupError } = await service
    .from("batch_recipes")
    .select("id")
    .eq("id", batchId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<{ id: string }>();
  if (existingLookupError) {
    return jsonWithRequest(request, {
      error: "batch_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", existingLookupError),
    }, 500);
  }

  const draft = parsed.draft;
  const batchWriteFields = makeBatchWriteFields({
    name: draft.name,
    description: draft.description,
    imageUrl: null,
    cookedAt: draft.cooked_at,
    totalWeightG: draft.total_weight_g,
    totalPortions: draft.total_portions,
    archived: false,
    totals: computeIngredientTotals(draft.ingredients),
  });
  const batchInsert = {
    id: batchId,
    user_id: userId,
    ...batchWriteFields,
  };

  if (existing) {
    const { error: updateError } = await service
      .from("batch_recipes")
      .update(batchWriteFields)
      .eq("id", batchId)
      .eq("user_id", userId)
      .is("deleted_at", null);

    if (updateError) {
      return jsonWithRequest(request, {
        error: "batch_create_failed",
        detail: sanitizedInternalDetail(request, "index", updateError),
      }, 500);
    }

    const ingredientError = await replaceBatchIngredients(
      service,
      batchId,
      draft.ingredients,
    );
    if (ingredientError) {
      return jsonWithRequest(request, {
        error: "batch_ingredients_create_failed",
        detail: sanitizedInternalDetail(request, "index", ingredientError),
      }, 500);
    }

    return jsonWithRequest(
      request,
      { id: batchId, idempotent_replay: true },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  const { error: insertError } = await service
    .from("batch_recipes")
    .insert(batchInsert);

  if (insertError) {
    return jsonWithRequest(request, {
      error: "batch_create_failed",
      detail: sanitizedInternalDetail(request, "index", insertError),
    }, 500);
  }

  const ingredientError = await replaceBatchIngredients(
    service,
    batchId,
    draft.ingredients,
  );
  if (ingredientError) {
    return jsonWithRequest(request, {
      error: "batch_ingredients_create_failed",
      detail: sanitizedInternalDetail(request, "index", ingredientError),
    }, 500);
  }

  return jsonWithRequest(request, { id: batchId }, 201);
}

async function handlePatch(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  batchId: string,
): Promise<Response> {
  const { data: existing, error: existingError } = await service
    .from("batch_recipes")
    .select(
      "id,name,description,image_url,cooked_at,total_weight_g,total_portions,total_calories,total_protein_g,total_fat_g,total_carbs_g,total_fiber_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,archived,times_used,last_used_at,updated_at",
    )
    .eq("id", batchId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<BatchRecipeRow>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "batch_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", existingError),
    }, 500);
  }
  if (!existing) {
    return jsonWithRequest(request, { error: "batch_not_found" }, 404);
  }

  const payload = await readJsonObject(request);
  if (!payload) {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const updates: Record<string, unknown> = {};

  if (Object.prototype.hasOwnProperty.call(payload, "name")) {
    const name = readOptionalTrimmedString(payload.name);
    if (!name) return jsonWithRequest(request, { error: "name_required" }, 400);
    updates.name = name;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "description")) {
    updates.description = readOptionalNullableString(payload.description);
  }

  if (Object.prototype.hasOwnProperty.call(payload, "image_url")) {
    updates.image_url = readOptionalNullableString(payload.image_url);
  }

  if (Object.prototype.hasOwnProperty.call(payload, "cooked_at")) {
    const cookedAt = readOptionalNullableString(payload.cooked_at);
    if (cookedAt && !isLocalDate(cookedAt)) {
      return jsonWithRequest(request, { error: "invalid_cooked_at" }, 400);
    }
    updates.cooked_at = cookedAt || null;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "total_weight_g")) {
    const totalWeight = readRequiredNumber(payload.total_weight_g);
    if (totalWeight == null || totalWeight <= 0) {
      return jsonWithRequest(request, { error: "invalid_total_weight_g" }, 400);
    }
    updates.total_weight_g = totalWeight;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "total_portions")) {
    if (payload.total_portions == null) {
      updates.total_portions = null;
    } else if (
      typeof payload.total_portions === "number" &&
      Number.isInteger(payload.total_portions) &&
      payload.total_portions > 0
    ) {
      updates.total_portions = payload.total_portions;
    } else {
      return jsonWithRequest(request, { error: "invalid_total_portions" }, 400);
    }
  }

  if (Object.prototype.hasOwnProperty.call(payload, "archived")) {
    if (typeof payload.archived !== "boolean") {
      return jsonWithRequest(request, { error: "invalid_archived" }, 400);
    }
    updates.archived = payload.archived;
  }

  let parsedIngredients: ParsedIngredient[] | null = null;
  if (Object.prototype.hasOwnProperty.call(payload, "ingredients")) {
    const parsed = parseIngredients(payload.ingredients);
    if (!parsed.ok) {
      return jsonWithRequest(request, { error: parsed.error }, 400);
    }
    parsedIngredients = parsed.ingredients;
    const totals = computeIngredientTotals(parsedIngredients);
    updates.total_calories = totals.calories;
    updates.total_protein_g = totals.protein_g;
    updates.total_fat_g = totals.fat_g;
    updates.total_carbs_g = totals.carbs_g;
    updates.total_fiber_g = totals.fiber_g;
  }

  const hasExplicitUpdates = Object.keys(updates).length > 0 ||
    parsedIngredients != null;
  if (!hasExplicitUpdates) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  const nextTotals = parsedIngredients == null
    ? {
      calories: Number(existing.total_calories ?? 0),
      protein_g: Number(existing.total_protein_g ?? 0),
      fat_g: Number(existing.total_fat_g ?? 0),
      carbs_g: Number(existing.total_carbs_g ?? 0),
      fiber_g: existing.total_fiber_g == null
        ? null
        : Number(existing.total_fiber_g),
    }
    : computeIngredientTotals(parsedIngredients);

  Object.assign(
    updates,
    makeBatchDerivedFields(nextTotals),
  );

  const previousIngredientsResponse = parsedIngredients == null
    ? null
    : await service
      .from("batch_recipe_ingredients")
      .select(
        "id,batch_recipe_id,name,brand,barcode,catalog_item_id,user_food_id,weight_g,calories,protein_g,fat_g,carbs_g,fiber_g,sort_order",
      )
      .eq("batch_recipe_id", batchId)
      .order("sort_order", { ascending: true })
      .returns<BatchIngredientRow[]>();
  if (previousIngredientsResponse?.error) {
    return jsonWithRequest(request, {
      error: "batch_ingredients_fetch_failed",
      detail: sanitizedInternalDetail(
        request,
        "index",
        previousIngredientsResponse.error,
      ),
    }, 500);
  }
  const previousIngredients = previousIngredientsResponse?.data ?? [];

  const previousSnapshot = makeBatchWriteFields({
    name: existing.name,
    description: existing.description,
    imageUrl: existing.image_url,
    cookedAt: existing.cooked_at,
    totalWeightG: Number(existing.total_weight_g ?? 0),
    totalPortions: existing.total_portions == null
      ? null
      : Number(existing.total_portions),
    archived: existing.archived,
    totals: {
      calories: Number(existing.total_calories ?? 0),
      protein_g: Number(existing.total_protein_g ?? 0),
      fat_g: Number(existing.total_fat_g ?? 0),
      carbs_g: Number(existing.total_carbs_g ?? 0),
      fiber_g: existing.total_fiber_g == null
        ? null
        : Number(existing.total_fiber_g),
    },
  });

  const { error: updateError } = await service
    .from("batch_recipes")
    .update(updates)
    .eq("id", batchId)
    .eq("user_id", userId)
    .is("deleted_at", null);

  if (updateError) {
    return jsonWithRequest(request, {
      error: "batch_update_failed",
      detail: sanitizedInternalDetail(request, "index", updateError),
    }, 500);
  }

  if (parsedIngredients != null) {
    const replaceError = await replaceBatchIngredients(
      service,
      batchId,
      parsedIngredients,
    );
    if (replaceError) {
      await service
        .from("batch_recipes")
        .update(previousSnapshot)
        .eq("id", batchId)
        .eq("user_id", userId)
        .is("deleted_at", null);
      await replaceBatchIngredients(service, batchId, previousIngredients);
      return jsonWithRequest(request, {
        error: "batch_ingredients_insert_failed",
        detail: sanitizedInternalDetail(request, "index", replaceError),
      }, 500);
    }
  }

  return jsonWithRequest(request, { ok: true });
}

async function handleLog(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string | null,
  batchId: string,
): Promise<Response> {
  const { data: batch, error: batchError } = await service
    .from("batch_recipes")
    .select(
      "id,name,cooked_at,total_weight_g,total_portions,total_calories,total_protein_g,total_fat_g,total_carbs_g,total_fiber_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,archived,times_used,last_used_at,updated_at",
    )
    .eq("id", batchId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<BatchRecipeRow>();

  if (batchError) {
    return jsonWithRequest(request, {
      error: "batch_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", batchError),
    }, 500);
  }
  if (!batch) {
    return jsonWithRequest(request, { error: "batch_not_found" }, 404);
  }

  const payload = (await readJsonObject(request)) ?? {};
  const providedLogId = readUUID(payload.food_log_id);
  const providedItemId = readUUID(payload.food_item_id);
  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const foodLogId = providedLogId ??
    (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());
  const foodItemId = providedItemId ?? crypto.randomUUID();

  const { data: existingLog, error: existingLogError } = await service
    .from("food_logs")
    .select("id")
    .eq("id", foodLogId)
    .eq("user_id", userId)
    .maybeSingle<{ id: string }>();
  if (existingLogError) {
    return jsonWithRequest(request, {
      error: "food_log_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", existingLogError),
    }, 500);
  }

  const { data: existingItem, error: existingItemError } = await service
    .from("food_items")
    .select("id")
    .eq("id", foodItemId)
    .eq("user_id", userId)
    .maybeSingle<{ id: string }>();
  if (existingItemError) {
    return jsonWithRequest(request, {
      error: "food_item_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", existingItemError),
    }, 500);
  }
  const isReplay = existingLog != null || existingItem != null;

  const portionWeight = readRequiredNumber(payload.portion_weight_g);
  if (portionWeight == null || portionWeight <= 0) {
    return jsonWithRequest(request, { error: "invalid_portion_weight_g" }, 400);
  }

  if (!(existingLog && existingItem)) {
    const consumed = await loadConsumedWeightMap(service, userId, [batchId]);
    const consumedWeight = consumed.get(batchId) ?? 0;
    const weightRemaining = Math.max(
      Number(batch.total_weight_g ?? 0) - consumedWeight,
      0,
    );
    if (portionWeight - weightRemaining > 0.001) {
      return jsonWithRequest(request, {
        error: "portion_exceeds_remaining",
        max_remaining_g: weightRemaining,
      }, 409);
    }
  }

  const loggedAt = toIsoString(payload.logged_at) ?? new Date().toISOString();
  const providedDate = parseLocalDateParam(request, "logged_date") ??
    (typeof payload.logged_date === "string" && isLocalDate(payload.logged_date)
      ? payload.logged_date
      : null);
  const loggedDate = providedDate ?? localDateToday(safeTimeZone(timezone));
  const loggedTimezone = safeTimeZone(
    readOptionalNullableString(payload.logged_timezone) || timezone,
  );
  const loggedUtcOffsetMinutes =
    typeof payload.logged_utc_offset_minutes === "number" &&
      Number.isFinite(payload.logged_utc_offset_minutes)
      ? Math.round(payload.logged_utc_offset_minutes)
      : 0;

  const mealType = readOptionalNullableString(payload.meal_type);
  if (mealType && !VALID_MEAL_TYPES.has(mealType)) {
    return jsonWithRequest(request, { error: "invalid_meal_type" }, 400);
  }

  const context = readOptionalNullableString(payload.context);
  if (context && !VALID_CONTEXTS.has(context)) {
    return jsonWithRequest(request, { error: "invalid_context" }, 400);
  }

  const override = parseMacrosOverride(payload.item_macros_override);
  if (payload.item_macros_override != null && !override.ok) {
    return jsonWithRequest(request, { error: override.error }, 400);
  }
  const macros = override.ok && override.value
    ? override.value
    : derivePortionMacros(batch, portionWeight);

  if (!existingLog) {
    const { error: foodLogError } = await service
      .from("food_logs")
      .insert({
        id: foodLogId,
        user_id: userId,
        logged_at: loggedAt,
        logged_date: loggedDate,
        logged_timezone: loggedTimezone,
        logged_utc_offset_minutes: loggedUtcOffsetMinutes,
        input_method: "batch",
        meal_type: mealType || null,
        context: context || null,
        calories: macros.calories,
        protein_g: macros.protein_g,
        fat_g: macros.fat_g,
        carbs_g: macros.carbs_g,
        fiber_g: macros.fiber_g,
        needs_review: false,
        user_corrected: false,
      });

    if (foodLogError) {
      return jsonWithRequest(request, {
        error: "food_log_insert_failed",
        detail: sanitizedInternalDetail(request, "index", foodLogError),
      }, 500);
    }
  }

  if (!existingItem) {
    const { error: foodItemError } = await service
      .from("food_items")
      .insert({
        id: foodItemId,
        food_log_id: foodLogId,
        user_id: userId,
        name: batch.name,
        batch_recipe_id: batchId,
        weight_g: portionWeight,
        calories: macros.calories,
        protein_g: macros.protein_g,
        fat_g: macros.fat_g,
        carbs_g: macros.carbs_g,
        fiber_g: macros.fiber_g,
        detected_by_ai: false,
        user_adjusted: false,
      });

    if (foodItemError) {
      return jsonWithRequest(request, {
        error: "food_item_insert_failed",
        detail: sanitizedInternalDetail(request, "index", foodItemError),
      }, 500);
    }
  }

  const usageError = await syncBatchUsageMetrics(service, userId, batchId);
  if (usageError) {
    return jsonWithRequest(request, {
      error: "batch_usage_update_failed",
      detail: sanitizedInternalDetail(request, "index", usageError),
    }, 500);
  }

  const consumed = await loadConsumedWeightMap(service, userId, [batchId]);
  const weightRemaining = Math.max(
    Number(batch.total_weight_g ?? 0) - (consumed.get(batchId) ?? 0),
    0,
  );

  return jsonWithRequest(request, {
    food_log_id: foodLogId,
    food_item_id: foodItemId,
    batch_id: batchId,
    weight_remaining_g: weightRemaining,
    ...(isReplay ? { idempotent_replay: true } : {}),
  }, 202);
}

async function handleDuplicate(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string | null,
  batchId: string,
): Promise<Response> {
  const { data: batch, error: batchError } = await service
    .from("batch_recipes")
    .select(
      "id,name,description,image_url,cooked_at,total_weight_g,total_portions,total_calories,total_protein_g,total_fat_g,total_carbs_g,total_fiber_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,archived,times_used,last_used_at,updated_at",
    )
    .eq("id", batchId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<BatchRecipeRow>();

  if (batchError) {
    return jsonWithRequest(request, {
      error: "batch_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", batchError),
    }, 500);
  }
  if (!batch) {
    return jsonWithRequest(request, { error: "batch_not_found" }, 404);
  }

  const { data: ingredients, error: ingredientsError } = await service
    .from("batch_recipe_ingredients")
    .select(
      "id,batch_recipe_id,name,brand,barcode,catalog_item_id,user_food_id,weight_g,calories,protein_g,fat_g,carbs_g,fiber_g,sort_order",
    )
    .eq("batch_recipe_id", batchId)
    .order("sort_order", { ascending: true })
    .returns<BatchIngredientRow[]>();

  if (ingredientsError) {
    return jsonWithRequest(request, {
      error: "batch_ingredients_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", ingredientsError),
    }, 500);
  }

  const payload = (await readJsonObject(request)) ?? {};
  const newBatchId = readUUID(payload.id) ??
    (isUUID(request.headers.get("Idempotency-Key")?.trim() ?? "")
      ? request.headers.get("Idempotency-Key")!.trim()
      : crypto.randomUUID());
  const cookedAt = readOptionalNullableString(payload.cooked_at) ||
    localDateToday(safeTimeZone(timezone));

  const { data: existingReplay, error: existingReplayError } = await service
    .from("batch_recipes")
    .select("id")
    .eq("id", newBatchId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<{ id: string }>();
  if (existingReplayError) {
    return jsonWithRequest(request, {
      error: "batch_duplicate_failed",
      detail: sanitizedInternalDetail(request, "index", existingReplayError),
    }, 500);
  }

  const duplicateWriteFields = {
    ...makeBatchWriteFields({
      name: batch.name,
      description: batch.description,
      imageUrl: batch.image_url,
      cookedAt,
      totalWeightG: Number(batch.total_weight_g ?? 0),
      totalPortions: batch.total_portions == null
        ? null
        : Number(batch.total_portions),
      archived: false,
      totals: {
        calories: Number(batch.total_calories ?? 0),
        protein_g: Number(batch.total_protein_g ?? 0),
        fat_g: Number(batch.total_fat_g ?? 0),
        carbs_g: Number(batch.total_carbs_g ?? 0),
        fiber_g: batch.total_fiber_g == null
          ? null
          : Number(batch.total_fiber_g),
      },
    }),
    times_used: 0,
    last_used_at: null,
  };
  const duplicateInsert = {
    id: newBatchId,
    user_id: userId,
    ...duplicateWriteFields,
  };

  if (existingReplay) {
    const { error: updateError } = await service
      .from("batch_recipes")
      .update(duplicateWriteFields)
      .eq("id", newBatchId)
      .eq("user_id", userId)
      .is("deleted_at", null);

    if (updateError) {
      return jsonWithRequest(request, {
        error: "batch_duplicate_failed",
        detail: sanitizedInternalDetail(request, "index", updateError),
      }, 500);
    }

    const ingredientRepairError = await replaceBatchIngredients(
      service,
      newBatchId,
      (ingredients ?? []).map((ingredient) => ({
        ...ingredient,
        id: crypto.randomUUID(),
      })),
    );
    if (ingredientRepairError) {
      return jsonWithRequest(request, {
        error: "batch_duplicate_ingredients_failed",
        detail: sanitizedInternalDetail(
          request,
          "index",
          ingredientRepairError,
        ),
      }, 500);
    }

    return jsonWithRequest(
      request,
      { id: existingReplay.id, idempotent_replay: true },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  const { error: createError } = await service
    .from("batch_recipes")
    .insert(duplicateInsert);

  if (createError) {
    return jsonWithRequest(request, {
      error: "batch_duplicate_failed",
      detail: sanitizedInternalDetail(request, "index", createError),
    }, 500);
  }

  const ingredientInsertError = await replaceBatchIngredients(
    service,
    newBatchId,
    (ingredients ?? []).map((ingredient) => ({
      ...ingredient,
      id: crypto.randomUUID(),
    })),
  );

  if (ingredientInsertError) {
    return jsonWithRequest(request, {
      error: "batch_duplicate_ingredients_failed",
      detail: sanitizedInternalDetail(request, "index", ingredientInsertError),
    }, 500);
  }

  return jsonWithRequest(request, { id: newBatchId }, 201);
}

function compareBatchRows(
  lhs: BatchRecipeRow,
  rhs: BatchRecipeRow,
  status: string,
): number {
  if (status === "archived") {
    return Date.parse(rhs.updated_at) - Date.parse(lhs.updated_at);
  }

  const lhsMissing = lhs.cooked_at == null ? 1 : 0;
  const rhsMissing = rhs.cooked_at == null ? 1 : 0;
  if (lhsMissing !== rhsMissing) return lhsMissing - rhsMissing;
  if (lhs.cooked_at !== rhs.cooked_at) {
    return Date.parse(`${rhs.cooked_at ?? "1970-01-01"}T00:00:00Z`) -
      Date.parse(`${lhs.cooked_at ?? "1970-01-01"}T00:00:00Z`);
  }
  return Date.parse(rhs.updated_at) - Date.parse(lhs.updated_at);
}

function buildBatchSummary(row: BatchRecipeRow, consumedWeightG: number) {
  const totalWeight = Number(row.total_weight_g ?? 0);
  const weightRemainingG = Math.max(totalWeight - consumedWeightG, 0);
  const totalPortions = row.total_portions == null
    ? null
    : Number(row.total_portions);
  const portionsRemaining =
    totalPortions != null && totalPortions > 0 && totalWeight > 0
      ? weightRemainingG / (totalWeight / totalPortions)
      : null;
  const totalCalories = Number(row.total_calories ?? 0);
  const totalProteinG = Number(row.total_protein_g ?? 0);
  const totalFatG = Number(row.total_fat_g ?? 0);
  const totalCarbsG = Number(row.total_carbs_g ?? 0);

  return {
    id: row.id,
    name: row.name,
    cooked_at: row.cooked_at,
    total_weight_g: totalWeight,
    consumed_weight_g: consumedWeightG,
    weight_remaining_g: weightRemainingG,
    total_portions: totalPortions,
    portions_remaining: portionsRemaining,
    total_calories: totalCalories,
    total_protein_g: totalProteinG,
    total_fat_g: totalFatG,
    total_carbs_g: totalCarbsG,
    total_fiber_g: row.total_fiber_g == null ? null : Number(row.total_fiber_g),
    calories_per_100g: row.calories_per_100g == null
      ? (totalWeight > 0 ? (totalCalories * 100) / totalWeight : null)
      : Number(row.calories_per_100g),
    protein_per_100g: row.protein_per_100g == null
      ? (totalWeight > 0 ? (totalProteinG * 100) / totalWeight : null)
      : Number(row.protein_per_100g),
    fat_per_100g: row.fat_per_100g == null
      ? (totalWeight > 0 ? (totalFatG * 100) / totalWeight : null)
      : Number(row.fat_per_100g),
    carbs_per_100g: row.carbs_per_100g == null
      ? (totalWeight > 0 ? (totalCarbsG * 100) / totalWeight : null)
      : Number(row.carbs_per_100g),
    archived: row.archived,
    times_used: row.times_used,
    last_used_at: row.last_used_at,
    updated_at: row.updated_at,
  };
}

function makeBatchDerivedFields(
  totals: {
    calories: number;
    protein_g: number;
    fat_g: number;
    carbs_g: number;
    fiber_g: number | null;
  },
) {
  return {
    total_calories: totals.calories,
    total_protein_g: totals.protein_g,
    total_fat_g: totals.fat_g,
    total_carbs_g: totals.carbs_g,
    total_fiber_g: totals.fiber_g,
  };
}

function makeBatchWriteFields(input: {
  name: string;
  description: string | null;
  imageUrl: string | null;
  cookedAt: string | null;
  totalWeightG: number;
  totalPortions: number | null;
  archived: boolean;
  totals: {
    calories: number;
    protein_g: number;
    fat_g: number;
    carbs_g: number;
    fiber_g: number | null;
  };
}) {
  return {
    name: input.name,
    description: input.description,
    image_url: input.imageUrl,
    cooked_at: input.cookedAt,
    total_weight_g: input.totalWeightG,
    total_portions: input.totalPortions,
    archived: input.archived,
    ...makeBatchDerivedFields(input.totals),
  };
}

async function loadConsumedWeightMap(
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  batchIds: string[],
): Promise<Map<string, number>> {
  const result = new Map<string, number>();
  if (batchIds.length === 0) return result;

  const { data: items, error: itemsError } = await service
    .from("food_items")
    .select("batch_recipe_id,food_log_id,weight_g")
    .eq("user_id", userId)
    .in("batch_recipe_id", batchIds)
    .returns<ConsumptionItemRow[]>();
  if (itemsError || !items || items.length === 0) {
    return result;
  }

  const foodLogIds = [
    ...new Set(items.map((item) => item.food_log_id).filter(Boolean)),
  ];
  if (foodLogIds.length === 0) return result;

  const { data: logs, error: logsError } = await service
    .from("food_logs")
    .select("id,deleted_at")
    .eq("user_id", userId)
    .in("id", foodLogIds)
    .returns<FoodLogStateRow[]>();
  if (logsError || !logs) {
    return result;
  }

  const activeLogs = new Set(
    logs.filter((log) => log.deleted_at == null).map((log) => log.id),
  );

  for (const item of items) {
    if (!item.batch_recipe_id || !activeLogs.has(item.food_log_id)) continue;
    result.set(
      item.batch_recipe_id,
      (result.get(item.batch_recipe_id) ?? 0) + Number(item.weight_g ?? 0),
    );
  }

  return result;
}

function mapIngredientResponse(row: BatchIngredientRow) {
  return {
    id: row.id,
    name: row.name,
    brand: row.brand,
    barcode: row.barcode,
    catalog_item_id: row.catalog_item_id,
    user_food_id: row.user_food_id,
    weight_g: Number(row.weight_g ?? 0),
    calories: Number(row.calories ?? 0),
    protein_g: Number(row.protein_g ?? 0),
    fat_g: Number(row.fat_g ?? 0),
    carbs_g: Number(row.carbs_g ?? 0),
    fiber_g: row.fiber_g == null ? null : Number(row.fiber_g),
  };
}

type ParsedIngredient = {
  id: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  catalog_item_id: string | null;
  user_food_id: string | null;
  weight_g: number;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
};

function parseBatchDraft(payload: Record<string, unknown>): {
  ok: true;
  batchId: string;
  draft: {
    name: string;
    description: string | null;
    cooked_at: string | null;
    total_weight_g: number;
    total_portions: number | null;
    ingredients: ParsedIngredient[];
  };
} | { ok: false; error: string } {
  const batchId = readUUID(payload.id) ?? crypto.randomUUID();
  const name = readOptionalTrimmedString(payload.name);
  if (!name) return { ok: false, error: "name_required" };

  const totalWeight = readRequiredNumber(payload.total_weight_g);
  if (totalWeight == null || totalWeight <= 0) {
    return { ok: false, error: "invalid_total_weight_g" };
  }

  let totalPortions: number | null = null;
  if (payload.total_portions != null) {
    if (
      typeof payload.total_portions !== "number" ||
      !Number.isInteger(payload.total_portions) ||
      payload.total_portions <= 0
    ) {
      return { ok: false, error: "invalid_total_portions" };
    }
    totalPortions = payload.total_portions;
  }

  const cookedAt = readOptionalNullableString(payload.cooked_at);
  if (cookedAt && !isLocalDate(cookedAt)) {
    return { ok: false, error: "invalid_cooked_at" };
  }

  const ingredients = parseIngredients(payload.ingredients);
  if (!ingredients.ok) return ingredients;

  return {
    ok: true,
    batchId,
    draft: {
      name,
      description: readOptionalNullableString(payload.description),
      cooked_at: cookedAt || null,
      total_weight_g: totalWeight,
      total_portions: totalPortions,
      ingredients: ingredients.ingredients,
    },
  };
}

function parseIngredients(value: unknown):
  | { ok: true; ingredients: ParsedIngredient[] }
  | { ok: false; error: string } {
  if (!Array.isArray(value) || value.length === 0) {
    return { ok: false, error: "ingredients_required" };
  }

  const ingredients: ParsedIngredient[] = [];
  for (const raw of value) {
    if (!isPlainObject(raw)) return { ok: false, error: "invalid_ingredient" };

    const id = readUUID(raw.id) ?? crypto.randomUUID();
    const name = readOptionalTrimmedString(raw.name);
    if (!name) return { ok: false, error: "ingredient_name_required" };

    const weight = readRequiredNumber(raw.weight_g);
    if (weight == null || weight <= 0) {
      return { ok: false, error: "invalid_ingredient_weight_g" };
    }

    const macrosTotal = isPlainObject(raw.macros_total)
      ? raw.macros_total
      : null;
    if (!macrosTotal) {
      return { ok: false, error: "ingredient_macros_required" };
    }

    const calories = readRequiredNumber(macrosTotal.calories);
    const protein = readRequiredNumber(macrosTotal.protein_g);
    const fat = readRequiredNumber(macrosTotal.fat_g);
    const carbs = readRequiredNumber(macrosTotal.carbs_g);
    const fiber = macrosTotal.fiber_g == null
      ? null
      : readRequiredNumber(macrosTotal.fiber_g);

    if (
      calories == null || protein == null || fat == null || carbs == null ||
      (macrosTotal.fiber_g != null && fiber == null)
    ) {
      return { ok: false, error: "invalid_ingredient_macros" };
    }

    const catalogItemId = readUUID(raw.catalog_item_id);
    const userFoodId = readUUID(raw.user_food_id);
    if (catalogItemId && userFoodId) {
      return { ok: false, error: "ingredient_multiple_refs" };
    }

    ingredients.push({
      id,
      name,
      brand: readOptionalNullableString(raw.brand),
      barcode: readOptionalNullableString(raw.barcode),
      catalog_item_id: catalogItemId,
      user_food_id: userFoodId,
      weight_g: weight,
      calories,
      protein_g: protein,
      fat_g: fat,
      carbs_g: carbs,
      fiber_g: fiber,
    });
  }

  return { ok: true, ingredients };
}

function computeIngredientTotals(ingredients: ParsedIngredient[]) {
  return ingredients.reduce(
    (totals, ingredient) => ({
      calories: totals.calories + ingredient.calories,
      protein_g: totals.protein_g + ingredient.protein_g,
      fat_g: totals.fat_g + ingredient.fat_g,
      carbs_g: totals.carbs_g + ingredient.carbs_g,
      fiber_g: (totals.fiber_g ?? 0) + (ingredient.fiber_g ?? 0),
    }),
    { calories: 0, protein_g: 0, fat_g: 0, carbs_g: 0, fiber_g: 0 },
  );
}

function makeIngredientInsert(
  batchId: string,
  ingredient: {
    id: string;
    name: string;
    brand: string | null;
    barcode: string | null;
    catalog_item_id: string | null;
    user_food_id: string | null;
    weight_g: number;
    calories: number;
    protein_g: number;
    fat_g: number;
    carbs_g: number;
    fiber_g: number | null;
  },
  sortOrder: number,
) {
  return {
    id: ingredient.id,
    batch_recipe_id: batchId,
    name: ingredient.name,
    brand: ingredient.brand,
    barcode: ingredient.barcode,
    catalog_item_id: ingredient.catalog_item_id,
    user_food_id: ingredient.user_food_id,
    weight_g: ingredient.weight_g,
    calories: ingredient.calories,
    protein_g: ingredient.protein_g,
    fat_g: ingredient.fat_g,
    carbs_g: ingredient.carbs_g,
    fiber_g: ingredient.fiber_g,
    sort_order: sortOrder,
  };
}

async function replaceBatchIngredients(
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  batchId: string,
  ingredients: Array<ParsedIngredient | BatchIngredientRow>,
): Promise<string | null> {
  const { error: deleteError } = await service
    .from("batch_recipe_ingredients")
    .delete()
    .eq("batch_recipe_id", batchId);

  if (deleteError) {
    return deleteError.message;
  }

  if (ingredients.length === 0) return null;

  const { error: insertError } = await service
    .from("batch_recipe_ingredients")
    .insert(
      ingredients.map((ingredient, index) =>
        makeIngredientInsert(batchId, ingredient, index)
      ),
    );

  return insertError?.message ?? null;
}

function parseMacrosOverride(value: unknown):
  | { ok: true; value: null | Record<string, number | null> }
  | { ok: false; error: string } {
  if (value == null) return { ok: true, value: null };
  if (!isPlainObject(value)) {
    return { ok: false, error: "invalid_item_macros_override" };
  }

  const calories = readRequiredNumber(value.calories);
  const protein = readRequiredNumber(value.protein_g);
  const fat = readRequiredNumber(value.fat_g);
  const carbs = readRequiredNumber(value.carbs_g);
  const fiber = value.fiber_g == null
    ? null
    : readRequiredNumber(value.fiber_g);
  if (
    calories == null || protein == null || fat == null || carbs == null ||
    (value.fiber_g != null && fiber == null)
  ) {
    return { ok: false, error: "invalid_item_macros_override" };
  }
  return {
    ok: true,
    value: {
      calories,
      protein_g: protein,
      fat_g: fat,
      carbs_g: carbs,
      fiber_g: fiber,
    },
  };
}

function derivePortionMacros(batch: BatchRecipeRow, portionWeightG: number) {
  const factor = portionWeightG / 100;
  const caloriesPer100g = Number(
    batch.calories_per_100g ?? (
      batch.total_weight_g > 0
        ? (batch.total_calories * 100) / batch.total_weight_g
        : 0
    ),
  );
  const proteinPer100g = Number(
    batch.protein_per_100g ?? (
      batch.total_weight_g > 0
        ? (batch.total_protein_g * 100) / batch.total_weight_g
        : 0
    ),
  );
  const fatPer100g = Number(
    batch.fat_per_100g ?? (
      batch.total_weight_g > 0
        ? (batch.total_fat_g * 100) / batch.total_weight_g
        : 0
    ),
  );
  const carbsPer100g = Number(
    batch.carbs_per_100g ?? (
      batch.total_weight_g > 0
        ? (batch.total_carbs_g * 100) / batch.total_weight_g
        : 0
    ),
  );
  const fiberPer100g = batch.total_fiber_g == null || batch.total_weight_g <= 0
    ? null
    : (Number(batch.total_fiber_g) * 100) / Number(batch.total_weight_g);

  return {
    calories: caloriesPer100g * factor,
    protein_g: proteinPer100g * factor,
    fat_g: fatPer100g * factor,
    carbs_g: carbsPer100g * factor,
    fiber_g: fiberPer100g == null ? null : fiberPer100g * factor,
  };
}

async function syncBatchUsageMetrics(
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  batchId: string,
): Promise<string | null> {
  const { data: items, error: itemsError } = await service
    .from("food_items")
    .select("food_log_id")
    .eq("user_id", userId)
    .eq("batch_recipe_id", batchId)
    .returns<Array<{ food_log_id: string }>>();
  if (itemsError) {
    return itemsError.message;
  }

  const foodLogIds = [
    ...new Set((items ?? []).map((item) => item.food_log_id).filter(Boolean)),
  ];
  if (foodLogIds.length === 0) {
    const { error } = await service
      .from("batch_recipes")
      .update({ times_used: 0, last_used_at: null })
      .eq("id", batchId)
      .eq("user_id", userId);
    return error?.message ?? null;
  }

  const { data: logs, error: logsError } = await service
    .from("food_logs")
    .select("id,logged_at,deleted_at")
    .eq("user_id", userId)
    .in("id", foodLogIds)
    .returns<FoodLogUsageRow[]>();
  if (logsError) {
    return logsError.message;
  }

  const activeLogs = new Map(
    (logs ?? [])
      .filter((log) => log.deleted_at == null)
      .map((log) => [log.id, log.logged_at]),
  );

  let usageCount = 0;
  let lastUsedAt: string | null = null;
  for (const item of items ?? []) {
    const loggedAt = activeLogs.get(item.food_log_id);
    if (!loggedAt) continue;
    usageCount += 1;
    if (!lastUsedAt || Date.parse(loggedAt) > Date.parse(lastUsedAt)) {
      lastUsedAt = loggedAt;
    }
  }

  const { error: updateError } = await service
    .from("batch_recipes")
    .update({
      times_used: usageCount,
      last_used_at: lastUsedAt,
    })
    .eq("id", batchId)
    .eq("user_id", userId);

  return updateError?.message ?? null;
}

async function readJsonObject(
  request: Request,
): Promise<Record<string, unknown> | null> {
  try {
    const payload = await request.json();
    return isPlainObject(payload) ? payload : null;
  } catch {
    return null;
  }
}

function readUUID(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return isUUID(trimmed) ? trimmed : null;
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value != null && !Array.isArray(value);
}

function readOptionalTrimmedString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  return value.trim();
}

function readOptionalNullableString(value: unknown): string | null {
  if (value == null) return null;
  if (typeof value !== "string") return "";
  return value.trim();
}

function readRequiredNumber(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return value;
}

function toIsoString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString();
}
