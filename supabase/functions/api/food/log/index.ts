import { pathnameTail } from "../../../_shared/date_range.ts";
import { isLocalDate } from "../../../_shared/datetime.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { FoodLogPayloadSchema } from "../../../_shared/payload_schemas.ts";
import { readJsonBody } from "../../../_shared/request_limits.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

type InputMethod =
  | "vision"
  | "barcode"
  | "batch"
  | "manual"
  | "voice"
  | "template";

interface FoodLogPayload {
  id?: string;
  user_id?: string;
  logged_at?: string;
  logged_date?: string;
  logged_timezone?: string | null;
  logged_utc_offset_minutes?: number | null;
  input_method?: InputMethod;
  meal_type?: string | null;
  context?: string | null;
  pre_workout?: boolean;
  post_workout?: boolean;
  minutes_since_workout?: number | null;
  calories?: number;
  protein_g?: number;
  fat_g?: number;
  carbs_g?: number;
  fiber_g?: number | null;
  sugar_g?: number | null;
  alcohol_units?: number | null;
  caffeine_mg?: number | null;
  sodium_mg?: number | null;
  potassium_mg?: number | null;
  calcium_mg?: number | null;
  iron_mg?: number | null;
  vitamin_d_mcg?: number | null;
  vitamin_b12_mcg?: number | null;
  image_url?: string | null;
  image_uploaded_at?: string | null;
  ai_detected_items?: unknown;
  ai_confidence?: number | null;
  ai_context_analysis?: string | null;
  needs_review?: boolean;
  user_corrected?: boolean;
  user_notes?: string | null;
  ai_feedback?: string | null;
  ai_feedback_details?: string | null;
  ai_feedback_at?: string | null;
  deleted_at?: string | null;
  deleted_reason?: string | null;
  synced_to_vector_db?: boolean;
  vector_id?: string | null;
}

interface FoodLogDetailRow {
  created_at: string;
  updated_at: string;
  id: string;
  logged_at: string;
  logged_date: string;
  meal_type: string | null;
  context: string | null;
  input_method: string;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
  ai_confidence: number | null;
  user_corrected: boolean;
  user_notes: string | null;
}

interface FoodItemRow {
  created_at: string;
  updated_at: string;
  id: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  catalog_item_id: string | null;
  user_food_id: string | null;
  batch_recipe_id: string | null;
  weight_g: number;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
  confidence: number | null;
  detected_by_ai: boolean;
  user_adjusted: boolean;
}

interface FoodItemPatch {
  id?: string;
  name?: string;
  brand?: string | null;
  barcode?: string | null;
  catalog_item_id?: string | null;
  user_food_id?: string | null;
  batch_recipe_id?: string | null;
  weight_g?: number;
  calories?: number;
  protein_g?: number;
  fat_g?: number;
  carbs_g?: number;
  fiber_g?: number | null;
  confidence?: number | null;
  detected_by_ai?: boolean;
  user_adjusted?: boolean;
}

const VALID_INPUT_METHODS = new Set<InputMethod>([
  "vision",
  "barcode",
  "batch",
  "manual",
  "voice",
  "template",
]);

const VALID_MEAL_TYPES = new Set(["breakfast", "lunch", "dinner", "snack"]);
const VALID_CONTEXTS = new Set([
  "home",
  "restaurant",
  "party",
  "work",
  "other",
  "unknown",
]);
const VALID_AI_FEEDBACK = new Set(["accurate", "slightly_off", "very_wrong"]);
const VALID_DELETED_REASONS = new Set(["user_deleted", "merged", "duplicate"]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!new Set(["GET", "POST", "PATCH", "DELETE"]).has(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const url = new URL(request.url);
  const pathTail = pathnameTail(url.pathname);
  const logId = pathTail[0] ?? "";
  const action = (pathTail[1] ?? "").toLowerCase();

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { userId, timezone, service } = userResult.context;

  if (request.method === "GET") {
    if (!isUUID(logId)) {
      return jsonWithRequest(request, { error: "invalid_log_id" }, 400);
    }
    return await handleGetLog(request, service, userId, logId);
  }

  if (request.method === "PATCH") {
    if (!isUUID(logId)) {
      return jsonWithRequest(request, { error: "invalid_log_id" }, 400);
    }
    return await handlePatchLog(request, service, userId, logId);
  }

  if (request.method === "DELETE") {
    if (!isUUID(logId)) {
      return jsonWithRequest(request, { error: "invalid_log_id" }, 400);
    }
    return await handleDeleteLog(request, service, userId, logId);
  }

  if (request.method === "POST" && isUUID(logId) && action === "undo") {
    return await handleUndoLog(request, service, userId, logId);
  }

  if (request.method === "POST" && pathTail.length === 0) {
    return await handleCreateLog(request, service, userId, timezone);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleGetLog(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  logId: string,
): Promise<Response> {
  const { data: log, error: logError } = await service
    .from("food_logs")
    .select(
      "created_at,updated_at,id,logged_at,logged_date,meal_type,context,input_method,calories,protein_g,fat_g,carbs_g,fiber_g,ai_confidence,user_corrected,user_notes",
    )
    .eq("id", logId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<FoodLogDetailRow>();

  if (logError) {
    return jsonWithRequest(request, {
      error: "food_log_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", logError),
    }, 500);
  }
  if (!log) {
    return jsonWithRequest(request, { error: "food_log_not_found" }, 404);
  }

  const { data: items, error: itemsError } = await service
    .from("food_items")
    .select(
      "created_at,updated_at,id,name,brand,barcode,catalog_item_id,user_food_id,batch_recipe_id,weight_g,calories,protein_g,fat_g,carbs_g,fiber_g,confidence,detected_by_ai,user_adjusted",
    )
    .eq("food_log_id", logId)
    .eq("user_id", userId)
    .order("created_at", { ascending: true })
    .returns<FoodItemRow[]>();

  if (itemsError) {
    return jsonWithRequest(request, {
      error: "food_items_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", itemsError),
    }, 500);
  }

  return jsonWithRequest(request, {
    id: log.id,
    created_at: log.created_at,
    updated_at: log.updated_at,
    logged_at: log.logged_at,
    logged_date: log.logged_date,
    meal_type: log.meal_type,
    context: log.context,
    input_method: log.input_method,
    macros: {
      calories: Number(log.calories ?? 0),
      protein_g: Number(log.protein_g ?? 0),
      fat_g: Number(log.fat_g ?? 0),
      carbs_g: Number(log.carbs_g ?? 0),
      fiber_g: log.fiber_g == null ? null : Number(log.fiber_g),
    },
    ai_confidence: log.ai_confidence,
    user_corrected: log.user_corrected,
    user_notes: log.user_notes,
    items: (items ?? []).map((item) => ({
      id: item.id,
      created_at: item.created_at,
      updated_at: item.updated_at,
      name: item.name,
      brand: item.brand,
      barcode: item.barcode,
      catalog_item_id: item.catalog_item_id,
      user_food_id: item.user_food_id,
      batch_recipe_id: item.batch_recipe_id,
      weight_g: Number(item.weight_g ?? 0),
      macros: {
        calories: Number(item.calories ?? 0),
        protein_g: Number(item.protein_g ?? 0),
        fat_g: Number(item.fat_g ?? 0),
        carbs_g: Number(item.carbs_g ?? 0),
        fiber_g: item.fiber_g == null ? null : Number(item.fiber_g),
      },
      confidence: item.confidence,
      detected_by_ai: item.detected_by_ai,
      user_adjusted: item.user_adjusted,
    })),
  });
}

async function handlePatchLog(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  logId: string,
): Promise<Response> {
  const patchBody = await readJsonBody(request);
  if (!patchBody.ok) {
    return jsonWithRequest(
      request,
      { error: patchBody.reason },
      patchBody.reason === "body_too_large" ? 413 : 400,
    );
  }
  const payload: Record<string, unknown> = patchBody.body as Record<
    string,
    unknown
  >;

  const { data: existing, error: existingError } = await service
    .from("food_logs")
    .select("id,input_method")
    .eq("id", logId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<{ id: string; input_method: string }>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "food_log_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", existingError),
    }, 500);
  }
  if (!existing) {
    return jsonWithRequest(request, { error: "food_log_not_found" }, 404);
  }

  const updates: Record<string, unknown> = {};

  if (Object.prototype.hasOwnProperty.call(payload, "logged_at")) {
    if (typeof payload.logged_at !== "string") {
      return jsonWithRequest(request, { error: "invalid_logged_at" }, 400);
    }
    const parsed = new Date(payload.logged_at);
    if (Number.isNaN(parsed.getTime())) {
      return jsonWithRequest(request, { error: "invalid_logged_at" }, 400);
    }
    updates.logged_at = parsed.toISOString();
  }

  if (Object.prototype.hasOwnProperty.call(payload, "logged_date")) {
    if (
      typeof payload.logged_date !== "string" ||
      !isLocalDate(payload.logged_date)
    ) {
      return jsonWithRequest(request, { error: "invalid_logged_date" }, 400);
    }
    updates.logged_date = payload.logged_date;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "meal_type")) {
    const mealType = readOptionalNullableString(payload.meal_type);
    if (
      mealType != null && mealType !== "" && !VALID_MEAL_TYPES.has(mealType)
    ) {
      return jsonWithRequest(request, { error: "invalid_meal_type" }, 400);
    }
    updates.meal_type = mealType || null;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "context")) {
    const context = readOptionalNullableString(payload.context);
    if (context != null && context !== "" && !VALID_CONTEXTS.has(context)) {
      return jsonWithRequest(request, { error: "invalid_context" }, 400);
    }
    updates.context = context || null;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "user_notes")) {
    const userNotes = readOptionalNullableString(payload.user_notes);
    if (userNotes != null && userNotes.length > 2_000) {
      return jsonWithRequest(request, { error: "invalid_user_notes" }, 400);
    }
    updates.user_notes = userNotes;
  }

  let parsedItems: FoodItemPatch[] | null = null;
  if (Object.prototype.hasOwnProperty.call(payload, "items")) {
    if (!Array.isArray(payload.items) || payload.items.length === 0) {
      return jsonWithRequest(request, { error: "invalid_items" }, 400);
    }
    parsedItems = [];
    let totalCalories = 0;
    let totalProtein = 0;
    let totalFat = 0;
    let totalCarbs = 0;
    let totalFiber = 0;

    for (const rawItem of payload.items) {
      if (!isPlainObject(rawItem)) {
        return jsonWithRequest(request, { error: "invalid_item" }, 400);
      }

      const name = readRequiredString(rawItem.name);
      if (!name) {
        return jsonWithRequest(request, { error: "item_name_required" }, 400);
      }

      const weight = readRequiredNumber(rawItem.weight_g);
      const calories = readRequiredNumber(rawItem.calories);
      const protein = readRequiredNumber(rawItem.protein_g);
      const fat = readRequiredNumber(rawItem.fat_g);
      const carbs = readRequiredNumber(rawItem.carbs_g);
      if (
        weight == null || calories == null || protein == null || fat == null ||
        carbs == null
      ) {
        return jsonWithRequest(request, { error: "item_macros_required" }, 400);
      }

      const refCount = [
        rawItem.catalog_item_id,
        rawItem.user_food_id,
        rawItem.batch_recipe_id,
      ]
        .filter((value) => typeof value === "string" && isUUID(value)).length;
      if (refCount > 1) {
        return jsonWithRequest(request, { error: "item_multiple_refs" }, 400);
      }

      const fiber = rawItem.fiber_g == null
        ? null
        : (typeof rawItem.fiber_g === "number" &&
            Number.isFinite(rawItem.fiber_g)
          ? rawItem.fiber_g
          : Number.NaN);
      if (fiber != null && !Number.isFinite(fiber)) {
        return jsonWithRequest(request, { error: "invalid_item_fiber_g" }, 400);
      }

      totalCalories += calories;
      totalProtein += protein;
      totalFat += fat;
      totalCarbs += carbs;
      totalFiber += fiber ?? 0;

      parsedItems.push({
        id: isUUID(String(rawItem.id ?? ""))
          ? String(rawItem.id)
          : crypto.randomUUID(),
        name,
        brand: readOptionalNullableString(rawItem.brand),
        barcode: readOptionalNullableString(rawItem.barcode),
        catalog_item_id: isUUID(String(rawItem.catalog_item_id ?? ""))
          ? String(rawItem.catalog_item_id)
          : null,
        user_food_id: isUUID(String(rawItem.user_food_id ?? ""))
          ? String(rawItem.user_food_id)
          : null,
        batch_recipe_id: isUUID(String(rawItem.batch_recipe_id ?? ""))
          ? String(rawItem.batch_recipe_id)
          : null,
        weight_g: weight,
        calories,
        protein_g: protein,
        fat_g: fat,
        carbs_g: carbs,
        fiber_g: fiber,
        confidence: typeof rawItem.confidence === "number" &&
            Number.isFinite(rawItem.confidence)
          ? rawItem.confidence
          : null,
        detected_by_ai: typeof rawItem.detected_by_ai === "boolean"
          ? rawItem.detected_by_ai
          : true,
        user_adjusted: true,
      });
    }

    updates.calories = totalCalories;
    updates.protein_g = totalProtein;
    updates.fat_g = totalFat;
    updates.carbs_g = totalCarbs;
    updates.fiber_g = totalFiber > 0 ? totalFiber : null;
    updates.user_corrected = true;
    updates.needs_review = false;
    updates.ai_confidence = null;
  }

  if (Object.keys(updates).length === 0) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  const { data: changed, error: updateError } = await service.rpc(
    "patch_food_log_atomic",
    {
      p_user_id: userId,
      p_log_id: logId,
      p_updates: updates,
      p_items: parsedItems ?? null,
    },
  );
  if (updateError) {
    return jsonWithRequest(request, {
      error: "food_log_update_failed",
      detail: sanitizedInternalDetail(request, "index", updateError),
    }, 500);
  }
  if (!changed) {
    return jsonWithRequest(request, { error: "food_log_not_found" }, 404);
  }

  return jsonWithRequest(request, { ok: true });
}

async function handleDeleteLog(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  logId: string,
): Promise<Response> {
  const { data, error } = await service
    .from("food_logs")
    .update({
      deleted_at: new Date().toISOString(),
      deleted_reason: "user_deleted",
    })
    .eq("id", logId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .select("id")
    .maybeSingle<{ id: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "food_log_delete_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(request, { error: "food_log_not_found" }, 404);
  }

  return jsonWithRequest(request, { ok: true });
}

async function handleUndoLog(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  logId: string,
): Promise<Response> {
  const undoSince = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await service
    .from("food_logs")
    .update({ deleted_at: null, deleted_reason: null })
    .eq("id", logId)
    .eq("user_id", userId)
    .gte("deleted_at", undoSince)
    .select("id")
    .maybeSingle<{ id: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "food_log_undo_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(
      request,
      { error: "food_log_not_found_or_expired" },
      404,
    );
  }

  return jsonWithRequest(request, { ok: true });
}

async function handleCreateLog(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string | null,
): Promise<Response> {
  const bodyResult = await readJsonBody(request);
  if (!bodyResult.ok) {
    return jsonWithRequest(
      request,
      { error: bodyResult.reason },
      bodyResult.reason === "body_too_large" ? 413 : 400,
    );
  }
  const payloadRaw: unknown = bodyResult.body;
  const payloadParse = parseWithSchema(FoodLogPayloadSchema, payloadRaw);
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: FoodLogPayload = payloadParse.output;

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const payloadId = typeof payload.id === "string" ? payload.id.trim() : "";
  const normalizedPayloadId = payloadId.toLowerCase();
  const normalizedIdempotencyKey = idempotencyKey.toLowerCase();
  const matchesPayloadScopedIdempotencyKey = isUUID(normalizedPayloadId) &&
    isUUID(normalizedIdempotencyKey) &&
    normalizedPayloadId === normalizedIdempotencyKey;

  // Ownership guard: reject cross-user UUID collisions before any upsert.
  let existingRow: {
    id: string;
    user_id: string;
    logged_date: string;
    updated_at: string;
  } | null = null;
  if (payloadId && isUUID(payloadId)) {
    const { data: existing, error: existingLookupError } = await service
      .from("food_logs")
      .select("id,user_id,logged_date,updated_at")
      .eq("id", payloadId)
      .maybeSingle<
        { id: string; user_id: string; logged_date: string; updated_at: string }
      >();

    if (existingLookupError) {
      return jsonWithRequest(request, {
        error: "food_log_lookup_failed",
        detail: sanitizedInternalDetail(request, "index", existingLookupError),
      }, 500);
    }
    existingRow = existing ?? null;
    if (existingRow && existingRow.user_id !== userId) {
      return jsonWithRequest(request, { error: "forbidden_id_ownership" }, 403);
    }
  }

  // P2 #11: Idempotency-Key deduplication for Outbox replay safety
  if (matchesPayloadScopedIdempotencyKey && existingRow) {
    return jsonWithRequest(
      request,
      {
        id: existingRow.id,
        logged_date: existingRow.logged_date,
        updated_at: existingRow.updated_at,
      },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  if (!payload.id || !isUUID(payload.id)) {
    return jsonWithRequest(request, { error: "invalid_id" }, 400);
  }
  if (
    typeof payload.logged_date !== "string" || !isLocalDate(payload.logged_date)
  ) {
    return jsonWithRequest(request, { error: "invalid_logged_date" }, 400);
  }
  if (
    typeof payload.logged_at !== "string" ||
    Number.isNaN(new Date(payload.logged_at).getTime())
  ) {
    return jsonWithRequest(request, { error: "invalid_logged_at" }, 400);
  }
  if (!payload.input_method || !VALID_INPUT_METHODS.has(payload.input_method)) {
    return jsonWithRequest(request, { error: "invalid_input_method" }, 400);
  }
  if (
    payload.meal_type != null &&
    (typeof payload.meal_type !== "string" ||
      !VALID_MEAL_TYPES.has(payload.meal_type))
  ) {
    return jsonWithRequest(request, { error: "invalid_meal_type" }, 400);
  }
  if (
    payload.context != null &&
    (typeof payload.context !== "string" ||
      !VALID_CONTEXTS.has(payload.context))
  ) {
    return jsonWithRequest(request, { error: "invalid_context" }, 400);
  }
  if (
    payload.ai_feedback != null &&
    (typeof payload.ai_feedback !== "string" ||
      !VALID_AI_FEEDBACK.has(payload.ai_feedback))
  ) {
    return jsonWithRequest(request, { error: "invalid_ai_feedback" }, 400);
  }
  if (
    payload.deleted_reason != null &&
    (typeof payload.deleted_reason !== "string" ||
      !VALID_DELETED_REASONS.has(payload.deleted_reason))
  ) {
    return jsonWithRequest(request, { error: "invalid_deleted_reason" }, 400);
  }

  const calories = toFinite(payload.calories);
  const protein = toFinite(payload.protein_g);
  const fat = toFinite(payload.fat_g);
  const carbs = toFinite(payload.carbs_g);

  if (calories == null || protein == null || fat == null || carbs == null) {
    return jsonWithRequest(request, { error: "missing_required_macros" }, 400);
  }
  if (
    !isWithin(calories, 0, 10_000) ||
    !isWithin(protein, 0, 1_000) ||
    !isWithin(fat, 0, 1_000) ||
    !isWithin(carbs, 0, 1_000)
  ) {
    return jsonWithRequest(request, { error: "invalid_macro_ranges" }, 400);
  }

  // Ignore body-level user_id spoofing; user comes from JWT.
  if (payload.user_id && payload.user_id !== userId) {
    return jsonWithRequest(request, { error: "forbidden_user_mismatch" }, 403);
  }

  const aiConfidence = toFiniteOrNull(payload.ai_confidence);
  if (aiConfidence != null && !isWithin(aiConfidence, 0, 1)) {
    return jsonWithRequest(request, { error: "invalid_ai_confidence" }, 400);
  }

  const minutesSinceWorkout = toIntegerOrNull(payload.minutes_since_workout);
  const loggedUtcOffsetMinutes = toIntegerOrNull(
    payload.logged_utc_offset_minutes,
  );
  const fiber = toFiniteOrNull(payload.fiber_g);
  const sugar = toFiniteOrNull(payload.sugar_g);
  const alcoholUnits = toFiniteOrNull(payload.alcohol_units);
  const caffeineMg = toIntegerOrNull(payload.caffeine_mg);
  const sodiumMg = toFiniteOrNull(payload.sodium_mg);
  const potassiumMg = toFiniteOrNull(payload.potassium_mg);
  const calciumMg = toFiniteOrNull(payload.calcium_mg);
  const ironMg = toFiniteOrNull(payload.iron_mg);
  const vitaminDMcg = toFiniteOrNull(payload.vitamin_d_mcg);
  const vitaminB12Mcg = toFiniteOrNull(payload.vitamin_b12_mcg);

  if (
    minutesSinceWorkout != null && !isWithin(minutesSinceWorkout, 0, 10_080)
  ) {
    return jsonWithRequest(
      request,
      { error: "invalid_minutes_since_workout" },
      400,
    );
  }
  if (
    loggedUtcOffsetMinutes != null &&
    !isWithin(loggedUtcOffsetMinutes, -840, 840)
  ) {
    return jsonWithRequest(request, {
      error: "invalid_logged_utc_offset_minutes",
    }, 400);
  }
  if (
    !isOptionalWithin(fiber, 0, 500) ||
    !isOptionalWithin(sugar, 0, 500) ||
    !isOptionalWithin(alcoholUnits, 0, 40) ||
    !isOptionalWithin(caffeineMg, 0, 2_000) ||
    !isOptionalWithin(sodiumMg, 0, 20_000) ||
    !isOptionalWithin(potassiumMg, 0, 20_000) ||
    !isOptionalWithin(calciumMg, 0, 20_000) ||
    !isOptionalWithin(ironMg, 0, 200) ||
    !isOptionalWithin(vitaminDMcg, 0, 500) ||
    !isOptionalWithin(vitaminB12Mcg, 0, 2_000)
  ) {
    return jsonWithRequest(request, { error: "invalid_nutrient_ranges" }, 400);
  }

  const fallbackTimezone = timezone ?? "UTC";
  const loggedTimezone = sanitizeTimeZone(
    payload.logged_timezone,
    fallbackTimezone,
  );

  const needsReview = aiConfidence != null
    ? aiConfidence < 0.65
    : Boolean(payload.needs_review ?? false);
  const imageUploadedAt = toIsoStringOrNull(payload.image_uploaded_at);
  const aiFeedbackAt = toIsoStringOrNull(payload.ai_feedback_at);
  const deletedAt = toIsoStringOrNull(payload.deleted_at);

  const row = {
    id: payload.id,
    user_id: userId,
    logged_at: new Date(payload.logged_at).toISOString(),
    logged_date: payload.logged_date,
    logged_timezone: loggedTimezone,
    logged_utc_offset_minutes: loggedUtcOffsetMinutes,
    input_method: payload.input_method,
    meal_type: payload.meal_type ?? null,
    context: payload.context ?? null,
    pre_workout: payload.pre_workout ?? false,
    post_workout: payload.post_workout ?? false,
    minutes_since_workout: minutesSinceWorkout,
    calories,
    protein_g: protein,
    fat_g: fat,
    carbs_g: carbs,
    fiber_g: fiber,
    sugar_g: sugar,
    alcohol_units: alcoholUnits,
    caffeine_mg: caffeineMg,
    sodium_mg: sodiumMg,
    potassium_mg: potassiumMg,
    calcium_mg: calciumMg,
    iron_mg: ironMg,
    vitamin_d_mcg: vitaminDMcg,
    vitamin_b12_mcg: vitaminB12Mcg,
    image_url: payload.image_url ?? null,
    image_uploaded_at: imageUploadedAt,
    ai_detected_items: payload.ai_detected_items ?? null,
    ai_confidence: aiConfidence,
    ai_context_analysis: payload.ai_context_analysis ?? null,
    needs_review: needsReview,
    user_corrected: payload.user_corrected ?? false,
    user_notes: payload.user_notes ?? null,
    ai_feedback: payload.ai_feedback ?? null,
    ai_feedback_details: payload.ai_feedback_details ?? null,
    ai_feedback_at: aiFeedbackAt,
    deleted_at: deletedAt,
    deleted_reason: payload.deleted_reason ?? null,
    synced_to_vector_db: payload.synced_to_vector_db ?? false,
    vector_id: payload.vector_id ?? null,
  };

  const { data: upserted, error: upsertError } = await service
    .from("food_logs")
    .upsert(row, { onConflict: "id" })
    .select("id,logged_date,updated_at")
    .single<{ id: string; logged_date: string; updated_at: string }>();

  if (upsertError) {
    return jsonWithRequest(request, {
      error: "food_log_upsert_failed",
      detail: sanitizedInternalDetail(request, "index", upsertError),
    }, 500);
  }

  return jsonWithRequest(request, {
    id: upserted.id,
    logged_date: upserted.logged_date,
    updated_at: upserted.updated_at,
  }, 202);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function toFinite(value: number | undefined): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return value;
}

function toFiniteOrNull(value: number | null | undefined): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return value;
}

function toIntegerOrNull(value: number | null | undefined): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.trunc(value);
}

function isWithin(value: number, min: number, max: number): boolean {
  return value >= min && value <= max;
}

function isOptionalWithin(
  value: number | null,
  min: number,
  max: number,
): boolean {
  return value == null || isWithin(value, min, max);
}

function sanitizeTimeZone(
  value: string | null | undefined,
  fallback: string,
): string {
  const candidate = typeof value === "string" ? value.trim() : "";
  if (!candidate) return fallback;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: candidate }).format(
      new Date(),
    );
    return candidate;
  } catch {
    return fallback;
  }
}

function toIsoStringOrNull(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString();
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readRequiredString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
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
