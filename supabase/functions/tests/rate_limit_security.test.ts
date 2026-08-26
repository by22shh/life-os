import {
  assertEquals,
  assertMatch,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { assertNotEquals } from "https://deno.land/std@0.224.0/assert/assert_not_equals.ts";
import {
  __rateLimitTestHooks,
  enforceRateLimit,
} from "../_shared/rate_limit.ts";
import {
  parseBearer,
  validateInternalServiceRoleRequest,
} from "../_shared/supabase.ts";

function requestWithHeaders(headers: Record<string, string>): Request {
  return new Request("http://localhost/test", {
    method: "POST",
    headers,
  });
}

function withEnv(
  key: string,
  value: string | undefined,
  fn: () => void,
): void {
  const previousValue = Deno.env.get(key);
  if (value === undefined) {
    Deno.env.delete(key);
  } else {
    Deno.env.set(key, value);
  }

  try {
    fn();
  } finally {
    if (previousValue === undefined) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, previousValue);
    }
  }
}

function seededRandom(seed = 0xdecafbad): () => number {
  let state = seed >>> 0;
  return () => {
    state = (1664525 * state + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

function randomToken(random: () => number, length: number): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-._~";
  let out = "";
  for (let i = 0; i < length; i += 1) {
    const index = Math.floor(random() * alphabet.length);
    out += alphabet[index];
  }
  return out;
}

function randomCasing(input: string, random: () => number): string {
  let out = "";
  for (const ch of input) {
    out += random() >= 0.5 ? ch.toUpperCase() : ch.toLowerCase();
  }
  return out;
}

Deno.test("parseBearer handles missing and malformed authorization headers", () => {
  assertEquals(parseBearer(requestWithHeaders({})), "");
  assertEquals(
    parseBearer(requestWithHeaders({ Authorization: "Basic abc123" })),
    "",
  );
  assertEquals(
    parseBearer(requestWithHeaders({ Authorization: "Bearer invalid-token" })),
    "Bearer invalid-token",
  );
  assertEquals(
    parseBearer(
      requestWithHeaders({ Authorization: "bearer   another-token" }),
    ),
    "Bearer another-token",
  );
  assertEquals(
    parseBearer(requestWithHeaders({ Authorization: "Bearer   " })),
    "",
  );
  assertEquals(
    parseBearer(requestWithHeaders({ Authorization: "Bearer token one" })),
    "",
  );
  assertEquals(
    parseBearer(requestWithHeaders({ Authorization: "Bearer\tabc" })),
    "",
  );
});

Deno.test("parseBearer property test: normalizes valid bearer schemes and rejects malformed tokens", () => {
  const random = seededRandom(0x5eed1234);

  for (let i = 0; i < 1_000; i += 1) {
    const token = randomToken(random, 8 + Math.floor(random() * 16));
    const spacesBeforeToken = " ".repeat(1 + Math.floor(random() * 4));
    const spacesAfterToken = " ".repeat(Math.floor(random() * 3));
    const scheme = randomCasing("bearer", random);
    const header = `${scheme}${spacesBeforeToken}${token}${spacesAfterToken}`;
    assertEquals(
      parseBearer(requestWithHeaders({ Authorization: header })),
      `Bearer ${token}`,
    );
  }

  for (let i = 0; i < 200; i += 1) {
    const token = `${randomToken(random, 6)} ${randomToken(random, 6)}`;
    const scheme = randomCasing("bearer", random);
    const header = `${scheme} ${token}`;
    assertEquals(
      parseBearer(requestWithHeaders({ Authorization: header })),
      "",
    );
  }

  for (let i = 0; i < 200; i += 1) {
    const scheme = randomCasing("basic", random);
    const token = randomToken(random, 12);
    assertEquals(
      parseBearer(requestWithHeaders({ Authorization: `${scheme} ${token}` })),
      "",
    );
  }
});

Deno.test("validateInternalServiceRoleRequest requires service role auth, apikey, and worker header", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-secret", () => {
    const okRequest = requestWithHeaders({
      Authorization: "Bearer service-role-secret",
      apikey: "service-role-secret",
      "X-Account-Deletion-Worker": "scheduled",
    });
    assertEquals(
      validateInternalServiceRoleRequest(okRequest, {
        invocationHeaderName: "X-Account-Deletion-Worker",
        invocationHeaderValue: "scheduled",
      }),
      { ok: true },
    );
    assertEquals(
      validateInternalServiceRoleRequest(
        requestWithHeaders({
          Authorization: "Bearer service-role-secret",
          apikey: "service-role-secret",
        }),
      ),
      { ok: true },
    );

    assertEquals(
      validateInternalServiceRoleRequest(
        requestWithHeaders({
          Authorization: "Bearer user-access-token",
          apikey: "service-role-secret",
          "X-Account-Deletion-Worker": "scheduled",
        }),
        {
          invocationHeaderName: "X-Account-Deletion-Worker",
          invocationHeaderValue: "scheduled",
        },
      ),
      { ok: false, status: 401, error: "unauthorized" },
    );

    assertEquals(
      validateInternalServiceRoleRequest(
        requestWithHeaders({
          Authorization: "Bearer service-role-secret",
          apikey: "service-role-secret",
        }),
        {
          invocationHeaderName: "X-Account-Deletion-Worker",
          invocationHeaderValue: "scheduled",
        },
      ),
      { ok: false, status: 401, error: "unauthorized" },
    );

    assertEquals(
      validateInternalServiceRoleRequest(
        requestWithHeaders({
          Authorization: "Bearer service-role-secret",
          apikey: "wrong-key",
          "X-Account-Deletion-Worker": "scheduled",
        }),
        {
          invocationHeaderName: "X-Account-Deletion-Worker",
          invocationHeaderValue: "scheduled",
        },
      ),
      { ok: false, status: 401, error: "unauthorized" },
    );
  });
});

Deno.test("validateInternalServiceRoleRequest reports misconfigured auth when service role key is missing", () => {
  withEnv("SUPABASE_SERVICE_ROLE_KEY", undefined, () => {
    assertEquals(
      validateInternalServiceRoleRequest(
        requestWithHeaders({
          Authorization: "Bearer service-role-secret",
          apikey: "service-role-secret",
          "X-Account-Deletion-Worker": "scheduled",
        }),
        {
          invocationHeaderName: "X-Account-Deletion-Worker",
          invocationHeaderValue: "scheduled",
        },
      ),
      { ok: false, status: 500, error: "internal_auth_misconfigured" },
    );
  });
});

Deno.test("rate-limit ignores outbox replay bypass when exemption is disabled", async () => {
  const userKey = `delete-account-${crypto.randomUUID()}`;

  for (let i = 0; i < 3; i += 1) {
    const response = await enforceRateLimit(
      requestWithHeaders({ "X-Outbox-Replay": "true" }),
      userKey,
      "delete_account",
      { allowOutboxReplayExemption: false },
    );
    assertEquals(response, null);
  }

  const blocked = await enforceRateLimit(
    requestWithHeaders({ "X-Outbox-Replay": "true" }),
    userKey,
    "delete_account",
    { allowOutboxReplayExemption: false },
  );

  assertNotEquals(blocked, null);
  assertEquals(blocked?.status, 429);
});

Deno.test("malformed X-Outbox-Replay header does not grant write-heavy exemption", async () => {
  const userKey = `write-heavy-${crypto.randomUUID()}`;

  for (let i = 0; i < 30; i += 1) {
    const response = await enforceRateLimit(
      requestWithHeaders({ "X-Outbox-Replay": "true, true" }),
      userKey,
      "write_heavy",
      { allowOutboxReplayExemption: true },
    );
    assertEquals(response, null);
  }

  const blocked = await enforceRateLimit(
    requestWithHeaders({ "X-Outbox-Replay": "true, true" }),
    userKey,
    "write_heavy",
    { allowOutboxReplayExemption: true },
  );

  assertNotEquals(blocked, null);
  assertEquals(blocked?.status, 429);
});

Deno.test("X-Outbox-Replay exemption accepts trimmed case-insensitive true", async () => {
  const userKey = `write-heavy-trim-${crypto.randomUUID()}`;

  for (let i = 0; i < 40; i += 1) {
    const scheme = i % 2 === 0 ? " TRUE " : "TrUe";
    const response = await enforceRateLimit(
      requestWithHeaders({ "x-outbox-replay": scheme }),
      userKey,
      "write_heavy",
      { allowOutboxReplayExemption: true },
    );
    assertEquals(response, null);
  }
});

Deno.test("X-Outbox-Replay exemption is denied for cost-sensitive tiers even when endpoint opts in", async () => {
  __rateLimitTestHooks.resetBuckets();

  try {
    const userKey = `ai-vision-replay-${crypto.randomUUID()}`;

    for (let i = 0; i < 10; i += 1) {
      const response = await enforceRateLimit(
        requestWithHeaders({ "X-Outbox-Replay": "true" }),
        userKey,
        "ai_vision",
        { allowOutboxReplayExemption: true },
      );
      assertEquals(response, null);
    }

    const blocked = await enforceRateLimit(
      requestWithHeaders({ "X-Outbox-Replay": "true" }),
      userKey,
      "ai_vision",
      { allowOutboxReplayExemption: true },
    );

    assertNotEquals(blocked, null);
    assertEquals(blocked?.status, 429);
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("local fallback bucket map stays bounded under high-cardinality traffic", async () => {
  const previousUrl = Deno.env.get("SUPABASE_URL");
  const previousServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  Deno.env.delete("SUPABASE_URL");
  Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
  __rateLimitTestHooks.resetBuckets();

  try {
    const maxBuckets = __rateLimitTestHooks.maxLocalBuckets();
    const totalRequests = maxBuckets + 1_500;

    for (let i = 0; i < totalRequests; i += 1) {
      const response = await enforceRateLimit(
        requestWithHeaders({}),
        `high-cardinality-${i}`,
        "standard",
      );
      assertEquals(response, null);
    }

    assertEquals(__rateLimitTestHooks.bucketCount() <= maxBuckets, true);
  } finally {
    __rateLimitTestHooks.resetBuckets();

    if (previousUrl === undefined) {
      Deno.env.delete("SUPABASE_URL");
    } else {
      Deno.env.set("SUPABASE_URL", previousUrl);
    }

    if (previousServiceRoleKey === undefined) {
      Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
    } else {
      Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", previousServiceRoleKey);
    }
  }
});

Deno.test("enforceRateLimit returns null for blank user key", async () => {
  const response = await enforceRateLimit(
    requestWithHeaders({}),
    "   ",
    "standard",
  );
  assertEquals(response, null);
});

Deno.test("distributed limiter rpc error falls back to local limiter", async () => {
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () =>
      Promise.resolve({ data: null, error: { message: "forced-db-error" } }),
  }));

  try {
    const userKey = `dist-fallback-error-${crypto.randomUUID()}`;
    const allowed = await enforceRateLimit(
      requestWithHeaders({}),
      userKey,
      "export",
    );
    assertEquals(allowed, null);

    const blocked = await enforceRateLimit(
      requestWithHeaders({}),
      userKey,
      "export",
    );
    assertNotEquals(blocked, null);
    assertEquals(blocked?.status, 429);
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("distributed limiter malformed data falls back to local limiter", async () => {
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () => Promise.resolve({ data: { invalid: true }, error: null }),
  }));

  try {
    const userKey = `dist-fallback-malformed-${crypto.randomUUID()}`;
    const allowed = await enforceRateLimit(
      requestWithHeaders({}),
      userKey,
      "export",
    );
    assertEquals(allowed, null);

    const blocked = await enforceRateLimit(
      requestWithHeaders({}),
      userKey,
      "export",
    );
    assertNotEquals(blocked, null);
    assertEquals(blocked?.status, 429);
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("distributed limiter deny response maps retry headers", async () => {
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () =>
      Promise.resolve({
        data: [
          {
            ok: false,
            retry_after_seconds: 17,
            remaining: 0,
            reset_epoch_seconds: 999_999_999,
          },
        ],
        error: null,
      }),
  }));

  try {
    const response = await enforceRateLimit(
      requestWithHeaders({ "X-Correlation-Id": "dist-deny-correlation-001" }),
      `dist-deny-${crypto.randomUUID()}`,
      "auth",
    );
    assertNotEquals(response, null);
    assertEquals(response?.status, 429);
    assertEquals(response?.headers.get("Retry-After"), "17");
    assertEquals(response?.headers.get("X-RateLimit-Reset"), "999999999");
    assertEquals(
      response?.headers.get("X-Correlation-Id"),
      "dist-deny-correlation-001",
    );
    assertMatch(
      await response!.text(),
      /rate_limit_exceeded/,
    );
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("distributed limiter allows request when rpc reports ok", async () => {
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () =>
      Promise.resolve({
        data: [
          {
            ok: true,
            retry_after_seconds: 0,
            remaining: 9,
            reset_epoch_seconds: 123_456_789,
          },
        ],
        error: null,
      }),
  }));

  try {
    const response = await enforceRateLimit(
      requestWithHeaders({}),
      `dist-allow-${crypto.randomUUID()}`,
      "standard",
    );
    assertEquals(response, null);
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("distributed limiter defaults reset epoch when rpc omits it", async () => {
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () =>
      Promise.resolve({
        data: [
          {
            ok: false,
          },
        ],
        error: null,
      }),
  }));

  try {
    const response = await enforceRateLimit(
      requestWithHeaders({}),
      `dist-default-reset-${crypto.randomUUID()}`,
      "standard",
    );
    assertNotEquals(response, null);
    assertEquals(response?.status, 429);
    const reset = Number(response?.headers.get("X-RateLimit-Reset") ?? "0");
    assertEquals(Number.isFinite(reset), true);
    assertEquals(reset > 0, true);
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("rate-limit test hooks allow resetting custom service factory to default", async () => {
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () =>
      Promise.resolve({ data: null, error: { message: "forced-error" } }),
  }));
  __rateLimitTestHooks.setServiceRoleClientFactory(null);

  try {
    const previousUrl = Deno.env.get("SUPABASE_URL");
    const previousServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    Deno.env.delete("SUPABASE_URL");
    Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");

    try {
      const first = await enforceRateLimit(
        requestWithHeaders({}),
        `hook-reset-${crypto.randomUUID()}`,
        "export",
      );
      assertEquals(first, null);
    } finally {
      if (previousUrl === undefined) {
        Deno.env.delete("SUPABASE_URL");
      } else {
        Deno.env.set("SUPABASE_URL", previousUrl);
      }
      if (previousServiceRoleKey === undefined) {
        Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
      } else {
        Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", previousServiceRoleKey);
      }
    }
  } finally {
    __rateLimitTestHooks.resetBuckets();
  }
});

Deno.test("fallback limiter evicts stale buckets after interval", async () => {
  const mutableDate = Date as unknown as { now: () => number };
  const originalNow = Date.now;
  let simulatedNow = originalNow();

  mutableDate.now = () => simulatedNow;
  __rateLimitTestHooks.resetBuckets();
  __rateLimitTestHooks.setServiceRoleClientFactory(() => ({
    rpc: () => Promise.reject(new Error("force-fallback")),
  }));

  try {
    const initial = await enforceRateLimit(
      requestWithHeaders({}),
      `evict-a-${crypto.randomUUID()}`,
      "standard",
    );
    assertEquals(initial, null);
    assertEquals(__rateLimitTestHooks.bucketCount(), 1);

    __rateLimitTestHooks.setLastEvictionEpochMs(simulatedNow - 6 * 60 * 1000);
    simulatedNow += 61 * 1000;

    const second = await enforceRateLimit(
      requestWithHeaders({}),
      `evict-b-${crypto.randomUUID()}`,
      "standard",
    );
    assertEquals(second, null);
    // Stale first bucket should be evicted before second key gets added.
    assertEquals(__rateLimitTestHooks.bucketCount() <= 1, true);
  } finally {
    mutableDate.now = originalNow;
    __rateLimitTestHooks.resetBuckets();
  }
});
