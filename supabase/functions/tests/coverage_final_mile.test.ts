import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  __dailyInsightsTestHooks,
  type GeneratedInsightRow,
  type GeneratedRecommendationRow,
} from "../_shared/daily_insights.ts";
import {
  localDateInTimeZone,
  representativeTimestampForLocalDate,
  safeTimeZone,
  utcOffsetMinutesAt,
} from "../_shared/datetime.ts";
import {
  __foodsProviderTestHooks,
  defaultFoodsProvider,
  FoodsError,
} from "../_shared/foods_provider.ts";
import { __predictiveContextTestHooks } from "../_shared/predictive_context.ts";
import {
  buildSupplementDayResult,
  isSupplementScheduledOnDate,
  normalizeDbTime,
} from "../_shared/supplements.ts";
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

async function loadEdgeModule<T>(modulePath: string): Promise<T> {
  await captureEdgeHandler(modulePath);
  return await import(new URL(modulePath, import.meta.url).href) as T;
}

function makeRecord(
  outcomeDate: string,
  overrides: Record<string, unknown> = {},
) {
  return {
    outcomeDate,
    phys: {
      date: outcomeDate,
      recovery_score: 72,
      recovery_zone: null,
      sleep_duration_hours: 9,
      sleep_quality_percent: 80,
      hrv_ms: 56,
      resting_heart_rate_bpm: 50,
      wrist_temperature_deviation_c: 0,
      allostatic_load: 6,
      steps: 8_000,
      data_completeness: 0.8,
      confidence_score: 0.7,
    },
    training: null,
    nutrition: {
      date: outcomeDate,
      total_calories: 2200,
      total_protein: 160,
      total_carbs: 250,
      total_fat: 70,
      alcohol_units: 1,
      caffeine_mg_total: 180,
      caffeine_mg_after_14: 90,
      meal_count: 3,
    },
    target: {
      date: outcomeDate,
      final_calories: 2200,
      final_protein_g: 150,
      final_carbs_g: 250,
      final_fat_g: 70,
    },
    hydrationMl: 900,
    wellness: {
      date: outcomeDate,
      energy_level: 2,
      stress_level: 4,
      muscle_soreness: 2,
      feeling_ill: false,
      wellness_score: 45,
    },
    workouts: {
      workoutCount: 1,
      totalDurationMinutes: 95,
      totalTrimp: 20,
      lateWorkoutCount: 0,
      workoutTypes: ["cardio"],
    },
    ...overrides,
  };
}

Deno.test("final-mile predictive helpers preserve fallback semantics", () => {
  const hooks = __predictiveContextTestHooks;
  const baselines = {
    recovery: null,
    sleepHours: 7,
    hrvMs: null,
    rhrBpm: null,
    trimp: 200,
    hydrationMl: 2200,
    calories: 2200,
    proteinG: 150,
    carbsG: 250,
  };

  const signals = hooks.parseScenarioSignals(
    "sleep 9 hours late alcohol stress",
    "sleep",
  );
  const matches = hooks.selectHistoricalMatches(
    [
      makeRecord("2026-06-01"),
      makeRecord("2026-06-02"),
    ] as never,
    signals,
    baselines as never,
  );
  assertEquals(matches[0]?.record.outcomeDate, "2026-06-02");
  assert(
    matches[0]?.reasons.some((reason) => reason.key === "long_sleep") ?? false,
  );
  assert(
    matches[0]?.reasons.some((reason) => reason.key === "alcohol") ?? false,
  );
  assert(
    matches[0]?.reasons.some((reason) => reason.key === "stress") ?? false,
  );

  const currentState = hooks.buildCurrentStateLines(
    [makeRecord("2026-06-02")] as never,
    { primary_goal: "maintain", activity_level: "high" } as never,
    { predictedScore: 68, predictedZone: "ready" } as never,
  );
  assertStringIncludes(currentState[0], "(ready)");
  assertStringIncludes(
    currentState.join("\n"),
    "Goal / activity: maintain / high",
  );

  const baselineOnlyProfile = hooks.buildBaselineLines(
    {} as never,
    { primary_goal: "cut", activity_level: null } as never,
  );
  assertEquals(baselineOnlyProfile, ["- Goal / activity: cut / unknown"]);

  const summaryLines = hooks.buildAggregateSummaryLines(
    [
      { score: 10, record: makeRecord("2026-06-01"), reasons: [] },
      {
        score: 10,
        record: makeRecord("2026-06-02", {
          phys: { ...makeRecord("2026-06-02").phys, recovery_score: 68 },
        }),
        reasons: [],
      },
    ] as never,
    { recovery: null, sleepHours: null } as never,
    hooks.parseScenarioSignals("sleep", "general") as never,
  );
  assertStringIncludes(summaryLines[0], "Similar precedents: 2");

  const selectedInsights = hooks.selectRelevantInsights(
    [
      {
        created_at: "2026-06-01T00:00:00.000Z",
        category: " Recovery ",
        title: "Older recovery",
        body: "Body",
        reasoning: null,
        confidence: 0.7,
        related_metrics: ["other_metric"],
        correlation_coefficient: null,
        lag_days: null,
      },
      {
        created_at: "2026-06-03T00:00:00.000Z",
        category: "other",
        title: "Metric match",
        body: "Body",
        reasoning: null,
        confidence: 0.7,
        related_metrics: [" sleep_duration_hours "],
        correlation_coefficient: null,
        lag_days: null,
      },
    ] as never,
    hooks.parseScenarioSignals("sleep", "general") as never,
  );
  assertEquals(selectedInsights[0]?.title, "Metric match");

  assertEquals(
    hooks.parseScenarioSignals("workout 2 hours", "workout").mentionsHeavyLoad,
    true,
  );
  assertEquals(
    hooks.isHeavyLoad(makeRecord("2026-06-01") as never, baselines as never),
    true,
  );
  assertEquals(
    hooks.isHeavyLoad(
      makeRecord("2026-06-01", {
        workouts: {
          workoutCount: 2,
          totalDurationMinutes: 20,
          totalTrimp: 10,
          lateWorkoutCount: 0,
          workoutTypes: [],
        },
      }) as never,
      baselines as never,
    ),
    true,
  );
  assertEquals(
    hooks.isHeavyLoad(
      makeRecord("2026-06-01", {
        workouts: {
          workoutCount: 1,
          totalDurationMinutes: 10,
          totalTrimp: 10,
          lateWorkoutCount: 0,
          workoutTypes: [],
        },
        training: {
          date: "2026-06-01",
          daily_trimp: 10,
          daily_duration_minutes: 10,
          workout_count: 1,
          acwr: 1.25,
          training_zone: "high",
        },
      }) as never,
      baselines as never,
    ),
    true,
  );
  assertEquals(
    hooks.isLowHydration(
      makeRecord("2026-06-01", { hydrationMl: null }) as never,
      baselines as never,
    ),
    false,
  );

  const workouts = hooks.aggregateWorkoutsByDate([
    {
      session_date: "2026-06-01",
      started_at: "2026-06-01T17:00:00.000Z",
      started_utc_offset_minutes: 120,
      duration_minutes: 30,
      trimp_score: 15,
      workout_type: "walk",
    },
    {
      session_date: "2026-06-01",
      started_at: "2026-06-01T18:00:00.000Z",
      started_utc_offset_minutes: 0,
      duration_minutes: 45,
      trimp_score: 25,
      workout_type: "strength",
    },
  ] as never);
  assertEquals(workouts.get("2026-06-01")?.totalDurationMinutes, 75);
  assertEquals(workouts.get("2026-06-01")?.totalTrimp, 40);
  assertEquals(
    hooks.resolveLocalHour("2026-06-01T10:00:00.000Z", "x" as never),
    10,
  );
  assertEquals(
    Math.round(hooks.standardDeviation([1, 2, 3, 4]) * 1000) / 1000,
    1.118,
  );
});

Deno.test("predictive scoring explains nutrition and general lifestyle matches", () => {
  const hooks = __predictiveContextTestHooks;
  const baselines = {
    recovery: 70,
    sleepHours: 7.5,
    hrvMs: null,
    rhrBpm: null,
    trimp: 90,
    hydrationMl: 2400,
    calories: 2200,
    proteinG: 150,
    carbsG: 260,
  };

  const nutritionSignals = hooks.parseScenarioSignals(
    "protein carbs caffeine hydration skip water under-eat overeating",
    "nutrition",
  );
  const lowNutrition = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-01", {
      nutrition: {
        date: "2026-06-01",
        total_calories: 1600,
        total_protein: 90,
        total_carbs: 180,
        total_fat: 50,
        alcohol_units: 0,
        caffeine_mg_total: 200,
        caffeine_mg_after_14: 120,
        meal_count: 2,
      },
      target: {
        date: "2026-06-01",
        final_calories: 2200,
        final_protein_g: 150,
        final_carbs_g: 260,
        final_fat_g: 70,
      },
      hydrationMl: 1000,
    }) as never,
    nutritionSignals as never,
    baselines as never,
  );
  assert(
    lowNutrition.reasons.some((reason) => reason.key === "late_caffeine"),
  );
  assert(
    lowNutrition.reasons.some((reason) => reason.key === "low_hydration"),
  );
  assert(lowNutrition.reasons.some((reason) => reason.key === "protein_low"));
  assert(lowNutrition.reasons.some((reason) => reason.key === "carbs_low"));
  assert(lowNutrition.reasons.some((reason) => reason.key === "under_eating"));

  const highNutrition = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-02", {
      nutrition: {
        date: "2026-06-02",
        total_calories: 2700,
        total_protein: 160,
        total_carbs: 270,
        total_fat: 90,
        alcohol_units: 0,
        caffeine_mg_total: 0,
        caffeine_mg_after_14: 0,
        meal_count: 4,
      },
      hydrationMl: 2200,
    }) as never,
    nutritionSignals as never,
    baselines as never,
  );
  assert(highNutrition.reasons.some((reason) => reason.key === "hydration"));
  assert(highNutrition.reasons.some((reason) => reason.key === "protein_high"));
  assert(highNutrition.reasons.some((reason) => reason.key === "carbs_high"));
  assert(highNutrition.reasons.some((reason) => reason.key === "over_eating"));

  const generalSignals = hooks.parseScenarioSignals(
    "stress sleep alcohol caffeine hydration workout travel",
    "general",
  );
  const generalMatch = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-03", {
      phys: {
        ...makeRecord("2026-06-03").phys,
        sleep_duration_hours: 5.8,
      },
      nutrition: {
        ...makeRecord("2026-06-03").nutrition,
        alcohol_units: 2,
        caffeine_mg_after_14: 100,
      },
      hydrationMl: 1000,
      wellness: {
        ...makeRecord("2026-06-03").wellness,
        stress_level: 5,
      },
      workouts: {
        workoutCount: 1,
        totalDurationMinutes: 45,
        totalTrimp: 35,
        lateWorkoutCount: 1,
        workoutTypes: ["walk"],
      },
    }) as never,
    generalSignals as never,
    baselines as never,
  );
  for (
    const expected of [
      "stress",
      "sleep_shift",
      "alcohol",
      "late_caffeine",
      "low_hydration",
      "workout_presence",
      "schedule_shift",
    ]
  ) {
    assert(
      generalMatch.reasons.some((reason) => reason.key === expected),
      `expected ${expected} reason`,
    );
  }
});

Deno.test("predictive helper scoring hits exact sleep nutrition and general branches", () => {
  const hooks = __predictiveContextTestHooks;
  const baselines = {
    recovery: 65,
    sleepHours: 7,
    hrvMs: null,
    rhrBpm: null,
    trimp: null,
    hydrationMl: null,
    calories: null,
    proteinG: null,
    carbsG: null,
  };

  const shortSleepScore = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-04", {
      phys: {
        ...makeRecord("2026-06-04").phys,
        sleep_duration_hours: 6,
      },
    }) as never,
    {
      type: "sleep",
      normalizedText: "",
      sleepHoursTarget: null,
      workoutMinutesTarget: null,
      mentionsSleep: true,
      mentionsShortSleep: true,
      mentionsLongSleep: false,
      mentionsLateNight: false,
      mentionsWorkout: false,
      mentionsHeavyLoad: false,
      mentionsRestDay: false,
      mentionsCardio: false,
      mentionsStrength: false,
      mentionsAlcohol: false,
      mentionsCaffeine: false,
      mentionsHydration: false,
      mentionsLowHydration: false,
      mentionsProtein: false,
      mentionsCarbs: false,
      mentionsUnderEating: false,
      mentionsOvereating: false,
      mentionsStress: false,
      mentionsIllness: false,
      mentionsTravel: false,
    } as never,
    baselines as never,
  );
  assert(
    shortSleepScore.reasons.some((reason) => reason.key === "short_sleep"),
  );

  const longSleepScore = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-05") as never,
    {
      type: "sleep",
      normalizedText: "",
      sleepHoursTarget: null,
      workoutMinutesTarget: null,
      mentionsSleep: true,
      mentionsShortSleep: false,
      mentionsLongSleep: true,
      mentionsLateNight: false,
      mentionsWorkout: false,
      mentionsHeavyLoad: false,
      mentionsRestDay: false,
      mentionsCardio: false,
      mentionsStrength: false,
      mentionsAlcohol: true,
      mentionsCaffeine: false,
      mentionsHydration: false,
      mentionsLowHydration: false,
      mentionsProtein: false,
      mentionsCarbs: false,
      mentionsUnderEating: false,
      mentionsOvereating: false,
      mentionsStress: true,
      mentionsIllness: false,
      mentionsTravel: false,
    } as never,
    baselines as never,
  );
  assert(longSleepScore.reasons.some((reason) => reason.key === "long_sleep"));
  assert(longSleepScore.reasons.some((reason) => reason.key === "alcohol"));
  assert(longSleepScore.reasons.some((reason) => reason.key === "stress"));

  const nutritionScore = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-06") as never,
    {
      type: "nutrition",
      normalizedText: "",
      sleepHoursTarget: null,
      workoutMinutesTarget: null,
      mentionsSleep: false,
      mentionsShortSleep: false,
      mentionsLongSleep: false,
      mentionsLateNight: false,
      mentionsWorkout: false,
      mentionsHeavyLoad: false,
      mentionsRestDay: false,
      mentionsCardio: false,
      mentionsStrength: false,
      mentionsAlcohol: false,
      mentionsCaffeine: true,
      mentionsHydration: false,
      mentionsLowHydration: false,
      mentionsProtein: false,
      mentionsCarbs: false,
      mentionsUnderEating: false,
      mentionsOvereating: false,
      mentionsStress: false,
      mentionsIllness: false,
      mentionsTravel: false,
    } as never,
    baselines as never,
  );
  assert(
    nutritionScore.reasons.some((reason) => reason.key === "late_caffeine"),
  );

  const generalScore = hooks.scoreHistoricalRecord(
    makeRecord("2026-06-07", {
      phys: {
        ...makeRecord("2026-06-07").phys,
        sleep_duration_hours: 8.2,
      },
    }) as never,
    {
      type: "general",
      normalizedText: "",
      sleepHoursTarget: null,
      workoutMinutesTarget: null,
      mentionsSleep: true,
      mentionsShortSleep: false,
      mentionsLongSleep: false,
      mentionsLateNight: false,
      mentionsWorkout: false,
      mentionsHeavyLoad: false,
      mentionsRestDay: false,
      mentionsCardio: false,
      mentionsStrength: false,
      mentionsAlcohol: true,
      mentionsCaffeine: true,
      mentionsHydration: false,
      mentionsLowHydration: false,
      mentionsProtein: false,
      mentionsCarbs: false,
      mentionsUnderEating: false,
      mentionsOvereating: false,
      mentionsStress: true,
      mentionsIllness: false,
      mentionsTravel: false,
    } as never,
    baselines as never,
  );
  assert(generalScore.reasons.some((reason) => reason.key === "stress"));
  assert(generalScore.reasons.some((reason) => reason.key === "sleep_shift"));
  assert(generalScore.reasons.some((reason) => reason.key === "alcohol"));
  assert(generalScore.reasons.some((reason) => reason.key === "late_caffeine"));
});

Deno.test("daily snapshot persistence keeps generated rows when upsert echoes nothing", async () => {
  const hooks = __dailyInsightsTestHooks;
  const snapshot = await hooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-03",
    generatedAt: "2026-06-03T18:00:00.000Z",
    localHour: 18,
    baselineSleepHours: 8,
    recoveryRows: [
      {
        date: "2026-06-02",
        recovery_score: 70,
        recovery_zone: "ready",
        sleep_duration_hours: 8,
        allostatic_load: 2,
        confidence_score: 0.9,
      },
      {
        date: "2026-06-03",
        recovery_score: 42,
        recovery_zone: "caution",
        sleep_duration_hours: 6.5,
        allostatic_load: 5,
        confidence_score: 0.86,
      },
    ],
    nutritionTarget: { final_protein_g: 120 },
    totalProtein: 40,
    mealCount: 1,
    workoutCount: 1,
    totalTrimp: 90,
  } as never);

  const service = createMockSupabaseService((state: MockQueryState) => {
    if (
      state.table === "insights" &&
      state.action === "select" &&
      state.terminal === "returns"
    ) {
      const likeValue = state.filters.find((filter) =>
        filter.op === "like" && filter.column === "type"
      )?.value;
      if (likeValue === "daily/%") {
        return {
          data: [
            {
              id: "old-daily",
              type: "daily/2026-06-01/recovery_status",
              dismissed: false,
            },
            {
              id: "already-dismissed",
              type: "daily/2026-05-30/recovery_status",
              dismissed: true,
            },
          ],
          error: null,
        };
      }
      return {
        data: [
          snapshot.insights[0],
          {
            ...(snapshot.insights[0] as GeneratedInsightRow),
            id: "stale-insight",
          },
        ],
        error: null,
      };
    }

    if (
      state.table === "recommendations" &&
      state.action === "select" &&
      state.terminal === "returns"
    ) {
      return {
        data: [
          snapshot.recommendations[0],
          {
            ...(snapshot.recommendations[0] as GeneratedRecommendationRow),
            id: "stale-rec",
          },
        ],
        error: null,
      };
    }

    if (state.action === "upsert") {
      return { data: null, error: null };
    }

    if (state.action === "update") {
      return { data: null, error: null };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  const persisted = await hooks.persistDailySnapshot(
    service as never,
    "user-1",
    snapshot as never,
  );

  assertEquals(persisted.insights.length > 0, true);
  assertEquals(persisted.recommendations.length > 0, true);
  assertEquals(
    service.__calls.some((state) =>
      state.table === "insights" &&
      state.action === "update" &&
      state.filters.some((filter) => filter.column === "id")
    ),
    true,
  );
  assertEquals(
    service.__calls.some((state) =>
      state.table === "recommendations" &&
      state.action === "update" &&
      state.filters.some((filter) => filter.column === "trigger_condition")
    ),
    true,
  );
});

Deno.test("datetime and daily helper fallbacks stay deterministic", () => {
  assertEquals(safeTimeZone(null as never), "UTC");
  assertEquals(
    localDateInTimeZone(new Date("2026-06-01T12:00:00.000Z"), "UTC"),
    "2026-06-01",
  );
  assertEquals(
    utcOffsetMinutesAt(new Date("2026-06-01T12:00:00.000Z"), "UTC"),
    0,
  );
  assertEquals(
    __dailyInsightsTestHooks.recommendationPriorityRank("medium"),
    2,
  );
  assertEquals(__dailyInsightsTestHooks.recommendationTimeOfDay(18), "evening");

  const RealDateTimeFormat = Intl.DateTimeFormat;
  let formatCalls = 0;
  Object.defineProperty(Intl, "DateTimeFormat", {
    configurable: true,
    value: class {
      constructor(..._args: unknown[]) {}

      format(_date: Date) {
        formatCalls += 1;
        return formatCalls === 1 ? "ok" : "2026-05-31";
      }

      formatToParts(_date: Date) {
        return [
          { type: "year", value: "2026" },
          { type: "month", value: "06" },
          { type: "day", value: "01" },
          { type: "hour", value: "oops" },
          { type: "minute", value: "00" },
          { type: "second", value: "00" },
        ];
      }
    },
  });

  try {
    assertEquals(__dailyInsightsTestHooks.localHourInTimeZone("UTC"), 0);
    const ts = representativeTimestampForLocalDate("2026-06-01", "UTC");
    assert(ts instanceof Date);
  } finally {
    Object.defineProperty(Intl, "DateTimeFormat", {
      configurable: true,
      value: RealDateTimeFormat,
    });
  }
});

Deno.test("supplement helpers match by normalized names and preserve fallback labels", () => {
  const result = buildSupplementDayResult(
    "2026-06-01",
    [
      {
        id: "supp-1",
        catalog_id: "catalog-1",
        custom_name: null,
        frequency: "daily",
        scheduled_times: ["08:00", "bad"],
        days_of_week: [],
        started_at: "2026-01-01",
        ended_at: null,
        active: true,
      },
      {
        id: "supp-2",
        catalog_id: null,
        custom_name: " Fish Oil ",
        frequency: "daily",
        scheduled_times: ["21:00"],
        days_of_week: [],
        started_at: "2026-01-01",
        ended_at: null,
        active: true,
      },
      {
        id: "supp-3",
        catalog_id: null,
        custom_name: "Ignored",
        frequency: "daily",
        scheduled_times: ["bad"],
        days_of_week: [],
        started_at: "2026-01-01",
        ended_at: null,
        active: true,
      },
    ] as never,
    [
      {
        id: "log-1",
        user_supplement_id: null,
        supplement_name: "fish oil",
        scheduled_time: "21:00:00",
        taken_at: "2026-06-01T21:02:00.000Z",
        taken_date: "2026-06-01",
      },
      {
        id: "log-2",
        user_supplement_id: "other",
        supplement_name: "Vitamin D",
        scheduled_time: null,
        taken_at: "2026-06-01T07:00:00.000Z",
        taken_date: "2026-06-01",
      },
    ] as never,
    new Map([["catalog-1", undefined as never]]),
  );

  assertEquals(result.scheduled_count, 2);
  assertEquals(result.taken_count, 1);
  assertEquals(result.adherence_today_percent, 50);
  assertEquals(result.schedule[0]?.supplements[0]?.name, "Supplement");
  assertEquals(result.schedule[1]?.supplements[0]?.taken, true);
  assertEquals(result.unscheduled_logs[0]?.time, "07:00");
  assertEquals(
    isSupplementScheduledOnDate({
      id: "weekly",
      catalog_id: null,
      custom_name: null,
      frequency: "weekly",
      scheduled_times: ["08:00"],
      days_of_week: [0],
      started_at: "2026-01-01",
      ended_at: null,
      active: true,
    } as never, "bad-date"),
    true,
  );
  assertEquals(normalizeDbTime("xx"), null);
});

Deno.test("parse-food-text and batch helper fallbacks keep output stable", async () => {
  const parseFoodText = await loadEdgeModule<
    typeof import("../parse-food-text/index.ts")
  >("../parse-food-text/index.ts");
  const parseHooks = parseFoodText.__parseFoodTextTestHooks;

  assertEquals(parseHooks.parseSegment("1 coffee")?.weightG, 250);
  assertEquals(parseHooks.parseSegment("2 pieces toast")?.weightG, 200);
  assertEquals(parseHooks.parseSegment("1 slice cheese")?.weightG, 30);
  assertEquals(parseHooks.parseSegment("2 mystery")?.weightG, null);
  assertEquals(parseHooks.parseSegment("the of a"), null);
  assertEquals(
    parseHooks.parseSegment("meal with many many words beyond expected length")
      ?.name,
    "meal with many many words beyond",
  );
  assertEquals(parseHooks.inferCountWeight(1, "water"), null);
  assertEquals(parseHooks.inferredCountUnit("plain yogurt"), "serving");
  assertEquals(parseHooks.normalizeLocale("   "), null);
  assertEquals(parseHooks.normalizeMealType("brunch"), null);
  assertEquals(parseHooks.normalizedText("   "), null);
  assertEquals(parseHooks.inferCategory(null), null);
  assertEquals(
    parseHooks.clarificationOptions({
      name: "rice bowl",
      unit: null,
    } as never),
    ["1 cup", "2 cups", "3 cups", "I can weigh it"],
  );
  assertEquals(
    parseHooks.clarificationOptions({
      name: "latte",
      unit: null,
    } as never),
    ["200 ml", "300 ml", "400 ml", "I can measure it"],
  );
  assertEquals(parseHooks.questionId("!!!", 0), "item_0");

  const analyzeBatch = await loadEdgeModule<
    typeof import("../analyze-batch-recipe-image/index.ts")
  >("../analyze-batch-recipe-image/index.ts");
  const batchHooks = analyzeBatch.__analyzeBatchRecipeImageTestHooks;

  assertEquals(batchHooks.normalizeImageDataUrl("   "), null);
  assertStringIncludes(
    batchHooks.buildBatchUserPrompt(
      {
        recipe_name: "Stew",
        total_weight_grams: 800,
        portions_planned: 4,
        cooking_method: "braise",
        known_ingredients: [],
      },
      null,
    ),
    '"portion_size_note": "portion size derived from totals"',
  );
  assertEquals(
    batchHooks.normalizeIngredient({ name: "Beef", confidence: null })
      ?.confidence,
    0.5,
  );

  const normalized = batchHooks.normalizeBatchRecipeResponse(
    {
      ingredients_detected: [],
      total_batch: {
        weight_g: 600,
        calories: 900,
        protein_g: 30,
        fat_g: 15,
        carbs_g: 120,
      },
      per_portion: {},
      storage: null,
    },
    {
      recipe_name: "Beans",
      total_weight_g: 600,
      portions_planned: 0,
      known_ingredients: [{ name: "Beans", raw_weight_g: -5 }],
    },
  );
  assertEquals(normalized?.ingredients_detected[0]?.estimated_raw_weight_g, 0);
  assertEquals(normalized?.per_portion.weight_g, null);
  assertEquals(normalized?.per_portion.calories, null);
  assertEquals(normalized?.storage.refrigerator_days, null);
});

Deno.test("foods provider handles empty provider payloads and request-level failures", async () => {
  const hooks = __foodsProviderTestHooks;

  withEnv("TEST_FOODS_TIMEOUT", "0", () => {
    assertEquals(hooks.readPositiveIntegerEnv("TEST_FOODS_TIMEOUT", 25), 25);
  });
  withEnv("TEST_FOODS_TIMEOUT", "15", () => {
    assertEquals(hooks.readPositiveIntegerEnv("TEST_FOODS_TIMEOUT", 25), 15);
  });
  assertEquals(hooks.normalizeLocale(" ru-RU, en-US "), "ru_RU");
  assertEquals(hooks.localeLanguage("  "), null);
  assertEquals(hooks.normalizeBrand(" , Brand"), null);
  assertEquals(hooks.readString({ name: "   " }, "name"), null);
  assertEquals(hooks.readNumber({ grams: "12,5" }, "grams"), 12.5);
  assertEquals(
    hooks.toMacros({
      calories_per_100g: "50",
      protein_per_100g: "4",
      fat_per_100g: "2",
      carbs_per_100g: "9",
      fiber_per_100g: "1.5",
    } as never),
    {
      calories: 50,
      protein_g: 4,
      fat_g: 2,
      carbs_g: 9,
      fiber_g: 1.5,
    },
  );

  const headers = hooks.buildProviderHeaders(
    "LifeOS-Test",
    "ru-RU,ru;q=0.9",
  ) as Record<string, string>;
  assertEquals(headers["Accept-Language"], "ru-RU");

  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          status: 0,
          product: null,
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    assertEquals(await provider.lookupBarcode("4600000000000"), null);
  });

  await withMockFetch(() =>
    Promise.resolve(
      new Response(
        JSON.stringify({
          products: [
            null,
            {
              code: "123",
              generic_name: "Fallback Soup",
              nutriments: {
                "energy-kcal_100g": 80,
                "proteins_100g": 3,
                "fat_100g": 2,
                "carbohydrates_100g": 10,
              },
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      ),
    ), async () => {
    const provider = defaultFoodsProvider();
    const results = await provider.search("soup", 5, "en_US");
    assertEquals(results.length, 1);
    assertEquals(results[0].name, "Fallback Soup");
  });

  await withMockFetch(
    () => Promise.resolve(new Response("down", { status: 503 })),
    async () => {
      const provider = defaultFoodsProvider();
      const error = await assertRejects(
        () => provider.search("soup", 5),
        FoodsError,
      ) as FoodsError;
      assertEquals(error.code, "provider_unavailable");
      assertStringIncludes(error.message, "Open Food Facts returned 503");
    },
  );

  await withMockFetch(() =>
    Promise.resolve(
      new Response("{", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    ), async () => {
    const provider = defaultFoodsProvider();
    const error = await assertRejects(
      () => provider.lookupBarcode("4600000000000"),
      FoodsError,
    ) as FoodsError;
    assertEquals(error.code, "provider_unavailable");
  });
});

Deno.test("privacy edge handler rejects failed auth lookups", async () => {
  const handler = await captureEdgeHandler("../api/settings/privacy/index.ts");

  await withMockedEdgeRuntime({
    authUser: null,
  }, async () => {
    const response = await handler(
      new Request("http://localhost/functions/v1/api-settings-privacy", {
        method: "GET",
        headers: {
          Authorization: "Bearer expired-token",
        },
      }),
    );

    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });
  });
});
