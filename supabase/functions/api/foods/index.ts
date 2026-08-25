import { pathnameTail } from "../../_shared/date_range.ts";
import {
  createSupabaseFoodsRepository,
  defaultFoodsProvider,
  FoodsError,
  isBarcodeCode,
  lookupFoodByBarcode,
  type MacrosPer100g,
  searchFoods,
} from "../../_shared/foods_provider.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

const VALID_PROVIDERS = new Set([
  "open_food_facts",
  "lifeos_label_ocr",
  "usda",
  "edamam",
  "manual_import",
  "other",
]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST", "DELETE"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const path = pathnameTail(new URL(request.url).pathname);
  const route = (path[0] ?? "").toLowerCase();
  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { userId, service } = userResult.context;

  if (request.method === "GET" && route === "search") {
    return await handleSearch(request, service, userId);
  }

  if (request.method === "GET" && route === "barcode") {
    return await handleBarcodeLookup(request, service, userId, path[1] ?? "");
  }

  if (
    request.method === "POST" && route === "barcode" &&
    (path[2] ?? "").toLowerCase() === "create"
  ) {
    return await handleBarcodeCreate(request, service, userId, path[1] ?? "");
  }

  if (request.method === "POST" && route === "custom") {
    return await handleCustomCreate(request, service, userId);
  }

  if (request.method === "POST" && route === "favorites") {
    return await handleFavoriteCreate(request, service, userId);
  }

  if (request.method === "GET" && route === "favorites") {
    return await handleFavoriteList(request, service, userId);
  }

  if (request.method === "DELETE" && route === "favorites") {
    return await handleFavoriteDelete(
      request,
      service,
      userId,
      path[1] ?? "",
      path[2] ?? "",
    );
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleSearch(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const query = (url.searchParams.get("q") ?? "").trim();
  if (!query) {
    return jsonWithRequest(request, { error: "query_required" }, 400);
  }

  const rawLimit = Number.parseInt(url.searchParams.get("limit") ?? "20", 10);
  const limit = Number.isFinite(rawLimit)
    ? Math.min(50, Math.max(1, rawLimit))
    : 20;
  try {
    const response = await searchFoods({
      repository: createSupabaseFoodsRepository(service),
      provider: defaultFoodsProvider(),
      userId,
      query,
      limit,
      locale: requestLocale(request),
    });

    return jsonWithRequest(request, response);
  } catch (error) {
    if (isFoodsError(error)) {
      return jsonWithRequest(request, {
        error: error.code,
        detail: sanitizedInternalDetail(request, "index", error),
      }, error.status);
    }
    throw error;
  }
}

async function handleBarcodeLookup(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  codeRaw: string,
): Promise<Response> {
  const code = codeRaw.trim();
  if (!isBarcodeCode(code)) {
    return jsonWithRequest(request, { error: "invalid_barcode" }, 400);
  }
  try {
    const outcome = await lookupFoodByBarcode({
      repository: createSupabaseFoodsRepository(service),
      provider: defaultFoodsProvider(),
      userId,
      barcode: code,
      locale: requestLocale(request),
    });

    if (outcome.status === "found") {
      return jsonWithRequest(request, outcome.item);
    }
    if (outcome.status === "provider_unavailable") {
      return jsonWithRequest(request, { error: "provider_unavailable" }, 503);
    }
    if (outcome.status === "insufficient_nutrition_data") {
      return jsonWithRequest(request, {
        error: "insufficient_nutrition_data",
      }, 422);
    }
    return jsonWithRequest(request, { error: "barcode_not_found" }, 404);
  } catch (error) {
    if (isFoodsError(error)) {
      return jsonWithRequest(request, {
        error: error.code,
        detail: sanitizedInternalDetail(request, "index", error),
      }, error.status);
    }
    throw error;
  }
}

async function handleBarcodeCreate(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  codeRaw: string,
): Promise<Response> {
  const code = codeRaw.trim();
  if (!isBarcodeCode(code)) {
    return jsonWithRequest(request, { error: "invalid_barcode" }, 400);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const provider = typeof payload.provider === "string"
    ? payload.provider.trim()
    : "";
  const name = typeof payload.name === "string" ? payload.name.trim() : "";
  if (!VALID_PROVIDERS.has(provider)) {
    return jsonWithRequest(request, { error: "invalid_provider" }, 400);
  }
  if (!name) {
    return jsonWithRequest(request, { error: "name_required" }, 400);
  }

  const macrosParsed = parseMacros(payload.macros_per_100g);
  if (!macrosParsed.ok) {
    return jsonWithRequest(request, { error: macrosParsed.error }, 400);
  }

  const rowId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : crypto.randomUUID();

  const { data: inserted, error } = await service
    .from("food_catalog_items")
    .upsert({
      id: rowId,
      provider,
      barcode: code,
      provider_item_id: code,
      created_by_user_id: userId,
      name,
      brand: optionalString(payload.brand),
      serving_size_g: toNumberOrNull(payload.serving_size_g),
      calories_per_100g: macrosParsed.value.calories,
      protein_per_100g: macrosParsed.value.protein_g,
      fat_per_100g: macrosParsed.value.fat_g,
      carbs_per_100g: macrosParsed.value.carbs_g,
      fiber_per_100g: macrosParsed.value.fiber_g,
      source_confidence: toUnitFloatOrNull(payload.source_confidence),
      expires_at: null,
    }, { onConflict: "provider,barcode" })
    .select("id,provider,barcode")
    .single<{ id: string; provider: string; barcode: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "barcode_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, {
    type: "catalog",
    provider: inserted.provider,
    id: inserted.id,
    barcode: inserted.barcode,
  });
}

async function handleCustomCreate(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const name = typeof payload.name === "string" ? payload.name.trim() : "";
  if (!name) {
    return jsonWithRequest(request, { error: "name_required" }, 400);
  }

  const macrosParsed = parseMacros(payload.macros_per_100g);
  if (!macrosParsed.ok) {
    return jsonWithRequest(request, { error: macrosParsed.error }, 400);
  }

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const rowId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());

  const { data: inserted, error } = await service
    .from("user_foods")
    .upsert({
      id: rowId,
      user_id: userId,
      name,
      brand: optionalString(payload.brand),
      barcode: optionalString(payload.barcode),
      default_serving_g: toNumberOrNull(payload.default_serving_g),
      calories_per_100g: macrosParsed.value.calories,
      protein_per_100g: macrosParsed.value.protein_g,
      fat_per_100g: macrosParsed.value.fat_g,
      carbs_per_100g: macrosParsed.value.carbs_g,
      fiber_per_100g: macrosParsed.value.fiber_g,
    }, { onConflict: "id" })
    .select("id,name,created_at")
    .single<{ id: string; name: string; created_at: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "custom_food_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, {
    id: inserted.id,
    name: inserted.name,
    created_at: inserted.created_at,
  });
}

async function handleFavoriteCreate(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const refType = typeof payload.ref_type === "string"
    ? payload.ref_type.trim().toLowerCase()
    : "";
  const refId = typeof payload.ref_id === "string" ? payload.ref_id.trim() : "";

  if (refType !== "catalog" && refType !== "custom") {
    return jsonWithRequest(request, { error: "invalid_ref_type" }, 400);
  }
  if (!isUUID(refId)) {
    return jsonWithRequest(request, { error: "invalid_ref_id" }, 400);
  }

  const favoriteId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : crypto.randomUUID();

  const { data, error } = await service
    .from("user_food_favorites")
    .upsert({
      id: favoriteId,
      user_id: userId,
      ref_type: refType,
      ref_id: refId,
    }, { onConflict: "user_id,ref_type,ref_id" })
    .select("id")
    .single<{ id: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "favorite_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, {
    ok: true,
    id: data.id,
  });
}

async function handleFavoriteList(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const { data, error } = await service
    .from("user_food_favorites")
    .select("id,ref_type,ref_id,created_at,updated_at")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .returns<
      Array<{
        id: string;
        ref_type: "catalog" | "custom";
        ref_id: string;
        created_at: string;
        updated_at: string;
      }>
    >();

  if (error) {
    return jsonWithRequest(request, {
      error: "favorites_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, {
    favorites: data ?? [],
  });
}

async function handleFavoriteDelete(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  refTypeRaw: string,
  refIdRaw: string,
): Promise<Response> {
  const refType = refTypeRaw.trim().toLowerCase();
  const refId = refIdRaw.trim();

  if (refType !== "catalog" && refType !== "custom") {
    return jsonWithRequest(request, { error: "invalid_ref_type" }, 400);
  }
  if (!isUUID(refId)) {
    return jsonWithRequest(request, { error: "invalid_ref_id" }, 400);
  }

  const { error } = await service
    .from("user_food_favorites")
    .delete()
    .eq("user_id", userId)
    .eq("ref_type", refType)
    .eq("ref_id", refId);

  if (error) {
    return jsonWithRequest(request, {
      error: "favorite_delete_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, { ok: true });
}

function parseMacros(value: unknown):
  | { ok: true; value: MacrosPer100g }
  | { ok: false; error: string } {
  if (!isObject(value)) return { ok: false, error: "invalid_macros_per_100g" };

  const calories = toNumberOrNull(value.calories);
  const protein = toNumberOrNull(value.protein_g);
  const fat = toNumberOrNull(value.fat_g);
  const carbs = toNumberOrNull(value.carbs_g);
  const fiber = value.fiber_g == null ? null : toNumberOrNull(value.fiber_g);

  if (calories == null || protein == null || fat == null || carbs == null) {
    return { ok: false, error: "invalid_macros_per_100g" };
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

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function toNumberOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Number(value);
}

function toUnitFloatOrNull(value: unknown): number | null {
  const parsed = toNumberOrNull(value);
  if (parsed == null) return null;
  if (parsed < 0 || parsed > 1) return null;
  return parsed;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function requestLocale(request: Request): string | null {
  const explicit = request.headers.get("X-Locale")?.trim();
  if (explicit) return explicit;
  return request.headers.get("Accept-Language")?.split(",")[0]?.trim() ?? null;
}

function isFoodsError(error: unknown): error is FoodsError {
  return error instanceof FoodsError;
}
