import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  serviceRoleClient,
} from "../../../_shared/supabase.ts";
import { handleCors, withCorsHeaders } from "../../../_shared/cors.ts";
import { enforceRateLimit } from "../../../_shared/rate_limit.ts";
import { fetchReadyExportArtifact } from "../../../_shared/export_builder.ts";

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const url = new URL(request.url);
  const exportId = (url.searchParams.get("export_id") ?? "").trim();
  const token = (url.searchParams.get("token") ?? "").trim();
  if (!exportId || !token) {
    return jsonWithRequest(request, {
      error: "missing_export_id_or_token",
    }, 400);
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
      detail: userLookupError.message,
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "standard");
  if (rateLimited) {
    return rateLimited;
  }

  const readyArtifact = await fetchReadyExportArtifact(
    service,
    userRow.id,
    exportId,
    token,
  );

  if (!readyArtifact) {
    return jsonWithRequest(request, {
      error: "export_not_ready_or_expired",
    }, 404);
  }

  const storedContentType = readyArtifact.artifact.content_type?.trim();
  const responseContentType = storedContentType
    ? (
      storedContentType.toLowerCase().startsWith("application/json") &&
        !storedContentType.toLowerCase().includes("charset=")
        ? `${storedContentType}; charset=utf-8`
        : storedContentType
    )
    : "application/json; charset=utf-8";

  return new Response(JSON.stringify(readyArtifact.payload, null, 2), {
    status: 200,
    headers: withCorsHeaders({
      "Content-Type": responseContentType,
      "Content-Disposition":
        `attachment; filename="${readyArtifact.artifact.file_name}"`,
      "Cache-Control": "private, max-age=0, no-store",
    }),
  });
});
