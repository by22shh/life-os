import { serviceRoleClient } from "./supabase.ts";

const PAGE_SIZE = 1_000;
const EXPORT_TTL_MS = 24 * 60 * 60 * 1_000;

// Download tokens are high-entropy UUIDs, but they are stored as SHA-256
// digests so a database leak does not expose usable export URLs.
export async function hashDownloadToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

type ServiceClient = ReturnType<typeof serviceRoleClient>;
type ExportQuery = ReturnType<ReturnType<ServiceClient["from"]>["select"]>;

interface ExportArtifactRow {
  job_id: string;
  user_id: string;
  download_token: string;
  file_name: string;
  content_type?: string | null;
  expires_at: string;
}

interface ExportJobRow {
  id: string;
  status: string;
  download_url: string | null;
  completed_at: string | null;
  failure_reason: string | null;
}

export async function ensureExportReady(
  service: ServiceClient,
  userId: string,
  jobId: string,
  origin: string,
): Promise<{ status: string; downloadUrl: string | null }> {
  const artifact = await fetchExportArtifact(service, jobId, userId);
  if (artifact) {
    if (isExpired(artifact.expires_at)) {
      await expireExport(service, jobId);
      return { status: "expired", downloadUrl: null };
    }

    // The raw token is never persisted (only its digest), so there is no
    // stored URL to reuse: every status poll rotates the artifact token and
    // issues a fresh short-lived download URL in the response only.
    const rotated = await rotateExportArtifactToken(
      service,
      jobId,
      userId,
      origin,
    );

    await service
      .from("export_jobs")
      .update({
        status: "ready",
        completed_at: new Date().toISOString(),
        failure_reason: null,
      })
      .eq("id", jobId)
      .eq("user_id", userId);
    return { status: "ready", downloadUrl: rotated.downloadUrl };
  }

  const currentJobResult = await service
    .from("export_jobs")
    .select("id,status,download_url,completed_at,failure_reason")
    .eq("id", jobId)
    .eq("user_id", userId)
    .maybeSingle();
  const currentJob = currentJobResult.data as ExportJobRow | null;

  if (currentJob?.status === "expired") {
    return { status: "expired", downloadUrl: null };
  }

  await service
    .from("export_jobs")
    .update({
      status: "processing",
      failure_reason: null,
    })
    .eq("id", jobId)
    .eq("user_id", userId);

  try {
    const payload = await buildExportPayload(service, userId);
    const { downloadToken, downloadUrl } = await rotateExportArtifactToken(
      service,
      jobId,
      userId,
      origin,
      { skipUpsert: true },
    );
    const now = new Date();
    const expiresAt = new Date(now.getTime() + EXPORT_TTL_MS);
    const fileName = `lifeos_export_${userId.slice(0, 8)}_${
      isoDateStamp(now)
    }.json`;

    const { error: artifactError } = await service
      .from("export_artifacts")
      .upsert({
        job_id: jobId,
        user_id: userId,
        download_token: await hashDownloadToken(downloadToken),
        payload_json: payload,
        content_type: "application/json",
        file_name: fileName,
        expires_at: expiresAt.toISOString(),
        updated_at: now.toISOString(),
      }, { onConflict: "job_id" });

    if (artifactError) throw artifactError;

    const { error: jobError } = await service
      .from("export_jobs")
      .update({
        status: "ready",
        completed_at: now.toISOString(),
        failure_reason: null,
      })
      .eq("id", jobId)
      .eq("user_id", userId);

    if (jobError) throw jobError;

    return { status: "ready", downloadUrl };
  } catch (error) {
    const failureReason = exportFailureReason(error);
    await service
      .from("export_jobs")
      .update({
        status: "failed",
        failure_reason: failureReason,
      })
      .eq("id", jobId)
      .eq("user_id", userId);
    throw error;
  }
}

export async function fetchReadyExportArtifact(
  service: ServiceClient,
  userId: string,
  jobId: string,
  token: string,
): Promise<
  {
    artifact: ExportArtifactRow;
    payload: unknown;
  } | null
> {
  const tokenDigest = await hashDownloadToken(token);
  const artifactResult = await service
    .from("export_artifacts")
    .select(
      "job_id,user_id,download_token,file_name,content_type,expires_at,payload_json",
    )
    .eq("job_id", jobId)
    .eq("user_id", userId)
    .eq("download_token", tokenDigest)
    .maybeSingle();
  const data = artifactResult.data as
    | (ExportArtifactRow & { payload_json: unknown })
    | null;
  const error = artifactResult.error;

  if (error || !data) {
    return null;
  }

  if (isExpired(data.expires_at)) {
    await expireExport(service, jobId);
    return null;
  }

  return {
    artifact: data,
    payload: data.payload_json,
  };
}

async function fetchExportArtifact(
  service: ServiceClient,
  jobId: string,
  userId: string,
): Promise<ExportArtifactRow | null> {
  const artifactResult = await service
    .from("export_artifacts")
    .select("job_id,user_id,download_token,file_name,expires_at")
    .eq("job_id", jobId)
    .eq("user_id", userId)
    .maybeSingle();
  const data = artifactResult.data as ExportArtifactRow | null;
  const error = artifactResult.error;

  if (error || !data) {
    return null;
  }
  return data;
}

// Generates a fresh download token, persists only its digest and returns the
// raw token so the caller can build a one-time-issued URL. Used both when an
// artifact is first created and when a legacy artifact has no reusable URL.
async function rotateExportArtifactToken(
  service: ServiceClient,
  jobId: string,
  userId: string,
  origin: string,
  options: { skipUpsert?: boolean } = {},
): Promise<{ downloadToken: string; downloadUrl: string }> {
  const downloadToken = crypto.randomUUID();
  const downloadUrl = buildDownloadURL(origin, jobId, downloadToken);

  if (options.skipUpsert) {
    return { downloadToken, downloadUrl };
  }

  const now = new Date();
  const { error } = await service
    .from("export_artifacts")
    .update({
      download_token: await hashDownloadToken(downloadToken),
      updated_at: now.toISOString(),
    })
    .eq("job_id", jobId)
    .eq("user_id", userId);

  if (error) throw error;
  return { downloadToken, downloadUrl };
}

async function expireExport(service: ServiceClient, jobId: string) {
  await service
    .from("export_jobs")
    .update({
      status: "expired",
      download_url: null,
    })
    .eq("id", jobId);
}

function buildDownloadURL(
  origin: string,
  jobId: string,
  token: string,
): string {
  const url = new URL("/functions/v1/api-user-export-download", origin);
  url.searchParams.set("export_id", jobId);
  url.searchParams.set("token", token);
  return url.toString();
}

function isExpired(isoTimestamp: string): boolean {
  const parsed = new Date(isoTimestamp);
  return Number.isNaN(parsed.getTime()) || parsed.getTime() <= Date.now();
}

function isoDateStamp(date: Date): string {
  return date.toISOString().slice(0, 10).replaceAll("-", "");
}

function exportFailureReason(error: unknown): string {
  if (error instanceof Error) return error.message.slice(0, 512);
  return String(error).slice(0, 512);
}

// MARK: - Sensitive Field Redaction for Export
// Prevents leaking GPS coordinates, raw image URLs, and AI extraction blobs
// in user data exports (GDPR data portability).

const REDACTED_KEYS = new Set([
  "location_lat",
  "location_lng",
  "gps_latitude",
  "gps_longitude",
  "original_image_url",
  "image_url",
  "ai_extraction_raw",
  "raw_document",
  "raw_pdf",
  "raw_image",
  "device_token", // push notification token
  "apns_token",
  "image_uploaded_at", // timing metadata for image uploads
]);

const REDACTED_PLACEHOLDER = "[REDACTED]";

function redactSensitiveFields(value: unknown): unknown {
  if (value === null || value === undefined) return value;
  if (Array.isArray(value)) {
    return value.map(redactSensitiveFields);
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const redacted: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(obj)) {
      if (REDACTED_KEYS.has(key) && child !== null && child !== undefined) {
        redacted[key] = REDACTED_PLACEHOLDER;
      } else {
        redacted[key] = redactSensitiveFields(child);
      }
    }
    return redacted;
  }
  return value;
}

async function buildExportPayload(
  service: ServiceClient,
  userId: string,
): Promise<Record<string, unknown>> {
  const [
    profile,
    notificationSettings,
    privacySettings,
    onboardingState,
    userBaselines,
    healthFlags,
  ] = await Promise.all([
    fetchMaybeSingle(service, "users", "id", userId),
    fetchMaybeSingle(service, "notification_settings", "user_id", userId),
    fetchMaybeSingle(service, "privacy_settings", "user_id", userId),
    fetchMaybeSingle(service, "onboarding_state", "user_id", userId),
    fetchMaybeSingle(service, "user_baselines", "user_id", userId),
    fetchMaybeSingle(service, "user_health_flags", "user_id", userId),
  ]);

  const [
    physiologicalStates,
    wellnessChecks,
    hydrationLogs,
    bodyComposition,
    foodLogs,
    foodItems,
    userFoods,
    userFoodFavorites,
    mealTemplates,
    batchRecipes,
    dailyNutritionTargets,
    workoutSessions,
    trainingPlans,
    trainingTemplates,
    userSupplements,
    supplementLogs,
    sleepLogs,
    menstrualLogs,
    medicalScans,
    healthMeasurements,
    healthDiagnoses,
    experiments,
    insights,
    recommendations,
    weeklyStrategyReports,
    consentRecords,
    notificationLog,
    analyticsEvents,
  ] = await Promise.all([
    fetchAllByUserId(service, "physiological_states", userId),
    fetchAllByUserId(service, "wellness_checks", userId),
    fetchAllByUserId(service, "hydration_logs", userId),
    fetchAllByUserId(service, "body_composition", userId),
    fetchAllByUserId(service, "food_logs", userId),
    fetchAllByUserId(service, "food_items", userId),
    fetchAllByUserId(service, "user_foods", userId),
    fetchAllByUserId(service, "user_food_favorites", userId),
    fetchAllByUserId(service, "meal_templates", userId),
    fetchAllByUserId(service, "batch_recipes", userId),
    fetchAllByUserId(service, "daily_nutrition_targets", userId),
    fetchAllByUserId(service, "workout_sessions", userId),
    fetchAllByUserId(service, "training_plans", userId),
    fetchAllByUserId(service, "training_templates", userId),
    fetchAllByUserId(service, "user_supplements", userId),
    fetchAllByUserId(service, "supplement_logs", userId),
    fetchAllByUserId(service, "sleep_logs", userId),
    fetchAllByUserId(service, "menstrual_logs", userId),
    fetchAllByUserId(service, "medical_scans", userId),
    fetchAllByUserId(service, "health_measurements", userId),
    fetchAllByUserId(service, "health_diagnoses", userId),
    fetchAllByUserId(service, "experiments", userId),
    fetchAllByUserId(service, "insights", userId),
    fetchAllByUserId(service, "recommendations", userId),
    fetchAllByUserId(service, "weekly_strategy_reports", userId),
    fetchAllByUserId(service, "consent_records", userId),
    fetchAllByUserId(service, "notification_log", userId),
    fetchAllByUserId(service, "analytics_events", userId),
  ]);

  const batchRecipeIds = collectIds(batchRecipes);
  const workoutSessionIds = collectIds(workoutSessions);
  const trainingPlanIds = collectIds(trainingPlans);
  const experimentIds = collectIds(experiments);
  const workoutExercises = await fetchAllByIds(
    service,
    "workout_exercises",
    "session_id",
    workoutSessionIds,
  );
  const workoutSets = await fetchAllByIds(
    service,
    "workout_sets",
    "exercise_entry_id",
    collectIds(workoutExercises),
  );
  const trainingPlanSessions = await fetchAllByIds(
    service,
    "training_plan_sessions",
    "training_plan_id",
    trainingPlanIds,
  );
  const batchRecipeIngredients = await fetchAllByIds(
    service,
    "batch_recipe_ingredients",
    "batch_recipe_id",
    batchRecipeIds,
  );
  const experimentMeasurements = await fetchAllByIds(
    service,
    "experiment_measurements",
    "experiment_id",
    experimentIds,
  );
  const vectorSummaryCount = await fetchCountByUserId(
    service,
    "vector_memory",
    userId,
  );

  const rawPayload = {
    metadata: {
      export_version: "1.0",
      export_date: new Date().toISOString(),
      user_id: userId,
      format: "json",
    },
    profile,
    settings: {
      notification_settings: notificationSettings,
      privacy_settings: privacySettings,
    },
    onboarding: {
      onboarding_state: onboardingState,
      user_baselines: userBaselines,
      user_health_flags: healthFlags,
    },
    health: {
      physiological_states: physiologicalStates,
      wellness_checks: wellnessChecks,
      hydration_logs: hydrationLogs,
      body_composition: bodyComposition,
      sleep_logs: sleepLogs,
      menstrual_logs: menstrualLogs,
      medical_scans: medicalScans,
      health_measurements: healthMeasurements,
      health_diagnoses: healthDiagnoses,
    },
    nutrition: {
      food_logs: foodLogs,
      food_items: foodItems,
      user_foods: userFoods,
      user_food_favorites: userFoodFavorites,
      meal_templates: mealTemplates,
      batch_recipes: batchRecipes,
      batch_recipe_ingredients: batchRecipeIngredients,
      daily_nutrition_targets: dailyNutritionTargets,
    },
    training: {
      workout_sessions: workoutSessions,
      workout_exercises: workoutExercises,
      workout_sets: workoutSets,
      training_plans: trainingPlans,
      training_plan_sessions: trainingPlanSessions,
      training_templates: trainingTemplates,
    },
    supplements: {
      user_supplements: userSupplements,
      supplement_logs: supplementLogs,
    },
    experiments: {
      experiments,
      experiment_measurements: experimentMeasurements,
    },
    insights: {
      insights,
      recommendations,
      weekly_strategy_reports: weeklyStrategyReports,
    },
    privacy: {
      consent_records: consentRecords,
      notification_log: notificationLog,
      analytics_events: analyticsEvents,
      vector_summary: {
        entry_count: vectorSummaryCount,
      },
    },
  };

  // Redact sensitive fields (GPS, image URLs, raw AI data, device tokens)
  // before the payload is persisted as an export artifact.
  return redactSensitiveFields(rawPayload) as Record<string, unknown>;
}

async function fetchMaybeSingle(
  service: ServiceClient,
  table: string,
  column: string,
  value: string,
): Promise<Record<string, unknown> | null> {
  const rowResult = await service
    .from(table)
    .select("*")
    .eq(column, value)
    .maybeSingle();
  const data = rowResult.data as Record<string, unknown> | null;
  const error = rowResult.error;

  if (error) {
    if (isMissingRelationError(error)) {
      return null;
    }
    throw error;
  }
  return data ?? null;
}

async function fetchAllByUserId(
  service: ServiceClient,
  table: string,
  userId: string,
): Promise<Record<string, unknown>[]> {
  return await fetchAllPaged(
    service,
    table,
    (query) => query.eq("user_id", userId),
  );
}

async function fetchAllByIds(
  service: ServiceClient,
  table: string,
  column: string,
  ids: string[],
): Promise<Record<string, unknown>[]> {
  if (ids.length === 0) {
    return [];
  }

  const rows: Record<string, unknown>[] = [];
  for (let index = 0; index < ids.length; index += 200) {
    const chunk = ids.slice(index, index + 200);
    rows.push(
      ...await fetchAllPaged(
        service,
        table,
        (query) => query.in(column, chunk),
      ),
    );
  }
  return rows;
}

async function fetchCountByUserId(
  service: ServiceClient,
  table: string,
  userId: string,
): Promise<number> {
  const { count, error } = await service
    .from(table)
    .select("*", { count: "exact", head: true })
    .eq("user_id", userId);

  if (error) {
    if (isMissingRelationError(error)) return 0;
    throw error;
  }

  return count ?? 0;
}

async function fetchAllPaged(
  service: ServiceClient,
  table: string,
  applyFilters: (query: ExportQuery) => ExportQuery,
): Promise<Record<string, unknown>[]> {
  const rows: Record<string, unknown>[] = [];
  let from = 0;

  while (true) {
    let query = service.from(table).select("*");
    query = applyFilters(query);
    const { data, error } = await query.range(from, from + PAGE_SIZE - 1);

    if (error) {
      if (isMissingRelationError(error)) return [];
      throw error;
    }

    const batch = (data ?? []) as Record<string, unknown>[];
    rows.push(...batch);
    if (batch.length < PAGE_SIZE) {
      return rows;
    }

    from += PAGE_SIZE;
  }
}

function collectIds(rows: Record<string, unknown>[]): string[] {
  return rows
    .map((row) => typeof row.id === "string" ? row.id : null)
    .filter((value): value is string => value !== null);
}

function isMissingRelationError(
  error: { code?: string; message?: string },
): boolean {
  return error.code === "42P01" ||
    error.message?.includes("does not exist") === true;
}

export const __exportBuilderTestHooks = {
  buildDownloadURL,
  buildExportPayload,
  collectIds,
  expireExport,
  exportFailureReason,
  fetchAllByIds,
  fetchAllByUserId,
  fetchAllPaged,
  fetchCountByUserId,
  fetchExportArtifact,
  fetchMaybeSingle,
  hashDownloadToken,
  isExpired,
  isMissingRelationError,
  isoDateStamp,
  redactSensitiveFields,
};
