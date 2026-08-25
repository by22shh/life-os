import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { ExportRequestBodySchema } from "../../../_shared/payload_schemas.ts";

interface ExportRequestBody {
  export_id?: string;
}

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  let payload: ExportRequestBody = {};
  try {
    const bodyRaw = await request.json();
    const payloadParse = parseWithSchema(ExportRequestBodySchema, bodyRaw);
    if (!payloadParse.ok) {
      return jsonWithRequest(request, {
        error: "invalid_payload",
        issues: payloadParse.issues,
      }, 400);
    }
    payload = payloadParse.output;
  } catch {
    // optional JSON body for legacy clients
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const userClient = anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const service = serviceRoleClient();

  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (userLookupError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userLookupError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const requestedExportId = typeof payload.export_id === "string"
    ? payload.export_id.trim()
    : "";
  if (requestedExportId && !isUUID(requestedExportId)) {
    return jsonWithRequest(request, { error: "invalid_export_id" }, 400);
  }

  // Idempotent replay should not consume the hourly export-create quota.
  if (requestedExportId) {
    const { data: existingJob, error: existingJobError } = await service
      .from("export_jobs")
      .select("id,user_id,status")
      .eq("id", requestedExportId)
      .maybeSingle<{ id: string; user_id: string; status: string }>();

    if (existingJobError) {
      return jsonWithRequest(request, {
        error: "export_job_lookup_failed",
        detail: sanitizedInternalDetail(request, "index", existingJobError),
      }, 500);
    }
    if (existingJob) {
      if (existingJob.user_id !== userRow.id) {
        return jsonWithRequest(request, { error: "export_id_conflict" }, 409);
      }
      return jsonWithRequest(request, {
        export_id: existingJob.id,
        status: existingJob.status,
      }, 202);
    }
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "export");
  if (rateLimited) {
    return rateLimited;
  }

  const exportId = requestedExportId || crypto.randomUUID();

  const { error } = await service.from("export_jobs").insert({
    id: exportId,
    user_id: userRow.id,
    status: "pending",
    requested_at: new Date().toISOString(),
  });

  if (error) {
    return jsonWithRequest(request, {
      error: "export_job_create_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  return jsonWithRequest(
    request,
    { export_id: exportId, status: "pending" },
    202,
  );
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
