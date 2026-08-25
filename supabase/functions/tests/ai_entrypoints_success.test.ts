import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const TINY_PNG_DATA_URL =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF3QAAAAASUVORK5CYII=";

type EdgeHandler = (request: Request) => Promise<Response> | Response;
const edgeHandlerCache = new Map<string, EdgeHandler>();

interface OpenRouterRequestCall {
  body: Record<string, unknown>;
  headers: Headers;
}

interface RuntimeCalls {
  authHeaders: string[];
  openrouterRequests: OpenRouterRequestCall[];
  rateLimitBodies: Array<Record<string, unknown>>;
  userLookupUrls: string[];
}

type RequestResponder = (request: Request) => Promise<Response> | Response;

interface RuntimeConfig {
  authUserId?: string;
  authResponse?: RequestResponder;
  env?: Record<string, string | null>;
  openrouterResponse?: (
    request: Request,
    body: Record<string, unknown>,
  ) => Promise<Response> | Response;
  publicUserId?: string;
  rateLimitResponse?: RequestResponder;
  userLookupResponse?: RequestResponder;
}

function jsonResponse(
  data: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...extraHeaders,
    },
  });
}

async function captureEdgeHandler(modulePath: string): Promise<EdgeHandler> {
  const cached = edgeHandlerCache.get(modulePath);
  if (cached) {
    return cached;
  }

  let handler: EdgeHandler | null = null;
  const previousServeDescriptor = Object.getOwnPropertyDescriptor(
    Deno,
    "serve",
  );

  const mockServe = ((...args: unknown[]) => {
    handler = typeof args[0] === "function"
      ? args[0] as EdgeHandler
      : args[1] as EdgeHandler;
    return { finished: Promise.resolve(), shutdown() {} } as never;
  }) as typeof Deno.serve;
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    enumerable: previousServeDescriptor?.enumerable ?? true,
    value: mockServe,
    writable: true,
  });

  try {
    const moduleUrl = new URL(modulePath, import.meta.url).href;
    await import(moduleUrl);
  } finally {
    if (previousServeDescriptor) {
      Object.defineProperty(Deno, "serve", previousServeDescriptor);
    } else {
      delete (Deno as { serve?: typeof Deno.serve }).serve;
    }
  }

  if (!handler) {
    throw new Error(`Failed to capture edge handler for ${modulePath}`);
  }

  edgeHandlerCache.set(modulePath, handler);
  return handler;
}

async function withMockedRuntime<T>(
  config: RuntimeConfig,
  fn: (calls: RuntimeCalls) => Promise<T>,
): Promise<T> {
  const calls: RuntimeCalls = {
    authHeaders: [],
    openrouterRequests: [],
    rateLimitBodies: [],
    userLookupUrls: [],
  };

  const previousFetch = globalThis.fetch;
  const touchedEnv = new Map<string, string | undefined>();
  const envValues: Record<string, string | null> = {
    SUPABASE_URL: "http://localhost:54321",
    SUPABASE_ANON_KEY: "anon-key",
    SUPABASE_SERVICE_ROLE_KEY: "service-role-key",
    ...config.env,
  };

  for (const key of Object.keys(envValues)) {
    touchedEnv.set(key, Deno.env.get(key));
    if (envValues[key] === null) {
      Deno.env.delete(key);
    } else {
      Deno.env.set(key, envValues[key]);
    }
  }

  globalThis.fetch = (async (
    input: Request | URL | string,
    init?: RequestInit,
  ) => {
    const request = input instanceof Request
      ? input
      : new Request(String(input), init);
    const url = new URL(request.url);

    if (url.pathname === "/auth/v1/user") {
      calls.authHeaders.push(request.headers.get("Authorization") ?? "");
      if (config.authResponse) {
        return await config.authResponse(request);
      }
      return jsonResponse({ id: config.authUserId ?? "auth-user-id" });
    }

    if (url.pathname === "/rest/v1/users") {
      calls.userLookupUrls.push(url.toString());
      if (config.userLookupResponse) {
        return await config.userLookupResponse(request);
      }
      return jsonResponse([{ id: config.publicUserId ?? "public-user-id" }]);
    }

    if (url.pathname === "/rest/v1/rpc/check_rate_limit_bucket") {
      const bodyText = await request.clone().text();
      calls.rateLimitBodies.push(
        bodyText ? JSON.parse(bodyText) as Record<string, unknown> : {},
      );
      if (config.rateLimitResponse) {
        return await config.rateLimitResponse(request);
      }
      return jsonResponse([{
        ok: true,
        retry_after_seconds: 0,
        remaining: 999,
        reset_epoch_seconds: Math.floor(Date.now() / 1000) + 60,
      }]);
    }

    if (request.url === OPENROUTER_URL) {
      const bodyText = await request.clone().text();
      const body = bodyText
        ? JSON.parse(bodyText) as Record<string, unknown>
        : {};
      calls.openrouterRequests.push({
        body,
        headers: new Headers(request.headers),
      });

      if (config.openrouterResponse) {
        return await config.openrouterResponse(request, body);
      }

      return jsonResponse({
        choices: [{ message: { content: "{}" } }],
      });
    }

    throw new Error(`Unexpected fetch URL in test harness: ${request.url}`);
  }) as typeof fetch;

  try {
    return await fn(calls);
  } finally {
    globalThis.fetch = previousFetch;
    for (const [key, value] of touchedEnv) {
      if (value === undefined) {
        Deno.env.delete(key);
      } else {
        Deno.env.set(key, value);
      }
    }
  }
}

Deno.test("AI edge entrypoints cover success paths and upstream shaping", async (t) => {
  await t.step(
    "openrouter gateway sanitizes and forwards allowed payloads",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
          OPENROUTER_REFERER: "https://lifeos.test",
          OPENROUTER_APP_NAME: "Life OS Test",
        },
        openrouterResponse: () =>
          new Response(
            JSON.stringify({
              id: "chatcmpl-test",
              choices: [{ message: { content: "pong" } }],
            }),
            {
              status: 200,
              headers: { "Content-Type": "application/json; charset=utf-8" },
            },
          ),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );

        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer test-access-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [
                { role: "user", content: "  ping  " },
                {
                  role: "assistant",
                  content: [{ type: "text", text: "kept" }],
                },
              ],
              max_tokens: 99_999,
              temperature: 7,
              stream: true,
              tools: [{ type: "function", name: "should_not_forward" }],
            }),
          }),
        );

        assertEquals(response.status, 200);
        assertEquals(await response.json(), {
          id: "chatcmpl-test",
          choices: [{ message: { content: "pong" } }],
        });
        assertEquals(
          response.headers.get("Content-Type"),
          "application/json; charset=utf-8",
        );
        assertEquals(calls.authHeaders, ["Bearer test-access-token"]);
        assertStringIncludes(
          calls.userLookupUrls[0],
          "auth_id=eq.auth-user-id",
        );
        assertEquals(
          calls.rateLimitBodies[0].p_bucket_key,
          "ai_vision:public-user-id",
        );
        assertEquals(calls.openrouterRequests.length, 1);
        assertEquals(
          calls.openrouterRequests[0].headers.get("Authorization"),
          "Bearer openrouter-test-key",
        );
        assertEquals(
          calls.openrouterRequests[0].headers.get("HTTP-Referer"),
          "https://lifeos.test",
        );
        assertEquals(
          calls.openrouterRequests[0].headers.get("X-Title"),
          "Life OS Test",
        );
        assertEquals(calls.openrouterRequests[0].body, {
          model: "openai/gpt-4o-mini",
          messages: [
            { role: "user", content: "ping" },
            { role: "assistant", content: [{ type: "text", text: "kept" }] },
          ],
          max_tokens: 4096,
          temperature: 2,
        });
      });
    },
  );

  await t.step(
    "analyze-food-image normalizes request hints and response payload",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
          ANALYZE_FOOD_IMAGE_MODEL: "openai/gpt-4o-mini",
        },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{
              message: {
                content: JSON.stringify({
                  detected_items: [{
                    name: "Salmon Bowl",
                    category: "protein",
                    weight_g: 320.7,
                    calories: 540.6,
                    protein_g: 34.24,
                    fat_g: 22.34,
                    carbs_g: 48.19,
                    fiber_g: 6.44,
                    confidence: 0.88,
                    notes: "  rice and greens  ",
                  }],
                  total_macros: {
                    calories: 0,
                    protein_g: 0,
                    fat_g: 0,
                    carbs_g: 0,
                    fiber_g: 0,
                  },
                  confidence: 0.91,
                  warnings: [
                    "  Hidden sauce possible  ",
                    "hidden sauce possible",
                  ],
                  suggestions: ["Add fruit"],
                  meal_type: "lunch",
                }),
              },
            }],
          }),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );

        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: `  ${TINY_PNG_DATA_URL}  `,
              context: "restaurant",
              timestamp: "2026-03-14T12:30:00Z",
              post_workout: true,
              recent_activity: "  60 minute strength workout  ",
              recovery_score: 140,
              recognized_text: "  salmon bowl  ",
              barcodes: ["4601234567890", "4601234567890", "", "012345678905"],
              locale: "en-US",
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.meal_type, "lunch");
        assertEquals(payload.total_macros.calories, 541);
        assertEquals(payload.total_macros.protein_g, 34.2);
        assertEquals(payload.warnings, ["Hidden sauce possible"]);
        assertEquals(
          payload.context_analysis,
          "Estimated meal from the photo: Salmon Bowl. Approximate portion energy is 541 kcal.",
        );
        assertEquals(
          calls.rateLimitBodies[0].p_bucket_key,
          "ai_vision:public-user-id",
        );
        assertEquals(
          calls.openrouterRequests[0].body.model,
          "openai/gpt-4o-mini",
        );

        const messages = calls.openrouterRequests[0].body
          .messages as Array<Record<string, unknown>>;
        const userContent = messages[1].content as Array<
          Record<string, unknown>
        >;
        const prompt = userContent[0].text as string;

        assertStringIncludes(prompt, "BARCODES: 4601234567890, 012345678905");
        assertStringIncludes(prompt, "Recovery score: 100");
        assertStringIncludes(prompt, "OCR HINT:\nsalmon bowl");
        assertEquals(
          (userContent[1].image_url as { url: string }).url,
          TINY_PNG_DATA_URL,
        );
      });
    },
  );

  await t.step(
    "analyze-food-image accepts array content and caps barcode hints",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
        },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{
              message: {
                content: [
                  null,
                  { type: "text", text: "" },
                  {
                    type: "text",
                    text: JSON.stringify({
                      detected_items: [],
                      total_macros: {
                        calories: 120,
                        protein_g: 4,
                        fat_g: 3,
                        carbs_g: 20,
                        fiber_g: 2,
                      },
                      confidence: 0.7,
                    }),
                  },
                ],
              },
            }],
          }),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );

        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              barcodes: [
                "000000000001",
                "000000000002",
                "000000000003",
                "000000000004",
                "000000000005",
                "000000000006",
                "000000000007",
              ],
            }),
          }),
        );

        const payload = await response.json();
        assertEquals(response.status, 200);
        assertEquals(payload.total_macros.calories, 120);

        const messages = calls.openrouterRequests[0].body
          .messages as Array<Record<string, unknown>>;
        const userContent = messages[1].content as Array<
          Record<string, unknown>
        >;
        const prompt = userContent[0].text as string;
        assertStringIncludes(
          prompt,
          "BARCODES: 000000000001, 000000000002, 000000000003, 000000000004, 000000000005, 000000000006",
        );
        assertEquals(prompt.includes("000000000007"), false);
        assertStringIncludes(prompt, "CONTEXT:");
        assertStringIncludes(prompt, "- Time: unknown");
        assertStringIncludes(prompt, "- Location: unknown");
      });
    },
  );

  await t.step(
    "analyze-food-label caps images and fills fallback warnings",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
          ANALYZE_FOOD_LABEL_MODEL: "anthropic/claude-3-haiku",
        },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{
              message: {
                content: JSON.stringify({
                  barcode: "ignored-ai-barcode",
                  name: "Protein Bar",
                  brand: "FitBrand",
                  serving_size_g: 60.4,
                  macros_per_100g: {
                    calories: 399.6,
                    protein_g: 31.16,
                    fat_g: 12.34,
                    carbs_g: 40.49,
                    fiber_g: null,
                    sugar_g: 28.12,
                    sodium_mg: 500.6,
                  },
                  confidence: 0.876,
                  warnings: [],
                  needs_review: false,
                }),
              },
            }],
          }),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );

        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: " 4601234500007 ",
              locale: "en-US",
              images_base64: [
                TINY_PNG_DATA_URL,
                ` ${TINY_PNG_DATA_URL} `,
                TINY_PNG_DATA_URL,
                TINY_PNG_DATA_URL,
              ],
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.barcode, "4601234500007");
        assertEquals(payload.name, "Protein Bar");
        assertEquals(payload.macros_per_100g.calories, 400);
        assertEquals(payload.macros_per_100g.protein_g, 31.2);
        assertEquals(payload.macros_per_100g.sodium_mg, 501);
        assertEquals(payload.confidence, 0.88);
        assertEquals(payload.warnings, [
          "Nutrition label output requires manual review.",
        ]);
        assertEquals(
          calls.rateLimitBodies[0].p_bucket_key,
          "ai_parse:public-user-id",
        );
        assertEquals(
          calls.openrouterRequests[0].body.model,
          "anthropic/claude-3-haiku",
        );

        const messages = calls.openrouterRequests[0].body
          .messages as Array<Record<string, unknown>>;
        const userContent = messages[1].content as Array<
          Record<string, unknown>
        >;
        const prompt = userContent[0].text as string;

        assertEquals(userContent.length, 4);
        assertStringIncludes(prompt, '"barcode": "4601234500007"');
        assertStringIncludes(prompt, "IMAGES: 3 label photos are attached.");
      });
    },
  );

  await t.step(
    "analyze-food-label filters invalid images and normalizes array-based AI content",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
          ANALYZE_FOOD_LABEL_MODEL: "openai/gpt-4o-mini",
        },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{
              message: {
                content: [{
                  type: "text",
                  text: JSON.stringify({
                    barcode: "ignored-ai-barcode",
                    name: "  Cheese Crackers  ",
                    brand: "   ",
                    serving_size_g: 0.4,
                    macros_per_100g: {
                      calories: -20,
                      protein_g: 700,
                      fat_g: 12.34,
                      carbs_g: 800,
                      fiber_g: 250,
                      sugar_g: "unknown",
                      sodium_mg: 9999,
                    },
                    confidence: 5,
                    warnings: [
                      "  Salt-derived  ",
                      "salt-derived",
                      "",
                      42,
                    ],
                    needs_review: false,
                  }),
                }],
              },
            }],
          }),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );

        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "   ",
              locale: "es-ES",
              images_base64: [
                "https://example.com/not-a-data-url.png",
                ` ${TINY_PNG_DATA_URL} `,
                "data:text/plain;base64,Zm9v",
              ],
            }),
          }),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.barcode, null);
        assertEquals(payload.name, "Cheese Crackers");
        assertEquals(payload.brand, null);
        assertEquals(payload.serving_size_g, 1);
        assertEquals(payload.macros_per_100g, {
          calories: 0,
          protein_g: 500,
          fat_g: 12.3,
          carbs_g: 500,
          fiber_g: 200,
          sugar_g: null,
          sodium_mg: 5000,
        });
        assertEquals(payload.confidence, 1);
        assertEquals(payload.warnings, ["Salt-derived"]);
        assertEquals(payload.needs_review, true);

        const messages = calls.openrouterRequests[0].body
          .messages as Array<Record<string, unknown>>;
        const systemPrompt = messages[0].content as string;
        const userContent = messages[1].content as Array<
          Record<string, unknown>
        >;
        const prompt = userContent[0].text as string;

        assertStringIncludes(systemPrompt, "Keep narrative fields in es-ES.");
        assertEquals(userContent.length, 2);
        assertStringIncludes(prompt, '"barcode": "unknown"');
        assertStringIncludes(prompt, "IMAGES: 1 label photo are attached.");
      });
    },
  );

  await t.step(
    "analyze-batch-recipe-image derives per-unit values and falls back to known ingredients",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
          ANALYZE_BATCH_RECIPE_MODEL: "google/gemini-flash-1.5",
        },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{
              message: {
                content: JSON.stringify({
                  recipe_name: "  Weeknight Chili  ",
                  ingredients_detected: [],
                  total_batch: {
                    calories: 2400,
                    protein_g: 150.4,
                    fat_g: 90.2,
                    carbs_g: 210.6,
                    fiber_g: 36.2,
                  },
                  per_100g: {},
                  per_portion: {},
                  notes: [],
                  storage: {
                    refrigerator_days: 4.7,
                    freezer_months: 3.2,
                    reheating_tip: " Warm gently before serving ",
                  },
                  warnings: [],
                  confidence: 0.734,
                }),
              },
            }],
          }),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );

        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Weeknight Chili",
                total_weight_grams: 1800,
                portions_planned: 6,
                cooking_method: "stewed",
                known_ingredients: [
                  { name: "beans", raw_weight_g: 600.2 },
                  { name: "beef", raw_weight_g: 500.4 },
                  { name: "tomatoes", raw_weight_g: 320.1 },
                  { name: "onion", raw_weight_g: 120.5 },
                  { name: "olive oil", raw_weight_g: 30.2 },
                  { name: "stock", raw_weight_g: 400.9 },
                  { name: "bay leaf", raw_weight_g: 2.4 },
                ],
                image_base64: TINY_PNG_DATA_URL,
                locale: "en-US",
              }),
            },
          ),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.recipe_name, "Weeknight Chili");
        assertEquals(payload.ingredients_detected.length, 7);
        assertEquals(payload.ingredients_detected[0].name, "beans");
        assertEquals(
          payload.ingredients_detected[0].estimated_raw_weight_g,
          600,
        );
        assertEquals(payload.total_batch.weight_g, 1800);
        assertEquals(payload.per_100g.calories, 133);
        assertEquals(payload.per_100g.protein_g, 8.4);
        assertEquals(payload.per_100g.fat_g, 5);
        assertEquals(payload.per_100g.carbs_g, 11.7);
        assertEquals(payload.per_100g.fiber_g, 2);
        assertEquals(payload.per_portion.weight_g, 300);
        assertEquals(payload.per_portion.calories, 400);
        assertEquals(payload.per_portion.protein_g, 25.1);
        assertEquals(payload.notes, [
          "Estimates require review before saving.",
        ]);
        assertEquals(payload.warnings, ["Batch recipe draft requires review."]);
        assertEquals(payload.storage.refrigerator_days, 5);
        assertEquals(payload.storage.freezer_months, 3);
        assertEquals(
          payload.storage.reheating_tip,
          "Warm gently before serving",
        );
        assertEquals(payload.confidence, 0.73);
        assertEquals(
          calls.rateLimitBodies[0].p_bucket_key,
          "ai_vision:public-user-id",
        );
        assertEquals(
          calls.openrouterRequests[0].body.model,
          "google/gemini-flash-1.5",
        );

        const messages = calls.openrouterRequests[0].body
          .messages as Array<Record<string, unknown>>;
        const userContent = messages[1].content as Array<
          Record<string, unknown>
        >;
        const prompt = userContent[0].text as string;

        assertStringIncludes(prompt, '"portion_size_grams": 300');
        assertStringIncludes(prompt, '"name": "stock"');
        assertEquals(prompt.includes("bay leaf"), false);
      });
    },
  );

  await t.step(
    "analyze-batch-recipe-image keeps explicit AI values and normalizes detected ingredients",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
          OPENROUTER_REFERER: "https://lifeos.test",
        },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{
              message: {
                content: [{
                  type: "text",
                  text: JSON.stringify({
                    recipe_name: "   ",
                    ingredients_detected: [
                      null,
                      { name: "   " },
                      {
                        name: "  Chickpeas  ",
                        estimated_raw_weight_g: 380.6,
                        estimated_cooked_weight_g: 410.4,
                        calories: 820.4,
                        protein_g: 45.67,
                        fat_g: 12.34,
                        carbs_g: 132.58,
                        confidence: 1.8,
                      },
                      {
                        name: "Spinach",
                        estimated_raw_weight_g: -5,
                        estimated_cooked_weight_g: 95.2,
                        calories: 25.5,
                        protein_g: 3.45,
                        fat_g: -4,
                        carbs_g: 6.12,
                        confidence: -0.2,
                      },
                    ],
                    total_batch: {
                      weight_g: 0,
                      calories: 1876.2,
                      protein_g: 101.26,
                      fat_g: 50.41,
                      carbs_g: 240.11,
                      fiber_g: 28.43,
                    },
                    per_100g: {
                      calories: 156.9,
                      protein_g: 8.44,
                      fat_g: 4.19,
                      carbs_g: 20.01,
                      fiber_g: 2.37,
                    },
                    per_portion: {
                      weight_g: 280.7,
                      calories: 525.5,
                      protein_g: 28.45,
                      fat_g: 13.11,
                      carbs_g: 67.29,
                    },
                    notes: [
                      "  Добавь зелень  ",
                      "добавь зелень",
                      "",
                      "Подавать горячим",
                    ],
                    warnings: [
                      "  Возможен скрытый соус  ",
                      "возможен скрытый соус",
                      "Соль может быть выше",
                    ],
                    storage: {
                      refrigerator_days: 4.4,
                      freezer_months: 2.6,
                      reheating_tip: "  Разогреть на слабом огне  ",
                    },
                    confidence: "bad",
                  }),
                }],
              },
            }],
          }),
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );

        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Lentil Stew",
                total_weight_grams: 1200,
                portions_planned: 4,
                cooking_method: "  baked  ",
                known_ingredients: [
                  { name: " chickpeas ", raw_weight_g: 380 },
                  { name: " spinach ", raw_weight_g: 95 },
                ],
                image_base64: `  ${TINY_PNG_DATA_URL}  `,
                locale: "ru-RU",
              }),
            },
          ),
        );

        const payload = await response.json();

        assertEquals(response.status, 200);
        assertEquals(payload.recipe_name, "Lentil Stew");
        assertEquals(payload.ingredients_detected.length, 2);
        assertEquals(payload.ingredients_detected[0], {
          name: "Chickpeas",
          estimated_raw_weight_g: 381,
          estimated_cooked_weight_g: 410,
          calories: 820,
          protein_g: 45.7,
          fat_g: 12.3,
          carbs_g: 132.6,
          confidence: 1,
        });
        assertEquals(payload.ingredients_detected[1], {
          name: "Spinach",
          estimated_raw_weight_g: 0,
          estimated_cooked_weight_g: 95,
          calories: 26,
          protein_g: 3.5,
          fat_g: 0,
          carbs_g: 6.1,
          confidence: 0,
        });
        assertEquals(payload.total_batch.weight_g, 0);
        assertEquals(payload.per_100g, {
          weight_g: null,
          calories: 157,
          protein_g: 8.4,
          fat_g: 4.2,
          carbs_g: 20,
          fiber_g: 2.4,
        });
        assertEquals(payload.per_portion, {
          weight_g: 281,
          calories: 526,
          protein_g: 28.5,
          fat_g: 13.1,
          carbs_g: 67.3,
        });
        assertEquals(payload.notes, ["Добавь зелень", "Подавать горячим"]);
        assertEquals(payload.warnings, [
          "Возможен скрытый соус",
          "Соль может быть выше",
        ]);
        assertEquals(payload.storage, {
          refrigerator_days: 4,
          freezer_months: 3,
          reheating_tip: "Разогреть на слабом огне",
        });
        assertEquals(payload.confidence, 0.5);

        const messages = calls.openrouterRequests[0].body
          .messages as Array<Record<string, unknown>>;
        assertStringIncludes(messages[0].content as string, "Russian");
        assertEquals(
          calls.openrouterRequests[0].headers.get("HTTP-Referer"),
          "https://lifeos.test",
        );
        assertEquals(
          (
            (
              messages[1].content as Array<Record<string, unknown>>
            )[1].image_url as { url: string }
          ).url,
          TINY_PNG_DATA_URL,
        );
      });
    },
  );
});

Deno.test("AI edge entrypoints cover guardrails and failure responses", async (t) => {
  await t.step(
    "openrouter gateway rejects malformed requests before upstream calls",
    async () => {
      await withMockedRuntime({
        env: {
          OPENROUTER_API_KEY: "openrouter-test-key",
        },
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );

        let response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "OPTIONS",
          }),
        );
        assertEquals(response.status, 204);

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "GET",
          }),
        );
        assertEquals(response.status, 405);
        assertEquals(await response.json(), { error: "method_not_allowed" });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
          }),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: "{",
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "invalid_json" });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o",
              messages: "not-an-array",
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals((await response.json()).error, "invalid_payload");

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "meta/llama-3",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals((await response.json()).error, "model_not_allowed");

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "messages_required" });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: Array.from({ length: 21 }, () => ({
                role: "user",
                content: "hello",
              })),
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals((await response.json()).error, "too_many_messages");

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "tool", content: "nope" }],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [null],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: " " }],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "x".repeat(8_001) }],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: Array.from({ length: 7 }, () => ({
                role: "user",
                content: "x".repeat(7_200),
              })),
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{
                role: "user",
                content: [{ type: "text", text: "x".repeat(8_000) }],
              }],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: 42 }],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_messages_payload",
        });

        assertEquals(calls.openrouterRequests.length, 0);
      });
    },
  );

  await t.step(
    "openrouter gateway surfaces auth, lookup, rate-limit, and upstream failures",
    async () => {
      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        authResponse: () => jsonResponse({ message: "bad jwt" }, 401),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () => jsonResponse({ message: "db blew up" }, 500),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "user_lookup_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () => jsonResponse([], 200),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 404);
        assertEquals(await response.json(), { error: "user_not_found" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 12,
            remaining: 0,
            reset_epoch_seconds: 1_717_171_717,
          }]),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        const payload = await response.json();
        assertEquals(response.status, 429);
        assertEquals(payload.error, "rate_limit_exceeded");
        assertEquals(payload.tier, "ai_vision");
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: null },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "openrouter_key_not_configured",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new DOMException("timed out", "AbortError");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 504);
        assertEquals(await response.json(), { error: "openrouter_timeout" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new Error("socket hang up");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../ai/openrouter-gateway/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/ai-openrouter-gateway", {
            method: "POST",
            headers: {
              Authorization: "Bearer gateway-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "openai/gpt-4o-mini",
              messages: [{ role: "user", content: "hello" }],
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "openrouter_request_failed",
        });
      });
    },
  );

  await t.step(
    "analyze-food-image handles validation, auth, rate-limit, and upstream failures",
    async () => {
      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );

        let response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "OPTIONS",
          }),
        );
        assertEquals(response.status, 204);

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "GET",
          }),
        );
        assertEquals(response.status, 405);
        assertEquals(await response.json(), { error: "method_not_allowed" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ image_base64: TINY_PNG_DATA_URL }),
          }),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: "not-a-data-url",
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "invalid_image_base64" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: "{",
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "invalid_json" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ image_base64: 42 }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals((await response.json()).error, "invalid_payload");
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        authResponse: () => jsonResponse({ message: "bad jwt" }, 401),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () =>
          jsonResponse({ message: "lookup failed" }, 500),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "user_lookup_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () => jsonResponse([], 200),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 404);
        assertEquals(await response.json(), { error: "user_not_found" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 7,
            remaining: 0,
            reset_epoch_seconds: 1_717_171_717,
          }]),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        const payload = await response.json();
        assertEquals(response.status, 429);
        assertEquals(payload.tier, "ai_vision");
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: null },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "openrouter_key_not_configured",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () =>
          new Response("upstream said no", { status: 429 }),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "openrouter_request_failed",
          status: 429,
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new DOMException("timed out", "AbortError");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 504);
        assertEquals(await response.json(), { error: "upstream_timeout" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new Error("network broke");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "upstream_request_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{ message: { content: "definitely not json" } }],
          }),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-image/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-image", {
            method: "POST",
            headers: {
              Authorization: "Bearer image-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              image_base64: TINY_PNG_DATA_URL,
              context: "home",
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "invalid_ai_response",
          detail: "definitely not json",
        });
      });
    },
  );

  await t.step(
    "analyze-food-label handles validation, config, and upstream failures",
    async () => {
      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );

        let response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "OPTIONS",
          }),
        );
        assertEquals(response.status, 204);

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "GET",
          }),
        );
        assertEquals(response.status, 405);
        assertEquals(await response.json(), { error: "method_not_allowed" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [],
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "label_images_required" });

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: "not-an-array",
            }),
          }),
        );
        assertEquals(response.status, 400);
        assertEquals((await response.json()).error, "invalid_payload");

        response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: "{",
          }),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "invalid_json" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        authResponse: () => jsonResponse({ message: "bad jwt" }, 401),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () =>
          jsonResponse({ message: "lookup failed" }, 500),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "user_lookup_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () => jsonResponse([], 200),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 404);
        assertEquals(await response.json(), { error: "user_not_found" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: null },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "openrouter_key_not_configured",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 9,
            remaining: 0,
            reset_epoch_seconds: 1_717_171_717,
          }]),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        const payload = await response.json();
        assertEquals(response.status, 429);
        assertEquals(payload.tier, "ai_parse");
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => new Response("bad label", { status: 503 }),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "openrouter_request_failed",
          status: 503,
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{ message: { content: "not-json" } }],
          }),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "invalid_ai_response",
          detail: "not-json",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () =>
          Promise.reject(Object.assign(new Error("timed out"), {
            name: "AbortError",
          })),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 504);
        assertEquals(await response.json(), {
          error: "upstream_timeout",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new Error("socket hang up");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "upstream_request_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw "transport down";
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-food-label/index.ts",
        );
        const response = await handler(
          new Request("http://localhost/functions/v1/analyze-food-label", {
            method: "POST",
            headers: {
              Authorization: "Bearer label-token",
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              barcode: "4601234500007",
              images_base64: [TINY_PNG_DATA_URL],
            }),
          }),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "upstream_request_failed",
          detail: "internal_error",
        });
      });
    },
  );

  await t.step(
    "analyze-batch-recipe-image handles validation, auth, and upstream failures",
    async () => {
      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
      }, async (calls) => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const validPayload = {
          recipe_name: "Chili",
          total_weight_grams: 1000,
          portions_planned: 4,
          cooking_method: "stewed",
          known_ingredients: [],
          image_base64: TINY_PNG_DATA_URL,
        };

        let response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "OPTIONS",
            },
          ),
        );
        assertEquals(response.status, 204);
        assertEquals(
          response.headers.get("Access-Control-Allow-Methods"),
          "GET, POST, PATCH, PUT, DELETE, OPTIONS",
        );

        response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "GET",
            },
          ),
        );
        assertEquals(response.status, 405);
        assertEquals(await response.json(), { error: "method_not_allowed" });

        response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
              },
              body: JSON.stringify(validPayload),
            },
          ),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });

        response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: "{",
            },
          ),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "invalid_json" });

        response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                ...validPayload,
                known_ingredients: "not-an-array",
              }),
            },
          ),
        );
        assertEquals(response.status, 400);
        assertEquals((await response.json()).error, "invalid_payload");

        response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                ...validPayload,
                total_weight_grams: 0,
              }),
            },
          ),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), {
          error: "invalid_totals",
          detail: "total_weight_grams and portions_planned must be positive",
        });

        response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                ...validPayload,
                image_base64: "bad-image",
              }),
            },
          ),
        );
        assertEquals(response.status, 400);
        assertEquals(await response.json(), { error: "invalid_image_base64" });
        assertEquals(calls.openrouterRequests.length, 0);
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        authResponse: () => jsonResponse({ message: "bad jwt" }, 401),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 401);
        assertEquals(await response.json(), { error: "unauthorized" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () => jsonResponse({ message: "db blew up" }, 500),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "user_lookup_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        userLookupResponse: () => jsonResponse([], 200),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 404);
        assertEquals(await response.json(), { error: "user_not_found" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        rateLimitResponse: () =>
          jsonResponse([{
            ok: false,
            retry_after_seconds: 12,
            remaining: 0,
            reset_epoch_seconds: 1_717_171_717,
          }]),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        const payload = await response.json();
        assertEquals(response.status, 429);
        assertEquals(payload.error, "rate_limit_exceeded");
        assertEquals(payload.tier, "ai_vision");
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: null },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 500);
        assertEquals(await response.json(), {
          error: "openrouter_key_not_configured",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () =>
          new Response("batch upstream failed", { status: 500 }),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "openrouter_request_failed",
          status: 500,
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new DOMException("timed out", "AbortError");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 504);
        assertEquals(await response.json(), { error: "upstream_timeout" });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () => {
          throw new Error("network broke");
        },
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "upstream_request_failed",
          detail: "internal_error",
        });
      });

      await withMockedRuntime({
        env: { OPENROUTER_API_KEY: "openrouter-test-key" },
        openrouterResponse: () =>
          jsonResponse({
            choices: [{ message: { content: "not-json" } }],
          }),
      }, async () => {
        const handler = await captureEdgeHandler(
          "../analyze-batch-recipe-image/index.ts",
        );
        const response = await handler(
          new Request(
            "http://localhost/functions/v1/analyze-batch-recipe-image",
            {
              method: "POST",
              headers: {
                Authorization: "Bearer batch-token",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                recipe_name: "Chili",
                total_weight_grams: 1000,
                portions_planned: 4,
                cooking_method: "stewed",
                known_ingredients: [],
                image_base64: TINY_PNG_DATA_URL,
              }),
            },
          ),
        );
        assertEquals(response.status, 502);
        assertEquals(await response.json(), {
          error: "invalid_ai_response",
          detail: "not-json",
        });
      });
    },
  );
});

Deno.test("analyze-batch-recipe-image sanitizes prompt fallbacks and stringifies unknown upstream failures", async () => {
  await withMockedRuntime({
    env: { OPENROUTER_API_KEY: "openrouter-test-key" },
    openrouterResponse: (_request, body) => {
      const userMessage = ((body.messages as Array<Record<string, unknown>>)[1]
        ?.content as Array<Record<string, unknown>>)[0]?.text as string;
      assertStringIncludes(userMessage, '"recipe_name": ""');
      assertStringIncludes(userMessage, '"cooking_method": "unknown"');
      assertStringIncludes(userMessage, '"portion_size_grams": 300');
      return jsonResponse({
        choices: [{ message: { content: "{}" } }],
      });
    },
  }, async () => {
    const handler = await captureEdgeHandler(
      "../analyze-batch-recipe-image/index.ts",
    );
    const response = await handler(
      new Request("http://localhost/functions/v1/analyze-batch-recipe-image", {
        method: "POST",
        headers: {
          Authorization: "Bearer batch-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          recipe_name: "   ",
          total_weight_grams: 900,
          portions_planned: 3,
          known_ingredients: [{ name: "  Onion  ", raw_weight_g: 120 }],
          image_base64: TINY_PNG_DATA_URL,
        }),
      }),
    );

    assertEquals(response.status, 200);
    assertEquals((await response.json()).recipe_name, "");
  });

  await withMockedRuntime({
    env: { OPENROUTER_API_KEY: "openrouter-test-key" },
    openrouterResponse: () => {
      throw "socket closed";
    },
  }, async () => {
    const handler = await captureEdgeHandler(
      "../analyze-batch-recipe-image/index.ts",
    );
    const response = await handler(
      new Request("http://localhost/functions/v1/analyze-batch-recipe-image", {
        method: "POST",
        headers: {
          Authorization: "Bearer batch-token",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          recipe_name: "Soup",
          total_weight_grams: 900,
          portions_planned: 3,
          known_ingredients: [],
          image_base64: TINY_PNG_DATA_URL,
        }),
      }),
    );

    assertEquals(response.status, 502);
    assertEquals(await response.json(), {
      error: "upstream_request_failed",
      detail: "internal_error",
    });
  });
});

Deno.test("AI entrypoint helper hooks reject unsafe payload shapes", async () => {
  await captureEdgeHandler("../analyze-food-image/index.ts");
  await captureEdgeHandler("../analyze-food-label/index.ts");
  await captureEdgeHandler("../analyze-batch-recipe-image/index.ts");
  await captureEdgeHandler("../ai/openrouter-gateway/index.ts");

  const foodImage = await import("../analyze-food-image/index.ts");
  const foodLabel = await import("../analyze-food-label/index.ts");
  const batchRecipe = await import("../analyze-batch-recipe-image/index.ts");
  const gateway = await import("../ai/openrouter-gateway/index.ts");

  const imageHooks = foodImage.__analyzeFoodImageTestHooks;
  assertEquals(imageHooks.normalizeImageDataUrl(""), null);
  assertEquals(imageHooks.normalizeImageDataUrl("data:image/png,abc"), null);
  assertEquals(imageHooks.asTrimmedString(42, 10), null);
  assertEquals(
    imageHooks.extractMessageContent({
      choices: [{ message: { content: [{ type: "text" }, null] } }],
    }),
    "",
  );

  const labelHooks = foodLabel.__analyzeFoodLabelTestHooks;
  assertEquals(labelHooks.normalizeImageDataUrl(42), null);
  assertEquals(
    labelHooks.normalizeImageDataUrl("data:text/plain;base64,abc"),
    null,
  );
  assertEquals(labelHooks.cleanWarnings(["A", "a", "", "B"]).length, 2);
  assertEquals(labelHooks.extractMessageContent({ choices: [] }), "");
  assertEquals(labelHooks.localizedNarrativeLanguage("kk-KZ"), "kk-KZ");

  const batchHooks = batchRecipe.__analyzeBatchRecipeImageTestHooks;
  assertEquals(batchHooks.normalizeImageDataUrl(42), null);
  assertEquals(batchHooks.normalizeImageDataUrl("data:image/png,abc"), null);
  assertEquals(batchHooks.asTrimmedString(42, 10), null);
  assertEquals(batchHooks.extractMessageContent({ choices: [] }), "");

  const gatewayHooks = gateway.__openRouterGatewayTestHooks;
  assertEquals(gatewayHooks.sanitizeMessages("not-array"), null);
  assertEquals(gatewayHooks.sanitizeMessages([]), null);
  assertEquals(
    gatewayHooks.sanitizeMessages([{ role: "tool", content: "x" }]),
    null,
  );
  assertEquals(
    gatewayHooks.sanitizeMessages([{ role: "user", content: "   " }]),
    null,
  );
  assertEquals(
    gatewayHooks.sanitizeMessages([
      { role: "user", content: "x".repeat(20_001) },
    ]),
    null,
  );
  assertEquals(
    gatewayHooks.sanitizeMessages([
      { role: "user", content: [{ type: "text", text: "x".repeat(20_000) }] },
    ]),
    null,
  );
});
