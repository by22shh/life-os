import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

const user = "11111111-1111-4111-8111-111111111111";
const payload = {
  id: "22222222-2222-4222-8222-222222222222",
  date: "2026-03-08",
  source: "manual",
  total_duration_minutes: 480,
  updated_at: "2026-03-08T08:00:00Z",
};
function request(body: unknown, method = "POST") {
  return new Request("http://localhost/functions/v1/api-sleep-log", {
    method,
    headers: {
      Authorization: "Bearer test",
      "Content-Type": "application/json",
    },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

Deno.test("sleep write validates identity, calendar date, duration, stages and malformed payloads", async () => {
  const handler = await captureEdgeHandler("../api/sleep/log/index.ts");
  await withMockedEdgeRuntime(
    { publicUser: { id: user, timezone: "UTC" } },
    async () => {
      for (
        const value of [
          null,
          [],
          { ...payload, date: "2026-02-30" },
          { ...payload, id: "invalid" },
          { ...payload, source: "fake" },
          { ...payload, total_duration_minutes: -1 },
          { ...payload, deep_sleep_minutes: 2.5 },
          { ...payload, sleep_efficiency: 101 },
          { ...payload, updated_at: null },
          {
            ...payload,
            bed_time: "2026-03-08T09:00:00Z",
            wake_time: "2026-03-08T08:00:00Z",
          },
        ]
      ) {
        assertEquals((await handler(request(value))).status, 400);
      }
      assertEquals((await handler(request(null, "GET"))).status, 405);
    },
  );
});

Deno.test("sleep write binds actor, clears missing objective stages, preserves canonical server identity", async () => {
  const handler = await captureEdgeHandler("../api/sleep/log/index.ts");
  let calls = 0;
  await withMockedEdgeRuntime({
    publicUser: { id: user, timezone: "UTC" },
    responders: [(_req, { url, bodyText }) => {
      if (
        url.pathname !== "/rest/v1/rpc/upsert_canonical_sleep"
      ) return undefined;
      calls++;
      const body = JSON.parse(bodyText);
      assertEquals(body.p_user_id, user);
      assertEquals(body.p_payload.user_id, undefined);
      assertEquals(body.p_payload.sleep_date, "2026-03-08");
      assertEquals(body.p_payload.date, undefined);
      assertEquals(body.p_payload.deep_sleep_minutes, null);
      assertEquals(body.p_payload.client_updated_at, payload.updated_at);
      assertEquals(body.p_payload.created_at, undefined);
      return jsonResponse({
        id: user,
        source: "manual",
        total_duration_minutes: 480,
      });
    }],
  }, async () => {
    const response = await handler(
      request({ ...payload, user_id: "spoofed", created_at: "invalid" }),
    );
    assertEquals(response.status, 200);
    assertEquals((await response.json()).sleep_log.id, user);
    assertEquals(calls, 1);
  });
});

Deno.test("sleep write surfaces owner violation and does not disclose SQL errors", async () => {
  const handler = await captureEdgeHandler("../api/sleep/log/index.ts");
  for (
    const [code, status] of [["42501", 403], ["22023", 400], [
      "XX000",
      500,
    ]] as const
  ) {
    await withMockedEdgeRuntime({
      publicUser: { id: user, timezone: "UTC" },
      responders: [
        (_req, { url }) =>
          url.pathname === "/rest/v1/rpc/upsert_canonical_sleep"
            ? jsonResponse({ code, message: "sensitive database detail" }, 400)
            : undefined,
      ],
    }, async () => {
      const response = await handler(request(payload));
      assertEquals(response.status, status);
      assertEquals((await response.text()).includes("sensitive"), false);
    });
  }
});
