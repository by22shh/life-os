import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  __accountDeletionTestHooks,
  cleanupMedicalScanStorage,
  type DeletionJobRow,
  type UserRow,
} from "../_shared/account_deletion.ts";
import { __corsTestHooks } from "../_shared/cors.ts";
import {
  __dailyInsightsTestHooks,
  generateAndPersistDailyInsights,
} from "../_shared/daily_insights.ts";
import {
  localDateInTimeZone,
  representativeTimestampForLocalDate,
  utcOffsetMinutesAt,
} from "../_shared/datetime.ts";
import { parseLocalDateRange } from "../_shared/date_range.ts";
import { __foodsProviderTestHooks } from "../_shared/foods_provider.ts";
import { __medicalScanPrivacyTestHooks } from "../_shared/medical_scan_privacy.ts";
import {
  adaptNextBestActionForWatch,
  determineNextBestAction,
  dueSupplementInWindow,
  dueSupplementsSummary,
  suggestedMealType,
} from "../_shared/next_best_action.ts";
import { __predictiveContextTestHooks } from "../_shared/predictive_context.ts";
import {
  __supplementLogHandlerTestHooks,
  __supplementLogTestHooks,
  serveSupplementLog,
} from "../_shared/supplement_log_handler.ts";
import { buildSupplementDayResult } from "../_shared/supplements.ts";
import {
  json,
  validateInternalServiceRoleRequest,
} from "../_shared/supabase.ts";
import {
  captureEdgeHandler,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";
import {
  createMockSupabaseService,
  type MockQueryState,
} from "./_mock_supabase_service.ts";

function withEnv(
  key: string,
  value: string | undefined,
  fn: () => void | Promise<void>,
): void | Promise<void> {
  const previous = Deno.env.get(key);
  if (value === undefined) {
    Deno.env.delete(key);
  } else {
    Deno.env.set(key, value);
  }

  try {
    return fn();
  } finally {
    if (previous === undefined) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, previous);
    }
  }
}

async function loadEdgeModule<T>(modulePath: string): Promise<T> {
  await captureEdgeHandler(modulePath);
  return await import(new URL(modulePath, import.meta.url).href) as T;
}

function withMockedDateTimeFormat(
  factory: (options?: Intl.DateTimeFormatOptions) => {
    format?: (date: Date) => string;
    formatToParts?: (date: Date) => Intl.DateTimeFormatPart[];
  },
  fn: () => void,
): void {
  const RealDateTimeFormat = Intl.DateTimeFormat;
  Intl.DateTimeFormat = class MockDateTimeFormat {
    #impl;
    constructor(
      _locale?: string | string[],
      options?: Intl.DateTimeFormatOptions,
    ) {
      this.#impl = factory(options);
    }
    format(date: Date): string {
      return this.#impl.format
        ? this.#impl.format(date)
        : new RealDateTimeFormat("en-US").format(date);
    }
    formatToParts(date: Date): Intl.DateTimeFormatPart[] {
      return this.#impl.formatToParts
        ? this.#impl.formatToParts(date)
        : new RealDateTimeFormat("en-US").formatToParts(date);
    }
  } as unknown as typeof Intl.DateTimeFormat;

  try {
    fn();
  } finally {
    Intl.DateTimeFormat = RealDateTimeFormat;
  }
}

function makePredictiveRecord(
  outcomeDate: string,
  overrides: Record<string, unknown> = {},
) {
  return {
    outcomeDate,
    phys: {
      date: outcomeDate,
      recovery_score: 66,
      recovery_zone: null,
      sleep_duration_hours: 7,
      sleep_quality_percent: 78,
      hrv_ms: 50,
      resting_heart_rate_bpm: 55,
      wrist_temperature_deviation_c: 0,
      allostatic_load: 2,
      steps: 7_500,
      data_completeness: 0.9,
      confidence_score: 0.8,
    },
    training: null,
    nutrition: {
      date: outcomeDate,
      total_calories: 2_200,
      total_protein: 130,
      total_carbs: 240,
      total_fat: 70,
      alcohol_units: 0,
      caffeine_mg_total: 80,
      caffeine_mg_after_14: 0,
      meal_count: 3,
    },
    target: {
      date: outcomeDate,
      final_calories: 2_200,
      final_protein_g: 150,
      final_carbs_g: 250,
      final_fat_g: 70,
    },
    hydrationMl: 2_100,
    wellness: {
      date: outcomeDate,
      energy_level: 4,
      stress_level: 2,
      muscle_soreness: 1,
      feeling_ill: false,
      wellness_score: 75,
    },
    workouts: {
      workoutCount: 0,
      totalDurationMinutes: 0,
      totalTrimp: 0,
      lateWorkoutCount: 0,
      workoutTypes: [],
    },
    ...overrides,
  };
}

Deno.test("true last mile shared guards keep malformed runtime inputs safe", () => {
  withMockedDateTimeFormat((options) => {
    if (options?.hour12 === false) {
      return { formatToParts: () => [] };
    }
    return { format: () => "2026-06-01" };
  }, () => {
    assertEquals(
      utcOffsetMinutesAt(new Date("1970-01-01T00:00:00.000Z"), "UTC"),
      0,
    );
  });

  let localDateCalls = 0;
  withMockedDateTimeFormat((options) => {
    if (options?.hour12 === false) {
      return {
        formatToParts: () => [
          { type: "year", value: "2026" },
          { type: "month", value: "06" },
          { type: "day", value: "01" },
          { type: "hour", value: "00" },
          { type: "minute", value: "00" },
          { type: "second", value: "00" },
        ],
      };
    }
    return {
      format: () => {
        localDateCalls += 1;
        return localDateCalls === 1 ? "2026-05-31" : "2026-06-01";
      },
    };
  }, () => {
    assertEquals(
      localDateInTimeZone(
        representativeTimestampForLocalDate("2026-06-01", "UTC"),
        "UTC",
      ),
      "2026-06-01",
    );
  });

  assertEquals(
    __corsTestHooks.isValidAbsoluteUrl("http://localhost:54321"),
    true,
  );
  assertEquals(__corsTestHooks.isValidAbsoluteUrl("nota url"), false);
  assertEquals(__corsTestHooks.isAppStoreSearchUrl("nota url"), false);

  withEnv("SUPABASE_SERVICE_ROLE_KEY", "edge-secret", () => {
    const missingApikey = new Request("http://localhost", {
      headers: { Authorization: "Bearer edge-secret" },
    });
    const validation = validateInternalServiceRoleRequest(missingApikey);
    assertEquals(validation.ok, false);
    if (!validation.ok) {
      assertEquals(validation.error, "unauthorized");
    }
  });

  withEnv("APP_STORE_URL", "https://apps.apple.com/search?term=lifeos", () => {
    withEnv("APP_STORE_ID", " id123456789 ", () => {
      assertEquals(
        __corsTestHooks.resolveConfiguredAppStoreUrl(),
        "https://apps.apple.com/app/id123456789",
      );
    });
  });

  const response = json({ ok: true }, 202, { "X-Test": "yes" });
  assertEquals(response.status, 202);
  assertEquals(response.headers.get("X-Test"), "yes");

  assertEquals(
    parseLocalDateRange(new Request("http://localhost?to=2026-06-01"), 7),
    null,
  );
  assertEquals(
    buildSupplementDayResult("2026-06-01", [], [], new Map())
      .adherence_today_percent,
    0,
  );
});

Deno.test("true last mile medical scan storage verification rejects path escapes and survivors", async () => {
  const hooks = __medicalScanPrivacyTestHooks;

  assertEquals(hooks.sanitizeStorageObjectPath("medical-scans/"), null);
  assertEquals(hooks.sanitizeStorageObjectPath("   "), null);
  assertEquals(hooks.sanitizeStorageObjectPath("auth-user"), null);
  assertEquals(hooks.splitStorageObjectPath("file.jpg"), {
    directory: "",
    filename: "file.jpg",
  });
  assertEquals(
    hooks.extractStorageObjectPath("https://example.test/%E0%A4%A"),
    null,
  );
  assertEquals(
    hooks.extractStorageObjectPath(
      "https://example.test/storage/v1/object/render/medical-scans/auth-user/report/file.jpg",
    ),
    "auth-user/report/file.jpg",
  );
  assertEquals(
    hooks.normalizeMedicalScanStoragePath(
      "AUTH-USER/report/file.jpg",
      "auth-user",
    ),
    "AUTH-USER/report/file.jpg",
  );
  assertEquals(hooks.chunkArray([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);

  const remainingViaSchema = {
    storage: {
      from: () => ({
        remove: () => Promise.resolve({ error: null }),
      }),
    },
    schema: () => ({
      from: () => ({
        select: () => ({
          eq: () => ({
            in: () =>
              Promise.resolve({
                data: [{ name: "auth-user/report/file.jpg" }],
                error: null,
              }),
          }),
        }),
      }),
    }),
  };
  await assertRejects(
    () =>
      hooks.removeMedicalScanStorageObjects(
        remainingViaSchema as never,
        "auth-user",
        ["auth-user/report/file.jpg"],
      ),
    Error,
    "medical_scan_storage_objects_remaining:auth-user/report/file.jpg",
  );

  const remainingViaStorageApi = {
    storage: {
      from: () => ({
        list: () =>
          Promise.resolve({
            data: [{ name: "file.jpg" }],
            error: null,
          }),
      }),
    },
  };
  await assertRejects(
    () =>
      hooks.verifyMedicalScanStorageObjectsRemovedViaStorageApi(
        remainingViaStorageApi as never,
        ["auth-user/report/file.jpg"],
      ),
    Error,
    "medical_scan_storage_objects_remaining:auth-user/report/file.jpg",
  );

  const verifyFailure = {
    storage: {
      from: () => ({
        remove: () => Promise.resolve({ error: null }),
      }),
    },
    schema: () => ({
      from: () => ({
        select: () => ({
          eq: () => ({
            in: () =>
              Promise.resolve({
                data: null,
                error: { message: "permission denied" },
              }),
          }),
        }),
      }),
    }),
  };
  await assertRejects(
    () =>
      hooks.removeMedicalScanStorageObjects(
        verifyFailure as never,
        "auth-user",
        ["auth-user/report/file.jpg"],
      ),
    Error,
    "medical_scan_storage_verify_failed:permission denied",
  );
});

Deno.test("true last mile account deletion storage cleanup persists verified manifests", async () => {
  assertEquals(
    __accountDeletionTestHooks.sanitizeStorageObjectPath("medical-scans/"),
    null,
  );

  const user: UserRow = { id: "user-1", auth_id: "auth-user" };
  const job: DeletionJobRow = {
    id: "job-1",
    user_id: "user-1",
    auth_user_id: null,
    idempotency_key: "idem-1",
    mode: "immediate",
    state: "data_deleting",
    reason: null,
    attempt_count: 1,
    next_retry_at: null,
    last_error: null,
    last_failure_type: null,
    scheduled_for: null,
    audit_log_id: "audit-1",
    storage_object_paths: [
      "auth-user/report/file.jpg",
      "medical-scans/auth-user/report/file.jpg",
      "other-user/report/file.jpg",
    ],
    storage_cleanup_completed: false,
    storage_cleanup_completed_at: null,
    created_at: "2026-06-01T00:00:00.000Z",
    updated_at: "2026-06-01T00:00:00.000Z",
  };
  const removedBatches: string[][] = [];
  let updatePayload: Record<string, unknown> | undefined;

  const queryService = createMockSupabaseService((state) => {
    if (state.table === "account_deletion_jobs" && state.action === "update") {
      const payload = state.payload as Record<string, unknown>;
      updatePayload = payload;
      return {
        data: { ...job, ...payload },
        error: null,
      };
    }
    return { data: [], error: null };
  });
  const service = {
    ...queryService,
    storage: {
      from: () => ({
        remove: (batch: string[]) => {
          removedBatches.push(batch);
          return Promise.resolve({ error: null });
        },
        list: () => Promise.resolve({ data: [], error: null }),
      }),
    },
    schema: () => ({
      from: () => ({
        select: () => ({
          eq: () => ({
            in: () =>
              Promise.resolve({
                data: [
                  { name: null },
                  { name: "other-user/report/file.jpg" },
                ],
                error: null,
              }),
          }),
        }),
      }),
    }),
  };

  const result = await cleanupMedicalScanStorage(
    service as never,
    user,
    job,
  );

  assertEquals(result.ok, true);
  assertEquals(removedBatches, [["auth-user/report/file.jpg"]]);
  assert(updatePayload);
  assertEquals(updatePayload["auth_user_id"], "auth-user");
  assertEquals(updatePayload["storage_object_paths"], [
    "auth-user/report/file.jpg",
  ]);
  assertEquals(updatePayload["storage_cleanup_completed"], true);
});

Deno.test("true last mile action helpers respect null meals, watch passthrough, and locale parsing", () => {
  const logMealAction = determineNextBestAction({
    date: "2026-06-01",
    needsReview: false,
    lowConfidence: false,
    supplementDueSoon: null,
    nutritionCurrentCalories: 600,
    nutritionTargetCalories: 2_000,
    lastMealAt: null,
    sleepNeedsPermission: false,
    unreadInsightId: null,
    isToday: true,
    timezone: "UTC",
  });
  assertEquals(logMealAction.type, "log_meal");

  const supplementAction = determineNextBestAction({
    date: "2026-06-01",
    needsReview: false,
    lowConfidence: false,
    supplementDueSoon: {
      supplement_name: "Magnesium",
      scheduled_time: "21:00",
    },
    nutritionCurrentCalories: 2_100,
    nutritionTargetCalories: 2_000,
    lastMealAt: new Date().toISOString(),
    sleepNeedsPermission: false,
    unreadInsightId: null,
    isToday: true,
    timezone: "UTC",
  });
  assertEquals(
    adaptNextBestActionForWatch({
      action: supplementAction,
      date: "2026-06-01",
      lowConfidence: false,
    }),
    supplementAction,
  );

  withMockedDateTimeFormat((options) => {
    if (options?.minute === "2-digit") {
      return {
        formatToParts: () => [{ type: "hour", value: "08" }],
      };
    }
    return { format: () => "08" };
  }, () => {
    const now = new Date("2026-06-01T00:00:00.000Z");
    const schedule = [{
      time: "08:30",
      supplements: [{ name: "Vitamin D", taken: false }],
    }];
    assertEquals(
      dueSupplementInWindow(schedule, now, "UTC")?.scheduled_time,
      "08:30",
    );
    assertEquals(dueSupplementsSummary(schedule, now, "UTC"), {
      time: "08:30",
      count: 1,
    });
  });

  withMockedDateTimeFormat(() => ({ format: () => "not-an-hour" }), () => {
    assertEquals(suggestedMealType("UTC"), "snack");
  });
  withMockedDateTimeFormat((options) => {
    if (options?.minute === "2-digit") {
      return {
        formatToParts: () => [{ type: "minute", value: "45" }],
      };
    }
    return { format: () => "00" };
  }, () => {
    assertEquals(dueSupplementInWindow([], new Date(), "UTC"), null);
  });
});

Deno.test("true last mile AI parser hooks reject invalid images and keep array content deterministic", async () => {
  const imageModule = await loadEdgeModule<{
    __analyzeFoodImageTestHooks: {
      asTrimmedString(value: unknown, maxLength: number): string | null;
      extractMessageContent(payload: unknown): string;
      normalizeBarcodes(value: unknown): string[];
      normalizeImageDataUrl(value: unknown): string | null;
    };
  }>("../analyze-food-image/index.ts");
  const labelModule = await loadEdgeModule<{
    __analyzeFoodLabelTestHooks: {
      cleanWarnings(value: unknown): string[];
      extractMessageContent(payload: unknown): string;
      normalizeImageDataUrl(value: unknown): string | null;
    };
  }>("../analyze-food-label/index.ts");
  const batchModule = await loadEdgeModule<{
    __analyzeBatchRecipeImageTestHooks: {
      normalizeIngredient(value: unknown): unknown;
      normalizeImageDataUrl(value: unknown): string | null;
      normalizeBatchRecipeResponse(value: unknown, context: {
        recipe_name: string;
        total_weight_g: number;
        portions_planned: number;
        known_ingredients: Array<
          { name: string; raw_weight_g?: number | null }
        >;
      }): {
        ingredients_detected: Array<{ estimated_raw_weight_g: number | null }>;
      } | null;
    };
  }>("../analyze-batch-recipe-image/index.ts");
  const openRouterModule = await loadEdgeModule<{
    __openRouterGatewayTestHooks: {
      sanitizeMessages(value: unknown): unknown;
    };
  }>("../ai/openrouter-gateway/index.ts");
  const parseModule = await loadEdgeModule<{
    __parseFoodTextTestHooks: {
      parseSegment(value: string): {
        quantity: number | null;
        unit: string | null;
        weightG: number | null;
      };
      unitToGrams(quantity: number, unit: string | null): number | null;
    };
  }>("../parse-food-text/index.ts");

  assertEquals(
    imageModule.__analyzeFoodImageTestHooks.asTrimmedString("  ", 4),
    null,
  );
  assertEquals(
    imageModule.__analyzeFoodImageTestHooks.normalizeImageDataUrl(42),
    null,
  );
  assertEquals(
    imageModule.__analyzeFoodImageTestHooks.extractMessageContent({
      choices: [{
        message: { content: [null, { text: 123 }, { text: "borsch" }] },
      }],
    }),
    "borsch",
  );
  assertEquals(
    imageModule.__analyzeFoodImageTestHooks.extractMessageContent({
      choices: [{ message: { content: 123 } }],
    }),
    "",
  );
  assertEquals(
    imageModule.__analyzeFoodImageTestHooks.normalizeBarcodes(
      ["1", "1", "2", "3", "4", "5", "6", "7"],
    ),
    ["1", "2", "3", "4", "5", "6"],
  );

  assertEquals(
    labelModule.__analyzeFoodLabelTestHooks.normalizeImageDataUrl(
      "data:image/png,abc",
    ),
    null,
  );
  assertEquals(
    labelModule.__analyzeFoodLabelTestHooks.normalizeImageDataUrl(""),
    null,
  );
  assertEquals(
    labelModule.__analyzeFoodLabelTestHooks.cleanWarnings(
      [" A ", "a", "B", "C", "D", "E", "F", "G"],
    ),
    ["A", "B", "C", "D", "E", "F"],
  );
  assertEquals(
    labelModule.__analyzeFoodLabelTestHooks.extractMessageContent({
      choices: [{
        message: { content: [null, { text: 0 }, { text: "label" }] },
      }],
    }),
    "label",
  );

  assertEquals(
    batchModule.__analyzeBatchRecipeImageTestHooks.normalizeImageDataUrl(
      "data:image/png,abc",
    ),
    null,
  );
  const ingredient = batchModule.__analyzeBatchRecipeImageTestHooks
    .normalizeIngredient({
      name: "Carrot",
      raw_weight_g: -10,
    }) as { estimated_raw_weight_g: number | null };
  assertEquals(ingredient.estimated_raw_weight_g, null);
  const fallbackRecipe = batchModule.__analyzeBatchRecipeImageTestHooks
    .normalizeBatchRecipeResponse({
      recipe_name: "",
      ingredients_detected: [],
      total_batch: {},
      confidence: 0.5,
    }, {
      recipe_name: "Soup",
      total_weight_g: 800,
      portions_planned: 4,
      known_ingredients: [{ name: "Potato", raw_weight_g: 250 }],
    });
  assertEquals(
    fallbackRecipe?.ingredients_detected[0]?.estimated_raw_weight_g,
    250,
  );

  assertEquals(
    openRouterModule.__openRouterGatewayTestHooks.sanitizeMessages([]),
    null,
  );
  assertEquals(
    openRouterModule.__openRouterGatewayTestHooks.sanitizeMessages([
      { role: "user", content: [{ type: "text", text: "hello" }] },
    ]),
    [{ role: "user", content: [{ type: "text", text: "hello" }] }],
  );
  assertEquals(
    openRouterModule.__openRouterGatewayTestHooks.sanitizeMessages([
      { role: "user", content: [{ text: "x".repeat(31_000) }] },
    ]),
    null,
  );
  assertEquals(
    openRouterModule.__openRouterGatewayTestHooks.sanitizeMessages(
      Array.from({ length: 8 }, () => ({
        role: "user",
        content: [{ text: "x".repeat(7_000) }],
      })),
    ),
    null,
  );

  assertEquals(
    parseModule.__parseFoodTextTestHooks.unitToGrams(2, "piece"),
    200,
  );
  assertEquals(
    parseModule.__parseFoodTextTestHooks.unitToGrams(2, "mystery"),
    2,
  );
  const parsed = parseModule.__parseFoodTextTestHooks.parseSegment(
    "NaN g apple",
  );
  assertEquals(parsed.quantity, null);
  assertEquals(parsed.weightG, null);

  const parseHandler = await captureEdgeHandler("../parse-food-text/index.ts");
  await withMockedEdgeRuntime({}, async () => {
    const response = await parseHandler(
      new Request("http://localhost/parse-food-text", {
        method: "POST",
        headers: { Authorization: "Bearer user-token" },
        body: JSON.stringify({ text: 42 }),
      }),
    );
    const body = await response.json();
    assertEquals(response.status, 400);
    assertEquals(body.error, "invalid_payload");
    assert(Array.isArray(body.issues));
  });
});

Deno.test("true last mile foods and predictive helpers preserve fallback ranking semantics", () => {
  const foods = __foodsProviderTestHooks;
  assertEquals(foods.localeLanguage(""), null);
  assertEquals(foods.localeLanguage("RU_ru"), "ru");
  assertEquals(foods.localeLanguage("_"), null);
  assertEquals(foods.normalizeLocale(",en-US"), null);
  assertEquals(foods.normalizeBrand(", Brand B"), null);
  assertEquals(foods.parseServingSizeGrams("250 g, about one cup"), 250);
  assertEquals(foods.parseServingSizeGrams("250 ml, about one cup"), null);
  assertEquals(foods.parseServingSizeGrams("not a serving"), null);
  assertEquals(
    foods.firstNonEmptyString(null, "  first, second "),
    "first, second",
  );
  assertEquals(
    foods.toErrorMessage({ message: "plain object failure" }),
    "unknown provider error",
  );
  assertEquals(
    foods.toMacros({
      calories_per_100g: null,
      protein_per_100g: null,
      fat_per_100g: null,
      carbs_per_100g: null,
      fiber_per_100g: null,
    } as never),
    {
      calories: 0,
      protein_g: 0,
      fat_g: 0,
      carbs_g: 0,
      fiber_g: null,
    },
  );

  const custom = foods.toCustomSearchCandidate(
    {
      id: "custom-1",
      name: " Kefir ",
      brand: null,
      serving_size_g: null,
      default_serving_g: null,
      calories_per_100g: "50",
      protein_per_100g: "4",
      fat_per_100g: "2",
      carbs_per_100g: "5",
      fiber_per_100g: null,
      barcode: "460",
      updated_at: "2026-06-01T00:00:00.000Z",
    } as never,
    new Set(),
    new Set(),
    "kefir",
  );
  assertEquals(custom?.macros_per_100g.protein_g, 4);

  const catalog = foods.toCatalogSearchCandidate(
    {
      id: "catalog-1",
      provider: "open_food_facts",
      name: "Protein bar",
      brand: null,
      serving_size_g: 50,
      calories_per_100g: 360,
      protein_per_100g: 22,
      fat_per_100g: 8,
      carbs_per_100g: 40,
      fiber_per_100g: 8,
      barcode: null,
      fetched_at: null,
      expires_at: null,
      updated_at: null,
    } as never,
    new Set(),
    new Set(["catalog:catalog-1"]),
    "protein",
    "provider",
  );
  assertEquals(catalog.type, "catalog");
  assert(catalog.tags.includes("recent"));

  const hooks = __predictiveContextTestHooks;
  const records = [
    makePredictiveRecord("2026-06-01", {
      nutrition: {
        ...makePredictiveRecord("2026-06-01").nutrition,
        alcohol_units: 2,
        caffeine_mg_after_14: 120,
      },
      wellness: {
        ...makePredictiveRecord("2026-06-01").wellness,
        stress_level: 5,
      },
    }),
    makePredictiveRecord("2026-06-02", {
      phys: {
        ...makePredictiveRecord("2026-06-02").phys,
        sleep_duration_hours: 9.5,
      },
      hydrationMl: 1_200,
    }),
  ];
  const baselines = hooks.deriveBaselines(records as never, null);
  const signals = hooks.parseScenarioSignals(
    "stress alcohol caffeine long sleep hydration",
    "general",
  );
  const matches = hooks.selectHistoricalMatches(
    records as never,
    signals,
    baselines,
  );
  assert(
    matches.some((match) =>
      match.reasons.some((reason) => reason.key === "alcohol")
    ),
  );
  assert(
    matches.some((match) =>
      match.reasons.some((reason) => reason.key === "late_caffeine")
    ),
  );
  assertStringIncludes(
    hooks.buildBaselineLines({} as never, { activity_level: "medium" } as never)
      .join("\n"),
    "unknown / medium",
  );
  assertStringIncludes(
    hooks.formatExampleLine(matches[0] as never),
    "matched on",
  );
  assertEquals(
    hooks.aggregateWorkoutsByDate([{
      session_date: "2026-06-01",
      started_at: null,
      duration_minutes: null,
      trimp_score: null,
      workout_type: "walk",
    }] as never).get("2026-06-01")?.totalDurationMinutes,
    0,
  );
  assertEquals(hooks.standardDeviation(["bad", null] as never), 0);
});

Deno.test("true last mile predictive scoring covers fallback thresholds and nullable insight ranking", () => {
  const hooks = __predictiveContextTestHooks;
  const nullBaseline = {
    recovery: null,
    sleepHours: null,
    hrvMs: null,
    rhrBpm: null,
    trimp: null,
    hydrationMl: null,
    calories: null,
    proteinG: null,
    carbsG: null,
  };
  const stressedAlcoholRecord = makePredictiveRecord("2026-06-03", {
    phys: {
      ...makePredictiveRecord("2026-06-03").phys,
      recovery_score: null,
      recovery_zone: null,
      sleep_duration_hours: 8.5,
      allostatic_load: 7,
    },
    nutrition: {
      ...makePredictiveRecord("2026-06-03").nutrition,
      alcohol_units: 2,
      caffeine_mg_after_14: 130,
    },
    wellness: {
      ...makePredictiveRecord("2026-06-03").wellness,
      stress_level: null,
    },
    workouts: {
      workoutCount: 1,
      totalDurationMinutes: 0,
      totalTrimp: 0,
      lateWorkoutCount: 0,
      workoutTypes: [],
    },
    training: {
      date: "2026-06-02",
      workout_count: 2,
      daily_duration_minutes: 95,
      daily_trimp: 120,
      acwr: 1.3,
    },
    hydrationMl: 1_000,
  });

  const sleepScore = hooks.scoreHistoricalRecord(
    stressedAlcoholRecord as never,
    hooks.parseScenarioSignals("sleep 8.5 hours alcohol stress", "sleep"),
    nullBaseline as never,
  );
  assert(sleepScore.reasons.some((reason) => reason.key === "sleep_target"));
  assert(sleepScore.reasons.some((reason) => reason.key === "alcohol"));
  assert(sleepScore.reasons.some((reason) => reason.key === "stress"));

  const nutritionScore = hooks.scoreHistoricalRecord(
    stressedAlcoholRecord as never,
    hooks.parseScenarioSignals(
      "caffeine alcohol dehydrated protein",
      "nutrition",
    ),
    nullBaseline as never,
  );
  assert(
    nutritionScore.reasons.some((reason) => reason.key === "late_caffeine"),
  );
  assert(
    nutritionScore.reasons.some((reason) => reason.key === "low_hydration"),
  );

  const generalScore = hooks.scoreHistoricalRecord(
    stressedAlcoholRecord as never,
    hooks.parseScenarioSignals(
      "sleep stress alcohol caffeine hydration workout",
      "general",
    ),
    nullBaseline as never,
  );
  assert(generalScore.reasons.some((reason) => reason.key === "late_caffeine"));
  assert(generalScore.reasons.some((reason) => reason.key === "heavy_load"));

  const currentLines = hooks.buildCurrentStateLines(
    [stressedAlcoholRecord] as never,
    { primary_goal: null, activity_level: "low" } as never,
    { predictedScore: 44, predictedZone: "critical" } as never,
  );
  assertStringIncludes(currentLines.join("\n"), "caution");
  assertStringIncludes(currentLines.join("\n"), "unknown / low");

  const aggregateLines = hooks.buildAggregateSummaryLines(
    [{ score: 1, record: stressedAlcoholRecord, reasons: [] }] as never,
    nullBaseline as never,
    hooks.parseScenarioSignals("hydration", "general") as never,
  );
  assertStringIncludes(aggregateLines.join("\n"), "hydration");

  const selected = hooks.selectRelevantInsights(
    [
      {
        created_at: "2026-06-01T00:00:00.000Z",
        category: null,
        title: "Metric match",
        body: "Body",
        reasoning: null,
        confidence: null,
        related_metrics: [" hydration_ml "],
      },
      {
        created_at: "2026-06-02T00:00:00.000Z",
        category: "general",
        title: "Category match",
        body: "Body",
        reasoning: null,
        confidence: 0.2,
        related_metrics: null,
      },
    ] as never,
    hooks.parseScenarioSignals("hydration stress", "general") as never,
  );
  assertEquals(selected.map((insight) => insight.title), [
    "Category match",
    "Metric match",
  ]);

  assertEquals(
    hooks.isHeavyLoad(stressedAlcoholRecord as never, nullBaseline as never),
    true,
  );
  assertEquals(
    hooks.isLowHydration(stressedAlcoholRecord as never, nullBaseline as never),
    true,
  );
  const lowSignalRecord = makePredictiveRecord("2026-06-04", {
    phys: {
      ...makePredictiveRecord("2026-06-04").phys,
      allostatic_load: 1,
    },
    nutrition: {
      ...makePredictiveRecord("2026-06-04").nutrition,
      alcohol_units: 0,
      caffeine_mg_after_14: 0,
    },
    wellness: {
      ...makePredictiveRecord("2026-06-04").wellness,
      stress_level: 1,
    },
  });
  const lowSignalScore = hooks.scoreHistoricalRecord(
    lowSignalRecord as never,
    hooks.parseScenarioSignals("stress alcohol caffeine", "general"),
    nullBaseline as never,
  );
  assertEquals(
    lowSignalScore.reasons.some((reason) =>
      ["stress", "alcohol", "late_caffeine"].includes(reason.key)
    ),
    false,
  );
  assertEquals(hooks.standardDeviation([1, 3]), 1);
});

Deno.test("true last mile daily insight orchestration sums food and workout rows before persistence", async () => {
  const service = createMockSupabaseService((state: MockQueryState) => {
    if (state.table === "users" && state.action === "select") {
      return {
        data: {
          timezone: "UTC",
          baseline_sleep_hours: 7,
        },
        error: null,
      };
    }
    if (state.table === "physiological_states" && state.action === "select") {
      return {
        data: [
          {
            date: "2026-06-01",
            recovery_score: 60,
            recovery_zone: "ready",
            sleep_duration_hours: 7,
            allostatic_load: 3,
            confidence_score: 0.82,
          },
          {
            date: "2026-05-31",
            recovery_score: 72,
            recovery_zone: "ready",
            sleep_duration_hours: 7.5,
            allostatic_load: 2,
            confidence_score: 0.8,
          },
        ],
        error: null,
      };
    }
    if (state.table === "nutrition_targets" && state.action === "select") {
      return {
        data: { final_calories: 2_200, final_protein_g: 120 },
        error: null,
      };
    }
    if (state.table === "food_logs" && state.action === "select") {
      return {
        data: [
          { calories: 500, protein_g: 20 },
          { calories: 400, protein_g: null },
        ],
        error: null,
      };
    }
    if (state.table === "workout_sessions" && state.action === "select") {
      return {
        data: [
          { trimp_score: 80, duration_minutes: 50 },
          { trimp_score: null, duration_minutes: 20 },
        ],
        error: null,
      };
    }
    if (state.table === "insights" && state.action === "select") {
      return { data: [], error: null };
    }
    if (state.table === "recommendations" && state.action === "select") {
      return { data: [], error: null };
    }
    if (state.action === "upsert") {
      return { data: state.payload, error: null };
    }
    if (state.action === "update") {
      return { data: [], error: null };
    }
    return { data: [], error: null };
  });

  const snapshot = await generateAndPersistDailyInsights({
    service: service as never,
    userId: "user-1",
    timezone: "UTC",
    date: "2026-06-01",
  });

  assert(snapshot.insights.some((row) => row.category === "training"));
  assert(
    snapshot.recommendations.some((row) =>
      row.action_parameters?.max_trimp === "80"
    ),
  );
  assert(
    service.__calls.some((call) =>
      call.table === "recommendations" && call.action === "upsert"
    ),
  );
});

Deno.test("true last mile daily snapshots cover allostatic rest and no-recovery nutrition guidance", async () => {
  const hooks = __dailyInsightsTestHooks;
  const allostaticSnapshot = await hooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T12:00:00.000Z",
    localHour: 10,
    baselineSleepHours: 7,
    recoveryRows: [{
      date: "2026-06-01",
      recovery_score: 62,
      recovery_zone: null,
      sleep_duration_hours: 7,
      allostatic_load: 5,
      confidence_score: null,
    }],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 0,
    totalTrimp: 10,
  } as never);
  assertEquals(
    allostaticSnapshot.insights.find((row) => row.category === "recovery")
      ?.confidence,
    0.86,
  );
  assert(
    allostaticSnapshot.recommendations.some((row) =>
      row.action_type === "rest" &&
      row.action_parameters?.max_trimp === "20"
    ),
  );

  const proteinSnapshot = await hooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-02",
    generatedAt: "2026-06-02T18:00:00.000Z",
    localHour: 18,
    baselineSleepHours: null,
    recoveryRows: [],
    nutritionTarget: { final_calories: 2_000, final_protein_g: 120 },
    totalProtein: 80,
    mealCount: 2,
    workoutCount: 0,
    totalTrimp: 0,
  } as never);
  assert(
    proteinSnapshot.recommendations.some((row) =>
      row.action_type === "eat_protein" &&
      row.recovery_score_at_time === null &&
      row.priority === "high"
    ),
  );

  const sleepWithoutRecoveryScore = await hooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-03",
    generatedAt: "2026-06-03T08:00:00.000Z",
    localHour: 8,
    baselineSleepHours: 8,
    recoveryRows: [{
      date: "2026-06-03",
      recovery_score: null,
      recovery_zone: null,
      sleep_duration_hours: 6.5,
      allostatic_load: null,
      confidence_score: null,
    }],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 2,
    totalTrimp: 120,
  } as never);
  assert(
    sleepWithoutRecoveryScore.recommendations.some((row) =>
      row.action_type === "increase_sleep" &&
      row.recovery_score_at_time === null
    ),
  );
  assertEquals(
    sleepWithoutRecoveryScore.insights.some((row) =>
      row.category === "training"
    ),
    false,
  );
});

Deno.test("true last mile daily persistence tolerates nullable existing query payloads", async () => {
  const hooks = __dailyInsightsTestHooks;
  const insight = await hooks.makeInsight({
    userId: "user-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T00:00:00.000Z",
    kind: "setup_prompt",
    category: "general",
    title: "Setup",
    description: null,
    body: "Body",
    reasoning: null,
    confidence: 0.8,
    inputsUsed: "none",
    priority: 4,
    actionable: true,
    actionType: null,
    relatedMetrics: [],
    relatedDates: ["2026-06-01"],
    expiresAt: null,
  } as never);
  const recommendation = await hooks.makeRecommendation({
    userId: "user-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T00:00:00.000Z",
    kind: "setup_prompt",
    category: "general",
    priority: "low",
    title: "Setup",
    description: "Description",
    reasoning: "Reason",
    timeOfDay: "morning",
    insightId: insight.id,
    actionType: "setup",
    actionParameters: null,
    recoveryScoreAtTime: null,
  } as never);
  const service = createMockSupabaseService((state) => {
    if (state.action === "select") {
      return { data: null, error: null };
    }
    if (state.action === "upsert") {
      return { data: null, error: null };
    }
    if (state.action === "update") {
      return { data: null, error: null };
    }
    return { data: null, error: null };
  });

  const persisted = await hooks.persistDailySnapshot(
    service as never,
    "user-1",
    {
      date: "2026-06-01",
      generated_at: "2026-06-01T00:00:00.000Z",
      insights: [insight],
      recommendations: [recommendation],
    },
  );

  assertEquals(persisted.insights[0]?.id, insight.id);
  assertEquals(persisted.recommendations[0]?.id, recommendation.id);
});

Deno.test("true last mile supplement log validates default dependency guards and formatter fallbacks", async () => {
  __supplementLogTestHooks.reset();
  await withEnv("SUPABASE_URL", undefined, async () => {
    await withEnv("SUPABASE_ANON_KEY", undefined, async () => {
      const response = await serveSupplementLog(
        new Request("http://localhost", {
          method: "POST",
          headers: { Authorization: "Bearer user-token" },
          body: JSON.stringify({ supplement_name: "Magnesium" }),
        }),
      );
      assertEquals(response.status, 503);
      assertEquals(await response.json(), { error: "auth_unavailable" });
    });
  });

  withMockedDateTimeFormat(() => ({
    formatToParts: () => [],
    format: () => "",
  }), () => {
    assertEquals(
      __supplementLogHandlerTestHooks.formatLocalDate(
        new Date("2026-06-01T00:00:00.000Z"),
        "UTC",
      ),
      "1970-01-01",
    );
  });

  assertEquals(
    __supplementLogHandlerTestHooks.normalizeWallClockTime("07:05:09"),
    "07:05",
  );
  assertEquals(
    __supplementLogHandlerTestHooks.normalizeWallClockTime("07:05:99"),
    null,
  );
  assertEquals(
    __supplementLogHandlerTestHooks.normalizeWallClockTime("not-a-time"),
    null,
  );
});

Deno.test("true last mile settings handlers stringify non-Error fetch failures", async () => {
  const notifications = await loadEdgeModule<{
    __notificationSettingsTestHooks: {
      enforceGuardianFeatureFlag(
        service: unknown,
        row: Record<string, unknown>,
        featureFlags: Array<Record<string, unknown>>,
      ): Promise<Record<string, unknown>>;
      fetchSettingsByUserId(service: unknown, userId: string): Promise<unknown>;
      resolveFeatureFlags(service: unknown, userId: string): Promise<unknown>;
      readErrorCode(error: unknown): string | null;
    };
  }>("../api/settings/notifications/index.ts");
  const privacy = await loadEdgeModule<{
    __privacySettingsTestHooks: {
      fetchPrivacyByUserId(service: unknown, userId: string): Promise<unknown>;
      readErrorCode(error: unknown): string | null;
    };
  }>("../api/settings/privacy/index.ts");

  const brokenFetchService = createMockSupabaseService(() => {
    throw "network-down";
  });
  try {
    await notifications.__notificationSettingsTestHooks.fetchSettingsByUserId(
      brokenFetchService as never,
      "user-1",
    );
    throw new Error("expected notification settings lookup to reject");
  } catch (error) {
    assertEquals(String(error), "network-down");
  }
  try {
    await notifications.__notificationSettingsTestHooks.resolveFeatureFlags(
      {
        rpc: () => {
          throw "network-down";
        },
      } as never,
      "user-1",
    );
    throw new Error("expected feature flag lookup to reject");
  } catch (error) {
    assertEquals(String(error), "network-down");
  }
  try {
    await privacy.__privacySettingsTestHooks.fetchPrivacyByUserId(
      brokenFetchService as never,
      "user-1",
    );
    throw new Error("expected privacy settings lookup to reject");
  } catch (error) {
    assertEquals(String(error), "network-down");
  }
  assertEquals(
    notifications.__notificationSettingsTestHooks.readErrorCode({ code: 409 }),
    null,
  );
  assertEquals(
    privacy.__privacySettingsTestHooks.readErrorCode({ code: 409 }),
    null,
  );
  const defaultFlags = await notifications.__notificationSettingsTestHooks
    .resolveFeatureFlags({
      rpc: () => Promise.resolve({ data: null, error: null }),
    } as never, "user-1") as Array<{ flag_key: string; enabled: boolean }>;
  assertEquals(
    defaultFlags.some((flag) =>
      flag.flag_key === "guardian_mode_enabled" && flag.enabled === true
    ),
    true,
  );
  await assertRejects(
    () =>
      notifications.__notificationSettingsTestHooks.enforceGuardianFeatureFlag(
        {
          from: () => ({
            upsert: () => ({
              select: () => ({
                single: () =>
                  Promise.resolve({
                    data: null,
                    error: { message: "downgrade failed" },
                  }),
              }),
            }),
          }),
        } as never,
        {
          id: "settings-1",
          user_id: "user-1",
          control_level: "guardian",
          focus_control_enabled: true,
        },
        [{ flag_key: "guardian_mode_enabled", enabled: false, variant: null }],
      ),
    Error,
    "downgrade failed",
  );

  const handler = await captureEdgeHandler("../api/settings/privacy/index.ts");
  await withMockedEdgeRuntime({
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/privacy_settings") {
          throw "fetch-boom";
        }
        return undefined;
      },
    ],
  }, async () => {
    const response = await handler(
      new Request("http://localhost/api/settings/privacy", {
        headers: { Authorization: "Bearer user-token" },
      }),
    );
    const body = await response.json();
    assertEquals(response.status, 500);
    assertEquals(body.error, "privacy_settings_fetch_failed");
    assert(String(body.detail).length > 0);
  });

  await withMockedEdgeRuntime({
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/rpc/resolve_feature_flags_for_user") {
          throw "flags-boom";
        }
        return undefined;
      },
    ],
  }, async () => {
    const notificationHandler = await captureEdgeHandler(
      "../api/settings/notifications/index.ts",
    );
    const response = await notificationHandler(
      new Request("http://localhost/api/settings/notifications", {
        headers: { Authorization: "Bearer user-token" },
      }),
    );
    const body = await response.json();
    assertEquals(response.status, 500);
    assertEquals(body.error, "feature_flags_resolve_failed");
    assert(String(body.detail).length > 0);
  });
});

Deno.test("true last mile privacy side effects respect unchanged cloud backup state", async () => {
  const privacy = await loadEdgeModule<{
    __privacySettingsTestHooks: {
      applyPrivacySideEffects(
        service: unknown,
        userId: string,
        authUserId: string,
        settings: {
          medical_scan_local_only: boolean | null;
          cloud_backup_enabled: boolean | null;
        },
      ): Promise<void>;
    };
  }>("../api/settings/privacy/index.ts");

  let called = false;
  const service = {
    from() {
      called = true;
      return {};
    },
  };
  await privacy.__privacySettingsTestHooks.applyPrivacySideEffects(
    service,
    "user-1",
    "auth-user",
    { medical_scan_local_only: false, cloud_backup_enabled: true },
  );
  assertEquals(called, false);

  const calls: MockQueryState[] = [];
  const cleanupService = createMockSupabaseService((state) => {
    calls.push(state);
    if (state.table === "medical_scans" && state.action === "select") {
      return { data: [], error: null };
    }
    if (state.action === "delete" || state.action === "update") {
      return { data: [], error: null };
    }
    return { data: [], error: null };
  });
  await privacy.__privacySettingsTestHooks.applyPrivacySideEffects(
    cleanupService as never,
    "user-1",
    "auth-user",
    { medical_scan_local_only: true, cloud_backup_enabled: false },
  );
  assert(
    calls.some((call) =>
      call.table === "user_health_flags" && call.action === "delete"
    ),
  );
  assert(
    calls.some((call) =>
      call.table === "medical_scans" && call.action === "update" &&
      (call.payload as Record<string, unknown>).storage_mode === "local_only"
    ),
  );

  const nullCloudBackupCalls: MockQueryState[] = [];
  const nullCloudBackupService = createMockSupabaseService((state) => {
    nullCloudBackupCalls.push(state);
    if (state.table === "medical_scans" && state.action === "select") {
      return { data: [], error: null };
    }
    if (state.action === "delete" || state.action === "update") {
      return { data: [], error: null };
    }
    return { data: [], error: null };
  });
  await privacy.__privacySettingsTestHooks.applyPrivacySideEffects(
    nullCloudBackupService as never,
    "user-1",
    "auth-user",
    { medical_scan_local_only: false, cloud_backup_enabled: null },
  );
  assert(
    nullCloudBackupCalls.some((call) =>
      call.table === "user_health_flags" && call.action === "delete"
    ),
  );
});
