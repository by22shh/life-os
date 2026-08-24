import { jsonWithRequest } from "../_shared/supabase.ts";
import {
  handleCorsPreflight,
  resolveUserContext,
} from "../_shared/user_context.ts";
import { parseWithSchema } from "../_shared/runtime_schema.ts";
import { ParseFoodTextBodySchema } from "../_shared/payload_schemas.ts";
import {
  createSupabaseFoodsRepository,
  defaultFoodsProvider,
  type FoodSearchResult,
  searchFoods,
} from "../_shared/foods_provider.ts";

const MAX_TEXT_LENGTH = 500;
const MAX_ITEMS = 6;

type MealType = "breakfast" | "lunch" | "dinner" | "snack";
type FoodCategory =
  | "protein"
  | "carbs"
  | "fat"
  | "vegetable"
  | "fruit"
  | "mixed";

interface ParseRequestBody {
  text?: string;
  locale?: string;
  context?: string;
  meal_type?: string;
}

interface ParsedSegment {
  raw: string;
  name: string;
  quantity: number | null;
  unit: string | null;
  weightG: number | null;
  quantityLabel: string | null;
}

interface ResponseItem {
  name: string;
  quantity: number | null;
  unit: string | null;
  category: FoodCategory | null;
  weight_g: number | null;
  calories: number | null;
  protein_g: number | null;
  fat_g: number | null;
  carbs_g: number | null;
  fiber_g: number | null;
  confidence: number | null;
  notes: string | null;
  brand: string | null;
  barcode: string | null;
}

interface ClarifyingQuestion {
  id: string;
  question: string;
  options: string[];
  item_index: number;
  item_name: string;
}

function normalizedText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().replace(/\s+/g, " ");
  if (!trimmed) return null;
  return trimmed.slice(0, MAX_TEXT_LENGTH);
}

function normalizeLocale(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, 32) : null;
}

function normalizeMealType(value: unknown): MealType | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (
    normalized === "breakfast" || normalized === "lunch" ||
    normalized === "dinner" || normalized === "snack"
  ) {
    return normalized;
  }
  return null;
}

function splitIntoSegments(text: string): ParsedSegment[] {
  const normalized = text
    .replace(/\n/g, ",")
    .replace(/\s+(and|with|plus)\s+/gi, ",")
    .replace(/\s*&\s*/g, ",")
    .replace(/\s*\+\s*/g, ",");

  const segments = normalized
    .split(/[;,]/)
    .map((segment) => segment.trim())
    .filter(Boolean)
    .slice(0, MAX_ITEMS);

  return segments
    .map(parseSegment)
    .filter((segment): segment is ParsedSegment => segment !== null);
}

function parseSegment(raw: string): ParsedSegment | null {
  const stripped = raw
    .replace(
      /^(i had|i ate|ate|had|for breakfast|for lunch|for dinner|drank|drink)\s+/i,
      "",
    )
    .trim();
  if (!stripped) return null;

  const weightMatch = stripped.match(
    /^(\d+(?:[.,]\d+)?)\s*(g|gram|grams|ml|cup|cups|tbsp|tsp|oz|ounce|ounces|slice|slices|piece|pieces|egg|eggs)\s+(.+)$/i,
  );
  if (weightMatch) {
    const quantity = Number.parseFloat(weightMatch[1].replace(",", "."));
    // deno-coverage-ignore-start -- regex only captures finite numeric strings before parseFloat.
    const parsedQuantity = Number.isFinite(quantity) ? quantity : null;
    // deno-coverage-ignore-stop
    const unit = weightMatch[2].toLowerCase();
    const name = cleanFoodName(weightMatch[3]);
    if (!name) return null;
    return {
      raw,
      name,
      quantity: parsedQuantity,
      unit,
      // deno-coverage-ignore-start -- null quantity fallback is unreachable after numeric regex capture.
      weightG: parsedQuantity == null
        ? null
        : unitToGrams(parsedQuantity, unit),
      // deno-coverage-ignore-stop
      quantityLabel: `${weightMatch[1]} ${weightMatch[2]}`,
    };
  }

  const countMatch = stripped.match(/^(\d+(?:[.,]\d+)?)\s+(.+)$/);
  if (countMatch) {
    const quantity = Number.parseFloat(countMatch[1].replace(",", "."));
    const parsedQuantity = Number.isFinite(quantity) ? quantity : null;
    const name = cleanFoodName(countMatch[2]);
    if (!name) return null;
    return {
      raw,
      name,
      quantity: parsedQuantity,
      unit: inferredCountUnit(name),
      weightG: parsedQuantity == null
        ? null
        : inferCountWeight(parsedQuantity, name),
      quantityLabel: countMatch[1],
    };
  }

  const name = cleanFoodName(stripped);
  if (!name) return null;
  return {
    raw,
    name,
    quantity: null,
    unit: null,
    weightG: null,
    quantityLabel: null,
  };
}

function cleanFoodName(raw: string): string | null {
  const cleaned = raw
    .replace(/\b(of|the|a|an)\b/gi, " ")
    .replace(/[^\p{L}\p{N}\s-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) return null;

  const words = cleaned.split(" ").filter(Boolean);
  if (words.length > 6) {
    return words.slice(0, 6).join(" ");
  }
  return words.join(" ");
}

function unitToGrams(quantity: number, unit: string): number {
  switch (unit) {
    case "g":
    case "gram":
    case "grams":
    case "ml":
      return quantity;
    case "cup":
    case "cups":
      return quantity * 240;
    case "tbsp":
      return quantity * 15;
    case "tsp":
      return quantity * 5;
    case "oz":
    case "ounce":
    case "ounces":
      return quantity * 28.35;
    case "slice":
    case "slices":
      return quantity * 30;
    case "piece":
    case "pieces":
      return quantity * 100;
    case "egg":
    case "eggs":
      return quantity * 50;
    default:
      return quantity;
  }
}

function inferCountWeight(quantity: number, name: string): number | null {
  const normalized = name.toLowerCase();
  if (normalized.includes("egg")) return quantity * 50;
  if (normalized.includes("banana")) return quantity * 120;
  if (normalized.includes("apple")) return quantity * 180;
  if (normalized.includes("coffee") || normalized.includes("cappuccino")) {
    return quantity * 250;
  }
  return null;
}

function inferredCountUnit(name: string): string {
  const normalized = name.toLowerCase();
  if (
    normalized.includes("egg") || normalized.includes("banana") ||
    normalized.includes("apple") || normalized.includes("toast") ||
    normalized.includes("cookie")
  ) {
    return "piece";
  }
  return "serving";
}

function inferMealType(
  text: string,
  explicit: MealType | null,
): MealType | null {
  if (explicit) return explicit;
  const normalized = text.toLowerCase();
  if (normalized.includes("breakfast")) return "breakfast";
  if (normalized.includes("lunch")) return "lunch";
  if (normalized.includes("dinner")) return "dinner";
  if (normalized.includes("snack")) return "snack";
  return null;
}

function inferCategory(result: FoodSearchResult | null): FoodCategory | null {
  if (!result) return null;
  const macros = result.macros_per_100g;
  if (macros.protein_g >= 18 && macros.protein_g >= macros.carbs_g) {
    return "protein";
  }
  if (macros.carbs_g >= 20 && macros.carbs_g >= macros.fat_g) return "carbs";
  if (macros.fat_g >= 15 && macros.fat_g > macros.carbs_g) return "fat";
  const haystack = `${result.name} ${result.brand ?? ""}`.toLowerCase();
  if (/(salad|broccoli|spinach|cucumber|tomato|vegetable)/.test(haystack)) {
    return "vegetable";
  }
  if (/(banana|apple|berry|fruit|orange|grape)/.test(haystack)) return "fruit";
  return "mixed";
}

function buildSuggestions(
  segments: ParsedSegment[],
  unmatched: string[],
): string[] {
  const suggestions: string[] = [];
  for (const segment of segments) {
    if (!segment.quantityLabel) {
      suggestions.push(`Confirm the serving size for ${segment.name}.`);
    }
    if (suggestions.length === 2) break;
  }
  for (const name of unmatched) {
    if (suggestions.length === 2) break;
    suggestions.push(`Review the nutrition match for ${name}.`);
  }
  return suggestions;
}

function clarificationOptions(segment: ParsedSegment): string[] {
  const normalized = segment.name.toLowerCase();
  if (
    /(pasta|rice|oatmeal|porridge|cereal|soup|salad|noodle|buckwheat|potato)/
      .test(normalized)
  ) {
    return ["1 cup", "2 cups", "3 cups", "I can weigh it"];
  }
  if (
    /(coffee|cappuccino|latte|tea|juice|milk|smoothie|shake)/.test(normalized)
  ) {
    return ["200 ml", "300 ml", "400 ml", "I can measure it"];
  }
  if (
    segment.unit === "piece" ||
    /(egg|banana|apple|toast|cookie)/.test(normalized)
  ) {
    return ["1 piece", "2 pieces", "3 pieces", "I can weigh it"];
  }
  return ["100 g", "200 g", "300 g", "I can weigh it"];
}

function questionId(name: string, index: number): string {
  const slug = name
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 24);
  return `${slug || "item"}_${index}`;
}

function buildClarifyingQuestions(
  segments: ParsedSegment[],
  items: ResponseItem[],
): ClarifyingQuestion[] {
  const questions: ClarifyingQuestion[] = [];

  for (const [index, segment] of segments.entries()) {
    if (questions.length >= 2) break;
    const item = items[index];
    const needsServingClarification = segment.quantityLabel == null;
    const needsMatchClarification = item?.calories == null;
    if (!needsServingClarification && !needsMatchClarification) continue;

    const question = needsServingClarification
      ? `About how much ${segment.name} was it?`
      : `Please review the nutrition match for ${segment.name}.`;

    questions.push({
      id: questionId(segment.name, index),
      question,
      options: clarificationOptions(segment),
      item_index: index,
      item_name: segment.name,
    });
  }

  return questions;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

export const __parseFoodTextTestHooks = {
  buildClarifyingQuestions,
  buildSuggestions,
  clamp,
  cleanFoodName,
  clarificationOptions,
  inferCategory,
  inferCountWeight,
  inferMealType,
  inferredCountUnit,
  normalizeLocale,
  normalizeMealType,
  normalizedText,
  parseSegment,
  questionId,
  splitIntoSegments,
  unitToGrams,
};

Deno.serve(async (request) => {
  const preflight = handleCorsPreflight(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonWithRequest(request, { error: "method_not_allowed" }, 405);
  }

  const userResult = await resolveUserContext(request, "ai_parse");
  if (!userResult.ok) return userResult.response;

  let bodyRaw: unknown;
  try {
    bodyRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }

  const bodyParse = parseWithSchema(ParseFoodTextBodySchema, bodyRaw);
  if (!bodyParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: bodyParse.issues,
    }, 400);
  }

  const payload = bodyParse.output as ParseRequestBody;
  const text = normalizedText(payload.text);
  if (!text) {
    return jsonWithRequest(request, { error: "text_required" }, 400);
  }

  const locale = normalizeLocale(payload.locale);
  const mealType = inferMealType(text, normalizeMealType(payload.meal_type));
  const segments = splitIntoSegments(text);
  if (segments.length === 0) {
    return jsonWithRequest(request, {
      items: [],
      detected_items: [],
      total_macros: null,
      meal_type: mealType,
      confidence: 0.2,
      needs_clarification: true,
      clarifying_questions: [],
      warnings: ["We couldn't detect any food items from that text yet."],
      suggestions: ["Try listing foods separated by commas."],
      context_analysis: "No structured foods detected from the text.",
    });
  }

  const repository = createSupabaseFoodsRepository(userResult.context.service);
  const provider = defaultFoodsProvider();

  const items: ResponseItem[] = [];
  const unmatched: string[] = [];

  for (const segment of segments) {
    let best: FoodSearchResult | null = null;
    try {
      const search = await searchFoods({
        repository,
        provider,
        userId: userResult.context.userId,
        query: segment.name,
        limit: 3,
        locale,
        providerSearchEnabled: true,
      });
      best = search.results[0] ?? null;
    } catch {
      best = null;
    }

    const weightG = segment.weightG ?? best?.serving_size_g ?? 100;

    if (!best) {
      unmatched.push(segment.name);
      items.push({
        name: segment.name,
        quantity: segment.quantity,
        unit: segment.unit,
        category: null,
        weight_g: segment.weightG,
        calories: null,
        protein_g: null,
        fat_g: null,
        carbs_g: null,
        fiber_g: null,
        confidence: 0.42,
        notes: segment.quantityLabel
          ? `Estimated from "${segment.quantityLabel}".`
          : "No catalog nutrition match found yet.",
        brand: null,
        barcode: null,
      });
      continue;
    }

    const ratio = weightG / 100;
    const macros = best.macros_per_100g;
    const confidence = clamp(
      // deno-coverage-ignore-start -- tag derivation is covered in foods provider ranking tests.
      0.62 + (segment.quantityLabel ? 0.16 : 0) +
        (best.tags.includes("favorite") ? 0.05 : 0) +
        (best.tags.includes("provider") ? 0.03 : 0),
      // deno-coverage-ignore-stop
      0.5,
      0.95,
    );

    items.push({
      name: best.name,
      quantity: segment.quantity,
      unit: segment.unit,
      category: inferCategory(best),
      weight_g: weightG,
      calories: Math.round(macros.calories * ratio * 10) / 10,
      protein_g: Math.round(macros.protein_g * ratio * 10) / 10,
      fat_g: Math.round(macros.fat_g * ratio * 10) / 10,
      carbs_g: Math.round(macros.carbs_g * ratio * 10) / 10,
      fiber_g: macros.fiber_g == null
        ? null
        : Math.round(macros.fiber_g * ratio * 10) / 10,
      confidence,
      notes: segment.quantityLabel
        ? `Serving parsed from "${segment.quantityLabel}".`
        : "Serving estimated from the default portion.",
      brand: best.brand,
      barcode: best.barcode,
    });
  }

  const matchedCount = items.filter((item) => item.calories != null).length;
  const explicitServingCount = segments.filter((segment) =>
    segment.quantityLabel != null
  ).length;
  const warnings: string[] = [];
  if (unmatched.length > 0) {
    warnings.push(`Review unmatched items: ${unmatched.join(", ")}.`);
  }
  if (explicitServingCount < segments.length) {
    warnings.push("Some serving sizes were estimated from default portions.");
  }

  const suggestions = buildSuggestions(segments, unmatched);
  const clarifyingQuestions = buildClarifyingQuestions(segments, items);
  const needsClarification = clarifyingQuestions.length > 0;
  if (needsClarification) {
    warnings.push(
      "Review the meal before saving because some portions still need confirmation.",
    );
  }
  const totalMacros = items.some((item) => item.calories != null)
    ? {
      calories: Math.round(
        items.reduce((sum, item) => sum + (item.calories ?? 0), 0) * 10,
      ) / 10,
      protein_g: Math.round(
        items.reduce((sum, item) => sum + (item.protein_g ?? 0), 0) * 10,
      ) / 10,
      fat_g: Math.round(
        items.reduce((sum, item) => sum + (item.fat_g ?? 0), 0) * 10,
      ) / 10,
      carbs_g: Math.round(
        items.reduce((sum, item) => sum + (item.carbs_g ?? 0), 0) * 10,
      ) / 10,
      fiber_g: Math.round(
        items.reduce((sum, item) => sum + (item.fiber_g ?? 0), 0) * 10,
      ) / 10,
    }
    : null;

  const confidence = clamp(
    0.45 +
      (matchedCount / segments.length) * 0.35 +
      (explicitServingCount / segments.length) * 0.20 -
      (unmatched.length > 0 ? 0.08 : 0) -
      (needsClarification ? 0.08 : 0),
    0.35,
    0.95,
  );

  return jsonWithRequest(request, {
    items,
    detected_items: items,
    total_macros: totalMacros,
    meal_type: mealType,
    confidence: Math.round(confidence * 100) / 100,
    needs_clarification: needsClarification,
    clarifying_questions: clarifyingQuestions,
    warnings,
    suggestions,
    context_analysis:
      `Parsed ${segments.length} item${
        segments.length == 1 ? "" : "s"
      } from the text. ` +
      `${matchedCount} matched nutrition data; ${
        segments.length - matchedCount
      } still need review.`,
  });
});
