import { parseLocalDateRange, pathnameTail } from "../../_shared/date_range.ts";
import {
  localDateInTimeZone,
  safeTimeZone,
  utcOffsetMinutesAt,
} from "../../_shared/datetime.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

const NUMERIC_FIELDS = new Set([
  "weight_kg",
  "body_fat_percent",
  "muscle_mass_kg",
  "water_percent",
  "bone_mass_kg",
  "visceral_fat_level",
  "metabolic_age",
  "bmi",
  "bmr_kcal",
  "protein_kg",
  "minerals_kg",
  "skeletal_muscle_percent",
  "lean_body_mass_kg",
  "fat_mass_kg",
  "fitness_score",
  "waist_hip_ratio",
  "target_weight_kg",
  "weight_control_kg",
  "fat_control_kg",
  "muscle_control_kg",
  "ai_confidence",
]);

const STRING_FIELDS = new Set([
  "device_name",
  "scan_image_url",
]);

const JSON_FIELDS = new Set([
  "segmental_lean",
  "segmental_fat",
  "impedance_data",
  "ai_extraction_raw",
]);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST", "PATCH", "DELETE"].includes(request.method)) {
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

  if (request.method === "POST" && (route === "" || route === "log")) {
    return await handleCreate(request, service, userId);
  }

  if (request.method === "GET" && route === "history") {
    return await handleHistory(request, service, userId);
  }

  if (request.method === "PATCH" && isUUID(route)) {
    return await handlePatch(request, service, userId, route);
  }

  if (request.method === "DELETE" && isUUID(route)) {
    return await handleDelete(request, service, userId, route);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleCreate(
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

  const measuredAt = parseTimestamp(payload.measured_at);
  if (!measuredAt) {
    return jsonWithRequest(request, { error: "invalid_measured_at" }, 400);
  }
  const userTimeZone = await loadUserTimeZone(service, userId);
  const localMetadata = resolveMeasuredLocalMetadata(
    payload,
    measuredAt,
    userTimeZone,
  );
  if ("error" in localMetadata) {
    return jsonWithRequest(request, { error: localMetadata.error }, 400);
  }

  const weightKg = toNumberOrNull(payload.weight_kg);
  if (weightKg == null || weightKg <= 0) {
    return jsonWithRequest(request, { error: "invalid_weight_kg" }, 400);
  }

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const rowId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());

  const row: Record<string, unknown> = {
    id: rowId,
    user_id: userId,
    measured_at: measuredAt.toISOString(),
    measured_date: localMetadata.measuredDate,
    measured_timezone: localMetadata.measuredTimezone,
    measured_utc_offset_minutes: localMetadata.measuredUtcOffsetMinutes,
    weight_kg: weightKg,
    input_type: normalizeInputType(payload.input_type),
    source: normalizeSource(payload.source),
    user_corrected: Boolean(payload.user_corrected),
  };

  if (
    Object.prototype.hasOwnProperty.call(payload, "input_type") &&
    row.input_type == null
  ) {
    return jsonWithRequest(request, { error: "invalid_input_type" }, 400);
  }
  if (
    Object.prototype.hasOwnProperty.call(payload, "source") &&
    row.source == null
  ) {
    return jsonWithRequest(request, { error: "invalid_source" }, 400);
  }

  for (const key of NUMERIC_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      row[key] = toNumberOrNull(payload[key]);
    }
  }

  for (const key of STRING_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      row[key] = optionalString(payload[key]);
    }
  }

  for (const key of JSON_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      row[key] = payload[key] ?? null;
    }
  }

  if (Object.prototype.hasOwnProperty.call(payload, "report_date")) {
    row.report_date = normalizeDateOnly(payload.report_date);
  }

  if (
    Object.prototype.hasOwnProperty.call(payload, "previous_measurement_id")
  ) {
    row.previous_measurement_id =
      isUUID(String(payload.previous_measurement_id ?? ""))
        ? String(payload.previous_measurement_id)
        : null;
  }

  const { data, error } = await service
    .from("body_composition")
    .upsert(row, { onConflict: "id" })
    .select("*")
    .single<Record<string, unknown>>();

  if (error) {
    return jsonWithRequest(request, {
      error: "body_composition_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, data);
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
    .from("body_composition")
    .select("*")
    .eq("user_id", userId)
    .gte("measured_date", range.from)
    .lte("measured_date", range.to)
    .is("deleted_at", null)
    .order("measured_at", { ascending: false })
    .returns<Record<string, unknown>[]>();

  if (error) {
    return jsonWithRequest(request, {
      error: "body_composition_history_fetch_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    items: data ?? [],
  });
}

async function handlePatch(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  rowId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const updates: Record<string, unknown> = {};
  const localMetadataTouched = [
    "measured_at",
    "measured_date",
    "measured_timezone",
    "measured_utc_offset_minutes",
  ].some((key) => Object.prototype.hasOwnProperty.call(payload, key));

  for (const key of NUMERIC_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      updates[key] = toNumberOrNull(payload[key]);
    }
  }

  for (const key of STRING_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      updates[key] = optionalString(payload[key]);
    }
  }

  for (const key of JSON_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      updates[key] = payload[key] ?? null;
    }
  }

  if (Object.prototype.hasOwnProperty.call(payload, "input_type")) {
    const inputType = normalizeInputType(payload.input_type);
    if (inputType == null) {
      return jsonWithRequest(request, { error: "invalid_input_type" }, 400);
    }
    updates.input_type = inputType;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "source")) {
    const source = normalizeSource(payload.source);
    if (source == null) {
      return jsonWithRequest(request, { error: "invalid_source" }, 400);
    }
    updates.source = source;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "measured_at")) {
    const measuredAt = parseTimestamp(payload.measured_at);
    if (!measuredAt) {
      return jsonWithRequest(request, { error: "invalid_measured_at" }, 400);
    }
    updates.measured_at = measuredAt.toISOString();
  }

  if (Object.prototype.hasOwnProperty.call(payload, "report_date")) {
    updates.report_date = normalizeDateOnly(payload.report_date);
  }

  if (Object.prototype.hasOwnProperty.call(payload, "user_corrected")) {
    if (typeof payload.user_corrected !== "boolean") {
      return jsonWithRequest(request, { error: "invalid_user_corrected" }, 400);
    }
    updates.user_corrected = payload.user_corrected;
  }

  if (Object.keys(updates).length === 0 && !localMetadataTouched) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  if (localMetadataTouched) {
    const { data: existingRow, error: existingRowError } = await service
      .from("body_composition")
      .select("measured_at")
      .eq("id", rowId)
      .eq("user_id", userId)
      .is("deleted_at", null)
      .maybeSingle<{ measured_at: string }>();
    if (existingRowError) {
      return jsonWithRequest(request, {
        error: "body_composition_update_failed",
        detail: sanitizedInternalDetail(request, "index", existingRowError),
      }, 500);
    }
    if (!existingRow) {
      return jsonWithRequest(
        request,
        { error: "body_composition_not_found" },
        404,
      );
    }

    const measuredAt =
      Object.prototype.hasOwnProperty.call(payload, "measured_at")
        ? parseTimestamp(payload.measured_at)
        : parseTimestamp(existingRow.measured_at);
    if (!measuredAt) {
      return jsonWithRequest(request, { error: "invalid_measured_at" }, 400);
    }

    const userTimeZone = await loadUserTimeZone(service, userId);
    const localMetadata = resolveMeasuredLocalMetadata(
      payload,
      measuredAt,
      userTimeZone,
    );
    if ("error" in localMetadata) {
      return jsonWithRequest(request, { error: localMetadata.error }, 400);
    }

    updates.measured_date = localMetadata.measuredDate;
    updates.measured_timezone = localMetadata.measuredTimezone;
    updates.measured_utc_offset_minutes =
      localMetadata.measuredUtcOffsetMinutes;
  }

  const { data, error } = await service
    .from("body_composition")
    .update(updates)
    .eq("id", rowId)
    .eq("user_id", userId)
    .is("deleted_at", null)
    .select("*")
    .maybeSingle<Record<string, unknown>>();

  if (error) {
    return jsonWithRequest(request, {
      error: "body_composition_update_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  if (!data) {
    return jsonWithRequest(
      request,
      { error: "body_composition_not_found" },
      404,
    );
  }

  return jsonWithRequest(request, data);
}

async function handleDelete(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  rowId: string,
): Promise<Response> {
  const { error } = await service
    .from("body_composition")
    .delete()
    .eq("id", rowId)
    .eq("user_id", userId);

  if (error) {
    return jsonWithRequest(request, {
      error: "body_composition_delete_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(request, { ok: true });
}

function parseTimestamp(value: unknown): Date | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeDateOnly(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return null;
  return trimmed;
}

function normalizeTimeZoneInput(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: trimmed }).format(new Date());
    return trimmed;
  } catch {
    return null;
  }
}

function normalizeInputType(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (!["home_scale", "professional_report"].includes(normalized)) return null;
  return normalized;
}

function normalizeSource(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  if (
    [
      "healthkit",
      "manual",
      "photo_scan",
      "withings",
      "renpho",
      "xiaomi",
      "tanita",
      "garmin",
      "inbody",
      "seca",
      "dexa",
      "other",
    ].includes(normalized)
  ) {
    return normalized;
  }
  return null;
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

function parseUtcOffset(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const parsed = Math.trunc(value);
  if (parsed < -14 * 60 || parsed > 14 * 60) return null;
  return parsed;
}

function resolveMeasuredLocalMetadata(
  payload: Record<string, unknown>,
  measuredAt: Date,
  fallbackTimeZone: string,
):
  | {
    measuredDate: string;
    measuredTimezone: string;
    measuredUtcOffsetMinutes: number;
  }
  | { error: string } {
  const explicitTimeZoneProvided = Object.prototype.hasOwnProperty.call(
    payload,
    "measured_timezone",
  );
  const explicitTimeZone = explicitTimeZoneProvided
    ? normalizeTimeZoneInput(payload.measured_timezone)
    : null;
  if (explicitTimeZoneProvided && explicitTimeZone == null) {
    return { error: "invalid_measured_timezone" };
  }

  const resolvedTimeZone = explicitTimeZone ?? safeTimeZone(fallbackTimeZone);
  const derivedMeasuredDate = localDateInTimeZone(measuredAt, resolvedTimeZone);
  const derivedUtcOffsetMinutes = utcOffsetMinutesAt(
    measuredAt,
    resolvedTimeZone,
  );

  if (Object.prototype.hasOwnProperty.call(payload, "measured_date")) {
    const measuredDate = normalizeDateOnly(payload.measured_date);
    if (measuredDate == null || measuredDate !== derivedMeasuredDate) {
      return { error: "invalid_measured_date" };
    }
  }

  if (
    Object.prototype.hasOwnProperty.call(payload, "measured_utc_offset_minutes")
  ) {
    const explicitOffset = parseUtcOffset(payload.measured_utc_offset_minutes);
    if (
      explicitOffset == null || explicitOffset !== derivedUtcOffsetMinutes
    ) {
      return { error: "invalid_measured_utc_offset_minutes" };
    }
  }

  return {
    measuredDate: derivedMeasuredDate,
    measuredTimezone: resolvedTimeZone,
    measuredUtcOffsetMinutes: derivedUtcOffsetMinutes,
  };
}

function toNumberOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Number(value);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
