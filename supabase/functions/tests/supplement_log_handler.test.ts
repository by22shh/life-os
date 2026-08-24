import {
  assertEquals,
  assertMatch,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  __supplementLogTestHooks,
  serveSupplementLog,
} from "../_shared/supplement_log_handler.ts";

interface SupplementLogServiceConfig {
  authError?: { message: string } | null;
  authUserId?: string | null;
  existingLog?: { id: string } | null;
  insertError?: { message: string } | null;
  rateLimitResponse?: Response | null;
  userLookupError?: { message: string } | null;
  userRow?: { id: string; timezone: string | null } | null;
}

function createSupplementLogDependencies(
  config: SupplementLogServiceConfig = {},
) {
  const calls = {
    insertedRows: [] as Array<Record<string, unknown>>,
    rateLimitCalls: [] as Array<{
      options: { allowOutboxReplayExemption?: boolean } | undefined;
      tier: string;
      userId: string;
    }>,
  };

  const service = {
    from(table: string) {
      if (table === "users") {
        return {
          select: () => ({
            eq: () => ({
              maybeSingle: () =>
                Promise.resolve({
                  data: Object.prototype.hasOwnProperty.call(config, "userRow")
                    ? config.userRow ?? null
                    : {
                      id: "public-user-id",
                      timezone: "America/New_York",
                    },
                  error: config.userLookupError ?? null,
                }),
            }),
          }),
        };
      }

      if (table === "supplement_logs") {
        return {
          insert: (payload: Record<string, unknown>) => {
            calls.insertedRows.push(payload);
            return Promise.resolve({
              error: config.insertError ?? null,
            });
          },
          select: () => ({
            eq: () => ({
              eq: () => ({
                maybeSingle: () =>
                  Promise.resolve({
                    data: config.existingLog ?? null,
                    error: null,
                  }),
              }),
            }),
          }),
        };
      }

      throw new Error(`Unexpected table in supplement log test: ${table}`);
    },
  };

  return {
    calls,
    deps: {
      anonClient: (_authHeader: string) => ({
        auth: {
          getUser: () =>
            Promise.resolve({
              data: config.authUserId === null
                ? { user: null }
                : { user: { id: config.authUserId ?? "auth-user-id" } },
              error: config.authError ?? null,
            }),
        },
      }),
      enforceRateLimit: (
        _request: Request,
        userId: string,
        tier: string,
        options?: { allowOutboxReplayExemption?: boolean },
      ) => {
        calls.rateLimitCalls.push({ userId, tier, options });
        return Promise.resolve(config.rateLimitResponse ?? null);
      },
      serviceRoleClient: () => service,
    },
  };
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function withSupplementLogDependencies(
  config: SupplementLogServiceConfig,
  fn: (
    calls: {
      insertedRows: Array<Record<string, unknown>>;
      rateLimitCalls: Array<{
        options: { allowOutboxReplayExemption?: boolean } | undefined;
        tier: string;
        userId: string;
      }>;
    },
  ) => Promise<void>,
): Promise<void> {
  const { calls, deps } = createSupplementLogDependencies(config);
  __supplementLogTestHooks.install(deps as never);
  try {
    await fn(calls);
  } finally {
    __supplementLogTestHooks.reset();
  }
}

Deno.test("supplement log handler inserts normalized rows on success", async () => {
  await withSupplementLogDependencies({}, async (calls) => {
    const idempotencyKey = "550e8400-e29b-41d4-a716-446655440000";
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
          "Idempotency-Key": idempotencyKey,
        },
        body: JSON.stringify({
          supplement_name: "Vitamin D",
          scheduled_time: "8:30:00",
          taken_at: "2026-02-22T13:05:00.000Z",
        }),
      }),
    );

    assertEquals(response.status, 200);
    assertEquals(await response.json(), { ok: true });
    assertEquals(calls.insertedRows.length, 1);
    assertEquals(calls.insertedRows[0].id, idempotencyKey);
    assertEquals(calls.insertedRows[0].supplement_name, "Vitamin D");
    assertEquals(calls.insertedRows[0].scheduled_time, "08:30");
    assertEquals(calls.insertedRows[0].taken_timezone, "America/New_York");
    assertEquals(calls.insertedRows[0].taken_date, "2026-02-22");
    assertEquals(calls.insertedRows[0].was_scheduled, true);
    assertEquals(calls.rateLimitCalls, [{
      userId: "public-user-id",
      tier: "write_heavy",
      options: { allowOutboxReplayExemption: true },
    }]);
  });
});

Deno.test("supplement log handler returns idempotent replay without inserting duplicates", async () => {
  await withSupplementLogDependencies({
    existingLog: { id: "550e8400-e29b-41d4-a716-446655440000" },
  }, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
          "Idempotency-Key": "550e8400-e29b-41d4-a716-446655440000",
        },
        body: JSON.stringify({
          supplement_name: "Magnesium",
          scheduled_time: "21:15",
        }),
      }),
    );

    assertEquals(response.status, 202);
    assertEquals(await response.json(), {
      ok: true,
      idempotent_replay: true,
    });
    assertEquals(calls.insertedRows.length, 0);
  });
});

Deno.test("supplement log handler rejects malformed scheduled times", async () => {
  await withSupplementLogDependencies({}, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          supplement_name: "Omega 3",
          scheduled_time: "25:99",
        }),
      }),
    );

    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "invalid_scheduled_time" });
    assertEquals(calls.insertedRows.length, 0);
  });
});

Deno.test("supplement log handler rejects blank and oversized supplement names", async () => {
  await withSupplementLogDependencies({}, async (calls) => {
    let response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "   " }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "supplement_name_required" });

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "x".repeat(121) }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "supplement_name_too_long" });
    assertEquals(calls.insertedRows.length, 0);
  });
});

Deno.test("supplement log handler rejects request guardrails and malformed payloads", async () => {
  await withSupplementLogDependencies({}, async (calls) => {
    let response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "OPTIONS",
      }),
    );
    assertEquals(response.status, 204);
    assertEquals(
      response.headers.get("Access-Control-Allow-Methods"),
      "GET, POST, PATCH, PUT, DELETE, OPTIONS",
    );

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "GET",
      }),
    );
    assertEquals(response.status, 405);
    assertEquals(await response.json(), { error: "method_not_allowed" });

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );
    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: "{",
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "invalid_json" });

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: 42 }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals((await response.json()).error, "invalid_payload");

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "   " }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "supplement_name_required" });

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "a".repeat(121) }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "supplement_name_too_long" });

    response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          supplement_name: "Omega 3",
          taken_at: "not-a-date",
        }),
      }),
    );
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { error: "invalid_taken_at" });

    assertEquals(calls.insertedRows.length, 0);
    assertEquals(calls.rateLimitCalls.length, 0);
  });

  await withSupplementLogDependencies({
    authError: { message: "bad jwt" },
  }, async () => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );

    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });
  });

  await withSupplementLogDependencies({
    authUserId: null,
  }, async () => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );

    assertEquals(response.status, 401);
    assertEquals(await response.json(), { error: "unauthorized" });
  });
});

Deno.test("supplement log handler surfaces lookup rate-limit and insert failures", async () => {
  await withSupplementLogDependencies({
    userLookupError: { message: "lookup failed" },
  }, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );

    assertEquals(response.status, 500);
    assertEquals(await response.json(), {
      error: "user_lookup_failed",
      detail: "lookup failed",
    });
    assertEquals(calls.rateLimitCalls.length, 0);
  });

  await withSupplementLogDependencies({
    userRow: null,
  }, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );

    assertEquals(response.status, 404);
    assertEquals(await response.json(), { error: "user_not_found" });
    assertEquals(calls.rateLimitCalls.length, 0);
  });

  await withSupplementLogDependencies({
    rateLimitResponse: jsonResponse({ error: "rate_limited" }, 429),
  }, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );

    assertEquals(response.status, 429);
    assertEquals(await response.json(), { error: "rate_limited" });
    assertEquals(calls.insertedRows.length, 0);
    assertEquals(calls.rateLimitCalls, [{
      userId: "public-user-id",
      tier: "write_heavy",
      options: { allowOutboxReplayExemption: true },
    }]);
  });

  await withSupplementLogDependencies({
    insertError: { message: "insert failed" },
  }, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ supplement_name: "Magnesium" }),
      }),
    );

    assertEquals(response.status, 500);
    assertEquals(await response.json(), {
      error: "supplement_log_failed",
      detail: "insert failed",
    });
    assertEquals(calls.insertedRows.length, 1);
  });
});

Deno.test("supplement log handler falls back to UTC and generates ids for invalid idempotency keys", async () => {
  await withSupplementLogDependencies({
    userRow: {
      id: "public-user-id",
      timezone: "Mars/Olympus",
    },
  }, async (calls) => {
    const response = await serveSupplementLog(
      new Request("http://localhost/functions/v1/api-supplements-log", {
        method: "POST",
        headers: {
          Authorization: "Bearer test-access-token",
          "Content-Type": "application/json",
          "Idempotency-Key": "not-a-uuid",
        },
        body: JSON.stringify({
          supplement_name: "  Magnesium  ",
          scheduled_time: "   ",
          taken_at: "2026-02-22T23:05:00.000Z",
        }),
      }),
    );

    assertEquals(response.status, 200);
    assertEquals(await response.json(), { ok: true });
    assertEquals(calls.insertedRows.length, 1);
    assertEquals(calls.insertedRows[0].supplement_name, "Magnesium");
    assertEquals(calls.insertedRows[0].scheduled_time, null);
    assertEquals(calls.insertedRows[0].was_scheduled, false);
    assertEquals(calls.insertedRows[0].taken_timezone, "UTC");
    assertEquals(calls.insertedRows[0].taken_date, "2026-02-22");
    assertMatch(
      String(calls.insertedRows[0].id),
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  });
});
