import {
  correlationIdFromRequest,
  json,
  serviceRoleClient,
} from "./supabase.ts";

export type RateLimitTier =
  | "standard"
  | "write_heavy"
  | "delete_account"
  | "ai_vision"
  | "ai_parse"
  | "search"
  | "auth"
  | "export"
  | "analytics";

interface WindowRule {
  limit: number;
  windowSeconds: number;
  label: string;
}

interface Bucket {
  count: number;
  resetAtEpochMs: number;
}

interface WindowResult {
  ok: boolean;
  retryAfterSeconds: number;
  remaining: number;
  resetEpochSeconds: number;
}

interface ServiceRoleClientLike {
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<{ data: unknown; error: unknown }>;
  // Optional so narrow test doubles stay valid; the real supabase client
  // always provides it and it is used only for best-effort ops alerts.
  from?(table: string): {
    insert(
      values: Record<string, unknown>,
    ): Promise<{ data: unknown; error: unknown }>;
  };
}

const buckets = new Map<string, Bucket>();
const MAX_LOCAL_BUCKETS = 20_000;
const BUCKET_TRIM_BATCH = 2_000;
const defaultServiceRoleClientFactory = () =>
  serviceRoleClient() as unknown as ServiceRoleClientLike;
let serviceRoleClientFactory = defaultServiceRoleClientFactory;

// TTL eviction interval (5 minutes) to prevent memory leaks in warm Edge Functions
const EVICTION_INTERVAL_MS = 5 * 60 * 1000;
let lastEvictionEpochMs = Date.now();

// When the distributed limiter is unavailable the effective budget silently
// multiplies by the number of warm isolates. That degradation must be
// observable instead of silent: emit a structured log line plus a best-effort
// ops_alert_events row (picked up by the ops-alert-dispatch cron). Both are
// throttled in-process on top of the table's dedup index.
const FALLBACK_ALERT_DEDUP_MS = 15 * 60 * 1000;
const FALLBACK_ALERT_SOURCE = "rate_limiter";
const FALLBACK_ALERT_KEY = "distributed_limiter_fallback";
let lastFallbackAlertEpochMs = 0;

function recordDistributedLimiterFallback(tierLabel: string): void {
  const nowMs = nowEpochMs();
  if (nowMs - lastFallbackAlertEpochMs < FALLBACK_ALERT_DEDUP_MS) return;
  lastFallbackAlertEpochMs = nowMs;

  console.error(
    JSON.stringify({
      event: "rate_limit_distributed_unavailable",
      tier: tierLabel,
      detail: "distributed limiter unavailable; using per-isolate fallback",
    }),
  );

  void (async () => {
    try {
      const service = serviceRoleClientFactory();
      if (!service.from) return;
      const dedupWindowStart = new Date(
        Math.floor(nowMs / FALLBACK_ALERT_DEDUP_MS) * FALLBACK_ALERT_DEDUP_MS,
      ).toISOString();
      const { error } = await service.from("ops_alert_events").insert({
        source: FALLBACK_ALERT_SOURCE,
        alert_key: FALLBACK_ALERT_KEY,
        severity: "warning",
        dedup_window_start: dedupWindowStart,
        summary:
          "Distributed rate limiter unavailable; requests degraded to per-isolate budgets.",
        details: { tier: tierLabel },
      });
      if (error) {
        throw new Error(
          typeof error === "object" && error !== null && "message" in error
            ? String((error as { message?: unknown }).message)
            : String(error),
        );
      }
    } catch (error) {
      console.error(
        JSON.stringify({
          event: "rate_limit_fallback_alert_failed",
          detail: error instanceof Error ? error.message : String(error),
        }),
      );
    }
  })();
}

function evictStaleBuckets(nowMs: number): void {
  if (nowMs - lastEvictionEpochMs < EVICTION_INTERVAL_MS) return;
  lastEvictionEpochMs = nowMs;
  for (const [key, bucket] of buckets) {
    if (bucket.resetAtEpochMs <= nowMs) {
      buckets.delete(key);
    }
  }
}

function trimBucketsIfNeeded(): void {
  if (buckets.size <= MAX_LOCAL_BUCKETS) return;

  const overflow = buckets.size - MAX_LOCAL_BUCKETS;
  const trimCount = Math.min(BUCKET_TRIM_BATCH, overflow);
  let removed = 0;
  for (const key of buckets.keys()) {
    if (removed >= trimCount) break;
    buckets.delete(key);
    removed += 1;
  }
}

const RULES: Record<RateLimitTier, WindowRule[]> = {
  standard: [{ limit: 120, windowSeconds: 60, label: "standard" }],
  write_heavy: [{ limit: 30, windowSeconds: 60, label: "write_heavy" }],
  delete_account: [{ limit: 3, windowSeconds: 3600, label: "delete_account" }],
  ai_vision: [
    { limit: 10, windowSeconds: 60, label: "ai_vision" },
    { limit: 30, windowSeconds: 3600, label: "ai_vision_hourly" },
  ],
  ai_parse: [
    { limit: 20, windowSeconds: 60, label: "ai_parse" },
    { limit: 200, windowSeconds: 86400, label: "ai_parse_daily" },
  ],
  search: [{ limit: 60, windowSeconds: 60, label: "search" }],
  auth: [{ limit: 5, windowSeconds: 60, label: "auth" }],
  export: [{ limit: 1, windowSeconds: 3600, label: "export" }],
  analytics: [{ limit: 10, windowSeconds: 60, label: "analytics" }],
};

const OUTBOX_REPLAY_RULE: WindowRule = {
  limit: 300,
  windowSeconds: 300,
  label: "outbox_replay",
};

// Outbox replay raises throughput for high-volume sync endpoints by replacing
// the interactive tier with OUTBOX_REPLAY_RULE. Cost-sensitive tiers are
// deliberately excluded: a client-supplied header must never relax AI,
// auth, deletion, export, or search budgets, because that would turn the
// exemption into a quota-bypass vector (e.g. ai_vision 10/min + 30/hr would
// otherwise become ~60/min sustained).
const OUTBOX_REPLAY_EXEMPTABLE_TIERS: ReadonlySet<RateLimitTier> = new Set([
  "standard",
  "write_heavy",
  "analytics",
]);

function nowEpochMs(): number {
  return Date.now();
}

function readHeader(request: Request, key: string): string | null {
  const direct = request.headers.get(key);
  if (direct != null) return direct;
  const alt = request.headers.get(key.toLowerCase());
  return alt;
}

function applyWindow(
  userKey: string,
  rule: WindowRule,
  nowMs: number,
): WindowResult {
  const bucketKey = `${rule.label}:${userKey}`;
  const existing = buckets.get(bucketKey);
  const resetAt = existing && existing.resetAtEpochMs > nowMs
    ? existing.resetAtEpochMs
    : nowMs + rule.windowSeconds * 1000;
  const count = existing && existing.resetAtEpochMs > nowMs
    ? existing.count
    : 0;

  if (count >= rule.limit) {
    const retryAfter = Math.max(1, Math.ceil((resetAt - nowMs) / 1000));
    return {
      ok: false,
      retryAfterSeconds: retryAfter,
      remaining: 0,
      resetEpochSeconds: Math.floor(resetAt / 1000),
    };
  }

  const nextCount = count + 1;
  buckets.set(bucketKey, { count: nextCount, resetAtEpochMs: resetAt });
  trimBucketsIfNeeded();
  return {
    ok: true,
    retryAfterSeconds: 0,
    remaining: Math.max(0, rule.limit - nextCount),
    resetEpochSeconds: Math.floor(resetAt / 1000),
  };
}

async function applyWindowDistributed(
  userKey: string,
  rule: WindowRule,
): Promise<WindowResult | null> {
  try {
    const service = serviceRoleClientFactory();
    const bucketKey = `${rule.label}:${userKey}`;
    const { data, error } = await service.rpc("check_rate_limit_bucket", {
      p_bucket_key: bucketKey,
      p_limit: rule.limit,
      p_window_seconds: rule.windowSeconds,
    });

    if (error) {
      recordDistributedLimiterFallback(rule.label);
      return null;
    }

    const row = Array.isArray(data) ? data[0] : data;
    if (!row || typeof row.ok !== "boolean") {
      recordDistributedLimiterFallback(rule.label);
      return null;
    }

    return {
      ok: Boolean(row.ok),
      retryAfterSeconds: Math.max(0, Number(row.retry_after_seconds ?? 0)),
      remaining: Math.max(0, Number(row.remaining ?? 0)),
      resetEpochSeconds: Math.max(
        0,
        Number(row.reset_epoch_seconds ?? Math.floor(Date.now() / 1000)),
      ),
    };
  } catch {
    recordDistributedLimiterFallback(rule.label);
    return null;
  }
}

export async function enforceRateLimit(
  request: Request,
  userKey: string,
  tier: RateLimitTier,
  options: { allowOutboxReplayExemption?: boolean } = {},
): Promise<Response | null> {
  const normalizedUserKey = userKey.trim();
  if (!normalizedUserKey) return null;

  const replayHeaderValue = readHeader(request, "X-Outbox-Replay")
    ?.trim()
    .toLowerCase();
  const outboxReplay = options.allowOutboxReplayExemption === true &&
    replayHeaderValue === "true" &&
    OUTBOX_REPLAY_EXEMPTABLE_TIERS.has(tier);

  const rules = outboxReplay ? [OUTBOX_REPLAY_RULE] : RULES[tier];
  const nowMs = nowEpochMs();

  // Periodically evict expired entries to prevent memory accumulation
  evictStaleBuckets(nowMs);

  for (const rule of rules) {
    // Primary: distributed DB-backed limiter; fallback to in-memory on failure.
    const result = await applyWindowDistributed(normalizedUserKey, rule) ??
      applyWindow(normalizedUserKey, rule, nowMs);
    if (!result.ok) {
      return json(
        {
          error: "rate_limit_exceeded",
          message:
            `Too many requests. Try again in ${result.retryAfterSeconds} seconds.`,
          retry_after_seconds: result.retryAfterSeconds,
          tier: rule.label,
        },
        429,
        {
          "Retry-After": String(result.retryAfterSeconds),
          "X-RateLimit-Limit": String(rule.limit),
          "X-RateLimit-Remaining": "0",
          "X-RateLimit-Reset": String(result.resetEpochSeconds),
          "X-Correlation-Id": correlationIdFromRequest(request),
        },
      );
    }
  }

  return null;
}

export const __rateLimitTestHooks = {
  resetBuckets(): void {
    buckets.clear();
    lastEvictionEpochMs = Date.now();
    lastFallbackAlertEpochMs = 0;
    serviceRoleClientFactory = defaultServiceRoleClientFactory;
  },
  setLastFallbackAlertEpochMs(epochMs: number): void {
    lastFallbackAlertEpochMs = epochMs;
  },
  bucketCount(): number {
    return buckets.size;
  },
  maxLocalBuckets(): number {
    return MAX_LOCAL_BUCKETS;
  },
  setLastEvictionEpochMs(epochMs: number): void {
    lastEvictionEpochMs = epochMs;
  },
  setServiceRoleClientFactory(
    factory: (() => ServiceRoleClientLike) | null,
  ): void {
    serviceRoleClientFactory = factory ?? defaultServiceRoleClientFactory;
  },
};
