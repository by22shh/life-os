import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

const routes: Array<
  { path: string; method?: string; query?: string; body?: unknown }
> = [
  { path: "analyze-food-image" },
  { path: "analyze-food-label" },
  { path: "analyze-batch-recipe-image" },
  { path: "send-notification" },
  { path: "ai/openrouter-gateway" },
  { path: "api/analytics/batch" },
  {
    path: "api/notifications/register_device",
    body: {
      device_id: "device",
      push_token: "a".repeat(64),
      platform: "ios",
      environment: "development",
    },
  },
  {
    path: "api/notifications/unregister_device",
    body: { device_id: "device" },
  },
  { path: "api/account/delete" },
  { path: "api/account/delete_cancel" },
  { path: "api/account/delete_status", method: "GET" },
  { path: "api/watch/snapshot", method: "GET" },
  { path: "api/user/export" },
  {
    path: "api/user/export_status",
    method: "GET",
    query: "?export_id=11111111-1111-4111-8111-111111111111",
  },
  {
    path: "api/user/export_download",
    method: "GET",
    query:
      "?export_id=11111111-1111-4111-8111-111111111111&token=valid-shaped-token",
  },
  { path: "api/insight/acknowledge" },
  { path: "api/menstrual/sync" },
  { path: "api/settings/privacy", method: "PATCH" },
  { path: "api/settings/consent" },
];

Deno.test("all migrated Auth routes distinguish invalid sessions from upstream failures before protected work", async (t) => {
  for (const route of routes) {
    await t.step(route.path, async () => {
      const handler = await captureEdgeHandler(`../${route.path}/index.ts`);
      for (const upstreamStatus of [401, 429, 503]) {
        await withMockedEdgeRuntime({
          authResponse: () =>
            jsonResponse({ message: "test auth response" }, upstreamStatus),
        }, async (calls) => {
          const method = route.method ?? "POST";
          const response = await handler(
            new Request(`https://edge.test/${route.query ?? ""}`, {
              method,
              headers: {
                Authorization: "Bearer route-test-token",
                "Content-Type": "application/json",
                "X-Device-Id": "auth-route-test",
                "Idempotency-Key": "11111111-1111-4111-8111-111111111111",
              },
              ...(method === "GET"
                ? {}
                : { body: JSON.stringify(route.body ?? {}) }),
            }),
          );
          assertEquals(
            response.status,
            upstreamStatus === 401 ? 401 : 503,
            route.path,
          );
          assertEquals(await response.json(), {
            error: upstreamStatus === 401 ? "unauthorized" : "auth_unavailable",
          });
          assertEquals(calls.authHeaders.length, 1);
          assertEquals(calls.userLookupUrls.length, 0);
          assertEquals(calls.rateLimitBodies.length, 0);
          assertEquals(
            calls.fetches.length,
            1,
            "must not write or invoke providers without verified auth",
          );
        });
      }
    });
  }
});
