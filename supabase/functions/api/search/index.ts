import { jsonWithRequest } from "../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../_shared/user_context.ts";

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(request, "search");
  if (!userResult.ok) return userResult.response;

  const { userId, service } = userResult.context;
  const url = new URL(request.url);

  const query = (url.searchParams.get("q") ?? "").trim();
  if (!query) {
    return jsonWithRequest(request, { error: "query_required" }, 400);
  }

  const rawLimit = Number.parseInt(url.searchParams.get("limit") ?? "20", 10);
  const limit = Number.isFinite(rawLimit)
    ? Math.min(50, Math.max(1, rawLimit))
    : 20;

  const [foodsRes, exercisesRes] = await Promise.all([
    service
      .from("user_foods")
      .select("id,name,brand,barcode")
      .eq("user_id", userId)
      .ilike("name", `%${escapeIlike(query)}%`)
      .order("created_at", { ascending: false })
      .limit(limit)
      .returns<
        Array<
          {
            id: string;
            name: string;
            brand: string | null;
            barcode: string | null;
          }
        >
      >(),
    service
      .from("exercise_catalog")
      .select("id,name,category,is_custom")
      .or(`is_custom.eq.false,created_by.eq.${userId}`)
      .ilike("name", `%${escapeIlike(query)}%`)
      .order("name", { ascending: true })
      .limit(limit)
      .returns<
        Array<
          { id: string; name: string; category: string; is_custom: boolean }
        >
      >(),
  ]);

  if (foodsRes.error) {
    return jsonWithRequest(request, {
      error: "search_foods_failed",
      detail: foodsRes.error.message,
    }, 500);
  }

  if (exercisesRes.error) {
    return jsonWithRequest(request, {
      error: "search_exercises_failed",
      detail: exercisesRes.error.message,
    }, 500);
  }

  return jsonWithRequest(request, {
    query,
    limit,
    foods: foodsRes.data ?? [],
    exercises: exercisesRes.data ?? [],
  });
});

function escapeIlike(value: string): string {
  return value.replaceAll("%", "\\%").replaceAll("_", "\\_");
}
