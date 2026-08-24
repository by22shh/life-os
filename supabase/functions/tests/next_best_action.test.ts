import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";

import {
  adaptNextBestActionForWatch,
  computeNutritionAdherencePercent,
  determineNextBestAction,
  dueSupplementInWindow,
  dueSupplementsSummary,
  suggestedMealType,
} from "../_shared/next_best_action.ts";

async function withMockedDate(
  isoTimestamp: string,
  fn: () => Promise<void> | void,
): Promise<void> {
  const RealDate = Date;
  const fixedTime = new RealDate(isoTimestamp).getTime();

  class MockDate extends RealDate {
    constructor(value?: ConstructorParameters<typeof Date>[0]) {
      super(value ?? fixedTime);
    }

    static override now() {
      return fixedTime;
    }

    static override parse(value: string) {
      return RealDate.parse(value);
    }

    static override UTC(...args: Parameters<typeof Date.UTC>) {
      return RealDate.UTC(...args);
    }
  }

  globalThis.Date = MockDate as DateConstructor;
  try {
    await fn();
  } finally {
    globalThis.Date = RealDate;
  }
}

Deno.test("determineNextBestAction prioritizes due supplements before insights", () => {
  const action = determineNextBestAction({
    date: "2026-02-24",
    needsReview: false,
    lowConfidence: false,
    supplementDueSoon: {
      supplement_name: "Magnesium Glycinate",
      scheduled_time: "21:00",
    },
    nutritionCurrentCalories: 1200,
    nutritionTargetCalories: 2000,
    lastMealAt: "2026-02-24T06:00:00.000Z",
    sleepNeedsPermission: false,
    unreadInsightId: crypto.randomUUID(),
    isToday: true,
    timezone: "UTC",
  });

  assertEquals(action, {
    type: "supplement_taken",
    label_copy_id: "supplements.log_primary",
    payload: {
      supplement_name: "Magnesium Glycinate",
      scheduled_time: "21:00",
    },
  });
});

Deno.test("adaptNextBestActionForWatch preserves lightweight actions and routes context actions to iPhone", () => {
  const insightAction = adaptNextBestActionForWatch({
    action: {
      type: "insight_acknowledge",
      label_copy_id: "insights.acknowledge",
      payload: { insight_id: "insight-1" },
    },
    date: "2026-02-24",
    lowConfidence: false,
  });
  assertEquals(insightAction, {
    type: "insight_acknowledge",
    label_copy_id: "insights.acknowledge",
    payload: { insight_id: "insight-1" },
  });

  const mealAction = adaptNextBestActionForWatch({
    action: {
      type: "log_meal",
      label_copy_id: "nutrition.diary_log_primary",
      payload: { meal_type: "lunch" },
    },
    date: "2026-02-24",
    lowConfidence: false,
  });
  assertEquals(mealAction, {
    type: "open_on_iphone",
    label_copy_id: "global.open_on_iphone",
    payload: { deep_link: "lifeos://nutrition?date=2026-02-24" },
  });
});

Deno.test("adaptNextBestActionForWatch forces open_on_iphone when confidence is low", () => {
  const action = adaptNextBestActionForWatch({
    action: {
      type: "supplement_taken",
      label_copy_id: "supplements.log_primary",
      payload: {
        supplement_name: "Vitamin D3",
        scheduled_time: "08:00",
      },
    },
    date: "2026-02-24",
    lowConfidence: true,
  });

  assertEquals(action, {
    type: "open_on_iphone",
    label_copy_id: "global.open_on_iphone",
    payload: { deep_link: "lifeos://diary?date=2026-02-24" },
  });
});

Deno.test("due supplement helpers return the first matching due slot and untaken count", () => {
  const schedule = [
    {
      time: "07:00",
      supplements: [{ name: "Vitamin D3", taken: true }],
    },
    {
      time: "08:30",
      supplements: [
        { name: "Magnesium", taken: false },
        { name: "Creatine", taken: false },
      ],
    },
    {
      time: "22:00",
      supplements: [{ name: "Glycine", taken: false }],
    },
  ];
  const now = new Date("2026-02-24T07:15:00.000Z");

  assertEquals(dueSupplementInWindow(schedule, now, "UTC"), {
    supplement_name: "Magnesium",
    scheduled_time: "08:30",
  });
  assertEquals(dueSupplementsSummary(schedule, now, "UTC"), {
    time: "08:30",
    count: 2,
  });
});

Deno.test("computeNutritionAdherencePercent averages calories and protein progress", () => {
  assertEquals(
    computeNutritionAdherencePercent({
      currentCalories: 1500,
      targetCalories: 2000,
      currentProteinG: 120,
      targetProteinG: 160,
    }),
    75,
  );
  assertEquals(
    computeNutritionAdherencePercent({
      currentCalories: 1800,
      targetCalories: null,
      currentProteinG: 90,
      targetProteinG: 120,
    }),
    75,
  );
  assertEquals(
    computeNutritionAdherencePercent({
      currentCalories: 0,
      targetCalories: null,
      currentProteinG: 0,
      targetProteinG: null,
    }),
    null,
  );
});

Deno.test("determineNextBestAction handles review, low-confidence, sleep, insight, and fallback branches", () => {
  assertEquals(
    determineNextBestAction({
      date: "2026-02-24",
      needsReview: true,
      lowConfidence: false,
      supplementDueSoon: null,
      nutritionCurrentCalories: 1500,
      nutritionTargetCalories: 2000,
      lastMealAt: null,
      sleepNeedsPermission: false,
      unreadInsightId: "insight-1",
      isToday: true,
      timezone: "UTC",
    }),
    {
      type: "open_diary",
      label_copy_id: "diary.review_required",
      payload: { date: "2026-02-24", section: "needs_review" },
    },
  );

  assertEquals(
    determineNextBestAction({
      date: "2026-02-24",
      needsReview: false,
      lowConfidence: true,
      supplementDueSoon: null,
      nutritionCurrentCalories: 1500,
      nutritionTargetCalories: 2000,
      lastMealAt: null,
      sleepNeedsPermission: false,
      unreadInsightId: "insight-1",
      isToday: true,
      timezone: "UTC",
    }),
    {
      type: "open_diary",
      label_copy_id: "diary.view_day",
      payload: { date: "2026-02-24" },
    },
  );

  assertEquals(
    determineNextBestAction({
      date: "2026-02-24",
      needsReview: false,
      lowConfidence: false,
      supplementDueSoon: null,
      nutritionCurrentCalories: 2100,
      nutritionTargetCalories: 2000,
      lastMealAt: "2026-02-24T10:00:00.000Z",
      sleepNeedsPermission: true,
      unreadInsightId: "insight-1",
      isToday: true,
      timezone: "UTC",
    }),
    {
      type: "open_sleep",
      label_copy_id: "sleep.connect_primary",
      payload: {},
    },
  );

  assertEquals(
    determineNextBestAction({
      date: "2026-02-24",
      needsReview: false,
      lowConfidence: false,
      supplementDueSoon: null,
      nutritionCurrentCalories: 2100,
      nutritionTargetCalories: 2000,
      lastMealAt: "2026-02-24T10:00:00.000Z",
      sleepNeedsPermission: false,
      unreadInsightId: "insight-1",
      isToday: true,
      timezone: "UTC",
    }),
    {
      type: "insight_acknowledge",
      label_copy_id: "insights.acknowledge",
      payload: { insight_id: "insight-1" },
    },
  );

  assertEquals(
    determineNextBestAction({
      date: "2026-02-24",
      needsReview: false,
      lowConfidence: false,
      supplementDueSoon: null,
      nutritionCurrentCalories: 2100,
      nutritionTargetCalories: 2000,
      lastMealAt: "2026-02-24T10:00:00.000Z",
      sleepNeedsPermission: false,
      unreadInsightId: null,
      isToday: false,
      timezone: "UTC",
    }),
    {
      type: "open_diary",
      label_copy_id: "diary.view_day",
      payload: { date: "2026-02-24" },
    },
  );
});

Deno.test("determineNextBestAction suggests meal type when today is under target and meal is overdue", async () => {
  await withMockedDate("2026-02-24T12:15:00.000Z", () => {
    const action = determineNextBestAction({
      date: "2026-02-24",
      needsReview: false,
      lowConfidence: false,
      supplementDueSoon: null,
      nutritionCurrentCalories: 900,
      nutritionTargetCalories: 2000,
      lastMealAt: "2026-02-24T07:30:00.000Z",
      sleepNeedsPermission: false,
      unreadInsightId: null,
      isToday: true,
      timezone: "UTC",
    });

    assertEquals(action, {
      type: "log_meal",
      label_copy_id: "nutrition.diary_log_primary",
      payload: { meal_type: "lunch" },
    });
  });
});

Deno.test("determineNextBestAction does not prompt another meal right after eating", async () => {
  await withMockedDate("2026-02-24T12:00:00.000Z", () => {
    const action = determineNextBestAction({
      date: "2026-02-24",
      needsReview: false,
      lowConfidence: false,
      supplementDueSoon: null,
      nutritionCurrentCalories: 900,
      nutritionTargetCalories: 2200,
      lastMealAt: "2026-02-24T10:30:00.000Z",
      sleepNeedsPermission: false,
      unreadInsightId: "insight-after-meal",
      isToday: true,
      timezone: "UTC",
    });

    assertEquals(action, {
      type: "insight_acknowledge",
      label_copy_id: "insights.acknowledge",
      payload: { insight_id: "insight-after-meal" },
    });
  });
});

Deno.test("due supplement helpers ignore invalid, past, and fully taken slots", () => {
  const schedule = [
    {
      time: "oops",
      supplements: [{ name: "Vitamin C", taken: false }],
    },
    {
      time: "06:00",
      supplements: [{ name: "Magnesium", taken: false }],
    },
    {
      time: "08:30",
      supplements: [{ name: "Creatine", taken: true }],
    },
    {
      time: "11:30",
      supplements: [{ name: "Glycine", taken: false }],
    },
  ];
  const now = new Date("2026-02-24T08:00:00.000Z");

  assertEquals(dueSupplementInWindow(schedule, now, "UTC"), null);
  assertEquals(dueSupplementsSummary(schedule, now, "UTC"), null);
});

Deno.test("suggestedMealType maps time buckets to breakfast lunch snack and dinner", async () => {
  await withMockedDate("2026-02-24T06:00:00.000Z", () => {
    assertEquals(suggestedMealType("UTC"), "breakfast");
  });
  await withMockedDate("2026-02-24T12:00:00.000Z", () => {
    assertEquals(suggestedMealType("UTC"), "lunch");
  });
  await withMockedDate("2026-02-24T16:00:00.000Z", () => {
    assertEquals(suggestedMealType("UTC"), "snack");
  });
  await withMockedDate("2026-02-24T19:00:00.000Z", () => {
    assertEquals(suggestedMealType("UTC"), "dinner");
  });
  await withMockedDate("2026-02-24T02:00:00.000Z", () => {
    assertEquals(suggestedMealType("UTC"), "snack");
  });
});

Deno.test("adaptNextBestActionForWatch routes sleep and diary actions to iPhone deep links", () => {
  const sleepAction = adaptNextBestActionForWatch({
    action: {
      type: "open_sleep",
      label_copy_id: "sleep.connect_primary",
      payload: {},
    },
    date: "2026-02-24",
    lowConfidence: false,
  });
  assertEquals(sleepAction, {
    type: "open_on_iphone",
    label_copy_id: "global.open_on_iphone",
    payload: { deep_link: "lifeos://sleep?date=2026-02-24" },
  });

  const diaryAction = adaptNextBestActionForWatch({
    action: {
      type: "open_diary",
      label_copy_id: "diary.view_day",
      payload: { date: "2026-02-25" },
    },
    date: "2026-02-24",
    lowConfidence: false,
  });
  assertEquals(diaryAction, {
    type: "open_on_iphone",
    label_copy_id: "global.open_on_iphone",
    payload: { deep_link: "lifeos://diary?date=2026-02-25" },
  });
});

Deno.test("computeNutritionAdherencePercent clamps over-target progress and zeros invalid current values", () => {
  assertEquals(
    computeNutritionAdherencePercent({
      currentCalories: 5000,
      targetCalories: 2000,
      currentProteinG: 300,
      targetProteinG: 150,
    }),
    100,
  );
  assertEquals(
    computeNutritionAdherencePercent({
      currentCalories: Number.NaN,
      targetCalories: 2000,
      currentProteinG: -5,
      targetProteinG: 150,
    }),
    0,
  );
});
