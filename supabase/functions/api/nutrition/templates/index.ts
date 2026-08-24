import {
  localDateToday,
  parseLocalDateParam,
  pathnameTail,
  safeTimeZone,
} from "../../../_shared/date_range.ts";
import { isLocalDate } from "../../../_shared/datetime.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface MealTemplateRow {
  id: string;
  name: string;
  meal_type: string | null;
  template_items: unknown;
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
  times_used: number;
  last_used_at: string | null;
  archived: boolean;
  updated_at: string;
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
  const queryTemplateId = url.searchParams.get("id")?.trim() ?? "";
  const templateId = queryTemplateId || (tail[0] ?? "");
  const action = (tail[1] ?? "").toLowerCase();

  if (request.method === "GET") {
    if (templateId) {
      const { data, error } = await service
        .from("meal_templates")
        .select(
          "id,name,meal_type,template_items,calories,protein_g,fat_g,carbs_g,fiber_g,times_used,last_used_at,archived,updated_at",
        )
        .eq("user_id", userId)
        .eq("id", templateId)
        .is("deleted_at", null)
        .maybeSingle<MealTemplateRow>();

      if (error) {
        return jsonWithRequest(request, {
          error: "template_fetch_failed",
          detail: error.message,
        }, 500);
      }
      if (!data) {
        return jsonWithRequest(request, { error: "template_not_found" }, 404);
      }
      return jsonWithRequest(request, data);
    }

    const { data, error } = await service
      .from("meal_templates")
      .select(
        "id,name,meal_type,calories,protein_g,fat_g,carbs_g,fiber_g,times_used,last_used_at,archived,updated_at",
      )
      .eq("user_id", userId)
      .is("deleted_at", null)
      .order("updated_at", { ascending: false })
      .returns<Array<Omit<MealTemplateRow, "template_items">>>();

    if (error) {
      return jsonWithRequest(request, {
        error: "templates_fetch_failed",
        detail: error.message,
      }, 500);
    }

    return jsonWithRequest(request, { templates: data ?? [] });
  }

  if (request.method === "PATCH") {
    if (!isUUID(templateId)) {
      return jsonWithRequest(request, { error: "invalid_template_id" }, 400);
    }

    let payload: Record<string, unknown>;
    try {
      payload = await request.json();
    } catch {
      return jsonWithRequest(request, { error: "invalid_json" }, 400);
    }

    const updates: Record<string, unknown> = {};

    const name = readOptionalTrimmedString(payload.name);
    if (name != null) {
      if (!name) {
        return jsonWithRequest(request, { error: "name_required" }, 400);
      }
      updates.name = name;
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

    if (Object.prototype.hasOwnProperty.call(payload, "archived")) {
      if (typeof payload.archived !== "boolean") {
        return jsonWithRequest(request, { error: "invalid_archived" }, 400);
      }
      updates.archived = payload.archived;
    }

    if (Object.prototype.hasOwnProperty.call(payload, "template_items")) {
      if (payload.template_items == null) {
        return jsonWithRequest(
          request,
          { error: "template_items_required" },
          400,
        );
      }
      updates.template_items = payload.template_items;
    }

    for (
      const field of [
        "calories",
        "protein_g",
        "fat_g",
        "carbs_g",
        "fiber_g",
      ] as const
    ) {
      if (Object.prototype.hasOwnProperty.call(payload, field)) {
        if (payload[field] != null && typeof payload[field] !== "number") {
          return jsonWithRequest(request, { error: `invalid_${field}` }, 400);
        }
        updates[field] = payload[field] ?? null;
      }
    }

    if (Object.keys(updates).length === 0) {
      return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
    }

    const { data, error } = await service
      .from("meal_templates")
      .update(updates)
      .eq("id", templateId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .select(
        "id,name,meal_type,template_items,calories,protein_g,fat_g,carbs_g,fiber_g,times_used,last_used_at,archived,updated_at",
      )
      .maybeSingle<MealTemplateRow>();

    if (error) {
      return jsonWithRequest(request, {
        error: "template_update_failed",
        detail: error.message,
      }, 500);
    }
    if (!data) {
      return jsonWithRequest(request, { error: "template_not_found" }, 404);
    }

    return jsonWithRequest(request, data);
  }

  // POST handlers
  if (isUUID(templateId) && action === "log") {
    const { data: template, error: templateError } = await service
      .from("meal_templates")
      .select(
        "id,name,meal_type,calories,protein_g,fat_g,carbs_g,fiber_g,times_used",
      )
      .eq("id", templateId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .maybeSingle<{
        id: string;
        name: string;
        meal_type: string | null;
        calories: number;
        protein_g: number;
        fat_g: number;
        carbs_g: number;
        fiber_g: number | null;
        times_used: number;
      }>();

    if (templateError) {
      return jsonWithRequest(request, {
        error: "template_fetch_failed",
        detail: templateError.message,
      }, 500);
    }
    if (!template) {
      return jsonWithRequest(request, { error: "template_not_found" }, 404);
    }

    let payload: Record<string, unknown> = {};
    try {
      payload = await request.json();
    } catch {
      // empty body is valid
    }

    const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
    const foodLogId = isUUID(idempotencyKey)
      ? idempotencyKey
      : crypto.randomUUID();
    if (isUUID(idempotencyKey)) {
      const { data: existing } = await service
        .from("food_logs")
        .select("id")
        .eq("id", foodLogId)
        .eq("user_id", userId)
        .maybeSingle<{ id: string }>();
      if (existing) {
        return jsonWithRequest(
          request,
          { food_log_id: existing.id, idempotent_replay: true },
          202,
          { "X-Idempotent-Replay": "true" },
        );
      }
    }

    const loggedAt = toIsoString(payload.logged_at) ?? new Date().toISOString();
    const providedDate = parseLocalDateParam(request, "logged_date") ??
      (typeof payload.logged_date === "string" &&
          isLocalDate(payload.logged_date)
        ? payload.logged_date
        : null);
    const loggedDate = providedDate ?? localDateToday(safeTimeZone(timezone));

    const mealTypeOverride = readOptionalNullableString(payload.meal_type);
    const mealType = mealTypeOverride || template.meal_type;
    if (
      mealType != null && mealType !== "" && !VALID_MEAL_TYPES.has(mealType)
    ) {
      return jsonWithRequest(request, { error: "invalid_meal_type" }, 400);
    }

    const context = readOptionalNullableString(payload.context);
    if (context != null && context !== "" && !VALID_CONTEXTS.has(context)) {
      return jsonWithRequest(request, { error: "invalid_context" }, 400);
    }

    const { error: insertError } = await service
      .from("food_logs")
      .insert({
        id: foodLogId,
        user_id: userId,
        logged_at: loggedAt,
        logged_date: loggedDate,
        logged_timezone: safeTimeZone(timezone),
        input_method: "template",
        meal_type: mealType || null,
        context: context || null,
        calories: template.calories,
        protein_g: template.protein_g,
        fat_g: template.fat_g,
        carbs_g: template.carbs_g,
        fiber_g: template.fiber_g,
        needs_review: false,
      });

    if (insertError) {
      return jsonWithRequest(request, {
        error: "food_log_insert_failed",
        detail: insertError.message,
      }, 500);
    }

    const nowIso = new Date().toISOString();
    const { error: usageError } = await service
      .from("meal_templates")
      .update({
        times_used: template.times_used + 1,
        last_used_at: nowIso,
      })
      .eq("id", template.id)
      .eq("user_id", userId);

    if (usageError) {
      return jsonWithRequest(request, {
        error: "template_usage_update_failed",
        detail: usageError.message,
      }, 500);
    }

    return jsonWithRequest(request, { food_log_id: foodLogId }, 202);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const name = readOptionalTrimmedString(payload.name);
  if (!name) {
    return jsonWithRequest(request, { error: "name_required" }, 400);
  }

  const hasExplicitId = Object.prototype.hasOwnProperty.call(payload, "id");
  const explicitTemplateId = typeof payload.id === "string"
    ? payload.id.trim()
    : "";
  if (hasExplicitId && !isUUID(explicitTemplateId)) {
    return jsonWithRequest(request, { error: "invalid_template_id" }, 400);
  }

  const templateItems = payload.template_items;
  if (templateItems == null) {
    return jsonWithRequest(request, { error: "template_items_required" }, 400);
  }

  const calories = readRequiredNumber(payload.calories, "calories");
  if (calories == null) {
    return jsonWithRequest(request, { error: "invalid_calories" }, 400);
  }
  const protein = readRequiredNumber(payload.protein_g, "protein_g");
  if (protein == null) {
    return jsonWithRequest(request, { error: "invalid_protein_g" }, 400);
  }
  const fat = readRequiredNumber(payload.fat_g, "fat_g");
  if (fat == null) {
    return jsonWithRequest(request, { error: "invalid_fat_g" }, 400);
  }
  const carbs = readRequiredNumber(payload.carbs_g, "carbs_g");
  if (carbs == null) {
    return jsonWithRequest(request, { error: "invalid_carbs_g" }, 400);
  }

  const mealType = readOptionalNullableString(payload.meal_type);
  if (mealType != null && mealType !== "" && !VALID_MEAL_TYPES.has(mealType)) {
    return jsonWithRequest(request, { error: "invalid_meal_type" }, 400);
  }

  const fiber = payload.fiber_g == null
    ? null
    : (typeof payload.fiber_g === "number" ? payload.fiber_g : Number.NaN);
  if (fiber != null && !Number.isFinite(fiber)) {
    return jsonWithRequest(request, { error: "invalid_fiber_g" }, 400);
  }

  let archived = false;
  if (Object.prototype.hasOwnProperty.call(payload, "archived")) {
    if (typeof payload.archived !== "boolean") {
      return jsonWithRequest(request, { error: "invalid_archived" }, 400);
    }
    archived = payload.archived;
  }

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const createTemplateId = explicitTemplateId ||
    (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());

  const { data: existing, error: existingError } = await service
    .from("meal_templates")
    .select(
      "id,name,meal_type,template_items,calories,protein_g,fat_g,carbs_g,fiber_g,times_used,last_used_at,archived,updated_at",
    )
    .eq("user_id", userId)
    .eq("id", createTemplateId)
    .is("deleted_at", null)
    .maybeSingle<MealTemplateRow>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "template_fetch_failed",
      detail: existingError.message,
    }, 500);
  }

  if (existing) {
    return jsonWithRequest(request, existing, 200);
  }

  const templateInsert = {
    id: createTemplateId,
    user_id: userId,
    name,
    meal_type: mealType || null,
    template_items: templateItems,
    calories,
    protein_g: protein,
    fat_g: fat,
    carbs_g: carbs,
    fiber_g: fiber,
    archived,
  };

  const { data: created, error: createError } = await service
    .from("meal_templates")
    .insert(templateInsert)
    .select(
      "id,name,meal_type,template_items,calories,protein_g,fat_g,carbs_g,fiber_g,times_used,last_used_at,archived,updated_at",
    )
    .single<MealTemplateRow>();

  if (createError) {
    return jsonWithRequest(request, {
      error: "template_create_failed",
      detail: createError.message,
    }, 500);
  }

  return jsonWithRequest(request, created, 201);
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
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

function readRequiredNumber(value: unknown, _field: string): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return value;
}

function toIsoString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString();
}
