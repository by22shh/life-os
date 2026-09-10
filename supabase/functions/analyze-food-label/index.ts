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
import { AnalyzeFoodLabelBodySchema } from "../_shared/payload_schemas.ts";
import { readJsonBody } from "../_shared/request_limits.ts";
import { parseAIJsonContent } from "../_shared/food_image_analysis.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TIMEOUT_MS = 20_000;
const MAX_IMAGE_DATA_URL_LENGTH = 8_000_000;
const MAX_LABEL_IMAGES = 3;
const MAX_WARNING_LENGTH = 200;
const MAX_WARNINGS = 6;

interface FoodLabelResponse {
  barcode: string | null;
  name: string | null;
  brand: string | null;
  serving_size_g: number | null;
  macros_per_100g: {
    calories: number | null;
    protein_g: number | null;
    fat_g: number | null;
    carbs_g: number | null;
    fiber_g: number | null;
    sugar_g: number | null;
    sodium_mg: number | null;
  };
  confidence: number;
  warnings: string[];
  needs_review: true;
}

function asTrimmedString(value: unknown, maxLength: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.length <= maxLength ? trimmed : trimmed.slice(0, maxLength);
}

function normalizeImageDataUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_IMAGE_DATA_URL_LENGTH) return null;
  if (!trimmed.startsWith("data:image/")) return null;
  if (!trimmed.includes(";base64,")) return null;
  return trimmed;
}

function normalizeBarcode(value: unknown): string | null {
  const cleaned = asTrimmedString(value, 64);
  if (!cleaned) return null;
  return cleaned;
}

function normalizeLocale(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed.slice(0, 32);
}

function roundValue(value: number, decimals: number): number {
  const factor = 10 ** decimals;
  return Math.round(value * factor) / factor;
}

function normalizeMacro(
  value: unknown,
  min: number,
  max: number,
  decimals: number,
): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const clamped = Math.min(max, Math.max(min, value));
  return roundValue(clamped, decimals);
}

function asConfidence(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return 0.5;
  }
  return Math.min(1, Math.max(0, value));
}

function cleanWarnings(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const result: string[] = [];
  for (const entry of value) {
    const warning = asTrimmedString(entry, MAX_WARNING_LENGTH);
    if (!warning) continue;
    const key = warning.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(warning);
    if (result.length >= MAX_WARNINGS) break;
  }
  return result;
}

function localizedNarrativeLanguage(locale: string | null): string {
  if (!locale) return "the user's preferred language";
  const lowered = locale.toLowerCase();
  if (lowered.startsWith("ru")) return "Russian";
  if (lowered.startsWith("en")) return "English";
  return locale;
}

function buildFoodLabelSystemPrompt(locale: string | null): string {
  const language = localizedNarrativeLanguage(locale);
  return `You are an expert nutrition label parser for Life OS.

Return ONLY valid JSON. No markdown, no code fences, no commentary outside of the requested structure.

Output MUST follow this exact schema:
{
  "barcode": "string",
  "name": "string|null",
  "brand": "string|null",
  "serving_size_g": number|null,
  "macros_per_100g": {
    "calories": number|null,
    "protein_g": number|null,
    "fat_g": number|null,
    "carbs_g": number|null,
    "fiber_g": number|null,
    "sugar_g": number|null,
    "sodium_mg": number|null
  },
  "confidence": number,
  "warnings": ["string"],
  "needs_review": true
}

Rules:
1. Prefer per-100g values; if only per-serving values are visible, mention the serving size and set lower confidence.
2. Support CIS-style labels (Белки/Жиры/Углеводы, ккал/кДж, соль/натрий).
3. Do not invent fiber, sugar, or sodium values if the label does not include them; use null instead.
4. If you only see kJ, convert to kcal using kcal = kJ / 4.184 and add warning "Calories converted from kJ".
5. If the label lists salt (NaCl) but not sodium, derive sodium_mg using salt_g * 1000 * 0.393 and add warning "Sodium derived from salt".
6. Always set needs_review to true; the client will double-check before saving.
7. Keep narrative fields in ${language}.`;
}

function buildFoodLabelUserPrompt(
  barcode: string | null,
  locale: string | null,
  imageCount: number,
): string {
  const data = {
    barcode: barcode ?? "unknown",
    locale: locale ?? "unknown",
  };
  return [
    "Extract nutrition from these label photos.",
    "",
    "DATA:",
    JSON.stringify(data, null, 2),
    "",
    `IMAGES: ${imageCount} label photo${
      imageCount === 1 ? "" : "s"
    } are attached.`,
  ].join("\n");
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

function normalizeFoodLabelResponse(
  raw: unknown,
  fallbackBarcode: string | null,
): FoodLabelResponse | null {
  if (!raw || typeof raw !== "object") return null;
  const record = raw as Record<string, unknown>;
  const macrosRecord = record.macros_per_100g as
    | Record<string, unknown>
    | undefined;

  const warnings = cleanWarnings(record.warnings);
  if (warnings.length === 0) {
    warnings.push("Nutrition label output requires manual review.");
  }

  return {
    barcode: fallbackBarcode,
    name: asTrimmedString(record.name, 128),
    brand: asTrimmedString(record.brand, 128),
    serving_size_g: normalizeMacro(record.serving_size_g, 1, 2_000, 0),
    macros_per_100g: {
      calories: normalizeMacro(macrosRecord?.["calories"], 0, 5_000, 0),
      protein_g: normalizeMacro(macrosRecord?.["protein_g"], 0, 500, 1),
      fat_g: normalizeMacro(macrosRecord?.["fat_g"], 0, 500, 1),
      carbs_g: normalizeMacro(macrosRecord?.["carbs_g"], 0, 500, 1),
      fiber_g: normalizeMacro(macrosRecord?.["fiber_g"], 0, 200, 1),
      sugar_g: normalizeMacro(macrosRecord?.["sugar_g"], 0, 500, 1),
      sodium_mg: normalizeMacro(macrosRecord?.["sodium_mg"], 0, 5_000, 0),
    },
    confidence: roundValue(
      Math.min(1, Math.max(0, asConfidence(record.confidence))),
      2,
    ),
    warnings,
    needs_review: true,
  };
}

export const __analyzeFoodLabelTestHooks = {
  asConfidence,
  asTrimmedString,
  buildFoodLabelSystemPrompt,
  buildFoodLabelUserPrompt,
  cleanWarnings,
  extractMessageContent,
  localizedNarrativeLanguage,
  normalizeBarcode,
  normalizeFoodLabelResponse,
  normalizeImageDataUrl,
  normalizeLocale,
  normalizeMacro,
  roundValue,
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
  const { data: userRow, error: lookupError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (lookupError) {
    return jsonWithRequest(request, {
      error: "user_lookup_failed",
      detail: sanitizedInternalDetail(request, "index", lookupError),
    }, 500);
  }
  if (!userRow) {
    return jsonWithRequest(request, { error: "user_not_found" }, 404);
  }

  const rateLimited = await enforceRateLimit(request, userRow.id, "ai_parse");
  if (rateLimited) {
    return rateLimited;
  }

  const consentBlocked = await enforceAIProcessingConsent(
    service,
    userRow.id,
  );
  if (consentBlocked) return consentBlocked;

  // Hard byte ceiling: up to MAX_LABEL_IMAGES data URLs of 8MB each, so
  // anything above ~26MB of JSON cannot be valid and must be rejected
  // before allocation.
  const bodyResult = await readJsonBody(request, 26_000_000);
  if (!bodyResult.ok) {
    return jsonWithRequest(
      request,
      { error: bodyResult.reason },
      bodyResult.reason === "body_too_large" ? 413 : 400,
    );
  }
  const parsed = parseWithSchema(AnalyzeFoodLabelBodySchema, bodyResult.body);
  if (!parsed.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: parsed.issues,
    }, 400);
  }

  const payload = parsed.output;
  const barcode = normalizeBarcode(payload.barcode);
  const locale = normalizeLocale(payload.locale);

  const normalizedImages = payload.images_base64
    .map(normalizeImageDataUrl)
    .filter((value): value is string => value != null)
    .slice(0, MAX_LABEL_IMAGES);

  if (normalizedImages.length === 0) {
    return jsonWithRequest(request, { error: "label_images_required" }, 400);
  }

  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) {
    return jsonWithRequest(
      request,
      { error: "openrouter_key_not_configured" },
      500,
    );
  }

  const model = Deno.env.get("ANALYZE_FOOD_LABEL_MODEL")?.trim() ||
    "openai/gpt-4o";

  const openRouterReq = {
    model,
    temperature: 0.1,
    max_tokens: 1_000,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: buildFoodLabelSystemPrompt(locale),
      },
      {
        role: "user",
        content: [
          {
            type: "text",
            text: buildFoodLabelUserPrompt(
              barcode,
              locale,
              normalizedImages.length,
            ),
          },
          ...normalizedImages.map((image) => ({
            type: "image_url",
            image_url: { url: image },
          })),
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
      const detail = await aiResponse.text();
      return jsonWithRequest(request, {
        error: "openrouter_request_failed",
        status: aiResponse.status,
        detail: sanitizedInternalDetail(request, "index", detail),
      }, 502);
    }

    const aiData = await aiResponse.json();
    const contentText = extractMessageContent(aiData);
    const parsedContent = parseAIJsonContent(contentText);
    const normalized = normalizeFoodLabelResponse(parsedContent, barcode);

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
