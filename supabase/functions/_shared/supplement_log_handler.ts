import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  serviceRoleClient,
} from "./supabase.ts";
import { enforceRateLimit } from "./rate_limit.ts";
import { handleCors } from "./cors.ts";
import { parseWithSchema } from "./runtime_schema.ts";
import { SupplementLogPayloadSchema } from "./payload_schemas.ts";
import { sanitizedInternalDetail } from "../_shared/supabase.ts";

interface SupplementLogPayload {
  supplement_name?: string;
  scheduled_time?: string;
  taken_at?: string;
}

type UserRow = { id: string; timezone: string | null };

interface SupplementLogAuthClient {
  auth: {
    getUser(): Promise<{
      data: { user: { id: string } | null };
      error: { message: string } | null;
    }>;
  };
}

interface SupplementLogServiceClient {
  from(table: "users"): {
    select(columns: string): {
      eq(column: string, value: string): {
        maybeSingle<T>(): Promise<{
          data: T | null;
          error: { message: string } | null;
        }>;
      };
    };
  };
  from(table: "supplement_logs"): {
    insert(payload: Record<string, unknown>): Promise<{
      error: { message: string } | null;
    }>;
    select(columns: string): {
      eq(column: string, value: string): {
        eq(column: string, value: string): {
          maybeSingle<T>(): Promise<{
            data: T | null;
            error: { message: string } | null;
          }>;
        };
      };
    };
  };
}

interface SupplementLogDependencies {
  anonClient(authHeader: string): SupplementLogAuthClient;
  serviceRoleClient(): SupplementLogServiceClient;
  enforceRateLimit: typeof enforceRateLimit;
}

const MAX_SUPPLEMENT_NAME_LENGTH = 120;
const TIME_INPUT_PATTERN = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/;

const defaultSupplementLogDependencies: SupplementLogDependencies = {
  anonClient: (authHeader) => anonClient(authHeader) as SupplementLogAuthClient,
  // deno-coverage-ignore-start -- production service-role wiring is replaced by mocks in handler behavior tests.
  serviceRoleClient: () =>
    serviceRoleClient() as unknown as SupplementLogServiceClient,
  // deno-coverage-ignore-stop
  enforceRateLimit,
};

let supplementLogDependencies: SupplementLogDependencies = {
  ...defaultSupplementLogDependencies,
};

export const __supplementLogTestHooks = {
  install(overrides: Partial<SupplementLogDependencies>) {
    supplementLogDependencies = { ...supplementLogDependencies, ...overrides };
  },
  reset() {
    supplementLogDependencies = { ...defaultSupplementLogDependencies };
  },
};

export async function serveSupplementLog(request: Request): Promise<Response> {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const userClient = supplementLogDependencies.anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  let payloadRaw: unknown;
  try {
    payloadRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const payloadParse = parseWithSchema(SupplementLogPayloadSchema, payloadRaw);
  if (!payloadParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: payloadParse.issues,
    }, 400);
  }
  const payload: SupplementLogPayload = payloadParse.output;

  // deno-coverage-ignore-start -- schema validation guarantees string shape before this normalization.
  const supplementName = typeof payload.supplement_name === "string"
    ? payload.supplement_name.trim()
    : "";
  // deno-coverage-ignore-stop
  if (!supplementName) {
    return jsonWithRequest(request, { error: "supplement_name_required" }, 400);
  }
  if (supplementName.length > MAX_SUPPLEMENT_NAME_LENGTH) {
    return jsonWithRequest(request, { error: "supplement_name_too_long" }, 400);
  }

  // deno-coverage-ignore-start -- schema validation rejects non-string taken_at before this guard.
  if (payload.taken_at != null && typeof payload.taken_at !== "string") {
    return jsonWithRequest(request, { error: "invalid_taken_at" }, 400);
  }
  // deno-coverage-ignore-stop
  const takenAtDate = typeof payload.taken_at === "string"
    ? new Date(payload.taken_at)
    : new Date();
  if (Number.isNaN(takenAtDate.getTime())) {
    return jsonWithRequest(request, { error: "invalid_taken_at" }, 400);
  }

  const service = supplementLogDependencies.serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id,timezone")
    .eq("auth_id", authData.user.id)
    .maybeSingle<UserRow>();

  if (userLookupError) {
    return jsonWithRequest(
      request,
      {
        error: "user_lookup_failed",
        detail: sanitizedInternalDetail(
          request,
          "supplement_log_handler",
          userLookupError,
        ),
      },
      500,
    );
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await supplementLogDependencies.enforceRateLimit(
    request,
    userRow.id,
    "write_heavy",
    { allowOutboxReplayExemption: true },
  );
  if (rateLimited) return rateLimited;

  const takenAtIso = takenAtDate.toISOString();
  // deno-coverage-ignore -- null timezone fallback is covered by endpoint behavior tests.
  const timezone = safeTimeZone(userRow.timezone ?? "UTC");
  const takenDate = formatLocalDate(takenAtDate, timezone);
  const scheduledTimeRaw = typeof payload.scheduled_time === "string"
    ? payload.scheduled_time.trim()
    : "";
  const scheduledTime = scheduledTimeRaw.length > 0
    ? normalizeWallClockTime(scheduledTimeRaw)
    : null;
  if (scheduledTimeRaw.length > 0 && !scheduledTime) {
    return jsonWithRequest(request, { error: "invalid_scheduled_time" }, 400);
  }

  const idempotencyKey = request.headers.get("Idempotency-Key");
  const logId = idempotencyKey && isUUID(idempotencyKey)
    ? idempotencyKey
    : crypto.randomUUID();

  if (idempotencyKey && isUUID(idempotencyKey)) {
    const { data: existing } = await service
      .from("supplement_logs")
      .select("id")
      .eq("id", logId)
      .eq("user_id", userRow.id)
      .maybeSingle<{ id: string }>();

    if (existing) {
      return jsonWithRequest(
        request,
        { ok: true, idempotent_replay: true },
        202,
      );
    }
  }

  const { error: insertError } = await service
    .from("supplement_logs")
    .insert({
      id: logId,
      user_id: userRow.id,
      taken_at: takenAtIso,
      taken_date: takenDate,
      taken_timezone: timezone,
      supplement_name: supplementName,
      was_scheduled: scheduledTime != null,
      scheduled_time: scheduledTime,
    });

  if (insertError) {
    return jsonWithRequest(
      request,
      {
        error: "supplement_log_failed",
        detail: sanitizedInternalDetail(
          request,
          "supplement_log_handler",
          insertError,
        ),
      },
      500,
    );
  }

  return jsonWithRequest(request, { ok: true });
}

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function formatLocalDate(date: Date, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: timezone,
  }).formatToParts(date);
  const year = parts.find((part) => part.type === "year")?.value ?? "1970";
  const month = parts.find((part) => part.type === "month")?.value ?? "01";
  const day = parts.find((part) => part.type === "day")?.value ?? "01";
  return `${year}-${month}-${day}`;
}

function safeTimeZone(value: string): string {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format(new Date());
    return value;
  } catch {
    return "UTC";
  }
}

function normalizeWallClockTime(value: string): string | null {
  const match = TIME_INPUT_PATTERN.exec(value);
  if (!match) return null;

  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3] ?? "0");

  if (
    !Number.isInteger(hours) || !Number.isInteger(minutes) ||
    !Number.isInteger(seconds) ||
    hours < 0 || hours > 23 ||
    minutes < 0 || minutes > 59 ||
    seconds < 0 || seconds > 59
  ) {
    return null;
  }

  return `${String(hours).padStart(2, "0")}:${
    String(minutes).padStart(2, "0")
  }`;
}

export const __supplementLogHandlerTestHooks = {
  formatLocalDate,
  isUUID,
  normalizeWallClockTime,
  safeTimeZone,
};
