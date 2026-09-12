import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  canonicalAuthUserId,
  type UserRow,
} from "../_shared/account_deletion.ts";
import { __dailyInsightsTestHooks } from "../_shared/daily_insights.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

const user: UserRow = {
  id: "11111111-1111-4111-8111-111111111111",
  auth_id: "22222222-2222-4222-8222-222222222222",
};

Deno.test("account deletion always derives the auth principal from the public user", () => {
  assertEquals(
    canonicalAuthUserId(user),
    "22222222-2222-4222-8222-222222222222",
  );
});

Deno.test("scheduled deletion cancellation uses one atomic RPC and reports an active worker", async () => {
  const handler = await captureEdgeHandler(
    "../api/account/delete_cancel/index.ts",
  );

  await withMockedEdgeRuntime({
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/rpc/cancel_scheduled_account_deletion") {
          return jsonResponse("in_progress");
        }
        return undefined;
      },
    ],
  }, async (calls) => {
    const response = await handler(
      new Request("http://localhost/functions/v1/api-account-delete-cancel", {
        method: "POST",
        headers: { Authorization: "Bearer valid-token" },
      }),
    );

    assertEquals(response.status, 409);
    assertEquals(await response.json(), {
      error: "deletion_already_in_progress",
    });
    const rpcCall = calls.fetches.find((call) =>
      call.url.pathname === "/rest/v1/rpc/cancel_scheduled_account_deletion"
    );
    assertEquals(
      rpcCall?.bodyText,
      JSON.stringify({ p_user_id: "public-user-id" }),
    );
    assertEquals(
      calls.fetches.some((call) =>
        call.url.pathname === "/rest/v1/account_deletion_jobs"
      ),
      false,
    );
  });
});

Deno.test("prediction falls back when an AI response has no personal historical support", async () => {
  const handler = await captureEdgeHandler("../api/insights/predict/index.ts");
  const historyTables = new Set([
    "/rest/v1/physiological_states",
    "/rest/v1/training_loads",
    "/rest/v1/daily_nutrition_summary",
    "/rest/v1/daily_nutrition_targets",
    "/rest/v1/hydration_logs",
    "/rest/v1/wellness_checks",
    "/rest/v1/workout_sessions",
    "/rest/v1/insights",
  ]);

  await withMockedEdgeRuntime({
    env: { OPENROUTER_API_KEY: "test-key" },
    responders: [
      (_request, { url }) => {
        if (historyTables.has(url.pathname)) return jsonResponse([]);
        if (url.href === "https://openrouter.ai/api/v1/chat/completions") {
          return jsonResponse({
            choices: [{
              message: {
                content: JSON.stringify({
                  predicted_recovery_range: [10, 20],
                  predicted_score: 15,
                  predicted_zone: "optimal",
                  confidence_score: 1,
                  explanation: "Unsupported certainty",
                }),
              },
            }],
          });
        }
        return undefined;
      },
    ],
  }, async () => {
    const response = await handler(
      new Request("http://localhost/functions/v1/api-insights-predict", {
        method: "POST",
        headers: {
          Authorization: "Bearer valid-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          target_date: "2026-09-13",
          scenario_type: "general",
          scenario_text: "A normal workday",
        }),
      }),
    );

    assertEquals(response.status, 200);
    const payload = await response.json() as Record<string, unknown>;
    assertEquals(payload.historical_match_count, 0);
    assertEquals(payload.fallback_mode, "deterministic");
    assertEquals(payload.historical_evidence, "none");
    assertEquals(payload.predicted_recovery_range, [57, 73]);
    assertEquals(payload.predicted_zone, "ready");
    assertEquals(payload.confidence_score, 0.35);
  });
});

Deno.test("daily recovery copy never reverses the direction of a historical comparison", async () => {
  const lowerButImproving = await __dailyInsightsTestHooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-02",
    generatedAt: "2026-06-02T10:00:00.000Z",
    localHour: 10,
    baselineSleepHours: null,
    recoveryRows: [
      { date: "2026-06-01", recovery_score: 20, recovery_zone: "critical" },
      { date: "2026-06-02", recovery_score: 40, recovery_zone: "caution" },
    ],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 0,
    totalTrimp: 0,
  } as never);
  assertEquals(
    lowerButImproving.insights[0]?.title,
    "Recovery needs a lighter day",
  );
  assertEquals(
    lowerButImproving.insights[0]?.body.includes("below your recent pattern"),
    false,
  );

  const highButDeclining = await __dailyInsightsTestHooks.buildDailySnapshot({
    userId: "user-1",
    date: "2026-06-02",
    generatedAt: "2026-06-02T10:00:00.000Z",
    localHour: 10,
    baselineSleepHours: null,
    recoveryRows: [
      { date: "2026-06-01", recovery_score: 90, recovery_zone: "optimal" },
      { date: "2026-06-02", recovery_score: 80, recovery_zone: "optimal" },
    ],
    nutritionTarget: null,
    totalProtein: 0,
    mealCount: 0,
    workoutCount: 0,
    totalTrimp: 0,
  } as never);
  assertStringIncludes(
    highButDeclining.insights[0]?.body ?? "",
    "supports a normal training",
  );
  assertEquals(
    highButDeclining.insights[0]?.body.includes("above your recent range"),
    false,
  );
});
