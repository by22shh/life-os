import {
  localDateToday,
  parseLocalDateParam,
  safeTimeZone,
} from "../../_shared/date_range.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

interface RecoveryRow {
  date: string;
  recovery_score: number;
  recovery_zone: string;
  hrv_ms: number | null;
  hrv_score: number | null;
  resting_heart_rate_bpm: number | null;
  rhr_score: number | null;
  wrist_temperature_deviation_c: number | null;
  temp_score: number | null;
  sleep_duration_hours: number | null;
  sleep_quality_percent: number | null;
  sleep_score: number | null;
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

  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);
  const apiIndex = segments.findIndex((segment) => segment.startsWith("api-"));
  const tail = apiIndex >= 0 ? segments.slice(apiIndex + 1) : segments;
  const route = (tail[0] ?? "latest").toLowerCase();

  if (route === "latest") {
    const date = localDateToday(safeTimeZone(timezone));
    const { data: todayRow, error: todayError } = await service
      .from("physiological_states")
      .select(
        "date,recovery_score,recovery_zone,hrv_ms,hrv_score,resting_heart_rate_bpm,rhr_score,wrist_temperature_deviation_c,temp_score,sleep_duration_hours,sleep_quality_percent,sleep_score,data_completeness,confidence_score",
      )
      .eq("user_id", userId)
      .eq("date", date)
      .maybeSingle<RecoveryRow>();

    if (todayError) {
      return jsonWithRequest(request, {
        error: "recovery_fetch_failed",
        detail: sanitizedInternalDetail(request, "index", todayError),
      }, 500);
    }

    let row = todayRow;
    if (!row) {
      const { data: fallbackRow, error: fallbackError } = await service
        .from("physiological_states")
        .select(
          "date,recovery_score,recovery_zone,hrv_ms,hrv_score,resting_heart_rate_bpm,rhr_score,wrist_temperature_deviation_c,temp_score,sleep_duration_hours,sleep_quality_percent,sleep_score,data_completeness,confidence_score",
        )
        .eq("user_id", userId)
        .order("date", { ascending: false })
        .limit(1)
        .maybeSingle<RecoveryRow>();

      if (fallbackError) {
        return jsonWithRequest(request, {
          error: "recovery_fetch_failed",
          detail: sanitizedInternalDetail(request, "index", fallbackError),
        }, 500);
      }
      row = fallbackRow;
    }

    if (!row) {
      return jsonWithRequest(request, { error: "recovery_not_found" }, 404);
    }

    const score = Number(row.recovery_score ?? 0);
    return jsonWithRequest(request, {
      date: row.date,
      recovery_score: score,
      recovery_zone: row.recovery_zone,
      breakdown: {
        hrv: {
          value: row.hrv_ms,
          score: row.hrv_score,
          baseline: null,
        },
        rhr: {
          value: row.resting_heart_rate_bpm,
          score: row.rhr_score,
          baseline: null,
        },
        sleep: {
          duration: row.sleep_duration_hours,
          quality: row.sleep_quality_percent,
          score: row.sleep_score,
        },
        temp: {
          deviation_c: row.wrist_temperature_deviation_c,
          score: row.temp_score,
        },
      },
      recommendation: recommendationFor(score),
      prediction: {
        tomorrow_if_sleep_8h: clampScore(score + 10),
        tomorrow_if_sleep_7h: clampScore(score + 2),
        tomorrow_if_sleep_6h: clampScore(score - 8),
      },
    });
  }

  if (route === "daily") {
    const date = parseLocalDateParam(request, "date");
    if (!date) {
      return jsonWithRequest(request, { error: "invalid_date" }, 400);
    }

    const { data: row, error } = await service
      .from("physiological_states")
      .select(
        "date,recovery_score,recovery_zone,hrv_score,rhr_score,temp_score,sleep_score,data_completeness,confidence_score",
      )
      .eq("user_id", userId)
      .eq("date", date)
      .maybeSingle<
        Pick<
          RecoveryRow,
          | "date"
          | "recovery_score"
          | "recovery_zone"
          | "hrv_score"
          | "rhr_score"
          | "temp_score"
          | "sleep_score"
          | "data_completeness"
          | "confidence_score"
        >
      >();

    if (error) {
      return jsonWithRequest(request, {
        error: "recovery_fetch_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500);
    }
    if (!row) {
      return jsonWithRequest(request, { error: "recovery_not_found" }, 404);
    }

    return jsonWithRequest(request, {
      date: row.date,
      recovery_score: Number(row.recovery_score ?? 0),
      recovery_zone: row.recovery_zone,
      data_completeness: row.data_completeness,
      confidence_score: row.confidence_score,
      breakdown: {
        hrv_score: row.hrv_score,
        rhr_score: row.rhr_score,
        temp_score: row.temp_score,
        sleep_score: row.sleep_score,
      },
    });
  }

  if (route === "trend") {
    const rawDays = url.searchParams.get("days")?.trim() ?? "30";
    const days = Number.parseInt(rawDays, 10);
    if (!Number.isFinite(days) || days < 1 || days > 365) {
      return jsonWithRequest(request, { error: "invalid_days" }, 400);
    }

    const now = new Date();
    const cutoff = new Date(now.getTime() - (days - 1) * 86_400_000)
      .toISOString()
      .slice(0, 10);

    const { data: rows, error } = await service
      .from("physiological_states")
      .select("date,recovery_score")
      .eq("user_id", userId)
      .gte("date", cutoff)
      .order("date", { ascending: false })
      .returns<Array<{ date: string; recovery_score: number }>>();

    if (error) {
      return jsonWithRequest(request, {
        error: "recovery_trend_fetch_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500);
    }

    const data = (rows ?? []).map((row) => ({
      date: row.date,
      score: Number(row.recovery_score ?? 0),
    }));

    const scores = data.map((entry) => entry.score);
    const average = scores.length > 0
      ? scores.reduce((acc, value) => acc + value, 0) / scores.length
      : 0;
    const variance = scores.length > 0
      ? scores.reduce((acc, value) => acc + (value - average) ** 2, 0) /
        scores.length
      : 0;

    return jsonWithRequest(request, {
      data,
      statistics: {
        average: round2(average),
        min: scores.length > 0 ? Math.min(...scores) : 0,
        max: scores.length > 0 ? Math.max(...scores) : 0,
        std_dev: round2(Math.sqrt(variance)),
      },
    });
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

function recommendationFor(score: number): string {
  if (score >= 75) return "Your body is ready for higher intensity work today.";
  if (score >= 50) return "Moderate training is appropriate today.";
  if (score >= 25) return "Prioritize recovery and keep training light today.";
  return "Focus on rest and recovery today.";
}

function clampScore(value: number): number {
  return Math.max(0, Math.min(100, Math.round(value)));
}

function round2(value: number): number {
  return Math.round(value * 100) / 100;
}
