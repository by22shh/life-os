import { parseLocalDateRange, pathnameTail } from "../../_shared/date_range.ts";
import {
  isLocalDate,
  representativeTimestampForLocalDate,
  safeTimeZone,
  utcOffsetMinutesAt,
} from "../../_shared/datetime.ts";
import { jsonWithRequest } from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const tail = pathnameTail(new URL(request.url).pathname);
  const route = (tail[0] ?? "").toLowerCase();

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { userId, service } = userResult.context;

  if (request.method === "POST" && (route === "check" || route === "")) {
    return await handleCheck(request, service, userId);
  }

  if (request.method === "GET" && route === "history") {
    return await handleHistory(request, service, userId);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleCheck(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const date = typeof payload.date === "string" ? payload.date.trim() : "";
  if (!isLocalDate(date)) {
    return jsonWithRequest(request, { error: "invalid_date" }, 400);
  }

  const scores = {
    perceived_sleep_quality: parseLikert(payload.perceived_sleep_quality),
    energy_level: parseLikert(payload.energy_level),
    muscle_soreness: parseLikert(payload.muscle_soreness),
    stress_level: parseLikert(payload.stress_level),
    mood: parseLikert(payload.mood),
  };

  if (
    scores.energy_level == null || scores.mood == null ||
    scores.stress_level == null
  ) {
    return jsonWithRequest(request, { error: "invalid_wellness_scores" }, 400);
  }

  const pss = {
    q1: parsePss(payload.pss4_q1),
    q2: parsePss(payload.pss4_q2),
    q3: parsePss(payload.pss4_q3),
    q4: parsePss(payload.pss4_q4),
  };

  const wellnessScore = computeWellnessScore(scores, pss);
  const userTimeZone = await loadUserTimeZone(service, userId);
  const checkedTimeZone = safeTimeZone(
    payload.checked_timezone ?? userTimeZone,
  );
  const checkedAt = parseTimestamp(payload.checked_at) ??
    representativeTimestampForLocalDate(date, checkedTimeZone);
  const checkedUtcOffsetMinutes = parseUtcOffset(
    payload.checked_utc_offset_minutes,
  );
  const derivedCheckedUtcOffsetMinutes = utcOffsetMinutesAt(
    checkedAt,
    checkedTimeZone,
  );
  if (
    checkedUtcOffsetMinutes != null &&
    checkedUtcOffsetMinutes !== derivedCheckedUtcOffsetMinutes
  ) {
    return jsonWithRequest(
      request,
      { error: "invalid_checked_utc_offset_minutes" },
      400,
    );
  }

  const rowId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : crypto.randomUUID();

  const { error } = await service
    .from("wellness_checks")
    .upsert({
      id: rowId,
      user_id: userId,
      checked_at: checkedAt.toISOString(),
      date,
      checked_timezone: checkedTimeZone,
      checked_utc_offset_minutes: derivedCheckedUtcOffsetMinutes,
      perceived_sleep_quality: scores.perceived_sleep_quality,
      energy_level: scores.energy_level,
      muscle_soreness: scores.muscle_soreness,
      stress_level: scores.stress_level,
      mood: scores.mood,
      pss4_q1: pss.q1,
      pss4_q2: pss.q2,
      pss4_q3: pss.q3,
      pss4_q4: pss.q4,
      feeling_ill: Boolean(payload.feeling_ill),
      headache: Boolean(payload.headache),
      digestive_issues: Boolean(payload.digestive_issues),
      notes: optionalString(payload.notes),
      wellness_score: wellnessScore,
    }, { onConflict: "user_id,date" });

  if (error) {
    return jsonWithRequest(request, {
      error: "wellness_check_create_failed",
      detail: error.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    ok: true,
    date,
    wellness_score: wellnessScore,
  });
}

async function handleHistory(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const range = parseLocalDateRange(request, 62);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const { data, error } = await service
    .from("wellness_checks")
    .select(
      "date,energy_level,mood,stress_level,pss4_total,wellness_score",
    )
    .eq("user_id", userId)
    .gte("date", range.from)
    .lte("date", range.to)
    .is("deleted_at", null)
    .order("date", { ascending: true })
    .returns<
      Array<{
        date: string;
        energy_level: number | null;
        mood: number | null;
        stress_level: number | null;
        pss4_total: number | null;
        wellness_score: number | null;
      }>
    >();

  if (error) {
    return jsonWithRequest(request, {
      error: "wellness_history_fetch_failed",
      detail: error.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    checks: data ?? [],
  });
}

function parseLikert(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const parsed = Math.trunc(value);
  if (parsed < 1 || parsed > 5) return null;
  return parsed;
}

function parsePss(value: unknown): number | null {
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const parsed = Math.trunc(value);
  if (parsed < 0 || parsed > 4) return null;
  return parsed;
}

function computeWellnessScore(
  scores: {
    perceived_sleep_quality: number | null;
    energy_level: number | null;
    muscle_soreness: number | null;
    stress_level: number | null;
    mood: number | null;
  },
  pss: {
    q1: number | null;
    q2: number | null;
    q3: number | null;
    q4: number | null;
  },
): number {
  const components: number[] = [];

  if (scores.perceived_sleep_quality != null) {
    components.push(scores.perceived_sleep_quality / 5);
  }
  if (scores.energy_level != null) {
    components.push(scores.energy_level / 5);
  }
  if (scores.mood != null) {
    components.push(scores.mood / 5);
  }
  if (scores.muscle_soreness != null) {
    components.push((6 - scores.muscle_soreness) / 5);
  }
  if (scores.stress_level != null) {
    components.push((6 - scores.stress_level) / 5);
  }

  if (pss.q1 != null && pss.q2 != null && pss.q3 != null && pss.q4 != null) {
    const pssTotal = pss.q1 + (4 - pss.q2) + (4 - pss.q3) + pss.q4;
    components.push((16 - pssTotal) / 16);
  }

  if (components.length === 0) return 0;
  const average = components.reduce((acc, value) => acc + value, 0) /
    components.length;
  return Math.round(average * 10000) / 100;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

async function loadUserTimeZone(
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<string> {
  const { data } = await service
    .from("users")
    .select("timezone")
    .eq("id", userId)
    .maybeSingle<{ timezone: string | null }>();
  return safeTimeZone(data?.timezone);
}

function parseTimestamp(value: unknown): Date | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed;
}

function parseUtcOffset(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const parsed = Math.trunc(value);
  if (parsed < -14 * 60 || parsed > 14 * 60) return null;
  return parsed;
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
