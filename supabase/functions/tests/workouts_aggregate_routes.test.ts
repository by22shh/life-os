import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

Deno.test("api-workouts-daily returns non-deleted sessions for a local date", async () => {
  const handler = await captureEdgeHandler("../api/workouts/daily/index.ts");

  await withMockedEdgeRuntime({
    authUser: { id: "auth-user-id" },
    publicUser: { id: "public-user-id", timezone: "Europe/Berlin" },
    responders: [
      (_request, { url }) => {
        if (url.pathname !== "/rest/v1/workout_sessions") return undefined;

        assertEquals(
          url.searchParams.get("select"),
          "id,workout_type,duration_minutes,total_volume",
        );
        assertEquals(url.searchParams.get("user_id"), "eq.public-user-id");
        assertEquals(url.searchParams.get("session_date"), "eq.2026-01-18");
        assertEquals(url.searchParams.get("deleted_at"), "is.null");
        assertEquals(url.searchParams.get("order"), "started_at.asc");

        return jsonResponse([
          {
            id: "session-1",
            workout_type: "strength",
            duration_minutes: 65,
            total_volume: 1040,
          },
        ]);
      },
    ],
  }, async () => {
    const response = await handler(
      new Request(
        "https://edge.test/api-workouts-daily?date=2026-01-18",
        { headers: { Authorization: "Bearer user-token" } },
      ),
    );

    assertEquals(response.status, 200);
    assertEquals(await response.json(), {
      date: "2026-01-18",
      sessions: [
        {
          id: "session-1",
          workout_type: "strength",
          duration_minutes: 65,
          total_volume: 1040,
        },
      ],
    });
  });
});

Deno.test("api-workouts-summary returns volume, TRIMP average, and latest ACWR", async () => {
  const handler = await captureEdgeHandler("../api/workouts/summary/index.ts");
  const expectedTo = localDateTodayUtc();
  const expectedFrom = addDays(expectedTo, -29);

  await withMockedEdgeRuntime({
    authUser: { id: "auth-user-id" },
    publicUser: { id: "public-user-id", timezone: "UTC" },
    responders: [
      (_request, { url }) => {
        if (url.pathname !== "/rest/v1/workout_sessions") return undefined;

        assertEquals(
          url.searchParams.get("select"),
          "total_volume,trimp_score",
        );
        assertEquals(url.searchParams.get("user_id"), "eq.public-user-id");
        assertEquals(url.searchParams.getAll("session_date"), [
          `gte.${expectedFrom}`,
          `lte.${expectedTo}`,
        ]);
        assertEquals(url.searchParams.get("deleted_at"), "is.null");

        return jsonResponse([
          { total_volume: 1000, trimp_score: 40 },
          { total_volume: 18240, trimp_score: 45 },
        ]);
      },
      (_request, { url }) => {
        if (url.pathname !== "/rest/v1/training_loads") return undefined;

        assertEquals(url.searchParams.get("select"), "acwr");
        assertEquals(url.searchParams.get("user_id"), "eq.public-user-id");
        assertEquals(url.searchParams.getAll("date"), [
          `gte.${expectedFrom}`,
          `lte.${expectedTo}`,
        ]);
        assertEquals(url.searchParams.get("order"), "date.desc");
        assertEquals(url.searchParams.get("limit"), "1");

        return jsonResponse({ acwr: 1.123 });
      },
    ],
  }, async () => {
    const response = await handler(
      new Request(
        "https://edge.test/api-workouts-summary?days=30",
        { headers: { Authorization: "Bearer user-token" } },
      ),
    );

    assertEquals(response.status, 200);
    assertEquals(await response.json(), {
      range_days: 30,
      workout_count: 2,
      total_volume: 19240,
      average_trimp: 42.5,
      acwr: 1.1,
    });
  });
});

Deno.test("workout aggregate routes validate methods and query params", async () => {
  const daily = await captureEdgeHandler("../api/workouts/daily/index.ts");
  const summary = await captureEdgeHandler("../api/workouts/summary/index.ts");

  const dailyPost = await daily(
    new Request("https://edge.test/api-workouts-daily", { method: "POST" }),
  );
  assertEquals(dailyPost.status, 405);
  assertEquals(await dailyPost.json(), { error: "method_not_allowed" });

  const dailyInvalidDate = await daily(
    new Request("https://edge.test/api-workouts-daily?date=20260118"),
  );
  assertEquals(dailyInvalidDate.status, 400);
  assertEquals(await dailyInvalidDate.json(), { error: "invalid_date" });

  const summaryPost = await summary(
    new Request("https://edge.test/api-workouts-summary", { method: "POST" }),
  );
  assertEquals(summaryPost.status, 405);
  assertEquals(await summaryPost.json(), { error: "method_not_allowed" });

  const summaryInvalidDays = await summary(
    new Request("https://edge.test/api-workouts-summary?days=91"),
  );
  assertEquals(summaryInvalidDays.status, 400);
  assertEquals(await summaryInvalidDays.json(), { error: "invalid_days" });
});

function localDateTodayUtc(): string {
  return new Intl.DateTimeFormat("en-CA", {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    timeZone: "UTC",
  }).format(new Date());
}

function addDays(date: string, days: number): string {
  const value = Date.parse(`${date}T00:00:00.000Z`);
  return new Date(value + days * 86_400_000).toISOString().slice(0, 10);
}
