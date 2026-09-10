import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  deleteUserVectorMemory,
  derivedVectorSummary,
  queryUserVectorMemory,
  syncUserVectorMemory,
} from "../_shared/vector_memory.ts";
import {
  createMockSupabaseService,
  type MockQueryResult,
  type MockQueryState,
} from "./_mock_supabase_service.ts";
import {
  captureEdgeHandler,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const SOURCE = "22222222-2222-4222-8222-222222222222";
const vectorId = `${USER}:food_log:${SOURCE}`;
const sourceRow = {
  id: SOURCE,
  updated_at: "2026-09-09T00:00:00Z",
  logged_date: "2026-09-09",
  calories: 300,
  protein_g: 15,
  raw_pdf: "PRIVATE",
  notes: "PRIVATE",
  deleted_at: null,
};

function makeService(
  options: {
    consent?: boolean;
    cleanup?: boolean;
    rejectClaim?: boolean;
    resolve?: (s: MockQueryState) => MockQueryResult | undefined;
  } = {},
) {
  const service = createMockSupabaseService((state) => {
    const result = options.resolve?.(state);
    if (result) return result;
    if (state.table === "privacy_settings" && state.action === "select") {
      return {
        data: {
          vector_opt_in: options.consent ?? true,
          ai_processing_consent: options.consent ?? true,
          vector_cleanup_required: options.cleanup ?? false,
          vector_lease_expires_at: new Date(Date.now() + 600_000).toISOString(),
        },
        error: null,
      };
    }
    if (state.table === "users") {
      return { data: { deletion_in_progress: false }, error: null };
    }
    if (state.table === "food_logs") return { data: [sourceRow], error: null };
    if (
      state.table === "vector_memory" &&
      state.selected === "source_type,source_id"
    ) {
      return {
        data: [{ source_type: "food_log", source_id: SOURCE }],
        error: null,
      };
    }
    return { data: [], count: 0, error: null };
  });
  return {
    ...service,
    rpc: () =>
      Promise.resolve(
        options.rejectClaim
          ? { data: null, error: { code: "55P03", message: "busy" } }
          : { data: true, error: null },
      ),
  };
}

async function withProviders(
  fn: (
    calls: Array<{ path: string; body: Record<string, unknown> }>,
  ) => Promise<void>,
  responder?: (
    path: string,
    body: Record<string, unknown>,
  ) => Response | undefined,
) {
  const before = new Map(
    ["PINECONE_INDEX_HOST", "PINECONE_API_KEY", "OPENROUTER_API_KEY"].map((
      key,
    ) => [key, Deno.env.get(key)]),
  );
  Deno.env.set("PINECONE_INDEX_HOST", "test-index.svc.pinecone.io");
  Deno.env.set("PINECONE_API_KEY", "mock-key");
  Deno.env.set("OPENROUTER_API_KEY", "mock-key");
  const previous = globalThis.fetch;
  const calls: Array<{ path: string; body: Record<string, unknown> }> = [];
  globalThis.fetch =
    (async (input: Request | URL | string, init?: RequestInit) => {
      const request = new Request(input, init);
      const path = new URL(request.url).pathname;
      const body = await request.json();
      calls.push({ path, body });
      const custom = responder?.(path, body);
      if (custom) return custom;
      if (path === "/api/v1/embeddings") {
        return Response.json({
          data: (body.input as string[]).map((_, index) => ({
            index,
            embedding: [0.1, 0.2],
          })),
        });
      }
      assertEquals(body.namespace ?? USER, USER);
      if (path === "/query") {
        return Response.json({
          matches: [{ id: vectorId }, { id: "foreign:food_log:private" }],
        });
      }
      if (path === "/describe_index_stats") {
        return Response.json({ namespaces: {} });
      }
      return Response.json({});
    }) as typeof fetch;
  try {
    await fn(calls);
  } finally {
    globalThis.fetch = previous;
    for (const [key, value] of before) {
      value === undefined ? Deno.env.delete(key) : Deno.env.set(key, value);
    }
  }
}

Deno.test("vector summaries exclude notes, arbitrary fields and non-finite values", () => {
  assertEquals(
    derivedVectorSummary("food_log", "2026-09-09", {
      ...sourceRow,
      fat_g: Infinity,
    }),
    "food_log 2026-09-09: calories=300, protein_g=15",
  );
});

Deno.test("opt-out performs no external embedding, upsert or query", async () => {
  await withProviders(async (calls) => {
    const service = makeService({ consent: false });
    assertEquals(await syncUserVectorMemory(service as never, USER), {
      synced: 0,
      status: "disabled",
    });
    assertEquals(
      await queryUserVectorMemory(service as never, USER, "sleep"),
      [],
    );
    assertEquals(calls, []);
  });
});

Deno.test("vector sync persists a cleanup manifest and idempotent derived vector under user namespace", async () => {
  await withProviders(async (calls) => {
    const service = makeService();
    assertEquals(await syncUserVectorMemory(service as never, USER), {
      synced: 1,
      status: "synced",
    });
    assertEquals(calls.map((c) => c.path), [
      "/api/v1/embeddings",
      "/vectors/upsert",
    ]);
    assert(!JSON.stringify(calls).includes("PRIVATE"));
    assertEquals(
      (calls[1].body.vectors as Array<{ id: string }>)[0].id,
      vectorId,
    );
    assert(
      service.__calls.some((s) =>
        s.table === "vector_memory" && s.action === "upsert"
      ),
    );
    assert(
      service.__calls.some((s) =>
        s.table === "privacy_settings" && s.action === "update" &&
        (s.payload as Record<string, unknown>).vector_last_sync_at
      ),
    );
  });
});

Deno.test("memory retrieval verifies own current SQL source and excludes foreign returned IDs", async () => {
  await withProviders(async () => {
    const service = makeService();
    assertEquals(
      await queryUserVectorMemory(service as never, USER, "nutrition"),
      ["food_log 2026-09-09: calories=300, protein_g=15"],
    );
    const lookup = service.__calls.find((s) => s.table === "vector_memory")!;
    assertEquals(lookup.filters.find((f) => f.column === "vector_id")?.value, [
      vectorId,
    ]);
    assert(
      service.__calls.some((s) =>
        s.table === "food_logs" &&
        s.filters.some((f) => f.column === "deleted_at" && f.value === null)
      ),
    );
  });
});

Deno.test("sync removes vectors for hard-deleted sources discovered by the bounded sweep", async () => {
  await withProviders(async (calls) => {
    const service = makeService({
      resolve: (state) => {
        if (state.table === "food_logs") return { data: [], error: null };
        if (
          state.table === "vector_memory" &&
          state.selected === "vector_id,source_id" &&
          state.filters.some((filter) =>
            filter.column === "source_type" && filter.value === "food_log"
          )
        ) {
          return {
            data: [{ vector_id: vectorId, source_id: SOURCE }],
            error: null,
          };
        }
      },
    });
    assertEquals(await syncUserVectorMemory(service as never, USER), {
      synced: 0,
      status: "synced",
    });
    assertEquals(calls, [{
      path: "/vectors/delete",
      body: { namespace: USER, ids: [vectorId] },
    }]);
    assert(
      service.__calls.some((state) =>
        state.table === "vector_memory" && state.action === "delete" &&
        state.filters.some((filter) =>
          filter.column === "vector_id" &&
          JSON.stringify(filter.value) === JSON.stringify([vectorId])
        )
      ),
    );
  });
});

Deno.test("large embedding batches stay below the Pinecone request byte limit without losing documents", async () => {
  const rows = Array.from(
    { length: 30 },
    (_, index) => ({
      ...sourceRow,
      id: `${SOURCE.slice(0, -2)}${index.toString().padStart(2, "0")}`,
    }),
  );
  await withProviders(
    async (calls) => {
      const service = makeService({
        resolve: (state) =>
          state.table === "food_logs" ? { data: rows, error: null } : undefined,
      });
      assertEquals(
        (await syncUserVectorMemory(service as never, USER)).synced,
        30,
      );
      const batches = calls.filter((call) => call.path === "/vectors/upsert");
      assert(batches.length > 1);
      const ids = batches.flatMap((batch) =>
        (batch.body.vectors as Array<{ id: string }>).map((vector) => vector.id)
      );
      assertEquals(new Set(ids).size, 30);
      for (const batch of batches) {
        assert(
          new TextEncoder().encode(JSON.stringify(batch.body)).byteLength <
            2_000_000,
        );
      }
    },
    (path, body) =>
      path === "/api/v1/embeddings"
        ? Response.json({
          data: (body.input as string[]).map((_, index) => ({
            index,
            embedding: Array.from({ length: 4096 }, () => 0.12345678901234567),
          })),
        })
        : undefined,
  );
});

Deno.test("vector deletion requires confirmed external emptiness before dropping metadata", async () => {
  await withProviders(async (calls) => {
    const service = makeService({ cleanup: true });
    await deleteUserVectorMemory(service as never, USER);
    assertEquals(calls.map((c) => c.path), [
      "/vectors/delete",
      "/describe_index_stats",
    ]);
    assertEquals(calls[0].body, { namespace: USER, deleteAll: true });
    assert(
      service.__calls.some((s) =>
        s.table === "vector_memory" && s.action === "delete"
      ),
    );
  });
  await withProviders(
    async () => {
      const service = makeService({ cleanup: true });
      await assertRejects(
        () => deleteUserVectorMemory(service as never, USER),
        Error,
        "vector_delete_pending",
      );
      assertEquals(
        service.__calls.some((s) =>
          s.table === "vector_memory" && s.action === "delete"
        ),
        false,
      );
    },
    (path) =>
      path === "/describe_index_stats"
        ? Response.json({ namespaces: { [USER]: { vectorCount: 1 } } })
        : undefined,
  );
});

Deno.test("vector operation lease prevents concurrent deletion and upload", async () => {
  await withProviders(async (calls) => {
    const service = makeService({ cleanup: true, rejectClaim: true });
    await assertRejects(
      () => deleteUserVectorMemory(service as never, USER),
      Error,
      "vector_operation_busy",
    );
    await assertRejects(
      () => syncUserVectorMemory(service as never, USER),
      Error,
      "vector_operation_busy",
    );
    assertEquals(calls, []);
  });
});

Deno.test("provider failure leaves manifest for retry and releases operation lease", async () => {
  await withProviders(
    async () => {
      const service = makeService();
      await assertRejects(
        () => syncUserVectorMemory(service as never, USER),
        Error,
        "vector_provider_error_503",
      );
      assert(
        service.__calls.some((s) =>
          s.table === "vector_memory" && s.action === "upsert"
        ),
      );
      assert(
        service.__calls.some((s) =>
          s.table === "privacy_settings" && s.action === "update" &&
          (s.payload as Row).vector_operation_id === null
        ),
      );
    },
    (path) =>
      path === "/vectors/upsert"
        ? Response.json({}, { status: 503 })
        : undefined,
  );
});

type Row = Record<string, unknown>;

Deno.test("worker rejects client JWT even when invocation header is supplied", async () => {
  const handler = await captureEdgeHandler(
    "../api/vector_memory/worker/index.ts",
  );
  await withMockedEdgeRuntime({}, async () => {
    const response = await handler(
      new Request("http://localhost/worker", {
        method: "POST",
        headers: {
          Authorization: "Bearer user-token",
          "X-Vector-Memory-Worker": "scheduled",
        },
        body: "{}",
      }),
    );
    assertEquals(response.status, 401);
  });
});
