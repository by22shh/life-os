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
      return null;
    }

    const row = Array.isArray(data) ? data[0] : data;
    if (!row || typeof row.ok !== "boolean") {
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
    replayHeaderValue === "true";

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
    serviceRoleClientFactory = defaultServiceRoleClientFactory;
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
