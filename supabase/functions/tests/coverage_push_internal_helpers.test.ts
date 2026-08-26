import {
  assert,
  assertEquals,
  assertMatch,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { __dailyInsightsTestHooks } from "../_shared/daily_insights.ts";
import { __exportBuilderTestHooks } from "../_shared/export_builder.ts";
import { __foodsProviderTestHooks } from "../_shared/foods_provider.ts";
import { __predictiveContextTestHooks } from "../_shared/predictive_context.ts";
import {
  localDateInTimeZone,
  representativeTimestampForLocalDate,
  safeTimeZone,
  utcOffsetMinutesAt,
} from "../_shared/datetime.ts";
import {
  isUniqueViolation as isDeletionUniqueViolation,
  normalizeIdempotencyKey,
  normalizeMedicalScanStoragePath,
  retryAfterSeconds,
} from "../_shared/account_deletion.ts";
import {
  buildSupplementDayResult,
  isSupplementScheduledOnDate,
  normalizeDbTime,
  normalizedScheduledTimes,
  supplementStatus,
} from "../_shared/supplements.ts";
import {
  json,
  parseBearer,
  validateInternalServiceRoleRequest,
} from "../_shared/supabase.ts";
import {
  captureEdgeHandler,
  maybeSingleNotFoundResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";
import { createMockSupabaseService } from "./_mock_supabase_service.ts";

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

async function loadEdgeModule<T>(modulePath: string): Promise<T> {
  await captureEdgeHandler(modulePath);
  return await import(new URL(modulePath, import.meta.url).href) as T;
}

Deno.test("shared helper hooks cover deterministic normalization branches", () => {
  assertEquals(safeTimeZone("Mars/Olympus"), "UTC");
  assertEquals(safeTimeZone("Asia/Tokyo"), "Asia/Tokyo");

  const utcTs = representativeTimestampForLocalDate(
    "2026-03-08",
    "America/Los_Angeles",
  );
  assertEquals(localDateInTimeZone(utcTs, "America/Los_Angeles"), "2026-03-08");
  assert(Math.abs(utcOffsetMinutesAt(utcTs, "America/Los_Angeles")) >= 420);

  assertEquals(
    normalizeMedicalScanStoragePath(
      "https://project.supabase.co/storage/v1/object/public/medical-scans/auth-user/scan/file.jpg",
      "auth-user",
    ),
    "auth-user/scan/file.jpg",
  );
  assertEquals(
    normalizeMedicalScanStoragePath(
      "medical-scans/../scan/file.jpg",
      "auth-user",
    ),
    null,
  );
  assertEquals(normalizeIdempotencyKey("  abc-123  "), "abc-123");
  assertEquals(normalizeIdempotencyKey("   "), null);
  assertEquals(retryAfterSeconds("2999-01-01T00:00:05.000Z") > 0, true);
  assertEquals(retryAfterSeconds("not-a-date"), 0);
  assertEquals(isDeletionUniqueViolation({ code: "23505" }), true);

  const supplements = [
    {
      id: "weekly",
      catalog_id: "c1",
      custom_name: null,
      frequency: "weekly",
      scheduled_times: ["8:30:00", "8:30:00", "bad"],
      days_of_week: [1, 1, 9],
      started_at: "2026-01-01",
      ended_at: null,
      active: true,
    },
    {
      id: "custom",
      catalog_id: null,
      custom_name: "  Fish Oil ",
      frequency: "daily",
      scheduled_times: ["21:00"],
      days_of_week: [],
      started_at: "2026-01-01",
      ended_at: null,
      active: true,
    },
    {
      id: "inactive",
      catalog_id: null,
      custom_name: null,
      frequency: "as_needed",
      scheduled_times: null,
      days_of_week: null,
      started_at: "2026-01-01",
      ended_at: null,
      active: false,
    },
  ];
  const logs = [
    {
      id: "log-1",
      user_supplement_id: "weekly",
      supplement_name: "Vitamin D",
      scheduled_time: "08:30:00",
      taken_at: "2026-06-01T08:31:00.000Z",
      taken_date: "2026-06-01",
    },
    {
      id: "log-2",
      user_supplement_id: null,
      supplement_name: "Fish Oil",
      scheduled_time: null,
      taken_at: "2026-06-01T10:00:00.000Z",
      taken_date: "2026-06-01",
    },
  ];
  const result = buildSupplementDayResult(
    "2026-06-01",
    supplements as never,
    logs as never,
    new Map([["c1", "Vitamin D"]]),
  );
  assertEquals(normalizedScheduledTimes(supplements[0] as never), ["08:30"]);
  assertEquals(normalizeDbTime("7:05:30"), "07:05");
  assertEquals(normalizeDbTime("72:05"), null);
  assertEquals(
    isSupplementScheduledOnDate(supplements[2] as never, "2026-06-01"),
    false,
  );
  assertEquals(result.scheduled_count, 2);
  assertEquals(result.taken_count, 1);
  assertEquals(result.unscheduled_logs[0].name, "Fish Oil");
  assertEquals(supplementStatus(0, 0), "no_data");
  assertEquals(supplementStatus(1, 79), "incomplete");
  assertEquals(supplementStatus(1, 80), "complete");

  const authRequest = new Request("http://localhost", {
    headers: { Authorization: "Token abc", apikey: "edge-key" },
  });
  assertEquals(parseBearer(authRequest), "");
  assertEquals(json({ ok: true }).headers.get("Cache-Control"), "no-store");
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "", () => {
    assertEquals(
      validateInternalServiceRoleRequest(new Request("http://localhost")),
      {
        ok: false,
        status: 500,
        error: "internal_auth_misconfigured",
      },
    );
  });
});

Deno.test("export and foods provider helper hooks cover fallback and error branches", async () => {
  const {
    buildDownloadURL,
    collectIds,
    exportFailureReason,
    fetchAllByIds,
    fetchAllPaged,
    fetchCountByUserId,
    fetchMaybeSingle,
    isExpired,
    isMissingRelationError,
    isoDateStamp,
    redactSensitiveFields,
  } = __exportBuilderTestHooks;
  assertEquals(
    buildDownloadURL("https://lifeos.app", "job-1", "token-1"),
    "https://lifeos.app/functions/v1/api-user-export-download?export_id=job-1&token=token-1",
  );
  assertEquals(isExpired("not-a-date"), true);
  assertEquals(isoDateStamp(new Date("2026-06-01T12:00:00.000Z")), "20260601");
  assertEquals(exportFailureReason(new Error("x".repeat(600))).length, 512);
  assertEquals(exportFailureReason("plain failure"), "plain failure");
  assertEquals(
    isMissingRelationError({ code: "42P01", message: "missing" }),
    true,
  );
  assertEquals(
    isMissingRelationError({ code: "200", message: "does not exist" }),
    true,
  );
  assertEquals(
    redactSensitiveFields({
      gps_latitude: 10,
      nested: [{ image_url: "https://secret" }, { keep: true }],
      text: "ok",
    }),
    {
      gps_latitude: "[REDACTED]",
      nested: [{ image_url: "[REDACTED]" }, { keep: true }],
      text: "ok",
    },
  );
  assertEquals(collectIds([{ id: "a" }, { id: 42 }, { id: "b" }]), ["a", "b"]);

  const exportService = createMockSupabaseService((state) => {
    if (state.table === "sample" && state.terminal === "maybeSingle") {
      return { data: { id: "single" }, error: null };
    }
    if (state.table === "rows" && state.terminal === "maybeSingle") {
      return {
        data: null,
        error: { code: "42P01", message: "relation does not exist" },
      };
    }
    if (state.table === "paged" && state.terminal === "then") {
      const from = state.range?.from ?? 0;
      const rows = from === 0
        ? Array.from({ length: 1000 }, (_, index) => ({ id: `a-${index}` }))
        : [{ id: "tail" }];
      return { data: rows, error: null };
    }
    if (state.table === "counted" && state.terminal === "then") {
      return { count: 7, data: null, error: null };
    }
    if (state.table === "chunked" && state.terminal === "then") {
      const ids = (state.filters.find((filter) =>
        filter.column === "id"
      )?.value ??
        []) as string[];
      return {
        data: ids.map((id) => ({ id })),
        error: null,
      };
    }
    throw new Error(`Unexpected export query ${JSON.stringify(state)}`);
  });
  assertEquals(
    await fetchMaybeSingle(exportService as never, "sample", "id", "single"),
    { id: "single" },
  );
  assertEquals(
    await fetchMaybeSingle(exportService as never, "rows", "id", "missing"),
    null,
  );
  assertEquals(
    (await fetchAllPaged(exportService as never, "paged", (query) => query))
      .length,
    1001,
  );
  assertEquals(
    await fetchCountByUserId(exportService as never, "counted", "user-1"),
    7,
  );
  assertEquals(
    (await fetchAllByIds(
      exportService as never,
      "chunked",
      "id",
      Array.from({ length: 205 }, (_, index) => `id-${index}`),
    )).length,
    205,
  );

  const missingRelationService = createMockSupabaseService((state) => {
    if (state.table === "missing_count" && state.terminal === "then") {
      return {
        count: null,
        data: null,
        error: { code: "42P01", message: "missing relation" },
      };
    }
    if (state.table === "missing_rows" && state.terminal === "then") {
      return {
        data: null,
        error: { code: "42P01", message: "missing relation" },
      };
    }
    throw new Error(
      `Unexpected missing relation query ${JSON.stringify(state)}`,
    );
  });
  assertEquals(
    await fetchCountByUserId(
      missingRelationService as never,
      "missing_count",
      "user-1",
    ),
    0,
  );
  assertEquals(
    await fetchAllPaged(
      missingRelationService as never,
      "missing_rows",
      (query) => query,
    ),
    [],
  );

  const hardFailureService = createMockSupabaseService((state) => {
    if (state.table === "hard_single" && state.terminal === "maybeSingle") {
      return { data: null, error: new Error("db down") };
    }
    if (state.table === "hard_count" && state.terminal === "then") {
      return { count: null, data: null, error: new Error("db down") };
    }
    if (state.table === "hard_rows" && state.terminal === "then") {
      return { data: null, error: new Error("db down") };
    }
    throw new Error(`Unexpected hard failure query ${JSON.stringify(state)}`);
  });
  await assertRejects(
    () =>
      fetchMaybeSingle(hardFailureService as never, "hard_single", "id", "x"),
    Error,
    "db down",
  );
  await assertRejects(
    () =>
      fetchCountByUserId(hardFailureService as never, "hard_count", "user-1"),
    Error,
    "db down",
  );
  await assertRejects(
    () =>
      fetchAllPaged(hardFailureService as never, "hard_rows", (query) => query),
    Error,
    "db down",
  );

  const foods = __foodsProviderTestHooks;
  assertEquals(
    foods.ensureTrailingSlash("https://lifeos.app/api"),
    "https://lifeos.app/api/",
  );
  assertEquals(
    foods.ensureTrailingSlash("https://lifeos.app/api/"),
    "https://lifeos.app/api/",
  );
  assertEquals(foods.normalizeLocale(" ru-RU,ru "), "ru_RU");
  assertEquals(foods.normalizeLocale(" ,ru "), null);
  assertEquals(foods.localeLanguage("pt-BR"), "pt");
  assertEquals(foods.localeLanguage("_RU"), null);
  assertEquals(foods.normalizeBrand(" Brand, Extra "), "Brand");
  assertEquals(foods.normalizeBrand(" , Extra "), null);
  assertEquals(foods.parseServingSizeGrams("125 g"), 125);
  assertEquals(foods.parseServingSizeGrams("0 g"), null);
  assertEquals(foods.parseServingSizeGrams("1 cup"), null);
  assertEquals(foods.readNumber({ value: "12,5" }, "value"), 12.5);
  assertEquals(foods.readNumber({ value: "not-a-number" }, "value"), null);
  assertEquals(
    foods.readCaloriesKcal(
      { "energy-kj": 418.4 },
      "missing",
      "energy-kj",
      "energy",
    ),
    100,
  );
  assertEquals(
    foods.readSodiumMgPer100g({ salt_100g: 1 }, "sodium_100g", "salt_100g"),
    393,
  );
  assertEquals(foods.calorieMismatch(200, 100), true);
  assertEquals(foods.scaleNumber(2, 5), 10);
  assertEquals(foods.scaleOptionalNumber(null, 5), null);
  assertEquals(foods.readPositiveIntegerEnv("MISSING_POSITIVE", 12), 12);

  withEnv("OPEN_FOOD_FACTS_SEARCH_ENABLED", "off", () => {
    assertEquals(foods.readPositiveIntegerEnv("MISSING_POSITIVE", 9), 9);
  });

  const headers = foods.buildProviderHeaders("LifeOS", "ru_RU");
  assertEquals((headers as Record<string, string>)["Accept-Language"], "ru-RU");
  assertEquals(
    (foods.buildProviderHeaders("LifeOS", null) as Record<string, string>)[
      "Accept-Language"
    ],
    undefined,
  );

  const normalized = foods.normalizeOpenFoodFactsProduct(
    {
      code: "12345",
      product_name_ru: "Творог",
      brands: "Brand, Other",
      serving_size: "30 g",
      nutrition_data_per: "100g",
      nutriments: {
        proteins: 18,
        fat: 5,
        carbohydrates: 4,
        fiber: 0,
        sugars: 3,
        salt: 0.5,
        "energy-kcal": 133,
      },
      image_front_small_url: "https://img",
      lang: "ru",
    },
    null,
    new Date("2026-06-01T00:00:00.000Z"),
    "ru-RU",
  );
  assertEquals(normalized.ok, true);
  if (normalized.ok) {
    assertEquals(normalized.value.name, "Творог");
    assertEquals(normalized.value.locale, "ru");
    assertEquals((normalized.value.source_confidence ?? 0) > 0.6, true);
  }
  assertEquals(
    foods.normalizeOpenFoodFactsProduct(
      { code: "x", product_name: "Name" },
      null,
      new Date(),
      "en",
    ).ok,
    false,
  );
  const abbreviatedFallback = foods.normalizeOpenFoodFactsProduct(
    {
      abbreviated_product_name: "Short name",
      nutriments: {
        "energy-kcal_100g": 50,
        proteins_100g: 1,
        fat_100g: 2,
        carbohydrates_100g: 3,
      },
    },
    "fallback-code",
    new Date("2026-06-01T00:00:00.000Z"),
    null,
  );
  assertEquals(abbreviatedFallback.ok, true);
  if (abbreviatedFallback.ok) {
    assertEquals(abbreviatedFallback.value.barcode, "fallback-code");
    assertEquals(abbreviatedFallback.value.name, "Short name");
  }

  const distinct = foods.distinctByResultKey();
  assertEquals(distinct({ type: "custom", id: "1" } as never), true);
  assertEquals(distinct({ type: "custom", id: "1" } as never), false);
  assertEquals(foods.isCacheFresh(null, new Date()), false);
  assertEquals(foods.isCacheFresh("not-a-date", new Date()), false);
  assertEquals(foods.toErrorMessage(new Error("  ")), "unknown provider error");
  assertEquals(foods.firstNonEmptyString(null, "  ok "), "ok");
});

Deno.test("predictive and daily insight helper hooks cover fallback branches", async () => {
  const predictive = __predictiveContextTestHooks;
  const sleepSignals = predictive.parseScenarioSignals(
    "If I sleep 9 hours after a late night strength cardio workout, drink alcohol, travel, get sick, and skip water",
    "sleep",
  );
  assertEquals(sleepSignals.mentionsLongSleep, true);
  assertEquals(sleepSignals.mentionsLateNight, true);
  assertEquals(sleepSignals.mentionsStrength, true);
  assertEquals(sleepSignals.mentionsCardio, true);
  assertEquals(sleepSignals.mentionsAlcohol, true);
  assertEquals(sleepSignals.mentionsTravel, true);
  assertEquals(sleepSignals.mentionsIllness, true);
  assertEquals(sleepSignals.mentionsLowHydration, true);
  assertEquals(
    predictive.extractNumberUnits("run 90 min and 2.5 hours", ["min", "hours"]),
    [90, 2.5],
  );
  assertEquals(predictive.containsAny("hello world", ["world"]), true);
  assertEquals(predictive.containsAny("hello world", ["zzz"]), false);
  assertEquals(predictive.zoneFromScore(20), "critical");
  assertEquals(predictive.zoneFromScore(40), "caution");
  assertEquals(predictive.zoneFromScore(65), "ready");
  assertEquals(predictive.zoneFromScore(90), "optimal");
  assertEquals(predictive.signedPercent(7), "+7%");
  assertEquals(predictive.signedPercent(0), "0%");
  assertEquals(predictive.formatPercent(null), "n/a");
  assertEquals(predictive.formatDecimal(1.2300, 2), "1.23");
  assertEquals(predictive.standardDeviation([1, 1, 1]), 0);
  assertEquals(predictive.average([1, null, 3]), 2);
  assertEquals(predictive.firstFinite([null, undefined, 4]), 4);
  assertEquals(predictive.clampInt(99, 0, 10), 10);
  assertEquals(predictive.clampPercent(1.5), 1.5);
  assertEquals(predictive.clampUnit(-4), 0);
  assertEquals(predictive.trimmed("  hi "), "hi");
  assertEquals(predictive.truncate("abcdef", 4), "abc…");
  assertEquals(predictive.section("TITLE", []), "");

  const workoutAggregate = predictive.aggregateWorkoutsByDate([
    {
      session_date: "2026-06-01",
      started_at: "2026-06-01T21:00:00.000Z",
      started_utc_offset_minutes: 0,
      duration_minutes: 45,
      trimp_score: 50,
      workout_type: "strength",
    },
    {
      session_date: "2026-06-01",
      started_at: "invalid",
      started_utc_offset_minutes: 0,
      duration_minutes: 30,
      trimp_score: 20,
      workout_type: null,
    },
  ] as never);
  assertEquals(workoutAggregate.get("2026-06-01")?.workoutCount, 2);
  assertEquals(workoutAggregate.get("2026-06-01")?.lateWorkoutCount, 1);
  assertEquals(predictive.firstWorkoutDurationMinutes([2], []), 120);
  assertEquals(predictive.firstWorkoutDurationMinutes([], []), null);
  assertEquals(predictive.relativeToTarget(80, 100, null), 0.8);

  const records = predictive.buildHistoricalDayRecords({
    scenarioType: "general",
    scenarioText: "",
    userProfile: null,
    physiologicalStates: [{
      date: "2026-06-02",
      recovery_score: 40,
      recovery_zone: null,
      sleep_duration_hours: 5.5,
      sleep_quality_percent: 70,
      hrv_ms: 44,
      resting_heart_rate_bpm: 61,
      wrist_temperature_deviation_c: 0.4,
      allostatic_load: 7,
      steps: 5000,
      data_completeness: 0.8,
      confidence_score: 0.7,
    }],
    trainingLoads: [{
      date: "2026-06-01",
      daily_trimp: 180,
      daily_duration_minutes: 90,
      workout_count: 1,
      acwr: 1.3,
      training_zone: "overreaching",
    }],
    nutritionSummaries: [{
      date: "2026-06-01",
      total_calories: 3000,
      total_protein: 100,
      total_carbs: 350,
      total_fat: 110,
      alcohol_units: 2,
      caffeine_mg_total: 250,
      caffeine_mg_after_14: 150,
      meal_count: 4,
    }],
    nutritionTargets: [{
      date: "2026-06-01",
      final_calories: 2200,
      final_protein_g: 140,
      final_carbs_g: 260,
      final_fat_g: 80,
    }],
    hydrationLogs: [{ logged_date: "2026-06-01", water_ml: 700 }],
    wellnessChecks: [{
      date: "2026-06-01",
      energy_level: 2,
      stress_level: 5,
      muscle_soreness: 3,
      feeling_ill: true,
      wellness_score: 35,
    }],
    workoutSessions: [{
      session_date: "2026-06-01",
      started_at: "2026-06-01T21:00:00.000Z",
      started_utc_offset_minutes: 0,
      duration_minutes: 90,
      trimp_score: 180,
      workout_type: "cardio",
    }],
    insights: [],
  } as never);
  const baselines = predictive.deriveBaselines(records, {
    baseline_sleep_hours: null,
    baseline_hrv_ms: null,
    baseline_rhr_bpm: null,
    primary_goal: "maintain",
    activity_level: "moderate",
  });
  assertEquals(baselines.recovery, 40);
  assertEquals(predictive.isHeavyLoad(records[0], baselines), true);
  assertEquals(predictive.isLowHydration(records[0], baselines), true);
  const score = predictive.scoreHistoricalRecord(
    records[0],
    sleepSignals,
    baselines,
  );
  assertEquals(score.reasons.length > 0, true);
  const estimate = predictive.buildDerivedEstimate([score], baselines, records);
  assertEquals(estimate.predictedZone, "caution");
  assertEquals(
    predictive.buildBaselineLines(
      baselines,
      { primary_goal: "maintain", activity_level: "moderate" } as never,
    ).length > 0,
    true,
  );
  assertEquals(
    predictive.buildCurrentStateLines(records, null, estimate).length > 0,
    true,
  );
  assertEquals(
    predictive.buildRagMatchLines([score], baselines, sleepSignals).length > 0,
    true,
  );
  assertEquals(
    predictive.formatInsightLine({
      created_at: "2026-06-01T00:00:00.000Z",
      category: "sleep",
      title: "Sleep note",
      body: "",
      reasoning: null,
      confidence: null,
      related_metrics: null,
      correlation_coefficient: null,
      lag_days: null,
    }),
    "- Sleep note (conf n/a): ",
  );

  const daily = __dailyInsightsTestHooks;
  assertEquals(daily.clampConfidence(-1), 0.67);
  assertEquals(daily.clampConfidence(2), 0.95);
  assertEquals(daily.recommendationPriorityRank("critical"), 0);
  assertEquals(daily.recommendationPriorityRank("unknown"), 3);
  assertEquals(daily.recommendationTimeOfDay(5), "morning");
  assertEquals(daily.recommendationTimeOfDay(12), "midday");
  assertEquals(daily.recommendationTimeOfDay(17), "afternoon");
  assertEquals(daily.recommendationTimeOfDay(23), "night");
  assertEquals(daily.humanize("recovery_ready"), "Recovery ready");
  assertEquals(daily.humanize("   "), "   ");
  assertEquals(daily.average([10, 20]), 15);
  assertEquals(daily.isFiniteNumber(NaN), false);
  assertEquals(daily.formatHours(7.25), "7.3");
  assertEquals(daily.addDays("2026-06-01", 2), "2026-06-03");
  assertEquals(
    daily.addDaysISO("2026-06-01T00:00:00.000Z", 1),
    "2026-06-02T00:00:00.000Z",
  );
  assertMatch(await daily.stableUuid("seed"), /^[0-9a-f-]{36}$/);

  const highRecoverySnapshot = await daily.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-01",
    generatedAt: "2026-06-01T10:00:00.000Z",
    localHour: 11,
    baselineSleepHours: 8,
    recoveryRows: [
      {
        date: "2026-05-30",
        recovery_score: 70,
        recovery_zone: "ready",
        sleep_duration_hours: 7.8,
        allostatic_load: 2,
        confidence_score: 0.8,
      },
      {
        date: "2026-06-01",
        recovery_score: 80,
        recovery_zone: "optimal",
        sleep_duration_hours: 8.1,
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
  assertEquals(
    highRecoverySnapshot.insights[0].title,
    "Recovery is supporting a steady day",
  );
  assertEquals(
    highRecoverySnapshot.recommendations[0].title,
    "Keep today's plan steady",
  );
});

Deno.test("edge-module private hooks cover parser and AI request guardrail branches", async () => {
  const parseFoodText = await loadEdgeModule<
    typeof import("../parse-food-text/index.ts")
  >(
    "../parse-food-text/index.ts",
  );
  const parseHooks = parseFoodText.__parseFoodTextTestHooks;
  assertEquals(parseHooks.normalizedText(42), null);
  assertEquals(parseHooks.normalizedText("  hello   world "), "hello world");
  assertEquals(parseHooks.normalizeLocale(" en-US "), "en-US");
  assertEquals(parseHooks.normalizeMealType("Dinner"), "dinner");
  assertEquals(parseHooks.normalizeMealType("brunch"), null);
  assertEquals(parseHooks.cleanFoodName("!!!"), null);
  assertEquals(
    parseHooks.cleanFoodName("one two three four five six seven"),
    "one two three four five six",
  );
  assertEquals(parseHooks.unitToGrams(2, "egg"), 100);
  assertEquals(parseHooks.inferCountWeight(1, "coffee"), 250);
  assertEquals(parseHooks.inferCountWeight(1, "banana"), 120);
  assertEquals(parseHooks.inferCountWeight(1, "apple"), 180);
  assertEquals(parseHooks.inferredCountUnit("toast"), "piece");
  assertEquals(parseHooks.inferredCountUnit("yogurt"), "serving");
  assertEquals(parseHooks.inferMealType("Breakfast bowl", null), "breakfast");
  assertEquals(parseHooks.inferMealType("Big dinner", null), "dinner");
  assertEquals(parseHooks.inferMealType("Snack time", null), "snack");
  assertEquals(parseHooks.inferMealType("Late lunch", null), "lunch");
  assertEquals(parseHooks.inferMealType("Meal", "snack"), "snack");
  assertEquals(parseHooks.parseSegment("2 eggs")?.unit, "piece");
  assertEquals(parseHooks.parseSegment("100 g rice")?.weightG, 100);
  assertEquals(parseHooks.parseSegment("ate   ") ?? null, null);
  assertEquals(parseHooks.parseSegment("10 g !!!") ?? null, null);
  assertEquals(parseHooks.parseSegment("2 !!!") ?? null, null);
  assertEquals(
    parseHooks.parseSegment(`${"9".repeat(400)} eggs`)?.quantity,
    null,
  );
  assertEquals(parseHooks.parseSegment("for breakfast")?.name, "for breakfast");
  assertEquals(
    parseHooks.splitIntoSegments("eggs and toast + coffee").length,
    3,
  );
  assertEquals(
    parseHooks.clarificationOptions({ name: "salad", unit: null } as never)[0],
    "1 cup",
  );
  assertEquals(parseHooks.questionId("Greek Yogurt", 2), "greek_yogurt_2");
  assertEquals(parseHooks.questionId("!!!", 0), "item_0");
  assertEquals(
    parseHooks.buildSuggestions(
      [{ name: "egg", quantityLabel: null }, {
        name: "toast",
        quantityLabel: "2",
      }] as never,
      ["banana"],
    ),
    [
      "Confirm the serving size for egg.",
      "Review the nutrition match for banana.",
    ],
  );
  assertEquals(
    parseHooks.buildClarifyingQuestions(
      [{ name: "egg", quantityLabel: null, unit: "piece" }] as never,
      [{ calories: 10 }] as never,
    )[0].options[0],
    "1 piece",
  );
  assertEquals(
    parseHooks.buildClarifyingQuestions(
      [{ name: "egg", quantityLabel: null, unit: "piece" }] as never,
      [{ calories: 10 }] as never,
    )[0].item_index,
    0,
  );
  assertEquals(
    parseHooks.buildClarifyingQuestions(
      [{ name: "egg", quantityLabel: null, unit: "piece" }] as never,
      [{ calories: 10 }] as never,
    )[0].item_name,
    "egg",
  );
  assertEquals(
    parseHooks.buildClarifyingQuestions(
      [
        { name: "egg", quantityLabel: null, unit: "piece" },
        { name: "salad", quantityLabel: "1", unit: null },
        { name: "toast", quantityLabel: null, unit: "piece" },
      ] as never,
      [{ calories: 10 }, { calories: null }, { calories: null }] as never,
    ).length,
    2,
  );
  assertEquals(
    parseHooks.inferCategory({
      name: "Olive Oil",
      brand: null,
      macros_per_100g: {
        calories: 900,
        protein_g: 0,
        fat_g: 100,
        carbs_g: 0,
        fiber_g: null,
      },
    } as never),
    "fat",
  );
  assertEquals(
    parseHooks.inferCategory({
      name: "Banana Bowl",
      brand: null,
      macros_per_100g: {
        calories: 80,
        protein_g: 1,
        fat_g: 0,
        carbs_g: 10,
        fiber_g: null,
      },
    } as never),
    "fruit",
  );
  assertEquals(
    parseHooks.inferCategory({
      name: "Cucumber salad",
      brand: null,
      macros_per_100g: {
        calories: 15,
        protein_g: 1,
        fat_g: 0,
        carbs_g: 3,
        fiber_g: null,
      },
    } as never),
    "vegetable",
  );

  const analyzeFoodImage = await loadEdgeModule<
    typeof import("../analyze-food-image/index.ts")
  >(
    "../analyze-food-image/index.ts",
  );
  assertEquals(
    analyzeFoodImage.__analyzeFoodImageTestHooks.normalizeImageDataUrl(
      "data:image/png;base64,abc",
    ),
    "data:image/png;base64,abc",
  );
  assertEquals(
    analyzeFoodImage.__analyzeFoodImageTestHooks.normalizeImageDataUrl(
      "http://x",
    ),
    null,
  );
  assertEquals(
    analyzeFoodImage.__analyzeFoodImageTestHooks.normalizeBarcodes([
      "1",
      " 1 ",
      "2",
      "",
      5,
    ]),
    ["1", "2"],
  );
  assertEquals(
    analyzeFoodImage.__analyzeFoodImageTestHooks.extractMessageContent({
      choices: [{ message: { content: [{ text: "a" }, null, { text: "b" }] } }],
    }),
    "a\nb",
  );

  const analyzeFoodLabel = await loadEdgeModule<
    typeof import("../analyze-food-label/index.ts")
  >(
    "../analyze-food-label/index.ts",
  );
  const labelHooks = analyzeFoodLabel.__analyzeFoodLabelTestHooks;
  assertEquals(labelHooks.normalizeBarcode(" 123 "), "123");
  assertEquals(labelHooks.normalizeBarcode(""), null);
  assertEquals(labelHooks.normalizeLocale(" ru "), "ru");
  assertEquals(labelHooks.normalizeLocale(""), null);
  assertEquals(labelHooks.asTrimmedString("  hello  ", 10), "hello");
  assertEquals(labelHooks.asTrimmedString("0123456789abc", 10), "0123456789");
  assertEquals(
    labelHooks.normalizeImageDataUrl(" data:image/png;base64,abc "),
    "data:image/png;base64,abc",
  );
  assertEquals(
    labelHooks.normalizeImageDataUrl("data:text/plain;base64,abc"),
    null,
  );
  assertEquals(labelHooks.asConfidence("x"), 0.5);
  assertEquals(labelHooks.cleanWarnings(["a", "", 1, "b"]).length, 2);
  assertEquals(labelHooks.cleanWarnings(["A", "a", "b"]), ["A", "b"]);
  assertEquals(labelHooks.localizedNarrativeLanguage("ru"), "Russian");
  assertEquals(
    labelHooks.localizedNarrativeLanguage(null),
    "the user's preferred language",
  );
  assertEquals(labelHooks.localizedNarrativeLanguage("de"), "de");
  assertEquals(
    labelHooks.normalizeFoodLabelResponse({}, "123")?.warnings[0],
    "Nutrition label output requires manual review.",
  );

  const analyzeBatch = await loadEdgeModule<
    typeof import("../analyze-batch-recipe-image/index.ts")
  >(
    "../analyze-batch-recipe-image/index.ts",
  );
  const batchHooks = analyzeBatch.__analyzeBatchRecipeImageTestHooks;
  assertEquals(
    batchHooks.normalizeImageDataUrl("data:image/jpeg;base64,abc"),
    "data:image/jpeg;base64,abc",
  );
  assertEquals(batchHooks.normalizeImageDataUrl("bad"), null);
  assertEquals(
    batchHooks.normalizeImageDataUrl("data:image/png;utf8,abc"),
    null,
  );
  assertEquals(batchHooks.cleanNarrativeList(["a", "", "b"], 2, 10), [
    "a",
    "b",
  ]);
  assertEquals(
    batchHooks.cleanNarrativeList(["Same", "same", "Third"], 5, 10),
    ["Same", "Third"],
  );
  assertEquals(batchHooks.localizedNarrativeLanguage("ru-RU"), "Russian");
  assertEquals(batchHooks.localizedNarrativeLanguage("it-IT"), "it-IT");
  assertEquals(batchHooks.derivePerUnit(200, 0, 100, 0), null);
  assertEquals(batchHooks.normalizeTotals(null).calories, null);
  assertEquals(
    batchHooks.extractMessageContent({
      choices: [{ message: { content: [null, { text: "a" }, { foo: "x" }] } }],
    }),
    "a",
  );
  assertEquals(
    batchHooks.normalizeIngredient({
      name: "Rice",
      estimated_raw_weight_g: 50,
      confidence: 2,
    })?.confidence,
    1,
  );
  assertEquals(batchHooks.normalizeIngredient({ name: "   " }), null);
  const normalizedBatch = batchHooks.normalizeBatchRecipeResponse(
    {
      per_portion: { weight_g: 0, calories: 0 },
      storage: { refrigerator_days: 3, freezer_months: 2 },
      confidence: 2,
    },
    {
      recipe_name: "Soup",
      total_weight_g: 900,
      portions_planned: 3,
      known_ingredients: [{ name: "Carrot", raw_weight_g: 100 }],
    },
  );
  assertEquals(normalizedBatch?.ingredients_detected[0].name, "Carrot");
  assertEquals(normalizedBatch?.per_portion.weight_g, 0);
  assertEquals(
    normalizedBatch?.warnings[0],
    "Batch recipe draft requires review.",
  );
  const derivedBatch = batchHooks.normalizeBatchRecipeResponse(
    {
      recipe_name: "  ",
      total_batch: {
        calories: 600,
        protein_g: 30,
        fat_g: 15,
        carbs_g: 90,
      },
      notes: [],
      warnings: [],
      storage: { reheating_tip: "  Warm slowly  " },
      confidence: "bad",
    },
    {
      recipe_name: "Stew",
      total_weight_g: 900,
      portions_planned: 3,
      known_ingredients: [{ name: "  ", raw_weight_g: -1 }],
    },
  );
  assertEquals(derivedBatch?.recipe_name, "Stew");
  assertEquals(
    derivedBatch?.ingredients_detected[0]?.name,
    "Unknown ingredient",
  );
  assertEquals(derivedBatch?.per_100g.calories, 67);
  assertEquals(derivedBatch?.per_portion.weight_g, 300);
  assertEquals(derivedBatch?.storage.reheating_tip, "Warm slowly");
  assertEquals(derivedBatch?.confidence, 0.5);

  const openRouter = await loadEdgeModule<
    typeof import("../ai/openrouter-gateway/index.ts")
  >(
    "../ai/openrouter-gateway/index.ts",
  );
  const sanitizeMessages =
    openRouter.__openRouterGatewayTestHooks.sanitizeMessages;
  // Client-supplied system role is rejected: the gateway is client-facing
  // only and must not act as a generic LLM proxy.
  assertEquals(sanitizeMessages([{ role: "system", content: " ok " }]), null);
  assertEquals(sanitizeMessages([{ role: "invalid", content: "x" }]), null);
  assertEquals(sanitizeMessages([{ role: "user", content: [{ text: "x" }] }]), [
    { role: "user", content: [{ text: "x" }] },
  ]);
  assertEquals(sanitizeMessages([{ role: "user", content: "" }]), null);
  assertEquals(
    sanitizeMessages([{
      role: "user",
      content: [{ text: "x".repeat(100_001) }],
    }]),
    null,
  );
  assertEquals(
    openRouter.__openRouterGatewayTestHooks.isJSONObject({ a: 1 }),
    true,
  );
  assertEquals(openRouter.__openRouterGatewayTestHooks.isJSONObject([]), false);
});

Deno.test("edge runtime harness and mocked runtime cover responder branches", async () => {
  const cachedA = await captureEdgeHandler("../api/settings/privacy/index.ts");
  const cachedB = await captureEdgeHandler("../api/settings/privacy/index.ts");
  assertEquals(cachedA, cachedB);

  await withMockedEdgeRuntime({
    env: { CUSTOM_EDGE_ENV: null },
    authResponse: () => maybeSingleNotFoundResponse(),
    userLookupResponse: () => maybeSingleNotFoundResponse(),
    rateLimitResponse: () =>
      new Response(JSON.stringify([{
        ok: false,
        retry_after_seconds: 4,
        remaining: 0,
        reset_epoch_seconds: Math.floor(Date.now() / 1000) + 4,
      }])),
    responders: [
      (request) => {
        if (request.url.endsWith("/custom")) {
          return new Response(JSON.stringify({ ok: true }), { status: 201 });
        }
      },
    ],
  }, async (calls) => {
    const userRes = await fetch("http://localhost/auth/v1/user", {
      headers: { Authorization: "Bearer x" },
    });
    assertEquals(userRes.status, 406);
    const publicUserRes = await fetch("http://localhost/rest/v1/users");
    assertEquals(publicUserRes.status, 406);
    const rateLimitRes = await fetch(
      "http://localhost/rest/v1/rpc/check_rate_limit_bucket",
      {
        method: "POST",
        body: JSON.stringify({ test: true }),
      },
    );
    assertEquals(rateLimitRes.status, 200);
    const customRes = await fetch("http://localhost/custom", {
      method: "POST",
    });
    assertEquals(customRes.status, 201);
    assertEquals(calls.authHeaders, ["Bearer x"]);
    assertEquals(calls.userLookupUrls.length, 1);
    assertEquals(calls.rateLimitBodies[0].test, true);
    assertEquals(Deno.env.get("CUSTOM_EDGE_ENV"), undefined);
  });
});
