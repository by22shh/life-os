import {
  generateAndPersistDailyInsights,
} from "../../_shared/daily_insights.ts";
import {
  localDateToday,
  parseLocalDateParam,
  pathnameTail,
  safeTimeZone,
} from "../../_shared/date_range.ts";
import {
  jsonWithRequest,
  sanitizedInternalDetail,
} from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (!["GET", "POST"].includes(request.method)) {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const tail = pathnameTail(new URL(request.url).pathname);
  const route = (tail[0] ?? "").toLowerCase();
  const action = (tail[1] ?? "").toLowerCase();

  const userResult = await resolveUserContext(
    request,
    request.method === "GET" ? "standard" : "write_heavy",
    { allowOutboxReplayExemption: request.method !== "GET" },
  );
  if (!userResult.ok) return userResult.response;

  const { userId, timezone, service } = userResult.context;

  if (request.method === "GET" && route === "") {
    const date = parseLocalDateParam(request, "date") ??
      localDateToday(safeTimeZone(timezone));
    try {
      const snapshot = await generateAndPersistDailyInsights({
        service,
        userId,
        timezone,
        date,
      });
      const recommendations = snapshot.recommendations
        .filter((row) => !row.dismissed)
        .sort((lhs, rhs) => rhs.updated_at.localeCompare(lhs.updated_at))
        .map((row) => ({
          id: row.id,
          category: row.category,
          priority: row.priority,
          title: row.title,
          description: row.description,
          dismissed: row.dismissed,
        }));

      return jsonWithRequest(request, {
        date,
        recommendations,
      });
    } catch (error) {
      return jsonWithRequest(request, {
        error: "recommendations_generation_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500);
    }
  }

  if (request.method === "POST" && isUUID(route) && action === "dismiss") {
    const { data, error } = await service
      .from("recommendations")
      .update({
        dismissed: true,
      })
      .eq("id", route)
      .eq("user_id", userId)
      .select("id")
      .maybeSingle<{ id: string }>();

    if (error) {
      return jsonWithRequest(request, {
        error: "recommendation_dismiss_failed",
        detail: sanitizedInternalDetail(request, "index", error),
      }, 500);
    }
    if (!data) {
      return jsonWithRequest(request, {
        error: "recommendation_not_found",
      }, 404);
    }

    return jsonWithRequest(request, { ok: true });
  }

  return jsonWithRequest(request, { error: "invalid_path" }, 404);
});

function isUUID(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}
