// P1 #7: Shared CORS handler for all Edge Functions.
// Prevents CORS errors for web-based clients and WebView integrations.

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PATCH, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Authorization, Content-Type, X-Device-Id, Idempotency-Key, X-Outbox-Replay, X-Correlation-Id, X-Client-Info, X-Deletion-Receipt, apikey",
  "Access-Control-Expose-Headers":
    "X-Correlation-Id, Retry-After, X-Idempotent-Replay, X-Min-App-Version, X-Soft-Update-Version, X-App-Store-URL",
  "Access-Control-Max-Age": "86400",
};

const MIN_APP_VERSION_HEADER = "X-Min-App-Version";
const SOFT_UPDATE_VERSION_HEADER = "X-Soft-Update-Version";
const APP_STORE_URL_HEADER = "X-App-Store-URL";

function readConfiguredValue(envKeys: readonly string[]): string | null {
  for (const key of envKeys) {
    const raw = Deno.env.get(key)?.trim();
    if (raw) {
      return raw;
    }
  }
  return null;
}

function isValidAbsoluteUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" || parsed.protocol === "https:";
  } catch {
    return false;
  }
}

function isAppleAppStoreHost(hostname: string): boolean {
  return hostname === "itunes.apple.com" || hostname.endsWith("apps.apple.com");
}

function isAppStoreSearchUrl(value: string): boolean {
  try {
    const parsed = new URL(value);
    if (!isAppleAppStoreHost(parsed.hostname)) {
      return false;
    }
    if (parsed.pathname.toLowerCase().includes("/search")) {
      return true;
    }
    return parsed.searchParams.has("term");
  } catch {
    return false;
  }
}

function normalizeAppStoreId(value: string | null): string | null {
  if (!value) {
    return null;
  }

  const trimmed = value.trim();
  const match = trimmed.match(/\d{5,}/);
  return match?.[0] ?? null;
}

function directAppStoreUrl(appStoreId: string): string {
  return `https://apps.apple.com/app/id${appStoreId}`;
}

function resolveConfiguredAppStoreUrl(): string | null {
  const configuredUrl = readConfiguredValue([
    "APP_STORE_URL",
    "FORCE_UPDATE_APP_STORE_URL",
  ]);
  const configuredId = normalizeAppStoreId(readConfiguredValue([
    "APP_STORE_ID",
    "FORCE_UPDATE_APP_STORE_ID",
  ]));

  if (
    configuredUrl &&
    isValidAbsoluteUrl(configuredUrl) &&
    !isAppStoreSearchUrl(configuredUrl)
  ) {
    return configuredUrl;
  }

  if (configuredId) {
    return directAppStoreUrl(configuredId);
  }

  return null;
}

function resolveServerManagedHeaders(): Record<string, string> {
  const headers: Record<string, string> = {};

  const minAppVersion = readConfiguredValue([
    "MIN_SUPPORTED_APP_VERSION",
    "X_MIN_APP_VERSION",
  ]);
  if (minAppVersion) {
    headers[MIN_APP_VERSION_HEADER] = minAppVersion;
  }

  const softUpdateVersion = readConfiguredValue([
    "SOFT_UPDATE_VERSION",
    "X_SOFT_UPDATE_VERSION",
  ]);
  if (softUpdateVersion) {
    headers[SOFT_UPDATE_VERSION_HEADER] = softUpdateVersion;
  }

  const appStoreUrl = resolveConfiguredAppStoreUrl();
  if (appStoreUrl) {
    headers[APP_STORE_URL_HEADER] = appStoreUrl;
  }

  return headers;
}

/**
 * Returns a preflight response for OPTIONS requests.
 * Returns `null` if the request is not an OPTIONS preflight.
 *
 * Usage:
 *   const preflight = handleCors(request);
 *   if (preflight) return preflight;
 */
/**
 * Optional browser-origin allowlist.
 *
 * Native iOS/watchOS clients do not implement CORS and are unaffected either
 * way. When CORS_ALLOWED_ORIGINS is configured (comma-separated list of exact
 * origins), preflight responses only succeed for origins on the list, which
 * stops arbitrary web origins from scripting authenticated calls from a user's
 * browser. When unset the historical wildcard behavior is preserved.
 */
function resolveCorsAllowedOrigins(): string[] | null {
  const raw = readConfiguredValue(["CORS_ALLOWED_ORIGINS"]);
  if (!raw) return null;
  const origins = raw
    .split(",")
    .map((origin) => origin.trim().toLowerCase())
    .filter((origin) => origin.length > 0);
  return origins.length > 0 ? origins : null;
}

export function handleCors(request: Request): Response | null {
  if (request.method !== "OPTIONS") return null;

  const allowlist = resolveCorsAllowedOrigins();
  if (!allowlist) {
    return new Response(null, {
      status: 204,
      headers: CORS_HEADERS,
    });
  }

  const requestOrigin = request.headers.get("Origin")?.trim().toLowerCase() ??
    "";
  if (requestOrigin && allowlist.includes(requestOrigin)) {
    return new Response(null, {
      status: 204,
      headers: {
        ...CORS_HEADERS,
        "Access-Control-Allow-Origin": requestOrigin,
        Vary: "Origin",
      },
    });
  }

  // No Access-Control-Allow-Origin: standards-compliant browsers reject the
  // cross-origin call even though the preflight itself returns 204/403.
  const headers = { ...CORS_HEADERS };
  delete headers["Access-Control-Allow-Origin"];
  return new Response(null, {
    status: requestOrigin ? 403 : 204,
    headers,
  });
}

/**
 * Merge CORS headers into an existing headers object.
 * Use this to attach CORS headers to non-preflight responses.
 */
export function withCorsHeaders(
  headers: Record<string, string> = {},
): Record<string, string> {
  return {
    ...CORS_HEADERS,
    ...resolveServerManagedHeaders(),
    ...headers,
  };
}

export const __corsTestHooks = {
  directAppStoreUrl,
  isAppleAppStoreHost,
  isAppStoreSearchUrl,
  isValidAbsoluteUrl,
  normalizeAppStoreId,
  readConfiguredValue,
  resolveConfiguredAppStoreUrl,
  resolveCorsAllowedOrigins,
  resolveServerManagedHeaders,
};
