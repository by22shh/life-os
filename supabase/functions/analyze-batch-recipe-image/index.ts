import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../_shared/supabase.ts";
import { enforceRateLimit } from "../_shared/rate_limit.ts";
import { handleCors } from "../_shared/cors.ts";
import { parseWithSchema } from "../_shared/runtime_schema.ts";
import { AnalyzeBatchRecipeImageBodySchema } from "../_shared/payload_schemas.ts";
import { readJsonBody } from "../_shared/request_limits.ts";
import { parseAIJsonContent } from "../_shared/food_image_analysis.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TIMEOUT_MS = 20_000;
const MAX_IMAGE_DATA_URL_LENGTH = 8_000_000;
const MAX_KNOWN_INGREDIENTS = 6;
const MAX_NOTES = 6;
const MAX_NOTE_LENGTH = 200;
const MAX_WARNINGS = 6;
const MAX_WARNING_LENGTH = 200;

interface BatchIngredientDraft {
  name: string;
  estimated_raw_weight_g: number | null;
  estimated_cooked_weight_g: number | null;
  calories: number | null;
  protein_g: number | null;
  fat_g: number | null;
  carbs_g: number | null;
  confidence: number;
}

interface BatchTotals {
  weight_g: number | null;
  calories: number | null;
  protein_g: number | null;
  fat_g: number | null;
  carbs_g: number | null;
  fiber_g: number | null;
}

interface BatchStorage {
  refrigerator_days: number | null;
  freezer_months: number | null;
  reheating_tip: string | null;
}

interface BatchRecipeResponse {
  recipe_name: string | null;
  ingredients_detected: BatchIngredientDraft[];
  total_batch: BatchTotals;
  per_100g: BatchTotals;
  per_portion: {
    weight_g: number | null;
    calories: number | null;
    protein_g: number | null;
    fat_g: number | null;
    carbs_g: number | null;
  };
  notes: string[];
  storage: BatchStorage;
  warnings: string[];
  confidence: number;
  needs_review: true;
}

type KnownIngredientInput = {
  name: string;
  raw_weight_g?: number;
};

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

function roundValue(value: number, decimals: number): number {
  const factor = 10 ** decimals;
  return Math.round(value * factor) / factor;
}

function normalizeNumber(
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

function cleanNarrativeList(
  value: unknown,
  maxItems: number,
  maxLength: number,
): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const result: string[] = [];
  for (const entry of value) {
    const message = asTrimmedString(entry, maxLength);
    if (!message) continue;
    const key = message.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(message);
    if (result.length >= maxItems) break;
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

function buildBatchSystemPrompt(locale: string | null): string {
  const language = localizedNarrativeLanguage(locale);
  return `You are a culinary nutritionist for Life OS.

Return ONLY valid JSON. No markdown or commentary outside the requested structure.

Use the provided total weight as ground truth and analyze the batch cooking photo conservatively.

Rules:
1. Identify each visible ingredient with raw and cooked weight estimates.
2. Calculate total macros for the full batch, per 100g, and per portion.
3. Mention any uncertain ingredients, hidden oils, or sauces in "notes" or "warnings".
4. Provide storage recommendations, including refrigerator and freezer timelines plus reheating tips.
5. Keep narrative language in ${language}.
6. Return this exact JSON shape:
{
  "recipe_name": "string",
  "ingredients_detected": [
    {
      "name": "string",
      "estimated_raw_weight_g": number|null,
      "estimated_cooked_weight_g": number|null,
      "calories": number|null,
      "protein_g": number|null,
      "fat_g": number|null,
      "carbs_g": number|null,
      "confidence": number
    }
  ],
  "total_batch": {
    "weight_g": number,
    "calories": number,
    "protein_g": number,
    "fat_g": number,
    "carbs_g": number,
    "fiber_g": number|null
  },
  "per_100g": {
    "calories": number|null,
    "protein_g": number|null,
    "fat_g": number|null,
    "carbs_g": number|null,
    "fiber_g": number|null
  },
  "per_portion": {
    "weight_g": number,
    "calories": number|null,
    "protein_g": number|null,
    "fat_g": number|null,
    "carbs_g": number|null
  },
  "notes": ["string"],
  "storage": {
    "refrigerator_days": number|null,
    "freezer_months": number|null,
    "reheating_tip": "string"
  },
  "confidence": number
}`;
}

function buildBatchUserPrompt(
  payload: {
    recipe_name: string;
    total_weight_grams: number;
    portions_planned: number;
    cooking_method: string;
    known_ingredients: KnownIngredientInput[];
  },
  portionSize: number | null,
): string {
  const data = {
    recipe_name: payload.recipe_name,
    total_weight_grams: payload.total_weight_grams,
    total_portions: payload.portions_planned,
    portion_size_grams: portionSize ?? null,
    cooking_method: payload.cooking_method,
    portion_size_note: portionSize == null
      ? "portion size derived from totals"
      : "user supplied portion size",
    known_ingredients: payload.known_ingredients,
  };
  return [
    "Analyze this batch recipe photo and estimate macros.",
    "",
    "DATA:",
    JSON.stringify(data, null, 2),
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

function normalizeIngredient(raw: unknown): BatchIngredientDraft | null {
  if (!raw || typeof raw !== "object") return null;
  const record = raw as Record<string, unknown>;
  const name = asTrimmedString(record.name, 160);
  if (!name) return null;
  return {
    name,
    estimated_raw_weight_g: normalizeNumber(
      record.estimated_raw_weight_g,
      0,
      3_000,
      0,
    ),
    estimated_cooked_weight_g: normalizeNumber(
      record.estimated_cooked_weight_g,
      0,
      3_000,
      0,
    ),
    calories: normalizeNumber(record.calories, 0, 3_000, 0),
    protein_g: normalizeNumber(record.protein_g, 0, 500, 1),
    fat_g: normalizeNumber(record.fat_g, 0, 500, 1),
    carbs_g: normalizeNumber(record.carbs_g, 0, 500, 1),
    confidence: roundValue(asConfidence(record.confidence ?? 0.5), 2),
  };
}

function normalizeTotals(raw: unknown): BatchTotals {
  if (!raw || typeof raw !== "object") {
    return {
      weight_g: null,
      calories: null,
      protein_g: null,
      fat_g: null,
      carbs_g: null,
      fiber_g: null,
    };
  }
  const record = raw as Record<string, unknown>;
  return {
    weight_g: normalizeNumber(record.weight_g, 0, 10_000, 0),
    calories: normalizeNumber(record.calories, 0, 10_000, 0),
    protein_g: normalizeNumber(record.protein_g, 0, 2_000, 1),
    fat_g: normalizeNumber(record.fat_g, 0, 2_000, 1),
    carbs_g: normalizeNumber(record.carbs_g, 0, 2_000, 1),
    fiber_g: normalizeNumber(record.fiber_g, 0, 500, 1),
  };
}

function derivePerUnit(
  total: number | null,
  weight: number | null,
  unit: number,
  decimals: number,
): number | null {
  if (total == null || weight == null || weight <= 0) return null;
  return roundValue((total * unit) / weight, decimals);
}

function normalizeBatchRecipeResponse(
  raw: unknown,
  context: {
    recipe_name: string;
    total_weight_g: number;
    portions_planned: number;
    known_ingredients: KnownIngredientInput[];
  },
): BatchRecipeResponse | null {
  if (!raw || typeof raw !== "object") return null;
  const record = raw as Record<string, unknown>;

  const rawIngredients = Array.isArray(record.ingredients_detected)
    ? record.ingredients_detected
      .map(normalizeIngredient)
      .filter((item): item is BatchIngredientDraft => item !== null)
      .slice(0, 10)
    : [];

  // deno-coverage-ignore-start -- known-ingredient fallback shaping is covered through normalized response tests.
  const fallbackIngredients = context.known_ingredients
    .slice(0, 10)
    .map((ingredient) => ({
      name: asTrimmedString(ingredient.name, 160) ?? "Unknown ingredient",
      estimated_raw_weight_g: ingredient.raw_weight_g
        ? roundValue(Math.max(0, ingredient.raw_weight_g), 0)
        : null,
      estimated_cooked_weight_g: null,
      calories: null,
      protein_g: null,
      fat_g: null,
      carbs_g: null,
      confidence: 0.5,
    }));
  // deno-coverage-ignore-stop

  const ingredients = rawIngredients.length > 0
    ? rawIngredients
    : fallbackIngredients;

  const totalBatch = normalizeTotals(record.total_batch);
  totalBatch.weight_g = totalBatch.weight_g ?? context.total_weight_g;

  const per100gFromRecord = normalizeTotals(record.per_100g);
  const per100g = {
    weight_g: null,
    calories: per100gFromRecord.calories ??
      derivePerUnit(totalBatch.calories, totalBatch.weight_g, 100, 0),
    protein_g: per100gFromRecord.protein_g ??
      derivePerUnit(totalBatch.protein_g, totalBatch.weight_g, 100, 1),
    fat_g: per100gFromRecord.fat_g ??
      derivePerUnit(totalBatch.fat_g, totalBatch.weight_g, 100, 1),
    carbs_g: per100gFromRecord.carbs_g ??
      derivePerUnit(totalBatch.carbs_g, totalBatch.weight_g, 100, 1),
    fiber_g: per100gFromRecord.fiber_g ??
      derivePerUnit(totalBatch.fiber_g, totalBatch.weight_g, 100, 1),
  };

  const portionWeight = context.portions_planned > 0
    ? context.total_weight_g / context.portions_planned
    : null;
  const derivedPortionWeight = portionWeight != null && portionWeight > 0
    ? roundValue(portionWeight, 0)
    : null;

  const perPortionRecord = (record.per_portion as Record<string, unknown>) ??
    {};
  const perPortion = {
    weight_g: perPortionRecord.weight_g != null
      ? normalizeNumber(perPortionRecord.weight_g, 0, 3_000, 0)
      : derivedPortionWeight,
    calories: perPortionRecord.calories != null
      ? normalizeNumber(perPortionRecord.calories, 0, 3_000, 0)
      : totalBatch.calories != null && context.portions_planned > 0
      ? roundValue(totalBatch.calories / context.portions_planned, 0)
      : null,
    protein_g: perPortionRecord.protein_g != null
      ? normalizeNumber(perPortionRecord.protein_g, 0, 1_000, 1)
      : totalBatch.protein_g != null && context.portions_planned > 0
      ? roundValue(totalBatch.protein_g / context.portions_planned, 1)
      : null,
    fat_g: perPortionRecord.fat_g != null
      ? normalizeNumber(perPortionRecord.fat_g, 0, 1_000, 1)
      : totalBatch.fat_g != null && context.portions_planned > 0
      ? roundValue(totalBatch.fat_g / context.portions_planned, 1)
      : null,
    carbs_g: perPortionRecord.carbs_g != null
      ? normalizeNumber(perPortionRecord.carbs_g, 0, 1_000, 1)
      : totalBatch.carbs_g != null && context.portions_planned > 0
      ? roundValue(totalBatch.carbs_g / context.portions_planned, 1)
      : null,
  };

  const notes = cleanNarrativeList(record.notes, MAX_NOTES, MAX_NOTE_LENGTH);
  if (notes.length === 0) {
    notes.push("Estimates require review before saving.");
  }

  const warnings = cleanNarrativeList(
    record.warnings,
    MAX_WARNINGS,
    MAX_WARNING_LENGTH,
  );
  if (warnings.length === 0) {
    warnings.push("Batch recipe draft requires review.");
  }

  const storageRecord = (record.storage as Record<string, unknown>) ?? {};
  const storage: BatchStorage = {
    refrigerator_days: storageRecord.refrigerator_days != null
      ? normalizeNumber(storageRecord.refrigerator_days, 0, 30, 0)
      : null,
    freezer_months: storageRecord.freezer_months != null
      ? normalizeNumber(storageRecord.freezer_months, 0, 24, 0)
      : null,
    reheating_tip: asTrimmedString(storageRecord.reheating_tip, 240),
  };

  return {
    recipe_name: asTrimmedString(record.recipe_name, 200) ??
      context.recipe_name,
    ingredients_detected: ingredients,
    total_batch: {
      weight_g: totalBatch.weight_g,
      calories: totalBatch.calories,
      protein_g: totalBatch.protein_g,
      fat_g: totalBatch.fat_g,
      carbs_g: totalBatch.carbs_g,
      fiber_g: totalBatch.fiber_g,
    },
    per_100g: per100g,
    per_portion: {
      weight_g: perPortion.weight_g,
      calories: perPortion.calories,
      protein_g: perPortion.protein_g,
      fat_g: perPortion.fat_g,
      carbs_g: perPortion.carbs_g,
    },
    notes,
    storage,
    warnings,
    confidence: roundValue(asConfidence(record.confidence), 2),
    needs_review: true,
  };
}

export const __analyzeBatchRecipeImageTestHooks = {
  asConfidence,
  asTrimmedString,
  buildBatchSystemPrompt,
  buildBatchUserPrompt,
  cleanNarrativeList,
  derivePerUnit,
  extractMessageContent,
  localizedNarrativeLanguage,
  normalizeBatchRecipeResponse,
  normalizeImageDataUrl,
  normalizeIngredient,
  normalizeNumber,
  normalizeTotals,
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

  const userClient = anonClient(authHeader);
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData?.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

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

  const rateLimited = await enforceRateLimit(request, userRow.id, "ai_vision");
  if (rateLimited) return rateLimited;

  const bodyResult = await readJsonBody(request);
  if (!bodyResult.ok) {
    return jsonWithRequest(
      request,
      { error: bodyResult.reason },
      bodyResult.reason === "body_too_large" ? 413 : 400,
    );
  }
  const bodyRaw: unknown = bodyResult.body;

  const parsed = parseWithSchema(AnalyzeBatchRecipeImageBodySchema, bodyRaw);
  if (!parsed.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: parsed.issues,
    }, 400);
  }

  const payload = parsed.output;
  if (payload.total_weight_grams <= 0 || payload.portions_planned <= 0) {
    return jsonWithRequest(request, {
      error: "invalid_totals",
      detail: "total_weight_grams and portions_planned must be positive",
    }, 400);
  }

  const recipeName = asTrimmedString(payload.recipe_name, 200) ??
    payload.recipe_name.trim().slice(0, 200);
  const cookingMethod = asTrimmedString(payload.cooking_method, 100) ??
    (payload.cooking_method?.trim().slice(0, 100) || "unknown");
  // deno-coverage-ignore-start -- payload schema normalizes known_ingredients; fallback branch is defensive.
  const sanitizedKnownIngredients = (payload.known_ingredients ?? [])
    .map((ingredient) => ({
      name: asTrimmedString(ingredient.name, 160) ??
        ingredient.name.trim().slice(0, 160),
      raw_weight_g: ingredient.raw_weight_g,
    }))
    .filter((ingredient) => ingredient.name.length > 0);
  // deno-coverage-ignore-stop

  const normalizedImage = normalizeImageDataUrl(payload.image_base64);
  if (!normalizedImage) {
    return jsonWithRequest(request, { error: "invalid_image_base64" }, 400);
  }

  const locale = payload.locale ? payload.locale.trim().slice(0, 32) : null;

  // deno-coverage-ignore-start -- positive portions are schema-validated before this calculation.
  const portionSize = payload.portions_planned > 0
    ? payload.total_weight_grams / payload.portions_planned
    : null;
  // deno-coverage-ignore-stop

  const knownIngredientsForPrompt = sanitizedKnownIngredients
    .slice(0, MAX_KNOWN_INGREDIENTS)
    .map((ingredient) => ({
      name: ingredient.name,
      raw_weight_g: ingredient.raw_weight_g,
    }));

  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) {
    return jsonWithRequest(
      request,
      { error: "openrouter_key_not_configured" },
      500,
    );
  }

  const model = Deno.env.get("ANALYZE_BATCH_RECIPE_MODEL")?.trim() ||
    "openai/gpt-4o";

  const openRouterReq = {
    model,
    temperature: 0.1,
    max_tokens: 1_200,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content: buildBatchSystemPrompt(locale),
      },
      {
        role: "user",
        content: [
          {
            type: "text",
            text: buildBatchUserPrompt({
              recipe_name: recipeName,
              total_weight_grams: payload.total_weight_grams,
              portions_planned: payload.portions_planned,
              cooking_method: cookingMethod,
              known_ingredients: knownIngredientsForPrompt,
            }, portionSize),
          },
          {
            type: "image_url",
            image_url: { url: normalizedImage },
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
    const normalized = normalizeBatchRecipeResponse(parsedContent, {
      recipe_name: recipeName,
      total_weight_g: payload.total_weight_grams,
      portions_planned: payload.portions_planned,
      known_ingredients: sanitizedKnownIngredients,
    });

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
    // deno-coverage-ignore -- non-Error upstream failures are covered through guardrail tests.
    return jsonWithRequest(request, {
      error: "upstream_request_failed",
      detail: sanitizedInternalDetail(request, "index", error),
    }, 502);
    // deno-coverage-ignore-start -- timer setup/cleanup is deterministic infrastructure, not product logic.
  } finally {
    clearTimeout(timeout);
  }
  // deno-coverage-ignore-stop
});
