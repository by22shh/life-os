import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { __dailyInsightsTestHooks } from "../_shared/daily_insights.ts";
import {
  localDateInTimeZone,
  representativeTimestampForLocalDate,
  utcOffsetMinutesAt,
} from "../_shared/datetime.ts";
import { __foodsProviderTestHooks } from "../_shared/foods_provider.ts";
import { __predictiveContextTestHooks } from "../_shared/predictive_context.ts";
import { captureEdgeHandler } from "./_edge_runtime_harness.ts";
import {
  createMockSupabaseService,
  type MockQueryState,
} from "./_mock_supabase_service.ts";

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
) {
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

Deno.test("datetime and daily helper branches handle formatter edge cases", () => {
  let offsetCalls = 0;
  let dateCalls = 0;

  withMockedDateTimeFormat((options) => {
    if (options?.hour === "2-digit") {
      return {
        formatToParts: () =>
          [{ type: "minute", value: "xx" }] as Intl.DateTimeFormatPart[],
      };
    }

    if (options?.hour12 === false) {
      offsetCalls += 1;
      if (offsetCalls === 1) {
        return {
          formatToParts: () => [
            { type: "year", value: "2026" },
            { type: "month", value: "06" },
            { type: "day", value: "01" },
            { type: "hour", value: "01" },
            { type: "minute", value: "00" },
            { type: "second", value: "00" },
          ],
        };
      }
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

    dateCalls += 1;
    return {
      format: () => dateCalls === 1 ? "2026-05-31" : "2026-06-01",
    };
  }, () => {
    const ts = representativeTimestampForLocalDate("2026-06-01", "UTC");
    assertEquals(ts instanceof Date, true);
    assertEquals(__dailyInsightsTestHooks.localHourInTimeZone("UTC"), 0);
  });

  assertEquals(
    localDateInTimeZone(new Date("2026-06-01T00:00:00.000Z"), "UTC"),
    "2026-06-01",
  );
  assertEquals(
    utcOffsetMinutesAt(new Date("2026-06-01T00:00:00.000Z"), "UTC"),
    0,
  );
});

Deno.test("daily insights persist branches surface failures and preserve merged state", async () => {
  const hooks = __dailyInsightsTestHooks;
  const insight = await hooks.makeInsight({
    userId: "USER-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T10:00:00.000Z",
    kind: "recovery_status",
    category: "recovery",
    title: "Title",
    description: null,
    body: "Body",
    reasoning: null,
    confidence: 0.5,
    inputsUsed: null,
    priority: 1,
    actionable: true,
    actionType: "rest",
    relatedMetrics: [],
    relatedDates: ["2026-06-01"],
    expiresAt: null,
  });
  assertEquals(insight.needs_review, true);

  const recommendation = await hooks.makeRecommendation({
    userId: "USER-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T10:00:00.000Z",
    kind: "steady_day",
    category: "recovery",
    priority: "low",
    title: "Steady",
    description: "Desc",
    reasoning: "Why",
    timeOfDay: "morning",
    insightId: null,
    actionType: null,
    actionParameters: null,
    recoveryScoreAtTime: null,
  });
  assertStringIncludes(
    recommendation.trigger_condition ?? "",
    "daily/2026-06-01/",
  );

  const mergedInsight = hooks.mergeInsight({
    ...insight,
    shown_to_user: true,
    shown_at: "2026-06-01T11:00:00.000Z",
    read: true,
    read_at: "2026-06-01T11:05:00.000Z",
    acknowledged: true,
    acknowledged_at: "2026-06-01T11:10:00.000Z",
    dismissed: true,
    dismissed_at: "2026-06-01T11:20:00.000Z",
    acted_upon: true,
    action_taken: "rest",
  }, { ...insight, title: "New" });
  assertEquals(mergedInsight.title, "New");
  assertEquals(mergedInsight.shown_to_user, true);

  const mergedRecommendation = hooks.mergeRecommendation({
    ...recommendation,
    dismissed: true,
    followed: true,
    user_feedback: "great",
  }, { ...recommendation, title: "Updated" });
  assertEquals(mergedRecommendation.title, "Updated");
  assertEquals(mergedRecommendation.dismissed, true);

  const snapshot = {
    date: "2026-06-01",
    generated_at: "2026-06-01T10:00:00.000Z",
    insights: [insight],
    recommendations: [recommendation],
  };

  const scenarios = [
    {
      label: "insights_existing_fetch_failed:x",
      resolver: (state: MockQueryState) =>
        state.table === "insights" && state.action === "select"
          ? { data: null, error: { message: "x" } }
          : { data: [], error: null },
    },
    {
      label: "recommendations_existing_fetch_failed:y",
      resolver: (state: MockQueryState) =>
        state.table === "recommendations" && state.action === "select"
          ? { data: null, error: { message: "y" } }
          : { data: [], error: null },
    },
    {
      label: "insights_upsert_failed:z",
      resolver: (state: MockQueryState) => {
        if (state.action === "select") return { data: [], error: null };
        if (state.table === "insights" && state.action === "upsert") {
          return { data: null, error: { message: "z" } };
        }
        return {
          data: state.action === "upsert" ? state.payload : null,
          error: null,
        };
      },
    },
  ] as const;

  for (const scenario of scenarios) {
    const service = createMockSupabaseService((state) =>
      scenario.resolver(state)
    );
    await assertRejects(
      () =>
        hooks.persistDailySnapshot(
          service as never,
          "user-1",
          snapshot as never,
        ),
      Error,
      scenario.label,
    );
  }

  const successfulService = createMockSupabaseService((state) => {
    if (state.action === "select") {
      if (state.table === "insights") {
        return {
          data: state.filters.some((f) =>
              f.column === "type" && f.op === "like" &&
              String(f.value).startsWith("daily/%")
            )
            ? [{ id: "old", type: "daily/2026-05-30/old", dismissed: false }]
            : [{ ...insight, id: "stale" }],
          error: null,
        };
      }
      if (state.table === "recommendations") {
        return { data: [{ ...recommendation, id: "stale-rec" }], error: null };
      }
    }
    if (state.action === "upsert") return { data: state.payload, error: null };
    if (state.action === "update") return { data: null, error: null };
    return { data: [], error: null };
  });
  const persisted = await hooks.persistDailySnapshot(
    successfulService as never,
    "user-1",
    snapshot as never,
  );
  assertEquals(persisted.insights.length, 1);
  assertEquals(persisted.recommendations.length, 1);
});

Deno.test("predictive context helper branches score scenario details across modes", () => {
  const hooks = __predictiveContextTestHooks;
  const baselines = {
    recovery: 60,
    sleepHours: 7.5,
    hrvMs: 55,
    rhrBpm: 54,
    trimp: 80,
    hydrationMl: 2200,
    calories: 2200,
    proteinG: 140,
    carbsG: 250,
  };
  const record = {
    outcomeDate: "2026-06-02",
    phys: {
      date: "2026-06-02",
      recovery_score: 48,
      recovery_zone: "caution",
      sleep_duration_hours: 5.5,
      sleep_quality_percent: 70,
      hrv_ms: 48,
      resting_heart_rate_bpm: 60,
      wrist_temperature_deviation_c: 0.1,
      allostatic_load: 7,
      steps: 6000,
      data_completeness: 0.8,
      confidence_score: 0.7,
    },
    training: {
      date: "2026-06-01",
      daily_trimp: 180,
      daily_duration_minutes: 100,
      workout_count: 1,
      acwr: 1.4,
      training_zone: "high",
    },
    nutrition: {
      date: "2026-06-01",
      total_calories: 2800,
      total_protein: 100,
      total_carbs: 180,
      total_fat: 80,
      alcohol_units: 2,
      caffeine_mg_total: 200,
      caffeine_mg_after_14: 150,
      meal_count: 3,
    },
    target: {
      date: "2026-06-01",
      final_calories: 2200,
      final_protein_g: 140,
      final_carbs_g: 260,
      final_fat_g: 70,
    },
    hydrationMl: 900,
    wellness: {
      date: "2026-06-01",
      energy_level: 2,
      stress_level: 5,
      muscle_soreness: 2,
      feeling_ill: true,
      wellness_score: 35,
    },
    workouts: {
      workoutCount: 1,
      totalDurationMinutes: 100,
      totalTrimp: 180,
      lateWorkoutCount: 1,
      workoutTypes: ["strength", "cardio"],
    },
  };

  const sleepSignals = hooks.parseScenarioSignals(
    "sleep 5 hours late coffee and alcohol",
    "sleep",
  );
  const workoutSignals = hooks.parseScenarioSignals(
    "hard workout 90 min strength cardio late",
    "workout",
  );
  const nutritionSignals = hooks.parseScenarioSignals(
    "overeat alcohol protein carbs hydrate",
    "nutrition",
  );
  const generalSignals = hooks.parseScenarioSignals(
    "travel stress sick hydrate workout",
    "general",
  );

  assertEquals(
    hooks.scoreHistoricalRecord(
      record as never,
      sleepSignals,
      baselines as never,
    ).reasons.some((r) => r.key === "short_sleep"),
    true,
  );
  const workoutScore = hooks.scoreHistoricalRecord(
    record as never,
    workoutSignals,
    baselines as never,
  );
  assertEquals(workoutScore.reasons.some((r) => r.key === "heavy_load"), true);
  assertEquals(workoutScore.reasons.some((r) => r.key === "strength"), true);
  assertEquals(workoutScore.reasons.some((r) => r.key === "cardio"), true);
  assertEquals(
    workoutScore.reasons.some((r) => r.key === "late_workout"),
    true,
  );

  const nutritionScore = hooks.scoreHistoricalRecord(
    record as never,
    nutritionSignals,
    baselines as never,
  );
  assertEquals(nutritionScore.reasons.some((r) => r.key === "alcohol"), true);
  assertEquals(
    nutritionScore.reasons.some((r) => r.key === "protein_low"),
    true,
  );
  assertEquals(nutritionScore.reasons.some((r) => r.key === "carbs_low"), true);
  assertEquals(
    nutritionScore.reasons.some((r) => r.key === "over_eating"),
    true,
  );

  const generalScore = hooks.scoreHistoricalRecord(
    record as never,
    generalSignals,
    baselines as never,
  );
  assertEquals(generalScore.reasons.some((r) => r.key === "illness"), true);
  assertEquals(generalScore.reasons.some((r) => r.key === "stress"), true);
  assertEquals(
    generalScore.reasons.some((r) => r.key === "low_hydration"),
    true,
  );
  assertEquals(generalScore.reasons.some((r) => r.key === "heavy_load"), true);
  assertEquals(
    generalScore.reasons.some((r) => r.key === "schedule_shift"),
    true,
  );

  const lines = hooks.buildAggregateSummaryLines(
    [generalScore, nutritionScore, workoutScore],
    baselines as never,
    {
      ...generalSignals,
      mentionsAlcohol: true,
      mentionsCaffeine: true,
      mentionsWorkout: true,
      mentionsHydration: true,
      mentionsStress: true,
      mentionsIllness: true,
    } as never,
  );
  assertEquals(lines.length > 0, true);
  assertStringIncludes(lines.join("\n"), "average next-morning recovery");
  const stressLines = hooks.buildAggregateSummaryLines(
    [generalScore],
    baselines as never,
    {
      ...generalSignals,
      mentionsAlcohol: false,
      mentionsCaffeine: false,
      mentionsWorkout: false,
      mentionsHydration: false,
      mentionsStress: true,
      mentionsIllness: true,
    } as never,
  );
  assertStringIncludes(stressLines.join("\n"), "stress");
  assertStringIncludes(
    hooks.formatExampleLine(generalScore as never),
    "feeling ill",
  );

  const selectedInsights = hooks.selectRelevantInsights([
    {
      created_at: "2026-06-02T00:00:00.000Z",
      category: "health",
      title: "Health",
      body: "Body",
      reasoning: null,
      confidence: 0.7,
      related_metrics: ["stress_level"],
      correlation_coefficient: null,
      lag_days: null,
    },
    {
      created_at: "2026-06-03T00:00:00.000Z",
      category: "recovery",
      title: "Recovery",
      body: "Body",
      reasoning: "Reasoning",
      confidence: 0.8,
      related_metrics: ["recovery_score"],
      correlation_coefficient: 0.5,
      lag_days: 1,
    },
    {
      created_at: "2026-06-01T00:00:00.000Z",
      category: "other",
      title: "Ignored",
      body: "Body",
      reasoning: null,
      confidence: 1,
      related_metrics: ["other_metric"],
      correlation_coefficient: null,
      lag_days: null,
    },
  ] as never, generalSignals as never);
  assertEquals(selectedInsights.length, 2);
  assertEquals(selectedInsights[0].title, "Recovery");
});

Deno.test("foods provider and batch analysis helper branches cover normalization fallbacks", async () => {
  const foods = __foodsProviderTestHooks;
  const normalizedFromServing = foods.normalizeNutriments(
    {
      proteins_serving: 3,
      fat_serving: 4,
      carbohydrates_serving: 10,
      fiber_serving: 1,
      sugars_serving: 5,
      salt_serving: 0.5,
      "energy-kcal_serving": 90,
    },
    30,
    null,
  );
  assertEquals(normalizedFromServing?.usedServingFallback, true);
  assertEquals(normalizedFromServing?.macros.protein_g, 10);

  const normalizedUnsuffixed = foods.normalizeNutriments(
    {
      proteins: 10,
      fat: 5,
      carbohydrates: 20,
      fiber: 2,
      sugars: 4,
      sodium: 0.1,
      "energy-kcal": 165,
    },
    null,
    "100g",
  );
  assertEquals(normalizedUnsuffixed?.usedServingFallback, false);
  assertEquals(normalizedUnsuffixed?.correctedCalories, false);
  assertEquals(
    foods.normalizeNutriments(
      {
        proteins_100g: -1,
        fat_100g: 1,
        carbohydrates_100g: 1,
        "energy-kcal_100g": 10,
      },
      null,
      null,
    ),
    null,
  );
  assertEquals(
    foods.normalizeNutriments(
      { proteins_100g: 100, fat_100g: 100, carbohydrates_100g: 100 },
      null,
      null,
    ),
    null,
  );
  assertEquals(
    foods.normalizeOpenFoodFactsProduct(
      {
        code: "1",
        product_name: "X",
        nutriments: { proteins_100g: 1, fat_100g: 1, carbohydrates_100g: 1 },
      },
      null,
      new Date(),
      "en",
    ).ok,
    true,
  );

  const batch = await loadEdgeModule<
    typeof import("../analyze-batch-recipe-image/index.ts")
  >(
    "../analyze-batch-recipe-image/index.ts",
  );
  const hooks = batch.__analyzeBatchRecipeImageTestHooks;
  assertStringIncludes(
    hooks.buildBatchSystemPrompt(null),
    "the user's preferred language",
  );
  assertStringIncludes(
    hooks.buildBatchUserPrompt(
      {
        recipe_name: "Soup",
        total_weight_grams: 900,
        portions_planned: 3,
        cooking_method: "boil",
        known_ingredients: [],
      },
      300,
    ),
    '"portion_size_note": "user supplied portion size"',
  );
  assertEquals(hooks.asTrimmedString("  x  ", 1), "x");
  assertEquals(hooks.asTrimmedString("  xx  ", 1), "x");
  assertEquals(hooks.normalizeNumber("bad", 0, 1, 0), null);
  assertEquals(
    hooks.extractMessageContent({
      choices: [{ message: { content: "hello" } }],
    }),
    "hello",
  );
});
