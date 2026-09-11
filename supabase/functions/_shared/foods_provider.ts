const OPEN_FOOD_FACTS_PROVIDER = "open_food_facts";
const LABEL_OCR_PROVIDER = "lifeos_label_ocr";
const OPEN_FOOD_FACTS_BASE_URL = "https://world.openfoodfacts.org";
const OPEN_FOOD_FACTS_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const DEFAULT_SEARCH_TIMEOUT_MS = 2_500;
const DEFAULT_BARCODE_TIMEOUT_MS = 3_500;

const CATALOG_SELECT =
  "id,provider,name,brand,barcode,serving_size_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,fiber_per_100g,fetched_at,expires_at";
const CUSTOM_SELECT =
  "id,name,brand,barcode,default_serving_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,fiber_per_100g,created_at";

type ServiceClient = ReturnType<
  typeof import("./supabase.ts").serviceRoleClient
>;

export interface FavoriteRow {
  ref_type: "catalog" | "custom";
  ref_id: string;
}

export interface RecentItemRow {
  user_food_id: string | null;
  catalog_item_id: string | null;
}

export interface CustomFoodRow {
  id: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  default_serving_g: number | null;
  calories_per_100g: number;
  protein_per_100g: number;
  fat_per_100g: number;
  carbs_per_100g: number;
  fiber_per_100g: number | null;
  created_at: string;
}

export interface CustomBarcodeFoodRow
  extends Omit<CustomFoodRow, "created_at"> {}

export interface CatalogFoodRow {
  id: string;
  provider: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  serving_size_g: number | null;
  calories_per_100g: number;
  protein_per_100g: number;
  fat_per_100g: number;
  carbs_per_100g: number;
  fiber_per_100g: number | null;
  fetched_at: string;
  expires_at: string | null;
}

export interface MacrosPer100g {
  calories: number;
  protein_g: number;
  fat_g: number;
  carbs_g: number;
  fiber_g: number | null;
}

export interface FoodSearchResult {
  type: "catalog" | "custom";
  id: string;
  provider?: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  serving_size_g: number | null;
  macros_per_100g: MacrosPer100g;
  tags: string[];
}

export interface BarcodeLookupResponse {
  type: "catalog" | "custom";
  id: string;
  provider?: string;
  name: string;
  brand: string | null;
  barcode: string | null;
  serving_size_g: number | null;
  macros_per_100g: MacrosPer100g;
  tags?: string[];
  fetched_at?: string;
  expires_at?: string | null;
}

export type BarcodeLookupOutcome =
  | { status: "found"; item: BarcodeLookupResponse }
  | { status: "not_found" }
  | { status: "provider_unavailable" }
  | { status: "insufficient_nutrition_data" };

export interface CatalogFoodUpsertInput {
  provider: typeof OPEN_FOOD_FACTS_PROVIDER;
  provider_item_id: string;
  barcode: string;
  name: string;
  brand: string | null;
  locale: string | null;
  image_url: string | null;
  serving_size_g: number | null;
  macros_per_100g: MacrosPer100g;
  sugar_per_100g: number | null;
  sodium_mg_per_100g: number | null;
  source_confidence: number | null;
  fetched_at: string;
  expires_at: string;
}

export interface FoodsRepository {
  listFavoriteRefs(userId: string): Promise<FavoriteRow[]>;
  listRecentRefs(userId: string): Promise<RecentItemRow[]>;
  searchCustomFoods(
    userId: string,
    query: string,
    limit: number,
  ): Promise<CustomFoodRow[]>;
  searchCatalogFoods(
    userId: string,
    query: string,
    limit: number,
  ): Promise<CatalogFoodRow[]>;
  findCustomFoodByBarcode(
    userId: string,
    barcode: string,
  ): Promise<CustomBarcodeFoodRow | null>;
  findCatalogFoodByBarcode(
    provider: string,
    barcode: string,
    userId?: string | null,
  ): Promise<CatalogFoodRow | null>;
  upsertCatalogFood(
    payload: CatalogFoodUpsertInput,
  ): Promise<CatalogFoodRow | null>;
}

export interface FoodsProvider {
  lookupBarcode(
    barcode: string,
    locale?: string | null,
    now?: Date,
  ): Promise<CatalogFoodUpsertInput | null>;
  search(
    query: string,
    limit: number,
    locale?: string | null,
    now?: Date,
  ): Promise<CatalogFoodUpsertInput[]>;
}

interface SearchCandidate extends FoodSearchResult {
  score: number;
}

interface MacroNormalization {
  macros: MacrosPer100g;
  sugarPer100g: number | null;
  sodiumMgPer100g: number | null;
  usedServingFallback: boolean;
  correctedCalories: boolean;
}

type NormalizedProduct =
  | { ok: true; value: CatalogFoodUpsertInput }
  | { ok: false; reason: "insufficient_nutrition_data" };

export class FoodsError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message?: string) {
    super(message ?? code);
    this.name = "FoodsError";
    this.status = status;
    this.code = code;
  }
}

export function createSupabaseFoodsRepository(
  service: ServiceClient,
): FoodsRepository {
  return {
    async listFavoriteRefs(userId) {
      const { data, error } = await service
        .from("user_food_favorites")
        .select("ref_type,ref_id")
        .eq("user_id", userId)
        .returns<FavoriteRow[]>();
      if (error) {
        throw new FoodsError(500, "favorites_fetch_failed", error.message);
      }
      return data ?? [];
    },

    async listRecentRefs(userId) {
      const { data, error } = await service
        .from("food_items")
        .select("user_food_id,catalog_item_id")
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .limit(80)
        .returns<RecentItemRow[]>();
      if (error) {
        throw new FoodsError(500, "recent_foods_fetch_failed", error.message);
      }
      return data ?? [];
    },

    async searchCustomFoods(userId, query, limit) {
      const { data, error } = await service
        .from("user_foods")
        .select(CUSTOM_SELECT)
        .eq("user_id", userId)
        .ilike("name", `%${escapeIlike(query)}%`)
        .order("created_at", { ascending: false })
        .limit(limit)
        .returns<CustomFoodRow[]>();
      if (error) {
        throw new FoodsError(500, "custom_foods_fetch_failed", error.message);
      }
      return data ?? [];
    },

    async searchCatalogFoods(userId, query, limit) {
      // Row Level Security deliberately hides user-created catalog entries from
      // other accounts; the service-role query must apply the same scope.
      const { data, error } = await service
        .from("food_catalog_items")
        .select(CATALOG_SELECT)
        .ilike("name", `%${escapeIlike(query)}%`)
        .or(`created_by_user_id.is.null,created_by_user_id.eq.${userId}`)
        .order("fetched_at", { ascending: false })
        .limit(limit)
        .returns<CatalogFoodRow[]>();
      if (error) {
        throw new FoodsError(500, "catalog_foods_fetch_failed", error.message);
      }
      return data ?? [];
    },

    async findCustomFoodByBarcode(userId, barcode) {
      const { data, error } = await service
        .from("user_foods")
        .select(
          "id,name,brand,barcode,default_serving_g,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g,fiber_per_100g",
        )
        .eq("user_id", userId)
        .eq("barcode", barcode)
        .maybeSingle<CustomBarcodeFoodRow>();
      if (error) {
        throw new FoodsError(500, "barcode_lookup_failed", error.message);
      }
      return data;
    },

    async findCatalogFoodByBarcode(provider, barcode, userId) {
      let query = service
        .from("food_catalog_items")
        .select(CATALOG_SELECT)
        .eq("provider", provider)
        .eq("barcode", barcode);
      query = userId
        ? query.or(`created_by_user_id.is.null,created_by_user_id.eq.${userId}`)
        : query.is("created_by_user_id", null);
      const { data, error } = await query
        .order("fetched_at", { ascending: false })
        .limit(1)
        .maybeSingle<CatalogFoodRow>();
      if (error) {
        throw new FoodsError(500, "barcode_lookup_failed", error.message);
      }
      return data;
    },

    async upsertCatalogFood(payload) {
      if (payload.barcode) {
        const { data: existing, error: existingError } = await service
          .from("food_catalog_items")
          .select("id,created_by_user_id")
          .eq("provider", payload.provider)
          .eq("barcode", payload.barcode)
          .maybeSingle<{ id: string; created_by_user_id: string | null }>();
        if (existingError) {
          throw new FoodsError(
            500,
            "catalog_cache_failed",
            existingError.message,
          );
        }
        if (existing && existing.created_by_user_id !== null) {
          // The owner-immutability trigger forbids re-attributing a
          // user-created row to the shared provider cache. Leave it alone.
          return null;
        }
      }
      const { data, error } = await service
        .from("food_catalog_items")
        .upsert({
          provider: payload.provider,
          provider_item_id: payload.provider_item_id,
          barcode: payload.barcode,
          created_by_user_id: null,
          name: payload.name,
          brand: payload.brand,
          locale: payload.locale,
          image_url: payload.image_url,
          serving_size_g: payload.serving_size_g,
          calories_per_100g: payload.macros_per_100g.calories,
          protein_per_100g: payload.macros_per_100g.protein_g,
          fat_per_100g: payload.macros_per_100g.fat_g,
          carbs_per_100g: payload.macros_per_100g.carbs_g,
          fiber_per_100g: payload.macros_per_100g.fiber_g,
          sugar_per_100g: payload.sugar_per_100g,
          sodium_mg_per_100g: payload.sodium_mg_per_100g,
          source_confidence: payload.source_confidence,
          fetched_at: payload.fetched_at,
          expires_at: payload.expires_at,
        }, { onConflict: "provider,barcode" })
        .select(CATALOG_SELECT)
        .single<CatalogFoodRow>();
      if (error) {
        throw new FoodsError(500, "catalog_cache_failed", error.message);
      }
      return data;
    },
  };
}

export function defaultFoodsProvider(): FoodsProvider {
  return new OpenFoodFactsProvider();
}

export async function searchFoods(args: {
  repository: FoodsRepository;
  provider?: FoodsProvider;
  userId: string;
  query: string;
  limit: number;
  locale?: string | null;
  providerSearchEnabled?: boolean;
  now?: Date;
}): Promise<{ query: string; limit: number; results: FoodSearchResult[] }> {
  const { repository, userId, query, limit } = args;
  const locale = normalizeLocale(args.locale);
  const providerSearchEnabled = args.providerSearchEnabled ??
    isFoodsProviderSearchEnabled();
  const now = args.now ?? new Date();

  const [favoritesRows, recentRows, customRows, catalogRows] = await Promise
    .all([
      repository.listFavoriteRefs(userId),
      repository.listRecentRefs(userId),
      repository.searchCustomFoods(userId, query, 60),
      repository.searchCatalogFoods(userId, query, 60),
    ]);

  const favorites = new Set(
    favoritesRows.map((row) => `${row.ref_type}:${row.ref_id}`),
  );
  const recent = new Set<string>();
  for (const row of recentRows) {
    if (row.user_food_id) recent.add(`custom:${row.user_food_id}`);
    if (row.catalog_item_id) recent.add(`catalog:${row.catalog_item_id}`);
  }

  const candidates: SearchCandidate[] = [
    ...customRows.map((row) =>
      toCustomSearchCandidate(row, favorites, recent, query)
    ),
    ...catalogRows.map((row) =>
      toCatalogSearchCandidate(row, favorites, recent, query, "cache")
    ),
  ];

  if (
    providerSearchEnabled &&
    args.provider &&
    query.trim().length >= 3 &&
    candidates.length < limit
  ) {
    try {
      const providerRows = await enrichProviderSearch({
        repository,
        provider: args.provider,
        query,
        limit: Math.min(Math.max(limit, 5), 12),
        locale,
        now,
      });
      for (const row of providerRows) {
        candidates.push(
          toCatalogSearchCandidate(row, favorites, recent, query, "provider"),
        );
      }
    } catch (error) {
      if (!(error instanceof FoodsError)) {
        throw error;
      }
      if (error.code !== "provider_unavailable") {
        throw error;
      }
    }
  }

  const results = candidates
    .sort((a, b) => a.score - b.score || a.name.localeCompare(b.name))
    .filter(distinctByResultKey())
    .slice(0, limit)
    .map(({ score: _score, ...result }) => result);

  return { query, limit, results };
}

export async function lookupFoodByBarcode(args: {
  repository: FoodsRepository;
  provider?: FoodsProvider;
  userId: string;
  barcode: string;
  locale?: string | null;
  providerBarcodeEnabled?: boolean;
  now?: Date;
}): Promise<BarcodeLookupOutcome> {
  const {
    repository,
    provider,
    userId,
    barcode,
  } = args;
  const locale = normalizeLocale(args.locale);
  const providerBarcodeEnabled = args.providerBarcodeEnabled ??
    isFoodsProviderBarcodeEnabled();
  const now = args.now ?? new Date();

  const customFood = await repository.findCustomFoodByBarcode(userId, barcode);
  if (customFood) {
    return {
      status: "found",
      item: toCustomBarcodeResponse(customFood),
    };
  }

  const cachedOff = await repository.findCatalogFoodByBarcode(
    OPEN_FOOD_FACTS_PROVIDER,
    barcode,
    userId,
  );
  if (cachedOff && isCacheFresh(cachedOff.expires_at, now)) {
    return {
      status: "found",
      item: toCatalogBarcodeResponse(cachedOff),
    };
  }

  let providerUnavailable = false;
  let insufficientNutrition = false;

  if (providerBarcodeEnabled && provider) {
    try {
      const fetched = await provider.lookupBarcode(barcode, locale, now);
      if (fetched) {
        const cached = await repository.upsertCatalogFood(fetched).catch(
          (error) => {
            if (error instanceof FoodsError) {
              throw new FoodsError(500, "barcode_lookup_failed", error.message);
            }
            throw error;
          },
        );
        if (cached) {
          return {
            status: "found",
            item: toCatalogBarcodeResponse(cached),
          };
        }
        // A user-owned catalog row blocks shared re-attribution; fall through
        // to the remaining lookup paths instead of exposing that row.
      }
    } catch (error) {
      if (error instanceof FoodsError) {
        if (error.code === "provider_unavailable") {
          providerUnavailable = true;
        } else if (error.code === "insufficient_nutrition_data") {
          insufficientNutrition = true;
        } else {
          throw error;
        }
      } else {
        throw error;
      }
    }
  }

  const ocrFallback = await repository.findCatalogFoodByBarcode(
    LABEL_OCR_PROVIDER,
    barcode,
    userId,
  );
  if (ocrFallback) {
    return {
      status: "found",
      item: toCatalogBarcodeResponse(ocrFallback),
    };
  }

  if (insufficientNutrition) {
    return { status: "insufficient_nutrition_data" };
  }

  if (providerUnavailable) {
    return { status: "provider_unavailable" };
  }

  return { status: "not_found" };
}

export function isFoodsProviderSearchEnabled(): boolean {
  return readBooleanEnv(
    "FOODS_PROVIDER_SEARCH_ENABLED",
    readBooleanEnv("FOODS_PROVIDER_ENABLED", true),
  );
}

export function isFoodsProviderBarcodeEnabled(): boolean {
  return readBooleanEnv(
    "FOODS_PROVIDER_BARCODE_ENABLED",
    readBooleanEnv("FOODS_PROVIDER_ENABLED", true),
  );
}

export function isBarcodeCode(value: string): boolean {
  if (value.length < 3 || value.length > 64) return false;
  return /^[0-9A-Za-z._-]+$/.test(value);
}

export function escapeIlike(value: string): string {
  return value.replaceAll("%", "\\%").replaceAll("_", "\\_");
}

function readBooleanEnv(key: string, fallback: boolean): boolean {
  const raw = Deno.env.get(key)?.trim().toLowerCase();
  if (!raw) return fallback;
  return !["0", "false", "off", "no", "disabled"].includes(raw);
}

function toCustomSearchCandidate(
  row: CustomFoodRow,
  favorites: Set<string>,
  recent: Set<string>,
  query: string,
): SearchCandidate {
  return {
    type: "custom",
    id: row.id,
    name: row.name,
    brand: row.brand,
    barcode: row.barcode,
    serving_size_g: row.default_serving_g,
    macros_per_100g: toMacros(row),
    tags: tagsFor(favorites, recent, "custom", row.id),
    score: scoreFor(
      favorites,
      recent,
      "custom",
      row.id,
      row.name,
      row.brand,
      row.barcode,
      query,
      "cache",
    ),
  };
}

function toCatalogSearchCandidate(
  row: CatalogFoodRow,
  favorites: Set<string>,
  recent: Set<string>,
  query: string,
  source: "cache" | "provider",
): SearchCandidate {
  return {
    type: "catalog",
    id: row.id,
    provider: row.provider,
    name: row.name,
    brand: row.brand,
    barcode: row.barcode,
    serving_size_g: row.serving_size_g,
    macros_per_100g: toMacros(row),
    tags: tagsFor(favorites, recent, "catalog", row.id),
    score: scoreFor(
      favorites,
      recent,
      "catalog",
      row.id,
      row.name,
      row.brand,
      row.barcode,
      query,
      source,
    ),
  };
}

function toCustomBarcodeResponse(
  row: CustomBarcodeFoodRow,
): BarcodeLookupResponse {
  return {
    type: "custom",
    id: row.id,
    name: row.name,
    brand: row.brand,
    barcode: row.barcode,
    serving_size_g: row.default_serving_g,
    macros_per_100g: toMacros(row),
    tags: ["user_override"],
  };
}

function toCatalogBarcodeResponse(row: CatalogFoodRow): BarcodeLookupResponse {
  return {
    type: "catalog",
    id: row.id,
    provider: row.provider,
    name: row.name,
    brand: row.brand,
    barcode: row.barcode,
    serving_size_g: row.serving_size_g,
    macros_per_100g: toMacros(row),
    fetched_at: row.fetched_at,
    expires_at: row.expires_at,
  };
}

function toMacros(
  row:
    | CatalogFoodRow
    | CustomFoodRow
    | CustomBarcodeFoodRow,
): MacrosPer100g {
  return {
    calories: Number(row.calories_per_100g ?? 0),
    protein_g: Number(row.protein_per_100g ?? 0),
    fat_g: Number(row.fat_per_100g ?? 0),
    carbs_g: Number(row.carbs_per_100g ?? 0),
    fiber_g: row.fiber_per_100g == null ? null : Number(row.fiber_per_100g),
  };
}

function tagsFor(
  favorites: Set<string>,
  recent: Set<string>,
  type: "catalog" | "custom",
  id: string,
): string[] {
  const tags: string[] = [];
  const key = `${type}:${id}`;
  if (favorites.has(key)) tags.push("favorite");
  if (recent.has(key)) tags.push("recent");
  return tags;
}

function scoreFor(
  favorites: Set<string>,
  recent: Set<string>,
  type: "catalog" | "custom",
  id: string,
  name: string,
  brand: string | null,
  barcode: string | null,
  query: string,
  source: "cache" | "provider",
): number {
  const key = `${type}:${id}`;
  const normalizedQuery = query.trim().toLowerCase();
  const normalizedName = name.toLowerCase();
  const normalizedBrand = (brand ?? "").toLowerCase();

  let group = 4;
  if (favorites.has(key)) {
    group = 0;
  } else if (recent.has(key)) {
    group = 1;
  } else if (type === "custom") {
    group = 2;
  } else if (source === "cache") {
    group = 3;
  }

  let score = group * 100;
  if (barcode && barcode === query) score -= 40;
  if (normalizedName === normalizedQuery) score -= 30;
  if (normalizedName.startsWith(normalizedQuery)) score -= 20;
  if (normalizedName.includes(normalizedQuery)) score -= 10;
  if (normalizedBrand.includes(normalizedQuery)) score -= 5;
  return score;
}

function distinctByResultKey(): (value: SearchCandidate) => boolean {
  const seen = new Set<string>();
  return (value) => {
    const key = `${value.type}:${value.id}`;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  };
}

function isCacheFresh(expiresAt: string | null, now: Date): boolean {
  if (!expiresAt) return false;
  const expiresTime = Date.parse(expiresAt);
  if (!Number.isFinite(expiresTime)) return false;
  return expiresTime >= now.getTime();
}

async function enrichProviderSearch(args: {
  repository: FoodsRepository;
  provider: FoodsProvider;
  query: string;
  limit: number;
  locale: string | null;
  now: Date;
}): Promise<CatalogFoodRow[]> {
  const providerItems = await args.provider.search(
    args.query,
    args.limit,
    args.locale,
    args.now,
  );

  const rows: CatalogFoodRow[] = [];
  for (const item of providerItems) {
    try {
      const cached = await args.repository.upsertCatalogFood(item);
      if (cached) {
        rows.push(cached);
      }
    } catch (error) {
      if (!(error instanceof FoodsError)) {
        throw error;
      }
    }
  }

  return rows;
}

class OpenFoodFactsProvider implements FoodsProvider {
  private readonly baseUrl: string;
  private readonly barcodeTimeoutMs: number;
  private readonly searchTimeoutMs: number;
  private readonly userAgent: string;

  constructor() {
    this.baseUrl = Deno.env.get("OPEN_FOOD_FACTS_BASE_URL")?.trim() ||
      OPEN_FOOD_FACTS_BASE_URL;
    this.barcodeTimeoutMs = readPositiveIntegerEnv(
      "OPEN_FOOD_FACTS_BARCODE_TIMEOUT_MS",
      DEFAULT_BARCODE_TIMEOUT_MS,
    );
    this.searchTimeoutMs = readPositiveIntegerEnv(
      "OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS",
      DEFAULT_SEARCH_TIMEOUT_MS,
    );
    this.userAgent = Deno.env.get("OPEN_FOOD_FACTS_USER_AGENT")?.trim() ||
      "LifeOS/1.0 (support@lifeos.app)";
  }

  async lookupBarcode(
    barcode: string,
    locale?: string | null,
    now = new Date(),
  ): Promise<CatalogFoodUpsertInput | null> {
    const data = await this.fetchJson(
      `/api/v2/product/${encodeURIComponent(barcode)}.json`,
      {
        fields: [
          "code",
          "product_name",
          "generic_name",
          "abbreviated_product_name",
          "brands",
          "serving_size",
          "nutrition_data_per",
          "nutriments",
          "image_front_small_url",
          "image_front_url",
          "image_url",
          "lang",
        ].join(","),
      },
      this.barcodeTimeoutMs,
      locale,
    );

    // deno-coverage-ignore-start -- malformed provider payload behavior is covered by provider miss tests.
    if (
      !isObject(data) || Number(data.status ?? 0) !== 1 ||
      !isObject(data.product)
    ) {
      return null;
    }
    // deno-coverage-ignore-stop

    // deno-coverage-ignore-start -- provider code fallback is covered by product normalization tests.
    const normalized = normalizeOpenFoodFactsProduct(
      data.product,
      readString(data, "code") ?? readString(data.product, "code"),
      now,
      locale,
    );
    // deno-coverage-ignore-stop
    if (!normalized.ok) {
      throw new FoodsError(422, "insufficient_nutrition_data");
    }

    return normalized.value;
  }

  async search(
    query: string,
    limit: number,
    locale?: string | null,
    now = new Date(),
  ): Promise<CatalogFoodUpsertInput[]> {
    const data = await this.fetchJson(
      "/cgi/search.pl",
      {
        action: "process",
        json: "1",
        page_size: String(limit),
        search_simple: "1",
        search_terms: query,
        fields: [
          "code",
          "product_name",
          "generic_name",
          "abbreviated_product_name",
          "brands",
          "serving_size",
          "nutrition_data_per",
          "nutriments",
          "image_front_small_url",
          "image_front_url",
          "image_url",
          "lang",
        ].join(","),
      },
      this.searchTimeoutMs,
      locale,
    );

    if (!isObject(data) || !Array.isArray(data.products)) {
      return [];
    }

    const normalized: CatalogFoodUpsertInput[] = [];
    for (const item of data.products) {
      if (!isObject(item)) continue;
      const result = normalizeOpenFoodFactsProduct(
        item,
        readString(item, "code"),
        now,
        locale,
      );
      if (!result.ok) continue;
      normalized.push(result.value);
    }

    return normalized;
  }

  private async fetchJson(
    pathname: string,
    params: Record<string, string>,
    timeoutMs: number,
    locale?: string | null,
  ): Promise<unknown> {
    const url = new URL(
      pathname.replace(/^\//, ""),
      ensureTrailingSlash(this.baseUrl),
    );
    for (const [key, value] of Object.entries(params)) {
      url.searchParams.set(key, value);
    }

    let response: Response;
    try {
      response = await fetch(url, {
        headers: buildProviderHeaders(this.userAgent, locale),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (error) {
      throw new FoodsError(503, "provider_unavailable", toErrorMessage(error));
    }

    if (!response.ok) {
      throw new FoodsError(
        503,
        "provider_unavailable",
        `Open Food Facts returned ${response.status}`,
      );
    }

    try {
      return await response.json();
    } catch (error) {
      throw new FoodsError(503, "provider_unavailable", toErrorMessage(error));
    }
  }
}

function normalizeOpenFoodFactsProduct(
  product: Record<string, unknown>,
  fallbackCode: string | null,
  now: Date,
  locale?: string | null,
): NormalizedProduct {
  const barcode = readString(product, "code") ?? fallbackCode;
  const language = localeLanguage(locale);
  const name = firstNonEmptyString(
    language ? readString(product, `product_name_${language}`) : null,
    readString(product, "product_name"),
    language ? readString(product, `generic_name_${language}`) : null,
    readString(product, "generic_name"),
    readString(product, "abbreviated_product_name"),
  );

  if (!barcode || !name) {
    return { ok: false, reason: "insufficient_nutrition_data" };
  }

  const servingSizeG = parseServingSizeGrams(
    readString(product, "serving_size"),
  );
  const nutriments = isObject(product.nutriments) ? product.nutriments : null;
  if (!nutriments) {
    return { ok: false, reason: "insufficient_nutrition_data" };
  }

  const normalizedMacros = normalizeNutriments(
    nutriments,
    servingSizeG,
    readString(product, "nutrition_data_per"),
  );
  if (!normalizedMacros) {
    return { ok: false, reason: "insufficient_nutrition_data" };
  }

  const confidence = normalizedMacros.correctedCalories
    ? 0.65
    : normalizedMacros.usedServingFallback
    ? 0.78
    : 0.85;

  return {
    ok: true,
    value: {
      provider: OPEN_FOOD_FACTS_PROVIDER,
      provider_item_id: barcode,
      barcode,
      name,
      brand: normalizeBrand(readString(product, "brands")),
      locale: normalizeLocale(readString(product, "lang") ?? locale),
      image_url: firstNonEmptyString(
        readString(product, "image_front_small_url"),
        readString(product, "image_front_url"),
        readString(product, "image_url"),
      ),
      serving_size_g: servingSizeG,
      macros_per_100g: normalizedMacros.macros,
      sugar_per_100g: normalizedMacros.sugarPer100g,
      sodium_mg_per_100g: normalizedMacros.sodiumMgPer100g,
      source_confidence: confidence,
      fetched_at: now.toISOString(),
      expires_at: new Date(now.getTime() + OPEN_FOOD_FACTS_TTL_MS)
        .toISOString(),
    },
  };
}

function normalizeNutriments(
  nutriments: Record<string, unknown>,
  servingSizeG: number | null,
  nutritionDataPer: string | null,
): MacroNormalization | null {
  const baseProtein = readNumber(nutriments, "proteins_100g");
  const baseFat = readNumber(nutriments, "fat_100g");
  const baseCarbs = readNumber(nutriments, "carbohydrates_100g");
  const baseFiber = readNumber(nutriments, "fiber_100g");
  const baseSugar = readNumber(nutriments, "sugars_100g");
  const baseSodium = readSodiumMgPer100g(
    nutriments,
    "sodium_100g",
    "salt_100g",
  );
  const baseCalories = readCaloriesKcal(
    nutriments,
    "energy-kcal_100g",
    "energy-kj_100g",
    "energy_100g",
  );

  let protein = baseProtein;
  let fat = baseFat;
  let carbs = baseCarbs;
  let fiber = baseFiber;
  let sugar = baseSugar;
  let sodiumMg = baseSodium;
  let calories = baseCalories;
  let usedServingFallback = false;

  if (
    protein == null || fat == null || carbs == null ||
    calories == null
  ) {
    const unsuffixedLooksLike100g =
      (nutritionDataPer ?? "").toLowerCase() === "100g";
    if (unsuffixedLooksLike100g) {
      protein ??= readNumber(nutriments, "proteins");
      fat ??= readNumber(nutriments, "fat");
      carbs ??= readNumber(nutriments, "carbohydrates");
      fiber ??= readNumber(nutriments, "fiber");
      sugar ??= readNumber(nutriments, "sugars");
      sodiumMg ??= readSodiumMgPer100g(nutriments, "sodium", "salt");
      calories ??= readCaloriesKcal(
        nutriments,
        "energy-kcal",
        "energy-kj",
        "energy",
      );
    }
  }

  if (
    (protein == null || fat == null || carbs == null || calories == null) &&
    servingSizeG != null &&
    servingSizeG > 0
  ) {
    const multiplier = 100 / servingSizeG;
    protein ??= scaleNumber(
      readNumber(nutriments, "proteins_serving"),
      multiplier,
    );
    fat ??= scaleNumber(readNumber(nutriments, "fat_serving"), multiplier);
    carbs ??= scaleNumber(
      readNumber(nutriments, "carbohydrates_serving"),
      multiplier,
    );
    fiber ??= scaleOptionalNumber(
      readNumber(nutriments, "fiber_serving"),
      multiplier,
    );
    sugar ??= scaleOptionalNumber(
      readNumber(nutriments, "sugars_serving"),
      multiplier,
    );
    sodiumMg ??= scaleOptionalNumber(
      readSodiumMgPer100g(nutriments, "sodium_serving", "salt_serving"),
      multiplier,
    );
    calories ??= scaleOptionalNumber(
      readCaloriesKcal(
        nutriments,
        "energy-kcal_serving",
        "energy-kj_serving",
        "energy_serving",
      ),
      multiplier,
    );
    usedServingFallback = true;
  }

  if (protein == null || fat == null || carbs == null) {
    return null;
  }
  if (
    protein < 0 || fat < 0 || carbs < 0 ||
    (fiber != null && fiber < 0)
  ) {
    return null;
  }

  const computedCalories = round1(protein * 4 + carbs * 4 + fat * 9);
  if (computedCalories < 0 || computedCalories > 900) {
    return null;
  }

  let correctedCalories = false;
  if (
    calories == null || calories < 0 || calories > 900 ||
    calorieMismatch(calories, computedCalories)
  ) {
    calories = computedCalories;
    correctedCalories = true;
  } else {
    calories = round1(calories);
  }

  return {
    macros: {
      calories,
      protein_g: round1(protein),
      fat_g: round1(fat),
      carbs_g: round1(carbs),
      fiber_g: fiber == null ? null : round1(fiber),
    },
    sugarPer100g: sugar == null ? null : round1(sugar),
    sodiumMgPer100g: sodiumMg == null ? null : round1(sodiumMg),
    usedServingFallback,
    correctedCalories,
  };
}

function readCaloriesKcal(
  nutriments: Record<string, unknown>,
  kcalKey: string,
  kjKey: string,
  genericEnergyKey: string,
): number | null {
  const kcal = readNumber(nutriments, kcalKey);
  if (kcal != null) return kcal;

  const energyKj = readNumber(nutriments, kjKey) ??
    readNumber(nutriments, genericEnergyKey);
  if (energyKj == null) return null;
  return round1(energyKj / 4.184);
}

function readSodiumMgPer100g(
  nutriments: Record<string, unknown>,
  sodiumKey: string,
  saltKey: string,
): number | null {
  const sodiumG = readNumber(nutriments, sodiumKey);
  if (sodiumG != null) return round1(sodiumG * 1000);

  const saltG = readNumber(nutriments, saltKey);
  if (saltG != null) return round1(saltG * 1000 * 0.393);

  return null;
}

function calorieMismatch(
  providerCalories: number,
  computedCalories: number,
): boolean {
  const baseline = Math.max(1, computedCalories);
  return Math.abs(providerCalories - computedCalories) / baseline > 0.2;
}

function scaleNumber(value: number | null, multiplier: number): number | null {
  if (value == null) return null;
  return round1(value * multiplier);
}

function scaleOptionalNumber(
  value: number | null,
  multiplier: number,
): number | null {
  if (value == null) return null;
  return round1(value * multiplier);
}

function readPositiveIntegerEnv(key: string, fallback: number): number {
  const raw = Deno.env.get(key)?.trim() ?? "";
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function ensureTrailingSlash(url: string): string {
  return url.endsWith("/") ? url : `${url}/`;
}

function buildProviderHeaders(
  userAgent: string,
  locale?: string | null,
): HeadersInit {
  const headers: HeadersInit = {
    Accept: "application/json",
    "User-Agent": userAgent,
  };
  const normalized = normalizeLocale(locale);
  if (normalized) {
    headers["Accept-Language"] = normalized.replaceAll("_", "-");
  }
  return headers;
}

function normalizeLocale(value: string | null | undefined): string | null {
  if (!value) return null;
  // deno-coverage-ignore -- optional split fallback is defensive; locale behavior is covered.
  const candidate = value.split(",")[0]?.trim() ?? "";
  if (!candidate) return null;
  return candidate.replaceAll("-", "_");
}

function localeLanguage(value: string | null | undefined): string | null {
  const locale = normalizeLocale(value);
  if (!locale) return null;
  // deno-coverage-ignore -- optional split fallback is defensive; language behavior is covered.
  const language = locale.split("_")[0]?.trim().toLowerCase() ?? "";
  return language.length > 0 ? language : null;
}

function normalizeBrand(value: string | null): string | null {
  if (!value) return null;
  // deno-coverage-ignore -- optional split fallback is defensive; brand behavior is covered.
  const candidate = value.split(",")[0]?.trim() ?? "";
  return candidate.length > 0 ? candidate : null;
}

function parseServingSizeGrams(value: string | null): number | null {
  if (!value) return null;
  const normalized = value.replaceAll(",", ".");
  const match = normalized.match(
    /([0-9]+(?:\.[0-9]+)?)\s*(g|gram|grams|гр|г)\b/i,
  );
  if (!match) return null;
  const parsed = Number.parseFloat(match[1]);
  if (!Number.isFinite(parsed) || parsed <= 0) return null;
  return round1(parsed);
}

function readString(
  value: Record<string, unknown>,
  key: string,
): string | null {
  const raw = value[key];
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function readNumber(
  value: Record<string, unknown>,
  key: string,
): number | null {
  const raw = value[key];
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  const parsed = Number.parseFloat(trimmed.replaceAll(",", "."));
  return Number.isFinite(parsed) ? parsed : null;
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function firstNonEmptyString(
  ...values: Array<string | null | undefined>
): string | null {
  for (const value of values) {
    if (value && value.trim().length > 0) return value.trim();
  }
  return null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message;
  }
  return "unknown provider error";
}

export const __foodsProviderTestHooks = {
  buildProviderHeaders,
  calorieMismatch,
  distinctByResultKey,
  ensureTrailingSlash,
  firstNonEmptyString,
  isCacheFresh,
  isObject,
  localeLanguage,
  normalizeBrand,
  normalizeLocale,
  normalizeNutriments,
  normalizeOpenFoodFactsProduct,
  parseServingSizeGrams,
  readCaloriesKcal,
  readNumber,
  readPositiveIntegerEnv,
  readSodiumMgPer100g,
  readString,
  round1,
  scaleNumber,
  scaleOptionalNumber,
  scoreFor,
  tagsFor,
  toCatalogBarcodeResponse,
  toCatalogSearchCandidate,
  toCustomBarcodeResponse,
  toCustomSearchCandidate,
  toErrorMessage,
  toMacros,
};
