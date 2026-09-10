import {
  assertEquals,
  assertMatch,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { resolveUserContext } from "../_shared/user_context.ts";

type RequestResponder = (request: Request) => Promise<Response> | Response;

interface RuntimeConfig {
  authResponse?: RequestResponder;
  env?: Record<string, string | null>;
  userLookupResponse?: RequestResponder;
  rateLimitResponse?: RequestResponder;
}

function jsonResponse(
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

async function withMockedRuntime<T>(
  config: RuntimeConfig,
  fn: () => Promise<T>,
): Promise<T> {
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

    if (url.pathname === "/auth/v1/user") {
      if (config.authResponse) {
        return await config.authResponse(request);
      }
      return jsonResponse({
        id: "auth-user-1",
        user_metadata: {},
        app_metadata: {},
        aud: "authenticated",
      });
    }

    if (url.pathname === "/rest/v1/users") {
      if (config.userLookupResponse) {
        return await config.userLookupResponse(request);
      }
      return jsonResponse({
        id: "public-user-1",
        timezone: "Asia/Tokyo",
      });
    }

    if (url.pathname === "/rest/v1/rpc/check_rate_limit_bucket") {
      if (config.rateLimitResponse) {
        return await config.rateLimitResponse(request);
      }
      return jsonResponse([{
        ok: true,
        retry_after_seconds: 0,
        remaining: 99,
        reset_epoch_seconds: Math.floor(Date.now() / 1000) + 60,
      }]);
    }

    throw new Error(
      `Unexpected fetch URL in user_context test: ${request.url}`,
    );
  }) as typeof fetch;

  try {
    return await fn();
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

Deno.test("resolveUserContext rejects missing or malformed bearer auth", async () => {
  const request = new Request("http://localhost/functions/v1/test", {
    headers: {
      Authorization: "Basic nope",
    },
  });

  const result = await resolveUserContext(request, "standard");
  assertEquals(result.ok, false);
  if (!result.ok) {
    assertEquals(result.response.status, 401);
    assertEquals(await result.response.json(), { error: "unauthorized" });
  }
});

Deno.test("resolveUserContext returns user context on successful auth lookup", async () => {
  await withMockedRuntime({}, async () => {
    const request = new Request("http://localhost/functions/v1/test", {
      headers: {
        Authorization: "Bearer access-token",
      },
    });

    const result = await resolveUserContext(request, "ai_parse");
    assertEquals(result.ok, true);
    if (result.ok) {
      assertEquals(result.context.authUserId, "auth-user-1");
      assertEquals(result.context.userId, "public-user-1");
      assertEquals(result.context.timezone, "Asia/Tokyo");
      assertEquals(typeof result.context.service.from, "function");
    }
  });
});

Deno.test("concurrent identical bearers share only the in-flight auth check and still consume each request budget", async () => {
  let checks = 0;
  let budgets = 0;
  let revoked = false;
  let release!: () => void;
  const barrier = new Promise<void>((resolve) => release = resolve);
  await withMockedRuntime({
    authResponse: async (request) => {
      checks += 1;
      assertEquals(request.headers.get("Authorization"), "Bearer same-token");
      await barrier;
      return revoked
        ? jsonResponse({ message: "session expired" }, 401)
        : jsonResponse({ id: "auth-user-1" });
    },
    rateLimitResponse: () => {
      budgets += 1;
      return jsonResponse([{ ok: true }]);
    },
  }, async () => {
    const request = () =>
      new Request("http://localhost/test", {
        headers: { Authorization: "Bearer same-token" },
      });
    const requests = Array.from(
      { length: 16 },
      () => resolveUserContext(request(), "standard"),
    );
    release();
    const results = await Promise.all(requests);
    assertEquals(results.every((result) => result.ok), true);
    assertEquals(checks, 1);
    assertEquals(budgets, 16);
    revoked = true;
    const next = await resolveUserContext(request(), "standard");
    assertEquals(next.ok, false);
    if (!next.ok) assertEquals(next.response.status, 401);
    assertEquals(checks, 2);
    assertEquals(budgets, 16);
  });
});

Deno.test("different bearers never share an auth result", async () => {
  const tokens: string[] = [];
  await withMockedRuntime({
    authResponse: (request) => {
      const token = request.headers.get("Authorization") ?? "";
      tokens.push(token);
      return token === "Bearer valid"
        ? jsonResponse({ id: "auth-user-1" })
        : jsonResponse({ message: "invalid token" }, 401);
    },
  }, async () => {
    const results = await Promise.all(
      ["valid", "forged"].map((token) =>
        resolveUserContext(
          new Request("http://localhost/test", {
            headers: { Authorization: `Bearer ${token}` },
          }),
          "standard",
        )
      ),
    );
    assertEquals(results.map((result) => result.ok), [true, false]);
    assertEquals(tokens.sort(), ["Bearer forged", "Bearer valid"]);
  });
});

Deno.test("Auth overload and server failures are retryable 503 and never proceed to profile or budget", async () => {
  for (const status of [429, 500, 502, 503]) {
    await withMockedRuntime({
      authResponse: () =>
        jsonResponse({ message: "upstream overloaded" }, status),
      userLookupResponse: () => {
        throw new Error("must not access profile");
      },
      rateLimitResponse: () => {
        throw new Error("must not consume budget");
      },
    }, async () => {
      const result = await resolveUserContext(
        new Request("http://localhost/test", {
          headers: { Authorization: "Bearer valid" },
        }),
        "standard",
      );
      assertEquals(result.ok, false);
      if (!result.ok) {
        assertEquals(result.response.status, 503);
        assertEquals(result.response.headers.get("Retry-After"), "1");
        assertEquals(await result.response.json(), {
          error: "auth_unavailable",
        });
      }
    });
  }
});

Deno.test("resolveUserContext maps auth, lookup, not-found, and rate-limit failures", async (t) => {
  await t.step("auth fetch failure returns unauthorized", async () => {
    await withMockedRuntime({
      authResponse: () =>
        jsonResponse(
          {
            error: "invalid_token",
            error_description: "token expired",
          },
          401,
        ),
    }, async () => {
      const request = new Request("http://localhost/functions/v1/test", {
        headers: {
          Authorization: "Bearer expired-token",
        },
      });

      const result = await resolveUserContext(request, "standard");
      assertEquals(result.ok, false);
      if (!result.ok) {
        assertEquals(result.response.status, 401);
        assertEquals(await result.response.json(), { error: "unauthorized" });
      }
    });
  });

  await t.step("user lookup failure returns 500", async () => {
    await withMockedRuntime({
      userLookupResponse: () =>
        jsonResponse(
          {
            code: "57014",
            details: null,
            hint: null,
            message: "query cancelled",
          },
          500,
        ),
    }, async () => {
      const request = new Request("http://localhost/functions/v1/test", {
        headers: {
          Authorization: "Bearer access-token",
        },
      });

      const result = await resolveUserContext(request, "standard");
      assertEquals(result.ok, false);
      if (!result.ok) {
        assertEquals(result.response.status, 500);
        assertEquals(await result.response.json(), {
          error: "user_lookup_failed",
          detail: "internal_error",
        });
      }
    });
  });

  await t.step("missing user row returns 404", async () => {
    await withMockedRuntime({
      userLookupResponse: () =>
        jsonResponse(
          {
            code: "PGRST116",
            details: "The result contains 0 rows",
            hint: null,
            message: "JSON object requested, multiple (or no) rows returned",
          },
          406,
        ),
    }, async () => {
      const request = new Request("http://localhost/functions/v1/test", {
        headers: {
          Authorization: "Bearer access-token",
        },
      });

      const result = await resolveUserContext(request, "standard");
      assertEquals(result.ok, false);
      if (!result.ok) {
        assertEquals(result.response.status, 404);
        assertEquals(await result.response.json(), { error: "user_not_found" });
      }
    });
  });

  await t.step(
    "rate-limited user returns 429 with request correlation id",
    async () => {
      await withMockedRuntime({
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 17,
            remaining: 0,
            reset_epoch_seconds: 999999999,
          }]),
      }, async () => {
        const request = new Request("http://localhost/functions/v1/test", {
          headers: {
            Authorization: "Bearer access-token",
            "X-Correlation-Id": "user-context-rate-limit",
          },
        });

        const result = await resolveUserContext(request, "standard");
        assertEquals(result.ok, false);
        if (!result.ok) {
          assertEquals(result.response.status, 429);
          assertEquals(result.response.headers.get("Retry-After"), "17");
          assertEquals(
            result.response.headers.get("X-Correlation-Id"),
            "user-context-rate-limit",
          );
          const body = await result.response.json();
          assertEquals(body.error, "rate_limit_exceeded");
          assertMatch(body.message, /17 seconds/);
        }
      });
    },
  );
});
