import {
  assert,
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { __dailyInsightsTestHooks } from "../_shared/daily_insights.ts";
import {
  __foodsProviderTestHooks,
  lookupFoodByBarcode,
  searchFoods,
} from "../_shared/foods_provider.ts";
import { __predictiveContextTestHooks } from "../_shared/predictive_context.ts";
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

Deno.test("predictive helper gaps cover low-signal scoring and fallback summaries", () => {
  const hooks = __predictiveContextTestHooks;
  const baselines = {
    recovery: 60,
    sleepHours: 7,
    hrvMs: 55,
    rhrBpm: 52,
    trimp: 80,
    hydrationMl: 2200,
    calories: 2200,
    proteinG: 150,
    carbsG: 250,
  };
  const baseRecord = {
    outcomeDate: "2026-06-02",
    phys: {
      date: "2026-06-02",
      recovery_score: 60,
      recovery_zone: null,
      sleep_duration_hours: null,
      sleep_quality_percent: 70,
      hrv_ms: 50,
      resting_heart_rate_bpm: 56,
      wrist_temperature_deviation_c: 0,
      allostatic_load: 2,
      steps: 5000,
      data_completeness: 0,
      confidence_score: 0,
    },
    training: null,
    nutrition: null,
    target: null,
    hydrationMl: null,
    wellness: null,
    workouts: {
      workoutCount: 0,
      totalDurationMinutes: 0,
      totalTrimp: 0,
      lateWorkoutCount: 0,
      workoutTypes: [],
    },
  };

  const plainGeneral = hooks.parseScenarioSignals("plain note", "general");
  const lowSignalScore = hooks.scoreHistoricalRecord(
    baseRecord as never,
    plainGeneral,
    baselines as never,
  );
  assertEquals(lowSignalScore.reasons.length, 0);
  assertEquals(lowSignalScore.score, 0.75);

  const sleepOnlyScore = hooks.scoreHistoricalRecord(
    {
      ...baseRecord,
      phys: { ...baseRecord.phys, sleep_duration_hours: 7.1 },
    } as never,
    hooks.parseScenarioSignals("sleep", "sleep"),
    baselines as never,
  );
  assertEquals(sleepOnlyScore.reasons.length, 1);
  assertEquals(sleepOnlyScore.reasons[0]?.key, "sleep_data");
  assertEquals(sleepOnlyScore.score, 0.7);

  const nutritionScore = hooks.scoreHistoricalRecord(
    {
      ...baseRecord,
      nutrition: {
        date: "2026-06-01",
        total_calories: 1600,
        total_protein: 150,
        total_carbs: 250,
        total_fat: 60,
        alcohol_units: 0,
        caffeine_mg_total: 200,
        caffeine_mg_after_14: 120,
        meal_count: 3,
      },
      target: {
        date: "2026-06-01",
        final_calories: 2200,
        final_protein_g: 140,
        final_carbs_g: 240,
        final_fat_g: 70,
      },
      hydrationMl: 1800,
    } as never,
    hooks.parseScenarioSignals(
      "late caffeine hydration protein carbs under-eat",
      "nutrition",
    ),
    baselines as never,
  );
  assertEquals(
    nutritionScore.reasons.some((reason) => reason.key === "late_caffeine"),
    true,
  );
  assertEquals(
    nutritionScore.reasons.some((reason) => reason.key === "hydration"),
    true,
  );
  assertEquals(
    nutritionScore.reasons.some((reason) => reason.key === "protein_high"),
    true,
  );
  assertEquals(
    nutritionScore.reasons.some((reason) => reason.key === "carbs_high"),
    true,
  );
  assertEquals(
    nutritionScore.reasons.some((reason) => reason.key === "under_eating"),
    true,
  );

  const generalScore = hooks.scoreHistoricalRecord(
    {
      ...baseRecord,
      phys: { ...baseRecord.phys, sleep_duration_hours: 8.3 },
      nutrition: {
        date: "2026-06-01",
        total_calories: 2200,
        total_protein: 120,
        total_carbs: 220,
        total_fat: 70,
        alcohol_units: 1,
        caffeine_mg_total: 180,
        caffeine_mg_after_14: 90,
        meal_count: 3,
      },
      hydrationMl: 2000,
      workouts: {
        workoutCount: 1,
        totalDurationMinutes: 45,
        totalTrimp: 30,
        lateWorkoutCount: 0,
        workoutTypes: ["walk"],
      },
    } as never,
    hooks.parseScenarioSignals(
      "sleep alcohol caffeine hydration workout",
      "general",
    ),
    baselines as never,
  );
  assertEquals(
    generalScore.reasons.some((reason) => reason.key === "sleep_shift"),
    true,
  );
  assertEquals(
    generalScore.reasons.some((reason) => reason.key === "alcohol"),
    true,
  );
  assertEquals(
    generalScore.reasons.some((reason) => reason.key === "late_caffeine"),
    true,
  );
  assertEquals(
    generalScore.reasons.some((reason) => reason.key === "hydration"),
    true,
  );
  assertEquals(
    generalScore.reasons.some((reason) => reason.key === "workout_presence"),
    true,
  );

  const estimate = hooks.buildDerivedEstimate(
    [generalScore],
    baselines as never,
    [generalScore.record] as never,
  );
  assertStringIncludes(
    hooks.buildCurrentStateLines(
      [],
      { primary_goal: "maintain" } as never,
      estimate,
    )[0],
    "No recent physiological history found",
  );
  const currentState = hooks.buildCurrentStateLines(
    [generalScore.record] as never,
    { primary_goal: "build", activity_level: null } as never,
    estimate,
  );
  assertStringIncludes(
    currentState.join("\n"),
    "Goal / activity: build / unknown",
  );
  assertStringIncludes(
    hooks.buildBaselineLines({} as never, {
      primary_goal: "recover",
      activity_level: "high",
    } as never).join("\n"),
    "Goal / activity: recover / high",
  );
  assertEquals(
    hooks.buildRagMatchLines([], baselines as never, plainGeneral),
    [
      "- No close personal precedents were found in the recent cloud history.",
      "- Use baseline-only reasoning and keep confidence conservative.",
    ],
  );
  assertEquals(
    hooks.selectHistoricalMatches(
      [baseRecord] as never,
      hooks.parseScenarioSignals("sleep", "sleep"),
      baselines as never,
    ),
    [],
  );

  const longSleepStressScore = hooks.scoreHistoricalRecord(
    {
      ...baseRecord,
      phys: {
        ...baseRecord.phys,
        sleep_duration_hours: 9,
        allostatic_load: 6,
      },
      nutrition: {
        date: "2026-06-01",
        total_calories: 2200,
        total_protein: 120,
        total_carbs: 220,
        total_fat: 70,
        alcohol_units: 1,
        caffeine_mg_total: 250,
        caffeine_mg_after_14: 100,
        meal_count: 3,
      },
      wellness: {
        date: "2026-06-01",
        energy_level: 2,
        stress_level: 5,
        muscle_soreness: 2,
        feeling_ill: false,
        wellness_score: 40,
      },
    } as never,
    hooks.parseScenarioSignals(
      "sleep 9 hours late alcohol stress",
      "sleep",
    ),
    baselines as never,
  );
  assertEquals(
    longSleepStressScore.reasons.some((reason) => reason.key === "long_sleep"),
    true,
  );
  assertEquals(
    longSleepStressScore.reasons.some((reason) =>
      reason.key === "late_caffeine"
    ),
    true,
  );
  assertEquals(
    longSleepStressScore.reasons.some((reason) => reason.key === "alcohol"),
    true,
  );
  assertEquals(
    longSleepStressScore.reasons.some((reason) => reason.key === "stress"),
    true,
  );

  const restDayScore = hooks.scoreHistoricalRecord(
    baseRecord as never,
    hooks.parseScenarioSignals("rest day", "workout"),
    baselines as never,
  );
  assertEquals(
    restDayScore.reasons.some((reason) => reason.key === "rest_day"),
    true,
  );

  const explicitHeavyWorkoutScore = hooks.scoreHistoricalRecord(
    {
      ...baseRecord,
      training: {
        date: "2026-06-01",
        daily_trimp: 50,
        daily_duration_minutes: 80,
        workout_count: 2,
        acwr: 1.3,
        training_zone: "high",
      },
      workouts: {
        workoutCount: 2,
        totalDurationMinutes: 80,
        totalTrimp: 50,
        lateWorkoutCount: 0,
        workoutTypes: ["mixed"],
      },
    } as never,
    hooks.parseScenarioSignals("hard workout 90 min", "workout"),
    baselines as never,
  );
  assertEquals(
    explicitHeavyWorkoutScore.reasons.some((reason) =>
      reason.key === "duration"
    ),
    true,
  );
  assertEquals(
    explicitHeavyWorkoutScore.reasons.some((reason) =>
      reason.key === "heavy_load"
    ),
    true,
  );

  const baselineLines = hooks.buildBaselineLines(
    {
      recovery: 61,
      sleepHours: 7.2,
      hrvMs: 54,
      rhrBpm: 51,
      trimp: 83,
      hydrationMl: 2300,
    } as never,
    null,
  );
  assertStringIncludes(baselineLines.join("\n"), "Baseline HRV");
  assertStringIncludes(baselineLines.join("\n"), "Typical daily training load");
  assertStringIncludes(baselineLines.join("\n"), "Typical hydration");

  const summaryLines = hooks.buildAggregateSummaryLines(
    [{
      ...longSleepStressScore,
      record: {
        ...longSleepStressScore.record,
        phys: {
          ...longSleepStressScore.record.phys,
          recovery_score: 58,
          sleep_duration_hours: 9,
        },
      },
    }] as never,
    { recovery: null, sleepHours: null } as never,
    hooks.parseScenarioSignals("sleep 9 hours", "sleep") as never,
  );
  assertStringIncludes(
    summaryLines.join("\n"),
    "Matched sleep duration averaged 9h",
  );

  const selectedInsights = hooks.selectRelevantInsights(
    [
      {
        created_at: "2026-06-01T00:00:00.000Z",
        category: "recovery",
        title: "Older",
        body: "Body",
        reasoning: null,
        confidence: 0.8,
        related_metrics: [" recovery_score "],
        correlation_coefficient: null,
        lag_days: null,
      },
      {
        created_at: "2026-06-02T00:00:00.000Z",
        category: "other",
        title: "Metric match",
        body: "Body",
        reasoning: null,
        confidence: 0.8,
        related_metrics: [" sleep_duration_hours "],
        correlation_coefficient: null,
        lag_days: null,
      },
    ] as never,
    hooks.parseScenarioSignals(
      "travel stress sick hydrate",
      "general",
    ) as never,
  );
  assertEquals(selectedInsights[0]?.title, "Metric match");

  assertEquals(
    hooks.parseScenarioSignals("90 min workout", "workout").mentionsHeavyLoad,
    true,
  );
  assertEquals(
    hooks.isHeavyLoad({
      ...baseRecord,
      training: null,
      workouts: {
        workoutCount: 1,
        totalDurationMinutes: 95,
        totalTrimp: 0,
        lateWorkoutCount: 0,
        workoutTypes: [],
      },
    } as never, baselines as never),
    true,
  );
  assertEquals(
    hooks.aggregateHydrationByDate([
      { logged_date: "", water_ml: 100 },
      { logged_date: "2026-06-01", water_ml: null },
      { logged_date: "2026-06-01", water_ml: 250 },
    ] as never).get("2026-06-01"),
    250,
  );
  assertEquals(
    hooks.aggregateWorkoutsByDate([
      {
        session_date: "",
        started_at: null,
        started_utc_offset_minutes: null,
        duration_minutes: 10,
        trimp_score: 5,
        workout_type: "walk",
      },
    ] as never).size,
    0,
  );
  assertEquals(hooks.resolveLocalHour("bad-date", 60), null);
  assertEquals(hooks.standardDeviation([2, 4]), 1);
  assertEquals(hooks.formatDecimal(null, 1), "n/a");
});

Deno.test("daily insight helper gaps cover stacked recommendations and persistence failure branches", async () => {
  const hooks = __dailyInsightsTestHooks;
  const snapshot = await hooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T18:00:00.000Z",
    localHour: 18,
    baselineSleepHours: 8,
    recoveryRows: [
      {
        date: "2026-05-31",
        recovery_score: 55,
        recovery_zone: "ready",
        sleep_duration_hours: 7.7,
        allostatic_load: 2,
        confidence_score: 0.9,
      },
      {
        date: "2026-06-01",
        recovery_score: 20,
        recovery_zone: "critical",
        sleep_duration_hours: 6,
        allostatic_load: 5,
        confidence_score: 0.88,
      },
    ],
    nutritionTarget: {
      final_protein_g: 120,
    },
    totalProtein: 20,
    mealCount: 1,
    workoutCount: 1,
    totalTrimp: 100,
  } as never);

  assertEquals(
    snapshot.insights.some((row) =>
      row.title === "Recovery is below your recent range"
    ),
    true,
  );
  assertEquals(
    snapshot.insights.some((row) =>
      row.title === "Sleep came in below your baseline"
    ),
    true,
  );
  assertEquals(
    snapshot.insights.some((row) =>
      row.title === "Protein is trailing today's target"
    ),
    true,
  );
  assertEquals(
    snapshot.insights.some((row) =>
      row.title === "Today's load is heavy relative to readiness"
    ),
    true,
  );
  assertEquals(
    snapshot.recommendations.some((row) =>
      row.title === "Make today a restoration day"
    ),
    true,
  );
  assertEquals(
    snapshot.recommendations.some((row) =>
      row.title === "Buy back sleep tonight"
    ),
    true,
  );
  const trainingOnlySnapshot = await hooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T18:00:00.000Z",
    localHour: 18,
    baselineSleepHours: null,
    recoveryRows: [{
      date: "2026-06-01",
      recovery_score: 50,
      recovery_zone: "caution",
      sleep_duration_hours: null,
      allostatic_load: 2,
      confidence_score: 0.88,
    }],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 1,
    totalTrimp: 100,
  } as never);
  assertEquals(
    trainingOnlySnapshot.recommendations.some((row) =>
      row.title === "Cap the day here"
    ),
    true,
  );

  const errorScenarios = [
    {
      label: "recommendations_upsert_failed:rec_upsert",
      resolver: (
        state: MockQueryState,
        insightId: string,
        _recommendationId: string,
      ) => {
        if (state.action === "select") return { data: [], error: null };
        if (state.table === "insights" && state.action === "upsert") {
          return {
            data: [{ ...snapshot.insights[0], id: insightId }],
            error: null,
          };
        }
        if (state.table === "recommendations" && state.action === "upsert") {
          return { data: null, error: { message: "rec_upsert" } };
        }
        return { data: [], error: null };
      },
    },
    {
      label: "insights_stale_dismiss_failed:stale_insight",
      resolver: (
        state: MockQueryState,
        insightId: string,
        recommendationId: string,
      ) => {
        if (state.action === "select") {
          if (state.table === "insights") {
            return {
              data: [{ ...snapshot.insights[0], id: insightId }, {
                ...snapshot.insights[0],
                id: "stale-insight",
              }],
              error: null,
            };
          }
          return {
            data: [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (state.table === "insights" && state.action === "upsert") {
          return {
            data: [{ ...snapshot.insights[0], id: insightId }],
            error: null,
          };
        }
        if (state.table === "recommendations" && state.action === "upsert") {
          return {
            data: [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (state.table === "insights" && state.action === "update") {
          return { data: null, error: { message: "stale_insight" } };
        }
        return { data: [], error: null };
      },
    },
    {
      label: "insights_old_cleanup_fetch_failed:old_fetch",
      resolver: (
        state: MockQueryState,
        insightId: string,
        recommendationId: string,
      ) => {
        if (state.action === "select") {
          if (state.table === "insights") {
            const likeValue = state.filters.find((filter) =>
              filter.column === "type" && filter.op === "like"
            )
              ?.value;
            if (likeValue === "daily/%") {
              return { data: null, error: { message: "old_fetch" } };
            }
            return {
              data: [{ ...snapshot.insights[0], id: insightId }],
              error: null,
            };
          }
          return {
            data: [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (state.action === "upsert") {
          return {
            data: state.table === "insights"
              ? [{ ...snapshot.insights[0], id: insightId }]
              : [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        return { data: [], error: null };
      },
    },
    {
      label: "insights_old_cleanup_failed:old_cleanup",
      resolver: (
        state: MockQueryState,
        insightId: string,
        recommendationId: string,
      ) => {
        if (state.action === "select") {
          if (state.table === "insights") {
            const likeValue = state.filters.find((filter) =>
              filter.column === "type" && filter.op === "like"
            )
              ?.value;
            if (likeValue === "daily/%") {
              return {
                data: [{
                  id: "old-daily",
                  type: "daily/2026-05-30/recovery_status",
                  dismissed: false,
                }],
                error: null,
              };
            }
            return {
              data: [{ ...snapshot.insights[0], id: insightId }],
              error: null,
            };
          }
          return {
            data: [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (state.action === "upsert") {
          return {
            data: state.table === "insights"
              ? [{ ...snapshot.insights[0], id: insightId }]
              : [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (
          state.table === "insights" &&
          state.action === "update" &&
          state.filters.some((filter) => filter.column === "id")
        ) {
          return { data: null, error: { message: "old_cleanup" } };
        }
        return { data: null, error: null };
      },
    },
    {
      label: "recommendations_stale_dismiss_failed:stale_rec",
      resolver: (
        state: MockQueryState,
        insightId: string,
        recommendationId: string,
      ) => {
        if (state.action === "select") {
          if (state.table === "insights") {
            return {
              data: [{ ...snapshot.insights[0], id: insightId }],
              error: null,
            };
          }
          return {
            data: [
              { ...snapshot.recommendations[0], id: recommendationId },
              { ...snapshot.recommendations[0], id: "stale-rec" },
            ],
            error: null,
          };
        }
        if (state.action === "upsert") {
          return {
            data: state.table === "insights"
              ? [{ ...snapshot.insights[0], id: insightId }]
              : [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (
          state.table === "recommendations" &&
          state.action === "update" &&
          state.filters.some((filter) => filter.column === "id")
        ) {
          return { data: null, error: { message: "stale_rec" } };
        }
        return { data: null, error: null };
      },
    },
    {
      label: "recommendations_old_cleanup_failed:old_rec_cleanup",
      resolver: (
        state: MockQueryState,
        insightId: string,
        recommendationId: string,
      ) => {
        if (state.action === "select") {
          if (state.table === "insights") {
            return {
              data: [{ ...snapshot.insights[0], id: insightId }],
              error: null,
            };
          }
          return {
            data: [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (state.action === "upsert") {
          return {
            data: state.table === "insights"
              ? [{ ...snapshot.insights[0], id: insightId }]
              : [{ ...snapshot.recommendations[0], id: recommendationId }],
            error: null,
          };
        }
        if (
          state.table === "recommendations" &&
          state.action === "update" &&
          state.filters.some((filter) => filter.column === "trigger_condition")
        ) {
          return { data: null, error: { message: "old_rec_cleanup" } };
        }
        return { data: null, error: null };
      },
    },
  ] as const;

  for (const scenario of errorScenarios) {
    const service = createMockSupabaseService((state) =>
      scenario.resolver(
        state,
        snapshot.insights[0]?.id ?? "insight-1",
        snapshot.recommendations[0]?.id ?? "recommendation-1",
      )
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

  const lowRecoveryNoDelta = await hooks.buildDailySnapshot({
    userId: "user-2",
    date: "2026-06-01",
    generatedAt: "2026-06-01T09:00:00.000Z",
    localHour: 9,
    baselineSleepHours: null,
    recoveryRows: [{
      date: "2026-06-01",
      recovery_score: 40,
      recovery_zone: null,
      sleep_duration_hours: null,
      allostatic_load: 1,
      confidence_score: 0.9,
    }],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 0,
    totalTrimp: 10,
  } as never);
  assertStringIncludes(
    lowRecoveryNoDelta.insights[0]?.body ?? "",
    "better day to protect bandwidth",
  );
  assertEquals(
    lowRecoveryNoDelta.recommendations[0]?.title,
    "Keep today's load restorative",
  );

  const highRecoveryWithDelta = await hooks.buildDailySnapshot({
    userId: "user-3",
    date: "2026-06-01",
    generatedAt: "2026-06-01T09:00:00.000Z",
    localHour: 9,
    baselineSleepHours: null,
    recoveryRows: [
      {
        date: "2026-05-31",
        recovery_score: 60,
        recovery_zone: "ready",
        sleep_duration_hours: 7.5,
        allostatic_load: 2,
        confidence_score: 0.8,
      },
      {
        date: "2026-06-01",
        recovery_score: 80,
        recovery_zone: "optimal",
        sleep_duration_hours: 8,
        allostatic_load: 1,
        confidence_score: 0.9,
      },
    ],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 0,
    totalTrimp: 0,
  } as never);
  assertStringIncludes(
    highRecoveryWithDelta.insights[0]?.body ?? "",
    "above your recent range",
  );

  const proteinMorning = await hooks.buildDailySnapshot({
    userId: "user-4",
    date: "2026-06-01",
    generatedAt: "2026-06-01T10:00:00.000Z",
    localHour: 10,
    baselineSleepHours: null,
    recoveryRows: [],
    nutritionTarget: { final_protein_g: 100 },
    totalProtein: 70,
    mealCount: 0,
    workoutCount: 0,
    totalTrimp: 0,
  } as never);
  const proteinInsight = proteinMorning.insights.find((row) =>
    row.title === "Protein is trailing today's target"
  );
  assertEquals(proteinInsight?.confidence, 0.74);
  assertEquals(proteinInsight?.priority, 3);

  const proteinEvening = await hooks.buildDailySnapshot({
    userId: "user-5",
    date: "2026-06-01",
    generatedAt: "2026-06-01T18:00:00.000Z",
    localHour: 18,
    baselineSleepHours: null,
    recoveryRows: [],
    nutritionTarget: { final_protein_g: 100 },
    totalProtein: 80,
    mealCount: 2,
    workoutCount: 0,
    totalTrimp: 0,
  } as never);
  const proteinEveningInsight = proteinEvening.insights.find((row) =>
    row.title === "Protein is trailing today's target"
  );
  assertEquals(proteinEveningInsight?.priority, 2);

  const emptyPersist = await hooks.persistDailySnapshot(
    createMockSupabaseService(() => ({ data: [], error: null })) as never,
    "user-empty",
    {
      date: "2026-06-01",
      generated_at: "2026-06-01T00:00:00.000Z",
      insights: [],
      recommendations: [],
    } as never,
  );
  assertEquals(emptyPersist.insights, []);
  assertEquals(emptyPersist.recommendations, []);
});

Deno.test("foods provider gap behaviors cover generic provider failures and helper fallbacks", async () => {
  const hooks = __foodsProviderTestHooks;

  withEnv("OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS", "bad", () => {
    assertEquals(
      hooks.readPositiveIntegerEnv("OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS", 25),
      25,
    );
  });
  assertEquals(hooks.scaleNumber(null, 2), null);
  assertEquals(
    hooks.toMacros({
      calories_per_100g: "100",
      protein_per_100g: "10",
      fat_per_100g: "5",
      carbs_per_100g: "15",
      fiber_per_100g: null,
    } as never),
    {
      calories: 100,
      protein_g: 10,
      fat_g: 5,
      carbs_g: 15,
      fiber_g: null,
    },
  );
  assertEquals(
    hooks.tagsFor(
      new Set(["catalog:1"]),
      new Set(["catalog:1"]),
      "catalog",
      "1",
    ),
    ["favorite", "recent"],
  );
  assert(
    hooks.scoreFor(
      new Set(),
      new Set(),
      "catalog",
      "1",
      "Greek Yogurt",
      "Protein Co",
      "123",
      "123",
      "provider",
    ) < hooks.scoreFor(
      new Set(),
      new Set(),
      "catalog",
      "2",
      "Greek Yogurt",
      "Protein Co",
      "999",
      "greek",
      "provider",
    ),
  );
  assertEquals(hooks.normalizeLocale(""), null);
  assertEquals(hooks.localeLanguage(null), null);
  assertEquals(hooks.normalizeBrand(" , "), null);
  assertEquals(hooks.parseServingSizeGrams("0 g"), null);
  assertEquals(hooks.readString({ value: "   " }, "value"), null);
  assertEquals(hooks.readNumber({ value: "   " }, "value"), null);

  await assertRejects(
    () =>
      searchFoods({
        repository: {
          listFavoriteRefs: () => Promise.resolve([]),
          listRecentRefs: () => Promise.resolve([]),
          searchCustomFoods: () => Promise.resolve([]),
          searchCatalogFoods: () => Promise.resolve([]),
          upsertCatalogFood: () =>
            Promise.reject(new Error("search-cache-broken")),
        } as never,
        provider: {
          search: () =>
            Promise.resolve([{
              provider: "open_food_facts",
              provider_item_id: "1",
              barcode: "123",
              name: "Yogurt",
              brand: null,
              locale: "en",
              image_url: null,
              serving_size_g: 100,
              macros_per_100g: {
                calories: 100,
                protein_g: 10,
                fat_g: 5,
                carbs_g: 10,
                fiber_g: null,
              },
              sugar_per_100g: null,
              sodium_mg_per_100g: null,
              source_confidence: 0.8,
              fetched_at: "2026-06-01T00:00:00.000Z",
              expires_at: "2026-06-02T00:00:00.000Z",
            }]),
        } as never,
        userId: "user-1",
        query: "yogurt",
        limit: 5,
        providerSearchEnabled: true,
        now: new Date("2026-06-01T00:00:00.000Z"),
      }),
    Error,
    "search-cache-broken",
  );

  await assertRejects(
    () =>
      lookupFoodByBarcode({
        repository: {
          findCustomFoodByBarcode: () => Promise.resolve(null),
          findCatalogFoodByBarcode: (_provider: string) =>
            Promise.resolve(
              _provider === "open_food_facts"
                ? {
                  id: "cached-1",
                  provider: "open_food_facts",
                  barcode: "123",
                  name: "Old Cache",
                  brand: null,
                  locale: "en",
                  image_url: null,
                  serving_size_g: 100,
                  calories_per_100g: 100,
                  protein_per_100g: 10,
                  fat_per_100g: 5,
                  carbs_per_100g: 10,
                  fiber_per_100g: null,
                  fetched_at: "2026-05-01T00:00:00.000Z",
                  expires_at: "2026-05-02T00:00:00.000Z",
                }
                : null,
            ),
          upsertCatalogFood: () =>
            Promise.reject(new Error("barcode-cache-broken")),
        } as never,
        provider: {
          lookupBarcode: () =>
            Promise.resolve({
              provider: "open_food_facts",
              provider_item_id: "123",
              barcode: "123",
              name: "Fetched",
              brand: null,
              locale: "en",
              image_url: null,
              serving_size_g: 100,
              macros_per_100g: {
                calories: 100,
                protein_g: 10,
                fat_g: 5,
                carbs_g: 10,
                fiber_g: null,
              },
              sugar_per_100g: null,
              sodium_mg_per_100g: null,
              source_confidence: 0.8,
              fetched_at: "2026-06-01T00:00:00.000Z",
              expires_at: "2026-06-02T00:00:00.000Z",
            }),
        } as never,
        userId: "user-1",
        barcode: "123",
        providerBarcodeEnabled: true,
        now: new Date("2026-06-01T00:00:00.000Z"),
      }),
    Error,
    "barcode-cache-broken",
  );
});
