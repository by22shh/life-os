import { isLocalDate } from "../../../_shared/datetime.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface WorkoutSetInput {
  id?: string;
  set_number?: number;
  weight?: number | null;
  reps?: number | null;
  rpe?: number | null;
  rest_after_seconds?: number | null;
  is_warmup?: boolean;
  is_failure?: boolean;
  is_dropset?: boolean;
}

interface WorkoutExerciseInput {
  id?: string;
  exercise_id?: string | null;
  name?: string | null;
  category?: string | null;
  order_in_session?: number | null;
  duration_seconds?: number | null;
  notes?: string | null;
  sets?: WorkoutSetInput[];
}

interface ExerciseCatalogRow {
  id: string;
  name: string;
  category: string;
  is_custom: boolean;
  created_by: string | null;
}

interface WorkoutLogPayload {
  id?: string;
  started_at?: string;
  session_date?: string;
  started_timezone?: string | null;
  started_utc_offset_minutes?: number | null;
  ended_at?: string | null;
  duration_minutes?: number | null;
  workout_type?: string | null;
  location?: string | null;
  notes?: string | null;
  training_plan_id?: string | null;
  perceived_exertion_rpe?: number | null;
  post_feeling?: number | null;
  estimated_calories?: number | null;
  trimp_score?: number | null;
  exercises?: WorkoutExerciseInput[];
}

const VALID_WORKOUT_TYPES = new Set([
  "strength",
  "cardio",
  "mobility",
  "mixed",
  "sport",
  "other",
]);

const VALID_LOCATIONS = new Set(["home", "gym", "outdoor", "studio", "other"]);
const VALID_EXERCISE_CATEGORIES = new Set([
  "strength",
  "cardio",
  "mobility",
  "sport",
  "other",
]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(request, "write_heavy", {
    allowOutboxReplayExemption: true,
  });
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  let payload: WorkoutLogPayload;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  if (typeof payload.started_at !== "string") {
    return jsonWithRequest(request, { error: "started_at_required" }, 400);
  }
  const startedAt = new Date(payload.started_at);
  if (Number.isNaN(startedAt.getTime())) {
    return jsonWithRequest(request, { error: "invalid_started_at" }, 400);
  }

  if (
    typeof payload.session_date !== "string" ||
    !isLocalDate(payload.session_date)
  ) {
    return jsonWithRequest(request, { error: "invalid_session_date" }, 400);
  }

  const endedAt = payload.ended_at ? new Date(payload.ended_at) : null;
  if (endedAt && Number.isNaN(endedAt.getTime())) {
    return jsonWithRequest(request, { error: "invalid_ended_at" }, 400);
  }

  if (
    payload.workout_type != null &&
    (typeof payload.workout_type !== "string" ||
      !VALID_WORKOUT_TYPES.has(payload.workout_type))
  ) {
    return jsonWithRequest(request, { error: "invalid_workout_type" }, 400);
  }

  if (
    payload.location != null &&
    (typeof payload.location !== "string" ||
      !VALID_LOCATIONS.has(payload.location))
  ) {
    return jsonWithRequest(request, { error: "invalid_location" }, 400);
  }

  const headerKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const payloadId = typeof payload.id === "string" ? payload.id.trim() : "";
  const sessionId = isUUID(payloadId)
    ? payloadId
    : (isUUID(headerKey) ? headerKey : crypto.randomUUID());

  const { data: existing } = await service
    .from("workout_sessions")
    .select("id,session_date,updated_at")
    .eq("id", sessionId)
    .eq("user_id", userId)
    .maybeSingle<{ id: string; session_date: string; updated_at: string }>();

  if (existing) {
    const replayTrainingPlanId = normalizeOptionalString(
      payload.training_plan_id,
    );
    if (replayTrainingPlanId) {
      const syncError = await syncTrainingPlanSessionCompletion(
        request,
        service,
        userId,
        replayTrainingPlanId,
        payload.session_date,
        existing.id,
      );
      if (syncError) {
        return jsonWithRequest(request, syncError.body, syncError.status);
      }
    }
    return jsonWithRequest(
      request,
      {
        id: existing.id,
        session_date: existing.session_date,
        updated_at: existing.updated_at,
        idempotent_replay: true,
      },
      202,
      { "X-Idempotent-Replay": "true" },
    );
  }

  const exercises = Array.isArray(payload.exercises) ? payload.exercises : [];
  const exercisePayloads: Array<Record<string, unknown>> = [];
  let totalSets = 0;
  let totalReps = 0;
  let totalVolume = 0;

  for (const exercise of exercises) {
    const exerciseResolution = await resolveExerciseCatalogReference(
      request,
      service,
      userId,
      exercise,
    );
    if (!exerciseResolution.ok) {
      return exerciseResolution.response;
    }

    const sets = Array.isArray(exercise.sets) ? exercise.sets : [];
    const setPayloads = sets.map((set, setIndex) => {
      const reps = typeof set.reps === "number" && Number.isFinite(set.reps)
        ? Math.max(0, Math.trunc(set.reps))
        : 0;
      const weight =
        typeof set.weight === "number" && Number.isFinite(set.weight)
          ? Math.max(0, set.weight)
          : 0;
      totalReps += reps;
      totalVolume += reps * weight;
      return {
        id: isUUID(set.id ?? "") ? set.id : crypto.randomUUID(),
        set_number: typeof set.set_number === "number" &&
            Number.isFinite(set.set_number)
          ? Math.max(1, Math.trunc(set.set_number))
          : setIndex + 1,
        weight: toNumberOrNull(set.weight),
        reps: toIntegerOrNull(set.reps),
        rpe: toIntegerOrNull(set.rpe),
        rest_after_seconds: toIntegerOrNull(set.rest_after_seconds),
        is_warmup: set.is_warmup ?? false,
        is_failure: set.is_failure ?? false,
        is_dropset: set.is_dropset ?? false,
      };
    });
    totalSets += sets.length;

    const rowTotals = setPayloads.reduce(
      (acc, row) => {
        const reps = typeof row.reps === "number" ? row.reps : 0;
        const weight = typeof row.weight === "number" ? row.weight : 0;
        return {
          reps: acc.reps + reps,
          volume: acc.volume + reps * weight,
          maxWeight: Math.max(acc.maxWeight, weight),
        };
      },
      { reps: 0, volume: 0, maxWeight: 0 },
    );

    exercisePayloads.push({
      id: isUUID(exercise.id ?? "") ? exercise.id : crypto.randomUUID(),
      exercise_id: exerciseResolution.exerciseId,
      order_in_session: typeof exercise.order_in_session === "number" &&
          Number.isFinite(exercise.order_in_session)
        ? Math.max(0, Math.trunc(exercise.order_in_session))
        : exercisePayloads.length,
      total_sets: sets.length,
      total_reps: rowTotals.reps,
      total_volume: rowTotals.volume,
      max_weight: rowTotals.maxWeight,
      duration_seconds: toIntegerOrNull(exercise.duration_seconds),
      notes: normalizeOptionalString(exercise.notes),
      sets: setPayloads,
    });
  }

  const providedDuration = typeof payload.duration_minutes === "number" &&
      Number.isFinite(payload.duration_minutes)
    ? Math.max(0, Math.trunc(payload.duration_minutes))
    : null;
  const derivedDuration = endedAt
    ? Math.max(
      0,
      Math.trunc((endedAt.getTime() - startedAt.getTime()) / 60_000),
    )
    : null;
  const durationMinutes = providedDuration ?? derivedDuration;

  const sessionRow = {
    id: sessionId,
    user_id: userId,
    started_at: startedAt.toISOString(),
    session_date: payload.session_date,
    started_timezone: normalizeOptionalString(payload.started_timezone),
    started_utc_offset_minutes: toIntegerOrNull(
      payload.started_utc_offset_minutes,
    ),
    ended_at: endedAt?.toISOString() ?? null,
    duration_minutes: durationMinutes,
    source: normalizeOptionalString(payload.training_plan_id)
      ? "plan"
      : "manual",
    workout_type: normalizeOptionalString(payload.workout_type),
    location: normalizeOptionalString(payload.location),
    notes: normalizeOptionalString(payload.notes),
    training_plan_id: normalizeOptionalString(payload.training_plan_id),
    total_volume: totalVolume > 0 ? totalVolume : null,
    total_sets: totalSets > 0 ? totalSets : null,
    total_reps: totalReps > 0 ? totalReps : null,
    estimated_calories: toIntegerOrNull(payload.estimated_calories),
    trimp_score: toNumberOrNull(payload.trimp_score),
    perceived_exertion_rpe: toIntegerOrNull(payload.perceived_exertion_rpe),
    post_feeling: toIntegerOrNull(payload.post_feeling),
  };

  // Session, exercises and sets are created inside one SQL function so a
  // failed child insert cannot leave a partial workout behind.
  const { data: sessionData, error: sessionError } = await service
    .rpc("create_workout_atomic", {
      p_user_id: userId,
      p_session: sessionRow,
      p_exercises: exercisePayloads,
    });

  const insertedSession =
    (Array.isArray(sessionData) ? sessionData[0] : sessionData) as
      | { id: string; session_date: string; updated_at: string }
      | null;

  if (sessionError) {
    const errorCode = rpcErrorCode(sessionError);
    if (errorCode === "23503") {
      return jsonWithRequest(
        request,
        { error: "invalid_workout_reference" },
        400,
      );
    }
    if (errorCode === "42501") {
      return jsonWithRequest(request, { error: "forbidden_id_ownership" }, 403);
    }
    return jsonWithRequest(request, {
      error: "workout_session_insert_failed",
      detail: sanitizedInternalDetail(request, "index", sessionError),
    }, 500);
  }
  if (!insertedSession) {
    return jsonWithRequest(request, {
      error: "workout_session_insert_failed",
    }, 500);
  }

  if (sessionRow.training_plan_id) {
    const syncError = await syncTrainingPlanSessionCompletion(
      request,
      service,
      userId,
      sessionRow.training_plan_id,
      sessionRow.session_date,
      insertedSession.id,
    );
    if (syncError) {
      return jsonWithRequest(request, syncError.body, syncError.status);
    }
  }

  return jsonWithRequest(request, {
    id: insertedSession.id,
    session_date: insertedSession.session_date,
    updated_at: insertedSession.updated_at,
    total_sets: totalSets,
    total_reps: totalReps,
    total_volume: totalVolume,
  }, 202);
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function rpcErrorCode(error: unknown): string | null {
  if (!error || typeof error !== "object") return null;
  const code = Reflect.get(error, "code");
  return typeof code === "string" ? code : null;
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeExerciseCategory(value: unknown): string | null {
  const category = normalizeOptionalString(value);
  if (category == null) return null;
  return VALID_EXERCISE_CATEGORIES.has(category) ? category : null;
}

function canAccessExerciseCatalogRow(
  row: ExerciseCatalogRow,
  userId: string,
): boolean {
  return !row.is_custom || row.created_by === userId;
}

async function resolveExerciseCatalogReference(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  exercise: WorkoutExerciseInput,
): Promise<
  | { ok: true; exerciseId: string | null }
  | { ok: false; response: Response }
> {
  const requestedId = isUUID(exercise.exercise_id ?? "")
    ? String(exercise.exercise_id)
    : null;
  const normalizedName = normalizeOptionalString(exercise.name);
  const normalizedCategory = normalizeExerciseCategory(exercise.category);

  if (exercise.category != null && normalizedCategory == null) {
    return {
      ok: false,
      response: jsonWithRequest(
        request,
        { error: "invalid_exercise_category" },
        400,
      ),
    };
  }

  if (requestedId) {
    const existingById = await fetchExerciseCatalogById(service, requestedId);
    if (existingById && canAccessExerciseCatalogRow(existingById, userId)) {
      return { ok: true, exerciseId: existingById.id };
    }

    if (!normalizedName) {
      return {
        ok: false,
        response: jsonWithRequest(request, {
          error: "exercise_catalog_entry_not_found",
        }, 400),
      };
    }

    const existingByName = await fetchVisibleExerciseCatalogByName(
      service,
      userId,
      normalizedName,
    );
    if (existingByName) {
      return { ok: true, exerciseId: existingByName.id };
    }

    const createResult = await createCustomExerciseCatalogEntry(
      request,
      service,
      userId,
      requestedId,
      normalizedName,
      normalizedCategory ?? "other",
    );
    if (!createResult.ok) {
      return createResult;
    }
    return { ok: true, exerciseId: requestedId };
  }

  if (!normalizedName) {
    return { ok: true, exerciseId: null };
  }

  const existingByName = await fetchVisibleExerciseCatalogByName(
    service,
    userId,
    normalizedName,
  );
  if (existingByName) {
    return { ok: true, exerciseId: existingByName.id };
  }

  const generatedId = crypto.randomUUID();
  const createResult = await createCustomExerciseCatalogEntry(
    request,
    service,
    userId,
    generatedId,
    normalizedName,
    normalizedCategory ?? "other",
  );
  if (!createResult.ok) {
    return createResult;
  }
  return { ok: true, exerciseId: generatedId };
}

async function fetchExerciseCatalogById(
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  id: string,
): Promise<ExerciseCatalogRow | null> {
  const { data, error } = await service
    .from("exercise_catalog")
    .select("id,name,category,is_custom,created_by")
    .eq("id", id)
    .maybeSingle<ExerciseCatalogRow>();

  if (error) {
    return null;
  }

  return data ?? null;
}

async function fetchVisibleExerciseCatalogByName(
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  name: string,
): Promise<ExerciseCatalogRow | null> {
  const { data, error } = await service
    .from("exercise_catalog")
    .select("id,name,category,is_custom,created_by")
    .ilike("name", name)
    .returns<ExerciseCatalogRow[]>();

  if (error) {
    return null;
  }

  return (data ?? []).find((row) =>
    row.name.trim().toLowerCase() === name.trim().toLowerCase() &&
    canAccessExerciseCatalogRow(row, userId)
  ) ?? null;
}

async function createCustomExerciseCatalogEntry(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  id: string,
  name: string,
  category: string,
): Promise<{ ok: true } | { ok: false; response: Response }> {
  const { error } = await service
    .from("exercise_catalog")
    .insert({
      id,
      name,
      category,
      is_custom: true,
      created_by: userId,
    });

  if (error) {
    return {
      ok: false,
      response: jsonWithRequest(request, {
        error: "exercise_catalog_insert_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500),
    };
  }

  return { ok: true };
}

async function syncTrainingPlanSessionCompletion(
  request: Request,
  service: ReturnType<
    typeof import("../../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  trainingPlanId: string,
  sessionDate: string,
  workoutId: string,
): Promise<
  {
    status: number;
    body: Record<string, string>;
  } | null
> {
  const { data: candidateRows, error: candidateError } = await service
    .from("training_plan_sessions")
    .select("id,actual_session_id,status")
    .eq("training_plan_id", trainingPlanId)
    .eq("user_id", userId)
    .eq("planned_date", sessionDate)
    .in("status", ["planned", "rescheduled", "completed"])
    .order("updated_at", { ascending: false })
    .returns<
      Array<{
        id: string;
        actual_session_id: string | null;
        status: string;
      }>
    >();

  if (candidateError) {
    return {
      status: 500,
      body: {
        error: "training_plan_session_fetch_failed",
        detail: sanitizedInternalDetail(request, "index", candidateError),
      },
    };
  }

  const candidate = (candidateRows ?? []).find((row) =>
    row.actual_session_id == null || row.actual_session_id === workoutId
  );
  if (!candidate) {
    return null;
  }

  const { error: updateError } = await service
    .from("training_plan_sessions")
    .update({
      status: "completed",
      actual_session_id: workoutId,
    })
    .eq("id", candidate.id)
    .eq("user_id", userId);

  if (updateError) {
    return {
      status: 500,
      body: {
        error: "training_plan_session_update_failed",
        detail: sanitizedInternalDetail(request, "index", updateError),
      },
    };
  }

  return null;
}

function toNumberOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return value;
}

function toIntegerOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.trunc(value);
}
