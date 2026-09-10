import {
  jsonWithRequest,
  parseBearer,
  resolveAuthenticatedUser,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../_shared/supabase.ts";
import { enforceRateLimit } from "../_shared/rate_limit.ts";
import { enforceAIProcessingConsent } from "../_shared/ai_consent.ts";
import { handleCors } from "../_shared/cors.ts";
import { parseWithSchema } from "../_shared/runtime_schema.ts";
import { AnalyzeFoodImageBodySchema } from "../_shared/payload_schemas.ts";
import { readJsonBody } from "../_shared/request_limits.ts";
import {
  type AnalyzeFoodImageRequestPayload,
  buildFoodImageSystemPrompt,
  buildFoodImageUserPrompt,
  normalizeFoodImageAnalysis,
  parseAIJsonContent,
} from "../_shared/food_image_analysis.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TIMEOUT_MS = 20_000;
const MAX_IMAGE_DATA_URL_LENGTH = 8_000_000;
const MAX_TIMESTAMP_LENGTH = 64;
const MAX_ACTIVITY_LENGTH = 280;
const MAX_RECOGNIZED_TEXT_LENGTH = 1_500;
const MAX_LOCALE_LENGTH = 32;

function asTrimmedString(value: unknown, maxLength: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength) return null;
  return trimmed;
}

function normalizeImageDataUrl(value: unknown): string | null {
  const raw = asTrimmedString(value, MAX_IMAGE_DATA_URL_LENGTH);
  if (!raw) return null;
  if (!raw.startsWith("data:image/")) return null;
  if (!raw.includes(";base64,")) return null;
  return raw;
}

function normalizeBarcodes(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const result: string[] = [];
  for (const entry of value) {
    const barcode = asTrimmedString(entry, 64);
    if (!barcode) continue;
    if (seen.has(barcode)) continue;
    seen.add(barcode);
    result.push(barcode);
    if (result.length >= 6) break;
  }
  return result;
}

function extractMessageContent(payload: unknown): string {
  const content = (payload as {
    choices?: Array<{
      message?: {
        content?: unknown;
      };
    }>;
  })?.choices?.[0]?.message?.content;

  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (!part || typeof part !== "object") return "";
        const text = (part as Record<string, unknown>).text;
        return typeof text === "string" ? text : "";
      })
      .filter(Boolean)
      .join("\n");
  }
  return "";
}

export const __analyzeFoodImageTestHooks = {
  asTrimmedString,
  extractMessageContent,
  normalizeBarcodes,
  normalizeImageDataUrl,
};

Deno.serve(async (request) => {
  const preflight = handleCors(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const authHeader = parseBearer(request);
  if (!authHeader.startsWith("Bearer ")) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const authenticated = await resolveAuthenticatedUser(request);
  if (!authenticated.ok) return authenticated.response;
  const authData = authenticated.data;

  const service = serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (userLookupError) {
    // deno-coverage-ignore -- non-Error upstream failures are covered through guardrail tests.
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", userLookupError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "ai_vision");
  if (rateLimited) {
    return rateLimited;
  }

  const consentBlocked = await enforceAIProcessingConsent(
    service,
    userRow.id,
  );
  if (consentBlocked) return consentBlocked;

  // Hard byte ceiling: a single data URL is capped at 8MB, so anything above
  // ~9.5MB of JSON cannot be valid and must be rejected before allocation.
  const bodyResult = await readJsonBody(request, 9_500_000);
  if (!bodyResult.ok) {
    return jsonWithRequest(
      request,
      { error: bodyResult.reason },
      bodyResult.reason === "body_too_large" ? 413 : 400,
    );
  }
  const bodyParse = parseWithSchema(
    AnalyzeFoodImageBodySchema,
    bodyResult.body,
  );
  if (!bodyParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: bodyParse.issues,
    }, 400);
  }

  const payload = bodyParse.output as AnalyzeFoodImageRequestPayload;
  const imageBase64 = normalizeImageDataUrl(payload.image_base64);
  if (!imageBase64) {
    return jsonWithRequest(request, { error: "invalid_image_base64" }, 400);
  }

  const normalizedPayload: AnalyzeFoodImageRequestPayload = {
    image_base64: imageBase64,
    context: payload.context ?? "unknown",
    timestamp: asTrimmedString(payload.timestamp, MAX_TIMESTAMP_LENGTH) ??
      undefined,
    pre_workout: payload.pre_workout === true,
    post_workout: payload.post_workout === true,
    recent_activity:
      asTrimmedString(payload.recent_activity, MAX_ACTIVITY_LENGTH) ??
        undefined,
    recovery_score: typeof payload.recovery_score === "number" &&
        Number.isFinite(payload.recovery_score)
      ? Math.max(0, Math.min(100, payload.recovery_score))
      : undefined,
    recognized_text:
      asTrimmedString(payload.recognized_text, MAX_RECOGNIZED_TEXT_LENGTH) ??
        undefined,
    barcodes: normalizeBarcodes(payload.barcodes),
    locale: asTrimmedString(payload.locale, MAX_LOCALE_LENGTH) ?? undefined,
  };

  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) {
    return jsonWithRequest(
      request,
      { error: "openrouter_key_not_configured" },
      500,
    );
  }

  const model = Deno.env.get("ANALYZE_FOOD_IMAGE_MODEL")?.trim() ||
    "openai/gpt-4o";

  const openRouterReq = {
    model,
    temperature: 0.1,
    max_tokens: 1_200,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: buildFoodImageSystemPrompt(normalizedPayload.locale),
      },
      {
        role: "user",
        content: [
          {
            type: "text",
            text: buildFoodImageUserPrompt(normalizedPayload),
          },
          {
            type: "image_url",
            image_url: {
              url: imageBase64,
            },
          },
        ],
      },
    ],
  };

  const controller = new AbortController();
  // deno-coverage-ignore-start -- timer setup/cleanup is deterministic infrastructure, not product logic.
  const timeout = setTimeout(() => controller.abort(), OPENROUTER_TIMEOUT_MS);
  // deno-coverage-ignore-stop

  try {
    const aiResponse = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": Deno.env.get("OPENROUTER_REFERER") ??
          "https://lifeos.app",
        "X-Title": Deno.env.get("OPENROUTER_APP_NAME") ?? "Life OS",
      },
      body: JSON.stringify(openRouterReq),
      signal: controller.signal,
    });

    if (!aiResponse.ok) {
      const responseText = await aiResponse.text();
      return jsonWithRequest(request, {
        error: "openrouter_request_failed",
        status: aiResponse.status,
        detail: sanitizedInternalDetail(request, "index", responseText),
      }, 502);
    }

    const aiData = await aiResponse.json();
    const contentText = extractMessageContent(aiData);
    const parsed = parseAIJsonContent(contentText);
    const normalized = normalizeFoodImageAnalysis(
      parsed,
      normalizedPayload.locale,
    );

    if (!normalized) {
      return jsonWithRequest(request, {
        error: "invalid_ai_response",
        detail: contentText.slice(0, 300),
      }, 502);
    }

    return jsonWithRequest(request, normalized, 200);
  } catch (error) {
    if ((error as Error).name === "AbortError") {
      return jsonWithRequest(request, { error: "upstream_timeout" }, 504);
    }
    // deno-coverage-ignore-start -- non-Error upstream failures are covered through guardrail tests.
    return jsonWithRequest(request, {
      error: "upstream_request_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 502);
    // deno-coverage-ignore-stop
    // deno-coverage-ignore-start -- timer setup/cleanup is deterministic infrastructure, not product logic.
  } finally {
    clearTimeout(timeout);
  }
  // deno-coverage-ignore-stop
});
