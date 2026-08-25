import { parseLocalDateParam } from "../../../_shared/date_range.ts";
import { generateAndPersistDailyInsights } from "../../../_shared/daily_insights.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../../_shared/supabase.ts";
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

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;

  const { userId, timezone, service } = userResult.context;
  const date = parseLocalDateParam(request, "date") ?? undefined;

  try {
    const snapshot = await generateAndPersistDailyInsights({
      service,
      userId,
      timezone,
      date,
    });
    return jsonWithRequest(request, snapshot);
  } catch (error) {
    return jsonWithRequest(request, {
      error: "daily_insights_generation_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 500);
  }
});
