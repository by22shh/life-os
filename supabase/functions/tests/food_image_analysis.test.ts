import {
  assertEquals,
  assertExists,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  buildFoodImageSystemPrompt,
  buildFoodImageUserPrompt,
  normalizeFoodImageAnalysis,
  parseAIJsonContent,
} from "../_shared/food_image_analysis.ts";

Deno.test("parseAIJsonContent unwraps fenced json", () => {
  const parsed = parseAIJsonContent(
    '```json\n{"confidence":0.91,"detected_items":[]}\n```',
  ) as Record<string, unknown> | null;

  assertExists(parsed);
  assertEquals(parsed?.confidence, 0.91);
  assertEquals(parseAIJsonContent("   "), null);
  assertEquals(parseAIJsonContent("```json\nnot json\n```"), null);
});

Deno.test("normalizeFoodImageAnalysis clamps macros and infers totals from items", () => {
  const normalized = normalizeFoodImageAnalysis({
    detected_items: [
      {
        name: "Chicken breast",
        category: "protein",
        weight_g: 150.2,
        calories: 248.4,
        protein_g: 46.2,
        fat_g: 5.1,
        carbs_g: 0,
        fiber_g: 0,
        confidence: 1.3,
        notes: "Visible grill marks",
      },
      {
        name: "Rice",
        category: "carbs",
        weight_g: 120,
        calories: 156,
        protein_g: 3.2,
        fat_g: 0.4,
        carbs_g: 34.6,
        fiber_g: 0.5,
        confidence: 0.81,
      },
    ],
    total_macros: {
      calories: 0,
      protein_g: 0,
      fat_g: 0,
      carbs_g: 0,
      fiber_g: 0,
    },
    confidence: 0.86,
    warnings: ["  Hidden oil likely  ", "hidden oil likely"],
    suggestions: ["Add vegetables"],
    context_analysis: "",
    meal_type: "dinner",
  }, "en-US");

  assertExists(normalized);
  assertEquals(normalized?.detected_items.length, 2);
  assertEquals(normalized?.detected_items[0].weight_g, 150);
  assertEquals(normalized?.detected_items[0].confidence, 1);
  assertEquals(normalized?.total_macros.calories, 404);
  assertEquals(normalized?.warnings, ["Hidden oil likely"]);
  assertEquals(normalized?.meal_type, "dinner");
  assertEquals(
    normalized?.context_analysis,
    "Estimated meal from the photo: Chicken breast, Rice. Approximate portion energy is 404 kcal.",
  );
});

Deno.test("normalizeFoodImageAnalysis rejects malformed payloads and localizes fallback narratives", () => {
  assertEquals(normalizeFoodImageAnalysis(null), null);
  assertEquals(normalizeFoodImageAnalysis("not-an-object"), null);

  const fallbackOnly = normalizeFoodImageAnalysis({
    detected_items: [
      null,
      { name: "   " },
      {
        name: "  Овсянка  ",
        category: "dessert",
        weight_g: Number.NaN,
        calories: 210.8,
        protein_g: 7.16,
        fat_g: 4.24,
        carbs_g: 35.91,
        fiber_g: 5.36,
        confidence: "high",
        notes: 42,
      },
    ],
    total_macros: {
      calories: 320,
      protein_g: 8.4,
      fat_g: 5.1,
      carbs_g: 44.2,
      fiber_g: 6.6,
    },
    meal_type: "late supper",
    confidence: Number.POSITIVE_INFINITY,
    warnings: "not-an-array",
    suggestions: Array.from(
      { length: 8 },
      (_, index) => index === 0 ? "  Добавить ягоды  " : `Совет ${index}`,
    ),
  }, "ru-RU");

  assertExists(fallbackOnly);
  assertEquals(fallbackOnly?.detected_items.length, 1);
  assertEquals(fallbackOnly?.detected_items[0], {
    name: "Овсянка",
    category: "mixed",
    weight_g: 100,
    calories: 211,
    protein_g: 7.2,
    fat_g: 4.2,
    carbs_g: 35.9,
    fiber_g: 5.4,
    confidence: 0.5,
    notes: null,
  });
  assertEquals(fallbackOnly?.total_macros.calories, 320);
  assertEquals(fallbackOnly?.meal_type, null);
  assertEquals(fallbackOnly?.confidence, 0.5);
  assertEquals(fallbackOnly?.warnings, []);
  assertEquals(fallbackOnly?.suggestions.length, 6);
  assertEquals(
    fallbackOnly?.context_analysis,
    "Оценка блюда по фото: Овсянка. Примерная калорийность порции — 320 ккал.",
  );

  const emptyRussian = normalizeFoodImageAnalysis({
    detected_items: [],
    total_macros: null,
    confidence: 0.4,
  }, "ru");

  assertEquals(
    emptyRussian?.context_analysis,
    "Фото обработано. Проверьте состав блюда перед сохранением.",
  );

  const emptyEnglish = normalizeFoodImageAnalysis({
    detected_items: "not-an-array",
    total_macros: undefined,
    confidence: 0.4,
    warnings: ["", 42, "  Check sauce  "],
  });

  assertEquals(emptyEnglish?.detected_items, []);
  assertEquals(emptyEnglish?.total_macros.calories, 0);
  assertEquals(emptyEnglish?.warnings, ["Check sauce"]);
  assertEquals(
    emptyEnglish?.context_analysis,
    "Photo processed. Review the meal composition before saving.",
  );

  const missingCategory = normalizeFoodImageAnalysis({
    detected_items: [{
      name: "Eggs",
      calories: 140,
      protein_g: 12,
      fat_g: 10,
      carbs_g: 1,
    }],
  });
  assertEquals(missingCategory?.detected_items[0].category, "mixed");
});

Deno.test("buildFoodImage prompts include locale and context guardrails", () => {
  assertStringIncludes(buildFoodImageSystemPrompt(null), "preferred language");
  assertStringIncludes(buildFoodImageSystemPrompt("ru-RU"), "Russian");
  assertStringIncludes(buildFoodImageSystemPrompt("en-US"), "English");
  assertStringIncludes(buildFoodImageSystemPrompt("es-MX"), "es-MX");

  const prompt = buildFoodImageUserPrompt({
    context: "restaurant",
    timestamp: "2026-03-14T12:30:00Z",
    pre_workout: true,
    post_workout: true,
    recognized_text: "salmon bowl",
    barcodes: ["4601234567890"],
    recent_activity: "60 minute strength workout",
    recovery_score: 78,
  });

  assertEquals(prompt.includes("OCR HINT:"), true);
  assertEquals(prompt.includes("BARCODES: 4601234567890"), true);
  assertEquals(prompt.includes("Pre-workout: true"), true);
  assertEquals(prompt.includes("Post-workout: true"), true);
});
