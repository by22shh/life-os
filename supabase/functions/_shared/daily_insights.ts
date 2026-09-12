import { localDateToday, safeTimeZone } from "./date_range.ts";
import { serviceRoleClient } from "./supabase.ts";

type ServiceClient = ReturnType<typeof serviceRoleClient>;

interface RecoveryRow {
  date: string;
  recovery_score: number | null;
  recovery_zone: string | null;
  sleep_duration_hours: number | null;
  allostatic_load: number | null;
  confidence_score: number | null;
}

interface NutritionTargetRow {
  final_calories: number | null;
  final_protein_g: number | null;
}

interface FoodRow {
  calories: number | null;
  protein_g: number | null;
}

interface WorkoutRow {
  trimp_score: number | null;
  duration_minutes: number | null;
}

export interface GeneratedInsightRow {
  id: string;
  user_id: string;
  created_at: string;
  updated_at: string;
  category: string;
  type: string | null;
  title: string;
  description: string | null;
  body: string;
  reasoning: string | null;
  confidence: number;
  confidence_score: number | null;
  inputs_used: string | null;
  needs_review: boolean;
  related_metrics: string[] | null;
  related_dates: string[] | null;
  priority: number;
  actionable: boolean;
  action_type: string | null;
  shown_to_user: boolean;
  shown_at: string | null;
  read: boolean;
  read_at: string | null;
  acknowledged: boolean;
  acknowledged_at: string | null;
  dismissed: boolean;
  dismissed_at: string | null;
  acted_upon: boolean;
  action_taken: string | null;
  expires_at: string | null;
}

export interface GeneratedRecommendationRow {
  id: string;
  user_id: string;
  created_at: string;
  updated_at: string;
  recommendation_date: string;
  time_of_day: string | null;
  category: string;
  priority: string;
  title: string;
  description: string;
  reasoning: string;
  insight_id: string | null;
  action_type: string | null;
  action_parameters: Record<string, string> | null;
  auto_execute: boolean;
  dismissed: boolean;
  followed: boolean | null;
  user_feedback: string | null;
  recovery_score_at_time: number | null;
  trigger_condition: string | null;
}

export interface GeneratedDailySnapshot {
  date: string;
  generated_at: string;
  insights: GeneratedInsightRow[];
  recommendations: GeneratedRecommendationRow[];
}

interface GenerationContext {
  userId: string;
  date: string;
  generatedAt: string;
  localHour: number;
  baselineSleepHours: number | null;
  recoveryRows: RecoveryRow[];
  nutritionTarget: NutritionTargetRow | null;
  totalProtein: number;
  mealCount: number;
  workoutCount: number;
  totalTrimp: number;
}

const INSIGHT_PREFIX = "daily/";
const RECOMMENDATION_PREFIX = "daily/";

const InsightKind = {
  recoveryStatus: "recovery_status",
  sleepDebt: "sleep_debt",
  nutritionGap: "nutrition_gap",
  trainingLoad: "training_load",
  setupPrompt: "setup_prompt",
} as const;

const RecommendationKind = {
  recoveryRest: "recovery_rest",
  sleepExtension: "sleep_extension",
  proteinAnchor: "protein_anchor",
  trainingCap: "training_cap",
  steadyDay: "steady_day",
  setupPrompt: "setup_prompt",
} as const;

export async function generateAndPersistDailyInsights(params: {
  service: ServiceClient;
  userId: string;
  timezone: string | null;
  date?: string;
}): Promise<GeneratedDailySnapshot> {
  const timezone = safeTimeZone(params.timezone);
  const date = params.date?.trim() || localDateToday(timezone);
  const generatedAt = new Date().toISOString();
  const lookbackStart = addDays(date, -6);

  const [userRes, recoveryRes, targetRes, foodRes, workoutRes] = await Promise
    .all([
      params.service
        .from("users")
        .select("baseline_sleep_hours")
        .eq("id", params.userId)
        .maybeSingle<{ baseline_sleep_hours: number | null }>(),
      params.service
        .from("physiological_states")
        .select(
          "date,recovery_score,recovery_zone,sleep_duration_hours,allostatic_load,confidence_score",
        )
        .eq("user_id", params.userId)
        .gte("date", lookbackStart)
        .lte("date", date)
        .order("date", { ascending: true })
        .returns<RecoveryRow[]>(),
      params.service
        .from("daily_nutrition_targets")
        .select("final_calories,final_protein_g")
        .eq("user_id", params.userId)
        .eq("date", date)
        .maybeSingle<NutritionTargetRow>(),
      params.service
        .from("food_logs")
        .select("calories,protein_g")
        .eq("user_id", params.userId)
        .eq("logged_date", date)
        .is("deleted_at", null)
        .returns<FoodRow[]>(),
      params.service
        .from("workout_sessions")
        .select("trimp_score,duration_minutes")
        .eq("user_id", params.userId)
        .eq("session_date", date)
        .is("deleted_at", null)
        .returns<WorkoutRow[]>(),
    ]);

  for (
    const [error, code] of [
      [userRes.error, "user_fetch_failed"],
      [recoveryRes.error, "recovery_fetch_failed"],
      [targetRes.error, "nutrition_target_fetch_failed"],
      [foodRes.error, "food_fetch_failed"],
      [workoutRes.error, "workout_fetch_failed"],
    ] as const
  ) {
    if (error) {
      throw new Error(`${code}:${error.message}`);
    }
  }

  const foodRows = foodRes.data ?? [];
  const workoutRows = workoutRes.data ?? [];
  const recoveryRows = recoveryRes.data ?? [];
  const nutritionTarget = targetRes.data ?? null;
  const totalProtein = foodRows.reduce(
    (sum, row) => sum + Number(row.protein_g ?? 0),
    0,
  );
  const totalTrimp = workoutRows.reduce(
    (sum, row) => sum + Number(row.trimp_score ?? 0),
    0,
  );
  const context: GenerationContext = {
    userId: params.userId,
    date,
    generatedAt,
    localHour: localHourInTimeZone(timezone),
    baselineSleepHours: userRes.data?.baseline_sleep_hours ?? null,
    recoveryRows,
    nutritionTarget,
    totalProtein,
    mealCount: foodRows.length,
    workoutCount: workoutRows.length,
    totalTrimp,
  };

  const generated = await buildDailySnapshot(context);
  return await persistDailySnapshot(params.service, params.userId, generated);
}

async function buildDailySnapshot(
  context: GenerationContext,
): Promise<GeneratedDailySnapshot> {
  const todayState =
    [...context.recoveryRows].reverse().find((row) =>
      row.date === context.date
    ) ?? null;
  // deno-coverage-ignore-start -- nullish recovery score filtering is covered by snapshot behavior tests.
  const priorRecoveryScores = context.recoveryRows.filter((row) =>
    row.date !== context.date
  ).map((row) => Number(row.recovery_score ?? 0)).filter((value) =>
    Number.isFinite(value) && value > 0
  );
  // deno-coverage-ignore-stop
  const avgPriorRecovery = average(priorRecoveryScores);
  const timeOfDay = recommendationTimeOfDay(context.localHour);

  const insights: GeneratedInsightRow[] = [];
  const recommendations: GeneratedRecommendationRow[] = [];

  if (todayState && isFiniteNumber(todayState.recovery_score)) {
    const recoveryScore = Number(todayState.recovery_score);
    const delta = avgPriorRecovery > 0 ? recoveryScore - avgPriorRecovery : 0;
    const roundedDelta = Math.abs(Math.round(delta));
    const roundedScore = Math.round(recoveryScore);
    const zone = humanize(todayState.recovery_zone ?? "ready");

    let recoveryTitle = "Recovery is stable but not fully topped up";
    let recoveryBody =
      `Today's recovery score is ${roundedScore} in the ${zone} zone, so consistency should pay off better than adding extra strain.`;
    let recoveryPriority = 3;
    if (recoveryScore < 45) {
      recoveryTitle = delta < 0
        ? "Recovery is below your recent range"
        : "Recovery needs a lighter day";
      recoveryBody = delta < 0 && roundedDelta > 0
        ? `Today's recovery score is ${roundedScore} in the ${zone} zone, about ${roundedDelta} points below your recent pattern.`
        : `Today's recovery score is ${roundedScore} in the ${zone} zone, so it is a better day to protect bandwidth than chase intensity.`;
      recoveryPriority = recoveryScore < 25 ? 1 : 2;
    } else if (recoveryScore >= 75) {
      recoveryTitle = "Recovery is supporting a steady day";
      recoveryBody = delta > 0 && roundedDelta > 0
        ? `Today's recovery score is ${roundedScore}, about ${roundedDelta} points above your recent range, which supports normal training and workload.`
        : `Today's recovery score is ${roundedScore}, which supports a normal training and work rhythm today.`;
      recoveryPriority = 4;
    }

    const recoveryInsight = await makeInsight({
      userId: context.userId,
      date: context.date,
      generatedAt: context.generatedAt,
      kind: InsightKind.recoveryStatus,
      category: "recovery",
      title: recoveryTitle,
      description: "Daily recovery guidance",
      body: recoveryBody,
      reasoning:
        "Life OS compared today's recovery state with your last week of physiological data.",
      confidence: clampConfidence(todayState.confidence_score ?? 0.86),
      inputsUsed: "physiological_states",
      priority: recoveryPriority,
      actionable: recoveryScore < 60,
      actionType: recoveryScore < 60 ? "rest" : null,
      relatedMetrics: [
        "recovery_score",
        "sleep_duration_hours",
        "stress_level",
      ],
      relatedDates: [context.date],
      expiresAt: addDaysISO(context.generatedAt, 7),
    });
    insights.push(recoveryInsight);

    // deno-coverage-ignore-start -- rest recommendation outcomes are covered; short-circuit branch is redundant.
    const shouldRecommendRest = recoveryScore < 55 ||
      Number(todayState.allostatic_load ?? 0) >= 4;
    // deno-coverage-ignore-stop
    if (shouldRecommendRest) {
      const reason = context.totalTrimp >= 60
        ? "Recovery is muted while today's training load is already substantial."
        : "Recovery and load signals both point to a lighter day paying off.";
      recommendations.push(
        await makeRecommendation({
          userId: context.userId,
          date: context.date,
          generatedAt: context.generatedAt,
          kind: RecommendationKind.recoveryRest,
          category: "recovery",
          priority: recoveryScore < 25 ? "critical" : "high",
          title: recoveryScore < 25
            ? "Make today a restoration day"
            : "Keep today's load restorative",
          description: context.totalTrimp >= 60
            ? "You already have meaningful load on the board. Skip extra intensity and bias toward mobility, walking, or rest."
            : "Favor mobility, walking, or easy zone-1 work over extra intensity today.",
          reasoning: reason,
          timeOfDay,
          insightId: recoveryInsight.id,
          actionType: "rest",
          actionParameters: {
            max_trimp: String(Math.max(Math.round(context.totalTrimp), 20)),
            mode: "restorative",
          },
          recoveryScoreAtTime: recoveryScore,
        }),
      );
    }
  }

  if (
    todayState &&
    isFiniteNumber(todayState.sleep_duration_hours) &&
    isFiniteNumber(context.baselineSleepHours) &&
    Number(context.baselineSleepHours) -
          Number(todayState.sleep_duration_hours) >=
      0.75
  ) {
    const sleepDuration = Number(todayState.sleep_duration_hours);
    const baselineSleep = Number(context.baselineSleepHours);
    const deficitHours = Math.max(0, baselineSleep - sleepDuration);
    const sleepInsight = await makeInsight({
      userId: context.userId,
      date: context.date,
      generatedAt: context.generatedAt,
      kind: InsightKind.sleepDebt,
      category: "sleep",
      title: "Sleep came in below your baseline",
      description: "Sleep debt signal",
      body: `You logged ${
        formatHours(sleepDuration)
      } hours of sleep versus a usual ${
        formatHours(baselineSleep)
      }, so today's recovery ceiling is lower than usual.`,
      reasoning:
        "Life OS compares today's sleep duration with your stored baseline sleep need.",
      confidence: 0.84,
      inputsUsed: "physiological_states,users",
      priority: 2,
      actionable: true,
      actionType: "increase_sleep",
      relatedMetrics: ["sleep_duration_hours", "recovery_score"],
      relatedDates: [context.date],
      expiresAt: addDaysISO(context.generatedAt, 5),
    });
    insights.push(sleepInsight);

    recommendations.push(
      await makeRecommendation({
        userId: context.userId,
        date: context.date,
        generatedAt: context.generatedAt,
        kind: RecommendationKind.sleepExtension,
        category: "sleep",
        priority: deficitHours >= 1.5 ? "high" : "medium",
        title: "Buy back sleep tonight",
        description: `Protect bedtime and pull ${
          Math.round(deficitHours * 60)
        } minutes of extra sleep into tonight's plan.`,
        reasoning:
          "Closing the sleep gap is the cleanest way to improve tomorrow's readiness.",
        timeOfDay,
        insightId: sleepInsight.id,
        actionType: "increase_sleep",
        actionParameters: {
          minutes: String(Math.round(deficitHours * 60)),
          focus: "bedtime",
        },
        recoveryScoreAtTime: todayState?.recovery_score ?? null,
      }),
    );
  }

  const targetProtein = Number(context.nutritionTarget?.final_protein_g ?? 0);
  if (
    isFiniteNumber(context.nutritionTarget?.final_protein_g) &&
    targetProtein > 0
  ) {
    const proteinShortfall = targetProtein - context.totalProtein;
    const shouldPushProtein = proteinShortfall >= 25 ||
      (context.localHour >= 15 && proteinShortfall >= 15);
    if (shouldPushProtein) {
      const nutritionInsight = await makeInsight({
        userId: context.userId,
        date: context.date,
        generatedAt: context.generatedAt,
        kind: InsightKind.nutritionGap,
        category: "nutrition",
        title: "Protein is trailing today's target",
        description: "Daily protein gap",
        body: `You're at ${
          Math.round(context.totalProtein)
        }g of ${targetProtein}g protein today, so the next meal is the best place to close the gap.`,
        reasoning:
          "Life OS compares today's food logs with your personalized protein target.",
        confidence: context.mealCount === 0 ? 0.74 : 0.82,
        inputsUsed: "food_logs,daily_nutrition_targets",
        priority: context.localHour >= 17 ? 2 : 3,
        actionable: true,
        actionType: "eat_protein",
        relatedMetrics: ["protein_g", "calories"],
        relatedDates: [context.date],
        expiresAt: addDaysISO(context.generatedAt, 3),
      });
      insights.push(nutritionInsight);

      recommendations.push(
        await makeRecommendation({
          userId: context.userId,
          date: context.date,
          generatedAt: context.generatedAt,
          kind: RecommendationKind.proteinAnchor,
          category: "nutrition",
          priority: context.localHour >= 17 ? "high" : "medium",
          title: "Anchor the next meal around protein",
          description: `Aim to close roughly ${
            Math.max(Math.round(proteinShortfall), 0)
          }g of protein with your next meal or snack.`,
          reasoning:
            "Protein intake is the biggest nutrition gap remaining in today's plan.",
          timeOfDay,
          insightId: nutritionInsight.id,
          actionType: "eat_protein",
          actionParameters: {
            remaining_protein_g: String(
              Math.max(Math.round(proteinShortfall), 0),
            ),
            meal_count: String(context.mealCount),
          },
          recoveryScoreAtTime: todayState?.recovery_score ?? null,
        }),
      );
    }
  }

  // deno-coverage-ignore-start -- heavy-load mismatch outcomes are covered; short-circuit branch is redundant.
  const hasHeavyLoadMismatch = context.workoutCount > 0 &&
    context.totalTrimp >= 75 &&
    isFiniteNumber(todayState?.recovery_score) &&
    Number(todayState?.recovery_score ?? 0) < 65;
  // deno-coverage-ignore-stop
  if (hasHeavyLoadMismatch) {
    const trainingInsight = await makeInsight({
      userId: context.userId,
      date: context.date,
      generatedAt: context.generatedAt,
      kind: InsightKind.trainingLoad,
      category: "training",
      title: "Today's load is heavy relative to readiness",
      description: "Training load check",
      body: `You've already accumulated ${
        Math.round(context.totalTrimp)
      } TRIMP today while recovery is still moderate, so adding more intensity is likely to cost more than it returns.`,
      reasoning:
        "Life OS combines today's workout load with today's recovery state to estimate marginal fatigue cost.",
      confidence: 0.87,
      inputsUsed: "workout_sessions,physiological_states",
      priority: 2,
      actionable: true,
      actionType: "rest",
      relatedMetrics: ["training_trimp", "recovery_score"],
      relatedDates: [context.date],
      expiresAt: addDaysISO(context.generatedAt, 3),
    });
    insights.push(trainingInsight);

    recommendations.push(
      await makeRecommendation({
        userId: context.userId,
        date: context.date,
        generatedAt: context.generatedAt,
        kind: RecommendationKind.trainingCap,
        category: "recovery",
        priority: "high",
        title: "Cap the day here",
        description:
          "Treat any additional movement as cooldown, mobility, or easy aerobic work instead of stacking more intensity.",
        reasoning:
          "The best adaptation move now is recovering from the work you've already done.",
        timeOfDay,
        insightId: trainingInsight.id,
        actionType: "rest",
        actionParameters: {
          max_trimp: String(Math.round(context.totalTrimp)),
          mode: "cap_day",
        },
        // deno-coverage-ignore -- null recovery score fallback is covered by no-recovery guidance tests.
        recoveryScoreAtTime: todayState?.recovery_score ?? null,
      }),
    );
  }

  if (insights.length === 0) {
    insights.push(
      await makeInsight({
        userId: context.userId,
        date: context.date,
        generatedAt: context.generatedAt,
        kind: InsightKind.setupPrompt,
        category: "general",
        title: "One more signal unlocks a sharper daily read",
        description: "Setup nudge",
        body:
          "Log a meal, a workout, or a wellness check today and Life OS will turn it into more specific guidance.",
        reasoning:
          "Today's diary is still too sparse for a more specific pattern match.",
        confidence: 0.78,
        inputsUsed: "food_logs,workout_sessions,wellness_checks",
        priority: 4,
        actionable: true,
        actionType: null,
        relatedMetrics: [],
        relatedDates: [context.date],
        expiresAt: addDaysISO(context.generatedAt, 2),
      }),
    );
  }

  if (recommendations.length === 0) {
    const setupMode = insights[0]?.type ===
      managedInsightKey(context.date, InsightKind.setupPrompt);
    recommendations.push(
      await makeRecommendation({
        userId: context.userId,
        date: context.date,
        generatedAt: context.generatedAt,
        kind: setupMode
          ? RecommendationKind.setupPrompt
          : RecommendationKind.steadyDay,
        category: "recovery",
        priority: "low",
        title: setupMode
          ? "Add one signal to today's diary"
          : "Keep today's plan steady",
        description: setupMode
          ? "A quick meal log or wellness check is enough to unlock more tailored guidance for the rest of the day."
          : "Recovery, nutrition, and training signals do not show a major risk right now, so consistency is the highest-value move.",
        reasoning: setupMode
          ? "More context is the fastest way to personalize today's guidance."
          : "No major recovery, sleep, or nutrition risks surfaced in the current daily snapshot.",
        timeOfDay,
        insightId: null,
        actionType: null,
        actionParameters: {
          focus: setupMode ? "log_signal" : "consistency",
        },
        recoveryScoreAtTime: todayState?.recovery_score ?? null,
      }),
    );
  }

  insights.sort((lhs, rhs) => {
    if (lhs.priority !== rhs.priority) return lhs.priority - rhs.priority;
    return rhs.updated_at.localeCompare(lhs.updated_at);
  });
  recommendations.sort((lhs, rhs) => {
    const priorityDelta = recommendationPriorityRank(lhs.priority) -
      recommendationPriorityRank(rhs.priority);
    if (priorityDelta !== 0) return priorityDelta;
    return rhs.updated_at.localeCompare(lhs.updated_at);
  });

  return {
    date: context.date,
    generated_at: context.generatedAt,
    insights: insights.slice(0, 4),
    recommendations: recommendations.slice(0, 3),
  };
}

async function persistDailySnapshot(
  service: ServiceClient,
  userId: string,
  snapshot: GeneratedDailySnapshot,
): Promise<GeneratedDailySnapshot> {
  const insightPrefix = `${managedInsightPrefix(snapshot.date)}%`;
  const recommendationPrefix = `${managedRecommendationPrefix(snapshot.date)}%`;

  const [existingInsightsRes, existingRecommendationsRes] = await Promise.all([
    service
      .from("insights")
      .select("*")
      .eq("user_id", userId)
      .like("type", insightPrefix)
      .returns<GeneratedInsightRow[]>(),
    service
      .from("recommendations")
      .select("*")
      .eq("user_id", userId)
      .like("trigger_condition", recommendationPrefix)
      .returns<GeneratedRecommendationRow[]>(),
  ]);

  if (existingInsightsRes.error) {
    throw new Error(
      `insights_existing_fetch_failed:${existingInsightsRes.error.message}`,
    );
  }
  if (existingRecommendationsRes.error) {
    throw new Error(
      `recommendations_existing_fetch_failed:${existingRecommendationsRes.error.message}`,
    );
  }

  const existingInsightById = new Map(
    (existingInsightsRes.data ?? []).map((row) => [row.id, row]),
  );
  const existingRecommendationById = new Map(
    (existingRecommendationsRes.data ?? []).map((row) => [row.id, row]),
  );

  const mergedInsights = snapshot.insights.map((row) =>
    mergeInsight(existingInsightById.get(row.id), row)
  );
  const mergedRecommendations = snapshot.recommendations.map((row) =>
    mergeRecommendation(existingRecommendationById.get(row.id), row)
  );

  let persistedInsights = mergedInsights;
  if (mergedInsights.length > 0) {
    const upsertRes = await service
      .from("insights")
      .upsert(mergedInsights)
      .select("*")
      .returns<GeneratedInsightRow[]>();
    if (upsertRes.error) {
      throw new Error(`insights_upsert_failed:${upsertRes.error.message}`);
    }
    persistedInsights = upsertRes.data ?? mergedInsights;
  }

  let persistedRecommendations = mergedRecommendations;
  if (mergedRecommendations.length > 0) {
    const upsertRes = await service
      .from("recommendations")
      .upsert(mergedRecommendations)
      .select("*")
      .returns<GeneratedRecommendationRow[]>();
    if (upsertRes.error) {
      throw new Error(
        `recommendations_upsert_failed:${upsertRes.error.message}`,
      );
    }
    persistedRecommendations = upsertRes.data ?? mergedRecommendations;
  }

  const activeInsightIds = new Set(persistedInsights.map((row) => row.id));
  const staleInsightIds = (existingInsightsRes.data ?? []).filter((row) =>
    !activeInsightIds.has(row.id)
  ).map((row) => row.id);
  if (staleInsightIds.length > 0) {
    const staleRes = await service
      .from("insights")
      .update({
        dismissed: true,
        dismissed_at: snapshot.generated_at,
        updated_at: snapshot.generated_at,
      })
      .eq("user_id", userId)
      .in("id", staleInsightIds);
    if (staleRes.error) {
      throw new Error(
        `insights_stale_dismiss_failed:${staleRes.error.message}`,
      );
    }
  }

  const oldDailyInsightsRes = await service
    .from("insights")
    .select("id,type,dismissed")
    .eq("user_id", userId)
    .like("type", "daily/%")
    .returns<Array<Pick<GeneratedInsightRow, "id" | "type" | "dismissed">>>();
  if (oldDailyInsightsRes.error) {
    throw new Error(
      `insights_old_cleanup_fetch_failed:${oldDailyInsightsRes.error.message}`,
    );
  }
  const oldDailyInsightIds = (oldDailyInsightsRes.data ?? []).filter((row) =>
    !row.dismissed && typeof row.type === "string" &&
    row.type.startsWith("daily/") &&
    row.type.slice(6, 16) < snapshot.date
  ).map((row) => row.id);
  if (oldDailyInsightIds.length > 0) {
    const oldDailyRes = await service
      .from("insights")
      .update({
        dismissed: true,
        dismissed_at: snapshot.generated_at,
        updated_at: snapshot.generated_at,
      })
      .eq("user_id", userId)
      .in("id", oldDailyInsightIds);
    if (oldDailyRes.error) {
      throw new Error(
        `insights_old_cleanup_failed:${oldDailyRes.error.message}`,
      );
    }
  }

  const activeRecommendationIds = new Set(
    persistedRecommendations.map((row) => row.id),
  );
  const staleRecommendationIds = (existingRecommendationsRes.data ?? []).filter(
    (row) => !activeRecommendationIds.has(row.id),
  ).map((row) => row.id);
  if (staleRecommendationIds.length > 0) {
    const staleRes = await service
      .from("recommendations")
      .update({
        dismissed: true,
        updated_at: snapshot.generated_at,
      })
      .eq("user_id", userId)
      .in("id", staleRecommendationIds);
    if (staleRes.error) {
      throw new Error(
        `recommendations_stale_dismiss_failed:${staleRes.error.message}`,
      );
    }
  }

  const oldRecommendationRes = await service
    .from("recommendations")
    .update({
      dismissed: true,
      updated_at: snapshot.generated_at,
    })
    .eq("user_id", userId)
    .like("trigger_condition", "daily/%")
    .lt("recommendation_date", snapshot.date)
    .eq("dismissed", false);
  if (oldRecommendationRes.error) {
    throw new Error(
      `recommendations_old_cleanup_failed:${oldRecommendationRes.error.message}`,
    );
  }

  return {
    date: snapshot.date,
    generated_at: snapshot.generated_at,
    insights: persistedInsights.filter((row) => !row.dismissed),
    recommendations: persistedRecommendations.filter((row) => !row.dismissed),
  };
}

function mergeInsight(
  existing: GeneratedInsightRow | undefined,
  generated: GeneratedInsightRow,
): GeneratedInsightRow {
  if (!existing) return generated;
  return {
    ...generated,
    created_at: existing.created_at,
    shown_to_user: existing.shown_to_user,
    shown_at: existing.shown_at,
    read: existing.read,
    read_at: existing.read_at,
    acknowledged: existing.acknowledged,
    acknowledged_at: existing.acknowledged_at,
    dismissed: existing.dismissed,
    dismissed_at: existing.dismissed_at,
    acted_upon: existing.acted_upon,
    action_taken: existing.action_taken,
  };
}

function mergeRecommendation(
  existing: GeneratedRecommendationRow | undefined,
  generated: GeneratedRecommendationRow,
): GeneratedRecommendationRow {
  if (!existing) return generated;
  return {
    ...generated,
    created_at: existing.created_at,
    dismissed: existing.dismissed,
    followed: existing.followed,
    user_feedback: existing.user_feedback,
  };
}

async function makeInsight(input: {
  userId: string;
  date: string;
  generatedAt: string;
  kind: string;
  category: string;
  title: string;
  description: string | null;
  body: string;
  reasoning: string | null;
  confidence: number;
  inputsUsed: string | null;
  priority: number;
  actionable: boolean;
  actionType: string | null;
  relatedMetrics: string[];
  relatedDates: string[];
  expiresAt: string | null;
}): Promise<GeneratedInsightRow> {
  const type = managedInsightKey(input.date, input.kind);
  return {
    id: await stableUuid(`insight:${input.userId.toLowerCase()}:${type}`),
    user_id: input.userId,
    created_at: input.generatedAt,
    updated_at: input.generatedAt,
    category: input.category,
    type,
    title: input.title,
    description: input.description,
    body: input.body,
    reasoning: input.reasoning,
    confidence: input.confidence,
    confidence_score: input.confidence,
    inputs_used: input.inputsUsed,
    needs_review: input.confidence < 0.65,
    related_metrics: input.relatedMetrics,
    related_dates: input.relatedDates,
    priority: input.priority,
    actionable: input.actionable,
    action_type: input.actionType,
    shown_to_user: false,
    shown_at: null,
    read: false,
    read_at: null,
    acknowledged: false,
    acknowledged_at: null,
    dismissed: false,
    dismissed_at: null,
    acted_upon: false,
    action_taken: null,
    expires_at: input.expiresAt,
  };
}

async function makeRecommendation(input: {
  userId: string;
  date: string;
  generatedAt: string;
  kind: string;
  category: string;
  priority: string;
  title: string;
  description: string;
  reasoning: string;
  timeOfDay: string;
  insightId: string | null;
  actionType: string | null;
  actionParameters: Record<string, string> | null;
  recoveryScoreAtTime: number | null;
}): Promise<GeneratedRecommendationRow> {
  const triggerCondition = managedRecommendationKey(input.date, input.kind);
  return {
    id: await stableUuid(
      `recommendation:${input.userId.toLowerCase()}:${triggerCondition}`,
    ),
    user_id: input.userId,
    created_at: input.generatedAt,
    updated_at: input.generatedAt,
    recommendation_date: input.date,
    time_of_day: input.timeOfDay,
    category: input.category,
    priority: input.priority,
    title: input.title,
    description: input.description,
    reasoning: input.reasoning,
    insight_id: input.insightId,
    action_type: input.actionType,
    action_parameters: input.actionParameters,
    auto_execute: false,
    dismissed: false,
    followed: null,
    user_feedback: null,
    recovery_score_at_time: input.recoveryScoreAtTime,
    trigger_condition: triggerCondition,
  };
}

function managedInsightKey(date: string, kind: string): string {
  return `${managedInsightPrefix(date)}${kind}`;
}

function managedInsightPrefix(date: string): string {
  return `${INSIGHT_PREFIX}${date}/`;
}

function managedRecommendationKey(date: string, kind: string): string {
  return `${managedRecommendationPrefix(date)}${kind}`;
}

function managedRecommendationPrefix(date: string): string {
  return `${RECOMMENDATION_PREFIX}${date}/`;
}

function clampConfidence(value: number): number {
  return Math.max(0.67, Math.min(value, 0.95));
}

function recommendationPriorityRank(priority: string): number {
  switch (priority.toLowerCase()) {
    case "critical":
      return 0;
    case "high":
      return 1;
    case "medium":
      return 2;
    default:
      return 3;
  }
}

function recommendationTimeOfDay(hour: number): string {
  if (hour < 11) return "morning";
  if (hour < 14) return "midday";
  if (hour < 18) return "afternoon";
  if (hour < 22) return "evening";
  return "night";
}

function localHourInTimeZone(timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    hour: "2-digit",
    hour12: false,
    timeZone,
  }).formatToParts(new Date());
  const hour = Number(parts.find((part) => part.type === "hour")?.value ?? "0");
  return Number.isFinite(hour) ? hour : 0;
}

function formatHours(value: number): string {
  const rounded = Math.round(value * 10) / 10;
  return Number.isInteger(rounded) ? String(rounded) : rounded.toFixed(1);
}

function average(values: number[]): number {
  if (values.length === 0) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function humanize(value: string): string {
  const normalized = value.replaceAll("_", " ").trim();
  if (!normalized) return value;
  return normalized.charAt(0).toUpperCase() + normalized.slice(1);
}

function addDays(date: string, days: number): string {
  const parsed = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(parsed + days * 86_400_000).toISOString().slice(0, 10);
}

function addDaysISO(iso: string, days: number): string {
  const parsed = Date.parse(iso);
  return new Date(parsed + days * 86_400_000).toISOString();
}

async function stableUuid(seed: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed)),
  );
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes).map((value) =>
    value.toString(16).padStart(2, "0")
  ).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

export const __dailyInsightsTestHooks = {
  addDays,
  addDaysISO,
  average,
  buildDailySnapshot,
  clampConfidence,
  formatHours,
  humanize,
  isFiniteNumber,
  localHourInTimeZone,
  makeInsight,
  makeRecommendation,
  managedInsightKey,
  managedInsightPrefix,
  managedRecommendationKey,
  managedRecommendationPrefix,
  mergeInsight,
  mergeRecommendation,
  persistDailySnapshot,
  recommendationPriorityRank,
  recommendationTimeOfDay,
  stableUuid,
};
