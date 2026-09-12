import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

const planId = "11111111-1111-4111-8111-111111111111";

Deno.test("training generation persists executable exercises through the atomic plan RPC", async () => {
  const handler = await captureEdgeHandler("../api/training/plan/index.ts");

  await withMockedEdgeRuntime({
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/rpc/create_training_plan_atomic") {
          return jsonResponse(planId);
        }
        return undefined;
      },
    ],
  }, async (calls) => {
    const response = await handler(
      new Request(
        "http://localhost/functions/v1/api-training-plan/generate",
        {
          method: "POST",
          headers: {
            Authorization: "Bearer valid-token",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            goal: "hypertrophy",
            available_days: [1],
            duration_weeks: 1,
            session_duration_minutes: 55,
          }),
        },
      ),
    );

    assertEquals(response.status, 200);
    const rpc = calls.fetches.find((call) =>
      call.url.pathname === "/rest/v1/rpc/create_training_plan_atomic"
    );
    assert(rpc);
    const body = JSON.parse(rpc.bodyText) as {
      p_sessions: Array<{ planned_exercises: Record<string, unknown> }>;
    };
    assertEquals(body.p_sessions.length, 1);
    const executable = body.p_sessions[0].planned_exercises;
    assertEquals(executable.duration_minutes, 55);
    assertEquals(executable.session_type, "strength");
    assert(Array.isArray(executable.exercises));
    assertEquals(executable.exercises.length, 3);
    assertEquals(
      (executable.exercises[0] as Record<string, unknown>).sets,
      3,
    );
  });
});

Deno.test("training adjustment invokes the atomic session-changing RPC and returns its change count", async () => {
  const handler = await captureEdgeHandler("../api/training/plan/index.ts");

  await withMockedEdgeRuntime({
    responders: [
      (_request, { url }) => {
        if (url.pathname === "/rest/v1/rpc/apply_training_plan_adjustment") {
          return jsonResponse({
            plan_found: true,
            sessions_adjusted: 3,
            skipped_sessions: 0,
          });
        }
        return undefined;
      },
    ],
  }, async (calls) => {
    const response = await handler(
      new Request(
        `http://localhost/functions/v1/api-training-plan/${planId}/adjust`,
        {
          method: "PATCH",
          headers: {
            Authorization: "Bearer valid-token",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            reason: "recovery_low",
            adjustment: "reduce_volume_30",
          }),
        },
      ),
    );

    assertEquals(response.status, 200);
    const responseBody = await response.json() as Record<string, unknown>;
    assertEquals(responseBody.plan_id, planId);
    assertEquals(responseBody.adjusted, true);
    assert(/^\d{4}-\d{2}-\d{2}$/.test(String(responseBody.effective_from)));
    assertEquals(responseBody.sessions_adjusted, 3);
    assertEquals(responseBody.skipped_sessions, 0);
    const rpc = calls.fetches.find((call) =>
      call.url.pathname === "/rest/v1/rpc/apply_training_plan_adjustment"
    );
    assert(rpc);
    const body = JSON.parse(rpc.bodyText) as Record<string, unknown>;
    assertEquals(body.p_plan_id, planId);
    assertEquals(body.p_adjustment, "reduce_volume_30");
    assertEquals(body.p_reason, "recovery_low");
    assertEquals(
      calls.fetches.some((call) =>
        call.url.pathname === "/rest/v1/training_plans"
      ),
      false,
    );
  });
});
