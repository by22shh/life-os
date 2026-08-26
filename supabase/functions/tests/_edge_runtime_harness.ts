// deno-coverage-ignore-file
type EdgeHandler = (request: Request) => Promise<Response> | Response;

const edgeHandlerCache = new Map<string, EdgeHandler>();

export interface EdgeFetchCall {
  request: Request;
  url: URL;
  bodyText: string;
}

export interface EdgeRuntimeCalls {
  authHeaders: string[];
  fetches: EdgeFetchCall[];
  rateLimitBodies: Array<Record<string, unknown>>;
  userLookupUrls: string[];
}

export type EdgeRuntimeResponder = (
  request: Request,
  context: {
    bodyText: string;
    calls: EdgeRuntimeCalls;
    url: URL;
  },
) => Promise<Response | undefined> | Response | undefined;

export interface EdgeRuntimeConfig {
  authResponse?: EdgeRuntimeResponder;
  authUser?: Record<string, unknown> | null;
  env?: Record<string, string | null>;
  publicUser?: Record<string, unknown> | null;
  rateLimitResponse?: EdgeRuntimeResponder;
  responders?: EdgeRuntimeResponder[];
  userLookupResponse?: EdgeRuntimeResponder;
}

export function jsonResponse(
  data: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...extraHeaders,
    },
  });
}

export function maybeSingleNotFoundResponse(): Response {
  return jsonResponse({
    code: "PGRST116",
    details: "0 rows",
    hint: null,
    message: "JSON object requested, multiple (or no) rows returned",
  }, 406);
}

export async function captureEdgeHandler(
  modulePath: string,
): Promise<EdgeHandler> {
  const cached = edgeHandlerCache.get(modulePath);
  if (cached) {
    return cached;
  }

  let handler: EdgeHandler | null = null;
  const previousServeDescriptor = Object.getOwnPropertyDescriptor(
    Deno,
    "serve",
  );

  const mockServe = ((...args: unknown[]) => {
    handler = typeof args[0] === "function"
      ? args[0] as EdgeHandler
      : args[1] as EdgeHandler;
    return { finished: Promise.resolve(), shutdown() {} } as never;
  }) as typeof Deno.serve;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    enumerable: previousServeDescriptor?.enumerable ?? true,
    value: mockServe,
    writable: true,
  });

  try {
    await import(new URL(modulePath, import.meta.url).href);
  } finally {
    if (previousServeDescriptor) {
      Object.defineProperty(Deno, "serve", previousServeDescriptor);
    } else {
      delete (Deno as { serve?: typeof Deno.serve }).serve;
    }
  }

  if (!handler) {
    throw new Error(`Failed to capture edge handler for ${modulePath}`);
  }

  edgeHandlerCache.set(modulePath, handler);
  return handler;
}

export async function withMockedEdgeRuntime<T>(
  config: EdgeRuntimeConfig,
  fn: (calls: EdgeRuntimeCalls) => Promise<T>,
): Promise<T> {
  const calls: EdgeRuntimeCalls = {
    authHeaders: [],
    fetches: [],
    rateLimitBodies: [],
    userLookupUrls: [],
  };

  const previousFetch = globalThis.fetch;
  const touchedEnv = new Map<string, string | undefined>();
  const envValues: Record<string, string | null> = {
    SUPABASE_URL: "http://localhost:54321",
    SUPABASE_ANON_KEY: "anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
    ...config.env,
  };

  for (const key of Object.keys(envValues)) {
    touchedEnv.set(key, Deno.env.get(key));
    const value = envValues[key];
    if (value === null) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, value);
    }
  }

  globalThis.fetch = (async (
    input: Request | URL | string,
    init?: RequestInit,
  ) => {
    const request = input instanceof Request
      ? input
      : new Request(String(input), init);
    const url = new URL(request.url);
    const bodyText = await request.clone().text();
    calls.fetches.push({ request, url, bodyText });

    if (url.pathname === "/auth/v1/user") {
      calls.authHeaders.push(request.headers.get("Authorization") ?? "");
      if (config.authResponse) {
        const response = await config.authResponse(
          request,
          { bodyText, calls, url },
        );
        if (response) return response;
      }
      if (config.authUser === null) {
        return jsonResponse({ message: "invalid token" }, 401);
      }
      return jsonResponse(config.authUser ?? { id: "auth-user-id" });
    }

    if (url.pathname === "/rest/v1/users") {
      calls.userLookupUrls.push(url.toString());
      if (config.userLookupResponse) {
        const response = await config.userLookupResponse(
          request,
          { bodyText, calls, url },
        );
        if (response) return response;
      }
      if (config.publicUser === null) {
        return maybeSingleNotFoundResponse();
      }
      return jsonResponse([config.publicUser ?? { id: "public-user-id" }]);
    }

    if (url.pathname === "/rest/v1/rpc/check_rate_limit_bucket") {
      calls.rateLimitBodies.push(
        bodyText ? JSON.parse(bodyText) as Record<string, unknown> : {},
      );
      if (config.rateLimitResponse) {
        const response = await config.rateLimitResponse(
          request,
          { bodyText, calls, url },
        );
        if (response) return response;
      }
      return jsonResponse([{
        ok: true,
        retry_after_seconds: 0,
        remaining: 999,
        reset_epoch_seconds: Math.floor(Date.now() / 1000) + 60,
      }]);
    }

    for (const responder of config.responders ?? []) {
      const response = await responder(request, { bodyText, calls, url });
      if (response) return response;
    }

    // Default to consent granted so AI success-path tests exercise their
    // real flows; the consent gate itself is covered by dedicated tests.
    // Checked after custom responders so privacy-settings tests can stub it.
    if (url.pathname === "/rest/v1/privacy_settings") {
      return jsonResponse([{ ai_processing_consent: true }]);
    }

    throw new Error(`Unexpected fetch URL in test harness: ${request.url}`);
  }) as typeof fetch;

  try {
    return await fn(calls);
  } finally {
    globalThis.fetch = previousFetch;
    for (const [key, value] of touchedEnv) {
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
  }
}
