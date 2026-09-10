// Audit probes: PASS means the vulnerable behavior was reproduced.
// These invoke real handlers with an in-memory HTTP/PostgREST model, not a live DB.
// Run: deno test --allow-env --allow-read --allow-net audits/system-audit-2026-09-08/backend-regression-probes.test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "../../supabase/functions/tests/_edge_runtime_harness.ts";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const RECORD = "33333333-3333-4333-8333-333333333333";
const MISSING_FOOD = "44444444-4444-4444-8444-444444444444";

Deno.test("AUDIT reproduction: A takes B supplement by supplied id and receives B notes", async () => {
  const handler = await captureEdgeHandler("../api/user-supplements/index.ts");
  let row: Record<string, unknown> = {
    id: RECORD, user_id: B, custom_name: "Original", frequency: "daily",
    notes: "B private note", active: true,
  };
  await withMockedEdgeRuntime({
    publicUser: { id: A, timezone: "UTC" },
    responders: [(request, { url, bodyText }) => {
      if (url.pathname !== "/rest/v1/user_supplements") return undefined;
      assertEquals(request.method, "POST");
      assertEquals(url.searchParams.get("on_conflict"), "id");
      // service-role POST ... on_conflict=id applies supplied columns to existing row.
      assertEquals(request.headers.get("Authorization"), "Bearer service-role-key");
      row = { ...row, ...JSON.parse(bodyText) };
      return jsonResponse(row);
    }],
  }, async () => {
    const response = await handler(new Request("http://localhost/functions/v1/api-user-supplements", {
      method: "POST", headers: { Authorization: "Bearer A-token", "Content-Type": "application/json" },
      body: JSON.stringify({ id: RECORD, custom_name: "A replacement", frequency: "daily" }),
    }));
    const body = await response.json();
    assertEquals(response.status, 200);
    assertEquals(row.user_id, A);
    assertEquals(body.notes, "B private note");
  });
});

Deno.test("AUDIT reproduction: failed meal PATCH destroys original items and changes totals", async () => {
  const handler = await captureEdgeHandler("../api/food/log/index.ts");
  let calories = 300;
  let items = [{ id: RECORD, name: "Original meal item" }];
  const writes: string[] = [];
  await withMockedEdgeRuntime({
    publicUser: { id: A, timezone: "UTC" },
    responders: [(request, { url, bodyText }) => {
      if (url.pathname === "/rest/v1/food_logs") {
        if (request.method === "GET") return jsonResponse([{ id: RECORD, input_method: "manual" }]);
        if (request.method === "PATCH") {
          writes.push("parent update");
          calories = JSON.parse(bodyText).calories;
          return new Response(null, { status: 204 });
        }
      }
      if (url.pathname === "/rest/v1/food_items") {
        if (request.method === "DELETE") {
          writes.push("items delete");
          items = [];
          return new Response(null, { status: 204 });
        }
        if (request.method === "POST") {
          writes.push("items insert fails");
          const inserted = JSON.parse(bodyText);
          assertEquals(inserted[0].user_food_id, MISSING_FOOD);
          return jsonResponse({ code: "23503", message: "food_items_user_food_id_fkey violation" }, 409);
        }
      }
      return undefined;
    }],
  }, async () => {
    const response = await handler(new Request(`http://localhost/functions/v1/api-food-log/${RECORD}`, {
      method: "PATCH", headers: { Authorization: "Bearer A-token", "Content-Type": "application/json" },
      body: JSON.stringify({ items: [{
        name: "Replacement", weight_g: 100, calories: 500,
        protein_g: 20, fat_g: 10, carbs_g: 50, user_food_id: MISSING_FOOD,
      }] }),
    }));
    assertEquals(response.status, 500);
    assertEquals((await response.json()).error, "food_items_insert_failed");
    assertEquals(writes, ["parent update", "items delete", "items insert fails"]);
    assertEquals(items, []);
    assertEquals(calories, 500);
  });
});
