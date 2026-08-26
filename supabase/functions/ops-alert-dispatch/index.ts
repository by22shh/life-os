// Ops alert dispatcher: bridges ops_alert_events to a real notification
// channel. Without this function the alert table is write-only telemetry that
// requires a manual SELECT to notice.
//
// Invocation: pg_cron (via pg_net) posts with the service-role key plus the
// X-Ops-Alert-Dispatcher header, mirroring the account deletion worker
// contract. The webhook target (Slack-compatible `{ "text": ... }` payload) is
// configured through the OPS_ALERT_WEBHOOK_URL environment variable; when it
// is unset the dispatcher reports skipped so the cron trail stays honest.

import { handleCors } from "../_shared/cors.ts";
import {
  jsonWithRequest,
  serviceRoleClient,
  validateInternalServiceRoleRequest,
} from "../_shared/supabase.ts";

const DISPATCHER_INVOCATION_HEADER = "X-Ops-Alert-Dispatcher";
const DISPATCHER_INVOCATION_VALUE = "scheduled";
const DEFAULT_WINDOW_MINUTES = 65;
const MAX_WINDOW_MINUTES = 24 * 60;
const MAX_EVENTS_PER_DIGEST = 20;

interface AlertEventRow {
  id: string;
  source: string;
  alert_key: string;
  severity: "warning" | "critical" | string;
  summary: string;
  details: Record<string, unknown> | null;
  triggered_at: string;
}

interface DispatcherBody {
  window_minutes?: number;
}

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const internalAuth = validateInternalServiceRoleRequest(request, {
    invocationHeaderName: DISPATCHER_INVOCATION_HEADER,
    invocationHeaderValue: DISPATCHER_INVOCATION_VALUE,
  });
  if (!internalAuth.ok) {
    return jsonWithRequest(
      request,
      { error: internalAuth.error },
      internalAuth.status,
    );
  }

  let body: DispatcherBody = {};
  try {
    body = await request.json();
  } catch {
    // optional body
  }
  const windowMinutes = clampWindowMinutes(body.window_minutes);

  const webhookUrl = Deno.env.get("OPS_ALERT_WEBHOOK_URL")?.trim() ?? "";
  if (!webhookUrl) {
    return jsonWithRequest(request, {
      status: "skipped",
      reason: "ops_alert_webhook_url_missing",
    });
  }

  const service = serviceRoleClient();

  let events: AlertEventRow[];
  try {
    const sinceIso = new Date(
      Date.now() - windowMinutes * 60 * 1000,
    ).toISOString();
    const { data, error } = await service
      .from("ops_alert_events")
      .select(
        "id,source,alert_key,severity,summary,details,triggered_at",
      )
      .gte("triggered_at", sinceIso)
      .order("triggered_at", { ascending: false })
      .limit(500)
      .returns<AlertEventRow[]>();
    if (error) {
      throw new Error(`ops_alert_fetch_failed:${error.message}`);
    }
    events = data ?? [];
  } catch (error) {
    console.error(
      JSON.stringify({
        event: "ops_alert_dispatch_failed",
        scope: "fetch",
        detail: error instanceof Error ? error.message : String(error),
      }),
    );
    return jsonWithRequest(request, {
      error: "ops_alert_dispatch_failed",
    }, 500);
  }

  if (events.length === 0) {
    return jsonWithRequest(request, {
      status: "ok",
      dispatched: false,
      alert_count: 0,
    });
  }

  const text = buildDigest(events, windowMinutes);
  try {
    const response = await fetch(webhookUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    if (!response.ok) {
      throw new Error(`webhook_status_${response.status}`);
    }
  } catch (error) {
    console.error(
      JSON.stringify({
        event: "ops_alert_dispatch_failed",
        scope: "webhook",
        detail: error instanceof Error ? error.message : String(error),
        alert_count: events.length,
      }),
    );
    return jsonWithRequest(request, {
      error: "ops_alert_dispatch_failed",
      alert_count: events.length,
    }, 502);
  }

  return jsonWithRequest(request, {
    status: "ok",
    dispatched: true,
    alert_count: events.length,
  });
});

function buildDigest(events: AlertEventRow[], windowMinutes: number): string {
  const criticalCount =
    events.filter((event) => event.severity === "critical").length;
  const warningCount = events.length - criticalCount;
  const header =
    `Life OS ops alerts (last ${windowMinutes} min): ${events.length} event(s), ${criticalCount} critical, ${warningCount} warning`;

  const lines = events.slice(0, MAX_EVENTS_PER_DIGEST).map((event) => {
    const triggeredAt = event.triggered_at ?? "";
    return `• [${event.severity}] ${event.source}/${event.alert_key} — ${event.summary} (${triggeredAt})`;
  });

  const overflow = events.length -
    Math.min(events.length, MAX_EVENTS_PER_DIGEST);
  const footer = overflow > 0 ? `\n…and ${overflow} more` : "";

  return [header, ...lines].join("\n") + footer;
}

function clampWindowMinutes(value: number | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_WINDOW_MINUTES;
  }
  return Math.min(MAX_WINDOW_MINUTES, Math.max(1, Math.trunc(value)));
}
