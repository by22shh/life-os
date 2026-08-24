import { parseLocalDateRange, pathnameTail } from "../../_shared/date_range.ts";
import { isLocalDate } from "../../_shared/datetime.ts";
import {
  computeMedicalScanScheduledDeletionAt,
  loadMedicalScanPrivacySettings,
  type MedicalScanPrivacySettings,
  pruneExpiredMedicalScanArtifacts,
} from "../../_shared/medical_scan_privacy.ts";
import { jsonWithRequest } from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

interface ScanRow {
  id: string;
  user_id: string;
  created_at: string;
  updated_at: string;
  scan_type: string;
  status: string;
  storage_mode: "local_only" | "cloud";
  image_url: string | null;
  image_uploaded_at: string | null;
  original_image_url: string | null;
  extraction_status: string;
  extraction_error: string | null;
  ai_confidence: number | null;
  ocr_confidence: number | null;
  processed_data: unknown;
  scan_date: string;
  lab_name: string | null;
  document_language: string | null;
  source_file_sha256: string | null;
  store_original_in_cloud: boolean | null;
  manually_verified: boolean | null;
  needs_review: boolean | null;
  user_reviewed: boolean | null;
  user_reviewed_at: string | null;
  pinned_by_user: boolean | null;
  markers_extracted: number | null;
  notes: string | null;
  scheduled_deletion_at: string | null;
  deleted_at: string | null;
}

interface MarkerHistoryRow {
  measured_at: string;
  value: number;
  unit: string;
  status: string | null;
  source_scan_id: string | null;
}

interface ExistingMeasurementRow {
  id: string;
  marker_id: string | null;
  measured_at: string | null;
  source_scan_id: string | null;
}

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
    request.method === "GET" ? "standard" : "ai_vision",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { authUserId, userId, service } = userResult.context;

  try {
    await pruneExpiredMedicalScanArtifacts(service, userId, authUserId);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(
      `[api-labs] retention_cleanup_failed user=${userId} detail=${detail}`,
    );
  }

  if (request.method === "POST" && (route === "" || route === "scan")) {
    return await handleScanCreate(request, service, userId);
  }

  if (request.method === "GET" && route === "scan") {
    return await handleScanGet(request, service, userId, tail[1] ?? "");
  }

  if (request.method === "GET" && route === "markers") {
    if ((tail[1] ?? "").toLowerCase() === "history") {
      return await handleMarkersHistory(request, service, userId);
    }
    return await handleMarkersLatest(request, service, userId);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleScanCreate(
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

  const scanType = normalizeScanType(payload.scan_type);
  if (!scanType) {
    return jsonWithRequest(request, { error: "invalid_scan_type" }, 400);
  }

  const scanId = isUUID(String(payload.scan_id ?? ""))
    ? String(payload.scan_id)
    : crypto.randomUUID();

  let privacySettings: MedicalScanPrivacySettings;
  try {
    privacySettings = await loadMedicalScanPrivacySettings(service, userId);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return jsonWithRequest(request, {
      error: "privacy_settings_lookup_failed",
      detail,
    }, 500);
  }

  const { data: existingScan, error: existingScanError } = await service
    .from("medical_scans")
    .select(
      "id,user_id,created_at,updated_at,scan_type,status,storage_mode,image_url,image_uploaded_at,original_image_url,extraction_status,extraction_error,ai_confidence,ocr_confidence,processed_data,scan_date,lab_name,document_language,source_file_sha256,store_original_in_cloud,manually_verified,needs_review,user_reviewed,user_reviewed_at,pinned_by_user,markers_extracted,notes,scheduled_deletion_at,deleted_at",
    )
    .eq("id", scanId)
    .eq("user_id", userId)
    .maybeSingle<ScanRow>();

  if (existingScanError) {
    return jsonWithRequest(request, {
      error: "scan_lookup_failed",
      detail: existingScanError.message,
    }, 500);
  }

  const scanDate = optionalString(payload.scan_date) ??
    existingScan?.scan_date ?? "";
  if (!isLocalDate(scanDate)) {
    return jsonWithRequest(request, { error: "invalid_scan_date" }, 400);
  }

  const createdAt = toIsoStringOrNull(payload.created_at) ??
    existingScan?.created_at ??
    new Date().toISOString();
  const requestedStorageMode = normalizeStorageMode(payload.storage_mode) ??
    existingScan?.storage_mode ??
    (privacySettings.medicalScanLocalOnly ? "local_only" : "cloud");
  if (
    requestedStorageMode !== "local_only" && requestedStorageMode !== "cloud"
  ) {
    return jsonWithRequest(request, { error: "invalid_storage_mode" }, 400);
  }
  if (
    Object.prototype.hasOwnProperty.call(payload, "storage_mode") &&
    normalizeStorageMode(payload.storage_mode) == null
  ) {
    return jsonWithRequest(request, { error: "invalid_storage_mode" }, 400);
  }

  const pinnedByUser = toBooleanOrNull(payload.pinned_by_user) ??
    existingScan?.pinned_by_user ?? false;
  const storageMode = privacySettings.medicalScanLocalOnly
    ? "local_only"
    : requestedStorageMode;
  const allowStoredCloudOriginal = !privacySettings.medicalScanLocalOnly &&
    privacySettings.cloudBackupEnabled &&
    storageMode === "cloud";
  const requestedStoredAssetPath = optionalString(payload.stored_asset_path) ??
    optionalString(payload.original_image_url) ??
    existingScan?.original_image_url ??
    existingScan?.image_url ??
    null;
  const storedAssetPath = allowStoredCloudOriginal
    ? requestedStoredAssetPath
    : null;
  const requestedStoreOriginalInCloud =
    toBooleanOrNull(payload.store_original_in_cloud) ??
      existingScan?.store_original_in_cloud ??
      false;
  const storeOriginalInCloud = allowStoredCloudOriginal &&
    requestedStoreOriginalInCloud &&
    storedAssetPath != null;
  const imageUploadedAt = storeOriginalInCloud
    ? (toIsoStringOrNull(payload.image_uploaded_at) ??
      existingScan?.image_uploaded_at ??
      createdAt)
    : null;
  const scheduledDeletionAt = storeOriginalInCloud && !pinnedByUser
    ? computeMedicalScanScheduledDeletionAt(createdAt)
    : null;

  const processedData = payload.processed_data ??
    existingScan?.processed_data ?? null;
  const extractedMarkers = extractMarkers(processedData);
  const normalizedStatus = normalizeScanStatus(
    payload.status,
    extractedMarkers.length > 0,
    storageMode,
    existingScan?.status,
  );
  const extractionStatus = normalizeExtractionStatus(
    payload.extraction_status,
    normalizedStatus,
    extractedMarkers.length > 0,
    storageMode,
    existingScan?.extraction_status,
  );
  const derivedNeedsReview = normalizedStatus === "review_required" ||
    extractionStatus === "review_required";
  const payloadNeedsReview = toBooleanOrNull(payload.needs_review);
  const needsReview = derivedNeedsReview ||
    (payloadNeedsReview ?? existingScan?.needs_review ?? false);
  const reviewBlocked = needsReview ||
    normalizedStatus === "review_required" ||
    extractionStatus === "review_required";
  const canonicalManuallyVerified = reviewBlocked
    ? false
    : toBooleanOrNull(payload.manually_verified) ??
      existingScan?.manually_verified ?? false;
  const canonicalUserReviewed = reviewBlocked
    ? false
    : toBooleanOrNull(payload.user_reviewed) ??
      existingScan?.user_reviewed ?? false;
  const canonicalUserReviewedAt = canonicalUserReviewed
    ? toIsoStringOrNull(payload.user_reviewed_at) ??
      existingScan?.user_reviewed_at ?? new Date().toISOString()
    : null;

  const { error: scanError } = await service
    .from("medical_scans")
    .upsert({
      id: scanId,
      user_id: userId,
      created_at: createdAt,
      updated_at: toIsoStringOrNull(payload.updated_at) ??
        new Date().toISOString(),
      scan_type: scanType,
      status: normalizedStatus,
      scan_date: scanDate,
      lab_name: optionalString(payload.lab_name) ?? existingScan?.lab_name ??
        null,
      storage_mode: storageMode,
      store_original_in_cloud: storeOriginalInCloud,
      image_url: storedAssetPath,
      image_uploaded_at: imageUploadedAt,
      original_image_url: storedAssetPath,
      source_file_sha256: optionalString(payload.source_file_sha256) ??
        existingScan?.source_file_sha256 ??
        null,
      document_language: optionalString(payload.document_language) ??
        existingScan?.document_language ??
        null,
      ocr_confidence: toUnitFloatOrNull(payload.ocr_confidence) ??
        existingScan?.ocr_confidence ??
        null,
      ai_confidence: toUnitFloatOrNull(payload.ai_confidence) ??
        existingScan?.ai_confidence ??
        null,
      manually_verified: canonicalManuallyVerified,
      needs_review: needsReview,
      user_reviewed: canonicalUserReviewed,
      user_reviewed_at: canonicalUserReviewedAt,
      pinned_by_user: pinnedByUser,
      scheduled_deletion_at: scheduledDeletionAt,
      notes: optionalString(payload.notes) ?? existingScan?.notes ?? null,
      extraction_status: extractionStatus,
      extraction_error: optionalString(payload.extraction_error) ??
        existingScan?.extraction_error ??
        null,
      processed_data: processedData,
      markers_extracted: extractedMarkers.length,
      deleted_at: toIsoStringOrNull(payload.deleted_at) ??
        existingScan?.deleted_at ?? null,
    }, { onConflict: "id" });

  if (scanError) {
    return jsonWithRequest(request, {
      error: "scan_create_failed",
      detail: scanError.message,
    }, 500);
  }

  const existingMeasurementsResult = extractedMarkers.length > 0
    ? await service
      .from("health_measurements")
      .select("id,marker_id,measured_at,source_scan_id")
      .eq("user_id", userId)
      .eq("source_scan_id", scanId)
      .returns<ExistingMeasurementRow[]>()
    : { data: [], error: null };

  if (existingMeasurementsResult.error) {
    return jsonWithRequest(request, {
      error: "scan_measurements_lookup_failed",
      detail: existingMeasurementsResult.error.message,
    }, 500);
  }

  const existingMeasurementIdByKey = new Map<string, string>();
  for (const row of existingMeasurementsResult.data ?? []) {
    const markerId = optionalString(row.marker_id);
    const measuredAt = optionalString(row.measured_at);
    if (!markerId || !measuredAt) continue;
    existingMeasurementIdByKey.set(`${markerId}|${measuredAt}`, row.id);
  }

  const activeMeasurementIds = new Set<string>();
  for (const marker of extractedMarkers) {
    if (!marker.marker_id || marker.value == null || !marker.unit) {
      continue;
    }

    const measuredAt = scanDate;
    const measurementKey = `${marker.marker_id}|${measuredAt}`;
    const measurementId = marker.measurement_id ??
      existingMeasurementIdByKey.get(measurementKey) ??
      crypto.randomUUID();
    activeMeasurementIds.add(measurementId);

    const { error: markerError } = await service
      .from("health_measurements")
      .upsert({
        id: measurementId,
        user_id: userId,
        marker_id: marker.marker_id,
        value: marker.value,
        unit: marker.unit,
        original_value: marker.value,
        original_unit: marker.unit,
        status: marker.status,
        reference_range_low: marker.reference_range_low,
        reference_range_high: marker.reference_range_high,
        measured_at: measuredAt,
        source_scan_id: scanId,
        source_type: "scan",
        original_label: marker.original_label,
        confidence: marker.confidence,
        manually_verified: canonicalManuallyVerified,
      }, {
        onConflict: "id",
      });

    if (markerError) {
      return jsonWithRequest(request, {
        error: "scan_markers_upsert_failed",
        detail: markerError.message,
      }, 500);
    }
  }

  if (processedData != null) {
    const staleMeasurementIds = (existingMeasurementsResult.data ?? [])
      .map((row) => row.id)
      .filter((id) => !activeMeasurementIds.has(id));

    if (staleMeasurementIds.length > 0) {
      const { error: deleteError } = await service
        .from("health_measurements")
        .delete()
        .eq("user_id", userId)
        .in("id", staleMeasurementIds);

      if (deleteError) {
        return jsonWithRequest(request, {
          error: "scan_markers_delete_failed",
          detail: deleteError.message,
        }, 500);
      }
    }
  }

  return jsonWithRequest(request, {
    scan_id: scanId,
    status: normalizedStatus,
  });
}

async function handleScanGet(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  scanId: string,
): Promise<Response> {
  if (!isUUID(scanId)) {
    return jsonWithRequest(request, { error: "invalid_scan_id" }, 400);
  }

  const { data: row, error } = await service
    .from("medical_scans")
    .select(
      "id,storage_mode,original_image_url,extraction_status,ai_confidence,processed_data,scan_date",
    )
    .eq("id", scanId)
    .eq("user_id", userId)
    .maybeSingle<ScanRow>();

  if (error) {
    return jsonWithRequest(request, {
      error: "scan_fetch_failed",
      detail: error.message,
    }, 500);
  }
  if (!row) {
    return jsonWithRequest(request, { error: "scan_not_found" }, 404);
  }

  return jsonWithRequest(request, {
    scan_id: row.id,
    storage_mode: row.storage_mode,
    original_image_url: row.original_image_url,
    status: row.extraction_status,
    confidence: row.ai_confidence,
    processed_data: row.processed_data,
    scan_date: row.scan_date,
  });
}

async function handleMarkersLatest(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const markerId = (new URL(request.url).searchParams.get("marker_id") ?? "")
    .trim();
  if (!markerId) {
    return jsonWithRequest(request, { error: "marker_id_required" }, 400);
  }

  const { data: rows, error } = await service
    .from("health_measurements")
    .select("measured_at,value,unit,status")
    .eq("user_id", userId)
    .eq("marker_id", markerId)
    .order("measured_at", { ascending: false })
    .limit(120)
    .returns<
      Array<Pick<MarkerHistoryRow, "measured_at" | "value" | "unit" | "status">>
    >();

  if (error) {
    return jsonWithRequest(request, {
      error: "marker_history_fetch_failed",
      detail: error.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    marker_id: markerId,
    history: (rows ?? []).map((row) => ({
      date: row.measured_at,
      value: Number(row.value ?? 0),
      unit: row.unit,
      status: row.status,
    })),
  });
}

async function handleMarkersHistory(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const markerId = (url.searchParams.get("marker_id") ?? "").trim();
  if (!markerId) {
    return jsonWithRequest(request, { error: "marker_id_required" }, 400);
  }

  const range = parseLocalDateRange(request, 366);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const [markerRes, historyRes] = await Promise.all([
    service
      .from("health_marker_catalog")
      .select("display_name,standard_unit")
      .eq("id", markerId)
      .maybeSingle<{ display_name: string; standard_unit: string }>(),
    service
      .from("health_measurements")
      .select("measured_at,value,unit,status,source_scan_id")
      .eq("user_id", userId)
      .eq("marker_id", markerId)
      .gte("measured_at", range.from)
      .lte("measured_at", range.to)
      .order("measured_at", { ascending: true })
      .returns<MarkerHistoryRow[]>(),
  ]);

  if (markerRes.error) {
    return jsonWithRequest(request, {
      error: "marker_catalog_fetch_failed",
      detail: markerRes.error.message,
    }, 500);
  }

  if (historyRes.error) {
    return jsonWithRequest(request, {
      error: "marker_history_fetch_failed",
      detail: historyRes.error.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    marker_id: markerId,
    marker_name: markerRes.data?.display_name ?? markerId,
    unit: markerRes.data?.standard_unit ?? null,
    history: (historyRes.data ?? []).map((row) => ({
      date: row.measured_at,
      value: Number(row.value ?? 0),
      status: row.status,
      scan_id: row.source_scan_id,
      unit: row.unit,
    })),
  });
}

function extractMarkers(processedData: unknown): Array<{
  measurement_id: string | null;
  marker_id: string;
  value: number | null;
  unit: string;
  status: string | null;
  original_label: string | null;
  confidence: number | null;
  reference_range_low: number | null;
  reference_range_high: number | null;
}> {
  if (!isObject(processedData)) return [];
  if (!Array.isArray(processedData.markers)) return [];

  const out: Array<{
    measurement_id: string | null;
    marker_id: string;
    value: number | null;
    unit: string;
    status: string | null;
    original_label: string | null;
    confidence: number | null;
    reference_range_low: number | null;
    reference_range_high: number | null;
  }> = [];

  for (const raw of processedData.markers) {
    if (!isObject(raw)) continue;
    out.push({
      measurement_id: optionalUUID(raw.measurement_id),
      marker_id: typeof raw.marker_id === "string" ? raw.marker_id.trim() : "",
      value: toNumberOrNull(raw.value),
      unit: typeof raw.unit === "string" ? raw.unit.trim() : "",
      status: normalizeMeasurementStatus(
        typeof raw.status === "string" ? raw.status.trim() : null,
        toNumberOrNull(raw.value),
        toNumberOrNull(raw.reference_range_low),
        toNumberOrNull(raw.reference_range_high),
      ),
      original_label: typeof raw.original_label === "string"
        ? raw.original_label.trim()
        : null,
      confidence: toUnitFloatOrNull(raw.confidence),
      reference_range_low: toNumberOrNull(raw.reference_range_low),
      reference_range_high: toNumberOrNull(raw.reference_range_high),
    });
  }

  return out;
}

function normalizeMeasurementStatus(
  rawStatus: string | null,
  value: number | null,
  referenceRangeLow: number | null,
  referenceRangeHigh: number | null,
): string | null {
  const inferred = inferMeasurementStatus(
    value,
    referenceRangeLow,
    referenceRangeHigh,
  );
  if (!rawStatus) return inferred;

  switch (rawStatus.trim().toLowerCase()) {
    case "critical_low":
    case "low":
    case "optimal":
    case "high":
    case "critical_high":
      return rawStatus.trim().toLowerCase();
    case "normal":
    case "within_range":
    case "within range":
    case "in_range":
      return "optimal";
    case "out_of_range":
    case "out of range":
    case "abnormal":
      return inferred === "optimal" ? null : inferred;
    default:
      return inferred;
  }
}

function inferMeasurementStatus(
  value: number | null,
  referenceRangeLow: number | null,
  referenceRangeHigh: number | null,
): string | null {
  if (value == null) return null;
  if (referenceRangeLow != null && value < referenceRangeLow) return "low";
  if (referenceRangeHigh != null && value > referenceRangeHigh) return "high";
  if (referenceRangeLow != null || referenceRangeHigh != null) return "optimal";
  return null;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function optionalUUID(value: unknown): string | null {
  const normalized = optionalString(value);
  if (!normalized || !isUUID(normalized)) return null;
  return normalized;
}

function toBooleanOrNull(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (value === 1) return true;
    if (value === 0) return false;
    return null;
  }
  if (typeof value === "string") {
    switch (value.trim().toLowerCase()) {
      case "true":
      case "1":
        return true;
      case "false":
      case "0":
        return false;
      default:
        return null;
    }
  }
  return null;
}

function normalizeStorageMode(value: unknown): "local_only" | "cloud" | null {
  const normalized = optionalString(value)?.toLowerCase();
  if (normalized === "local_only" || normalized === "cloud") {
    return normalized;
  }
  return null;
}

function toIsoStringOrNull(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString();
}

function normalizeScanType(value: unknown): string | null {
  if (typeof value !== "string") return null;

  switch (value.trim().toLowerCase()) {
    case "blood_test":
    case "bloodwork":
      return "blood_test";
    case "inbody":
      return "inbody";
    case "dexa":
      return "dexa";
    case "other":
    case "urine":
    case "body_composition":
      return "other";
    default:
      return null;
  }
}

function toNumberOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Number(value);
}

function toUnitFloatOrNull(value: unknown): number | null {
  const parsed = toNumberOrNull(value);
  if (parsed == null) return null;
  if (parsed < 0 || parsed > 1) return null;
  return parsed;
}

function normalizeScanStatus(
  value: unknown,
  hasProcessedMarkers: boolean,
  storageMode: "local_only" | "cloud",
  fallback: string | null | undefined,
): string {
  const candidate = optionalString(value)?.toLowerCase() ??
    optionalString(fallback)?.toLowerCase();
  switch (candidate) {
    case "pending":
    case "processing":
    case "completed":
    case "review_required":
    case "failed":
      return candidate;
    default:
      return hasProcessedMarkers
        ? "completed"
        : storageMode === "cloud"
        ? "processing"
        : "pending";
  }
}

function normalizeExtractionStatus(
  value: unknown,
  normalizedStatus: string,
  hasProcessedMarkers: boolean,
  storageMode: "local_only" | "cloud",
  fallback: string | null | undefined,
): string {
  const candidate = optionalString(value)?.toLowerCase() ??
    optionalString(fallback)?.toLowerCase();
  switch (candidate) {
    case "pending":
    case "processing":
    case "completed":
    case "review_required":
    case "failed":
      return candidate;
    default:
      if (normalizedStatus === "review_required") return "review_required";
      return hasProcessedMarkers
        ? "completed"
        : storageMode === "cloud"
        ? "processing"
        : "pending";
  }
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
