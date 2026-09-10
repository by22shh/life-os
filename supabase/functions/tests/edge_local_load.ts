type JsonValue = null | boolean | number | string | JsonValue[] | {
  [key: string]: JsonValue;
};

interface HttpResponse {
  status: number;
  body: JsonValue | string | null;
  headers: Headers;
}

interface AuthSession {
  accessToken: string;
  authUserId: string;
  email: string;
}

interface EnvConfig {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
}

interface LoadConfig {
  concurrency: number;
  foodRequests: number;
  settingsRequests: number;
  foodP95Ms: number;
  settingsP95Ms: number;
  maxErrorRate: number;
  warmupRequests: number;
  soakDurationSeconds: number;
  soakRequestIntervalMs: number;
  reportPath?: string;
}

interface LatencySummary {
  requests: number;
  concurrency: number;
  p50Ms: number;
  p95Ms: number;
  p99Ms: number;
  avgMs: number;
  maxMs: number;
  minMs: number;
  errorRate: number;
  statusCounts: Record<string, number>;
  errorCounts: Record<string, number>;
  totalDurationMs: number;
  throughputRps: number;
}

interface Sample {
  latencyMs: number;
  status: number;
  ok: boolean;
  errorCode?: string;
}

const LOCAL_FUNCTION_URL = "http://127.0.0.1:8000";
const REPO_ROOT = new URL("../../../", import.meta.url);

const env = loadEnv();
const config = loadConfig();
const auth = await createAuthSession(env);
await waitForPublicUser(env, auth.authUserId, auth.email);

const report: Record<string, LatencySummary> = {};

await runFunctionScenario(
  "api-food-log",
  "../api/food/log/index.ts",
  async () => {
    const summary = await runConfiguredProfile({
      name: "api-food-log",
      totalRequests: config.foodRequests,
      concurrency: config.concurrency,
      warmupRequests: config.warmupRequests,
      expectedStatuses: new Set([202]),
      soakDurationSeconds: config.soakDurationSeconds,
      soakRequestIntervalMs: config.soakRequestIntervalMs,
      requestFactory: (index) => {
        const sampleIndex = index < 0 ? Math.abs(index) : index;
        const requestId = crypto.randomUUID();
        return requestJson(
          LOCAL_FUNCTION_URL,
          "/",
          {
            method: "POST",
            headers: {
              ...jsonAuthHeaders(auth.accessToken),
              "Idempotency-Key": requestId,
              "X-Outbox-Replay": "true",
            },
            body: JSON.stringify({
              id: requestId,
              logged_at: new Date().toISOString(),
              logged_date: "2026-02-22",
              input_method: "manual",
              calories: 320 + (sampleIndex % 200),
              protein_g: 20 + (sampleIndex % 50),
              fat_g: 10 + (sampleIndex % 30),
              carbs_g: 35 + (sampleIndex % 80),
              context: sampleIndex % 2 === 0 ? "home" : "work",
              meal_type: sampleIndex % 2 === 0 ? "lunch" : "dinner",
            }),
          },
        );
      },
    });

    report["api-food-log"] = summary;
    await persistReport();
    enforceThresholds(
      "api-food-log",
      summary,
      config.foodP95Ms,
      config.maxErrorRate,
    );
  },
);

await runFunctionScenario(
  "api-settings-notifications",
  "../api/settings/notifications/index.ts",
  async () => {
    const summary = await runConfiguredProfile({
      name: "api-settings-notifications",
      totalRequests: config.settingsRequests,
      concurrency: config.concurrency,
      warmupRequests: config.warmupRequests,
      expectedStatuses: new Set([200]),
      soakDurationSeconds: config.soakDurationSeconds,
      soakRequestIntervalMs: config.soakRequestIntervalMs,
      requestFactory: (index) => {
        const sampleIndex = index < 0 ? Math.abs(index) : index;
        const criticalOnly = sampleIndex % 5 === 0;
        const controlLevel = criticalOnly
          ? "guardian"
          : (sampleIndex % 3 === 0
            ? "guardian"
            : (sampleIndex % 2 === 0 ? "protective" : "advisory"));
        const focusControlEnabled = criticalOnly
          ? true
          : controlLevel === "guardian";

        return requestJson(
          LOCAL_FUNCTION_URL,
          "/",
          {
            method: "PATCH",
            headers: jsonAuthHeaders(auth.accessToken),
            body: JSON.stringify({
              critical_only: criticalOnly,
              control_level: controlLevel,
              focus_control_enabled: focusControlEnabled,
              max_total_per_day: 6,
              max_nudges_per_day: sampleIndex % 3,
              max_positive_per_day: sampleIndex % 4,
              max_celebration_per_day: sampleIndex % 3,
            }),
          },
        );
      },
    });

    report["api-settings-notifications"] = summary;
    await persistReport();
    enforceThresholds(
      "api-settings-notifications",
      summary,
      config.settingsP95Ms,
      config.maxErrorRate,
    );
  },
);

await persistReport();

console.log("Edge local load test suite completed.");

async function persistReport(): Promise<void> {
  if (config.reportPath) {
    await Deno.writeTextFile(
      config.reportPath,
      JSON.stringify(report, null, 2),
    );
  }
}

function failureCode(response: HttpResponse): string {
  // Record only a machine-readable code, never response bodies, tokens or PII.
  const code = objectString(response.body, "error");
  return code && /^[a-zA-Z0-9_.-]{1,80}$/.test(code)
    ? code
    : `http_${response.status}`;
}

function loadEnv(): EnvConfig {
  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim() ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() ??
    "";

  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    throw new Error(
      "Missing SUPABASE_URL, SUPABASE_ANON_KEY, or SUPABASE_SERVICE_ROLE_KEY.",
    );
  }

  return { supabaseUrl, anonKey, serviceRoleKey };
}

function loadConfig(): LoadConfig {
  return {
    concurrency: intFromEnv("EDGE_LOAD_CONCURRENCY", 16),
    foodRequests: intFromEnv("EDGE_LOAD_FOOD_REQUESTS", 120),
    settingsRequests: intFromEnv("EDGE_LOAD_SETTINGS_REQUESTS", 90),
    warmupRequests: intFromEnv("EDGE_LOAD_WARMUP_REQUESTS", 10),
    foodP95Ms: intFromEnv("EDGE_LOAD_FOOD_P95_MS", 1200),
    settingsP95Ms: intFromEnv("EDGE_LOAD_SETTINGS_P95_MS", 800),
    maxErrorRate: floatFromEnv("EDGE_LOAD_MAX_ERROR_RATE", 0.0),
    soakDurationSeconds: intFromEnv(
      "EDGE_LOAD_SOAK_DURATION_SECONDS",
      0,
      { allowZero: true },
    ),
    soakRequestIntervalMs: intFromEnv(
      "EDGE_LOAD_SOAK_REQUEST_INTERVAL_MS",
      0,
      { allowZero: true },
    ),
    reportPath: Deno.env.get("EDGE_LOAD_REPORT_PATH")?.trim() || undefined,
  };
}

function intFromEnv(
  key: string,
  fallback: number,
  options: { allowZero?: boolean } = {},
): number {
  const { allowZero = false } = options;
  const raw = Deno.env.get(key);
  if (!raw) return fallback;
  const value = Number.parseInt(raw, 10);
  const min = allowZero ? 0 : 1;
  if (!Number.isFinite(value) || value < min) {
    throw new Error(`${key} must be an integer >= ${min}, got: ${raw}`);
  }
  return value;
}

function floatFromEnv(key: string, fallback: number): number {
  const raw = Deno.env.get(key);
  if (!raw) return fallback;
  const value = Number.parseFloat(raw);
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new Error(`${key} must be within [0, 1], got: ${raw}`);
  }
  return value;
}

async function createAuthSession(env: EnvConfig): Promise<AuthSession> {
  const email = `edge-load-${crypto.randomUUID()}@example.com`;
  const password = `LifeOs!${crypto.randomUUID()}`;

  const signup = await fetch(`${env.supabaseUrl}/auth/v1/signup`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.anonKey,
    },
    body: JSON.stringify({ email, password }),
  });

  const signupJson = await safeJson(signup);
  const signupToken = objectString(signupJson, "access_token") ??
    objectString(objectValueOrNull(signupJson, "session"), "access_token");
  const signupUserId = objectString(
    objectValueOrNull(signupJson, "user"),
    "id",
  );

  if (signup.ok && signupToken && signupUserId) {
    return {
      accessToken: signupToken,
      authUserId: signupUserId,
      email,
    };
  }

  const login = await fetch(
    `${env.supabaseUrl}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: env.anonKey,
      },
      body: JSON.stringify({ email, password }),
    },
  );
  const loginJson = await safeJson(login);
  const loginToken = objectString(loginJson, "access_token");
  const loginUserId = objectString(objectValueOrNull(loginJson, "user"), "id");

  if (!login.ok || !loginToken || !loginUserId) {
    throw new Error(
      `Unable to create auth session. signup=${
        JSON.stringify(signupJson)
      } login=${JSON.stringify(loginJson)}`,
    );
  }

  return {
    accessToken: loginToken,
    authUserId: loginUserId,
    email,
  };
}

async function waitForPublicUser(
  env: EnvConfig,
  authUserId: string,
  email?: string,
): Promise<string> {
  const selectUrl = new URL(`${env.supabaseUrl}/rest/v1/users`);
  selectUrl.searchParams.set("select", "id,auth_id");
  selectUrl.searchParams.set("auth_id", `eq.${authUserId}`);

  for (let i = 0; i < 30; i += 1) {
    const response = await fetch(selectUrl, {
      headers: {
        apikey: env.serviceRoleKey,
        Authorization: `Bearer ${env.serviceRoleKey}`,
      },
    });

    if (response.ok) {
      const rows = await safeJson(response);
      if (Array.isArray(rows) && rows.length > 0) {
        const id = objectString(rows[0], "id");
        if (id) return id;
      }
    }

    await delay(200);
  }

  const fallback = await fetch(`${env.supabaseUrl}/rest/v1/users`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.serviceRoleKey,
      Authorization: `Bearer ${env.serviceRoleKey}`,
      Prefer: "resolution=merge-duplicates,return=representation",
    },
    body: JSON.stringify({
      id: authUserId,
      auth_id: authUserId,
      email: email ?? null,
      timezone: "UTC",
      units: "metric",
      notification_enabled: true,
      onboarding_completed: false,
      calibration_days_remaining: 3,
      deletion_in_progress: false,
    }),
  });

  if (!fallback.ok) {
    throw new Error(
      `public.users row was not created for test auth user (fallback upsert failed with status ${fallback.status})`,
    );
  }

  return authUserId;
}

async function runLoadProfile(
  options: {
    name: string;
    totalRequests: number;
    concurrency: number;
    warmupRequests: number;
    expectedStatuses: Set<number>;
    requestFactory: (index: number) => Promise<HttpResponse>;
  },
): Promise<LatencySummary> {
  const {
    name,
    totalRequests,
    concurrency,
    warmupRequests,
    expectedStatuses,
    requestFactory,
  } = options;

  console.log(
    `[load] ${name}: warmup=${warmupRequests}, requests=${totalRequests}, concurrency=${concurrency}`,
  );

  for (let i = 0; i < warmupRequests; i += 1) {
    const response = await requestFactory(-1 - i);
    if (!expectedStatuses.has(response.status)) {
      throw new Error(
        `[load] ${name}: warmup failed with status ${response.status}`,
      );
    }
  }

  const samples: Sample[] = [];
  let requestCursor = 0;
  const startedAt = performance.now();

  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (true) {
        const index = requestCursor++;
        if (index >= totalRequests) return;

        const requestStart = performance.now();
        let status = 0;
        let ok = false;
        let errorCode: string | undefined;
        try {
          const response = await requestFactory(index);
          status = response.status;
          ok = expectedStatuses.has(response.status);
          if (!ok) errorCode = failureCode(response);
        } catch {
          status = 0;
          ok = false;
          errorCode = "transport_failure";
        }
        const latencyMs = performance.now() - requestStart;
        samples.push({ latencyMs, status, ok, errorCode });
      }
    }),
  );

  const totalDurationMs = performance.now() - startedAt;
  return summarizeSamples(name, samples, concurrency, totalDurationMs);
}

async function runConfiguredProfile(
  options: {
    name: string;
    totalRequests: number;
    concurrency: number;
    warmupRequests: number;
    expectedStatuses: Set<number>;
    soakDurationSeconds: number;
    soakRequestIntervalMs: number;
    requestFactory: (index: number) => Promise<HttpResponse>;
  },
): Promise<LatencySummary> {
  if (options.soakDurationSeconds > 0) {
    return await runSoakProfile({
      name: options.name,
      durationSeconds: options.soakDurationSeconds,
      concurrency: options.concurrency,
      warmupRequests: options.warmupRequests,
      expectedStatuses: options.expectedStatuses,
      requestIntervalMs: options.soakRequestIntervalMs,
      requestFactory: options.requestFactory,
    });
  }

  return await runLoadProfile({
    name: options.name,
    totalRequests: options.totalRequests,
    concurrency: options.concurrency,
    warmupRequests: options.warmupRequests,
    expectedStatuses: options.expectedStatuses,
    requestFactory: options.requestFactory,
  });
}

async function runSoakProfile(
  options: {
    name: string;
    durationSeconds: number;
    concurrency: number;
    warmupRequests: number;
    expectedStatuses: Set<number>;
    requestIntervalMs: number;
    requestFactory: (index: number) => Promise<HttpResponse>;
  },
): Promise<LatencySummary> {
  const {
    name,
    durationSeconds,
    concurrency,
    warmupRequests,
    expectedStatuses,
    requestIntervalMs,
    requestFactory,
  } = options;

  console.log(
    `[soak] ${name}: warmup=${warmupRequests}, duration=${durationSeconds}s, concurrency=${concurrency}, interval_ms=${requestIntervalMs}`,
  );

  for (let i = 0; i < warmupRequests; i += 1) {
    const response = await requestFactory(-1 - i);
    if (!expectedStatuses.has(response.status)) {
      throw new Error(
        `[soak] ${name}: warmup failed with status ${response.status}`,
      );
    }
  }

  const samples: Sample[] = [];
  let requestCursor = 0;
  const startedAt = performance.now();
  const deadlineAt = startedAt + durationSeconds * 1000;

  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (performance.now() < deadlineAt) {
        const index = requestCursor++;
        const requestStart = performance.now();
        let status = 0;
        let ok = false;
        let errorCode: string | undefined;
        try {
          const response = await requestFactory(index);
          status = response.status;
          ok = expectedStatuses.has(response.status);
          if (!ok) errorCode = failureCode(response);
        } catch {
          status = 0;
          ok = false;
          errorCode = "transport_failure";
        }
        const latencyMs = performance.now() - requestStart;
        samples.push({ latencyMs, status, ok, errorCode });
        if (requestIntervalMs > 0) {
          await delay(requestIntervalMs);
        }
      }
    }),
  );

  if (samples.length === 0) {
    throw new Error(`[soak] ${name}: no requests executed`);
  }

  const totalDurationMs = performance.now() - startedAt;
  return summarizeSamples(name, samples, concurrency, totalDurationMs);
}

function summarizeSamples(
  name: string,
  samples: Sample[],
  concurrency: number,
  totalDurationMs: number,
): LatencySummary {
  const statusCounts = samples.reduce<Record<string, number>>((acc, sample) => {
    const key = String(sample.status);
    acc[key] = (acc[key] ?? 0) + 1;
    return acc;
  }, {});

  const successfulLatencies = samples
    .filter((sample) => sample.ok)
    .map((sample) => sample.latencyMs)
    .sort((a, b) => a - b);

  const errorCounts: Record<string, number> = {};
  for (const sample of samples) {
    if (sample.errorCode) {
      errorCounts[sample.errorCode] = (errorCounts[sample.errorCode] ?? 0) + 1;
    }
  }

  if (successfulLatencies.length === 0) {
    throw new Error(
      `[load] ${name}: no successful responses; statusCounts=${
        JSON.stringify(statusCounts)
      }`,
    );
  }

  const failureCount = samples.length - successfulLatencies.length;
  const errorRate = failureCount / samples.length;
  const sumMs = successfulLatencies.reduce((acc, n) => acc + n, 0);
  const minMs = successfulLatencies[0];
  const maxMs = successfulLatencies[successfulLatencies.length - 1];
  const p50Ms = percentile(successfulLatencies, 0.50);
  const p95Ms = percentile(successfulLatencies, 0.95);
  const p99Ms = percentile(successfulLatencies, 0.99);
  const avgMs = sumMs / successfulLatencies.length;
  const throughputRps = samples.length /
    Math.max(totalDurationMs / 1000, 0.001);

  const summary: LatencySummary = {
    requests: samples.length,
    concurrency,
    p50Ms,
    p95Ms,
    p99Ms,
    avgMs,
    maxMs,
    minMs,
    errorRate,
    statusCounts,
    errorCounts,
    totalDurationMs,
    throughputRps,
  };

  console.log(
    `[load] ${name}: p50=${p50Ms.toFixed(1)}ms p95=${p95Ms.toFixed(1)}ms p99=${
      p99Ms.toFixed(1)
    }ms avg=${avgMs.toFixed(1)}ms errors=${(errorRate * 100).toFixed(2)}% rps=${
      throughputRps.toFixed(1)
    } statuses=${JSON.stringify(statusCounts)} errors=${
      JSON.stringify(errorCounts)
    } requests=${samples.length}`,
  );

  return summary;
}

function percentile(sortedValues: number[], p: number): number {
  if (sortedValues.length === 0) return 0;
  const clamped = Math.max(0, Math.min(1, p));
  const index = Math.min(
    sortedValues.length - 1,
    Math.ceil(sortedValues.length * clamped) - 1,
  );
  return sortedValues[Math.max(0, index)];
}

function enforceThresholds(
  name: string,
  summary: LatencySummary,
  p95LimitMs: number,
  maxErrorRate: number,
): void {
  if (summary.p95Ms > p95LimitMs) {
    throw new Error(
      `[load] ${name}: p95 ${
        summary.p95Ms.toFixed(1)
      }ms exceeds limit ${p95LimitMs}ms`,
    );
  }
  if (summary.errorRate > maxErrorRate) {
    throw new Error(
      `[load] ${name}: error rate ${
        (summary.errorRate * 100).toFixed(2)
      }% exceeds limit ${(maxErrorRate * 100).toFixed(2)}%`,
    );
  }
}

async function runFunctionScenario(
  name: string,
  relativeEntrypoint: string,
  run: () => Promise<void>,
): Promise<void> {
  const entrypointPath = pathFromUrl(
    new URL(relativeEntrypoint, import.meta.url),
  );
  console.log(`\n[edge-load] ${name} :: starting ${entrypointPath}`);

  const proc = new Deno.Command("deno", {
    args: [
      "run",
      "--allow-env",
      "--allow-net",
      "--allow-read",
      entrypointPath,
    ],
    cwd: pathFromUrl(REPO_ROOT),
    env: {
      SUPABASE_URL: env.supabaseUrl,
      SUPABASE_ANON_KEY: env.anonKey,
      SUPABASE_SERVICE_ROLE_KEY: env.serviceRoleKey,
      ...forwardedEdgeEnv(),
    },
    stdout: "inherit",
    stderr: "inherit",
  }).spawn();

  try {
    await waitForFunctionReadiness();
    await run();
    console.log(`[edge-load] ${name} :: OK`);
  } finally {
    try {
      proc.kill("SIGTERM");
    } catch {
      // ignore
    }

    const exited = await Promise.race([
      proc.status,
      delay(2_000).then(() => null),
    ]);

    if (exited === null) {
      try {
        proc.kill("SIGKILL");
      } catch {
        // ignore
      }
      await proc.status;
    }

    await delay(150);
  }
}

async function waitForFunctionReadiness(): Promise<void> {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(LOCAL_FUNCTION_URL, {
        method: "OPTIONS",
      });

      if (
        response.status === 204 || response.status === 200 ||
        response.status === 401 || response.status === 405
      ) {
        return;
      }
    } catch {
      // server not ready
    }

    await delay(100);
  }

  throw new Error(
    "Timed out waiting for edge function to start on localhost:8000",
  );
}

function jsonAuthHeaders(accessToken: string): HeadersInit {
  return {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
  };
}

async function requestJson(
  origin: string,
  path: string,
  init: RequestInit,
): Promise<HttpResponse> {
  const response = await fetch(`${origin}${path}`, init);
  const rawText = await response.text();
  let parsed: JsonValue | string | null = null;

  if (rawText.length > 0) {
    try {
      parsed = JSON.parse(rawText) as JsonValue;
    } catch {
      parsed = rawText;
    }
  }

  return {
    status: response.status,
    body: parsed,
    headers: response.headers,
  };
}

function forwardedEdgeEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (
    const key of [
      "FOODS_PROVIDER_ENABLED",
      "FOODS_PROVIDER_SEARCH_ENABLED",
      "FOODS_PROVIDER_BARCODE_ENABLED",
      "OPEN_FOOD_FACTS_BASE_URL",
      "OPEN_FOOD_FACTS_USER_AGENT",
      "OPEN_FOOD_FACTS_BARCODE_TIMEOUT_MS",
      "OPEN_FOOD_FACTS_SEARCH_TIMEOUT_MS",
    ] as const
  ) {
    const value = Deno.env.get(key)?.trim();
    if (value) env[key] = value;
  }
  return env;
}

async function safeJson(response: Response): Promise<JsonValue | null> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as JsonValue;
  } catch {
    return null;
  }
}

function objectValueOrNull(
  value: JsonValue | null,
  key: string,
): JsonValue | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }

  return (value as Record<string, JsonValue>)[key] ?? null;
}

function objectString(value: JsonValue | null, key: string): string | null {
  const raw = objectValueOrNull(value, key);
  return typeof raw === "string" ? raw : null;
}

function pathFromUrl(url: URL): string {
  if (Deno.build.os === "windows") {
    return url.pathname.replace(/^\//, "");
  }
  return url.pathname;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
