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
  if (authHeader !== expectedAuthorization) {
    return {
      ok: false,
      status: 401,
      error: "unauthorized",
    };
  }

  const apiKey = request.headers.get("apikey")?.trim() ?? "";
  if (apiKey !== serviceRoleKey) {
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
