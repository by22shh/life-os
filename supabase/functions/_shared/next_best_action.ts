export type MealType = "breakfast" | "lunch" | "snack" | "dinner";

export type DiaryNextBestAction =
  | {
    type: "open_diary";
    label_copy_id: "diary.review_required" | "diary.view_day";
    payload: { date: string; section?: string };
  }
  | {
    type: "supplement_taken";
    label_copy_id: "supplements.log_primary";
    payload: { supplement_name: string; scheduled_time: string };
  }
  | {
    type: "log_meal";
    label_copy_id: "nutrition.diary_log_primary";
    payload: { meal_type: MealType };
  }
  | {
    type: "open_sleep";
    label_copy_id: "sleep.connect_primary";
    payload: Record<string, never>;
  }
  | {
    type: "insight_acknowledge";
    label_copy_id: "insights.acknowledge";
    payload: { insight_id: string };
  };

export type WatchNextBestAction = DiaryNextBestAction | {
  type: "open_on_iphone";
  label_copy_id: "global.open_on_iphone";
  payload: { deep_link: string };
};

export interface SupplementScheduleEntry {
  time: string;
  supplements: Array<{ name: string; taken: boolean }>;
}

export function determineNextBestAction(input: {
  date: string;
  needsReview: boolean;
  lowConfidence: boolean;
  supplementDueSoon: { supplement_name: string; scheduled_time: string } | null;
  nutritionCurrentCalories: number;
  nutritionTargetCalories: number | null;
  lastMealAt: string | null;
  sleepNeedsPermission: boolean;
  unreadInsightId: string | null;
  isToday: boolean;
  timezone: string;
}): DiaryNextBestAction {
  if (input.needsReview) {
    return {
      type: "open_diary",
      label_copy_id: "diary.review_required",
      payload: { date: input.date, section: "needs_review" },
    };
  }

  if (input.lowConfidence) {
    return {
      type: "open_diary",
      label_copy_id: "diary.view_day",
      payload: { date: input.date },
    };
  }

  if (input.supplementDueSoon) {
    return {
      type: "supplement_taken",
      label_copy_id: "supplements.log_primary",
      payload: {
        supplement_name: input.supplementDueSoon.supplement_name,
        scheduled_time: input.supplementDueSoon.scheduled_time,
      },
    };
  }

  const noMealFor4h = input.lastMealAt == null
    ? true
    : (Date.now() - Date.parse(input.lastMealAt)) >= 4 * 60 * 60 * 1000;
  const underTarget = input.nutritionTargetCalories != null &&
    input.nutritionCurrentCalories < input.nutritionTargetCalories;

  if (input.isToday && underTarget && noMealFor4h) {
    return {
      type: "log_meal",
      label_copy_id: "nutrition.diary_log_primary",
      payload: { meal_type: suggestedMealType(input.timezone) },
    };
  }

  if (input.sleepNeedsPermission) {
    return {
      type: "open_sleep",
      label_copy_id: "sleep.connect_primary",
      payload: {},
    };
  }

  if (input.unreadInsightId) {
    return {
      type: "insight_acknowledge",
      label_copy_id: "insights.acknowledge",
      payload: { insight_id: input.unreadInsightId },
    };
  }

  return {
    type: "open_diary",
    label_copy_id: "diary.view_day",
    payload: { date: input.date },
  };
}

export function dueSupplementInWindow(
  schedule: SupplementScheduleEntry[],
  now: Date,
  timezone: string,
): { supplement_name: string; scheduled_time: string } | null {
  const nowMinutes = localMinutesOfDay(now, timezone);

  for (const slot of schedule) {
    const slotMinutes = parseWallClockMinutes(slot.time);
    if (slotMinutes == null) continue;
    const delta = slotMinutes - nowMinutes;
    if (delta < 0 || delta > 120) continue;

    const dueSupplement = slot.supplements.find((item) => !item.taken);
    if (dueSupplement) {
      return {
        supplement_name: dueSupplement.name,
        scheduled_time: slot.time,
      };
    }
  }

  return null;
}

export function dueSupplementsSummary(
  schedule: SupplementScheduleEntry[],
  now: Date,
  timezone: string,
): { time: string; count: number } | null {
  const nowMinutes = localMinutesOfDay(now, timezone);

  for (const slot of schedule) {
    const slotMinutes = parseWallClockMinutes(slot.time);
    if (slotMinutes == null) continue;
    const delta = slotMinutes - nowMinutes;
    if (delta < 0 || delta > 120) continue;

    const dueCount = slot.supplements.filter((item) => !item.taken).length;
    if (dueCount > 0) {
      return { time: slot.time, count: dueCount };
    }
  }

  return null;
}

export function suggestedMealType(timezone: string): MealType {
  const hour = Number(
    new Intl.DateTimeFormat("en-US", {
      hour: "2-digit",
      hour12: false,
      timeZone: timezone,
    }).format(new Date()),
  );

  if (hour >= 5 && hour <= 10) return "breakfast";
  if (hour >= 11 && hour <= 14) return "lunch";
  if (hour >= 15 && hour <= 17) return "snack";
  if (hour >= 18 && hour <= 22) return "dinner";
  return "snack";
}

export function adaptNextBestActionForWatch(input: {
  action: DiaryNextBestAction;
  date: string;
  lowConfidence: boolean;
}): WatchNextBestAction {
  if (input.lowConfidence) {
    return openOnIPhone(`lifeos://diary?date=${input.date}`);
  }

  switch (input.action.type) {
    case "supplement_taken":
    case "insight_acknowledge":
      return input.action;
    case "open_sleep":
      return openOnIPhone(`lifeos://sleep?date=${input.date}`);
    case "log_meal":
      return openOnIPhone(`lifeos://nutrition?date=${input.date}`);
    case "open_diary":
      return openOnIPhone(`lifeos://diary?date=${input.action.payload.date}`);
  }
}

export function computeNutritionAdherencePercent(input: {
  currentCalories: number;
  targetCalories: number | null;
  currentProteinG: number;
  targetProteinG: number | null;
}): number | null {
  const ratios = [
    boundedCompletionRatio(input.currentCalories, input.targetCalories),
    boundedCompletionRatio(input.currentProteinG, input.targetProteinG),
  ].filter((value): value is number => value != null);

  if (ratios.length === 0) return null;
  const average = ratios.reduce((sum, value) => sum + value, 0) / ratios.length;
  return Math.round(average * 100);
}

function openOnIPhone(deepLink: string): WatchNextBestAction {
  return {
    type: "open_on_iphone",
    label_copy_id: "global.open_on_iphone",
    payload: { deep_link: deepLink },
  };
}

function boundedCompletionRatio(
  current: number,
  target: number | null,
): number | null {
  if (target == null || !Number.isFinite(target) || target <= 0) return null;
  if (!Number.isFinite(current) || current <= 0) return 0;
  return Math.max(0, Math.min(current / target, 1));
}

function localMinutesOfDay(now: Date, timezone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: timezone,
  }).formatToParts(now);
  const hour = Number(parts.find((part) => part.type === "hour")?.value ?? "0");
  const minute = Number(
    parts.find((part) => part.type === "minute")?.value ?? "0",
  );
  return (hour * 60) + minute;
}

function parseWallClockMinutes(value: string): number | null {
  const [hourRaw, minuteRaw] = value.split(":");
  const hour = Number(hourRaw);
  const minute = Number(minuteRaw);
  if (
    !Number.isInteger(hour) || !Number.isInteger(minute) ||
    hour < 0 || hour > 23 ||
    minute < 0 || minute > 59
  ) {
    return null;
  }
  return (hour * 60) + minute;
}
