import {
  assert,
  assertEquals,
  assertExists,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  __foodsProviderTestHooks,
  type CatalogFoodRow,
  type CatalogFoodUpsertInput,
  createSupabaseFoodsRepository,
  type CustomBarcodeFoodRow,
  type CustomFoodRow,
  defaultFoodsProvider,
  escapeIlike,
  type FavoriteRow,
  FoodsError,
  type FoodsProvider,
  type FoodsRepository,
  isBarcodeCode,
  isFoodsProviderBarcodeEnabled,
  isFoodsProviderSearchEnabled,
  lookupFoodByBarcode,
  type RecentItemRow,
  searchFoods,
} from "../_shared/foods_provider.ts";
import {
  createMockSupabaseService,
  type MockQueryState,
} from "./_mock_supabase_service.ts";

class FakeFoodsRepository implements FoodsRepository {
  favorites: FavoriteRow[] = [];
  recents: RecentItemRow[] = [];
  customSearchRows: CustomFoodRow[] = [];
  catalogSearchRows: CatalogFoodRow[] = [];
  customBarcodeRows = new Map<string, CustomBarcodeFoodRow>();
  catalogBarcodeRows = new Map<string, CatalogFoodRow>();
  upsertCalls: CatalogFoodUpsertInput[] = [];

  listFavoriteRefs(_userId: string): Promise<FavoriteRow[]> {
    return Promise.resolve(this.favorites);
  }

  listRecentRefs(_userId: string): Promise<RecentItemRow[]> {
    return Promise.resolve(this.recents);
  }

  searchCustomFoods(
    _userId: string,
    _query: string,
    _limit: number,
  ): Promise<CustomFoodRow[]> {
    return Promise.resolve(this.customSearchRows);
  }

  searchCatalogFoods(
    _query: string,
    _limit: number,
  ): Promise<CatalogFoodRow[]> {
    return Promise.resolve(this.catalogSearchRows);
  }

  findCustomFoodByBarcode(
    _userId: string,
    barcode: string,
  ): Promise<CustomBarcodeFoodRow | null> {
    return Promise.resolve(this.customBarcodeRows.get(barcode) ?? null);
  }

  findCatalogFoodByBarcode(
    provider: string,
    barcode: string,
  ): Promise<CatalogFoodRow | null> {
    return Promise.resolve(
      this.catalogBarcodeRows.get(`${provider}:${barcode}`) ?? null,
    );
  }

  upsertCatalogFood(
    payload: CatalogFoodUpsertInput,
  ): Promise<CatalogFoodRow> {
    this.upsertCalls.push(payload);
    const row: CatalogFoodRow = {
      id: `catalog-${payload.provider}-${payload.barcode}`,
      provider: payload.provider,
      name: payload.name,
      brand: payload.brand,
      barcode: payload.barcode,
      serving_size_g: payload.serving_size_g,
      calories_per_100g: payload.macros_per_100g.calories,
      protein_per_100g: payload.macros_per_100g.protein_g,
      fat_per_100g: payload.macros_per_100g.fat_g,
      carbs_per_100g: payload.macros_per_100g.carbs_g,
      fiber_per_100g: payload.macros_per_100g.fiber_g,
      fetched_at: payload.fetched_at,
      expires_at: payload.expires_at,
    };
    this.catalogBarcodeRows.set(`${payload.provider}:${payload.barcode}`, row);
    return Promise.resolve(row);
  }
}

class FakeFoodsProvider implements FoodsProvider {
  barcodeResult: CatalogFoodUpsertInput | null = null;
  barcodeError: Error | null = null;
  searchResults: CatalogFoodUpsertInput[] = [];
  searchError: Error | null = null;
  lookupCalls = 0;
  searchCalls = 0;

  lookupBarcode(): Promise<CatalogFoodUpsertInput | null> {
    this.lookupCalls += 1;
    if (this.barcodeError) return Promise.reject(this.barcodeError);
    return Promise.resolve(this.barcodeResult);
  }

  search(): Promise<CatalogFoodUpsertInput[]> {
    this.searchCalls += 1;
    if (this.searchError) return Promise.reject(this.searchError);
    return Promise.resolve(this.searchResults);
  }
}

function customFood(
  id: string,
  name: string,
  barcode: string | null = null,
): CustomFoodRow {
  return {
    id,
    name,
    brand: null,
    barcode,
    default_serving_g: 100,
    calories_per_100g: 120,
    protein_per_100g: 20,
    fat_per_100g: 4,
    carbs_per_100g: 8,
    fiber_per_100g: 2,
    created_at: "2026-03-06T00:00:00Z",
  };
}

function catalogFood(
  id: string,
  provider: string,
  name: string,
  barcode: string | null = null,
): CatalogFoodRow {
  return {
    id,
    provider,
    name,
    brand: null,
    barcode,
    serving_size_g: 50,
    calories_per_100g: 110,
    protein_per_100g: 18,
    fat_per_100g: 3,
    carbs_per_100g: 9,
    fiber_per_100g: 1,
    fetched_at: "2026-03-06T00:00:00Z",
    expires_at: "2026-04-05T00:00:00Z",
  };
}

function providerFood(
  barcode: string,
  name: string,
  fetchedAt = "2026-03-06T00:00:00Z",
): CatalogFoodUpsertInput {
  return {
    provider: "open_food_facts",
    provider_item_id: barcode,
    barcode,
    name,
    brand: "Provider Brand",
    locale: "ru_RU",
    image_url: null,
    serving_size_g: 45,
    macros_per_100g: {
      calories: 133.3,
      protein_g: 4.4,
      fat_g: 5.5,
      carbs_g: 16.6,
      fiber_g: 1.2,
    },
    sugar_per_100g: 9.1,
    sodium_mg_per_100g: 42.8,
    source_confidence: 0.85,
    fetched_at: fetchedAt,
    expires_at: "2026-04-05T00:00:00Z",
  };
}

async function withMockFetch(
  mock: (
    input: Request | URL | string,
    init?: RequestInit,
  ) => Promise<Response>,
  fn: () => Promise<void>,
): Promise<void> {
  const previousFetch = globalThis.fetch;
  globalThis.fetch = mock as typeof fetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = previousFetch;
  }
}

function withEnv(
  key: string,
  value: string | undefined,
  fn: () => void,
): void {
  const previous = Deno.env.get(key);
  if (value === undefined) {
    Deno.env.delete(key);
  } else {
    Deno.env.set(key, value);
  }

  try {
    fn();
  } finally {
    if (previous === undefined) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, previous);
    }
  }
}

function filterValue(
  state: MockQueryState,
  op: string,
  column: string,
): unknown {
  return state.filters.find((filter) =>
    filter.op === op && filter.column === column
  )?.value;
}

Deno.test("Open Food Facts barcode lookup normalizes macros and fixes implausible calories", async () => {
  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          status: 1,
          code: "3017620422003",
          product: {
            code: "3017620422003",
            product_name: "Nutella",
            brands: "Ferrero,Nutella",
            serving_size: "15 g",
            nutriments: {
              "energy-kj_100g": 2252,
              "energy-kcal_100g": 3860,
              "proteins_100g": 6.3,
              "fat_100g": 30.9,
              "carbohydrates_100g": 57.5,
              "fiber_100g": 0,
              "salt_100g": 0.107,
            },
          },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const now = new Date("2026-03-06T00:00:00Z");
    const result = await provider.lookupBarcode(
      "3017620422003",
      "ru_RU",
      now,
    );

    assertExists(result);
    assertEquals(result.name, "Nutella");
    assertEquals(result.brand, "Ferrero");
    assertEquals(result.serving_size_g, 15);
    assertEquals(result.macros_per_100g.calories, 533.3);
    assertEquals(result.sodium_mg_per_100g, 42.1);
    assertEquals(result.expires_at, "2026-04-05T00:00:00.000Z");
  });
});

Deno.test("barcode lookup fetches provider product on cache miss and stores it", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  provider.barcodeResult = providerFood("4601234567890", "Kefir 2.5%");

  const outcome = await lookupFoodByBarcode({
    repository,
    provider,
    userId: "user-1",
    barcode: "4601234567890",
    locale: "ru_RU",
    providerBarcodeEnabled: true,
  });

  assertEquals(outcome.status, "found");
  if (outcome.status === "found") {
    assertEquals(outcome.item.type, "catalog");
    assertEquals(outcome.item.provider, "open_food_facts");
    assertEquals(outcome.item.name, "Kefir 2.5%");
  }
  assertEquals(provider.lookupCalls, 1);
  assertEquals(repository.upsertCalls.length, 1);
  assertEquals(repository.upsertCalls[0].barcode, "4601234567890");
});

Deno.test("barcode lookup falls back to OCR catalog after provider miss", async () => {
  const repository = new FakeFoodsRepository();
  repository.catalogBarcodeRows.set(
    "lifeos_label_ocr:4607654321098",
    catalogFood(
      "ocr-1",
      "lifeos_label_ocr",
      "Ryazhenka",
      "4607654321098",
    ),
  );

  const provider = new FakeFoodsProvider();
  provider.barcodeResult = null;

  const outcome = await lookupFoodByBarcode({
    repository,
    provider,
    userId: "user-1",
    barcode: "4607654321098",
    providerBarcodeEnabled: true,
  });

  assertEquals(outcome.status, "found");
  if (outcome.status === "found") {
    assertEquals(outcome.item.provider, "lifeos_label_ocr");
    assertEquals(outcome.item.name, "Ryazhenka");
  }
  assertEquals(provider.lookupCalls, 1);
  assertEquals(repository.upsertCalls.length, 0);
});

Deno.test("barcode lookup returns provider_unavailable when provider fails and no fallback exists", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  provider.barcodeError = new FoodsError(
    503,
    "provider_unavailable",
    "timeout",
  );

  const outcome = await lookupFoodByBarcode({
    repository,
    provider,
    userId: "user-1",
    barcode: "4601111111111",
    providerBarcodeEnabled: true,
  });

  assertEquals(outcome, { status: "provider_unavailable" });
});

Deno.test("search merges local and provider results with provider items ranked last", async () => {
  const repository = new FakeFoodsRepository();
  repository.favorites = [{ ref_type: "custom", ref_id: "custom-favorite" }];
  repository.recents = [{
    catalog_item_id: "catalog-recent",
    user_food_id: null,
  }];
  repository.customSearchRows = [
    customFood("custom-favorite", "Kefir Favorite"),
    customFood("custom-plain", "Kefir Custom"),
  ];
  repository.catalogSearchRows = [
    catalogFood("catalog-recent", "open_food_facts", "Kefir Recent"),
    catalogFood("catalog-cache", "open_food_facts", "Kefir Cached"),
  ];

  const provider = new FakeFoodsProvider();
  provider.searchResults = [providerFood("4609999999999", "Kefir Provider")];

  const response = await searchFoods({
    repository,
    provider,
    userId: "user-1",
    query: "kefir",
    limit: 5,
    providerSearchEnabled: true,
  });

  assertEquals(
    response.results.map((row) => row.name),
    [
      "Kefir Favorite",
      "Kefir Recent",
      "Kefir Custom",
      "Kefir Cached",
      "Kefir Provider",
    ],
  );
  assertEquals(response.results[0].tags, ["favorite"]);
  assertEquals(response.results[1].tags, ["recent"]);
  assertEquals(provider.searchCalls, 1);
  assertEquals(repository.upsertCalls.length, 1);
});

Deno.test("search skips provider query when local results already satisfy limit", async () => {
  const repository = new FakeFoodsRepository();
  repository.customSearchRows = [
    customFood("custom-1", "Oatmeal"),
    customFood("custom-2", "Oat Bran"),
    customFood("custom-3", "Oat Pancake"),
  ];
  repository.catalogSearchRows = [
    catalogFood("catalog-1", "open_food_facts", "Oat Milk"),
    catalogFood("catalog-2", "open_food_facts", "Oat Cookie"),
  ];

  const provider = new FakeFoodsProvider();
  provider.searchResults = [providerFood("4602222222222", "Oat Provider")];

  const response = await searchFoods({
    repository,
    provider,
    userId: "user-1",
    query: "oat",
    limit: 5,
    providerSearchEnabled: true,
  });

  assertEquals(response.results.length, 5);
  assertEquals(provider.searchCalls, 0);
  assertEquals(repository.upsertCalls.length, 0);
});

Deno.test("createSupabaseFoodsRepository maps query results and payloads", async () => {
  const favoriteRows: FavoriteRow[] = [{
    ref_type: "catalog",
    ref_id: "cat-1",
  }];
  const recentRows: RecentItemRow[] = [{
    user_food_id: "custom-1",
    catalog_item_id: "catalog-1",
  }];
  const customRows = [customFood("custom-1", "Kefir Custom", "4600000000001")];
  const catalogRows = [
    catalogFood(
      "catalog-1",
      "open_food_facts",
      "Kefir Cached",
      "4600000000002",
    ),
  ];
  const customBarcodeRow: CustomBarcodeFoodRow = {
    id: "custom-barcode-1",
    name: "User Kefir",
    brand: "Home",
    barcode: "4601234500001",
    default_serving_g: 250,
    calories_per_100g: 54,
    protein_per_100g: 3,
    fat_per_100g: 2.5,
    carbs_per_100g: 4,
    fiber_per_100g: null,
  };
  const catalogBarcodeRow = catalogFood(
    "catalog-barcode-1",
    "open_food_facts",
    "Catalog Kefir",
    "4601234500002",
  );
  const upsertedRow = catalogFood(
    "catalog-upsert-1",
    "open_food_facts",
    "Provider Kefir",
    "4601234500003",
  );

  const service = createMockSupabaseService((state) => {
    if (state.table === "user_food_favorites" && state.terminal === "returns") {
      return { data: favoriteRows, error: null };
    }

    if (state.table === "food_items" && state.terminal === "returns") {
      return { data: recentRows, error: null };
    }

    if (
      state.table === "user_foods" &&
      state.terminal === "returns" &&
      state.selected?.includes("created_at")
    ) {
      return { data: customRows, error: null };
    }

    if (
      state.table === "food_catalog_items" &&
      state.terminal === "returns" &&
      state.action === "select"
    ) {
      return { data: catalogRows, error: null };
    }

    if (state.table === "user_foods" && state.terminal === "maybeSingle") {
      return { data: customBarcodeRow, error: null };
    }

    if (
      state.table === "food_catalog_items" &&
      state.terminal === "maybeSingle"
    ) {
      return { data: catalogBarcodeRow, error: null };
    }

    if (
      state.table === "food_catalog_items" &&
      state.action === "upsert" &&
      state.terminal === "single"
    ) {
      return { data: upsertedRow, error: null };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const repository = createSupabaseFoodsRepository(service as never);
  const escapedQuery = "kef%_ir";
  const upsertPayload = providerFood("4601234500003", "Provider Kefir");

  assertEquals(await repository.listFavoriteRefs("user-1"), favoriteRows);
  assertEquals(await repository.listRecentRefs("user-1"), recentRows);
  assertEquals(
    await repository.searchCustomFoods("user-1", escapedQuery, 12),
    customRows,
  );
  assertEquals(
    await repository.searchCatalogFoods(escapedQuery, 8),
    catalogRows,
  );
  assertEquals(
    await repository.findCustomFoodByBarcode("user-1", "4601234500001"),
    customBarcodeRow,
  );
  assertEquals(
    await repository.findCatalogFoodByBarcode(
      "open_food_facts",
      "4601234500002",
    ),
    catalogBarcodeRow,
  );
  assertEquals(await repository.upsertCatalogFood(upsertPayload), upsertedRow);

  const favoritesCall = service.__calls.find((state) =>
    state.table === "user_food_favorites"
  );
  assertExists(favoritesCall);
  assertEquals(filterValue(favoritesCall, "eq", "user_id"), "user-1");

  const recentCall = service.__calls.find((state) =>
    state.table === "food_items"
  );
  assertExists(recentCall);
  assertEquals(filterValue(recentCall, "eq", "user_id"), "user-1");
  assertEquals(recentCall.limit, 80);
  assertEquals(recentCall.orderBy, [{
    column: "created_at",
    options: { ascending: false },
  }]);

  const customSearchCall = service.__calls.find((state) =>
    state.table === "user_foods" &&
    state.terminal === "returns" &&
    state.selected?.includes("created_at")
  );
  assertExists(customSearchCall);
  assertEquals(filterValue(customSearchCall, "eq", "user_id"), "user-1");
  assertEquals(
    filterValue(customSearchCall, "ilike", "name"),
    `%${escapeIlike(escapedQuery)}%`,
  );
  assertEquals(customSearchCall.limit, 12);

  const catalogSearchCall = service.__calls.find((state) =>
    state.table === "food_catalog_items" &&
    state.terminal === "returns" &&
    state.action === "select"
  );
  assertExists(catalogSearchCall);
  assertEquals(
    filterValue(catalogSearchCall, "ilike", "name"),
    `%${escapeIlike(escapedQuery)}%`,
  );
  assertEquals(catalogSearchCall.limit, 8);
  assertEquals(catalogSearchCall.orderBy, [{
    column: "fetched_at",
    options: { ascending: false },
  }]);

  const customBarcodeCall = service.__calls.find((state) =>
    state.table === "user_foods" && state.terminal === "maybeSingle"
  );
  assertExists(customBarcodeCall);
  assertEquals(
    filterValue(customBarcodeCall, "eq", "barcode"),
    "4601234500001",
  );

  const catalogBarcodeCall = service.__calls.find((state) =>
    state.table === "food_catalog_items" && state.terminal === "maybeSingle"
  );
  assertExists(catalogBarcodeCall);
  assertEquals(
    filterValue(catalogBarcodeCall, "eq", "provider"),
    "open_food_facts",
  );
  assertEquals(
    filterValue(catalogBarcodeCall, "eq", "barcode"),
    "4601234500002",
  );
  assertEquals(catalogBarcodeCall.limit, 1);

  const upsertCall = service.__calls.find((state) =>
    state.table === "food_catalog_items" &&
    state.action === "upsert" &&
    state.terminal === "single"
  );
  assertExists(upsertCall);
  assertEquals(upsertCall.selected?.includes("provider,name,brand"), true);
  assertEquals(
    (upsertCall.payload as Record<string, unknown>).created_by_user_id,
    null,
  );
  assertEquals(
    (upsertCall.payload as Record<string, unknown>).barcode,
    "4601234500003",
  );
});

Deno.test("createSupabaseFoodsRepository wraps Supabase failures in FoodsError codes", async () => {
  const cases = [
    {
      expectedCode: "favorites_fetch_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.listFavoriteRefs("user-1"),
      matches: (state: MockQueryState) =>
        state.table === "user_food_favorites" && state.terminal === "returns",
    },
    {
      expectedCode: "recent_foods_fetch_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.listRecentRefs("user-1"),
      matches: (state: MockQueryState) =>
        state.table === "food_items" && state.terminal === "returns",
    },
    {
      expectedCode: "custom_foods_fetch_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.searchCustomFoods("user-1", "kefir", 5),
      matches: (state: MockQueryState) =>
        state.table === "user_foods" &&
        state.terminal === "returns" &&
        state.selected?.includes("created_at") === true,
    },
    {
      expectedCode: "catalog_foods_fetch_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.searchCatalogFoods("kefir", 5),
      matches: (state: MockQueryState) =>
        state.table === "food_catalog_items" &&
        state.terminal === "returns" &&
        state.action === "select",
    },
    {
      expectedCode: "barcode_lookup_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.findCustomFoodByBarcode("user-1", "4601234500001"),
      matches: (state: MockQueryState) =>
        state.table === "user_foods" && state.terminal === "maybeSingle",
    },
    {
      expectedCode: "barcode_lookup_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.findCatalogFoodByBarcode("open_food_facts", "4601234500002"),
      matches: (state: MockQueryState) =>
        state.table === "food_catalog_items" &&
        state.terminal === "maybeSingle",
    },
    {
      expectedCode: "catalog_cache_failed",
      invoke: (repository: ReturnType<typeof createSupabaseFoodsRepository>) =>
        repository.upsertCatalogFood(
          providerFood("4601234500003", "Provider Kefir"),
        ),
      matches: (state: MockQueryState) =>
        state.table === "food_catalog_items" &&
        state.action === "upsert" &&
        state.terminal === "single",
    },
  ] as const;

  for (const testCase of cases) {
    const service = createMockSupabaseService((state) => {
      if (testCase.matches(state)) {
        return { data: null, error: { message: "boom" } };
      }
      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });
    const repository = createSupabaseFoodsRepository(service as never);

    const error = await assertRejects(
      () => testCase.invoke(repository),
      FoodsError,
    ) as FoodsError;

    assertEquals(error.code, testCase.expectedCode);
    assertEquals(error.status, 500);
    assertEquals(error.message, "boom");
  }
});

Deno.test("barcode lookup reports insufficient_nutrition_data when provider lacks usable macros", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  provider.barcodeError = new FoodsError(
    422,
    "insufficient_nutrition_data",
    "missing macros",
  );

  const outcome = await lookupFoodByBarcode({
    repository,
    provider,
    userId: "user-1",
    barcode: "4604444444444",
    providerBarcodeEnabled: true,
  });

  assertEquals(outcome, { status: "insufficient_nutrition_data" });
});

Deno.test("search ignores provider_unavailable and preserves local results", async () => {
  const repository = new FakeFoodsRepository();
  repository.customSearchRows = [customFood("custom-1", "Greek Yogurt")];
  const provider = new FakeFoodsProvider();
  provider.searchError = new FoodsError(503, "provider_unavailable", "timeout");

  const response = await searchFoods({
    repository,
    provider,
    userId: "user-1",
    query: "yogurt",
    limit: 5,
    providerSearchEnabled: true,
  });

  assertEquals(response.results.map((row) => row.name), ["Greek Yogurt"]);
  assertEquals(provider.searchCalls, 1);
});

Deno.test("barcode lookup prefers a user's custom barcode override", async () => {
  const repository = new FakeFoodsRepository();
  repository.customBarcodeRows.set("4607000000001", {
    id: "custom-barcode-1",
    name: "Homemade Kefir",
    brand: "Home",
    barcode: "4607000000001",
    default_serving_g: 250,
    calories_per_100g: 54,
    protein_per_100g: 3,
    fat_per_100g: 2.5,
    carbs_per_100g: 4,
    fiber_per_100g: null,
  });

  const provider = new FakeFoodsProvider();
  provider.barcodeResult = providerFood("4607000000001", "Provider Kefir");

  const outcome = await lookupFoodByBarcode({
    repository,
    provider,
    userId: "user-1",
    barcode: "4607000000001",
  });

  assertEquals(outcome.status, "found");
  if (outcome.status === "found") {
    assertEquals(outcome.item.type, "custom");
    assertEquals(outcome.item.name, "Homemade Kefir");
    assertEquals(outcome.item.tags, ["user_override"]);
    assertEquals(outcome.item.macros_per_100g.protein_g, 3);
  }
  assertEquals(provider.lookupCalls, 0);
  assertEquals(repository.upsertCalls.length, 0);
});

Deno.test("barcode lookup returns a fresh cached provider item without refetching", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  repository.catalogBarcodeRows.set(
    "open_food_facts:4607000000002",
    {
      ...catalogFood(
        "cached-off-1",
        "open_food_facts",
        "Cached Ayran",
        "4607000000002",
      ),
      expires_at: "2026-04-15T00:00:00Z",
    },
  );

  const outcome = await lookupFoodByBarcode({
    repository,
    provider,
    userId: "user-1",
    barcode: "4607000000002",
    now: new Date("2026-04-10T00:00:00Z"),
  });

  assertEquals(outcome.status, "found");
  if (outcome.status === "found") {
    assertEquals(outcome.item.provider, "open_food_facts");
    assertEquals(outcome.item.name, "Cached Ayran");
  }
  assertEquals(provider.lookupCalls, 0);
  assertEquals(repository.upsertCalls.length, 0);
});

Deno.test("barcode lookup remaps provider cache-write failures after an expired cache entry", async () => {
  class FailingRepository extends FakeFoodsRepository {
    override upsertCatalogFood(): Promise<CatalogFoodRow> {
      return Promise.reject(
        new FoodsError(500, "catalog_cache_failed", "cache write failed"),
      );
    }
  }

  const repository = new FailingRepository();
  repository.catalogBarcodeRows.set(
    "open_food_facts:4607000000003",
    {
      ...catalogFood(
        "expired-off-1",
        "open_food_facts",
        "Expired Yogurt",
        "4607000000003",
      ),
      expires_at: "2026-04-01T00:00:00Z",
    },
  );

  const provider = new FakeFoodsProvider();
  provider.barcodeResult = providerFood("4607000000003", "Fresh Yogurt");

  const error = await assertRejects(
    () =>
      lookupFoodByBarcode({
        repository,
        provider,
        userId: "user-1",
        barcode: "4607000000003",
        now: new Date("2026-04-10T00:00:00Z"),
      }),
    FoodsError,
  ) as FoodsError;

  assertEquals(error.code, "barcode_lookup_failed");
  assertEquals(error.message, "cache write failed");
  assertEquals(provider.lookupCalls, 1);
});

Deno.test("foods provider feature flags honor global and per-feature environment overrides", () => {
  withEnv("FOODS_PROVIDER_ENABLED", "off", () => {
    assertEquals(isFoodsProviderSearchEnabled(), false);
    assertEquals(isFoodsProviderBarcodeEnabled(), false);
  });

  withEnv("FOODS_PROVIDER_ENABLED", "off", () => {
    withEnv("FOODS_PROVIDER_SEARCH_ENABLED", "true", () => {
      assertEquals(isFoodsProviderSearchEnabled(), true);
    });
  });

  withEnv("FOODS_PROVIDER_ENABLED", "true", () => {
    withEnv("FOODS_PROVIDER_BARCODE_ENABLED", "disabled", () => {
      assertEquals(isFoodsProviderBarcodeEnabled(), false);
    });
  });
});

Deno.test("search does not call the provider for queries shorter than three characters", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  provider.searchResults = [providerFood("4607000000004", "Tiny Query Result")];

  const response = await searchFoods({
    repository,
    provider,
    userId: "user-1",
    query: "ok",
    limit: 5,
    providerSearchEnabled: true,
  });

  assertEquals(response.results, []);
  assertEquals(provider.searchCalls, 0);
});

Deno.test("search rethrows non-availability provider errors", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  provider.searchError = new FoodsError(
    422,
    "insufficient_nutrition_data",
    "provider payload invalid",
  );

  const error = await assertRejects(
    () =>
      searchFoods({
        repository,
        provider,
        userId: "user-1",
        query: "protein",
        limit: 5,
        providerSearchEnabled: true,
      }),
    FoodsError,
  ) as FoodsError;

  assertEquals(error.code, "insufficient_nutrition_data");
  assertEquals(error.message, "provider payload invalid");
});

Deno.test("search keeps successful provider rows when one provider cache write fails", async () => {
  class PartiallyFailingRepository extends FakeFoodsRepository {
    override upsertCatalogFood(
      payload: CatalogFoodUpsertInput,
    ): Promise<CatalogFoodRow> {
      if (payload.barcode === "4607000000005") {
        return Promise.reject(
          new FoodsError(500, "catalog_cache_failed", "write failed"),
        );
      }
      return super.upsertCatalogFood(payload);
    }
  }

  const repository = new PartiallyFailingRepository();
  const provider = new FakeFoodsProvider();
  provider.searchResults = [
    providerFood("4607000000005", "Broken Provider Row"),
    providerFood("4607000000006", "Good Provider Row"),
  ];

  const response = await searchFoods({
    repository,
    provider,
    userId: "user-1",
    query: "provider",
    limit: 5,
    providerSearchEnabled: true,
  });

  assertEquals(response.results.map((row) => row.name), ["Good Provider Row"]);
  assertEquals(repository.upsertCalls.length, 1);
});

Deno.test("Open Food Facts search uses custom base URL, headers, and unsuffixed 100g nutriments", async () => {
  let seenUrl = "";
  let seenHeaders: Record<string, string> = {};

  await withMockFetch((input, init) => {
    seenUrl = String(input);
    seenHeaders = init?.headers as Record<string, string>;
    return Promise.resolve(
      new Response(
        JSON.stringify({
          products: [
            {
              code: "4607000000007",
              product_name_ru: "Йогурт",
              brands: "Домик,Запасной бренд",
              serving_size: "1 piece",
              nutrition_data_per: "100g",
              nutriments: {
                proteins: "10",
                fat: "5",
                carbohydrates: "20",
                fiber: "3",
                sugars: "12",
                salt: "0.5",
                "energy-kcal": "165",
              },
              lang: "ru",
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    );
  }, async () => {
    const keys = [
      "OPEN_FOOD_FACTS_BASE_URL",
      "OPEN_FOOD_FACTS_USER_AGENT",
      "OPEN_FOOD_FACTS_BARCODE_TIMEOUT_MS",
      "OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS",
    ] as const;
    const previous = Object.fromEntries(
      keys.map((key) => [key, Deno.env.get(key)]),
    ) as Record<(typeof keys)[number], string | undefined>;

    Deno.env.set("OPEN_FOOD_FACTS_BASE_URL", "https://example.test/off");
    Deno.env.set("OPEN_FOOD_FACTS_USER_AGENT", "CustomAgent/2.0");
    Deno.env.set("OPEN_FOOD_FACTS_BARCODE_TIMEOUT_MS", "0");
    Deno.env.set("OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS", "-1");

    try {
      const provider = defaultFoodsProvider();
      const results = await provider.search(
        "йогурт",
        3,
        "ru-RU,ru;q=0.9",
        new Date("2026-03-06T00:00:00Z"),
      );

      assertEquals(results.length, 1);
      assertEquals(results[0].name, "Йогурт");
      assertEquals(results[0].brand, "Домик");
      assertEquals(results[0].locale, "ru");
      assertEquals(results[0].serving_size_g, null);
      assertEquals(results[0].macros_per_100g.calories, 165);
      assertEquals(results[0].macros_per_100g.protein_g, 10);
      assertEquals(results[0].macros_per_100g.fiber_g, 3);
      assertEquals(results[0].sodium_mg_per_100g, 196.5);
      assertEquals(results[0].source_confidence, 0.85);
    } finally {
      for (const key of keys) {
        const value = previous[key];
        if (value === undefined) {
          Deno.env.delete(key);
        } else {
          Deno.env.set(key, value);
        }
      }
    }
  });

  assertStringIncludes(seenUrl, "https://example.test/off/cgi/search.pl");
  assertEquals(seenHeaders["User-Agent"], "CustomAgent/2.0");
  assertEquals(seenHeaders["Accept-Language"], "ru-RU");
});

Deno.test("Open Food Facts search skips invalid products and uses serving-based nutriment fallback", async () => {
  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          products: [
            {
              code: "4607000000008",
              generic_name: "Protein shake",
              serving_size: "30 g",
              nutriments: {
                proteins_serving: 24,
                fat_serving: 2,
                carbohydrates_serving: 3,
                fiber_serving: 1,
                sugars_serving: 2,
                "energy-kcal_serving": 130,
              },
              lang: "en",
            },
            {
              product_name: "Missing code should be skipped",
              nutriments: {
                proteins_100g: 8,
                fat_100g: 2,
                carbohydrates_100g: 10,
                "energy-kcal_100g": 90,
              },
            },
            {
              code: "4607000000009",
              product_name: "Broken Macros",
              nutriments: {
                proteins_100g: -1,
                fat_100g: 2,
                carbohydrates_100g: 10,
                "energy-kcal_100g": 90,
              },
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const results = await provider.search(
      "shake",
      5,
      "en_US",
      new Date("2026-03-06T00:00:00Z"),
    );

    assertEquals(results.length, 1);
    assertEquals(results[0].name, "Protein shake");
    assertEquals(results[0].serving_size_g, 30);
    assertEquals(results[0].macros_per_100g.protein_g, 80);
    assertEquals(results[0].macros_per_100g.fat_g, 6.7);
    assertEquals(results[0].macros_per_100g.carbs_g, 10);
    assertEquals(results[0].macros_per_100g.fiber_g, 3.3);
    assertEquals(results[0].sugar_per_100g, 6.7);
    assertEquals(results[0].source_confidence, 0.78);
  });
});

Deno.test("search scoring prioritizes exact barcode and exact name matches within cached catalog rows", async () => {
  const repository = new FakeFoodsRepository();
  repository.catalogSearchRows = [
    {
      ...catalogFood(
        "catalog-exact-barcode",
        "open_food_facts",
        "Alpha Mix",
        "460123",
      ),
      brand: "Brand One",
    },
    {
      ...catalogFood("catalog-exact-name", "open_food_facts", "460123"),
      brand: "Brand Two",
    },
    {
      ...catalogFood("catalog-prefix", "open_food_facts", "460123 Protein"),
      brand: "Brand Three",
    },
    {
      ...catalogFood("catalog-brand", "open_food_facts", "Neutral Name"),
      brand: "460123 Foods",
    },
  ];

  const response = await searchFoods({
    repository,
    userId: "user-1",
    query: "460123",
    limit: 4,
    providerSearchEnabled: false,
  });

  assertEquals(
    response.results.map((row) => row.id),
    [
      "catalog-exact-name",
      "catalog-exact-barcode",
      "catalog-prefix",
      "catalog-brand",
    ],
  );
  assert(
    response.results.every((row) => row.type === "catalog"),
  );
});

Deno.test("foods provider env helpers and barcode helpers normalize flags and patterns", () => {
  withEnv("FOODS_PROVIDER_ENABLED", "false", () => {
    withEnv("FOODS_PROVIDER_SEARCH_ENABLED", undefined, () => {
      withEnv("FOODS_PROVIDER_BARCODE_ENABLED", undefined, () => {
        assertEquals(isFoodsProviderSearchEnabled(), false);
        assertEquals(isFoodsProviderBarcodeEnabled(), false);
      });
    });
  });

  withEnv("FOODS_PROVIDER_ENABLED", "false", () => {
    withEnv("FOODS_PROVIDER_SEARCH_ENABLED", "yes", () => {
      withEnv("FOODS_PROVIDER_BARCODE_ENABLED", "0", () => {
        assertEquals(isFoodsProviderSearchEnabled(), true);
        assertEquals(isFoodsProviderBarcodeEnabled(), false);
      });
    });
  });

  assertEquals(isBarcodeCode("4601234567890"), true);
  assertEquals(isBarcodeCode("ab_cd-42"), true);
  assertEquals(isBarcodeCode("a"), false);
  assertEquals(isBarcodeCode("bad barcode"), false);
  assertEquals(escapeIlike("100%_whey"), "100\\%\\_whey");
});

Deno.test("Open Food Facts search uses serving fallback, localized names, and skips invalid products", async () => {
  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          products: [
            {
              code: "4605555555555",
              product_name_ru: "Творожок",
              brands: "Простоквашино,Россия",
              serving_size: "30 g",
              nutriments: {
                proteins_serving: 3,
                fat_serving: 4.5,
                carbohydrates_serving: 6,
                fiber_serving: 0.9,
                sugars_serving: 4.2,
                salt_serving: 0.12,
                "energy-kcal_serving": 90,
              },
              image_front_url: "https://example.com/tvorozhok.jpg",
              lang: "ru-RU",
            },
            {
              code: "4606666666666",
              product_name: "Broken Item",
              nutriments: {},
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const now = new Date("2026-03-06T00:00:00.000Z");
    const results = await provider.search("творожок", 5, "ru-RU", now);

    assertEquals(results.length, 1);
    assertEquals(results[0].name, "Творожок");
    assertEquals(results[0].brand, "Простоквашино");
    assertEquals(results[0].locale, "ru_RU");
    assertEquals(results[0].image_url, "https://example.com/tvorozhok.jpg");
    assertEquals(results[0].serving_size_g, 30);
    assertEquals(results[0].macros_per_100g, {
      calories: 300,
      protein_g: 10,
      fat_g: 15,
      carbs_g: 20,
      fiber_g: 3,
    });
    assertEquals(results[0].sugar_per_100g, 14);
    assertEquals(results[0].sodium_mg_per_100g, 157.3);
    assertEquals(results[0].source_confidence, 0.78);
    assertEquals(results[0].fetched_at, "2026-03-06T00:00:00.000Z");
  });
});

Deno.test("Open Food Facts provider returns empty search results for malformed payload and wraps fetch failures", async () => {
  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({ items: [] }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const results = await provider.search("milk", 3, "en-US");
    assertEquals(results, []);
  });

  await withMockFetch(() =>
    Promise.resolve(
      new Response("not-json", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ), async () => {
    const provider = defaultFoodsProvider();
    const error = await assertRejects(
      () => provider.lookupBarcode("4607777777777", "en-US"),
      FoodsError,
    ) as FoodsError;

    assertEquals(error.status, 503);
    assertEquals(error.code, "provider_unavailable");
  });
});

Deno.test("foods provider helper hooks preserve normalization defaults and provider lookup fallbacks", async () => {
  const hooks = __foodsProviderTestHooks;
  const defaultError = new FoodsError(418, "teapot");
  assertEquals(defaultError.message, "teapot");

  assertEquals(
    hooks.toMacros({
      calories_per_100g: "110.5",
      protein_per_100g: "18",
      fat_per_100g: "3",
      carbs_per_100g: "9",
      fiber_per_100g: null,
    } as never),
    {
      calories: 110.5,
      protein_g: 18,
      fat_g: 3,
      carbs_g: 9,
      fiber_g: null,
    },
  );

  const localized = hooks.normalizeOpenFoodFactsProduct(
    {
      code: "4608888888888",
      generic_name_fr: "Yaourt nature",
      abbreviated_product_name: "Backup",
      brands: "  Ferme,Ignore ",
      nutriments: {
        proteins_100g: 9,
        fat_100g: 4,
        carbohydrates_100g: 11,
        "energy-kcal_100g": 110,
      },
      lang: "fr",
    },
    null,
    new Date("2026-03-06T00:00:00.000Z"),
    "fr-FR",
  );
  assertEquals(localized.ok, true);
  if (localized.ok) {
    assertEquals(localized.value.name, "Yaourt nature");
    assertEquals(localized.value.brand, "Ferme");
  }

  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({ status: 0, product: null }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const result = await provider.lookupBarcode("4608888888888", "fr-FR");
    assertEquals(result, null);
  });

  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          status: 1,
          code: "4609999999999",
          product: {
            product_name: "Mystery Product",
          },
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const error = await assertRejects(
      () => provider.lookupBarcode("4609999999999", "fr-FR"),
      FoodsError,
    ) as FoodsError;
    assertEquals(error.status, 422);
    assertEquals(error.code, "insufficient_nutrition_data");
  });
});

Deno.test("search uses env-enabled provider and recent refs for both custom and catalog items", async () => {
  const repository = new FakeFoodsRepository();
  repository.recents = [{
    user_food_id: "custom-1",
    catalog_item_id: "catalog-1",
  }];
  repository.customSearchRows = [customFood("custom-1", "Greek Yogurt")];
  repository.catalogSearchRows = [
    catalogFood("catalog-1", "open_food_facts", "Greek Yogurt Drink"),
  ];

  const provider = new FakeFoodsProvider();

  const previous = Deno.env.get("FOODS_PROVIDER_ENABLED");
  Deno.env.set("FOODS_PROVIDER_ENABLED", "true");
  try {
    const response = await searchFoods({
      repository,
      provider,
      userId: "user-1",
      query: "greek yogurt",
      limit: 5,
      locale: "en-US,en;q=0.9",
    });

    assertEquals(provider.searchCalls, 1);
    assertEquals(
      response.results.map((row) => ({ id: row.id, tags: row.tags.sort() })),
      [
        { id: "custom-1", tags: ["recent"] },
        { id: "catalog-1", tags: ["recent"] },
      ],
    );
  } finally {
    if (previous === undefined) {
      Deno.env.delete("FOODS_PROVIDER_ENABLED");
    } else {
      Deno.env.set("FOODS_PROVIDER_ENABLED", previous);
    }
  }
});

Deno.test("createSupabaseFoodsRepository falls back to empty collections when Supabase returns null data", async () => {
  const service = createMockSupabaseService((state) => {
    if (
      ["user_food_favorites", "food_items", "user_foods", "food_catalog_items"]
        .includes(state.table) &&
      state.terminal === "returns"
    ) {
      return { data: null, error: null };
    }

    if (
      ["user_foods", "food_catalog_items"].includes(state.table) &&
      state.terminal === "maybeSingle"
    ) {
      return { data: null, error: null };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const repository = createSupabaseFoodsRepository(service as never);

  assertEquals(await repository.listFavoriteRefs("user-1"), []);
  assertEquals(await repository.listRecentRefs("user-1"), []);
  assertEquals(await repository.searchCustomFoods("user-1", "kefir", 5), []);
  assertEquals(await repository.searchCatalogFoods("kefir", 5), []);
  assertEquals(
    await repository.findCustomFoodByBarcode("user-1", "4601"),
    null,
  );
  assertEquals(
    await repository.findCatalogFoodByBarcode("open_food_facts", "4602"),
    null,
  );
});

Deno.test("barcode lookup returns not_found without touching the provider when barcode enrichment is disabled", async () => {
  const repository = new FakeFoodsRepository();
  const provider = new FakeFoodsProvider();
  const previous = Deno.env.get("FOODS_PROVIDER_ENABLED");
  Deno.env.set("FOODS_PROVIDER_ENABLED", "off");

  try {
    const outcome = await lookupFoodByBarcode({
      repository,
      provider,
      userId: "user-1",
      barcode: "4607000000010",
      now: new Date("2026-04-10T00:00:00Z"),
    });

    assertEquals(outcome, { status: "not_found" });
    assertEquals(provider.lookupCalls, 0);
  } finally {
    if (previous === undefined) {
      Deno.env.delete("FOODS_PROVIDER_ENABLED");
    } else {
      Deno.env.set("FOODS_PROVIDER_ENABLED", previous);
    }
  }
});
