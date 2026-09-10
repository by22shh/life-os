import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

const integerFields = [
  "total_duration_minutes",
  "time_in_bed_minutes",
  "deep_sleep_minutes",
  "rem_sleep_minutes",
  "light_sleep_minutes",
  "awake_minutes",
  "number_of_awakenings",
];
const percentFields = ["sleep_efficiency", "sleep_quality_score"];
const timestampFields = ["bed_time", "wake_time", "deleted_at"];
const isUUID = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;
  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }
  const context = await resolveUserContext(request, "write_heavy", {
    allowOutboxReplayExemption: true,
  });
  if (!context.ok) return context.response;
  let input: Record<string, unknown>;
  try {
    const parsed = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error();
    }
    input = parsed;
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const day = input.sleep_date ?? input.date;
  if (
    !isUUID(input.id) || typeof day !== "string" ||
    !/^\d{4}-\d{2}-\d{2}$/.test(day) || !Number.isFinite(Date.parse(day)) ||
    new Date(day).toISOString().slice(0, 10) !== day
  ) {
    return jsonWithRequest(request, { error: "invalid_sleep_identity" }, 400);
  }
  if (
    !["manual", "healthkit", "wearable", "import"].includes(
      String(input.source),
    )
  ) return jsonWithRequest(request, { error: "invalid_source" }, 400);
  if (
    typeof input.updated_at !== "string" ||
    !Number.isFinite(Date.parse(input.updated_at))
  ) return jsonWithRequest(request, { error: "invalid_updated_at" }, 400);
  const row: Record<string, unknown> = {
    id: input.id,
    sleep_date: day,
    source: input.source,
    client_updated_at: input.updated_at,
  };
  for (const field of [...integerFields, ...percentFields]) {
    const value = input[field] ?? null;
    if (
      value !== null &&
      (typeof value !== "number" || !Number.isFinite(value) || value < 0 ||
        value > (percentFields.includes(field) ? 100 : 1440) ||
        (integerFields.includes(field) && !Number.isInteger(value)))
    ) return jsonWithRequest(request, { error: `invalid_${field}` }, 400);
    row[field] = value;
  }
  for (const field of timestampFields) {
    const value = input[field] ?? null;
    if (
      value !== null &&
      (typeof value !== "string" || !Number.isFinite(Date.parse(value)))
    ) return jsonWithRequest(request, { error: `invalid_${field}` }, 400);
    row[field] = value;
  }
  if (
    row.bed_time && row.wake_time &&
    Date.parse(String(row.wake_time)) <= Date.parse(String(row.bed_time))
  ) return jsonWithRequest(request, { error: "invalid_sleep_interval" }, 400);
  for (const field of ["notes", "device_name", "sleep_timezone"]) {
    if (
      input[field] != null &&
      (typeof input[field] !== "string" ||
        String(input[field]).length > (field === "notes" ? 10000 : 200))
    ) return jsonWithRequest(request, { error: `invalid_${field}` }, 400);
    if (input[field] !== undefined) row[field] = input[field];
  }
  if (
    input.sleep_utc_offset_minutes != null &&
    (typeof input.sleep_utc_offset_minutes !== "number" ||
      !Number.isInteger(input.sleep_utc_offset_minutes) ||
      Math.abs(input.sleep_utc_offset_minutes) > 840)
  ) {
    return jsonWithRequest(request, {
      error: "invalid_sleep_utc_offset_minutes",
    }, 400);
  }
  row.sleep_utc_offset_minutes = input.sleep_utc_offset_minutes ?? null;
  const { data, error } = await context.context.service.rpc(
    "upsert_canonical_sleep",
    { p_user_id: context.context.userId, p_payload: row },
  );
  if (error) {
    if (error.code === "42501") {
      return jsonWithRequest(request, { error: "forbidden_id_ownership" }, 403);
    }
    if (error.code === "22023") {
      return jsonWithRequest(request, { error: "invalid_sleep_identity" }, 400);
    }
    return jsonWithRequest(request, { error: "sleep_write_failed" }, 500);
  }
  return jsonWithRequest(request, { sleep_log: data });
});
