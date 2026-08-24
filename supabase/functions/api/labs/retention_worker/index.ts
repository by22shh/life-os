import { handleCors } from "../../../_shared/cors.ts";
import {
  jsonWithRequest,
  serviceRoleClient,
  validateInternalServiceRoleRequest,
} from "../../../_shared/supabase.ts";
import { pruneExpiredMedicalScanArtifacts } from "../../../_shared/medical_scan_privacy.ts";

const DEFAULT_BATCH_SIZE = 100;
const MAX_BATCH_SIZE = 100;
const WORKER_INVOCATION_HEADER = "X-Labs-Retention-Worker";
const WORKER_INVOCATION_VALUE = "scheduled";

interface WorkerBody {
  batch_size?: number;
  now?: string;
}

interface DueMedicalScanUserRow {
  user_id: string;
}

interface UserRow {
  id: string;
  auth_id: string;
}

interface WorkerResult {
  user_id: string;
  status: "processed";
}

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const internalAuth = validateInternalServiceRoleRequest(request, {
    invocationHeaderName: WORKER_INVOCATION_HEADER,
    invocationHeaderValue: WORKER_INVOCATION_VALUE,
  });
  if (!internalAuth.ok) {
    return jsonWithRequest(
      request,
      { error: internalAuth.error },
      internalAuth.status,
    );
  }

  let body: WorkerBody = {};
  try {
    body = await request.json();
  } catch {
    // optional body
  }

  const batchSize = clampBatchSize(body.batch_size);
  const now = parseWorkerNow(body.now);
  const service = serviceRoleClient();

  try {
    const users = await fetchUsersWithDueRetention(service, now, batchSize);
    const results: WorkerResult[] = [];

    for (const user of users) {
      await pruneExpiredMedicalScanArtifacts(
        service,
        user.id,
        user.auth_id,
        now,
      );
      results.push({
        user_id: user.id,
        status: "processed",
      });
    }

    return jsonWithRequest(request, {
      processed_users: results.length,
      batch_size: batchSize,
      now: now.toISOString(),
      results,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return jsonWithRequest(request, {
      error: "medical_scan_retention_worker_failed",
      detail,
    }, 500);
  }
});

async function fetchUsersWithDueRetention(
  service: ReturnType<typeof serviceRoleClient>,
  now: Date,
  batchSize: number,
): Promise<UserRow[]> {
  const { data: dueRows, error: dueRowsError } = await service
    .from("medical_scans")
    .select("user_id")
    .not("scheduled_deletion_at", "is", null)
    .lte("scheduled_deletion_at", now.toISOString())
    .order("scheduled_deletion_at", { ascending: true })
    .limit(batchSize)
    .returns<DueMedicalScanUserRow[]>();

  if (dueRowsError) {
    throw new Error(
      `medical_scan_retention_due_lookup_failed:${dueRowsError.message}`,
    );
  }

  const userIds = [
    ...new Set((dueRows ?? []).map((row) => row.user_id).filter(Boolean)),
  ];
  if (userIds.length === 0) {
    return [];
  }

  const { data: users, error: usersError } = await service
    .from("users")
    .select("id,auth_id")
    .in("id", userIds)
    .returns<UserRow[]>();

  if (usersError) {
    throw new Error(
      `medical_scan_retention_user_lookup_failed:${usersError.message}`,
    );
  }

  const userById = new Map((users ?? []).map((user) => [user.id, user]));
  return userIds
    .map((userId) => userById.get(userId))
    .filter((user): user is UserRow =>
      user != null && typeof user.auth_id === "string" &&
      user.auth_id.length > 0
    );
}

function clampBatchSize(value: number | undefined): number {
  const numeric = Number.isFinite(value) ? Number(value) : DEFAULT_BATCH_SIZE;
  return Math.min(MAX_BATCH_SIZE, Math.max(1, Math.trunc(numeric)));
}

function parseWorkerNow(rawValue: string | undefined): Date {
  if (typeof rawValue !== "string" || rawValue.trim().length === 0) {
    return new Date();
  }

  const parsed = new Date(rawValue);
  if (Number.isNaN(parsed.getTime())) {
    return new Date();
  }
  return parsed;
}
