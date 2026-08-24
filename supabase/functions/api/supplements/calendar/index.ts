import {
  enumerateLocalDates,
  parseLocalDateRange,
} from "../../../_shared/date_range.ts";
import {
  buildSupplementDayResult,
  type SupplementLogRow,
  supplementStatus,
  type UserSupplementRow,
} from "../../../_shared/supplements.ts";
import { jsonWithRequest } from "../../../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../../../_shared/user_context.ts";

interface CatalogRow {
  id: string;
  name: string;
}

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "GET") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const range = parseLocalDateRange(request, 62);
  if (!range) {
    return jsonWithRequest(request, { error: "invalid_range" }, 400);
  }

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, service } = userResult.context;

  const { data: supplements, error: supplementsError } = await service
    .from("user_supplements")
    .select(
      "id,catalog_id,custom_name,frequency,scheduled_times,days_of_week,started_at,ended_at,active",
    )
    .eq("user_id", userId)
    .eq("active", true)
    .returns<UserSupplementRow[]>();

  if (supplementsError) {
    return jsonWithRequest(request, {
      error: "supplements_fetch_failed",
      detail: supplementsError.message,
    }, 500);
  }

  const { data: logs, error: logsError } = await service
    .from("supplement_logs")
    .select(
      "id,user_supplement_id,supplement_name,scheduled_time,taken_at,taken_date",
    )
    .eq("user_id", userId)
    .gte("taken_date", range.from)
    .lte("taken_date", range.to)
    .is("deleted_at", null)
    .returns<SupplementLogRow[]>();

  if (logsError) {
    return jsonWithRequest(request, {
      error: "supplement_logs_fetch_failed",
      detail: logsError.message,
    }, 500);
  }

  const catalogIds = (supplements ?? [])
    .map((row) => row.catalog_id)
    .filter((id): id is string => typeof id === "string" && id.length > 0);

  const catalogNameById = new Map<string, string>();
  if (catalogIds.length > 0) {
    const { data: catalogRows, error: catalogError } = await service
      .from("supplement_catalog")
      .select("id,name")
      .in("id", catalogIds)
      .returns<CatalogRow[]>();

    if (catalogError) {
      return jsonWithRequest(request, {
        error: "supplement_catalog_fetch_failed",
        detail: catalogError.message,
      }, 500);
    }

    for (const row of catalogRows ?? []) {
      catalogNameById.set(row.id, row.name);
    }
  }

  const logsByDate = new Map<string, SupplementLogRow[]>();
  for (const row of logs ?? []) {
    const list = logsByDate.get(row.taken_date) ?? [];
    list.push(row);
    logsByDate.set(row.taken_date, list);
  }

  const days = enumerateLocalDates(range.from, range.to).map((date) => {
    const result = buildSupplementDayResult(
      date,
      supplements ?? [],
      logsByDate.get(date) ?? [],
      catalogNameById,
    );

    return {
      date,
      adherence_today_percent: result.adherence_today_percent,
      status: supplementStatus(
        result.scheduled_count,
        result.adherence_today_percent,
      ),
    };
  });

  return jsonWithRequest(request, {
    from: range.from,
    to: range.to,
    days,
  });
});
