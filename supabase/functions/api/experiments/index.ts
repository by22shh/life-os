import {
  localDateToday,
  pathnameTail,
  safeTimeZone,
} from "../../_shared/date_range.ts";
import { isLocalDate } from "../../_shared/datetime.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

interface ExperimentRow {
  id: string;
  status: string;
  baseline_start_date: string | null;
  baseline_end_date: string | null;
  intervention_start_date: string | null;
  intervention_end_date: string | null;
  washout_start_date: string | null;
  washout_end_date: string | null;
}

interface ExperimentListRow extends ExperimentRow {
  title: string;
  primary_metric: string;
  created_at: string;
}

const ACTIVE_EXPERIMENT_STATUSES = new Set([
  "baseline",
  "intervention",
  "washout",
  "active",
]);

const TERMINAL_EXPERIMENT_STATUSES = new Set([
  "completed",
  "abandoned",
]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST", "DELETE"].includes(request.method)) {
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

  const { userId, timezone, service } = userResult.context;
  const resolvedTimezone = safeTimeZone(timezone);

  if (request.method === "GET" && (route === "" || route === "list")) {
    return await handleList(request, service, userId, resolvedTimezone);
  }

  if (request.method === "POST" && route === "create") {
    return await handleCreate(request, service, userId, resolvedTimezone);
  }

  if (request.method === "POST" && isUUID(route) && (tail[1] ?? "") === "log") {
    return await handleLog(request, service, userId, resolvedTimezone, route);
  }

  if (request.method === "DELETE" && isUUID(route)) {
    return await handleDelete(request, service, userId, route);
  }

  if (
    request.method === "POST" && isUUID(route) && (tail[1] ?? "") === "undo"
  ) {
    return await handleUndo(request, service, userId, resolvedTimezone, route);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleList(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string,
): Promise<Response> {
  const { data, error } = await service
    .from("experiments")
    .select(
      "id,title,status,primary_metric,created_at,baseline_start_date,baseline_end_date,intervention_start_date,intervention_end_date,washout_start_date,washout_end_date",
    )
    .eq("user_id", userId)
    .is("deleted_at", null)
    .order("created_at", { ascending: false })
    .returns<ExperimentListRow[]>();

  if (error) {
    return jsonWithRequest(request, {
      error: "experiments_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  const normalized = await normalizeExperimentStatuses(
    service,
    userId,
    data ?? [],
    localDateToday(timezone),
  );
  if (normalized.error) {
    return jsonWithRequest(request, {
      error: "experiments_status_sync_failed",
      detail: normalized.error,
    }, 500);
  }

  return jsonWithRequest(request, {
    experiments: normalized.experiments,
    count: normalized.experiments.length,
  });
}

async function handleCreate(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
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

  const title = typeof payload.title === "string" ? payload.title.trim() : "";
  const hypothesis = typeof payload.hypothesis === "string"
    ? payload.hypothesis.trim()
    : "";
  const variable = typeof payload.variable === "string"
    ? payload.variable.trim()
    : "";
  const primaryMetric = typeof payload.primary_metric === "string"
    ? payload.primary_metric.trim()
    : "";

  if (!title || !hypothesis || !variable || !primaryMetric) {
    return jsonWithRequest(request, {
      error: "missing_required_fields",
    }, 400);
  }

  const baselineDays = clampInt(payload.baseline_duration_days, 1, 60, 7);
  const interventionDays = clampInt(
    payload.intervention_duration_days,
    1,
    120,
    14,
  );
  const washoutDays = clampInt(payload.washout_duration_days, 0, 60, 0);

  const today = localDateToday(timezone);
  const baselineStart = today;
  const baselineEnd = addDays(today, baselineDays - 1);
  const interventionStart = addDays(baselineEnd, 1);
  const interventionEnd = addDays(interventionStart, interventionDays - 1);
  const washoutStart = washoutDays > 0 ? addDays(interventionEnd, 1) : null;
  const washoutEnd = washoutStart
    ? addDays(washoutStart, washoutDays - 1)
    : null;

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const experimentId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());

  const { data: existing, error: existingError } = await service
    .from("experiments")
    .select(
      "id,status,baseline_start_date,baseline_end_date,intervention_start_date,intervention_end_date,washout_start_date,washout_end_date",
    )
    .eq("id", experimentId)
    .eq("user_id", userId)
    .maybeSingle<ExperimentRow>();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "experiment_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", existingError),
    }, 500);
  }

  if (existing) {
    const normalized = await normalizeExperimentStatuses(
      service,
      userId,
      [existing],
      today,
    );
    if (normalized.error) {
      return jsonWithRequest(request, {
        error: "experiments_status_sync_failed",
        detail: normalized.error,
      }, 500);
    }
    const normalizedExperiment = normalized.experiments[0];
    return jsonWithRequest(
      request,
      {
        id: normalizedExperiment.id,
        status: normalizedExperiment.status,
        baseline_start_date: normalizedExperiment.baseline_start_date,
        baseline_end_date: normalizedExperiment.baseline_end_date,
        intervention_start_date: normalizedExperiment.intervention_start_date,
        intervention_end_date: normalizedExperiment.intervention_end_date,
        washout_start_date: normalizedExperiment.washout_start_date,
        washout_end_date: normalizedExperiment.washout_end_date,
        reminders_scheduled: true,
        idempotent_replay: true,
      },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  const { data: activeExperimentCandidates, error: activeExperimentError } =
    await service
      .from("experiments")
      .select(
        "id,status,baseline_start_date,baseline_end_date,intervention_start_date,intervention_end_date,washout_start_date,washout_end_date",
      )
      .eq("user_id", userId)
      .in("status", Array.from(ACTIVE_EXPERIMENT_STATUSES))
      .is("deleted_at", null)
      .order("created_at", { ascending: false })
      .returns<ExperimentRow[]>();

  if (activeExperimentError) {
    return jsonWithRequest(request, {
      error: "active_experiment_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", activeExperimentError),
    }, 500);
  }

  const normalizedCandidates = await normalizeExperimentStatuses(
    service,
    userId,
    activeExperimentCandidates ?? [],
    today,
  );
  if (normalizedCandidates.error) {
    return jsonWithRequest(request, {
      error: "experiments_status_sync_failed",
      detail: normalizedCandidates.error,
    }, 500);
  }

  const activeExperiment = normalizedCandidates.experiments.find((candidate) =>
    isActiveExperimentStatus(candidate.status)
  );
  if (activeExperiment) {
    return jsonWithRequest(request, {
      error: "experiment_already_active",
      existing_id: activeExperiment.id,
    }, 409);
  }

  const createdStatus = deriveExperimentStatus({
    id: experimentId,
    status: "baseline",
    baseline_start_date: baselineStart,
    baseline_end_date: baselineEnd,
    intervention_start_date: interventionStart,
    intervention_end_date: interventionEnd,
    washout_start_date: washoutStart,
    washout_end_date: washoutEnd,
  }, today);

  const { error } = await service
    .from("experiments")
    .insert({
      id: experimentId,
      user_id: userId,
      title,
      hypothesis,
      variable,
      control_description: optionalString(payload.control_description),
      intervention_description: optionalString(
        payload.intervention_description,
      ),
      status: createdStatus,
      baseline_start_date: baselineStart,
      baseline_end_date: baselineEnd,
      baseline_duration_days: baselineDays,
      intervention_start_date: interventionStart,
      intervention_end_date: interventionEnd,
      intervention_duration_days: interventionDays,
      washout_start_date: washoutStart,
      washout_end_date: washoutEnd,
      washout_duration_days: washoutDays > 0 ? washoutDays : null,
      primary_metric: primaryMetric,
      secondary_metrics: Array.isArray(payload.secondary_metrics)
        ? payload.secondary_metrics.filter((item) => typeof item === "string")
        : null,
      measurement_frequency: normalizeMeasurementFrequency(
        payload.measurement_frequency,
      ),
      reminder_time: normalizeTime(payload.reminder_time),
      user_notes: optionalString(payload.user_notes),
    });

  if (error) {
    return jsonWithRequest(request, {
      error: "experiment_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, {
    id: experimentId,
    status: createdStatus,
    baseline_start_date: baselineStart,
    baseline_end_date: baselineEnd,
    intervention_start_date: interventionStart,
    intervention_end_date: interventionEnd,
    washout_start_date: washoutStart,
    washout_end_date: washoutEnd,
    reminders_scheduled: true,
  });
}

async function handleLog(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string,
  experimentId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const logDate = typeof payload.date === "string" ? payload.date.trim() : "";
  if (!isLocalDate(logDate)) {
    return jsonWithRequest(request, { error: "invalid_date" }, 400);
  }
  if (!isObject(payload.measurements)) {
    return jsonWithRequest(request, { error: "invalid_measurements" }, 400);
  }

  const { data: experiment, error: experimentError } = await service
    .from("experiments")
    .select(
      "id,status,baseline_start_date,baseline_end_date,intervention_start_date,intervention_end_date,washout_start_date,washout_end_date",
    )
    .eq("id", experimentId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<ExperimentRow>();

  if (experimentError) {
    return jsonWithRequest(request, {
      error: "experiment_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", experimentError),
    }, 500);
  }
  if (!experiment) {
    return jsonWithRequest(request, { error: "experiment_not_found" }, 404);
  }

  const phase = phaseForDate(experiment, logDate);
  if (!phase) {
    return jsonWithRequest(request, {
      error: "measurement_date_out_of_range",
    }, 409);
  }
  const entries = Object.entries(payload.measurements)
    .filter(([, value]) => typeof value === "number" && Number.isFinite(value))
    .map(([metricName, value]) => ({ metricName, value: Number(value) }));
  const protocolFollowed = typeof payload.protocol_followed === "boolean"
    ? payload.protocol_followed
    : true;
  const metricUnit = optionalString(payload.metric_unit);

  if (entries.length === 0) {
    return jsonWithRequest(request, { error: "measurements_required" }, 400);
  }

  const measurementId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : crypto.randomUUID();

  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    const rowId = index === 0 ? measurementId : crypto.randomUUID();

    const { error } = await service
      .from("experiment_measurements")
      .upsert({
        id: rowId,
        experiment_id: experimentId,
        user_id: userId,
        measurement_date: logDate,
        measurement_phase: phase,
        metric_name: entry.metricName,
        metric_value: entry.value,
        metric_unit: metricUnit,
        protocol_followed: protocolFollowed,
        notes: optionalString(payload.notes),
      }, {
        onConflict: "experiment_id,measurement_date,metric_name",
      });

    if (error) {
      return jsonWithRequest(request, {
        error: "experiment_log_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500);
    }
  }

  const normalized = await normalizeExperimentStatuses(
    service,
    userId,
    [experiment],
    localDateToday(timezone),
  );
  if (normalized.error) {
    return jsonWithRequest(request, {
      error: "experiments_status_sync_failed",
      detail: normalized.error,
    }, 500);
  }
  const experimentStatus = normalized.experiments[0]?.status ??
    experiment.status;

  return jsonWithRequest(request, {
    measurement_id: measurementId,
    status: phase,
    measurement_phase: phase,
    experiment_status: experimentStatus,
    logged: true,
  });
}

async function handleDelete(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  experimentId: string,
): Promise<Response> {
  const { data, error } = await service
    .from("experiments")
    .update({
      deleted_at: new Date().toISOString(),
      deleted_reason: "user_deleted",
    })
    .eq("id", experimentId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .select("id")
    .maybeSingle<{ id: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "experiment_delete_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  if (!data) {
    return jsonWithRequest(request, { error: "experiment_not_found" }, 404);
  }

  return jsonWithRequest(request, { ok: true });
}

async function handleUndo(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  timezone: string,
  experimentId: string,
): Promise<Response> {
  const undoSince = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await service
    .from("experiments")
    .update({ deleted_at: null, deleted_reason: null })
    .eq("id", experimentId)
    .eq("user_id", userId)
    .gte("deleted_at", undoSince)
    .select(
      "id,status,baseline_start_date,baseline_end_date,intervention_start_date,intervention_end_date,washout_start_date,washout_end_date",
    )
    .maybeSingle<ExperimentRow>();

  if (error) {
    return jsonWithRequest(request, {
      error: "experiment_undo_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  if (!data) {
    return jsonWithRequest(
      request,
      { error: "experiment_not_found_or_expired" },
      404,
    );
  }

  const normalized = await normalizeExperimentStatuses(
    service,
    userId,
    [data],
    localDateToday(timezone),
  );
  if (normalized.error) {
    return jsonWithRequest(request, {
      error: "experiments_status_sync_failed",
      detail: normalized.error,
    }, 500);
  }

  return jsonWithRequest(request, {
    ok: true,
    status: normalized.experiments[0]?.status ?? data.status,
  });
}

function hasExplicitLifecycleSchedule(experiment: ExperimentRow): boolean {
  return Boolean(
    experiment.baseline_start_date ||
      experiment.baseline_end_date ||
      experiment.intervention_start_date ||
      experiment.intervention_end_date ||
      experiment.washout_start_date ||
      experiment.washout_end_date,
  );
}

function lifecycleEndDate(experiment: ExperimentRow): string | null {
  return experiment.washout_end_date ??
    experiment.intervention_end_date ??
    experiment.baseline_end_date ??
    null;
}

function phaseForDate(experiment: ExperimentRow, date: string): string | null {
  if (
    experiment.washout_start_date && experiment.washout_end_date &&
    date >= experiment.washout_start_date && date <= experiment.washout_end_date
  ) {
    return "washout";
  }

  if (
    experiment.intervention_start_date && experiment.intervention_end_date &&
    date >= experiment.intervention_start_date &&
    date <= experiment.intervention_end_date
  ) {
    return "intervention";
  }

  if (
    experiment.baseline_start_date && experiment.baseline_end_date &&
    date >= experiment.baseline_start_date &&
    date <= experiment.baseline_end_date
  ) {
    return "baseline";
  }

  if (hasExplicitLifecycleSchedule(experiment)) {
    return null;
  }

  switch (experiment.status) {
    case "intervention":
      return "intervention";
    case "washout":
      return "washout";
    default:
      return "baseline";
  }
}

function deriveExperimentStatus(
  experiment: ExperimentRow,
  currentDate: string,
): string {
  if (TERMINAL_EXPERIMENT_STATUSES.has(experiment.status)) {
    return experiment.status;
  }

  const endDate = lifecycleEndDate(experiment);
  if (endDate && currentDate > endDate) {
    return "completed";
  }

  const phase = phaseForDate(experiment, currentDate);
  if (phase) {
    return phase;
  }

  if (hasExplicitLifecycleSchedule(experiment)) {
    if (experiment.status === "active") return "baseline";
    return experiment.status;
  }

  return experiment.status === "active" ? "baseline" : experiment.status;
}

function isActiveExperimentStatus(status: string): boolean {
  return ACTIVE_EXPERIMENT_STATUSES.has(status);
}

async function normalizeExperimentStatuses<T extends ExperimentRow>(
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  experiments: T[],
  currentDate: string,
): Promise<{ experiments: T[]; error: string | null }> {
  const normalized: T[] = [];

  for (const experiment of experiments) {
    const nextStatus = deriveExperimentStatus(experiment, currentDate);

    if (nextStatus !== experiment.status) {
      const { error } = await service
        .from("experiments")
        .update({ status: nextStatus })
        .eq("id", experiment.id)
        .eq("user_id", userId)
        .is("deleted_at", null);

      if (error) {
        return { experiments: normalized, error: error.message };
      }
    }

    normalized.push({
      ...experiment,
      status: nextStatus,
    });
  }

  return { experiments: normalized, error: null };
}

function addDays(date: string, days: number): string {
  const parsed = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(parsed + days * 86_400_000).toISOString().slice(0, 10);
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

function normalizeMeasurementFrequency(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (!["daily", "twice_daily", "weekly"].includes(normalized)) return null;
  return normalized;
}

function normalizeTime(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!/^\d{2}:\d{2}$/.test(trimmed)) return null;
  return trimmed;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
