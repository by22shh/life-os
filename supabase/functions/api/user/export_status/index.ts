import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { handleCors } from "../../../_shared/cors.ts";
import { parseWithSchema } from "../../../_shared/runtime_schema.ts";
import { ExportStatusRequestBodySchema } from "../../../_shared/payload_schemas.ts";
import { ensureExportReady } from "../../../_shared/export_builder.ts";

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "GET" && request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  let exportId = new URL(request.url).searchParams.get("export_id") ?? "";
  if (!exportId && request.method === "POST") {
    try {
      const bodyRaw = await request.json();
      const bodyParse = parseWithSchema(ExportStatusRequestBodySchema, bodyRaw);
      if (!bodyParse.ok) {
        return jsonWithRequest(request, {
          error: "invalid_payload",
          issues: bodyParse.issues,
        }, 400);
      }
      if (typeof bodyParse.output.export_id === "string") {
        exportId = bodyParse.output.export_id;
      }
    } catch {
      // no-op
    }
  }
  exportId = exportId.trim();
  if (!exportId) {
    return jsonWithRequest(request, { error: "missing_export_id" }, 400);
  }
  if (!isUUID(exportId)) {
    return jsonWithRequest(request, { error: "invalid_export_id" }, 400);
  }

  const authenticated = await resolveAuthenticatedUser(request);
  if (!authenticated.ok) return authenticated.response;
  const authData = authenticated.data;

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

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }

  const { data, error } = await service
    .from("export_jobs")
    .select("id,status,download_url,completed_at")
    .eq("id", exportId)
    .eq("user_id", userRow.id)
    .maybeSingle<{
      id: string;
      status: string;
      download_url: string | null;
      completed_at: string | null;
    }>();

  if (error) {
    return jsonWithRequest(request, {
      error: "export_status_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }
  if (!data) {
    return jsonWithRequest(request, { error: "not_found" }, 404);
  }

  let resolvedStatus = data.status;
  let resolvedDownloadUrl = data.download_url;
  if (
    data.status === "pending" || data.status === "processing" ||
    data.status === "ready"
  ) {
    try {
      const ensured = await ensureExportReady(
        service,
        userRow.id,
        data.id,
        new URL(request.url).origin,
      );
      resolvedStatus = ensured.status;
      resolvedDownloadUrl = ensured.downloadUrl;
    } catch (processingError) {
      const detail = processingError instanceof Error
        ? processingError.message
        : String(processingError);
      return jsonWithRequest(request, {
        error: "export_processing_failed",
        detail,
      }, 500);
    }
  }

  return jsonWithRequest(request, {
    export_id: data.id,
    status: resolvedStatus,
    download_url: resolvedDownloadUrl,
  });
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
