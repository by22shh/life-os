import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";
import {
  DEFAULT_FEATURE_FLAGS,
  FEATURE_FLAG_CACHE_TTL_SECONDS,
  isFeatureFlagEnabled,
  mergeResolvedFeatureFlags,
} from "../_shared/feature_flags.ts";
import {
  enumerateLocalDates,
  isoFromDateOnly,
  localDateToday,
  parseLocalDateParam,
  parseLocalDateRange,
  parseRequiredLocalDate,
  pathnameTail,
  safeTimeZone,
} from "../_shared/date_range.ts";
import {
  buildSupplementDayResult,
  isSupplementScheduledOnDate,
  normalizeDbTime,
  normalizedScheduledTimes,
  supplementStatus,
} from "../_shared/supplements.ts";
import { computeMedicalScanScheduledDeletionAt } from "../_shared/medical_scan_privacy.ts";
import { handleCorsPreflight } from "../_shared/user_context.ts";

Deno.test("date range helpers parse, cap, enumerate, and normalize routes", () => {
  const request = new Request(
    "https://edge.test/api-diary/calendar?from=2026-02-01&to=2026-02-03&date=2026-02-02&bad=20260202",
  );
  const reversedRange = new Request(
    "https://edge.test/api-diary/calendar?from=2026-02-03&to=2026-02-01",
  );
  const invalidRange = new Request(
    "https://edge.test/api-diary/calendar?from=2026-02-30&to=2026-03-01",
  );
  const blankFromRange = new Request(
    "https://edge.test/api-diary/calendar?from=%20%20&to=2026-03-01",
  );
  const emptyRequest = new Request("https://edge.test/plain/path");

  assertEquals(parseLocalDateParam(request, "date"), "2026-02-02");
  assertEquals(parseLocalDateParam(request, "bad"), null);
  assertEquals(parseLocalDateParam(emptyRequest, "date"), null);
  assertEquals(parseRequiredLocalDate(request, "date"), {
    from: "2026-02-02",
    to: "2026-02-02",
    days: 1,
  });
  assertEquals(parseRequiredLocalDate(emptyRequest, "date"), null);
  assertEquals(parseLocalDateRange(request, 7), {
    from: "2026-02-01",
    to: "2026-02-03",
    days: 3,
  });
  assertEquals(parseLocalDateRange(request, 2), null);
  assertEquals(parseLocalDateRange(blankFromRange, 7), null);
  assertEquals(parseLocalDateRange(reversedRange, 7), null);
  assertEquals(parseLocalDateRange(invalidRange, 7), null);
  assertEquals(
    parseLocalDateRange(
      new Request("https://edge.test/api-diary/calendar?from=2026-02-01"),
      7,
    ),
    null,
  );
  assertEquals(enumerateLocalDates("2026-02-01", "2026-02-03"), [
    "2026-02-01",
    "2026-02-02",
    "2026-02-03",
  ]);
  assertEquals(safeTimeZone(null), "UTC");
  assertEquals(safeTimeZone(undefined), "UTC");
  assertEquals(safeTimeZone(""), "UTC");
  assertEquals(safeTimeZone("Definitely/Not_A_Timezone"), "UTC");
  assertEquals(localDateToday("UTC").length, 10);
  assertEquals(pathnameTail("/functions/v1/api-workouts/session-id/undo"), [
    "session-id",
    "undo",
  ]);
  assertEquals(pathnameTail("/plain/path"), ["plain", "path"]);
  assertEquals(isoFromDateOnly("2026-02-02"), "2026-02-02T00:00:00.000Z");
});

Deno.test("feature flag helpers merge defaults with resolved overrides", () => {
  assertEquals(
    mergeResolvedFeatureFlags(null).length,
    Object.keys(DEFAULT_FEATURE_FLAGS).length,
  );

  const merged = mergeResolvedFeatureFlags([
    {
      flag_key: "ai_food_photo_enabled",
      enabled: false,
      variant: "holdout",
    },
    {
      flag_key: "new_server_side_flag",
      enabled: true,
      variant: null,
    },
  ]);

  assertEquals(FEATURE_FLAG_CACHE_TTL_SECONDS, 3600);
  assertEquals(
    merged.length,
    Object.keys(DEFAULT_FEATURE_FLAGS).length + 1,
  );
  assertEquals(
    merged.find((row) => row.flag_key === "ai_food_photo_enabled"),
    {
      flag_key: "ai_food_photo_enabled",
      enabled: false,
      variant: "holdout",
    },
  );
  assertEquals(
    isFeatureFlagEnabled(merged, "ai_food_photo_enabled"),
    false,
  );
  assertEquals(isFeatureFlagEnabled([], "guardian_mode_enabled"), true);
});

Deno.test("supplement helpers build adherence from scheduled and unscheduled logs", () => {
  const dailySupplement = {
    id: "daily-1",
    catalog_id: "catalog-1",
    custom_name: null,
    frequency: "daily",
    scheduled_times: ["8:00", "08:00:00", "21:30", "25:00"],
    days_of_week: null,
    started_at: "2026-02-01",
    ended_at: null,
    active: true,
  };
  const weeklySupplement = {
    id: "weekly-1",
    catalog_id: null,
    custom_name: "Weekly Zinc",
    frequency: "weekly",
    scheduled_times: ["09:00"],
    days_of_week: [1],
    started_at: "2026-02-01",
    ended_at: null,
    active: true,
  };
  const asNeededSupplement = {
    id: "as-needed-1",
    catalog_id: null,
    custom_name: "Rescue Electrolytes",
    frequency: "as_needed",
    scheduled_times: null,
    days_of_week: null,
    started_at: "2026-02-01",
    ended_at: null,
    active: true,
  };
  const inactiveSupplement = {
    ...dailySupplement,
    id: "inactive-1",
    active: false,
  };
  const futureSupplement = {
    ...dailySupplement,
    id: "future-1",
    started_at: "2026-03-01",
  };
  const endedSupplement = {
    ...dailySupplement,
    id: "ended-1",
    ended_at: "2026-02-01",
  };
  const weeklyWithoutDays = {
    ...weeklySupplement,
    id: "weekly-empty-1",
    days_of_week: [],
  };
  const restrictedDaily = {
    ...dailySupplement,
    id: "restricted-daily-1",
    days_of_week: [3],
  };
  const catalogFallbackSupplement = {
    ...dailySupplement,
    id: "catalog-fallback-1",
    catalog_id: "missing-catalog",
    custom_name: "   ",
    scheduled_times: ["07:00"],
  };

  assertEquals(normalizeDbTime("8:00:00"), "08:00");
  assertEquals(normalizeDbTime("24:00"), null);
  assertEquals(normalizeDbTime("bad"), null);
  assertEquals(normalizedScheduledTimes(dailySupplement), ["08:00", "21:30"]);
  assertEquals(normalizedScheduledTimes(asNeededSupplement), []);
  assertEquals(
    isSupplementScheduledOnDate(weeklySupplement, "2026-02-02"),
    true,
  );
  assertEquals(
    isSupplementScheduledOnDate(weeklySupplement, "2026-02-03"),
    false,
  );
  assertEquals(
    isSupplementScheduledOnDate(asNeededSupplement, "2026-02-02"),
    false,
  );
  assertEquals(
    isSupplementScheduledOnDate(inactiveSupplement, "2026-02-02"),
    false,
  );
  assertEquals(
    isSupplementScheduledOnDate(futureSupplement, "2026-02-02"),
    false,
  );
  assertEquals(
    isSupplementScheduledOnDate(endedSupplement, "2026-02-02"),
    false,
  );
  assertEquals(
    isSupplementScheduledOnDate(weeklyWithoutDays, "2026-02-02"),
    false,
  );
  assertEquals(
    isSupplementScheduledOnDate(restrictedDaily, "2026-02-02"),
    false,
  );

  const result = buildSupplementDayResult(
    "2026-02-02",
    [dailySupplement, weeklySupplement],
    [
      {
        id: "log-1",
        user_supplement_id: "daily-1",
        supplement_name: "Vitamin D",
        scheduled_time: "08:00:00",
        taken_at: "2026-02-02T08:05:00Z",
        taken_date: "2026-02-02",
      },
      {
        id: "log-2",
        user_supplement_id: null,
        supplement_name: "Electrolytes",
        scheduled_time: null,
        taken_at: "2026-02-02T12:15:00Z",
        taken_date: "2026-02-02",
      },
      {
        id: "log-3",
        user_supplement_id: null,
        supplement_name: "Magnesium",
        scheduled_time: null,
        taken_at: "2026-02-02T06:45:00Z",
        taken_date: "2026-02-02",
      },
    ],
    new Map([["catalog-1", "Vitamin D"]]),
  );

  assertEquals(result.scheduled_count, 3);
  assertEquals(result.taken_count, 1);
  assertEquals(result.adherence_today_percent, 33);
  assertEquals(result.unscheduled_logs, [
    {
      time: "06:45",
      name: "Magnesium",
      log_id: "log-3",
    },
    {
      time: "12:15",
      name: "Electrolytes",
      log_id: "log-2",
    },
  ]);
  assertEquals(supplementStatus(3, 100), "complete");
  assertEquals(supplementStatus(3, 33), "incomplete");
  assertEquals(supplementStatus(0, 0), "no_data");

  const emptyResult = buildSupplementDayResult(
    "2026-02-02",
    [asNeededSupplement, catalogFallbackSupplement],
    [{
      id: "log-fallback",
      user_supplement_id: "catalog-fallback-1",
      supplement_name: "Supplement",
      scheduled_time: "07:00",
      taken_at: "2026-02-02T07:05:00Z",
      taken_date: "2026-02-02",
    }],
    new Map(),
  );

  assertEquals(emptyResult.scheduled_count, 1);
  assertEquals(emptyResult.taken_count, 1);
  assertEquals(emptyResult.adherence_today_percent, 100);
  assertEquals(emptyResult.schedule[0].supplements[0].name, "Supplement");
});

Deno.test("medical scan retention helper computes deterministic 90 day deadline", () => {
  assertEquals(
    computeMedicalScanScheduledDeletionAt("2026-01-01T00:00:00.000Z"),
    "2026-04-01T00:00:00.000Z",
  );
});

Deno.test("user context CORS preflight helper returns a CORS response", () => {
  const response = handleCorsPreflight(
    new Request("https://edge.test/api", {
      method: "OPTIONS",
      headers: {
        Origin: "https://app.lifeos.test",
        "Access-Control-Request-Method": "GET",
      },
    }),
  );

  assertEquals(response?.status, 204);
  assertEquals(
    response?.headers.get("Access-Control-Allow-Origin"),
    "*",
  );
});
