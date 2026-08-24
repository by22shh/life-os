import { pathnameTail } from "../../_shared/date_range.ts";
import { isLocalDate } from "../../_shared/datetime.ts";
import { jsonWithRequest } from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

interface WorkoutSessionRow {
  id: string;
  started_at: string;
  ended_at: string | null;
  session_date: string;
  started_timezone: string | null;
  started_utc_offset_minutes: number | null;
  workout_type: string | null;
  source: string;
  total_volume: number | null;
  total_sets: number | null;
  total_reps: number | null;
  estimated_calories: number | null;
  trimp_score: number | null;
  perceived_exertion_rpe: number | null;
  notes: string | null;
  duration_minutes: number | null;
  location: string | null;
  training_plan_id: string | null;
  post_feeling: number | null;
}

interface WorkoutExerciseRow {
  id: string;
  exercise_id: string | null;
  order_in_session: number | null;
  total_sets: number | null;
  total_reps: number | null;
  total_volume: number | null;
  max_weight: number | null;
  duration_seconds: number | null;
  notes: string | null;
}

interface WorkoutSetRow {
  id: string;
  exercise_entry_id: string;
  set_number: number;
  weight: number | null;
  reps: number | null;
  rpe: number | null;
  rest_after_seconds: number | null;
  is_warmup: boolean;
  is_failure: boolean;
  is_dropset: boolean;
}

interface ExerciseCatalogRow {
  id: string;
  name: string;
  category: string;
  is_custom: boolean;
  created_by: string | null;
}

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

  if (!["GET", "PATCH", "DELETE", "POST"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const url = new URL(request.url);
  const tail = pathnameTail(url.pathname);
  const sessionId = tail[0] ?? "";
  const action = (tail[1] ?? "").toLowerCase();

  if (!isUUID(sessionId)) {
    return jsonWithRequest(request, { error: "invalid_session_id" }, 400);
  }

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  if (request.method === "GET") {
    return await handleGetWorkout(request, service, userId, sessionId);
  }

  if (request.method === "PATCH") {
    return await handlePatchWorkout(request, service, userId, sessionId);
  }

  if (request.method === "DELETE") {
    return await handleDeleteWorkout(request, service, userId, sessionId);
  }

  if (request.method === "POST" && action === "undo") {
    return await handleUndoWorkout(request, service, userId, sessionId);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleGetWorkout(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  sessionId: string,
): Promise<Response> {
  const { data: session, error: sessionError } = await service
    .from("workout_sessions")
    .select(
      "id,started_at,ended_at,session_date,started_timezone,started_utc_offset_minutes,workout_type,source,total_volume,total_sets,total_reps,estimated_calories,trimp_score,perceived_exertion_rpe,notes,duration_minutes,location,training_plan_id,post_feeling",
    )
    .eq("id", sessionId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<WorkoutSessionRow>();

  if (sessionError) {
    return jsonWithRequest(request, {
      error: "workout_session_fetch_failed",
      detail: sessionError.message,
    }, 500);
  }
  if (!session) {
    return jsonWithRequest(request, { error: "workout_not_found" }, 404);
  }

  const { data: exercises, error: exercisesError } = await service
    .from("workout_exercises")
    .select(
      "id,exercise_id,order_in_session,total_sets,total_reps,total_volume,max_weight,duration_seconds,notes",
    )
    .eq("session_id", sessionId)
    .order("order_in_session", { ascending: true })
    .returns<WorkoutExerciseRow[]>();

  if (exercisesError) {
    return jsonWithRequest(request, {
      error: "workout_exercises_fetch_failed",
      detail: exercisesError.message,
    }, 500);
  }

  const exerciseRows = exercises ?? [];
  const exerciseIds = exerciseRows.map((row) => row.id);

  const setsByExercise = new Map<string, WorkoutSetRow[]>();
  if (exerciseIds.length > 0) {
    const { data: sets, error: setsError } = await service
      .from("workout_sets")
      .select(
        "id,exercise_entry_id,set_number,weight,reps,rpe,rest_after_seconds,is_warmup,is_failure,is_dropset",
      )
      .eq("user_id", userId)
      .in("exercise_entry_id", exerciseIds)
      .order("set_number", { ascending: true })
      .returns<WorkoutSetRow[]>();

    if (setsError) {
      return jsonWithRequest(request, {
        error: "workout_sets_fetch_failed",
        detail: setsError.message,
      }, 500);
    }

    for (const set of sets ?? []) {
      const list = setsByExercise.get(set.exercise_entry_id) ?? [];
      list.push(set);
      setsByExercise.set(set.exercise_entry_id, list);
    }
  }

  const catalogIds = exerciseRows
    .map((row) => row.exercise_id)
    .filter((value): value is string =>
      typeof value === "string" && value.length > 0
    );

  const exerciseNameMap = new Map<string, string>();
  const exerciseCategoryMap = new Map<string, string>();
  if (catalogIds.length > 0) {
    const { data: catalogRows, error: catalogError } = await service
      .from("exercise_catalog")
      .select("id,name,category,is_custom,created_by")
      .in("id", catalogIds)
      .returns<ExerciseCatalogRow[]>();

    if (catalogError) {
      return jsonWithRequest(request, {
        error: "exercise_catalog_fetch_failed",
        detail: catalogError.message,
      }, 500);
    }

    for (const row of catalogRows ?? []) {
      exerciseNameMap.set(row.id, row.name);
      exerciseCategoryMap.set(row.id, row.category);
    }
  }

  return jsonWithRequest(request, {
    id: session.id,
    started_at: session.started_at,
    ended_at: session.ended_at,
    session_date: session.session_date,
    started_timezone: session.started_timezone,
    started_utc_offset_minutes: session.started_utc_offset_minutes,
    workout_type: session.workout_type,
    source: session.source,
    total_volume: session.total_volume,
    total_sets: session.total_sets,
    total_reps: session.total_reps,
    estimated_calories: session.estimated_calories,
    trimp_score: session.trimp_score,
    perceived_exertion_rpe: session.perceived_exertion_rpe,
    duration_minutes: session.duration_minutes,
    location: session.location,
    training_plan_id: session.training_plan_id,
    post_feeling: session.post_feeling,
    notes: session.notes,
    exercises: exerciseRows.map((exercise) => ({
      id: exercise.id,
      exercise_id: exercise.exercise_id,
      name: exercise.exercise_id
        ? exerciseNameMap.get(exercise.exercise_id) ?? null
        : null,
      category: exercise.exercise_id
        ? exerciseCategoryMap.get(exercise.exercise_id) ?? null
        : null,
      order_in_session: exercise.order_in_session,
      total_sets: exercise.total_sets,
      total_reps: exercise.total_reps,
      total_volume: exercise.total_volume,
      max_weight: exercise.max_weight,
      duration_seconds: exercise.duration_seconds,
      notes: exercise.notes,
      sets: (setsByExercise.get(exercise.id) ?? []).map((set) => ({
        id: set.id,
        set_number: set.set_number,
        weight: set.weight,
        reps: set.reps,
        rpe: set.rpe,
        rest_after_seconds: set.rest_after_seconds,
        is_warmup: set.is_warmup,
        is_failure: set.is_failure,
        is_dropset: set.is_dropset,
      })),
    })),
  });
}

async function handlePatchWorkout(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  sessionId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const { data: existing, error: existingError } = await service
    .from("workout_sessions")
    .select("id,source,started_at,ended_at,session_date,training_plan_id")
    .eq("id", sessionId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .maybeSingle<
      {
        id: string;
        source: string;
        started_at: string;
        ended_at: string | null;
        session_date: string;
        training_plan_id: string | null;
      }
    >();

  if (existingError) {
    return jsonWithRequest(request, {
      error: "workout_session_fetch_failed",
      detail: existingError.message,
    }, 500);
  }
  if (!existing) {
    return jsonWithRequest(request, { error: "workout_not_found" }, 404);
  }

  const hasExercisesPayload = Object.prototype.hasOwnProperty.call(
    payload,
    "exercises",
  );
  if (existing.source === "import" && hasExercisesPayload) {
    return jsonWithRequest(
      request,
      { error: "import_workout_edit_restricted" },
      403,
    );
  }

  const updates: Record<string, unknown> = {};
  let startedAtIso = existing.started_at;
  let endedAtIso = existing.ended_at;

  if (Object.prototype.hasOwnProperty.call(payload, "started_at")) {
    if (typeof payload.started_at !== "string") {
      return jsonWithRequest(request, { error: "invalid_started_at" }, 400);
    }
    const parsed = new Date(payload.started_at);
    if (Number.isNaN(parsed.getTime())) {
      return jsonWithRequest(request, { error: "invalid_started_at" }, 400);
    }
    startedAtIso = parsed.toISOString();
    updates.started_at = startedAtIso;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "ended_at")) {
    if (payload.ended_at != null && typeof payload.ended_at !== "string") {
      return jsonWithRequest(request, { error: "invalid_ended_at" }, 400);
    }
    if (typeof payload.ended_at === "string") {
      const parsed = new Date(payload.ended_at);
      if (Number.isNaN(parsed.getTime())) {
        return jsonWithRequest(request, { error: "invalid_ended_at" }, 400);
      }
      endedAtIso = parsed.toISOString();
      updates.ended_at = endedAtIso;
    } else {
      endedAtIso = null;
      updates.ended_at = null;
    }
  }

  if (Object.prototype.hasOwnProperty.call(payload, "session_date")) {
    if (
      typeof payload.session_date !== "string" ||
      !isLocalDate(payload.session_date)
    ) {
      return jsonWithRequest(request, { error: "invalid_session_date" }, 400);
    }
    updates.session_date = payload.session_date;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "workout_type")) {
    const workoutType = normalizeOptionalString(payload.workout_type);
    if (workoutType != null && !VALID_WORKOUT_TYPES.has(workoutType)) {
      return jsonWithRequest(request, { error: "invalid_workout_type" }, 400);
    }
    updates.workout_type = workoutType;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "location")) {
    const location = normalizeOptionalString(payload.location);
    if (location != null && !VALID_LOCATIONS.has(location)) {
      return jsonWithRequest(request, { error: "invalid_location" }, 400);
    }
    updates.location = location;
  }

  for (
    const field of [
      "started_timezone",
      "notes",
      "training_plan_id",
    ] as const
  ) {
    if (Object.prototype.hasOwnProperty.call(payload, field)) {
      updates[field] = normalizeOptionalString(payload[field]);
    }
  }

  for (
    const field of [
      "started_utc_offset_minutes",
      "duration_minutes",
      "estimated_calories",
      "perceived_exertion_rpe",
      "post_feeling",
    ] as const
  ) {
    if (Object.prototype.hasOwnProperty.call(payload, field)) {
      if (
        payload[field] != null &&
        (typeof payload[field] !== "number" || !Number.isFinite(payload[field]))
      ) {
        return jsonWithRequest(request, { error: `invalid_${field}` }, 400);
      }
      updates[field] = payload[field] == null
        ? null
        : Math.trunc(Number(payload[field]));
    }
  }

  if (Object.prototype.hasOwnProperty.call(payload, "trimp_score")) {
    if (
      payload.trimp_score != null &&
      (typeof payload.trimp_score !== "number" ||
        !Number.isFinite(payload.trimp_score))
    ) {
      return jsonWithRequest(request, { error: "invalid_trimp_score" }, 400);
    }
    updates.trimp_score = payload.trimp_score == null
      ? null
      : Number(payload.trimp_score);
  }

  let parsedExercises:
    | Array<{
      id: string;
      exercise_id: string | null;
      name: string | null;
      category: string | null;
      order_in_session: number;
      duration_seconds: number | null;
      notes: string | null;
      total_sets: number;
      total_reps: number;
      total_volume: number;
      max_weight: number;
      sets: Array<{
        id: string;
        set_number: number;
        weight: number | null;
        reps: number | null;
        rpe: number | null;
        rest_after_seconds: number | null;
        is_warmup: boolean;
        is_failure: boolean;
        is_dropset: boolean;
      }>;
    }>
    | null = null;

  if (hasExercisesPayload) {
    if (!Array.isArray(payload.exercises)) {
      return jsonWithRequest(request, { error: "invalid_exercises" }, 400);
    }

    parsedExercises = [];
    let totalSets = 0;
    let totalReps = 0;
    let totalVolume = 0;

    for (
      let exerciseIndex = 0;
      exerciseIndex < payload.exercises.length;
      exerciseIndex += 1
    ) {
      const exercise = payload.exercises[exerciseIndex] as WorkoutExerciseInput;
      if (!isPlainObject(exercise)) {
        return jsonWithRequest(request, { error: "invalid_exercise" }, 400);
      }

      const exerciseResolution = await resolveExerciseCatalogReference(
        request,
        service,
        userId,
        exercise,
      );
      if (!exerciseResolution.ok) {
        return exerciseResolution.response;
      }

      const setsInput = Array.isArray(exercise.sets) ? exercise.sets : [];
      const parsedSets: Array<{
        id: string;
        set_number: number;
        weight: number | null;
        reps: number | null;
        rpe: number | null;
        rest_after_seconds: number | null;
        is_warmup: boolean;
        is_failure: boolean;
        is_dropset: boolean;
      }> = [];

      let exerciseTotalReps = 0;
      let exerciseTotalVolume = 0;
      let exerciseMaxWeight = 0;

      for (let setIndex = 0; setIndex < setsInput.length; setIndex += 1) {
        const set = setsInput[setIndex];

        const reps = toIntegerOrNull(set.reps);
        const weight = toNumberOrNull(set.weight);
        const repsValue = Math.max(0, reps ?? 0);
        const weightValue = Math.max(0, weight ?? 0);

        exerciseTotalReps += repsValue;
        exerciseTotalVolume += repsValue * weightValue;
        exerciseMaxWeight = Math.max(exerciseMaxWeight, weightValue);

        parsedSets.push({
          id: isUUID(String(set.id ?? ""))
            ? String(set.id)
            : crypto.randomUUID(),
          set_number: typeof set.set_number === "number" &&
              Number.isFinite(set.set_number)
            ? Math.max(1, Math.trunc(set.set_number))
            : (setIndex + 1),
          weight,
          reps,
          rpe: toIntegerOrNull(set.rpe),
          rest_after_seconds: toIntegerOrNull(set.rest_after_seconds),
          is_warmup: set.is_warmup ?? false,
          is_failure: set.is_failure ?? false,
          is_dropset: set.is_dropset ?? false,
        });
      }

      totalSets += parsedSets.length;
      totalReps += exerciseTotalReps;
      totalVolume += exerciseTotalVolume;

      parsedExercises.push({
        id: isUUID(String(exercise.id ?? ""))
          ? String(exercise.id)
          : crypto.randomUUID(),
        exercise_id: exerciseResolution.exerciseId,
        name: normalizeOptionalString(exercise.name),
        category: normalizeExerciseCategory(exercise.category),
        order_in_session: typeof exercise.order_in_session === "number" &&
            Number.isFinite(exercise.order_in_session)
          ? Math.max(0, Math.trunc(exercise.order_in_session))
          : exerciseIndex,
        duration_seconds: toIntegerOrNull(exercise.duration_seconds),
        notes: normalizeOptionalString(exercise.notes),
        total_sets: parsedSets.length,
        total_reps: exerciseTotalReps,
        total_volume: exerciseTotalVolume,
        max_weight: exerciseMaxWeight,
        sets: parsedSets,
      });
    }

    updates.total_sets = totalSets > 0 ? totalSets : null;
    updates.total_reps = totalReps > 0 ? totalReps : null;
    updates.total_volume = totalVolume > 0 ? totalVolume : null;
  }

  if (!Object.prototype.hasOwnProperty.call(updates, "duration_minutes")) {
    const startedMs = Date.parse(startedAtIso);
    const endedMs = endedAtIso ? Date.parse(endedAtIso) : Number.NaN;
    if (Number.isFinite(startedMs) && Number.isFinite(endedMs)) {
      updates.duration_minutes = Math.max(
        0,
        Math.trunc((endedMs - startedMs) / 60_000),
      );
    }
  }

  const nextTrainingPlanId = Object.prototype.hasOwnProperty.call(
      updates,
      "training_plan_id",
    )
    ? (updates.training_plan_id as string | null)
    : existing.training_plan_id;
  const nextSessionDate = Object.prototype.hasOwnProperty.call(
      updates,
      "session_date",
    )
    ? String(updates.session_date)
    : existing.session_date;
  if (existing.source !== "import") {
    updates.source = nextTrainingPlanId ? "plan" : "manual";
  }

  if (Object.keys(updates).length === 0 && !parsedExercises) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  const { error: updateError } = await service
    .from("workout_sessions")
    .update(updates)
    .eq("id", sessionId)
    .eq("user_id", userId)
    .is("deleted_at", null);

  if (updateError) {
    return jsonWithRequest(request, {
      error: "workout_session_update_failed",
      detail: updateError.message,
    }, 500);
  }

  if (parsedExercises) {
    const { error: deleteExercisesError } = await service
      .from("workout_exercises")
      .delete()
      .eq("session_id", sessionId);

    if (deleteExercisesError) {
      return jsonWithRequest(request, {
        error: "workout_exercises_replace_failed",
        detail: deleteExercisesError.message,
      }, 500);
    }

    for (const exercise of parsedExercises) {
      const { error: insertExerciseError } = await service
        .from("workout_exercises")
        .insert({
          id: exercise.id,
          session_id: sessionId,
          exercise_id: exercise.exercise_id,
          order_in_session: exercise.order_in_session,
          total_sets: exercise.total_sets,
          total_reps: exercise.total_reps,
          total_volume: exercise.total_volume,
          max_weight: exercise.max_weight,
          duration_seconds: exercise.duration_seconds,
          notes: exercise.notes,
        });

      if (insertExerciseError) {
        return jsonWithRequest(request, {
          error: "workout_exercise_insert_failed",
          detail: insertExerciseError.message,
        }, 500);
      }

      for (const set of exercise.sets) {
        const { error: insertSetError } = await service
          .from("workout_sets")
          .insert({
            id: set.id,
            exercise_entry_id: exercise.id,
            user_id: userId,
            set_number: set.set_number,
            weight: set.weight,
            reps: set.reps,
            rpe: set.rpe,
            rest_after_seconds: set.rest_after_seconds,
            is_warmup: set.is_warmup,
            is_failure: set.is_failure,
            is_dropset: set.is_dropset,
          });

        if (insertSetError) {
          return jsonWithRequest(request, {
            error: "workout_set_insert_failed",
            detail: insertSetError.message,
          }, 500);
        }
      }
    }
  }

  const planSyncError = await syncTrainingPlanSessionLinkage(
    service,
    userId,
    sessionId,
    existing.training_plan_id,
    existing.session_date,
    nextTrainingPlanId,
    nextSessionDate,
  );
  if (planSyncError) {
    return jsonWithRequest(request, planSyncError.body, planSyncError.status);
  }

  return jsonWithRequest(request, {
    ok: true,
    id: sessionId,
  });
}

async function handleDeleteWorkout(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  sessionId: string,
): Promise<Response> {
  const { data: existing, error: fetchError } = await service
    .from("workout_sessions")
    .select("id,training_plan_id,session_date,deleted_at")
    .eq("id", sessionId)
    .eq("user_id", userId)
    .maybeSingle<{
      id: string;
      training_plan_id: string | null;
      session_date: string;
      deleted_at: string | null;
    }>();

  if (fetchError) {
    return jsonWithRequest(request, {
      error: "workout_session_fetch_failed",
      detail: fetchError.message,
    }, 500);
  }
  if (!existing) {
    return jsonWithRequest(request, { error: "workout_not_found" }, 404);
  }

  if (existing.deleted_at == null) {
    const { data, error } = await service
      .from("workout_sessions")
      .update({
        deleted_at: new Date().toISOString(),
        deleted_reason: "user_deleted",
      })
      .eq("id", sessionId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .select("id")
      .maybeSingle<{ id: string }>();

    if (error) {
      return jsonWithRequest(request, {
        error: "workout_delete_failed",
        detail: error.message,
      }, 500);
    }
    if (!data) {
      return jsonWithRequest(request, { error: "workout_not_found" }, 404);
    }
  }

  const planSyncError = await unlinkTrainingPlanSessionCompletion(
    service,
    userId,
    existing.training_plan_id,
    existing.session_date,
    sessionId,
  );
  if (planSyncError) {
    return jsonWithRequest(request, planSyncError.body, planSyncError.status);
  }

  return jsonWithRequest(request, {
    ok: true,
    id: sessionId,
    idempotent_replay: existing.deleted_at != null,
  });
}

async function handleUndoWorkout(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  sessionId: string,
): Promise<Response> {
  const undoSince = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data: existing, error: fetchError } = await service
    .from("workout_sessions")
    .select("id,training_plan_id,session_date,deleted_at")
    .eq("id", sessionId)
    .eq("user_id", userId)
    .maybeSingle<{
      id: string;
      training_plan_id: string | null;
      session_date: string;
      deleted_at: string | null;
    }>();

  if (fetchError) {
    return jsonWithRequest(request, {
      error: "workout_session_fetch_failed",
      detail: fetchError.message,
    }, 500);
  }
  if (!existing) {
    return jsonWithRequest(
      request,
      { error: "workout_not_found_or_expired" },
      404,
    );
  }

  let restoredSession = {
    id: existing.id,
    training_plan_id: existing.training_plan_id,
    session_date: existing.session_date,
  };

  if (existing.deleted_at != null) {
    if (existing.deleted_at < undoSince) {
      return jsonWithRequest(
        request,
        { error: "workout_not_found_or_expired" },
        404,
      );
    }

    const { data, error } = await service
      .from("workout_sessions")
      .update({ deleted_at: null, deleted_reason: null })
      .eq("id", sessionId)
      .eq("user_id", userId)
      .gte("deleted_at", undoSince)
      .select("id,training_plan_id,session_date")
      .maybeSingle<{
        id: string;
        training_plan_id: string | null;
        session_date: string;
      }>();

    if (error) {
      return jsonWithRequest(request, {
        error: "workout_undo_failed",
        detail: error.message,
      }, 500);
    }
    if (!data) {
      return jsonWithRequest(
        request,
        { error: "workout_not_found_or_expired" },
        404,
      );
    }
    restoredSession = data;
  }

  const planSyncError = await syncTrainingPlanSessionLinkage(
    service,
    userId,
    sessionId,
    null,
    restoredSession.session_date,
    restoredSession.training_plan_id,
    restoredSession.session_date,
  );
  if (planSyncError) {
    return jsonWithRequest(request, planSyncError.body, planSyncError.status);
  }

  return jsonWithRequest(request, {
    ok: true,
    id: sessionId,
    idempotent_replay: existing.deleted_at == null,
  });
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
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
    typeof import("../../_shared/supabase.ts").serviceRoleClient
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
    typeof import("../../_shared/supabase.ts").serviceRoleClient
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
    typeof import("../../_shared/supabase.ts").serviceRoleClient
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
    typeof import("../../_shared/supabase.ts").serviceRoleClient
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
        detail: error.message,
      }, 500),
    };
  }

  return { ok: true };
}

function toNumberOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return value;
}

function toIntegerOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.trunc(value);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function syncTrainingPlanSessionLinkage(
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  workoutId: string,
  previousTrainingPlanId: string | null,
  previousSessionDate: string,
  nextTrainingPlanId: string | null,
  nextSessionDate: string,
): Promise<
  {
    status: number;
    body: Record<string, string>;
  } | null
> {
  if (
    previousTrainingPlanId &&
    (
      previousTrainingPlanId !== nextTrainingPlanId ||
      previousSessionDate !== nextSessionDate
    )
  ) {
    const unlinkError = await unlinkTrainingPlanSessionCompletion(
      service,
      userId,
      previousTrainingPlanId,
      previousSessionDate,
      workoutId,
    );
    if (unlinkError) {
      return unlinkError;
    }
  }

  if (!nextTrainingPlanId) {
    return null;
  }

  return await syncTrainingPlanSessionCompletion(
    service,
    userId,
    nextTrainingPlanId,
    nextSessionDate,
    workoutId,
  );
}

async function syncTrainingPlanSessionCompletion(
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
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
    .select("id,actual_session_id")
    .eq("training_plan_id", trainingPlanId)
    .eq("user_id", userId)
    .eq("planned_date", sessionDate)
    .in("status", ["planned", "rescheduled", "completed"])
    .order("updated_at", { ascending: false })
    .returns<
      Array<{
        id: string;
        actual_session_id: string | null;
      }>
    >();

  if (candidateError) {
    return {
      status: 500,
      body: {
        error: "training_plan_session_fetch_failed",
        detail: candidateError.message,
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
        detail: updateError.message,
      },
    };
  }

  return null;
}

async function unlinkTrainingPlanSessionCompletion(
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  trainingPlanId: string | null,
  sessionDate: string,
  workoutId: string,
): Promise<
  {
    status: number;
    body: Record<string, string>;
  } | null
> {
  if (!trainingPlanId) {
    return null;
  }

  const { data: row, error: fetchError } = await service
    .from("training_plan_sessions")
    .select("id")
    .eq("training_plan_id", trainingPlanId)
    .eq("user_id", userId)
    .eq("planned_date", sessionDate)
    .eq("actual_session_id", workoutId)
    .order("updated_at", { ascending: false })
    .limit(1)
    .maybeSingle<{ id: string }>();

  if (fetchError) {
    return {
      status: 500,
      body: {
        error: "training_plan_session_fetch_failed",
        detail: fetchError.message,
      },
    };
  }
  if (!row) {
    return null;
  }

  const { error: updateError } = await service
    .from("training_plan_sessions")
    .update({
      status: "planned",
      actual_session_id: null,
    })
    .eq("id", row.id)
    .eq("user_id", userId);

  if (updateError) {
    return {
      status: 500,
      body: {
        error: "training_plan_session_update_failed",
        detail: updateError.message,
      },
    };
  }

  return null;
}
