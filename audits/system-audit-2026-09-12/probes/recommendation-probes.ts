// Audit regression probes. Expected behavior is asserted, so current defects fail.
// Uses actual production generator/handler; only network dependencies are mocked.
import { assert, assertEquals, assertStringIncludes } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { __dailyInsightsTestHooks } from "../../../supabase/functions/_shared/daily_insights.ts";

for (const example of [
  { prior: 20, today: 40, expected: "above" },
  { prior: 90, today: 80, expected: "below" },
]) {
  Deno.test(`daily insight must describe the actual direction ${example.prior} → ${example.today}`, async () => {
    const snapshot = await __dailyInsightsTestHooks.buildDailySnapshot({
      userId: "11111111-1111-4111-8111-111111111111", date: "2026-09-12",
      generatedAt: "2026-09-12T10:00:00Z", localHour: 17, baselineSleepHours: 8,
      recoveryRows: [
        { date: "2026-09-11", recovery_score: example.prior, recovery_zone: "critical", sleep_duration_hours: 8, allostatic_load: 0, confidence_score: 0.9 },
        { date: "2026-09-12", recovery_score: example.today, recovery_zone: example.today < 50 ? "caution" : "optimal", sleep_duration_hours: 8, allostatic_load: 0, confidence_score: 0.9 },
      ], nutritionTarget: null, totalProtein: 0, mealCount: 0, workoutCount: 0, totalTrimp: 0,
    });
    const insight = snapshot.insights.find((i) => i.type?.endsWith("recovery_status"))!;
    console.log(JSON.stringify({input:example,actual:insight.body}));
    assertStringIncludes(insight.body, example.expected);
  });
}

type Handler = (request: Request) => Promise<Response>;
let handler: Handler;
const originalServe = Deno.serve;
Object.defineProperty(Deno, "serve", {configurable:true, writable:true, value: (h: Handler) => {
  handler = h;
  return { finished: Promise.resolve(), shutdown() {} };
}});
try { await import("../../../supabase/functions/api/insights/predict/index.ts"); }
finally { Object.defineProperty(Deno, "serve", {configurable:true, writable:true, value:originalServe}); }

async function predictWithAI(aiResult: Record<string, unknown>) {
  const originalFetch = globalThis.fetch;
  const config = { SUPABASE_URL: "http://127.0.0.1:54321", SUPABASE_ANON_KEY: "audit-anon", SUPABASE_SERVICE_ROLE_KEY:"audit-service", OPENROUTER_API_KEY:"audit-mock-only" };
  const oldEnv = new Map(Object.keys(config).map((key) => [key, Deno.env.get(key)]));
  for(const [key,value] of Object.entries(config)) Deno.env.set(key,value);
  const json = (value: unknown) => new Response(JSON.stringify(value),{headers:{"Content-Type":"application/json"}});
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const req = input instanceof Request ? input : new Request(String(input),init);
    const url = new URL(req.url);
    if(url.pathname === "/auth/v1/user") return json({id:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"});
    if(url.pathname === "/rest/v1/users") return json([{id:"11111111-1111-4111-8111-111111111111",timezone:"UTC",baseline_sleep_hours:8}]);
    if(url.pathname === "/rest/v1/privacy_settings") return json([{ai_processing_consent:true}]);
    if(url.pathname === "/rest/v1/rpc/check_rate_limit_bucket") return json([{ok:true,retry_after_seconds:0,remaining:999,reset_epoch_seconds:Math.floor(Date.now()/1000)+60}]);
    if(url.hostname === "openrouter.ai") return json({choices:[{message:{content:JSON.stringify(aiResult)}}]});
    if(url.pathname.startsWith("/rest/v1/")) return json([]);
    throw new Error(`Unexpected network request ${url.origin}${url.pathname}`);
  }) as typeof fetch;
  try {
    const response = await handler(new Request("http://audit.invalid/predict",{method:"POST",headers:{"Content-Type":"application/json",Authorization:"Bearer audit-token"},body:JSON.stringify({target_date:"2026-09-13",scenario_text:"I sleep for eight hours",scenario_type:"sleep"})}));
    const result = await response.json();
    assertEquals(response.status,200);
    console.log(JSON.stringify({ai:aiResult,actual:result}));
    return result;
  } finally {
    globalThis.fetch = originalFetch;
    for(const [key,value] of oldEnv) value === undefined ? Deno.env.delete(key) : Deno.env.set(key,value);
  }
}

Deno.test("predict must derive zone from returned recovery range", async () => {
  const result = await predictWithAI({predicted_recovery_range:[10,20],predicted_zone:"optimal",confidence_score:1,explanation:"Mock model returned an inconsistent zone."});
  assertEquals(result.predicted_zone,"critical");
});
Deno.test("predict must clamp both endpoints and return an ordered 0–100 range", async () => {
  const result = await predictWithAI({predicted_recovery_range:[-50,-20],predicted_zone:"critical",confidence_score:0.5,explanation:"Mock model returned an out-of-range result."});
  const [lo,hi] = result.predicted_recovery_range;
  assert(lo >= 0 && lo <= hi && hi <= 100,`Invalid returned range ${JSON.stringify(result.predicted_recovery_range)}`);
});
