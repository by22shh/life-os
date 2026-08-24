import {
  localDateToday,
  parseLocalDateParam,
  safeTimeZone,
} from "../../../_shared/date_range.ts";
import {
  buildSupplementDayResult,
  type SupplementLogRow,
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

  const userResult = await resolveUserContext(request, "standard");
  if (!userResult.ok) return userResult.response;
  const { userId, timezone, service } = userResult.context;

  const date = parseLocalDateParam(request, "date") ??
    localDateToday(safeTimeZone(timezone));

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
    .eq("taken_date", date)
    .is("deleted_at", null)
    .order("taken_at", { ascending: true })
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

  const result = buildSupplementDayResult(
    date,
    supplements ?? [],
    logs ?? [],
    catalogNameById,
  );

  return jsonWithRequest(request, {
    date,
    adherence_today_percent: result.adherence_today_percent,
    schedule: result.schedule,
    unscheduled_logs: result.unscheduled_logs,
  });
});
