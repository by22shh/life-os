import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildPredictiveContext,
  type BuildPredictiveContextInput,
} from "../_shared/predictive_context.ts";

function makeInput(
  overrides: Partial<BuildPredictiveContextInput>,
): BuildPredictiveContextInput {
  return {
    scenarioType: "general",
    scenarioText: "baseline scenario",
    userProfile: {
      baseline_sleep_hours: 7.4,
      baseline_hrv_ms: 58,
      baseline_rhr_bpm: 54,
      primary_goal: "recovery",
      activity_level: "active",
    },
    physiologicalStates: [],
    trainingLoads: [],
    nutritionSummaries: [],
    nutritionTargets: [],
    hydrationLogs: [],
    wellnessChecks: [],
    workoutSessions: [],
    insights: [],
    ...overrides,
  };
}

Deno.test("predictive context builds real sleep precedents from personal history", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "sleep",
      scenarioText: "If I sleep 5.5 hours after coffee late at night",
      physiologicalStates: [
        {
          date: "2026-03-15",
          recovery_score: 72,
          recovery_zone: "ready",
          sleep_duration_hours: 7.3,
          sleep_quality_percent: 83,
          hrv_ms: 59,
          resting_heart_rate_bpm: 54,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 4.2,
          steps: 9300,
          data_completeness: 0.92,
          confidence_score: 0.86,
        },
        {
          date: "2026-03-12",
          recovery_score: 58,
          recovery_zone: "ready",
          sleep_duration_hours: 5.4,
          sleep_quality_percent: 68,
          hrv_ms: 51,
          resting_heart_rate_bpm: 59,
          wrist_temperature_deviation_c: 0.3,
          allostatic_load: 6.1,
          steps: 7600,
          data_completeness: 0.9,
          confidence_score: 0.84,
        },
        {
          date: "2026-03-08",
          recovery_score: 60,
          recovery_zone: "ready",
          sleep_duration_hours: 5.8,
          sleep_quality_percent: 70,
          hrv_ms: 52,
          resting_heart_rate_bpm: 58,
          wrist_temperature_deviation_c: 0.2,
          allostatic_load: 5.8,
          steps: 8100,
          data_completeness: 0.88,
          confidence_score: 0.8,
        },
        {
          date: "2026-03-05",
          recovery_score: 74,
          recovery_zone: "ready",
          sleep_duration_hours: 7.8,
          sleep_quality_percent: 86,
          hrv_ms: 60,
          resting_heart_rate_bpm: 53,
          wrist_temperature_deviation_c: 0.0,
          allostatic_load: 3.9,
          steps: 9800,
          data_completeness: 0.9,
          confidence_score: 0.85,
        },
      ],
      nutritionSummaries: [
        {
          date: "2026-03-11",
          total_calories: 2200,
          total_protein: 140,
          total_carbs: 210,
          total_fat: 78,
          alcohol_units: 0,
          caffeine_mg_total: 240,
          caffeine_mg_after_14: 180,
          meal_count: 3,
        },
        {
          date: "2026-03-07",
          total_calories: 2150,
          total_protein: 135,
          total_carbs: 205,
          total_fat: 74,
          alcohol_units: 0,
          caffeine_mg_total: 190,
          caffeine_mg_after_14: 140,
          meal_count: 3,
        },
      ],
      insights: [
        {
          created_at: "2026-03-14T08:00:00Z",
          category: "sleep",
          title: "Late caffeine usually hurts next-day readiness",
          body: "Your recovery tends to dip after caffeine late in the day.",
          reasoning:
            "Across recent weeks, caffeine after 14:00 aligned with shorter sleep and lower next-day recovery.",
          confidence: 0.81,
          related_metrics: ["sleep_duration_hours", "caffeine_mg"],
          correlation_coefficient: -0.42,
          lag_days: 1,
        },
      ],
    }),
  );

  assert(context.matchCount >= 2);
  assertStringIncludes(
    context.historicalContextText,
    "Matched sleep duration averaged",
  );
  assertStringIncludes(context.historicalContextText, "caffeine after 14:00");
  assertStringIncludes(
    context.historicalContextText,
    "Late caffeine usually hurts next-day readiness",
  );
  assertEquals(
    context.historicalContextText.includes(
      "Data shows past 14 days indicate sensitivity",
    ),
    false,
  );
  assert(context.derivedEstimate.predictedScore < 72);
});

Deno.test("predictive context aligns workout load from previous day to next-day recovery", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "workout",
      scenarioText: "If I do a hard leg workout tonight",
      physiologicalStates: [
        {
          date: "2026-03-14",
          recovery_score: 71,
          recovery_zone: "ready",
          sleep_duration_hours: 7.2,
          sleep_quality_percent: 81,
          hrv_ms: 57,
          resting_heart_rate_bpm: 55,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 4.4,
          steps: 8900,
          data_completeness: 0.9,
          confidence_score: 0.83,
        },
        {
          date: "2026-03-12",
          recovery_score: 54,
          recovery_zone: "ready",
          sleep_duration_hours: 6.3,
          sleep_quality_percent: 72,
          hrv_ms: 50,
          resting_heart_rate_bpm: 59,
          wrist_temperature_deviation_c: 0.2,
          allostatic_load: 6.0,
          steps: 7500,
          data_completeness: 0.91,
          confidence_score: 0.84,
        },
      ],
      trainingLoads: [
        {
          date: "2026-03-11",
          daily_trimp: 210,
          daily_duration_minutes: 95,
          workout_count: 1,
          acwr: 1.28,
          training_zone: "overreaching",
        },
        {
          date: "2026-03-14",
          daily_trimp: 240,
          daily_duration_minutes: 100,
          workout_count: 1,
          acwr: 1.34,
          training_zone: "overreaching",
        },
      ],
      workoutSessions: [
        {
          session_date: "2026-03-11",
          started_at: "2026-03-11T18:30:00Z",
          started_utc_offset_minutes: 0,
          duration_minutes: 95,
          trimp_score: 210,
          workout_type: "strength",
        },
        {
          session_date: "2026-03-14",
          started_at: "2026-03-14T18:00:00Z",
          started_utc_offset_minutes: 0,
          duration_minutes: 100,
          trimp_score: 240,
          workout_type: "strength",
        },
      ],
    }),
  );

  assertStringIncludes(
    context.historicalContextText,
    "Previous-day training load",
  );
  assertStringIncludes(
    context.historicalContextText,
    "2026-03-12 -> recovery 54%",
  );
  assertEquals(
    context.historicalContextText.includes("2026-03-14 -> recovery 71%"),
    false,
  );
});

Deno.test("predictive context uses prior-evening alcohol as nutrition precedent", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "nutrition",
      scenarioText: "If I drink wine tonight",
      physiologicalStates: [
        {
          date: "2026-03-15",
          recovery_score: 69,
          recovery_zone: "ready",
          sleep_duration_hours: 7.1,
          sleep_quality_percent: 80,
          hrv_ms: 56,
          resting_heart_rate_bpm: 55,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 4.6,
          steps: 8700,
          data_completeness: 0.89,
          confidence_score: 0.82,
        },
        {
          date: "2026-03-11",
          recovery_score: 53,
          recovery_zone: "ready",
          sleep_duration_hours: 6.0,
          sleep_quality_percent: 69,
          hrv_ms: 49,
          resting_heart_rate_bpm: 60,
          wrist_temperature_deviation_c: 0.2,
          allostatic_load: 6.3,
          steps: 7100,
          data_completeness: 0.9,
          confidence_score: 0.85,
        },
        {
          date: "2026-03-07",
          recovery_score: 55,
          recovery_zone: "ready",
          sleep_duration_hours: 6.2,
          sleep_quality_percent: 70,
          hrv_ms: 50,
          resting_heart_rate_bpm: 59,
          wrist_temperature_deviation_c: 0.2,
          allostatic_load: 6.0,
          steps: 7400,
          data_completeness: 0.88,
          confidence_score: 0.81,
        },
      ],
      nutritionSummaries: [
        {
          date: "2026-03-10",
          total_calories: 2550,
          total_protein: 118,
          total_carbs: 245,
          total_fat: 92,
          alcohol_units: 2.5,
          caffeine_mg_total: 80,
          caffeine_mg_after_14: 0,
          meal_count: 3,
        },
        {
          date: "2026-03-06",
          total_calories: 2480,
          total_protein: 120,
          total_carbs: 238,
          total_fat: 88,
          alcohol_units: 3.0,
          caffeine_mg_total: 60,
          caffeine_mg_after_14: 0,
          meal_count: 3,
        },
      ],
    }),
  );

  assert(context.matchCount >= 2);
  assertStringIncludes(
    context.historicalContextText,
    "Previous-evening alcohol",
  );
  assertStringIncludes(context.historicalContextText, "alcohol 2.5u");
  assert(context.derivedEstimate.deltaVsBaseline < 0);
  assert(context.derivedEstimate.predictedScore < 69);
});

Deno.test("predictive context falls back to baseline-only guidance when no history exists", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "general",
      scenarioText: "If I travel for work and feel stressed",
      userProfile: {
        baseline_sleep_hours: null,
        baseline_hrv_ms: null,
        baseline_rhr_bpm: null,
        primary_goal: "consistency",
        activity_level: "light",
      },
      physiologicalStates: [],
      trainingLoads: [],
      nutritionSummaries: [],
      nutritionTargets: [],
      hydrationLogs: [],
      wellnessChecks: [],
      workoutSessions: [],
      insights: [],
    }),
  );

  assertEquals(context.matchCount, 0);
  assertStringIncludes(
    context.currentStateLines[0],
    "No recent physiological history found",
  );
  assertEquals(
    context.baselineLines,
    ["- Goal / activity: consistency / light"],
  );
  assertStringIncludes(
    context.historicalContextText,
    "No close personal precedents were found",
  );
  assertStringIncludes(
    context.derivedEstimate.rationale,
    "No close personal precedents were found",
  );
  assertEquals(context.derivedEstimate.predictedScore, 65);
  assertEquals(context.derivedEstimate.predictedZone, "ready");
});

Deno.test("predictive context pulls hydration and illness precedents from mixed-language travel stress scenarios", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "general",
      scenarioText:
        "После перелета и сильного стресса вода была на нуле, я почти не пил и мог заболеть",
      userProfile: {
        baseline_sleep_hours: 7.4,
        baseline_hrv_ms: 57,
        baseline_rhr_bpm: 54,
        primary_goal: "resilience",
        activity_level: "active",
      },
      physiologicalStates: [
        {
          date: "2026-04-08",
          recovery_score: 46,
          recovery_zone: "caution",
          sleep_duration_hours: 6.2,
          sleep_quality_percent: 66,
          hrv_ms: 49,
          resting_heart_rate_bpm: 58,
          wrist_temperature_deviation_c: 0.2,
          allostatic_load: 6.4,
          steps: 6700,
          data_completeness: 0.94,
          confidence_score: 0.88,
        },
        {
          date: "2026-04-05",
          recovery_score: 49,
          recovery_zone: "caution",
          sleep_duration_hours: 6.4,
          sleep_quality_percent: 69,
          hrv_ms: 50,
          resting_heart_rate_bpm: 57,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 5.9,
          steps: 7100,
          data_completeness: 0.9,
          confidence_score: 0.84,
        },
        {
          date: "2026-04-02",
          recovery_score: 72,
          recovery_zone: "ready",
          sleep_duration_hours: 7.7,
          sleep_quality_percent: 84,
          hrv_ms: 59,
          resting_heart_rate_bpm: 53,
          wrist_temperature_deviation_c: 0.0,
          allostatic_load: 3.6,
          steps: 9700,
          data_completeness: 0.92,
          confidence_score: 0.86,
        },
      ],
      hydrationLogs: [
        { logged_date: "2026-04-07", water_ml: 450 },
        { logged_date: "2026-04-07", water_ml: 500 },
        { logged_date: "2026-04-04", water_ml: 1100 },
        { logged_date: "2026-04-01", water_ml: 2300 },
      ],
      wellnessChecks: [
        {
          date: "2026-04-07",
          energy_level: 2,
          stress_level: 5,
          muscle_soreness: 2,
          feeling_ill: true,
          wellness_score: 34,
        },
        {
          date: "2026-04-04",
          energy_level: 2,
          stress_level: 4,
          muscle_soreness: 1,
          feeling_ill: true,
          wellness_score: 38,
        },
        {
          date: "2026-04-01",
          energy_level: 4,
          stress_level: 2,
          muscle_soreness: 1,
          feeling_ill: false,
          wellness_score: 72,
        },
      ],
      workoutSessions: [
        {
          session_date: "2026-04-07",
          started_at: "2026-04-07T19:30:00Z",
          started_utc_offset_minutes: 0,
          duration_minutes: 40,
          trimp_score: 52,
          workout_type: "mixed",
        },
        {
          session_date: "2026-04-04",
          started_at: "2026-04-04T20:15:00Z",
          started_utc_offset_minutes: 0,
          duration_minutes: 30,
          trimp_score: 38,
          workout_type: "mixed",
        },
      ],
      insights: [
        {
          created_at: "2026-04-07T08:00:00Z",
          category: "health",
          title: "Travel days usually amplify strain",
          body:
            "Travel days have lined up with lower readiness more than once.",
          reasoning:
            "Flight and schedule-shift days correlate with more stress.",
          confidence: 0.92,
          related_metrics: ["stress_level", "recovery_score"],
          correlation_coefficient: -0.44,
          lag_days: 1,
        },
        {
          created_at: "2026-04-06T08:00:00Z",
          category: "training",
          title: "Irrelevant training note",
          body: "Should not show up for this scenario.",
          reasoning: null,
          confidence: 0.99,
          related_metrics: ["training_trimp"],
          correlation_coefficient: null,
          lag_days: null,
        },
        {
          created_at: "2026-04-05T08:00:00Z",
          category: "recovery",
          title: "Low hydration tends to track with recovery dips",
          body: "Hydration has been a repeatable lever on rougher days.",
          reasoning:
            "Lower hydration days were followed by more strain and lower recovery.",
          confidence: 0.88,
          related_metrics: ["hydration_ml"],
          correlation_coefficient: -0.38,
          lag_days: 1,
        },
      ],
    }),
  );

  assert(context.matchCount >= 2);
  assertStringIncludes(
    context.historicalContextText,
    "Previous-day hydration on matched days averaged",
  );
  assertStringIncludes(
    context.historicalContextText,
    "Previous-day stress on matched days averaged",
  );
  assertStringIncludes(
    context.historicalContextText,
    "matched precedents were explicitly marked as feeling ill",
  );
  assertEquals(context.relevantInsightLines.length, 2);
  assertStringIncludes(
    context.relevantInsightLines[0],
    "Travel days usually amplify strain",
  );
  assertStringIncludes(
    context.relevantInsightLines[1],
    "Low hydration tends to track with recovery dips",
  );
  assertEquals(
    context.historicalContextText.includes("Irrelevant training note"),
    false,
  );
});

Deno.test("predictive context compares rest-day and late-cardio precedents for workout scenarios", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "workout",
      scenarioText:
        "If I skip training on a rest day instead of a 45 min cardio session late at night",
      physiologicalStates: [
        {
          date: "2026-04-10",
          recovery_score: 79,
          recovery_zone: "optimal",
          sleep_duration_hours: 8.0,
          sleep_quality_percent: 87,
          hrv_ms: 61,
          resting_heart_rate_bpm: 52,
          wrist_temperature_deviation_c: 0.0,
          allostatic_load: 3.0,
          steps: 8500,
          data_completeness: 0.95,
          confidence_score: 0.9,
        },
        {
          date: "2026-04-08",
          recovery_score: 56,
          recovery_zone: "ready",
          sleep_duration_hours: 7.1,
          sleep_quality_percent: 74,
          hrv_ms: 52,
          resting_heart_rate_bpm: 57,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 5.4,
          steps: 7800,
          data_completeness: 0.9,
          confidence_score: 0.84,
        },
        {
          date: "2026-04-06",
          recovery_score: 58,
          recovery_zone: "ready",
          sleep_duration_hours: 7.0,
          sleep_quality_percent: 73,
          hrv_ms: 53,
          resting_heart_rate_bpm: 56,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 5.1,
          steps: 7600,
          data_completeness: 0.88,
          confidence_score: 0.82,
        },
      ],
      trainingLoads: [
        {
          date: "2026-04-07",
          daily_trimp: 90,
          daily_duration_minutes: 45,
          workout_count: 1,
          acwr: 0.96,
          training_zone: "maintaining",
        },
        {
          date: "2026-04-05",
          daily_trimp: 96,
          daily_duration_minutes: 50,
          workout_count: 1,
          acwr: 0.99,
          training_zone: "maintaining",
        },
      ],
      workoutSessions: [
        {
          session_date: "2026-04-07",
          started_at: "2026-04-07T19:15:00Z",
          started_utc_offset_minutes: 0,
          duration_minutes: 45,
          trimp_score: 90,
          workout_type: "cardio",
        },
        {
          session_date: "2026-04-05",
          started_at: "2026-04-05T20:10:00Z",
          started_utc_offset_minutes: 0,
          duration_minutes: 50,
          trimp_score: 96,
          workout_type: "cardio",
        },
      ],
    }),
  );

  assert(context.matchCount >= 3);
  assertStringIncludes(
    context.historicalContextText,
    "Previous-day training load on matched days averaged",
  );
  assertStringIncludes(context.historicalContextText, "cardio workout");
  assertStringIncludes(context.historicalContextText, "late workout");
  assertStringIncludes(context.historicalContextText, "rest day");
});

Deno.test("predictive context distinguishes under-eating and over-eating nutrition precedents", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "nutrition",
      scenarioText:
        "If I under-eat or overeat, skip water, miss carbs and protein, and drink coffee late",
      physiologicalStates: [
        {
          date: "2026-04-12",
          recovery_score: 51,
          recovery_zone: "ready",
          sleep_duration_hours: 6.8,
          sleep_quality_percent: 72,
          hrv_ms: 51,
          resting_heart_rate_bpm: 58,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 5.4,
          steps: 7200,
          data_completeness: 0.94,
          confidence_score: 0.88,
        },
        {
          date: "2026-04-09",
          recovery_score: 55,
          recovery_zone: "ready",
          sleep_duration_hours: 7.0,
          sleep_quality_percent: 74,
          hrv_ms: 53,
          resting_heart_rate_bpm: 57,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 5.0,
          steps: 7600,
          data_completeness: 0.9,
          confidence_score: 0.84,
        },
      ],
      nutritionSummaries: [
        {
          date: "2026-04-11",
          total_calories: 1600,
          total_protein: 95,
          total_carbs: 150,
          total_fat: 55,
          alcohol_units: 0,
          caffeine_mg_total: 260,
          caffeine_mg_after_14: 180,
          meal_count: 2,
        },
        {
          date: "2026-04-08",
          total_calories: 2900,
          total_protein: 165,
          total_carbs: 305,
          total_fat: 88,
          alcohol_units: 0,
          caffeine_mg_total: 220,
          caffeine_mg_after_14: 140,
          meal_count: 4,
        },
      ],
      nutritionTargets: [
        {
          date: "2026-04-11",
          final_calories: 2200,
          final_protein_g: 150,
          final_carbs_g: 240,
          final_fat_g: 70,
        },
        {
          date: "2026-04-08",
          final_calories: 2200,
          final_protein_g: 150,
          final_carbs_g: 240,
          final_fat_g: 70,
        },
      ],
      hydrationLogs: [
        { logged_date: "2026-04-11", water_ml: 850 },
        { logged_date: "2026-04-08", water_ml: 900 },
      ],
    }),
  );

  assert(context.matchCount >= 2);
  assertStringIncludes(
    context.historicalContextText,
    "Previous-evening caffeine after 14:00",
  );
  assertStringIncludes(
    context.historicalContextText,
    "Previous-day hydration on matched days averaged",
  );
  assertStringIncludes(context.historicalContextText, "protein below target");
  assertStringIncludes(context.historicalContextText, "protein on target");
  assertStringIncludes(context.historicalContextText, "over target calories");
  assert(context.derivedEstimate.predictedScore < 60);
});

Deno.test("predictive context derives baselines from history and uses zone fallback for long-sleep alcohol scenarios", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "sleep",
      scenarioText:
        "If I sleep 8.5 hours after wine and coffee late at night while stressed",
      userProfile: null,
      physiologicalStates: [
        {
          date: "2026-04-14",
          recovery_score: 78,
          recovery_zone: null,
          sleep_duration_hours: 9.5,
          sleep_quality_percent: 87,
          hrv_ms: 61,
          resting_heart_rate_bpm: 52,
          wrist_temperature_deviation_c: 0.0,
          allostatic_load: 6.2,
          steps: 8900,
          data_completeness: 0.96,
          confidence_score: 0.9,
        },
        {
          date: "2026-04-12",
          recovery_score: 65,
          recovery_zone: "ready",
          sleep_duration_hours: 7.6,
          sleep_quality_percent: 84,
          hrv_ms: 58,
          resting_heart_rate_bpm: 54,
          wrist_temperature_deviation_c: 0.1,
          allostatic_load: 6.0,
          steps: 8300,
          data_completeness: 0.91,
          confidence_score: 0.85,
        },
      ],
      trainingLoads: [
        {
          date: "2026-04-13",
          daily_trimp: 72,
          daily_duration_minutes: 55,
          workout_count: 1,
          acwr: 1.18,
          training_zone: "maintaining",
        },
      ],
      nutritionSummaries: [
        {
          date: "2026-04-13",
          total_calories: 2350,
          total_protein: 135,
          total_carbs: 245,
          total_fat: 82,
          alcohol_units: 2.5,
          caffeine_mg_total: 260,
          caffeine_mg_after_14: 180,
          meal_count: 3,
        },
        {
          date: "2026-04-11",
          total_calories: 2280,
          total_protein: 132,
          total_carbs: 238,
          total_fat: 79,
          alcohol_units: 2.0,
          caffeine_mg_total: 210,
          caffeine_mg_after_14: 150,
          meal_count: 3,
        },
      ],
      wellnessChecks: [
        {
          date: "2026-04-13",
          energy_level: 3,
          stress_level: 4,
          muscle_soreness: 2,
          feeling_ill: false,
          wellness_score: 58,
        },
        {
          date: "2026-04-11",
          energy_level: 3,
          stress_level: 4,
          muscle_soreness: 2,
          feeling_ill: false,
          wellness_score: 61,
        },
      ],
    }),
  );

  assertStringIncludes(context.currentStateLines[0], "(optimal)");
  assertStringIncludes(context.currentStateLines[1], "Latest sleep: 9.5h");
  assertStringIncludes(context.currentStateLines[2], "Latest ACWR: 1.18");
  assertStringIncludes(context.baselineLines.join("\n"), "Baseline HRV:");
  assertStringIncludes(
    context.historicalContextText,
    "Previous-evening alcohol on matched days averaged",
  );
  assertStringIncludes(
    context.historicalContextText,
    "Previous-evening caffeine after 14:00 on matched days averaged",
  );
  assertStringIncludes(context.historicalContextText, "long sleep");
  assertStringIncludes(context.historicalContextText, "high stress");
});

Deno.test("predictive context still ranks general precedents when the scenario text has no direct cues", () => {
  const context = buildPredictiveContext(
    makeInput({
      scenarioType: "general",
      scenarioText: "baseline check",
      userProfile: null,
      physiologicalStates: [
        {
          date: "2026-04-20",
          recovery_score: 68,
          recovery_zone: "ready",
          sleep_duration_hours: 7.4,
          sleep_quality_percent: 80,
          hrv_ms: 56,
          resting_heart_rate_bpm: 54,
          wrist_temperature_deviation_c: 0.0,
          allostatic_load: 4.2,
          steps: 9100,
          data_completeness: 0.92,
          confidence_score: 0.86,
        },
        {
          date: "2026-04-18",
          recovery_score: 66,
          recovery_zone: "ready",
          sleep_duration_hours: 7.2,
          sleep_quality_percent: 78,
          hrv_ms: 55,
          resting_heart_rate_bpm: 55,
          wrist_temperature_deviation_c: 0.0,
          allostatic_load: 4.4,
          steps: 8800,
          data_completeness: 0.9,
          confidence_score: 0.84,
        },
      ],
    }),
  );

  assert(context.matchCount >= 1);
  assertStringIncludes(
    context.historicalContextText,
    "Similar precedents: 2; average next-morning recovery 67%",
  );
  assertEquals(
    context.ragMatchLines.some((line) => line.includes("matched on")),
    false,
  );
  assertStringIncludes(
    context.derivedEstimate.rationale,
    "Based on 2 matched personal precedents",
  );
});
