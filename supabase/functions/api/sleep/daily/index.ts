import {
  localDateToday,
  parseLocalDateParam,
  safeTimeZone,
} from "../../../_shared/date_range.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface SleepRow {
  date: string;
  sleep_duration_hours: number | null;
  sleep_score: number | null;
  sleep_quality_percent: number | null;
  deep_sleep_percent: number | null;
  rem_sleep_percent: number | null;
  light_sleep_percent: number | null;
  awake_percent: number | null;
  data_completeness: number | null;
  confidence_score: number | null;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, timezone, service } = userResult.context;

  const date = parseLocalDateParam(request, "date") ??
    localDateToday(safeTimeZone(timezone));

  const { data, error } = await service
    .from("physiological_states")
    .select(
      "date,sleep_duration_hours,sleep_score,sleep_quality_percent,deep_sleep_percent,rem_sleep_percent,light_sleep_percent,awake_percent,data_completeness,confidence_score",
    )
    .eq("user_id", userId)
    .eq("date", date)
    .maybeSingle<SleepRow>();

  if (error) {
    return jsonWithRequest(request, {
      error: "sleep_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  const row = data ?? null;
  const stagesAvailable = row != null && [
    row.deep_sleep_percent,
    row.rem_sleep_percent,
    row.light_sleep_percent,
    row.awake_percent,
  ].some((value) => value != null);

  return jsonWithRequest(request, {
    date,
    sleep_duration_hours: row?.sleep_duration_hours ?? null,
    sleep_score: row?.sleep_score ?? null,
    sleep_quality_percent: row?.sleep_quality_percent ?? null,
    stages: {
      deep_sleep_percent: row?.deep_sleep_percent ?? null,
      rem_sleep_percent: row?.rem_sleep_percent ?? null,
      light_sleep_percent: row?.light_sleep_percent ?? null,
      awake_percent: row?.awake_percent ?? null,
      stages_available: stagesAvailable,
    },
    data_completeness: row?.data_completeness ?? null,
    confidence_score: row?.confidence_score ?? null,
  });
});
