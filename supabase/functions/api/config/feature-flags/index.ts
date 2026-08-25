import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
import {
  FEATURE_FLAG_CACHE_TTL_SECONDS,
  mergeResolvedFeatureFlags,
  type ResolvedFeatureFlagRow,
} from "../../../_shared/feature_flags.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const contextResult = await resolveUserContext(request, "standard");
  if (!contextResult.ok) {
    return contextResult.response;
  }

  const {
    context: { service, userId },
  } = contextResult;

  const { data, error } = await service.rpc("resolve_feature_flags_for_user", {
    p_user_id: userId,
  });

  if (error) {
    return jsonWithRequest(request, {
      error: "feature_flags_resolve_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }

  const flags = mergeResolvedFeatureFlags(
    (data ?? []) as ResolvedFeatureFlagRow[],
  );

  return jsonWithRequest(request, {
    flags,
    fetched_at: new Date().toISOString(),
    ttl_seconds: FEATURE_FLAG_CACHE_TTL_SECONDS,
  });
});
