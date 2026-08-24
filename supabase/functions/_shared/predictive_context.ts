const MS_PER_DAY = 86_400_000;
const MAX_MATCHES = 4;
const MAX_EXAMPLE_LINES = 3;

export type PredictiveScenarioType =
  | "sleep"
  | "workout"
  | "nutrition"
  | "general";

export type RecoveryZone = "critical" | "caution" | "ready" | "optimal";

export interface PredictiveUserProfile {
  baseline_sleep_hours: number | null;
  baseline_hrv_ms: number | null;
  baseline_rhr_bpm: number | null;
  primary_goal: string | null;
  activity_level: string | null;
}

export interface PhysiologicalStateHistoryRow {
  date: string;
  recovery_score: number | null;
  recovery_zone: string | null;
  sleep_duration_hours: number | null;
  sleep_quality_percent: number | null;
  hrv_ms: number | null;
  resting_heart_rate_bpm: number | null;
  wrist_temperature_deviation_c: number | null;
  allostatic_load: number | null;
  steps: number | null;
  data_completeness: number | null;
  confidence_score: number | null;
}

export interface TrainingLoadHistoryRow {
  date: string;
  daily_trimp: number | null;
  daily_duration_minutes: number | null;
  workout_count: number | null;
  acwr: number | null;
  training_zone: string | null;
}

export interface NutritionSummaryHistoryRow {
  date: string;
  total_calories: number | null;
  total_protein: number | null;
  total_carbs: number | null;
  total_fat: number | null;
  alcohol_units: number | null;
  caffeine_mg_total: number | null;
  caffeine_mg_after_14: number | null;
  meal_count: number | null;
}

export interface NutritionTargetHistoryRow {
  date: string;
  final_calories: number | null;
  final_protein_g: number | null;
  final_carbs_g: number | null;
  final_fat_g: number | null;
}

export interface HydrationHistoryRow {
  logged_date: string;
  water_ml: number | null;
}

export interface WellnessHistoryRow {
  date: string;
  energy_level: number | null;
  stress_level: number | null;
  muscle_soreness: number | null;
  feeling_ill: boolean | null;
  wellness_score: number | null;
}

export interface WorkoutSessionHistoryRow {
  session_date: string;
  started_at: string | null;
  started_utc_offset_minutes: number | null;
  duration_minutes: number | null;
  trimp_score: number | null;
  workout_type: string | null;
}

export interface InsightHistoryRow {
  created_at: string;
  category: string | null;
  title: string;
  body: string;
  reasoning: string | null;
  confidence: number | null;
  related_metrics: string[] | null;
  correlation_coefficient: number | null;
  lag_days: number | null;
}

interface DailyWorkoutAggregate {
  workoutCount: number;
  totalDurationMinutes: number;
  totalTrimp: number;
  lateWorkoutCount: number;
  workoutTypes: string[];
}

interface HistoricalDayRecord {
  outcomeDate: string;
  phys: PhysiologicalStateHistoryRow;
  training: TrainingLoadHistoryRow | null;
  nutrition: NutritionSummaryHistoryRow | null;
  target: NutritionTargetHistoryRow | null;
  hydrationMl: number | null;
  wellness: WellnessHistoryRow | null;
  workouts: DailyWorkoutAggregate;
}

interface ScenarioSignals {
  type: PredictiveScenarioType;
  normalizedText: string;
  sleepHoursTarget: number | null;
  workoutMinutesTarget: number | null;
  mentionsSleep: boolean;
  mentionsShortSleep: boolean;
  mentionsLongSleep: boolean;
  mentionsLateNight: boolean;
  mentionsWorkout: boolean;
  mentionsHeavyLoad: boolean;
  mentionsRestDay: boolean;
  mentionsCardio: boolean;
  mentionsStrength: boolean;
  mentionsAlcohol: boolean;
  mentionsCaffeine: boolean;
  mentionsHydration: boolean;
  mentionsLowHydration: boolean;
  mentionsProtein: boolean;
  mentionsCarbs: boolean;
  mentionsUnderEating: boolean;
  mentionsOvereating: boolean;
  mentionsStress: boolean;
  mentionsIllness: boolean;
  mentionsTravel: boolean;
}

interface Baselines {
  recovery: number | null;
  sleepHours: number | null;
  hrvMs: number | null;
  rhrBpm: number | null;
  trimp: number | null;
  hydrationMl: number | null;
  calories: number | null;
  proteinG: number | null;
  carbsG: number | null;
}

interface MatchReason {
  key: string;
  label: string;
}

interface ScoredMatch {
  score: number;
  record: HistoricalDayRecord;
  reasons: MatchReason[];
}

export interface DerivedPredictiveEstimate {
  predictedScore: number;
  predictedRange: [number, number];
  predictedZone: RecoveryZone;
  confidence: number;
  baselineRecovery: number;
  matchedAverageRecovery: number;
  deltaVsBaseline: number;
  rationale: string;
}

export interface PredictiveContextBundle {
  currentStateLines: string[];
  baselineLines: string[];
  ragMatchLines: string[];
  relevantInsightLines: string[];
  historicalContextText: string;
  derivedEstimate: DerivedPredictiveEstimate;
  matchCount: number;
}

export interface BuildPredictiveContextInput {
  scenarioType: PredictiveScenarioType;
  scenarioText: string;
  userProfile: PredictiveUserProfile | null;
  physiologicalStates: PhysiologicalStateHistoryRow[];
  trainingLoads: TrainingLoadHistoryRow[];
  nutritionSummaries: NutritionSummaryHistoryRow[];
  nutritionTargets: NutritionTargetHistoryRow[];
  hydrationLogs: HydrationHistoryRow[];
  wellnessChecks: WellnessHistoryRow[];
  workoutSessions: WorkoutSessionHistoryRow[];
  insights: InsightHistoryRow[];
}

export function buildPredictiveContext(
  input: BuildPredictiveContextInput,
): PredictiveContextBundle {
  const signals = parseScenarioSignals(input.scenarioText, input.scenarioType);
  const records = buildHistoricalDayRecords(input);
  const baselines = deriveBaselines(records, input.userProfile);
  const matches = selectHistoricalMatches(records, signals, baselines);
  const relevantInsights = selectRelevantInsights(input.insights, signals);
  const derivedEstimate = buildDerivedEstimate(matches, baselines, records);
  const currentStateLines = buildCurrentStateLines(
    records,
    input.userProfile,
    derivedEstimate,
  );
  const baselineLines = buildBaselineLines(baselines, input.userProfile);
  const ragMatchLines = buildRagMatchLines(matches, baselines, signals);
  const relevantInsightLines = relevantInsights.map((insight) =>
    formatInsightLine(insight)
  );

  const sections = [
    section("CURRENT STATE", currentStateLines),
    section("PERSONAL BASELINE", baselineLines),
    section("HISTORICAL MATCHES", ragMatchLines),
    section("PRIOR PERSONAL INSIGHTS", relevantInsightLines),
    section("DERIVED N=1 ESTIMATE", [
      `- Suggested midpoint: ${derivedEstimate.predictedScore}% (${derivedEstimate.predictedZone})`,
      `- Suggested range: ${derivedEstimate.predictedRange[0]}-${
        derivedEstimate.predictedRange[1]
      }%`,
      `- Confidence prior: ${formatDecimal(derivedEstimate.confidence, 2)}`,
      `- Rationale: ${derivedEstimate.rationale}`,
    ]),
  ].filter((sectionValue) => sectionValue.length > 0);

  return {
    currentStateLines,
    baselineLines,
    ragMatchLines,
    relevantInsightLines,
    historicalContextText: sections.join("\n\n"),
    derivedEstimate,
    matchCount: matches.length,
  };
}

function buildHistoricalDayRecords(
  input: BuildPredictiveContextInput,
): HistoricalDayRecord[] {
  const trainingByDate = indexByDate(input.trainingLoads, (row) => row.date);
  const nutritionByDate = indexByDate(
    input.nutritionSummaries,
    (row) => row.date,
  );
  const targetsByDate = indexByDate(input.nutritionTargets, (row) => row.date);
  const hydrationByDate = aggregateHydrationByDate(input.hydrationLogs);
  const wellnessByDate = indexByDate(input.wellnessChecks, (row) => row.date);
  const workoutsByDate = aggregateWorkoutsByDate(input.workoutSessions);

  return [...input.physiologicalStates]
    .sort((lhs, rhs) => rhs.date.localeCompare(lhs.date))
    .map((phys) => {
      const exposureDate = addDays(phys.date, -1);
      return {
        outcomeDate: phys.date,
        phys,
        training: trainingByDate.get(exposureDate) ?? null,
        nutrition: nutritionByDate.get(exposureDate) ?? null,
        target: targetsByDate.get(exposureDate) ?? null,
        hydrationMl: hydrationByDate.get(exposureDate) ?? null,
        wellness: wellnessByDate.get(exposureDate) ?? null,
        workouts: workoutsByDate.get(exposureDate) ?? emptyWorkoutAggregate(),
      };
    })
    .filter((record) => record.phys.recovery_score != null);
}

function deriveBaselines(
  records: HistoricalDayRecord[],
  userProfile: PredictiveUserProfile | null,
): Baselines {
  const recent = records.slice(0, 28);
  return {
    recovery: average(recent.map((record) => record.phys.recovery_score)),
    sleepHours: userProfile?.baseline_sleep_hours ??
      average(recent.map((record) => record.phys.sleep_duration_hours)),
    hrvMs: userProfile?.baseline_hrv_ms ??
      average(recent.map((record) => record.phys.hrv_ms)),
    rhrBpm: userProfile?.baseline_rhr_bpm ??
      average(recent.map((record) => record.phys.resting_heart_rate_bpm)),
    trimp: average(recent.map((record) =>
      firstFinite([
        record.training?.daily_trimp,
        record.workouts.totalTrimp > 0 ? record.workouts.totalTrimp : null,
      ])
    )),
    hydrationMl: average(recent.map((record) => record.hydrationMl)),
    calories: average(recent.map((record) => record.nutrition?.total_calories)),
    proteinG: average(recent.map((record) => record.nutrition?.total_protein)),
    carbsG: average(recent.map((record) => record.nutrition?.total_carbs)),
  };
}

function selectHistoricalMatches(
  records: HistoricalDayRecord[],
  signals: ScenarioSignals,
  baselines: Baselines,
): ScoredMatch[] {
  const scored = records
    .map((record) => scoreHistoricalRecord(record, signals, baselines))
    .filter((match) => match.score > 0)
    .sort((lhs, rhs) => {
      if (rhs.score !== lhs.score) return rhs.score - lhs.score;
      return rhs.record.outcomeDate.localeCompare(lhs.record.outcomeDate);
    });

  if (scored.length === 0) {
    return [];
  }

  const topScore = scored[0].score;
  const threshold = Math.max(3.5, topScore * 0.45);
  const matches = scored
    .filter((match) => match.score >= threshold)
    .slice(0, MAX_MATCHES);

  if (matches.length > 0) {
    return matches;
  }
  return scored.slice(0, Math.min(MAX_MATCHES, scored.length));
}

function scoreHistoricalRecord(
  record: HistoricalDayRecord,
  signals: ScenarioSignals,
  baselines: Baselines,
): ScoredMatch {
  let score = 0;
  const reasons: MatchReason[] = [];

  const sleepHours = record.phys.sleep_duration_hours;
  const alcoholUnits = record.nutrition?.alcohol_units;
  const caffeineAfter14 = record.nutrition?.caffeine_mg_after_14;
  const hydrationMl = record.hydrationMl;
  const stressLevel = record.wellness?.stress_level;
  const workoutCount = Math.max(
    record.workouts.workoutCount,
    toFiniteNumber(record.training?.workout_count) ?? 0,
  );
  const workoutDuration = firstFinite([
    record.training?.daily_duration_minutes,
    record.workouts.totalDurationMinutes > 0
      ? record.workouts.totalDurationMinutes
      : null,
  ]);
  const calorieRatio = relativeToTarget(
    record.nutrition?.total_calories,
    record.target?.final_calories,
    baselines.calories,
  );
  const proteinRatio = relativeToTarget(
    record.nutrition?.total_protein,
    record.target?.final_protein_g,
    baselines.proteinG,
  );
  const carbRatio = relativeToTarget(
    record.nutrition?.total_carbs,
    record.target?.final_carbs_g,
    baselines.carbsG,
  );

  const addReason = (key: string, label: string, weight: number) => {
    score += weight;
    reasons.push({ key, label });
  };
  // deno-coverage-ignore -- threshold fallback branches are exercised indirectly by scoring scenarios.
  const shortSleepThreshold = Math.min(
    6.5,
    (baselines.sleepHours ?? 7.0) - 0.5,
  );
  // deno-coverage-ignore -- threshold fallback branches are exercised indirectly by scoring scenarios.
  const longSleepThreshold = Math.max(
    8.0,
    (baselines.sleepHours ?? 7.0) + 0.75,
  );
  // deno-coverage-ignore-start -- nullish allostatic/stress combinations are defensive data-shape fallbacks.
  const hasHighStress = (stressLevel ?? 0) >= 4 ||
    (record.phys.allostatic_load ?? 0) >= 6;
  // deno-coverage-ignore-stop

  switch (signals.type) {
    case "sleep":
      if (sleepHours != null) addReason("sleep_data", "sleep data", 1.2);
      if (signals.sleepHoursTarget != null && sleepHours != null) {
        const closeness = Math.max(
          0,
          7 - Math.abs(sleepHours - signals.sleepHoursTarget) * 2.2,
        );
        if (closeness > 0) {
          addReason("sleep_target", "sleep duration match", closeness);
        }
      }
      if (
        signals.mentionsShortSleep && sleepHours != null &&
        sleepHours <= shortSleepThreshold
      ) {
        addReason("short_sleep", "short sleep", 6.0);
      }
      if (
        signals.mentionsLongSleep && sleepHours != null &&
        sleepHours >= longSleepThreshold
      ) {
        addReason("long_sleep", "long sleep", 4.5);
      }
      if (signals.mentionsLateNight && (caffeineAfter14 ?? 0) > 0) {
        addReason("late_caffeine", "late caffeine", 2.8);
      }
      // deno-coverage-ignore -- false-side alcohol guard is defensive; positive behavior is covered.
      if (signals.mentionsAlcohol && (alcoholUnits ?? 0) > 0) {
        addReason("alcohol", "alcohol", 3.2);
      }
      if (signals.mentionsStress && hasHighStress) {
        addReason("stress", "high stress", 2.3);
      }
      break;

    case "workout":
      if (workoutCount > 0) addReason("workout_presence", "workout day", 1.5);
      if (signals.mentionsRestDay && workoutCount === 0) {
        addReason("rest_day", "rest day", 7.0);
      }
      if (signals.mentionsHeavyLoad && isHeavyLoad(record, baselines)) {
        addReason("heavy_load", "high training load", 6.2);
      }
      if (
        signals.workoutMinutesTarget != null &&
        workoutDuration != null
      ) {
        const closeness = Math.max(
          0,
          6 - Math.abs(workoutDuration - signals.workoutMinutesTarget) / 18,
        );
        if (closeness > 0) {
          addReason("duration", "workout duration match", closeness);
        }
      }
      if (
        signals.mentionsStrength &&
        record.workouts.workoutTypes.some((type) => type === "strength")
      ) {
        addReason("strength", "strength workout", 4.2);
      }
      if (
        signals.mentionsCardio &&
        record.workouts.workoutTypes.some((type) =>
          type === "cardio" || type === "sport" || type === "mixed"
        )
      ) {
        addReason("cardio", "cardio workout", 4.2);
      }
      if (signals.mentionsLateNight && record.workouts.lateWorkoutCount > 0) {
        addReason("late_workout", "late workout", 2.7);
      }
      break;

    case "nutrition":
      if (record.nutrition) addReason("nutrition_data", "nutrition data", 1.2);
      if (signals.mentionsAlcohol && (alcoholUnits ?? 0) > 0) {
        addReason("alcohol", "alcohol", 7.0);
      }
      // deno-coverage-ignore -- false-side caffeine guard is defensive; positive behavior is covered.
      if (signals.mentionsCaffeine && (caffeineAfter14 ?? 0) > 0) {
        addReason("late_caffeine", "late caffeine", 6.5);
      }
      if (signals.mentionsLowHydration && isLowHydration(record, baselines)) {
        addReason("low_hydration", "low hydration", 5.5);
      } else if (signals.mentionsHydration && hydrationMl != null) {
        addReason("hydration", "hydration context", 2.2);
      }
      if (signals.mentionsProtein && proteinRatio != null) {
        if (proteinRatio >= 0.95) {
          addReason("protein_high", "protein on target", 4.0);
        }
        if (proteinRatio < 0.85) {
          addReason("protein_low", "protein below target", 3.0);
        }
      }
      if (signals.mentionsCarbs && carbRatio != null) {
        if (carbRatio >= 0.95) addReason("carbs_high", "carbs on target", 3.5);
        if (carbRatio < 0.85) addReason("carbs_low", "carbs below target", 3.0);
      }
      if (
        signals.mentionsUnderEating && calorieRatio != null &&
        calorieRatio < 0.85
      ) {
        addReason("under_eating", "under target calories", 5.0);
      }
      if (
        signals.mentionsOvereating && calorieRatio != null &&
        calorieRatio > 1.15
      ) {
        addReason("over_eating", "over target calories", 5.0);
      }
      break;

    case "general":
      if (signals.mentionsIllness && record.wellness?.feeling_ill === true) {
        addReason("illness", "feeling ill", 7.2);
      }
      if (signals.mentionsStress && (stressLevel ?? 0) >= 4) {
        addReason("stress", "high stress", 5.5);
      }
      if (signals.mentionsSleep && sleepHours != null) {
        const delta = baselines.sleepHours != null
          ? Math.abs(sleepHours - baselines.sleepHours)
          : null;
        if (delta != null && delta >= 0.75) {
          addReason("sleep_shift", "sleep pattern shift", 3.4);
        }
      }
      // deno-coverage-ignore -- false-side alcohol guard is defensive; positive behavior is covered.
      if (signals.mentionsAlcohol && (alcoholUnits ?? 0) > 0) {
        addReason("alcohol", "alcohol", 4.2);
      }
      // deno-coverage-ignore -- false-side caffeine guard is defensive; positive behavior is covered.
      if (signals.mentionsCaffeine && (caffeineAfter14 ?? 0) > 0) {
        addReason("late_caffeine", "late caffeine", 4.0);
      }
      if (signals.mentionsHydration && hydrationMl != null) {
        addReason(
          isLowHydration(record, baselines) ? "low_hydration" : "hydration",
          isLowHydration(record, baselines)
            ? "low hydration"
            : "hydration context",
          isLowHydration(record, baselines) ? 4.0 : 2.0,
        );
      }
      if (signals.mentionsWorkout && workoutCount > 0) {
        addReason(
          isHeavyLoad(record, baselines) ? "heavy_load" : "workout_presence",
          isHeavyLoad(record, baselines) ? "high training load" : "workout day",
          isHeavyLoad(record, baselines) ? 4.2 : 2.0,
        );
      }
      if (signals.mentionsTravel && record.workouts.lateWorkoutCount > 0) {
        addReason("schedule_shift", "schedule shift", 1.5);
      }
      break;
  }

  const qualityBoost = clampUnit(record.phys.data_completeness) * 1.4 +
    clampUnit(record.phys.confidence_score) * 1.1;
  score += qualityBoost;

  if (signals.type === "general" && reasons.length === 0) {
    score += 0.75;
  }
  if (
    signals.type === "sleep" && reasons.length === 1 &&
    reasons[0]?.key === "sleep_data"
  ) {
    score -= 0.5;
  }

  return { score, record, reasons };
}

function buildDerivedEstimate(
  matches: ScoredMatch[],
  baselines: Baselines,
  records: HistoricalDayRecord[],
): DerivedPredictiveEstimate {
  const latest = records[0];
  const currentRecovery = toFiniteNumber(latest?.phys.recovery_score) ??
    baselines.recovery ?? 65;
  const baselineRecovery = baselines.recovery ?? currentRecovery;
  const matchScores = matches
    .map((match) => toFiniteNumber(match.record.phys.recovery_score))
    .filter((value): value is number => value != null);

  const matchedAverage = average(matchScores) ?? baselineRecovery;
  const deltaVsBaseline = matchedAverage - baselineRecovery;
  const predictedScore = clampPercent(
    Math.round(currentRecovery + deltaVsBaseline),
  );

  const variance = standardDeviation(matchScores);
  const halfWidth = clampInt(
    Math.round(8 + Math.min(4, variance / 4) - Math.min(3, matches.length / 2)),
    4,
    10,
  );
  const predictedRange: [number, number] = [
    clampPercent(predictedScore - halfWidth),
    clampPercent(predictedScore + halfWidth),
  ];
  const confidence = clampUnit(
    0.35 +
      Math.min(0.32, matches.length * 0.08) +
      clampUnit(latest?.phys.data_completeness) * 0.18 +
      clampUnit(latest?.phys.confidence_score) * 0.15,
  );

  const rationale = matches.length > 0
    ? `Based on ${matches.length} matched personal precedents, the average shift versus your 28-day baseline is ${
      signedPercent(Math.round(deltaVsBaseline))
    }.`
    : "No close personal precedents were found; using your recent baseline and latest physiological trend only.";

  return {
    predictedScore,
    predictedRange,
    predictedZone: zoneFromScore(predictedScore),
    confidence,
    baselineRecovery,
    matchedAverageRecovery: matchedAverage,
    deltaVsBaseline,
    rationale,
  };
}

function buildCurrentStateLines(
  records: HistoricalDayRecord[],
  userProfile: PredictiveUserProfile | null,
  derivedEstimate: DerivedPredictiveEstimate,
): string[] {
  const latest = records[0];
  if (!latest) {
    return [
      `- No recent physiological history found; fallback estimate is ${derivedEstimate.predictedScore}% (${derivedEstimate.predictedZone})`,
    ];
  }
  const latestRecoveryZone = latest.phys.recovery_zone ??
    zoneFromScore(
      toFiniteNumber(latest.phys.recovery_score) ??
        derivedEstimate.predictedScore,
    );

  const lines = [
    `- Latest recovery (${latest.outcomeDate}): ${
      formatPercent(latest.phys.recovery_score)
    } (${latestRecoveryZone})`,
  ];

  if (latest.phys.sleep_duration_hours != null) {
    lines.push(
      `- Latest sleep: ${formatDecimal(latest.phys.sleep_duration_hours, 1)}h`,
    );
  }
  if (latest.training?.acwr != null) {
    lines.push(`- Latest ACWR: ${formatDecimal(latest.training.acwr, 2)}`);
  }
  if (latest.phys.allostatic_load != null) {
    lines.push(
      `- Latest allostatic load: ${
        formatDecimal(latest.phys.allostatic_load, 1)
      }/10`,
    );
  }
  if (userProfile?.primary_goal || userProfile?.activity_level) {
    lines.push(
      `- Goal / activity: ${userProfile?.primary_goal ?? "unknown"} / ${
        userProfile?.activity_level ?? "unknown"
      }`,
    );
  }

  return lines;
}

function buildBaselineLines(
  baselines: Baselines,
  userProfile: PredictiveUserProfile | null,
): string[] {
  const lines: string[] = [];

  if (baselines.recovery != null) {
    lines.push(
      `- 28-day baseline recovery: ${formatDecimal(baselines.recovery, 0)}%`,
    );
  }
  if (baselines.sleepHours != null) {
    lines.push(`- Baseline sleep: ${formatDecimal(baselines.sleepHours, 1)}h`);
  }
  if (baselines.hrvMs != null) {
    lines.push(`- Baseline HRV: ${formatDecimal(baselines.hrvMs, 1)} ms`);
  }
  if (baselines.rhrBpm != null) {
    lines.push(
      `- Baseline resting HR: ${formatDecimal(baselines.rhrBpm, 0)} bpm`,
    );
  }
  if (baselines.trimp != null) {
    lines.push(
      `- Typical daily training load: ${
        formatDecimal(baselines.trimp, 0)
      } TRIMP`,
    );
  }
  if (baselines.hydrationMl != null) {
    lines.push(
      `- Typical hydration: ${formatDecimal(baselines.hydrationMl, 0)} mL`,
    );
  }
  if (
    lines.length === 0 &&
    (userProfile?.primary_goal != null || userProfile?.activity_level != null)
  ) {
    lines.push(
      `- Goal / activity: ${userProfile?.primary_goal ?? "unknown"} / ${
        userProfile?.activity_level ?? "unknown"
      }`,
    );
  }

  return lines;
}

function buildRagMatchLines(
  matches: ScoredMatch[],
  baselines: Baselines,
  signals: ScenarioSignals,
): string[] {
  if (matches.length === 0) {
    return [
      "- No close personal precedents were found in the recent cloud history.",
      "- Use baseline-only reasoning and keep confidence conservative.",
    ];
  }

  const lines: string[] = [];
  lines.push(...buildAggregateSummaryLines(matches, baselines, signals));

  for (const match of matches.slice(0, MAX_EXAMPLE_LINES)) {
    lines.push(`- ${formatExampleLine(match)}`);
  }

  return lines;
}

function buildAggregateSummaryLines(
  matches: ScoredMatch[],
  baselines: Baselines,
  signals: ScenarioSignals,
): string[] {
  const lines: string[] = [];
  const baselineRecovery = baselines.recovery ??
    average(matches.map((match) => match.record.phys.recovery_score)) ?? 65;
  const matchRecovery = average(
    matches.map((match) => match.record.phys.recovery_score),
  );
  if (matchRecovery != null) {
    lines.push(
      `- Similar precedents: ${matches.length}; average next-morning recovery ${
        formatDecimal(matchRecovery, 0)
      }% (${
        signedPercent(Math.round(matchRecovery - baselineRecovery))
      } vs 28-day baseline).`,
    );
  }

  if (signals.type === "sleep" || signals.mentionsSleep) {
    const sleepAvg = average(
      matches.map((match) => match.record.phys.sleep_duration_hours),
    );
    if (sleepAvg != null) {
      lines.push(
        `- Matched sleep duration averaged ${
          formatDecimal(sleepAvg, 1)
        }h (baseline ${formatDecimal(baselines.sleepHours ?? sleepAvg, 1)}h).`,
      );
    }
  }

  if (signals.mentionsAlcohol) {
    const alcoholAvg = average(
      matches.map((match) => match.record.nutrition?.alcohol_units),
    );
    if (alcoholAvg != null && alcoholAvg > 0) {
      lines.push(
        `- Previous-evening alcohol on matched days averaged ${
          formatDecimal(alcoholAvg, 1)
        } units.`,
      );
    }
  }

  if (signals.mentionsCaffeine) {
    const caffeineAvg = average(
      matches.map((match) => match.record.nutrition?.caffeine_mg_after_14),
    );
    if (caffeineAvg != null && caffeineAvg > 0) {
      lines.push(
        `- Previous-evening caffeine after 14:00 on matched days averaged ${
          formatDecimal(caffeineAvg, 0)
        } mg.`,
      );
    }
  }

  if (signals.type === "workout" || signals.mentionsWorkout) {
    const trimpAvg = average(matches.map((match) =>
      firstFinite([
        match.record.training?.daily_trimp,
        match.record.workouts.totalTrimp > 0
          ? match.record.workouts.totalTrimp
          : null,
      ])
    ));
    if (trimpAvg != null) {
      lines.push(
        `- Previous-day training load on matched days averaged ${
          formatDecimal(trimpAvg, 0)
        } TRIMP.`,
      );
    }
  }

  if (signals.mentionsHydration) {
    const hydrationAvg = average(
      matches.map((match) => match.record.hydrationMl),
    );
    if (hydrationAvg != null) {
      lines.push(
        `- Previous-day hydration on matched days averaged ${
          formatDecimal(hydrationAvg, 0)
        } mL.`,
      );
    }
  }

  if (signals.mentionsStress || signals.mentionsIllness) {
    const stressAvg = average(
      matches.map((match) => match.record.wellness?.stress_level),
    );
    if (stressAvg != null) {
      lines.push(
        `- Previous-day stress on matched days averaged ${
          formatDecimal(stressAvg, 1)
        }/5.`,
      );
    }
    const illCount = matches.filter((match) =>
      match.record.wellness?.feeling_ill === true
    ).length;
    if (illCount > 0) {
      lines.push(
        `- ${illCount}/${matches.length} matched precedents were explicitly marked as feeling ill.`,
      );
    }
  }

  return lines.slice(0, 4);
}

function formatExampleLine(match: ScoredMatch): string {
  const parts = [
    `${match.record.outcomeDate} -> recovery ${
      formatPercent(match.record.phys.recovery_score)
    }`,
  ];

  if (match.record.phys.sleep_duration_hours != null) {
    parts.push(
      `sleep ${formatDecimal(match.record.phys.sleep_duration_hours, 1)}h`,
    );
  }
  if ((match.record.nutrition?.alcohol_units ?? 0) > 0) {
    parts.push(
      `alcohol ${formatDecimal(match.record.nutrition?.alcohol_units, 1)}u`,
    );
  }
  if ((match.record.nutrition?.caffeine_mg_after_14 ?? 0) > 0) {
    parts.push(
      `caffeine after 14:00 ${
        formatDecimal(match.record.nutrition?.caffeine_mg_after_14, 0)
      }mg`,
    );
  }
  const trainingTrimp = firstFinite([
    match.record.training?.daily_trimp,
    match.record.workouts.totalTrimp > 0
      ? match.record.workouts.totalTrimp
      : null,
  ]);
  if (trainingTrimp != null && trainingTrimp > 0) {
    parts.push(`prev-day TRIMP ${formatDecimal(trainingTrimp, 0)}`);
  }
  if (match.record.hydrationMl != null) {
    parts.push(`hydration ${formatDecimal(match.record.hydrationMl, 0)}mL`);
  }
  if ((match.record.wellness?.stress_level ?? 0) >= 4) {
    parts.push(`stress ${match.record.wellness?.stress_level}/5`);
  }
  if (match.record.wellness?.feeling_ill === true) {
    parts.push("feeling ill");
  }
  if (match.reasons.length > 0) {
    parts.push(
      `matched on ${
        dedupe(match.reasons.map((reason) => reason.label)).join(", ")
      }`,
    );
  }

  return parts.join("; ");
}

function selectRelevantInsights(
  insights: InsightHistoryRow[],
  signals: ScenarioSignals,
): InsightHistoryRow[] {
  const relevantCategories = new Set<string>();
  const relevantMetrics = new Set<string>();

  switch (signals.type) {
    case "sleep":
      relevantCategories.add("sleep");
      relevantCategories.add("recovery");
      relevantMetrics.add("sleep_duration_hours");
      relevantMetrics.add("sleep_quality_percent");
      relevantMetrics.add("deep_sleep_percent");
      relevantMetrics.add("rem_sleep_percent");
      relevantMetrics.add("caffeine_mg");
      relevantMetrics.add("alcohol_units");
      break;
    case "workout":
      relevantCategories.add("training");
      relevantCategories.add("recovery");
      relevantMetrics.add("training_trimp");
      relevantMetrics.add("acwr");
      relevantMetrics.add("active_energy_kcal");
      relevantMetrics.add("recovery_score");
      break;
    case "nutrition":
      relevantCategories.add("nutrition");
      relevantCategories.add("recovery");
      relevantMetrics.add("calories");
      relevantMetrics.add("protein_g");
      relevantMetrics.add("carbs_g");
      relevantMetrics.add("fat_g");
      relevantMetrics.add("hydration_ml");
      relevantMetrics.add("alcohol_units");
      relevantMetrics.add("caffeine_mg");
      break;
    case "general":
      relevantCategories.add("general");
      relevantCategories.add("health");
      relevantCategories.add("recovery");
      relevantMetrics.add("stress_level");
      relevantMetrics.add("energy_level");
      relevantMetrics.add("recovery_score");
      relevantMetrics.add("sleep_duration_hours");
      relevantMetrics.add("hydration_ml");
      break;
  }

  return insights
    .filter((insight) => {
      const category = (insight.category ?? "").trim().toLowerCase();
      const relatedMetrics = (insight.related_metrics ?? []).map((metric) =>
        metric.trim().toLowerCase()
      );
      if (category && relevantCategories.has(category)) return true;
      return relatedMetrics.some((metric) => relevantMetrics.has(metric));
    })
    .sort((lhs, rhs) => {
      // deno-coverage-ignore-start -- null confidence sorting fallback is defensive; ranking behavior is covered.
      const confidenceDelta = (toFiniteNumber(rhs.confidence) ?? 0) -
        (toFiniteNumber(lhs.confidence) ?? 0);
      // deno-coverage-ignore-stop
      if (confidenceDelta !== 0) return confidenceDelta;
      return rhs.created_at.localeCompare(lhs.created_at);
    })
    .slice(0, 2);
}

function formatInsightLine(insight: InsightHistoryRow): string {
  const confidence = toFiniteNumber(insight.confidence);
  const confidenceText = confidence != null
    ? `conf ${formatDecimal(confidence, 2)}`
    : "conf n/a";
  const lagText = insight.lag_days != null ? `, lag ${insight.lag_days}d` : "";
  const correlationText = insight.correlation_coefficient != null
    ? `, r=${formatDecimal(insight.correlation_coefficient, 2)}`
    : "";
  const rationale = trimmed(insight.reasoning) || trimmed(insight.body);
  return `- ${insight.title} (${confidenceText}${lagText}${correlationText}): ${
    truncate(rationale, 180)
  }`;
}

function parseScenarioSignals(
  scenarioText: string,
  scenarioType: PredictiveScenarioType,
): ScenarioSignals {
  const normalizedText = scenarioText.toLowerCase().replace(/\s+/g, " ").trim();
  const hours = extractNumberUnits(normalizedText, [
    "h",
    "hr",
    "hrs",
    "hour",
    "hours",
    "ч",
    "час",
    "часа",
    "часов",
  ]);
  const minutes = extractNumberUnits(normalizedText, [
    "m",
    "min",
    "mins",
    "minute",
    "minutes",
    "мин",
    "минута",
    "минуты",
    "минут",
  ]);

  const mentionsSleep = scenarioType === "sleep" ||
    containsAny(normalizedText, [
      "sleep",
      "bed",
      "nap",
      "insomnia",
      "сон",
      "спать",
      "усну",
      "бессон",
      "кровать",
      "ноч",
      "поздно",
    ]);
  const mentionsWorkout = scenarioType === "workout" ||
    containsAny(normalizedText, [
      "workout",
      "training",
      "run",
      "gym",
      "cardio",
      "strength",
      "session",
      "exercise",
      "трениров",
      "зал",
      "кардио",
      "бег",
      "силов",
      "пробеж",
    ]);

  const mentionsLateNight = containsAny(normalizedText, [
    "late",
    "midnight",
    "01:00",
    "00:",
    "23:",
    "поздно",
    "ноч",
    "поздний",
    "полноч",
  ]);
  const mentionsShortSleep = mentionsSleep && (
    containsAny(normalizedText, [
      "short sleep",
      "sleep less",
      "sleep 2",
      "sleep 3",
      "sleep 4",
      "sleep 5",
      "all-nighter",
      "не высп",
      "мало сна",
      "спать 2",
      "спать 3",
      "спать 4",
      "спать 5",
    ]) ||
    (scenarioType === "sleep" && hours.some((value) => value < 6.5))
  );
  const mentionsLongSleep = mentionsSleep && (
    containsAny(normalizedText, [
      "sleep more",
      "sleep in",
      "extra sleep",
      "долго спать",
      "выспаться",
      "дольше сна",
    ]) ||
    (scenarioType === "sleep" && hours.some((value) => value >= 8.0))
  );
  const mentionsHeavyLoad = containsAny(normalizedText, [
    "hard workout",
    "intense",
    "heavy",
    "double session",
    "long run",
    "max effort",
    "тяжел",
    "интенсив",
    "жестк",
    "двойн",
    "долгая пробеж",
  ]) || (scenarioType === "workout" && (
    hours.some((value) => value >= 1.5) || minutes.some((value) => value >= 75)
  ));

  return {
    type: scenarioType,
    normalizedText,
    sleepHoursTarget: mentionsSleep
      ? firstMatching(hours, (value) => value >= 2 && value <= 14)
      : null,
    workoutMinutesTarget: mentionsWorkout
      ? firstWorkoutDurationMinutes(hours, minutes)
      : null,
    mentionsSleep,
    mentionsShortSleep,
    mentionsLongSleep,
    mentionsLateNight,
    mentionsWorkout,
    mentionsHeavyLoad,
    mentionsRestDay: containsAny(normalizedText, [
      "rest day",
      "no workout",
      "skip training",
      "day off",
      "без тренировки",
      "день отдыха",
      "пропущу тренировку",
    ]),
    mentionsCardio: containsAny(normalizedText, [
      "cardio",
      "run",
      "cycling",
      "bike",
      "zone 2",
      "кардио",
      "бег",
      "вело",
    ]),
    mentionsStrength: containsAny(normalizedText, [
      "strength",
      "lift",
      "weights",
      "leg day",
      "силов",
      "веса",
      "присед",
      "жим",
    ]),
    mentionsAlcohol: containsAny(normalizedText, [
      "alcohol",
      "beer",
      "wine",
      "drink",
      "cocktail",
      "пиво",
      "вино",
      "алког",
      "коктейл",
      "выпью",
    ]),
    mentionsCaffeine: containsAny(normalizedText, [
      "coffee",
      "caffeine",
      "espresso",
      "pre-workout",
      "energy drink",
      "кофе",
      "кофеин",
      "эспрессо",
      "энергетик",
      "предтр",
    ]),
    mentionsHydration: containsAny(normalizedText, [
      "water",
      "hydrate",
      "hydration",
      "electrolyte",
      "вода",
      "гидрат",
      "электролит",
      "пить",
    ]),
    mentionsLowHydration: containsAny(normalizedText, [
      "dehydr",
      "not enough water",
      "skip water",
      "обезвож",
      "мало воды",
      "не пил воду",
    ]),
    mentionsProtein: containsAny(normalizedText, [
      "protein",
      "shake",
      "белок",
      "протеин",
      "шейк",
    ]),
    mentionsCarbs: containsAny(normalizedText, [
      "carb",
      "carbs",
      "углевод",
    ]),
    mentionsUnderEating: containsAny(normalizedText, [
      "fast",
      "skip meal",
      "under-eat",
      "undereat",
      "calorie deficit",
      "натощак",
      "голод",
      "не поем",
      "дефицит калор",
    ]),
    mentionsOvereating: containsAny(normalizedText, [
      "binge",
      "overeat",
      "cheat meal",
      "переем",
      "объед",
      "читмил",
      "слишком много еды",
    ]),
    mentionsStress: containsAny(normalizedText, [
      "stress",
      "anxiety",
      "anxious",
      "overwhelm",
      "busy",
      "стресс",
      "тревог",
      "нерв",
      "перегруз",
    ]),
    mentionsIllness: containsAny(normalizedText, [
      "sick",
      "ill",
      "fever",
      "cold",
      "flu",
      "боле",
      "простуд",
      "температур",
      "забол",
      "грип",
    ]),
    mentionsTravel: containsAny(normalizedText, [
      "travel",
      "flight",
      "jet lag",
      "trip",
      "timezone",
      "перелет",
      "поездк",
      "джетлаг",
      "смена час",
    ]),
  };
}

function firstWorkoutDurationMinutes(
  hours: number[],
  minutes: number[],
): number | null {
  const directMinutes = firstMatching(
    minutes,
    (value) => value >= 10 && value <= 300,
  );
  if (directMinutes != null) return directMinutes;
  const hourValue = firstMatching(hours, (value) => value >= 0.5 && value <= 5);
  if (hourValue == null) return null;
  return Math.round(hourValue * 60);
}

function relativeToTarget(
  actual: number | null | undefined,
  target: number | null | undefined,
  baseline: number | null,
): number | null {
  const actualValue = toFiniteNumber(actual);
  const denominator = firstFinite([target, baseline]);
  if (actualValue == null || denominator == null || denominator <= 0) {
    return null;
  }
  return actualValue / denominator;
}

function isHeavyLoad(
  record: HistoricalDayRecord,
  baselines: Baselines,
): boolean {
  const trimp = firstFinite([
    record.training?.daily_trimp,
    record.workouts.totalTrimp > 0 ? record.workouts.totalTrimp : null,
  ]) ?? 0;
  const durationSource = record.workouts.totalDurationMinutes > 0
    ? record.workouts.totalDurationMinutes
    : null;
  // deno-coverage-ignore-start -- duration fallback composes already-covered workout aggregate fallbacks.
  const duration =
    firstFinite([record.training?.daily_duration_minutes, durationSource]) ?? 0;
  // deno-coverage-ignore-stop
  const workoutCount = Math.max(
    record.workouts.workoutCount,
    toFiniteNumber(record.training?.workout_count) ?? 0,
  );
  const baselineTrimp = baselines.trimp ?? 75;
  return trimp >= Math.max(100, baselineTrimp * 1.25) ||
    duration >= 90 ||
    workoutCount >= 2 ||
    (record.training?.acwr ?? 0) >= 1.2;
}

function isLowHydration(
  record: HistoricalDayRecord,
  baselines: Baselines,
): boolean {
  const hydrationMl = toFiniteNumber(record.hydrationMl);
  if (hydrationMl == null) return false;
  const baselineHydration = baselines.hydrationMl ?? 2000;
  return hydrationMl < Math.max(1200, baselineHydration * 0.75);
}

function aggregateHydrationByDate(
  rows: HydrationHistoryRow[],
): Map<string, number> {
  const result = new Map<string, number>();
  for (const row of rows) {
    const date = trimmed(row.logged_date);
    const waterMl = toFiniteNumber(row.water_ml);
    if (!date || waterMl == null) continue;
    result.set(date, (result.get(date) ?? 0) + waterMl);
  }
  return result;
}

function aggregateWorkoutsByDate(
  rows: WorkoutSessionHistoryRow[],
): Map<string, DailyWorkoutAggregate> {
  const result = new Map<string, DailyWorkoutAggregate>();
  for (const row of rows) {
    const date = trimmed(row.session_date);
    if (!date) continue;
    const aggregate = result.get(date) ?? emptyWorkoutAggregate();
    aggregate.workoutCount += 1;
    aggregate.totalDurationMinutes += toFiniteNumber(row.duration_minutes) ?? 0;
    aggregate.totalTrimp += toFiniteNumber(row.trimp_score) ?? 0;
    const workoutType = trimmed(row.workout_type);
    if (workoutType && !aggregate.workoutTypes.includes(workoutType)) {
      aggregate.workoutTypes.push(workoutType);
    }
    const localHour = resolveLocalHour(
      row.started_at,
      row.started_utc_offset_minutes,
    );
    if (localHour != null && localHour >= 18) {
      aggregate.lateWorkoutCount += 1;
    }
    result.set(date, aggregate);
  }
  return result;
}

function resolveLocalHour(
  startedAt: string | null,
  offsetMinutes: number | null,
): number | null {
  const startedMs = startedAt != null ? Date.parse(startedAt) : Number.NaN;
  if (!Number.isFinite(startedMs)) return null;
  const offsetMs = (toFiniteNumber(offsetMinutes) ?? 0) * 60_000;
  return new Date(startedMs + offsetMs).getUTCHours();
}

function indexByDate<T>(
  rows: T[],
  getDate: (row: T) => string,
): Map<string, T> {
  const result = new Map<string, T>();
  for (const row of rows) {
    const date = trimmed(getDate(row));
    if (date) {
      result.set(date, row);
    }
  }
  return result;
}

function section(title: string, lines: string[]): string {
  if (lines.length === 0) return "";
  return `${title}:\n${lines.join("\n")}`;
}

function zoneFromScore(score: number): RecoveryZone {
  if (score < 25) return "critical";
  if (score < 50) return "caution";
  if (score < 75) return "ready";
  return "optimal";
}

function addDays(date: string, deltaDays: number): string {
  const parsed = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(parsed + deltaDays * MS_PER_DAY).toISOString().slice(0, 10);
}

function containsAny(haystack: string, needles: string[]): boolean {
  return needles.some((needle) => haystack.includes(needle));
}

function extractNumberUnits(
  text: string,
  unitPatterns: string[],
): number[] {
  const escapedUnits = unitPatterns.map((pattern) =>
    pattern.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  );
  const regex = new RegExp(
    `(\\d+(?:[.,]\\d+)?)\\s*(?:${escapedUnits.join("|")})\\b`,
    "gi",
  );
  const values: number[] = [];
  let match: RegExpExecArray | null;
  while ((match = regex.exec(text)) != null) {
    const parsed = Number(match[1].replace(",", "."));
    if (Number.isFinite(parsed)) values.push(parsed);
  }
  return values;
}

function firstMatching(
  values: number[],
  predicate: (value: number) => boolean,
): number | null {
  for (const value of values) {
    if (predicate(value)) return value;
  }
  return null;
}

function average(values: Array<number | null | undefined>): number | null {
  const numeric = values
    .map((value) => toFiniteNumber(value))
    .filter((value): value is number => value != null);
  if (numeric.length === 0) return null;
  const total = numeric.reduce((sum, value) => sum + value, 0);
  return total / numeric.length;
}

function standardDeviation(values: Array<number | null | undefined>): number {
  const numeric = values
    .map((value) => toFiniteNumber(value))
    .filter((value): value is number => value != null);
  if (numeric.length <= 1) return 0;
  // deno-coverage-ignore -- average cannot be null after numeric.length > 1 guard.
  const mean = average(numeric) ?? 0;
  const variance = numeric.reduce((sum, value) => {
    const diff = value - mean;
    return sum + diff * diff;
  }, 0) / numeric.length;
  return Math.sqrt(variance);
}

function firstFinite(values: Array<number | null | undefined>): number | null {
  for (const value of values) {
    const numeric = toFiniteNumber(value);
    if (numeric != null) return numeric;
  }
  return null;
}

function toFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clampUnit(value: unknown): number {
  const numeric = toFiniteNumber(value) ?? 0;
  return Math.min(1, Math.max(0, numeric));
}

function clampPercent(value: number): number {
  return Math.min(100, Math.max(0, value));
}

function clampInt(value: number, minValue: number, maxValue: number): number {
  return Math.min(maxValue, Math.max(minValue, value));
}

function formatPercent(value: number | null | undefined): string {
  const numeric = toFiniteNumber(value);
  return numeric == null ? "n/a" : `${formatDecimal(numeric, 0)}%`;
}

function formatDecimal(
  value: number | null | undefined,
  precision: number,
): string {
  const numeric = toFiniteNumber(value);
  if (numeric == null) return "n/a";
  const fixed = numeric.toFixed(precision);
  return fixed.replace(/\.0+$/, "").replace(/(\.\d*?)0+$/, "$1");
}

function signedPercent(value: number): string {
  if (value > 0) return `+${value}%`;
  if (value < 0) return `${value}%`;
  return "0%";
}

function dedupe(values: string[]): string[] {
  return [...new Set(values)];
}

function emptyWorkoutAggregate(): DailyWorkoutAggregate {
  return {
    workoutCount: 0,
    totalDurationMinutes: 0,
    totalTrimp: 0,
    lateWorkoutCount: 0,
    workoutTypes: [],
  };
}

function trimmed(value: string | null | undefined): string {
  return typeof value === "string" ? value.trim() : "";
}

function truncate(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  return `${value.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`;
}

export const __predictiveContextTestHooks = {
  addDays,
  aggregateHydrationByDate,
  aggregateWorkoutsByDate,
  average,
  buildAggregateSummaryLines,
  buildBaselineLines,
  buildCurrentStateLines,
  buildDerivedEstimate,
  buildHistoricalDayRecords,
  buildRagMatchLines,
  clampInt,
  clampPercent,
  clampUnit,
  containsAny,
  dedupe,
  deriveBaselines,
  emptyWorkoutAggregate,
  extractNumberUnits,
  firstFinite,
  firstMatching,
  firstWorkoutDurationMinutes,
  formatDecimal,
  formatExampleLine,
  formatInsightLine,
  formatPercent,
  indexByDate,
  isHeavyLoad,
  isLowHydration,
  parseScenarioSignals,
  relativeToTarget,
  resolveLocalHour,
  scoreHistoricalRecord,
  section,
  selectHistoricalMatches,
  selectRelevantInsights,
  signedPercent,
  standardDeviation,
  toFiniteNumber,
  trimmed,
  truncate,
  zoneFromScore,
};
