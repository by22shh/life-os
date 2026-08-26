import {
  assert,
  assertEquals,
  assertMatch,
  assertNotEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertDeletionStateTransition,
  canTransitionDeletionState,
} from "../_shared/account_deletion_state_machine.ts";
import { handleCors, withCorsHeaders } from "../_shared/cors.ts";
import { parseWithSchema, v } from "../_shared/runtime_schema.ts";
import {
  anonClient,
  json,
  jsonWithRequest,
  serviceRoleClient,
} from "../_shared/supabase.ts";

function withEnv(
  key: string,
  value: string | undefined,
  fn: () => void,
): void {
  const prev = Deno.env.get(key);
  if (value === undefined) {
    Deno.env.delete(key);
  } else {
    Deno.env.set(key, value);
  }

  try {
    fn();
  } finally {
    if (prev === undefined) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, prev);
    }
  }
}

Deno.test("cors helper returns preflight response and merges headers", () => {
  const preflight = handleCors(
    new Request("http://localhost", { method: "OPTIONS" }),
  );
  assert(preflight instanceof Response);
  assertEquals(preflight.status, 204);
  assertEquals(preflight.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(
    preflight.headers.get("Access-Control-Expose-Headers")?.includes(
      "X-Min-App-Version",
    ),
    true,
  );
  assertEquals(
    preflight.headers.get("Access-Control-Expose-Headers")?.includes(
      "X-Soft-Update-Version",
    ),
    true,
  );
  assertEquals(
    preflight.headers.get("Access-Control-Expose-Headers")?.includes(
      "X-App-Store-URL",
    ),
    true,
  );

  const nonPreflight = handleCors(
    new Request("http://localhost", { method: "POST" }),
  );
  assertEquals(nonPreflight, null);

  const merged = withCorsHeaders({
    "X-Test": "ok",
    "Access-Control-Max-Age": "1",
  });
  assertEquals(merged["X-Test"], "ok");
  assertEquals(merged["Access-Control-Max-Age"], "1");
  assertEquals(
    merged["Access-Control-Allow-Headers"].includes("Authorization"),
    true,
  );
});

Deno.test("cors allowlist reflects configured origins and rejects others", () => {
  withEnv(
    "CORS_ALLOWED_ORIGINS",
    "https://app.lifeos.example, https://admin.lifeos.example",
    () => {
      const allowed = handleCors(
        new Request("http://localhost", {
          method: "OPTIONS",
          headers: { Origin: "https://app.lifeos.example" },
        }),
      );
      assertEquals(allowed?.status, 204);
      assertEquals(
        allowed?.headers.get("Access-Control-Allow-Origin"),
        "https://app.lifeos.example",
      );
      assertEquals(allowed?.headers.get("Vary"), "Origin");

      const denied = handleCors(
        new Request("http://localhost", {
          method: "OPTIONS",
          headers: { Origin: "https://evil.example" },
        }),
      );
      assertEquals(denied?.status, 403);
      assertEquals(denied?.headers.get("Access-Control-Allow-Origin"), null);
    },
  );
});

Deno.test("cors wildcard behavior is preserved when no allowlist is configured", () => {
  withEnv("CORS_ALLOWED_ORIGINS", undefined, () => {
    const preflight = handleCors(
      new Request("http://localhost", { method: "OPTIONS" }),
    );
    assertEquals(preflight?.status, 204);
    assertEquals(
      preflight?.headers.get("Access-Control-Allow-Origin"),
      "*",
    );
  });
});

Deno.test("json helpers include no-store and correlation id semantics", async () => {
  const response = json({ ok: true }, 201, { "X-Test": "value" });
  assertEquals(response.status, 201);
  assertEquals(response.headers.get("Content-Type"), "application/json");
  assertEquals(response.headers.get("Cache-Control"), "no-store");
  assertEquals(response.headers.get("X-Test"), "value");
  assertEquals(await response.json(), { ok: true });

  const explicitCorrelationId = "explicit-correlation-id-1234";
  const request = new Request("http://localhost", {
    headers: { "X-Correlation-Id": "request-correlation-id-1234" },
  });
  const responseWithRequest = jsonWithRequest(
    request,
    { ok: true },
    200,
    { "X-Correlation-Id": explicitCorrelationId },
  );
  assertEquals(
    responseWithRequest.headers.get("X-Correlation-Id"),
    explicitCorrelationId,
  );

  const generated = jsonWithRequest(new Request("http://localhost"), {
    ok: true,
  });
  const generatedId = generated.headers.get("X-Correlation-Id") ?? "";
  assertMatch(
    generatedId,
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
  );
  assertNotEquals(generatedId, "");
});

Deno.test("response helpers include configured force-update headers", () => {
  withEnv("MIN_SUPPORTED_APP_VERSION", " 2.4.0 ", () => {
    withEnv("SOFT_UPDATE_VERSION", " 2.6.0 ", () => {
      withEnv("APP_STORE_URL", " https://example.com/app ", () => {
        const response = jsonWithRequest(
          new Request("http://localhost"),
          { ok: true },
          200,
        );
        assertEquals(response.headers.get("X-Min-App-Version"), "2.4.0");
        assertEquals(response.headers.get("X-Soft-Update-Version"), "2.6.0");
        assertEquals(
          response.headers.get("X-App-Store-URL"),
          "https://example.com/app",
        );
      });
    });
  });
});

Deno.test("response helpers build a direct app store header from APP_STORE_ID", () => {
  withEnv("APP_STORE_URL", undefined, () => {
    withEnv("APP_STORE_ID", " 1234567890 ", () => {
      const response = json({ ok: true });
      assertEquals(
        response.headers.get("X-App-Store-URL"),
        "https://apps.apple.com/app/id1234567890",
      );
    });
  });
});

Deno.test("response helpers omit blank or invalid force-update config", () => {
  withEnv("MIN_SUPPORTED_APP_VERSION", "   ", () => {
    withEnv("SOFT_UPDATE_VERSION", "", () => {
      withEnv(
        "APP_STORE_URL",
        "https://apps.apple.com/us/search?term=Life%20OS",
        () => {
          const response = json({ ok: true });
          assertEquals(response.headers.get("X-Min-App-Version"), null);
          assertEquals(response.headers.get("X-Soft-Update-Version"), null);
          assertEquals(response.headers.get("X-App-Store-URL"), null);
        },
      );
    });
  });

  withEnv("APP_STORE_URL", "not a url", () => {
    withEnv("APP_STORE_ID", "not-an-id", () => {
      const response = json({ ok: true });
      assertEquals(response.headers.get("X-App-Store-URL"), null);
    });
  });

  withEnv("APP_STORE_URL", "https://apps.apple.com/app/id1234567890", () => {
    withEnv("APP_STORE_ID", "not-an-id", () => {
      const response = json({ ok: true });
      assertEquals(
        response.headers.get("X-App-Store-URL"),
        "https://apps.apple.com/app/id1234567890",
      );
    });
  });
});

Deno.test("response helpers support legacy force-update env aliases", () => {
  withEnv("X_MIN_APP_VERSION", "3.1.0", () => {
    withEnv("X_SOFT_UPDATE_VERSION", "3.2.0", () => {
      withEnv(
        "FORCE_UPDATE_APP_STORE_URL",
        "https://apps.apple.com/us/search?term=Life%20OS",
        () => {
          withEnv("FORCE_UPDATE_APP_STORE_ID", "9876543210", () => {
            const response = json({ ok: true });
            assertEquals(response.headers.get("X-Min-App-Version"), "3.1.0");
            assertEquals(
              response.headers.get("X-Soft-Update-Version"),
              "3.2.0",
            );
            assertEquals(
              response.headers.get("X-App-Store-URL"),
              "https://apps.apple.com/app/id9876543210",
            );
          });
        },
      );
    });
  });
});

Deno.test("serviceRoleClient and anonClient validate required env and build clients", () => {
  withEnv("SUPABASE_URL", undefined, () => {
    withEnv("SUPABASE_SERVICE_ROLE_KEY", undefined, () => {
      assertThrows(
        () => serviceRoleClient(),
        Error,
        "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY",
      );
    });
  });

  withEnv("SUPABASE_URL", undefined, () => {
    withEnv("SUPABASE_ANON_KEY", undefined, () => {
      assertThrows(
        () => anonClient("Bearer token"),
        Error,
        "Missing SUPABASE_URL or SUPABASE_ANON_KEY",
      );
    });
  });

  withEnv("SUPABASE_URL", "http://localhost:54321", () => {
    withEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key", () => {
      const client = serviceRoleClient();
      assert(client != null);
    });
  });

  withEnv("SUPABASE_URL", "http://localhost:54321", () => {
    withEnv("SUPABASE_ANON_KEY", "anon-key", () => {
      const client = anonClient("Bearer token");
      assert(client != null);
    });
  });
});

Deno.test("parseWithSchema returns success and issues payloads", () => {
  const schema = v.object({
    name: v.string(),
    age: v.number(),
  });

  const ok = parseWithSchema(schema, { name: "Ada", age: 30 });
  assertEquals(ok.ok, true);
  if (ok.ok) {
    assertEquals(ok.output.name, "Ada");
    assertEquals(ok.output.age, 30);
  }

  const bad = parseWithSchema(schema, { name: 10, age: "old" });
  assertEquals(bad.ok, false);
  if (!bad.ok) {
    assertEquals(bad.issues.length > 0, true);
    assertEquals(typeof bad.issues[0].message, "string");
  }
});

Deno.test("account deletion state machine allows same-state no-op transition", () => {
  assertEquals(canTransitionDeletionState("requested", "requested"), true);
  assertEquals(canTransitionDeletionState("failed", "failed"), true);
  assertDeletionStateTransition("completed", "completed");
});
