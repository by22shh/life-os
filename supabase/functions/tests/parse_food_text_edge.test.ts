import {
  assertEquals,
  assertExists,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  captureEdgeHandler,
  jsonResponse,
  withMockedEdgeRuntime,
} from "./_edge_runtime_harness.ts";

function customFood(
  id: string,
  name: string,
  defaultServingG: number,
  macros: {
    calories: number;
    protein: number;
    fat: number;
    carbs: number;
    fiber: number | null;
  },
) {
  return {
    id,
    name,
    brand: null,
    barcode: null,
    default_serving_g: defaultServingG,
    calories_per_100g: macros.calories,
    protein_per_100g: macros.protein,
    fat_per_100g: macros.fat,
    carbs_per_100g: macros.carbs,
    fiber_per_100g: macros.fiber,
    created_at: "2026-05-29T00:00:00.000Z",
  };
}

function catalogFood(
  id: string,
  name: string,
  servingSizeG: number,
  macros: {
    calories: number;
    protein: number;
    fat: number;
    carbs: number;
    fiber: number | null;
  },
) {
  return {
    id,
    provider: "open_food_facts",
    name,
    brand: null,
    barcode: null,
    serving_size_g: servingSizeG,
    calories_per_100g: macros.calories,
    protein_per_100g: macros.protein,
    fat_per_100g: macros.fat,
    carbs_per_100g: macros.carbs,
    fiber_per_100g: macros.fiber,
    fetched_at: "2026-05-29T00:00:00.000Z",
    expires_at: "2026-06-29T00:00:00.000Z",
  };
}

function searchFilter(url: URL): string {
  return (url.searchParams.get("name") ?? "").toLowerCase();
}

Deno.test("parse-food-text edge handler parses meals, falls back cleanly, and validates requests", async (t) => {
  const handler = await captureEdgeHandler("../parse-food-text/index.ts");

  await t.step(
    "returns structured items with matched nutrition and clarification prompts",
    async () => {
      await withMockedEdgeRuntime({
        publicUser: {
          id: "public-user-id",
          timezone: "Asia/Novosibirsk",
        },
        responders: [
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_food_favorites") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_items") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_foods") {
              const filter = searchFilter(url);
              if (filter.includes("chicken breast")) {
                return jsonResponse([
                  customFood("custom-chicken-1", "Chicken breast", 100, {
                    calories: 165,
                    protein: 31,
                    fat: 3.6,
                    carbs: 0,
                    fiber: null,
                  }),
                  customFood(
                    "custom-chicken-2",
                    "Chicken breast grilled",
                    100,
                    {
                      calories: 172,
                      protein: 30,
                      fat: 4.1,
                      carbs: 0,
                      fiber: null,
                    },
                  ),
                ]);
              }
              if (filter.includes("banana")) {
                return jsonResponse([
                  customFood("custom-banana-1", "Banana", 120, {
                    calories: 89,
                    protein: 1.1,
                    fat: 0.3,
                    carbs: 23,
                    fiber: 2.6,
                  }),
                  customFood("custom-banana-2", "Banana chips", 30, {
                    calories: 519,
                    protein: 2.3,
                    fat: 33.6,
                    carbs: 58.4,
                    fiber: 7.7,
                  }),
                ]);
              }
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_catalog_items") {
              if (url.searchParams.has("provider")) {
                return jsonResponse([]);
              }

              const filter = searchFilter(url);
              if (filter.includes("chicken breast")) {
                return jsonResponse([
                  catalogFood("catalog-chicken-1", "Chicken breast", 100, {
                    calories: 165,
                    protein: 31,
                    fat: 3.6,
                    carbs: 0,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("banana")) {
                return jsonResponse([
                  catalogFood("catalog-banana-1", "Banana", 118, {
                    calories: 89,
                    protein: 1.1,
                    fat: 0.3,
                    carbs: 23,
                    fiber: 2.6,
                  }),
                ]);
              }
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.hostname === "world.openfoodfacts.org") {
              return jsonResponse({ products: [] });
            }
          },
        ],
      }, async (calls) => {
        const response = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              text: "150 g chicken breast, banana, mystery stew",
              locale: "en-US",
              meal_type: "breakfast",
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.meal_type, "breakfast");
        assertEquals(payload.items.length, 3);
        assertEquals(payload.items[0].name, "Chicken breast");
        assertEquals(payload.items[0].weight_g, 150);
        assertEquals(payload.items[0].category, "protein");
        assertEquals(payload.items[0].calories, 247.5);
        assertEquals(payload.items[1].name, "Banana");
        assertEquals(payload.items[1].weight_g, 120);
        assertEquals(payload.items[1].category, "carbs");
        assertEquals(payload.items[2].name, "mystery stew");
        assertEquals(payload.items[2].calories, null);
        assertEquals(payload.needs_clarification, true);
        assertEquals(payload.clarifying_questions.length, 2);
        assertStringIncludes(payload.warnings[0], "mystery stew");
        assertEquals(
          payload.warnings.includes(
            "Some serving sizes were estimated from default portions.",
          ),
          true,
        );
        assertEquals(payload.suggestions.length, 2);
        assertExists(payload.total_macros);
        assertStringIncludes(payload.context_analysis, "3 items");

        const providerSearchCall = calls.fetches.find((call) =>
          call.url.hostname === "world.openfoodfacts.org"
        );
        assertExists(providerSearchCall);
      });
    },
  );

  await t.step(
    "infers meal type from text and covers count-based fruit, drinks, and vegetable matches",
    async () => {
      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_food_favorites") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_items") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_foods") {
              const filter = searchFilter(url);
              if (filter.includes("apples")) {
                return jsonResponse([
                  customFood("custom-apple-1", "Apples", 180, {
                    calories: 52,
                    protein: 0.3,
                    fat: 0.2,
                    carbs: 14,
                    fiber: 2.4,
                  }),
                  customFood("custom-apple-2", "Apple slices", 150, {
                    calories: 48,
                    protein: 0.2,
                    fat: 0.2,
                    carbs: 13,
                    fiber: 2.1,
                  }),
                ]);
              }
              if (filter.includes("coffee")) {
                return jsonResponse([
                  customFood("custom-coffee-1", "Coffee", 250, {
                    calories: 2,
                    protein: 0.3,
                    fat: 0,
                    carbs: 0,
                    fiber: null,
                  }),
                  customFood("custom-coffee-2", "Cappuccino", 250, {
                    calories: 38,
                    protein: 2.1,
                    fat: 1.5,
                    carbs: 4.3,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("vegetable soup")) {
                return jsonResponse([
                  customFood("custom-soup-1", "Vegetable soup", 240, {
                    calories: 46,
                    protein: 1.9,
                    fat: 1.1,
                    carbs: 8.2,
                    fiber: 1.6,
                  }),
                  customFood("custom-soup-2", "Tomato vegetable soup", 240, {
                    calories: 42,
                    protein: 1.6,
                    fat: 0.9,
                    carbs: 7.8,
                    fiber: 1.5,
                  }),
                ]);
              }
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_catalog_items") {
              const filter = searchFilter(url);
              if (filter.includes("apples")) {
                return jsonResponse([
                  catalogFood("catalog-apple-1", "Apples", 180, {
                    calories: 52,
                    protein: 0.3,
                    fat: 0.2,
                    carbs: 14,
                    fiber: 2.4,
                  }),
                ]);
              }
              if (filter.includes("coffee")) {
                return jsonResponse([
                  catalogFood("catalog-coffee-1", "Coffee", 250, {
                    calories: 2,
                    protein: 0.3,
                    fat: 0,
                    carbs: 0,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("vegetable soup")) {
                return jsonResponse([
                  catalogFood("catalog-soup-1", "Vegetable soup", 240, {
                    calories: 46,
                    protein: 1.9,
                    fat: 1.1,
                    carbs: 8.2,
                    fiber: 1.6,
                  }),
                ]);
              }
              return jsonResponse([]);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              text: "for lunch 2 apples, coffee, vegetable soup",
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.meal_type, "lunch");
        assertEquals(payload.items[0].unit, "piece");
        assertEquals(payload.items[0].weight_g, 360);
        assertEquals(payload.items[0].category, "fruit");
        assertEquals(payload.items[1].weight_g, 250);
        assertEquals(payload.items[2].category, "vegetable");
        assertEquals(payload.clarifying_questions.length, 2);
        assertEquals(payload.clarifying_questions[0].options[0], "200 ml");
      });
    },
  );

  await t.step(
    "parses mixed separators and unit conversions across a fuller meal",
    async () => {
      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_food_favorites") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_items") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_foods") {
              const filter = searchFilter(url);
              if (filter.includes("eggs")) {
                return jsonResponse([
                  customFood("custom-eggs-1", "Eggs", 50, {
                    calories: 143,
                    protein: 12.6,
                    fat: 9.5,
                    carbs: 0.7,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("oatmeal")) {
                return jsonResponse([
                  customFood("custom-oats-1", "Oatmeal", 240, {
                    calories: 68,
                    protein: 2.4,
                    fat: 1.4,
                    carbs: 12,
                    fiber: 1.7,
                  }),
                ]);
              }
              if (filter.includes("peanut butter")) {
                return jsonResponse([
                  customFood("custom-pb-1", "Peanut butter", 15, {
                    calories: 588,
                    protein: 25,
                    fat: 50,
                    carbs: 20,
                    fiber: 6,
                  }),
                ]);
              }
              if (filter.includes("salmon")) {
                return jsonResponse([
                  customFood("custom-salmon-1", "Salmon", 100, {
                    calories: 208,
                    protein: 20,
                    fat: 13,
                    carbs: 0,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("toast")) {
                return jsonResponse([
                  customFood("custom-toast-1", "Toast", 30, {
                    calories: 265,
                    protein: 9,
                    fat: 3.2,
                    carbs: 49,
                    fiber: 2.7,
                  }),
                ]);
              }
              if (filter.includes("tea")) {
                return jsonResponse([
                  customFood("custom-tea-1", "Tea", 300, {
                    calories: 1,
                    protein: 0,
                    fat: 0,
                    carbs: 0.2,
                    fiber: null,
                  }),
                ]);
              }
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_catalog_items") {
              if (url.searchParams.has("provider")) {
                return jsonResponse([]);
              }
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.hostname === "world.openfoodfacts.org") {
              return jsonResponse({ products: [] });
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              text:
                "for dinner 2 eggs and 1 cup oatmeal + 2 tbsp peanut butter & 3 oz salmon, 2 slices toast, 300 ml tea",
              meal_type: "brunch",
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.meal_type, "dinner");
        assertEquals(payload.items.length, 6);
        assertEquals(payload.items[0].weight_g, 100);
        assertEquals(payload.items[1].weight_g, 240);
        assertEquals(payload.items[2].weight_g, 30);
        assertEquals(Math.round(payload.items[3].weight_g * 100) / 100, 85.05);
        assertEquals(payload.items[4].weight_g, 60);
        assertEquals(payload.items[5].weight_g, 300);
        assertEquals(payload.items[0].unit, "piece");
        assertEquals(payload.items[5].notes, 'Serving parsed from "300 ml".');
        assertEquals(payload.needs_clarification, false);
        assertEquals(payload.clarifying_questions, []);
        assertEquals(payload.suggestions, []);
        assertStringIncludes(
          payload.context_analysis,
          "6 matched nutrition data",
        );
        assertStringIncludes(payload.context_analysis, "0 still need review");
      });
    },
  );

  await t.step(
    "returns an empty-detection response when text has no parseable foods",
    async () => {
      await withMockedEdgeRuntime({}, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ text: ", ; + &" }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.items, []);
        assertEquals(payload.needs_clarification, true);
        assertEquals(payload.suggestions, [
          "Try listing foods separated by commas.",
        ]);
        assertStringIncludes(payload.warnings[0], "couldn't detect");
      });
    },
  );

  await t.step(
    "treats repository failures as unmatched items and returns stable request guardrails",
    async () => {
      await withMockedEdgeRuntime({}, async () => {
        const preflight = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "OPTIONS",
          }),
        );
        assertEquals(preflight.status, 204);

        const unauthorized = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
          }),
        );
        assertEquals(unauthorized.status, 401);

        const methodResponse = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "GET",
          }),
        );
        assertEquals(methodResponse.status, 405);

        const invalidJsonResponse = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: "{",
          }),
        );
        assertEquals(invalidJsonResponse.status, 400);

        const invalidPayloadResponse = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify([]),
          }),
        );
        assertEquals(invalidPayloadResponse.status, 400);

        const blankTextResponse = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ text: "   " }),
          }),
        );
        assertEquals(blankTextResponse.status, 400);
        assertEquals(
          await blankTextResponse.json(),
          { error: "text_required" },
        );
      });

      await withMockedEdgeRuntime({
        responders: [
          () => jsonResponse({ message: "favorites fetch failed" }, 500),
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              text: "2 cups broken stew",
            }),
          }),
        );

        const payload = await response.json();
        assertEquals(response.status, 200);
        assertEquals(payload.items[0].name, "broken stew");
        assertEquals(payload.items[0].weight_g, 480);
        assertEquals(
          payload.items[0].notes,
          'Estimated from "2 cups".',
        );
      });
    },
  );

  await t.step(
    "covers additional unit conversions, meal inference, and fat category matches",
    async () => {
      await withMockedEdgeRuntime({
        responders: [
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_food_favorites") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_items") {
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/user_foods") {
              const filter = searchFilter(url);
              if (filter.includes("olive oil")) {
                return jsonResponse([
                  customFood("custom-oil-1", "Olive oil", 10, {
                    calories: 884,
                    protein: 0,
                    fat: 100,
                    carbs: 0,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("cheddar")) {
                return jsonResponse([
                  customFood("custom-cheddar-1", "Cheddar", 30, {
                    calories: 402,
                    protein: 25,
                    fat: 33,
                    carbs: 1.3,
                    fiber: null,
                  }),
                ]);
              }
              if (filter.includes("cookie")) {
                return jsonResponse([
                  customFood("custom-cookie-1", "Cookie", 100, {
                    calories: 488,
                    protein: 6,
                    fat: 24,
                    carbs: 64,
                    fiber: 2,
                  }),
                ]);
              }
              if (filter.includes("bananas")) {
                return jsonResponse([
                  customFood("custom-banana-1", "Bananas", 120, {
                    calories: 89,
                    protein: 1.1,
                    fat: 0.3,
                    carbs: 23,
                    fiber: 2.6,
                  }),
                ]);
              }
              return jsonResponse([]);
            }
          },
          (_request, { url }) => {
            if (url.pathname === "/rest/v1/food_catalog_items") {
              return jsonResponse([]);
            }
          },
        ],
      }, async () => {
        const response = await handler(
          new Request("http://localhost/functions/v1/parse-food-text", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              text:
                "2 tsp olive oil, 1 slice cheddar, 3 pieces cookie, 2 bananas",
              meal_type: "snack",
              locale: "   ",
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.meal_type, "snack");
        assertEquals(payload.items.length, 4);
        assertEquals(payload.items[0].weight_g, 10);
        assertEquals(payload.items[0].category, "fat");
        assertEquals(payload.items[1].weight_g, 30);
        assertEquals(payload.items[2].weight_g, 300);
        assertEquals(payload.items[3].unit, "piece");
        assertEquals(payload.items[3].weight_g, 240);
        assertEquals(payload.needs_clarification, false);
      });
    },
  );
});
