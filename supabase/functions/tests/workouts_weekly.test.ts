import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

Deno.test("api-workouts-weekly returns ISO weekly session metrics and filters by range", async () => {
  const handler = await captureEdgeHandler("../api/workouts/weekly/index.ts");

  await withMockedEdgeRuntime({
    authUser: { id: "auth-user-id" },
    publicUser: { id: "public-user-id", timezone: "Europe/Berlin" },
    responders: [
      (_request, { url }) => {
        if (url.pathname !== "/rest/v1/workout_sessions") return undefined;

        assertEquals(
          url.searchParams.get("select"),
          "session_date,duration_minutes,trimp_score",
        );
        assertEquals(url.searchParams.get("user_id"), "eq.public-user-id");
        assertEquals(url.searchParams.getAll("session_date"), [
          "gte.2026-01-01",
          "lte.2026-01-31",
        ]);
        assertEquals(url.searchParams.get("deleted_at"), "is.null");

        return jsonResponse([
          {
            session_date: "2026-01-05",
            duration_minutes: 60,
            trimp_score: 45,
          },
          {
            session_date: "2026-01-07",
            duration_minutes: 45,
            trimp_score: 55.5,
          },
          {
            session_date: "2026-01-12",
            duration_minutes: null,
            trimp_score: null,
          },
          {
            session_date: "not-a-date",
            duration_minutes: 999,
            trimp_score: 999,
          },
        ]);
      },
    ],
  }, async () => {
    const response = await handler(
      new Request(
        "https://edge.test/api-workouts-weekly?from=2026-01-01&to=2026-01-31",
        { headers: { Authorization: "Bearer user-token" } },
      ),
    );

    assertEquals(response.status, 200);
    assertEquals(await response.json(), {
      from: "2026-01-01",
      to: "2026-01-31",
      weeks: [
        {
          week_start: "2026-01-05",
          week_end: "2026-01-11",
          session_count: 2,
          total_duration_minutes: 105,
          total_trimp: 100.5,
          average_trimp: 50.3,
        },
        {
          week_start: "2026-01-12",
          week_end: "2026-01-18",
          session_count: 1,
          total_duration_minutes: 0,
          total_trimp: 0,
          average_trimp: 0,
        },
      ],
    });
  });
});

Deno.test("api-workouts-weekly validates method and max 26-week range before auth", async () => {
  const handler = await captureEdgeHandler("../api/workouts/weekly/index.ts");

  const invalidMethod = await handler(
    new Request("https://edge.test/api-workouts-weekly", { method: "POST" }),
  );
  assertEquals(invalidMethod.status, 405);
  assertEquals(await invalidMethod.json(), { error: "method_not_allowed" });

  const invalidRange = await handler(
    new Request(
      "https://edge.test/api-workouts-weekly?from=2026-01-01&to=2026-07-05",
    ),
  );
  assertEquals(invalidRange.status, 400);
  assertEquals(await invalidRange.json(), { error: "invalid_range" });
});
