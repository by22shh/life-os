import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  deletionReceiptHash,
  issueDeletionReceipt,
  readDeletionReceipt,
} from "../_shared/deletion_receipt.ts";
import { createMockSupabaseService } from "./_mock_supabase_service.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

Deno.test("deletion receipt stores only hash and explicit job/audit binding", async () => {
  const service = createMockSupabaseService(() => ({
    data: null,
    error: null,
  }));
  const receipt = await issueDeletionReceipt(
    service as never,
    { id: "job", audit_log_id: "audit", state: "scheduled" } as never,
  );
  const stored = service.__calls[0].payload as Record<string, unknown>;
  assertEquals(
    stored.token_hash,
    await deletionReceiptHash(receipt.deletion_receipt),
  );
  assert(stored.token_hash !== receipt.deletion_receipt);
  assertEquals(stored.job_id, "job");
  assertEquals(stored.audit_log_id, "audit");
  assertEquals(Object.keys(stored).sort(), [
    "audit_log_id",
    "expires_at",
    "job_id",
    "state",
    "token_hash",
  ]);
});

Deno.test("receipt lookup rejects expired and unknown tokens without revealing a job", async () => {
  const token = "a".repeat(64);
  for (
    const data of [null, {
      state: "completed",
      expires_at: "2020-01-01T00:00:00Z",
    }]
  ) {
    const service = createMockSupabaseService(() => ({ data, error: null }));
    assertEquals(await readDeletionReceipt(service as never, token), null);
    assertEquals(
      service.__calls[0].filters[0].value,
      await deletionReceiptHash(token),
    );
  }
});

Deno.test("client-prepared receipt replays the same job but cannot rebind to another deletion", async () => {
  const token = "b".repeat(64);
  const service = createMockSupabaseService(() => ({
    data: {
      job_id: "job",
      audit_log_id: "audit",
      expires_at: "2099-01-01T00:00:00Z",
    },
    error: null,
  }));
  const receipt = await issueDeletionReceipt(
    service as never,
    { id: "job", audit_log_id: "audit", state: "scheduled" } as never,
    token,
  );
  assertEquals(receipt.deletion_receipt, token);
  assertEquals(receipt.deletion_receipt_expires_at, "2099-01-01T00:00:00Z");
  assertEquals(service.__calls.every((call) => call.action === "select"), true);
  await assertRejects(() =>
    issueDeletionReceipt(
      service as never,
      { id: "another-job", audit_log_id: "audit", state: "scheduled" } as never,
      token,
    )
  );
});

Deno.test("status receipt works without an active auth principal and returns only status", async () => {
  const handler = await captureEdgeHandler(
    "../api/account/delete_status/index.ts",
  );
  await withMockedEdgeRuntime({
    authUser: null,
    responders: [(request, { url }) => {
      if (url.pathname === "/rest/v1/account_deletion_receipts") {
        assertEquals(request.method, "GET");
        return jsonResponse({
          state: "completed",
          expires_at: "2099-01-01T00:00:00Z",
        });
      }
    }],
  }, async (calls) => {
    const response = await handler(
      new Request("https://edge.test/status", {
        headers: { "X-Deletion-Receipt": "a".repeat(64) },
      }),
    );
    assertEquals(response.status, 200);
    assertEquals(await response.json(), {
      deletion_state: "completed",
      completed: true,
    });
    assertEquals(calls.authHeaders.length, 0);
    assertEquals(calls.rateLimitBodies.length > 0, true);
  });
});

Deno.test("status without receipt still requires live authenticated user", async () => {
  const handler = await captureEdgeHandler(
    "../api/account/delete_status/index.ts",
  );
  await withMockedEdgeRuntime({ authUser: null }, async () => {
    const response = await handler(
      new Request("https://edge.test/status", {
        headers: { Authorization: "Bearer expired" },
      }),
    );
    assertEquals(response.status, 401);
  });
});
