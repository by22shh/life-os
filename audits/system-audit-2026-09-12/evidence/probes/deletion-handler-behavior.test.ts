import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { captureEdgeHandler, jsonResponse, withMockedEdgeRuntime } from "../../../../supabase/functions/tests/_edge_runtime_harness.ts";

// These characterization probes assert the observed defect, not desired behavior.
// Every fetch is intercepted; no database, Auth erasure, storage or provider call runs.

Deno.test("audit: cancellation reports success after losing worker state race", async () => {
  const handler = await captureEdgeHandler("../api/account/delete_cancel/index.ts");
  let state = "scheduled";
  await withMockedEdgeRuntime({
    publicUser: { id: "audit-user", deletion_scheduled_at: "2026-09-12T00:00:00Z", deletion_in_progress: false },
    userLookupResponse: (request) => request.method === "PATCH" ? jsonResponse(null) : undefined,
    responders: [(request, { url }) => {
      if (url.pathname !== "/rest/v1/account_deletion_jobs") return undefined;
      if (request.method === "GET") return jsonResponse([{ id: "audit-job", state: "scheduled" }]);
      state = "data_deleting"; // worker wins compare-and-swap before cancellation
      return jsonResponse([]); // PATCH ... state=scheduled affected zero rows
    }],
  }, async () => {
    const response = await handler(new Request("http://localhost/functions/v1/api-account-delete-cancel", {
      method: "POST", headers: { Authorization: "Bearer fixture-token" },
    }));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { cancelled: true, deletion_state: "cancelled" });
    assertEquals(state, "data_deleting");
  });
});

Deno.test("audit: storage lookup failure strands claimed deletion beyond subsequent worker runs", async () => {
  const handler = await captureEdgeHandler("../api/account/delete_worker/index.ts");
  let job = {
    id: "audit-job", user_id: "audit-user", auth_user_id: "audit-auth", idempotency_key: "audit-key",
    mode: "scheduled", state: "scheduled", reason: "user_requested", attempt_count: 0,
    next_retry_at: null, last_error: null, last_failure_type: null,
    scheduled_for: "2026-09-12T00:00:00Z", audit_log_id: "audit-log", storage_object_paths: [],
    storage_cleanup_completed: false, storage_cleanup_completed_at: null,
    created_at: "2026-09-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z",
  };
  await withMockedEdgeRuntime({
    publicUser: { id: "audit-user", auth_id: "audit-auth", deletion_reason: "user_requested" },
    userLookupResponse: (request) => request.method === "PATCH" ? jsonResponse(null) : undefined,
    responders: [(request, { url, bodyText }) => {
      if (url.pathname === "/rest/v1/account_deletion_jobs") {
        if (request.method === "GET") {
          const requestedState = url.searchParams.get("state")?.replace(/^eq\./, "");
          return jsonResponse(requestedState === job.state ? [job] : []);
        }
        job = { ...job, ...JSON.parse(bodyText) };
        return jsonResponse([job]);
      }
      if (url.pathname === "/rest/v1/medical_scans") {
        return jsonResponse({ message: "fixture database unavailable", code: "XX000" }, 500);
      }
      return undefined;
    }],
  }, async () => {
    const request = () => new Request("http://localhost/functions/v1/api-account-delete-worker", {
      method: "POST",
      headers: { Authorization: "Bearer service-role-key", apikey: "service-role-key", "X-Account-Deletion-Worker": "scheduled", "Content-Type": "application/json" },
      body: "{}",
    });
    const first = await handler(request());
    assertEquals(first.status, 500);
    assertEquals(job.state, "data_deleting");
    const second = await handler(request());
    assertEquals(second.status, 200);
    assertEquals(await second.json(), { processed: 0, results: [] });
    assertEquals(job.state, "data_deleting");
  });
});
