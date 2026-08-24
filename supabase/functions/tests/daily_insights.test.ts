import {
  assertEquals,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  generateAndPersistDailyInsights,
  type GeneratedInsightRow,
  type GeneratedRecommendationRow,
} from "../_shared/daily_insights.ts";
import {
  createMockSupabaseService,
  type MockQueryState,
} from "./_mock_supabase_service.ts";

const USER_ID = "11111111-1111-4111-8111-111111111111";

function filterValue(
  state: MockQueryState,
  op: string,
  column: string,
): unknown {
  return state.filters.find((filter) =>
    filter.op === op && filter.column === column
  )?.value;
}

function makeExistingInsight(overrides: Partial<GeneratedInsightRow> = {}) {
  return {
    id: "existing-insight",
    user_id: USER_ID,
    created_at: "2026-02-20T10:00:00.000Z",
    updated_at: "2026-02-20T10:00:00.000Z",
    category: "recovery",
    type: "daily/2026-02-20/recovery_status",
    title: "Existing insight",
    description: "Existing",
    body: "Existing body",
    reasoning: "Existing reasoning",
    confidence: 0.8,
    confidence_score: 0.8,
    inputs_used: "physiological_states",
    needs_review: false,
    related_metrics: ["recovery_score"],
    related_dates: ["2026-02-20"],
    priority: 2,
    actionable: true,
    action_type: "rest",
    shown_to_user: true,
    shown_at: "2026-02-20T11:00:00.000Z",
    read: true,
    read_at: "2026-02-20T11:05:00.000Z",
    acknowledged: false,
    acknowledged_at: null,
    dismissed: false,
    dismissed_at: null,
    acted_upon: false,
    action_taken: null,
    expires_at: "2026-02-27T10:00:00.000Z",
    ...overrides,
  } satisfies GeneratedInsightRow;
}

function makeExistingRecommendation(
  overrides: Partial<GeneratedRecommendationRow> = {},
) {
  return {
    id: "existing-recommendation",
    user_id: USER_ID,
    created_at: "2026-02-20T10:00:00.000Z",
    updated_at: "2026-02-20T10:00:00.000Z",
    recommendation_date: "2026-02-20",
    time_of_day: "morning",
    category: "recovery",
    priority: "medium",
    title: "Existing recommendation",
    description: "Existing description",
    reasoning: "Existing reasoning",
    insight_id: null,
    action_type: null,
    action_parameters: { focus: "consistency" },
    auto_execute: false,
    dismissed: false,
    followed: null,
    user_feedback: null,
    recovery_score_at_time: null,
    trigger_condition: "daily/2026-02-20/steady_day",
    ...overrides,
  } satisfies GeneratedRecommendationRow;
}

async function withMockedDate(
  isoTimestamp: string,
  fn: () => Promise<void>,
): Promise<void> {
  const RealDate = Date;
  const fixedTime = new RealDate(isoTimestamp).getTime();

  class MockDate extends RealDate {
    constructor(value?: ConstructorParameters<typeof Date>[0]) {
      super(value ?? fixedTime);
    }

    static override now() {
      return fixedTime;
    }

    static override parse(value: string) {
      return RealDate.parse(value);
    }

    static override UTC(...args: Parameters<typeof Date.UTC>) {
      return RealDate.UTC(...args);
    }
  }

  globalThis.Date = MockDate as DateConstructor;
  try {
    await fn();
  } finally {
    globalThis.Date = RealDate;
  }
}

async function stableManagedId(
  prefix: "insight" | "recommendation",
  key: string,
): Promise<string> {
  const seed = `${prefix}:${USER_ID.toLowerCase()}:${key}`;
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed)),
  );
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes).map((value) =>
    value.toString(16).padStart(2, "0")
  ).join("");
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20, 32),
  ].join("-");
}

Deno.test("daily insights emit setup prompt and steady recommendation on sparse day", async () => {
  await withMockedDate("2026-02-22T10:00:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: null }, error: null };
      }

      if (
        ["physiological_states", "food_logs", "workout_sessions"].includes(
          state.table,
        ) && state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "update"
      ) {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      date: "2026-02-22",
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(snapshot.generated_at, "2026-02-22T10:00:00.000Z");
    assertEquals(snapshot.insights.length, 1);
    assertEquals(
      snapshot.insights[0].type,
      "daily/2026-02-22/setup_prompt",
    );
    assertEquals(
      snapshot.insights[0].title,
      "One more signal unlocks a sharper daily read",
    );

    assertEquals(snapshot.recommendations.length, 1);
    assertEquals(
      snapshot.recommendations[0].trigger_condition,
      "daily/2026-02-22/setup_prompt",
    );
    assertEquals(
      snapshot.recommendations[0].title,
      "Add one signal to today's diary",
    );
  });
});

Deno.test("daily insights generate rich recovery snapshot and dismiss stale rows", async () => {
  await withMockedDate("2026-02-22T18:00:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: 8 }, error: null };
      }

      if (
        state.table === "physiological_states" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            {
              date: "2026-02-20",
              recovery_score: 72,
              recovery_zone: "ready",
              sleep_duration_hours: 8.1,
              allostatic_load: 2,
              confidence_score: 0.82,
            },
            {
              date: "2026-02-21",
              recovery_score: 70,
              recovery_zone: "ready",
              sleep_duration_hours: 7.9,
              allostatic_load: 2,
              confidence_score: 0.8,
            },
            {
              date: "2026-02-22",
              recovery_score: 40,
              recovery_zone: "strained",
              sleep_duration_hours: 6.5,
              allostatic_load: 5,
              confidence_score: 0.9,
            },
          ],
          error: null,
        };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return {
          data: { final_calories: 2200, final_protein_g: 150 },
          error: null,
        };
      }

      if (state.table === "food_logs" && state.terminal === "returns") {
        return {
          data: [
            { calories: 500, protein_g: 40 },
            { calories: 700, protein_g: 30 },
          ],
          error: null,
        };
      }

      if (state.table === "workout_sessions" && state.terminal === "returns") {
        return {
          data: [{ trimp_score: 90, duration_minutes: 75 }],
          error: null,
        };
      }

      if (
        state.table === "insights" &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        const typeLike = filterValue(state, "like", "type");
        if (typeLike === "daily/2026-02-22/%") {
          return {
            data: [
              makeExistingInsight({
                id: "stale-insight",
                type: "daily/2026-02-22/unused",
                title: "Dismiss me",
              }),
            ],
            error: null,
          };
        }

        if (typeLike === "daily/%") {
          return {
            data: [
              makeExistingInsight({
                id: "old-insight",
                type: "daily/2026-02-20/recovery_status",
                dismissed: false,
              }),
            ],
            error: null,
          };
        }
      }

      if (
        state.table === "recommendations" &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            makeExistingRecommendation({
              id: "stale-recommendation",
              trigger_condition: "daily/2026-02-22/unused",
            }),
          ],
          error: null,
        };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "update"
      ) {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      date: "2026-02-22",
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(
      snapshot.insights.map((row) => row.type),
      [
        "daily/2026-02-22/recovery_status",
        "daily/2026-02-22/sleep_debt",
        "daily/2026-02-22/nutrition_gap",
        "daily/2026-02-22/training_load",
      ],
    );
    assertEquals(
      snapshot.recommendations.map((row) => row.trigger_condition),
      [
        "daily/2026-02-22/recovery_rest",
        "daily/2026-02-22/sleep_extension",
        "daily/2026-02-22/protein_anchor",
      ],
    );
    assertEquals(snapshot.recommendations[0].time_of_day, "evening");

    const insightUpdates = service.__calls.filter((state) =>
      state.table === "insights" && state.action === "update"
    );
    assertEquals(insightUpdates.length, 2);
    assertEquals(
      insightUpdates.some((state) =>
        JSON.stringify(filterValue(state, "in", "id")) ===
          JSON.stringify(["stale-insight"])
      ),
      true,
    );
    assertEquals(
      insightUpdates.some((state) =>
        JSON.stringify(filterValue(state, "in", "id")) ===
          JSON.stringify(["old-insight"])
      ),
      true,
    );

    const recommendationUpdates = service.__calls.filter((state) =>
      state.table === "recommendations" && state.action === "update"
    );
    assertEquals(recommendationUpdates.length, 2);
    assertEquals(
      recommendationUpdates.some((state) =>
        JSON.stringify(filterValue(state, "in", "id")) ===
          JSON.stringify(["stale-recommendation"])
      ),
      true,
    );
    assertEquals(
      recommendationUpdates.some((state) =>
        filterValue(state, "lt", "recommendation_date") === "2026-02-22"
      ),
      true,
    );
  });
});

Deno.test("daily insights surface fetch failures with stable error prefixes", async () => {
  const service = createMockSupabaseService((state) => {
    if (state.table === "users" && state.terminal === "maybeSingle") {
      return {
        data: null,
        error: { message: "boom" },
      };
    }

    if (
      ["physiological_states", "food_logs", "workout_sessions"].includes(
        state.table,
      ) && state.terminal === "returns"
    ) {
      return { data: [], error: null };
    }

    if (
      state.table === "daily_nutrition_targets" &&
      state.terminal === "maybeSingle"
    ) {
      return { data: null, error: null };
    }

    throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
  });

  await assertRejects(
    () =>
      generateAndPersistDailyInsights({
        date: "2026-02-22",
        service: service as never,
        timezone: "UTC",
        userId: USER_ID,
      }),
    Error,
    "user_fetch_failed:boom",
  );
});

Deno.test("daily insights tolerate null query payloads and still persist a sparse snapshot", async () => {
  await withMockedDate("2026-02-22T08:00:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: null, error: null };
      }

      if (
        ["physiological_states", "food_logs", "workout_sessions"].includes(
          state.table,
        ) && state.terminal === "returns"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      date: "2026-02-22",
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(snapshot.insights.length, 1);
    assertEquals(snapshot.recommendations.length, 1);
    assertEquals(snapshot.insights[0].type, "daily/2026-02-22/setup_prompt");
  });
});

Deno.test("daily insights preserve user interaction fields when steady-day rows are regenerated", async () => {
  await withMockedDate("2026-02-23T13:00:00.000Z", async () => {
    const insightId = await stableManagedId(
      "insight",
      "daily/2026-02-23/recovery_status",
    );
    const recommendationId = await stableManagedId(
      "recommendation",
      "daily/2026-02-23/steady_day",
    );

    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: 8 }, error: null };
      }

      if (
        state.table === "physiological_states" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            {
              date: "2026-02-21",
              recovery_score: 70,
              recovery_zone: "ready",
              sleep_duration_hours: 7.8,
              allostatic_load: 2,
              confidence_score: 0.82,
            },
            {
              date: "2026-02-22",
              recovery_score: 71,
              recovery_zone: "ready",
              sleep_duration_hours: 7.9,
              allostatic_load: 2,
              confidence_score: 0.82,
            },
            {
              date: "2026-02-23",
              recovery_score: 82,
              recovery_zone: "ready",
              sleep_duration_hours: 8,
              allostatic_load: 2,
              confidence_score: 0.8,
            },
          ],
          error: null,
        };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["food_logs", "workout_sessions"].includes(state.table) &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        state.table === "insights" &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        const typeLike = filterValue(state, "like", "type");
        if (typeLike === "daily/2026-02-23/%") {
          return {
            data: [
              makeExistingInsight({
                id: insightId,
                type: "daily/2026-02-23/recovery_status",
                shown_to_user: true,
                shown_at: "2026-02-23T12:00:00.000Z",
                read: true,
                read_at: "2026-02-23T12:15:00.000Z",
                acknowledged: true,
                acknowledged_at: "2026-02-23T12:20:00.000Z",
                acted_upon: true,
                action_taken: "kept day easy",
              }),
            ],
            error: null,
          };
        }

        if (typeLike === "daily/%") {
          return { data: [], error: null };
        }
      }

      if (
        state.table === "recommendations" &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            makeExistingRecommendation({
              id: recommendationId,
              recommendation_date: "2026-02-23",
              trigger_condition: "daily/2026-02-23/steady_day",
              followed: true,
              user_feedback: "helpful",
            }),
          ],
          error: null,
        };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      date: "2026-02-23",
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(snapshot.insights.length, 1);
    assertEquals(snapshot.insights[0].id, insightId);
    assertEquals(snapshot.insights[0].created_at, "2026-02-20T10:00:00.000Z");
    assertEquals(snapshot.insights[0].shown_to_user, true);
    assertEquals(snapshot.insights[0].read, true);
    assertEquals(snapshot.insights[0].acknowledged, true);
    assertEquals(snapshot.insights[0].acted_upon, true);
    assertStringIncludes(
      snapshot.insights[0].body,
      "about 12 points above your recent range",
    );

    assertEquals(snapshot.recommendations.length, 1);
    assertEquals(snapshot.recommendations[0].id, recommendationId);
    assertEquals(
      snapshot.recommendations[0].trigger_condition,
      "daily/2026-02-23/steady_day",
    );
    assertEquals(snapshot.recommendations[0].title, "Keep today's plan steady");
    assertEquals(snapshot.recommendations[0].time_of_day, "midday");
    assertEquals(snapshot.recommendations[0].followed, true);
    assertEquals(snapshot.recommendations[0].user_feedback, "helpful");
  });
});

Deno.test("daily insights use the current local date and emit a critical night restoration recommendation for very low recovery", async () => {
  await withMockedDate("2026-02-24T23:30:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: 8 }, error: null };
      }

      if (
        state.table === "physiological_states" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            {
              date: "2026-02-22",
              recovery_score: 50,
              recovery_zone: "ready",
              sleep_duration_hours: 7.9,
              allostatic_load: 2,
              confidence_score: 0.82,
            },
            {
              date: "2026-02-23",
              recovery_score: 48,
              recovery_zone: "ready",
              sleep_duration_hours: 7.8,
              allostatic_load: 2,
              confidence_score: 0.82,
            },
            {
              date: "2026-02-24",
              recovery_score: 20,
              recovery_zone: "strained_state",
              sleep_duration_hours: 8,
              allostatic_load: 5,
              confidence_score: 0.91,
            },
          ],
          error: null,
        };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["food_logs", "workout_sessions"].includes(state.table) &&
        state.terminal === "returns"
      ) {
        return { data: null, error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(snapshot.date, "2026-02-24");
    assertEquals(
      snapshot.insights[0].title,
      "Recovery is below your recent range",
    );
    assertStringIncludes(snapshot.insights[0].body, "Strained state zone");
    assertEquals(snapshot.recommendations[0].priority, "critical");
    assertEquals(
      snapshot.recommendations[0].title,
      "Make today a restoration day",
    );
    assertEquals(snapshot.recommendations[0].time_of_day, "night");
  });
});

Deno.test("daily insights only push a modest protein shortfall after mid-afternoon", async () => {
  const cases = [
    {
      now: "2026-02-25T14:00:00.000Z",
      expectProtein: false,
      expectedTimeOfDay: "afternoon",
    },
    {
      now: "2026-02-25T16:00:00.000Z",
      expectProtein: true,
      expectedTimeOfDay: "afternoon",
    },
  ] as const;

  for (const testCase of cases) {
    await withMockedDate(testCase.now, async () => {
      const service = createMockSupabaseService((state) => {
        if (state.table === "users" && state.terminal === "maybeSingle") {
          return { data: { baseline_sleep_hours: 8 }, error: null };
        }

        if (
          state.table === "physiological_states" &&
          state.terminal === "returns"
        ) {
          return {
            data: [
              {
                date: "2026-02-23",
                recovery_score: 71,
                recovery_zone: "ready",
                sleep_duration_hours: 7.9,
                allostatic_load: 2,
                confidence_score: 0.82,
              },
              {
                date: "2026-02-24",
                recovery_score: 70,
                recovery_zone: "ready",
                sleep_duration_hours: 7.8,
                allostatic_load: 2,
                confidence_score: 0.82,
              },
              {
                date: "2026-02-25",
                recovery_score: 72,
                recovery_zone: "ready",
                sleep_duration_hours: 8,
                allostatic_load: 2,
                confidence_score: 0.9,
              },
            ],
            error: null,
          };
        }

        if (
          state.table === "daily_nutrition_targets" &&
          state.terminal === "maybeSingle"
        ) {
          return {
            data: { final_calories: 2200, final_protein_g: 100 },
            error: null,
          };
        }

        if (state.table === "food_logs" && state.terminal === "returns") {
          return {
            data: [{ calories: 750, protein_g: 82 }],
            error: null,
          };
        }

        if (
          state.table === "workout_sessions" && state.terminal === "returns"
        ) {
          return { data: [], error: null };
        }

        if (
          ["insights", "recommendations"].includes(state.table) &&
          state.action === "select" &&
          state.terminal === "returns"
        ) {
          return { data: [], error: null };
        }

        if (
          ["insights", "recommendations"].includes(state.table) &&
          state.action === "upsert" &&
          state.terminal === "returns"
        ) {
          return { data: state.payload, error: null };
        }

        if (state.action === "update") {
          return { data: null, error: null };
        }

        throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
      });

      const snapshot = await generateAndPersistDailyInsights({
        date: "2026-02-25",
        service: service as never,
        timezone: "UTC",
        userId: USER_ID,
      });

      const hasProteinInsight = snapshot.insights.some((row) =>
        row.type === "daily/2026-02-25/nutrition_gap"
      );
      const hasProteinRecommendation = snapshot.recommendations.some((row) =>
        row.trigger_condition === "daily/2026-02-25/protein_anchor"
      );

      assertEquals(hasProteinInsight, testCase.expectProtein);
      assertEquals(hasProteinRecommendation, testCase.expectProtein);
      assertEquals(
        snapshot.recommendations[0].time_of_day,
        testCase.expectedTimeOfDay,
      );

      if (testCase.expectProtein) {
        const proteinRecommendation = snapshot.recommendations.find((row) =>
          row.trigger_condition === "daily/2026-02-25/protein_anchor"
        );
        assertEquals(proteinRecommendation?.priority, "medium");
      } else {
        assertEquals(
          snapshot.recommendations[0].trigger_condition,
          "daily/2026-02-25/steady_day",
        );
        assertEquals(
          snapshot.recommendations[0].title,
          "Keep today's plan steady",
        );
      }
    });
  }
});

Deno.test("daily insights surface persistence failures with stable error prefixes", async () => {
  function createPersistenceService(
    failAt?: (state: MockQueryState) => boolean,
  ) {
    return createMockSupabaseService((state) => {
      if (failAt?.(state)) {
        return { data: null, error: { message: "boom" } };
      }

      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: null }, error: null };
      }

      if (
        ["physiological_states", "food_logs", "workout_sessions"].includes(
          state.table,
        ) && state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        state.table === "insights" &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        const typeLike = filterValue(state, "like", "type");
        if (typeLike === "daily/2026-02-26/%") {
          return {
            data: [
              makeExistingInsight({
                id: "stale-insight",
                type: "daily/2026-02-26/unused",
              }),
            ],
            error: null,
          };
        }

        if (typeLike === "daily/%") {
          return {
            data: [
              makeExistingInsight({
                id: "old-insight",
                type: "daily/2026-02-25/recovery_status",
                dismissed: false,
              }),
            ],
            error: null,
          };
        }
      }

      if (
        state.table === "recommendations" &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            makeExistingRecommendation({
              id: "stale-recommendation",
              recommendation_date: "2026-02-26",
              trigger_condition: "daily/2026-02-26/unused",
            }),
          ],
          error: null,
        };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });
  }

  const cases = [
    {
      expected: "insights_existing_fetch_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "insights" &&
        state.action === "select" &&
        state.terminal === "returns" &&
        filterValue(state, "like", "type") === "daily/2026-02-26/%",
    },
    {
      expected: "recommendations_existing_fetch_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "recommendations" &&
        state.action === "select" &&
        state.terminal === "returns",
    },
    {
      expected: "insights_upsert_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "insights" &&
        state.action === "upsert" &&
        state.terminal === "returns",
    },
    {
      expected: "recommendations_upsert_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "recommendations" &&
        state.action === "upsert" &&
        state.terminal === "returns",
    },
    {
      expected: "insights_stale_dismiss_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "insights" &&
        state.action === "update" &&
        JSON.stringify(filterValue(state, "in", "id")) ===
          JSON.stringify(["stale-insight"]),
    },
    {
      expected: "insights_old_cleanup_fetch_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "insights" &&
        state.action === "select" &&
        state.terminal === "returns" &&
        filterValue(state, "like", "type") === "daily/%",
    },
    {
      expected: "insights_old_cleanup_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "insights" &&
        state.action === "update" &&
        JSON.stringify(filterValue(state, "in", "id")) ===
          JSON.stringify(["old-insight"]),
    },
    {
      expected: "recommendations_stale_dismiss_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "recommendations" &&
        state.action === "update" &&
        JSON.stringify(filterValue(state, "in", "id")) ===
          JSON.stringify(["stale-recommendation"]),
    },
    {
      expected: "recommendations_old_cleanup_failed:boom",
      match: (state: MockQueryState) =>
        state.table === "recommendations" &&
        state.action === "update" &&
        filterValue(state, "lt", "recommendation_date") === "2026-02-26",
    },
  ] as const;

  for (const testCase of cases) {
    const service = createPersistenceService(testCase.match);
    await assertRejects(
      () =>
        generateAndPersistDailyInsights({
          date: "2026-02-26",
          service: service as never,
          timezone: "UTC",
          userId: USER_ID,
        }),
      Error,
      testCase.expected,
    );
  }
});

Deno.test("daily insights clamp high recovery confidence and fall back to steady guidance without prior history", async () => {
  await withMockedDate("2026-02-27T09:00:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: null }, error: null };
      }

      if (
        state.table === "physiological_states" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            {
              date: "2026-02-27",
              recovery_score: 78,
              recovery_zone: "ready",
              sleep_duration_hours: 7.9,
              allostatic_load: 2,
              confidence_score: 1.4,
            },
          ],
          error: null,
        };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["food_logs", "workout_sessions"].includes(state.table) &&
        state.terminal === "returns"
      ) {
        return { data: null, error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      date: "2026-02-27",
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(snapshot.insights.length, 1);
    assertEquals(snapshot.insights[0].confidence, 0.95);
    assertEquals(
      snapshot.insights[0].body,
      "Today's recovery score is 78, which supports a normal training and work rhythm today.",
    );
    assertEquals(snapshot.recommendations[0].title, "Keep today's plan steady");
    assertEquals(snapshot.recommendations[0].time_of_day, "morning");
  });
});

Deno.test("daily insights issue a medium sleep-extension recommendation for a modest sleep deficit", async () => {
  await withMockedDate("2026-02-28T10:00:00.000Z", async () => {
    const service = createMockSupabaseService((state) => {
      if (state.table === "users" && state.terminal === "maybeSingle") {
        return { data: { baseline_sleep_hours: 8 }, error: null };
      }

      if (
        state.table === "physiological_states" &&
        state.terminal === "returns"
      ) {
        return {
          data: [
            {
              date: "2026-02-26",
              recovery_score: 61,
              recovery_zone: "ready",
              sleep_duration_hours: 7.8,
              allostatic_load: 2,
              confidence_score: 0.8,
            },
            {
              date: "2026-02-27",
              recovery_score: 60,
              recovery_zone: "ready",
              sleep_duration_hours: 8.0,
              allostatic_load: 2,
              confidence_score: 0.8,
            },
            {
              date: "2026-02-28",
              recovery_score: 62,
              recovery_zone: "ready",
              sleep_duration_hours: 7.1,
              allostatic_load: 2,
              confidence_score: 0.82,
            },
          ],
          error: null,
        };
      }

      if (
        state.table === "daily_nutrition_targets" &&
        state.terminal === "maybeSingle"
      ) {
        return { data: null, error: null };
      }

      if (
        ["food_logs", "workout_sessions"].includes(state.table) &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "select" &&
        state.terminal === "returns"
      ) {
        return { data: [], error: null };
      }

      if (
        ["insights", "recommendations"].includes(state.table) &&
        state.action === "upsert" &&
        state.terminal === "returns"
      ) {
        return { data: state.payload, error: null };
      }

      if (state.action === "update") {
        return { data: null, error: null };
      }

      throw new Error(`Unhandled mock query: ${JSON.stringify(state)}`);
    });

    const snapshot = await generateAndPersistDailyInsights({
      date: "2026-02-28",
      service: service as never,
      timezone: "UTC",
      userId: USER_ID,
    });

    assertEquals(
      snapshot.insights.map((row) => row.type),
      [
        "daily/2026-02-28/sleep_debt",
        "daily/2026-02-28/recovery_status",
      ],
    );
    assertEquals(snapshot.recommendations.length, 1);
    assertEquals(
      snapshot.recommendations[0].trigger_condition,
      "daily/2026-02-28/sleep_extension",
    );
    assertEquals(snapshot.recommendations[0].priority, "medium");
    assertStringIncludes(
      snapshot.recommendations[0].description,
      "54 minutes of extra sleep",
    );
  });
});
