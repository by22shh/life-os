import {
  localDateToday,
  parseLocalDateRange,
  pathnameTail,
  safeTimeZone,
} from "../../../_shared/date_range.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

type PlanStatus = "active" | "paused" | "completed" | "archived";

const VALID_STATUSES: PlanStatus[] = [
  "active",
  "paused",
  "completed",
  "archived",
];

const VALID_REASONS = new Set([
  "recovery_low",
  "recovery_critical",
  "fatigue_accumulation",
  "injury_flag",
  "user_request",
  "schedule_conflict",
  "load_spike_acwr",
]);

const VALID_ADJUSTMENTS = new Set([
  "reduce_volume_30",
  "reduce_intensity_20",
  "skip_session",
  "swap_to_mobility",
  "extend_rest_day",
  "deload_week",
]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST", "PATCH"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const tail = pathnameTail(new URL(request.url).pathname);
  const route = (tail[0] ?? "").toLowerCase();
  const subRoute = (tail[1] ?? "").toLowerCase();

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { userId, timezone, service } = userResult.context;

  if (request.method === "POST" && route === "generate") {
    return await handleGenerate(
      request,
      service,
      userId,
      safeTimeZone(timezone),
    );
  }

  if (request.method === "GET" && route === "active") {
    return await handleActive(request, service, userId);
  }

  if (request.method === "GET" && route === "sessions") {
    return await handleSessions(request, service, userId);
  }

  if (request.method === "GET" && isUUID(route)) {
    return await handleGetById(request, service, userId, route);
  }

  if (request.method === "PATCH" && isUUID(route) && subRoute === "") {
    return await handlePatchPlan(request, service, userId, route);
  }

  if (request.method === "PATCH" && isUUID(route) && subRoute === "adjust") {
    return await handleAdjustPlan(request, service, userId, route);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleGenerate(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const goal = normalizeGoal(payload.goal);
  if (!goal) {
    return jsonWithRequest(request, { error: "invalid_goal" }, 400);
  }

  const availableDays = normalizeAvailableDays(payload.available_days);
  const durationWeeks = clampInt(payload.duration_weeks, 1, 24, 4);
  const sessionDuration = clampInt(
    payload.session_duration_minutes,
    10,
    240,
    60,
  );

  const today = localDateToday(timezone);
  const endDate = addDays(today, durationWeeks * 7 - 1);

  const planId = crypto.randomUUID();
  const planName =
    typeof payload.name === "string" && payload.name.trim().length > 0
      ? payload.name.trim()
      : `${capitalize(goal)} Plan`;

  const planJson = {
    generated_at: new Date().toISOString(),
    request: payload,
    session_duration_minutes: sessionDuration,
  };

  const { error: planError } = await service
    .from("training_plans")
    .insert({
      id: planId,
      user_id: userId,
      name: planName,
      goal,
      status: "active",
      start_date: today,
      end_date: endDate,
      duration_weeks: durationWeeks,
      days_per_week: availableDays.length,
      current_week: 1,
      ai_generated: true,
      plan_json: planJson,
      adaptive_rules: {},
    });

  if (planError) {
    return jsonWithRequest(request, {
      error: "training_plan_create_failed",
      detail: planError.message,
    }, 500);
  }

  const sessionTypes = ["strength", "cardio", "mobility", "recovery"];
  const sessionRows: Array<Record<string, unknown>> = [];

  for (let week = 0; week < durationWeeks; week += 1) {
    for (let index = 0; index < availableDays.length; index += 1) {
      const weekday = availableDays[index];
      const date = nextWeekday(today, weekday, week);
      sessionRows.push({
        id: crypto.randomUUID(),
        training_plan_id: planId,
        user_id: userId,
        planned_date: date,
        session_type: sessionTypes[index % sessionTypes.length],
        planned_duration_minutes: sessionDuration,
        planned_exercises: {
          title: `${capitalize(goal)} Session ${index + 1}`,
          week: week + 1,
        },
        status: "planned",
      });
    }
  }

  if (sessionRows.length > 0) {
    const { error: sessionsError } = await service
      .from("training_plan_sessions")
      .insert(sessionRows);

    if (sessionsError) {
      return jsonWithRequest(request, {
        error: "training_plan_sessions_create_failed",
        detail: sessionsError.message,
      }, 500);
    }
  }

  return jsonWithRequest(request, {
    plan_id: planId,
    status: "active",
    weeks_generated: durationWeeks,
  });
}

async function handleActive(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const { data: plan, error: planError } = await service
    .from("training_plans")
    .select("id,name,current_week")
    .eq("user_id", userId)
    .eq("status", "active")
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle<{ id: string; name: string; current_week: number | null }>();

  if (planError) {
    return jsonWithRequest(request, {
      error: "training_plan_fetch_failed",
      detail: planError.message,
    }, 500);
  }

  if (!plan) {
    return jsonWithRequest(request, { error: "plan_not_active" }, 404);
  }

  const fromDate = localDateToday("UTC");
  const toDate = addDays(fromDate, 14);

  const { data: sessions, error: sessionsError } = await service
    .from("training_plan_sessions")
    .select("planned_date,session_type,status")
    .eq("training_plan_id", plan.id)
    .gte("planned_date", fromDate)
    .lte("planned_date", toDate)
    .order("planned_date", { ascending: true })
    .returns<
      Array<{ planned_date: string; session_type: string; status: string }>
    >();

  if (sessionsError) {
    return jsonWithRequest(request, {
      error: "training_plan_sessions_fetch_failed",
      detail: sessionsError.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    plan_id: plan.id,
    name: plan.name,
    current_week: plan.current_week,
    sessions: (sessions ?? []).map((row) => ({
      date: row.planned_date,
      session_type: row.session_type,
      status: row.status,
    })),
  });
}

async function handleGetById(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  planId: string,
): Promise<Response> {
  const { data: row, error } = await service
    .from("training_plans")
    .select(
      "id,name,status,goal,duration_weeks,days_per_week,adaptive_rules,created_at,updated_at",
    )
    .eq("id", planId)
    .eq("user_id", userId)
    .maybeSingle<{
      id: string;
      name: string;
      status: string;
      goal: string;
      duration_weeks: number | null;
      days_per_week: number | null;
      adaptive_rules: unknown;
      created_at: string;
      updated_at: string;
    }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "training_plan_fetch_failed",
      detail: error.message,
    }, 500);
  }

  if (!row) {
    return jsonWithRequest(request, { error: "plan_not_found" }, 404);
  }

  return jsonWithRequest(request, {
    id: row.id,
    name: row.name,
    status: row.status,
    goal: row.goal,
    duration_weeks: row.duration_weeks,
    sessions_per_week: row.days_per_week,
    adaptive_rules: row.adaptive_rules,
    created_at: row.created_at,
    updated_at: row.updated_at,
  });
}

async function handleSessions(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const range = parseLocalDateRange(request, 120);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const { data: activePlan, error: activePlanError } = await service
    .from("training_plans")
    .select("id")
    .eq("user_id", userId)
    .eq("status", "active")
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle<{ id: string }>();

  if (activePlanError) {
    return jsonWithRequest(request, {
      error: "training_plan_fetch_failed",
      detail: activePlanError.message,
    }, 500);
  }

  if (!activePlan) {
    return jsonWithRequest(request, {
      from: range.from,
      to: range.to,
      sessions: [],
    });
  }

  const { data: sessions, error: sessionsError } = await service
    .from("training_plan_sessions")
    .select(
      "id,training_plan_id,planned_date,session_type,status,planned_exercises",
    )
    .eq("training_plan_id", activePlan.id)
    .gte("planned_date", range.from)
    .lte("planned_date", range.to)
    .order("planned_date", { ascending: true })
    .returns<
      Array<{
        id: string;
        training_plan_id: string;
        planned_date: string;
        session_type: string;
        status: string;
        planned_exercises: unknown;
      }>
    >();

  if (sessionsError) {
    return jsonWithRequest(request, {
      error: "training_plan_sessions_fetch_failed",
      detail: sessionsError.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    sessions: (sessions ?? []).map((row) => ({
      id: row.id,
      plan_id: row.training_plan_id,
      planned_date: row.planned_date,
      session_type: row.session_type,
      status: row.status,
      title: extractTitle(row.planned_exercises) ??
        `${capitalize(row.session_type)} Session`,
    })),
  });
}

async function handlePatchPlan(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  planId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const updates: Record<string, unknown> = {};

  if (Object.prototype.hasOwnProperty.call(payload, "name")) {
    const name = normalizeOptionalString(payload.name);
    if (!name) {
      return jsonWithRequest(request, { error: "invalid_name" }, 400);
    }
    updates.name = name;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "status")) {
    const status = typeof payload.status === "string"
      ? payload.status.trim().toLowerCase()
      : "";
    if (!VALID_STATUSES.includes(status as PlanStatus)) {
      return jsonWithRequest(request, { error: "invalid_status" }, 400);
    }
    updates.status = status;
  }

  if (Object.keys(updates).length === 0) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  const { data, error } = await service
    .from("training_plans")
    .update(updates)
    .eq("id", planId)
    .eq("user_id", userId)
    .select("id,status")
    .maybeSingle<{ id: string; status: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "training_plan_update_failed",
      detail: error.message,
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(request, { error: "plan_not_found" }, 404);
  }

  return jsonWithRequest(request, {
    ok: true,
    plan_id: data.id,
    status: data.status,
  });
}

async function handleAdjustPlan(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  planId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const reason = typeof payload.reason === "string"
    ? payload.reason.trim()
    : "";
  const adjustment = typeof payload.adjustment === "string"
    ? payload.adjustment.trim()
    : "";

  if (!VALID_REASONS.has(reason)) {
    return jsonWithRequest(request, { error: "invalid_reason" }, 400);
  }
  if (!VALID_ADJUSTMENTS.has(adjustment)) {
    return jsonWithRequest(request, { error: "invalid_adjustment" }, 400);
  }

  const { data: existingPlan, error: existingPlanError } = await service
    .from("training_plans")
    .select("adaptive_rules")
    .eq("id", planId)
    .eq("user_id", userId)
    .maybeSingle<{ adaptive_rules: Record<string, unknown> | null }>();

  if (existingPlanError) {
    return jsonWithRequest(request, {
      error: "training_plan_fetch_failed",
      detail: existingPlanError.message,
    }, 500);
  }
  if (!existingPlan) {
    return jsonWithRequest(request, { error: "plan_not_found" }, 404);
  }

  const adaptiveRules = {
    ...(existingPlan.adaptive_rules ?? {}),
    [reason]: adjustment,
  };

  const { error: updateError } = await service
    .from("training_plans")
    .update({
      adaptive_rules: adaptiveRules,
      last_adjusted_at: new Date().toISOString(),
    })
    .eq("id", planId)
    .eq("user_id", userId);

  if (updateError) {
    return jsonWithRequest(request, {
      error: "training_plan_adjust_failed",
      detail: updateError.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    plan_id: planId,
    adjusted: true,
    effective_from: localDateToday("UTC"),
  });
}

function normalizeGoal(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (
    [
      "strength",
      "hypertrophy",
      "endurance",
      "weight_loss",
      "sport_specific",
      "general_fitness",
    ].includes(normalized)
  ) {
    return normalized;
  }
  return null;
}

function normalizeAvailableDays(value: unknown): number[] {
  if (!Array.isArray(value)) return [1, 3, 5];
  const normalized = [
    ...new Set(
      value
        .filter((item) => typeof item === "number" && Number.isInteger(item))
        .map((item) => Number(item))
        .filter((item) => item >= 0 && item <= 6),
    ),
  ];

  if (normalized.length === 0) return [1, 3, 5];
  return normalized.slice(0, 7);
}

function addDays(date: string, days: number): string {
  const parsed = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(parsed + days * 86_400_000).toISOString().slice(0, 10);
}

function nextWeekday(
  startDate: string,
  weekday: number,
  weekOffset: number,
): string {
  const startMs = Date.parse(`${startDate}T00:00:00.000Z`);
  const startDay = new Date(startMs).getUTCDay();
  const delta = (weekday - startDay + 7) % 7 + weekOffset * 7;
  return new Date(startMs + delta * 86_400_000).toISOString().slice(0, 10);
}

function clampInt(
  value: unknown,
  min: number,
  max: number,
  fallback: number,
): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(value)));
}

function extractTitle(value: unknown): string | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return null;
  }
  const title = (value as Record<string, unknown>).title;
  if (typeof title !== "string") return null;
  const trimmed = title.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function capitalize(value: string): string {
  if (!value) return value;
  return value[0].toUpperCase() + value.slice(1);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
