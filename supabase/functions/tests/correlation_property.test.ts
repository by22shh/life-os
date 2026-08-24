import {
  assertEquals,
  assertMatch,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { enforceRateLimit } from "../_shared/rate_limit.ts";
import {
  correlationIdFromRequest,
  jsonWithRequest,
} from "../_shared/supabase.ts";

function seededRandom(seed = 0x1234abce): () => number {
  let state = seed >>> 0;
  return () => {
    state = (1664525 * state + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

function randomToken(random: () => number, length: number): string {
  const alphabet =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-";
  let out = "";
  for (let i = 0; i < length; i += 1) {
    out += alphabet[Math.floor(random() * alphabet.length)];
  }
  return out;
}

function requestWithHeaders(headers: Record<string, string>): Request {
  return new Request("http://localhost/test", { headers });
}

Deno.test("correlationIdFromRequest keeps valid IDs and regenerates malformed values", () => {
  const valid = "sync-queue:abc12345";
  assertEquals(
    correlationIdFromRequest(requestWithHeaders({ "X-Correlation-Id": valid })),
    valid,
  );

  const malformed = [
    "",
    "a",
    "contains spaces",
    "too-long-" + "a".repeat(200),
  ];

  for (const value of malformed) {
    const resolved = correlationIdFromRequest(
      requestWithHeaders({ "X-Correlation-Id": value }),
    );
    assertNotEquals(resolved, value);
    assertMatch(
      resolved,
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  }
});

Deno.test("jsonWithRequest always includes X-Correlation-Id", () => {
  const random = seededRandom(0x5eed4321);

  for (let i = 0; i < 1_000; i += 1) {
    const correlationId = randomToken(random, 12 + Math.floor(random() * 32));
    const response = jsonWithRequest(
      requestWithHeaders({ "X-Correlation-Id": correlationId }),
      { ok: true },
      200,
    );
    assertEquals(response.headers.get("X-Correlation-Id"), correlationId);
  }

  const generated = jsonWithRequest(requestWithHeaders({}), { ok: true }, 200);
  const generatedId = generated.headers.get("X-Correlation-Id") ?? "";
  assertMatch(
    generatedId,
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
  );
});

Deno.test("rate-limit 429 responses preserve request correlation id", async () => {
  const userKey = `corr-${crypto.randomUUID()}`;
  const correlationId = "rate-limit-test-correlation-01";

  for (let i = 0; i < 3; i += 1) {
    const response = await enforceRateLimit(
      requestWithHeaders({
        "X-Outbox-Replay": "true",
        "X-Correlation-Id": correlationId,
      }),
      userKey,
      "delete_account",
      { allowOutboxReplayExemption: false },
    );
    assertEquals(response, null);
  }

  const blocked = await enforceRateLimit(
    requestWithHeaders({
      "X-Outbox-Replay": "true",
      "X-Correlation-Id": correlationId,
    }),
    userKey,
    "delete_account",
    { allowOutboxReplayExemption: false },
  );

  assertNotEquals(blocked, null);
  assertEquals(blocked?.status, 429);
  assertEquals(blocked?.headers.get("X-Correlation-Id"), correlationId);
});
