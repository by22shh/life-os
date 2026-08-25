import { createClient } from "jsr:@supabase/supabase-js@2.50.0";
import { withCorsHeaders } from "./cors.ts";

const CORRELATION_ID_HEADER = "X-Correlation-Id";
const CORRELATION_ID_PATTERN = /^[A-Za-z0-9._:-]{8,128}$/;

export interface InternalServiceRoleAuthOptions {
  invocationHeaderName?: string;
  invocationHeaderValue?: string;
}

export type InternalServiceRoleAuthResult =
  | { ok: true }
  | {
    ok: false;
    status: 401 | 500;
    error: "unauthorized" | "internal_auth_misconfigured";
  };

export function serviceRoleClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function anonClient(authHeader: string) {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !key) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_ANON_KEY");
  }
  return createClient(url, key, {
    global: {
      headers: {
        Authorization: authHeader,
      },
    },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function json(
  data: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: withCorsHeaders({
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...extraHeaders,
    }),
  });
}

function normalizeCorrelationId(raw: string | null): string {
  const candidate = raw?.trim() ?? "";
  if (CORRELATION_ID_PATTERN.test(candidate)) {
    return candidate;
  }
  return crypto.randomUUID();
}

export function correlationIdFromRequest(request: Request): string {
  return normalizeCorrelationId(request.headers.get(CORRELATION_ID_HEADER));
}

/**
 * Logs the full internal error server-side (with correlation id) and returns
 * an opaque detail string safe to expose to clients. PostgREST, storage and
 * upstream provider messages can reveal table/column names and infrastructure
 * topology, so they must never flow into API responses verbatim.
 */
export function sanitizedInternalDetail(
  request: Request,
  scope: string,
  error: unknown,
): string {
  const message = error instanceof Error ? error.message : String(error);
  console.error(
    JSON.stringify({
      event: "internal_error",
      scope,
      correlation_id: correlationIdFromRequest(request),
      detail: message.slice(0, 500),
    }),
  );
  return "internal_error";
}

export function jsonWithRequest(
  request: Request,
  data: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  const correlationId = normalizeCorrelationId(
    extraHeaders[CORRELATION_ID_HEADER] ??
      request.headers.get(CORRELATION_ID_HEADER),
  );
  return json(data, status, {
    [CORRELATION_ID_HEADER]: correlationId,
    ...extraHeaders,
  });
}

export function parseBearer(request: Request): string {
  const authorization = request.headers.get("Authorization");
  if (!authorization) return "";

  const trimmed = authorization.trim();
  const separatorIndex = trimmed.indexOf(" ");
  if (separatorIndex <= 0) return "";

  const scheme = trimmed.slice(0, separatorIndex);
  if (scheme.toLowerCase() !== "bearer") return "";

  const token = trimmed.slice(separatorIndex + 1).trim();
  if (!token || /\s/.test(token)) return "";

  return `Bearer ${token}`;
}

/**
 * Constant-time string equality so secret comparisons do not leak
 * prefix-match timing information.
 */
function timingSafeEqualStrings(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const aBytes = encoder.encode(a);
  const bBytes = encoder.encode(b);
  const mismatch = aBytes.byteLength ^ bBytes.byteLength;
  const longest = Math.max(aBytes.byteLength, bBytes.byteLength);
  let result = mismatch;
  for (let i = 0; i < longest; i += 1) {
    result |= (aBytes[i] ?? 0) ^ (bBytes[i] ?? 0);
  }
  return result === 0;
}

export function validateInternalServiceRoleRequest(
  request: Request,
  options: InternalServiceRoleAuthOptions = {},
): InternalServiceRoleAuthResult {
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ??
    "";
  if (!serviceRoleKey) {
    return {
      ok: false,
      status: 500,
      error: "internal_auth_misconfigured",
    };
  }

  const authHeader = parseBearer(request);
  const expectedAuthorization = `Bearer ${serviceRoleKey}`;
  if (
    authHeader.slice(0, 7).toLowerCase() !== "bearer " ||
    !timingSafeEqualStrings(authHeader, expectedAuthorization)
  ) {
    return {
      ok: false,
      status: 401,
      error: "unauthorized",
    };
  }

  const apiKey = request.headers.get("apikey")?.trim() ?? "";
  if (!timingSafeEqualStrings(apiKey, serviceRoleKey)) {
    return {
      ok: false,
      status: 401,
      error: "unauthorized",
    };
  }

  const invocationHeaderName = options.invocationHeaderName?.trim() ?? "";
  const invocationHeaderValue = options.invocationHeaderValue?.trim() ?? "";
  if (invocationHeaderName && invocationHeaderValue) {
    const actualInvocationValue =
      request.headers.get(invocationHeaderName)?.trim() ?? "";
    if (actualInvocationValue !== invocationHeaderValue) {
      return {
        ok: false,
        status: 401,
        error: "unauthorized",
      };
    }
  }

  return { ok: true };
}
