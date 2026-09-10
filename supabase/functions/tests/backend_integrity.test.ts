import {
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";
import {
  listOwnedMedicalScanStorageObjects,
  verifyMedicalScanStorageObjectsRemovedViaStorageApi,
} from "../_shared/medical_scan_privacy.ts";

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const ID = "33333333-3333-4333-8333-333333333333";
const headers = {
  Authorization: "Bearer user-token",
  "Content-Type": "application/json",
};

for (
  const [route, table, payload] of [
    ["user-supplements", "user_supplements", {
      id: ID,
      custom_name: "Replacement",
      frequency: "daily",
    }],
    ["body-composition", "body_composition", {
      id: ID,
      measured_at: "2026-09-09T12:00:00Z",
      weight_kg: 72,
    }],
    ["labs", "medical_scans", {
      scan_id: ID,
      scan_type: "blood_test",
      scan_date: "2026-09-09",
    }],
  ] as const
) {
  Deno.test(`${route} rejects a foreign ID before any write or private-field response`, async () => {
    const handler = await captureEdgeHandler(`../api/${route}/index.ts`);
    let writes = 0;
    await withMockedEdgeRuntime({
      publicUser: { id: A, timezone: "UTC" },
      responders: [(request, { url }) => {
        if (url.pathname === "/rest/v1/privacy_settings") {
          return jsonResponse({ medical_scan_local_only: true });
        }
        if (url.pathname === `/rest/v1/${table}`) {
          if (request.method !== "GET") writes++;
          return jsonResponse({ id: ID, user_id: B, notes: "private note" });
        }
      }],
    }, async () => {
      const response = await handler(
        new Request(`http://localhost/functions/v1/api-${route}`, {
          method: "POST",
          headers,
          body: JSON.stringify(payload),
        }),
      );
      assertEquals(response.status, 403);
      assertEquals(await response.json(), { error: "forbidden_id_ownership" });
      assertEquals(writes, 0);
    });
  });
}

for (
  const [route, table, rpc, payload, existing] of [
    ["food/log", "food_logs", "patch_food_log_atomic", {
      items: [{
        name: "Replacement",
        weight_g: 100,
        calories: 500,
        protein_g: 20,
        fat_g: 10,
        carbs_g: 50,
        user_food_id: B,
      }],
    }, { input_method: "manual" }],
    ["workouts", "workout_sessions", "patch_workout_atomic", {
      notes: "updated",
    }, {
      source: "manual",
      started_at: "2026-09-09T12:00:00Z",
      ended_at: null,
      session_date: "2026-09-09",
      training_plan_id: null,
    }],
  ] as const
) {
  Deno.test(`${route} sends mutation as one RPC and propagates rollback failure`, async () => {
    const handler = await captureEdgeHandler(`../api/${route}/index.ts`);
    let rpcCalls = 0;
    let directWrites = 0;
    await withMockedEdgeRuntime({
      publicUser: { id: A, timezone: "UTC" },
      responders: [(request, { url, bodyText }) => {
        if (url.pathname === `/rest/v1/rpc/${rpc}`) {
          rpcCalls++;
          const body = JSON.parse(bodyText);
          assertEquals(body.p_user_id, A);
          assertEquals(body.p_log_id ?? body.p_session_id, ID);
          return jsonResponse({
            code: "23503",
            message: "invalid child reference",
          }, 409);
        }
        if (url.pathname === `/rest/v1/${table}` && request.method === "GET") {
          return jsonResponse([{ id: ID, ...existing }]);
        }
        if (request.method !== "GET") directWrites++;
      }],
    }, async () => {
      const response = await handler(
        new Request(
          `http://localhost/functions/v1/api-${
            route.replaceAll("/", "-")
          }/${ID}`,
          {
            method: "PATCH",
            headers,
            body: JSON.stringify(payload),
          },
        ),
      );
      assertEquals(response.status, 500);
      assertEquals(rpcCalls, 1);
      assertEquals(directWrites, 0);
    });
  });
}

Deno.test("menstrual writes require explicit current cloud consent, including outbox replay", async () => {
  const handler = await captureEdgeHandler("../api/menstrual/sync/index.ts");
  for (const privacy of [null, { menstrual_local_only: true }]) {
    let writes = 0;
    await withMockedEdgeRuntime({
      publicUser: { id: A },
      responders: [(request, { url }) => {
        if (url.pathname === "/rest/v1/privacy_settings") {
          return jsonResponse(privacy);
        }
        if (url.pathname === "/rest/v1/menstrual_logs") {
          if (request.method !== "GET") writes++;
          return jsonResponse(null);
        }
      }],
    }, async () => {
      const response = await handler(
        new Request("http://localhost/api-menstrual-sync", {
          method: "POST",
          headers: { ...headers, "X-Outbox-Replay": "true" },
          body: JSON.stringify({ id: ID, date: "2026-09-09", flow: "light" }),
        }),
      );
      assertEquals(response.status, 403);
      assertEquals(writes, 0);
    });
  }
});

Deno.test("storage manifest includes orphan uploads and paginates owned nested folders", async () => {
  const listed: string[] = [];
  const service = {
    storage: {
      from: () => ({
        list: (directory: string, options: { offset: number }) => {
          listed.push(directory);
          const data = directory === A
            ? [{ name: "orphan-folder", id: null }]
            : options.offset === 0
            ? Array.from(
              { length: 100 },
              (_, i) => ({ name: `scan-${i}.pdf`, id: String(i) }),
            )
            : [{ name: "last.pdf", id: "last" }];
          return Promise.resolve({ data, error: null });
        },
      }),
    },
  };
  const paths = await listOwnedMedicalScanStorageObjects(service as never, A);
  assertEquals(paths.length, 101);
  assertEquals(paths.includes(`${A}/orphan-folder/last.pdf`), true);
  assertEquals(
    listed.every((prefix) => prefix === A || prefix.startsWith(`${A}/`)),
    true,
  );
});

Deno.test("storage verification detects a survivor after page one", async () => {
  const service = {
    storage: {
      from: () => ({
        list: (_directory: string, options: { offset: number }) =>
          Promise.resolve({
            data: options.offset === 0
              ? Array.from(
                { length: 100 },
                (_, i) => ({ name: `copy-${i}-original.pdf` }),
              )
              : [{ name: "original.pdf" }],
            error: null,
          }),
      }),
    },
  };
  await assertRejects(
    () =>
      verifyMedicalScanStorageObjectsRemovedViaStorageApi(service as never, [
        `${A}/original.pdf`,
      ]),
    Error,
    "objects_remaining",
  );
});
