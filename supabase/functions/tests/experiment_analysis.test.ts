import {
  assert,
  assertAlmostEquals,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  analyzeExperiment,
  type ExperimentSample,
} from "../api/experiments/analysis.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

function samples(
  baseline: number[],
  intervention: number[],
  metric = "sleep_quality",
): ExperimentSample[] {
  return [
    ...baseline.map((value, index) => ({
      measurement_date: `2024-01-0${index + 1}`,
      measurement_phase: "baseline",
      metric_name: metric,
      metric_value: value,
      metric_unit: null,
      protocol_followed: true,
    })),
    ...intervention.map((value, index) => ({
      measurement_date: `2024-01-1${index + 1}`,
      measurement_phase: "intervention",
      metric_name: metric,
      metric_value: value,
      metric_unit: null,
      protocol_followed: true,
    })),
  ];
}

Deno.test("experiment analysis compares phase means, not first and last endpoints", () => {
  const result = analyzeExperiment(
    "sleep_quality",
    samples([1, 100], [100, 2]),
  );
  assertEquals(result.baseline_mean, 50.5);
  assertEquals(result.intervention_mean, 51);
  assertEquals(result.effect_direction, null);
  assertEquals(result.effect_size, null);
  assertEquals(result.p_value, null);
  assertEquals(result.significant, null);
  assertStringIncludes(result.ai_interpretation, "Insufficient data");
});

Deno.test("experiment analysis excludes other metrics, washout, and protocol violations", () => {
  const rows = samples([1, 2, 3], [3, 4, 5]);
  rows.push({ ...rows[0], metric_name: "weight", metric_value: 10000 });
  rows.push({ ...rows[0], measurement_phase: "washout", metric_value: 20000 });
  rows.push({ ...rows[0], protocol_followed: false, metric_value: 30000 });
  const result = analyzeExperiment("sleep_quality", rows);
  assertEquals(result.baseline_mean, 2);
  assertEquals(result.intervention_mean, 4);
  assertEquals(result.baseline_std_dev, 1);
  assertEquals(result.intervention_std_dev, 1);
  assertEquals(result.effect_size, 2);
  assertEquals(result.effect_direction, "positive");
  assertAlmostEquals(result.compliance_percent!, 6 / 7 * 100);
  assertStringIncludes(
    result.ai_interpretation,
    "does not establish causation",
  );
});

Deno.test("increasing stress is adverse, decreasing stress favorable, unknown direction stays unknown", () => {
  assertEquals(
    analyzeExperiment("stress", samples([1, 2, 3], [3, 4, 5], "stress"))
      .effect_direction,
    "negative",
  );
  assertEquals(
    analyzeExperiment("stress", samples([3, 4, 5], [1, 2, 3], "stress"))
      .effect_direction,
    "positive",
  );
  assertEquals(
    analyzeExperiment("weight", samples([1, 2, 3], [3, 4, 5], "weight"))
      .effect_direction,
    null,
  );
});

Deno.test("mixed units and missing or constant samples cannot yield fabricated significance", () => {
  const rows = samples([1, 2, 3], [3, 4, 5]);
  rows[0].metric_unit = "hours";
  rows[3].metric_unit = "minutes";
  const mixed = analyzeExperiment("sleep_quality", rows);
  assertEquals(mixed.baseline_mean, null);
  assertEquals(mixed.effect_direction, null);
  assertStringIncludes(mixed.ai_interpretation, "Units differ");
  const constant = analyzeExperiment(
    "sleep_quality",
    samples([2, 2, 2], [2, 2, 2]),
  );
  assertEquals(constant.effect_size, null);
  assertEquals(constant.effect_direction, "neutral");
  assertEquals(constant.confidence_interval_lower, null);
  assertEquals(analyzeExperiment("sleep_quality", []).baseline_mean, null);
});

const USER = "11111111-1111-4111-8111-111111111111";
const EXPERIMENT = "22222222-2222-4222-8222-222222222222";
const historical = {
  id: EXPERIMENT,
  user_id: USER,
  title: "Stress",
  status: "baseline",
  primary_metric: "stress",
  secondary_metrics: ["sleep_quality"],
  baseline_start_date: "2024-01-01",
  baseline_end_date: "2024-01-07",
  intervention_start_date: "2024-01-11",
  intervention_end_date: "2024-01-17",
  washout_start_date: null,
  washout_end_date: null,
};

Deno.test("experiment mutations reject JSON null and arrays without throwing", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  await withMockedEdgeRuntime(
    { publicUser: { id: USER, timezone: "UTC" } },
    async () => {
      for (const path of ["/create", `/${EXPERIMENT}/log`]) {
        for (const body of [null, []]) {
          const response = await handler(request(path, body));
          assertEquals(response.status, 400);
          assertEquals((await response.json()).error, "invalid_payload");
        }
      }
    },
  );
});
function request(path: string, body?: unknown) {
  return new Request(`http://localhost/functions/v1/api-experiments${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: {
      Authorization: "Bearer test",
      "Content-Type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

Deno.test("completed experiment handler persists real phase analysis and never queries another user", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  const rows = samples([1, 2, 3], [3, 4, 5], "stress");
  let persisted: Record<string, unknown> | null = null;
  await withMockedEdgeRuntime({
    publicUser: { id: USER, timezone: "UTC" },
    responders: [
      (req, { url, bodyText }) => {
        if (
          !["/rest/v1/experiments", "/rest/v1/experiment_measurements"]
            .includes(url.pathname)
        ) return undefined;
        assertEquals(url.searchParams.get("user_id"), `eq.${USER}`);
        if (url.pathname.endsWith("experiment_measurements")) {
          assertEquals(
            url.searchParams.get("experiment_id"),
            `eq.${EXPERIMENT}`,
          );
          assertEquals(url.searchParams.get("metric_name"), "eq.stress");
          return jsonResponse(rows);
        }
        if (req.method === "PATCH") {
          persisted = JSON.parse(bodyText);
          return new Response(null, { status: 204 });
        }
        return jsonResponse([historical]);
      },
    ],
  }, async () => {
    const response = await handler(request(""));
    assertEquals(response.status, 200);
    const data = await response.json();
    assertEquals(data.experiments[0].status, "completed");
    assertEquals(data.experiments[0].baseline_mean, 2);
    assertEquals(data.experiments[0].intervention_mean, 4);
  });
  assert(persisted);
  assertEquals(
    (persisted as Record<string, unknown>).effect_direction,
    "negative",
  );
});

Deno.test("experiment create and replay truthfully report unsupported reminders", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  for (const replay of [false, true]) {
    await withMockedEdgeRuntime({
      publicUser: { id: USER, timezone: "UTC" },
      responders: [
        (req, { url }) => {
          if (url.pathname === "/rest/v1/experiments") {
            if (
              req.method === "POST" || req.method === "PATCH"
            ) return new Response(null, { status: 204 });
            return jsonResponse(
              replay && url.searchParams.has("id")
                ? [{ ...historical, status: "abandoned" }]
                : [],
            );
          }
          return undefined;
        },
      ],
    }, async () => {
      const response = await handler(
        request("/create", {
          id: EXPERIMENT,
          title: "Test",
          hypothesis: "Hypothesis",
          variable: "Routine",
          primary_metric: "stress",
          reminder_time: "08:00",
        }),
      );
      assertEquals(response.status, replay ? 202 : 200);
      const body = await response.json();
      assertEquals(body.reminders_scheduled, false);
      assertEquals(body.reminder_status, "unsupported");
    });
  }
});

Deno.test("delayed experiment creation preserves baseline and accepts already collected measurements", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  let stored: Record<string, unknown> | null = null;
  let measurements: Record<string, unknown>[] = [];
  await withMockedEdgeRuntime({
    publicUser: { id: USER, timezone: "UTC" },
    responders: [(req, { url, bodyText }) => {
      if (url.pathname === "/rest/v1/experiments") {
        if (req.method === "POST") {
          stored = JSON.parse(bodyText);
          return new Response(null, { status: 201 });
        }
        if (req.method === "PATCH") return new Response(null, { status: 204 });
        return jsonResponse(stored ? [stored] : []);
      }
      if (url.pathname === "/rest/v1/experiment_measurements") {
        if (req.method === "POST") {
          measurements = JSON.parse(bodyText);
          return new Response(null, { status: 201 });
        }
        return jsonResponse(measurements);
      }
      return undefined;
    }],
  }, async () => {
    const create = {
      id: EXPERIMENT,
      title: "Offline start",
      hypothesis: "Routine may help",
      variable: "Routine",
      primary_metric: "stress",
      baseline_start_date: "2024-01-01",
      baseline_duration_days: 3,
      intervention_duration_days: 3,
    };
    const response = await handler(request("/create", create));
    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.baseline_start_date, "2024-01-01");
    assertEquals(body.intervention_start_date, "2024-01-04");
    const logged = await handler(
      request(`/${EXPERIMENT}/log`, {
        date: "2024-01-01",
        measurements: { stress: 4 },
      }),
    );
    assertEquals(logged.status, 200);
    assertEquals(measurements[0].measurement_date, "2024-01-01");
    assertEquals(measurements[0].measurement_phase, "baseline");
    const replay = await handler(request("/create", create));
    assertEquals(replay.status, 202);
    assertEquals((await replay.json()).baseline_start_date, "2024-01-01");
  });
});

Deno.test("experiment create rejects invalid or future baseline anchors", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  await withMockedEdgeRuntime(
    { publicUser: { id: USER, timezone: "UTC" } },
    async () => {
      for (
        const baseline_start_date of [
          "2024-02-30",
          "9999-01-01",
          "invalid",
          123,
          null,
        ]
      ) {
        const response = await handler(
          request("/create", {
            id: EXPERIMENT,
            title: "Test",
            hypothesis: "Hypothesis",
            variable: "Routine",
            primary_metric: "stress",
            baseline_start_date,
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(
          (await response.json()).error,
          "invalid_baseline_start_date",
        );
      }
    },
  );
});

Deno.test("experiment log rejects invalid/unplanned metrics and writes all valid metrics atomically", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  let writes = 0;
  let payload: unknown = null;
  await withMockedEdgeRuntime({
    publicUser: { id: USER, timezone: "UTC" },
    responders: [
      (req, { url, bodyText }) => {
        if (url.pathname === "/rest/v1/experiments") {
          if (req.method === "PATCH") {
            return new Response(null, { status: 204 });
          }
          return jsonResponse([historical]);
        }
        if (url.pathname === "/rest/v1/experiment_measurements") {
          if (req.method === "POST") {
            writes++;
            payload = JSON.parse(bodyText);
            return new Response(null, { status: 201 });
          }
          return jsonResponse([]);
        }
        return undefined;
      },
    ],
  }, async () => {
    for (
      const measurements of [{ stress: "invalid" }, { unrelated: 5 }, {
        stress: 4,
        sleep_quality: "bad",
      }]
    ) {
      const response = await handler(
        request(`/${EXPERIMENT}/log`, { date: "2024-01-12", measurements }),
      );
      assertEquals(response.status, 400);
    }
    assertEquals(writes, 0);
    const response = await handler(
      request(`/${EXPERIMENT}/log`, {
        date: "2024-01-12",
        measurements: { stress: 4, sleep_quality: 8 },
      }),
    );
    assertEquals(response.status, 200);
    assertEquals(writes, 1);
    assert(Array.isArray(payload));
    assertEquals(payload.length, 2);
    assertEquals(payload[0].measurement_phase, "intervention");
    assertEquals(payload[0].user_id, USER);
  });
});

Deno.test("historical corrections recompute analysis even after status is already completed", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  let rows = samples([1, 2, 3], [3, 4, 5], "stress");
  let saved: Record<string, unknown> = {};
  await withMockedEdgeRuntime({
    publicUser: { id: USER, timezone: "UTC" },
    responders: [
      (req, { url, bodyText }) => {
        if (url.pathname === "/rest/v1/experiments") {
          if (req.method === "PATCH") {
            saved = JSON.parse(bodyText);
            return new Response(null, { status: 204 });
          }
          return jsonResponse([{ ...historical, status: "completed" }]);
        }
        if (url.pathname === "/rest/v1/experiment_measurements") {
          if (req.method === "POST") {
            const updates = JSON.parse(bodyText) as ExperimentSample[];
            for (const update of updates) {
              rows = rows.map((row) =>
                row.measurement_date === update.measurement_date &&
                  row.metric_name === update.metric_name
                  ? update
                  : row
              );
            }
            return new Response(null, { status: 201 });
          }
          return jsonResponse(rows);
        }
        return undefined;
      },
    ],
  }, async () => {
    const response = await handler(
      request(`/${EXPERIMENT}/log`, {
        date: "2024-01-11",
        measurements: { stress: 9 },
      }),
    );
    assertEquals(response.status, 200);
    assertEquals((await response.json()).experiment_status, "completed");
    assertEquals(saved.baseline_mean, 2);
    assertEquals(saved.intervention_mean, 6);
  });
});

Deno.test("stop is scoped and idempotent and stopped runs reject new logs", async () => {
  const handler = await captureEdgeHandler("../api/experiments/index.ts");
  let status = "baseline";
  await withMockedEdgeRuntime({
    publicUser: { id: USER, timezone: "UTC" },
    responders: [
      (req, { url, bodyText }) => {
        if (url.pathname !== "/rest/v1/experiments") return undefined;
        assertEquals(url.searchParams.get("user_id"), `eq.${USER}`);
        assertEquals(url.searchParams.get("id"), `eq.${EXPERIMENT}`);
        if (req.method === "PATCH") {
          assertEquals(JSON.parse(bodyText), { status: "abandoned" });
          if (status === "abandoned") return jsonResponse([]);
          status = "abandoned";
          return jsonResponse([{ id: EXPERIMENT }]);
        }
        return jsonResponse([{ ...historical, status }]);
      },
    ],
  }, async () => {
    assertEquals(
      (await handler(request(`/${EXPERIMENT}/stop`, {}))).status,
      200,
    );
    assertEquals(
      (await handler(request(`/${EXPERIMENT}/stop`, {}))).status,
      200,
    );
    const log = await handler(
      request(`/${EXPERIMENT}/log`, {
        date: "2024-01-11",
        measurements: { stress: 4 },
      }),
    );
    assertEquals(log.status, 409);
    assertEquals((await log.json()).error, "experiment_abandoned");
  });
});
