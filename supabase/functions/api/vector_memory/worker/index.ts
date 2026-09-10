import {
  jsonWithRequest,
  serviceRoleClient,
  validateInternalServiceRoleRequest,
} from "../../../_shared/supabase.ts";
import {
  deleteUserVectorMemory,
  syncUserVectorMemory,
} from "../../../_shared/vector_memory.ts";

Deno.serve(async (request) => {
  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }
  const auth = validateInternalServiceRoleRequest(request, {
    invocationHeaderName: "X-Vector-Memory-Worker",
    invocationHeaderValue: "scheduled",
  });
  if (!auth.ok) {
    return jsonWithRequest(request, { error: auth.error }, auth.status);
  }
  const service = serviceRoleClient();
  const before = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data, error } = await service.from("privacy_settings")
    .select("user_id,vector_opt_in,ai_processing_consent")
    .or(
      `and(vector_cleanup_required.eq.true,or(vector_opt_in.eq.false,ai_processing_consent.eq.false)),and(vector_opt_in.eq.true,ai_processing_consent.eq.true,or(vector_last_sync_at.is.null,vector_last_sync_at.lt.${before}))`,
    )
    .order("vector_last_attempt_at", { ascending: true, nullsFirst: true })
    .limit(5)
    .returns<
      Array<
        {
          user_id: string;
          vector_opt_in: boolean;
          ai_processing_consent: boolean;
        }
      >
    >();
  if (error) {
    return jsonWithRequest(
      request,
      { error: "vector_worker_lookup_failed" },
      500,
    );
  }
  const results: Array<{ user_id: string; status: string }> = [];
  for (const row of data ?? []) {
    try {
      if (!row.vector_opt_in || !row.ai_processing_consent) {
        await deleteUserVectorMemory(service, row.user_id);
        results.push({ user_id: row.user_id, status: "deleted" });
      } else {
        const outcome = await syncUserVectorMemory(service, row.user_id);
        results.push({ user_id: row.user_id, status: outcome.status });
      }
    } catch (error) {
      results.push({
        user_id: row.user_id,
        status: error instanceof Error ? error.message : "vector_worker_failed",
      });
    }
  }
  const failed = results.some((r) =>
    !["synced", "disabled", "deleted"].includes(r.status)
  );
  return jsonWithRequest(
    request,
    { processed: results.length, results },
    failed ? 503 : 200,
  );
});
