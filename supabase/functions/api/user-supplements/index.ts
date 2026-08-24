import { localDateToday, pathnameTail } from "../../_shared/date_range.ts";
import { jsonWithRequest } from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

const VALID_FREQUENCIES = new Set([
  "daily",
  "twice_daily",
  "weekly",
  "as_needed",
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

  if (request.method === "GET" && route === "") {
    return await handleList(request, service, userId);
  }

  if (request.method === "POST" && route === "") {
    return await handleCreate(request, service, userId);
  }

  if (request.method === "PATCH" && isUUID(route)) {
    return await handlePatch(request, service, userId, route);
  }

  if (request.method === "DELETE" && isUUID(route)) {
    return await handleDelete(request, service, userId, route);
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

async function handleList(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
): Promise<Response> {
  const url = new URL(request.url);
  const activeOnly =
    (url.searchParams.get("active") ?? "true").toLowerCase() !==
      "false";

  const query = service
    .from("user_supplements")
    .select(
      "id,catalog_id,custom_name,dose_amount,dose_unit,frequency,scheduled_times,days_of_week,take_with_food,notes,active,started_at,ended_at",
    )
    .eq("user_id", userId)
    .order("created_at", { ascending: false });

  if (activeOnly) {
    query.eq("active", true);
  }

  const { data, error } = await query.returns<
    Array<{
      id: string;
      catalog_id: string | null;
      custom_name: string | null;
      dose_amount: number | null;
      dose_unit: string | null;
      frequency: string;
      scheduled_times: string[] | null;
      days_of_week: number[] | null;
      take_with_food: boolean | null;
      notes: string | null;
      active: boolean;
      started_at: string;
      ended_at: string | null;
    }>
  >();

  if (error) {
    return jsonWithRequest(request, {
      error: "user_supplements_fetch_failed",
      detail: error.message,
    }, 500);
  }

  const catalogIds = (data ?? [])
    .map((item) => item.catalog_id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);

  const nameById = new Map<string, string>();
  if (catalogIds.length > 0) {
    const { data: catalogRows, error: catalogError } = await service
      .from("supplement_catalog")
      .select("id,name")
      .in("id", catalogIds)
      .returns<Array<{ id: string; name: string }>>();

    if (catalogError) {
      return jsonWithRequest(request, {
        error: "supplement_catalog_fetch_failed",
        detail: catalogError.message,
      }, 500);
    }

    for (const row of catalogRows ?? []) {
      nameById.set(row.id, row.name);
    }
  }

  return jsonWithRequest(request, {
    items: (data ?? []).map((item) => ({
      ...item,
      name: item.catalog_id
        ? (nameById.get(item.catalog_id) ?? item.custom_name)
        : item.custom_name,
    })),
  });
}

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

  const parsed = parsePayload(payload, true);
  if (!parsed.ok) {
    return jsonWithRequest(request, { error: parsed.error }, 400);
  }

  const idempotencyKey = request.headers.get("Idempotency-Key")?.trim() ?? "";
  const rowId = isUUID(String(payload.id ?? ""))
    ? String(payload.id)
    : (isUUID(idempotencyKey) ? idempotencyKey : crypto.randomUUID());

  const { data, error } = await service
    .from("user_supplements")
    .upsert({
      id: rowId,
      user_id: userId,
      ...parsed.value,
    }, { onConflict: "id" })
    .select("*")
    .single<Record<string, unknown>>();

  if (error) {
    return jsonWithRequest(request, {
      error: "user_supplement_create_failed",
      detail: error.message,
    }, 500);
  }

  return jsonWithRequest(request, data);
}

async function handlePatch(
  request: Request,
  service: ReturnType<
    typeof import("../../_shared/supabase.ts").serviceRoleClient
  >,
  userId: string,
  supplementId: string,
): Promise<Response> {
  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const parsed = parsePayload(payload, false);
  if (!parsed.ok) {
    return jsonWithRequest(request, { error: parsed.error }, 400);
  }

  if (Object.keys(parsed.value).length === 0) {
    return jsonWithRequest(request, { error: "no_fields_to_update" }, 400);
  }

  const { data, error } = await service
    .from("user_supplements")
    .update(parsed.value)
    .eq("id", supplementId)
    .eq("user_id", userId)
    .select("*")
    .maybeSingle<Record<string, unknown>>();

  if (error) {
    return jsonWithRequest(request, {
      error: "user_supplement_update_failed",
      detail: error.message,
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(
      request,
      { error: "user_supplement_not_found" },
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
  supplementId: string,
): Promise<Response> {
  const { data, error } = await service
    .from("user_supplements")
    .update({
      active: false,
      ended_at: localDateToday("UTC"),
    })
    .eq("id", supplementId)
    .eq("user_id", userId)
    .select("id")
    .maybeSingle<{ id: string }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "user_supplement_delete_failed",
      detail: error.message,
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(
      request,
      { error: "user_supplement_not_found" },
      404,
    );
  }

  return jsonWithRequest(request, { ok: true });
}

function parsePayload(
  payload: Record<string, unknown>,
  requireBaseFields: boolean,
): { ok: true; value: Record<string, unknown> } | { ok: false; error: string } {
  const out: Record<string, unknown> = {};

  if (Object.prototype.hasOwnProperty.call(payload, "catalog_id")) {
    out.catalog_id = isUUID(String(payload.catalog_id ?? ""))
      ? String(payload.catalog_id)
      : null;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "custom_name")) {
    out.custom_name = optionalString(payload.custom_name);
  }

  if (requireBaseFields) {
    if (out.catalog_id == null && out.custom_name == null) {
      return { ok: false, error: "catalog_id_or_custom_name_required" };
    }
  }

  if (Object.prototype.hasOwnProperty.call(payload, "dose_amount")) {
    const dose = toNumberOrNull(payload.dose_amount);
    if (dose != null && dose <= 0) {
      return { ok: false, error: "invalid_dose_amount" };
    }
    out.dose_amount = dose;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "dose_unit")) {
    out.dose_unit = optionalString(payload.dose_unit);
  }

  if (Object.prototype.hasOwnProperty.call(payload, "frequency")) {
    const frequency = typeof payload.frequency === "string"
      ? payload.frequency.trim().toLowerCase()
      : "";
    if (!VALID_FREQUENCIES.has(frequency)) {
      return { ok: false, error: "invalid_frequency" };
    }
    out.frequency = frequency;
  } else if (requireBaseFields) {
    return { ok: false, error: "frequency_required" };
  }

  if (Object.prototype.hasOwnProperty.call(payload, "scheduled_times")) {
    const times = normalizeScheduledTimes(payload.scheduled_times);
    if (times == null) {
      return { ok: false, error: "invalid_scheduled_times" };
    }
    out.scheduled_times = times;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "days_of_week")) {
    const days = normalizeDaysOfWeek(payload.days_of_week);
    if (days == null) {
      return { ok: false, error: "invalid_days_of_week" };
    }
    out.days_of_week = days;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "take_with_food")) {
    if (typeof payload.take_with_food !== "boolean") {
      return { ok: false, error: "invalid_take_with_food" };
    }
    out.take_with_food = payload.take_with_food;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "notes")) {
    out.notes = optionalString(payload.notes);
  }

  if (Object.prototype.hasOwnProperty.call(payload, "active")) {
    if (typeof payload.active !== "boolean") {
      return { ok: false, error: "invalid_active" };
    }
    out.active = payload.active;
  } else if (requireBaseFields) {
    out.active = true;
  }

  if (Object.prototype.hasOwnProperty.call(payload, "started_at")) {
    out.started_at = normalizeDateOnly(payload.started_at);
  } else if (requireBaseFields) {
    out.started_at = localDateToday("UTC");
  }

  if (Object.prototype.hasOwnProperty.call(payload, "ended_at")) {
    out.ended_at = normalizeDateOnly(payload.ended_at);
  }

  return { ok: true, value: out };
}

function normalizeScheduledTimes(value: unknown): string[] | null {
  if (value == null) return null;
  if (!Array.isArray(value)) return null;
  const out = value
    .filter((item) => typeof item === "string")
    .map((item) => item.trim())
    .filter((item) => /^\d{2}:\d{2}$/.test(item));

  if (out.length !== value.length) return null;
  return out;
}

function normalizeDaysOfWeek(value: unknown): number[] | null {
  if (value == null) return null;
  if (!Array.isArray(value)) return null;

  const out = [
    ...new Set(
      value
        .filter((item) => typeof item === "number" && Number.isInteger(item))
        .map((item) => Number(item))
        .filter((item) => item >= 0 && item <= 6),
    ),
  ];

  if (out.length !== value.length) return null;
  return out;
}

function normalizeDateOnly(value: unknown): string | null {
  if (value == null) return null;
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return null;
  return trimmed;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function toNumberOrNull(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Number(value);
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
