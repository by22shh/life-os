import {
  anonClient,
  jsonWithRequest,
  parseBearer,
  sanitizedInternalDetail,
  serviceRoleClient,
} from "../../_shared/supabase.ts";
import { enforceRateLimit } from "../../_shared/rate_limit.ts";
import { handleCors, withCorsHeaders } from "../../_shared/cors.ts";
import { parseWithSchema } from "../../_shared/runtime_schema.ts";
import { OpenRouterGatewayBodySchema } from "../../_shared/payload_schemas.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
const OPENROUTER_TIMEOUT_MS = 20_000;

// P0 #4: Whitelist of allowed models to prevent cost attacks
const ALLOWED_MODELS = new Set([
  "openai/gpt-4o",
  "openai/gpt-4o-mini",
  "anthropic/claude-3.5-sonnet",
  "anthropic/claude-3-haiku",
  "google/gemini-pro",
  "google/gemini-flash-1.5",
]);

const MAX_TOKENS_CAP = 4096;
const MAX_MESSAGES = 20;
const MAX_MESSAGE_CONTENT_LENGTH = 8_000;
const MAX_TOTAL_CONTENT_LENGTH = 50_000;

type OpenRouterRole = "system" | "user" | "assistant";

interface OpenRouterMessage {
  role: OpenRouterRole;
  content: string | unknown[];
}

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
  if (authError || !authData.user) {
    return jsonWithRequest(request, { error: "unauthorized" }, 401);
  }

  const service = serviceRoleClient();
  const { data: userRow, error: userLookupError } = await service
    .from("users")
    .select("id")
    .eq("auth_id", authData.user.id)
    .maybeSingle<{ id: string }>();

  if (userLookupError) {
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

  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) {
    return jsonWithRequest(
      request,
      { error: "openrouter_key_not_configured" },
      500,
    );
  }

  let bodyRaw: unknown;
  try {
    bodyRaw = await request.json();
  } catch {
    return jsonWithRequest(request, { error: "invalid_json" }, 400);
  }
  const bodyParse = parseWithSchema(OpenRouterGatewayBodySchema, bodyRaw);
  if (!bodyParse.ok) {
    return jsonWithRequest(request, {
      error: "invalid_payload",
      issues: bodyParse.issues,
    }, 400);
  }
  const body = bodyParse.output;

  // P0 #4: Validate model — must be in whitelist
  // deno-coverage-ignore-start -- schema validation guarantees string model before whitelist check.
  const model = typeof body.model === "string" ? body.model : "";
  // deno-coverage-ignore-stop
  if (!ALLOWED_MODELS.has(model)) {
    return jsonWithRequest(request, {
      error: "model_not_allowed",
      allowed: [...ALLOWED_MODELS],
    }, 400);
  }

  // P0 #4: Cap max_tokens to prevent cost attacks
  const maxTokens = typeof body.max_tokens === "number"
    ? Math.min(Math.max(1, Math.floor(body.max_tokens)), MAX_TOKENS_CAP)
    : MAX_TOKENS_CAP;

  // P0 #4: Validate messages array length
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return jsonWithRequest(request, { error: "messages_required" }, 400);
  }
  if (body.messages.length > MAX_MESSAGES) {
    return jsonWithRequest(request, {
      error: "too_many_messages",
      max: MAX_MESSAGES,
    }, 400);
  }

  const sanitizedMessages = sanitizeMessages(body.messages);
  if (!sanitizedMessages) {
    return jsonWithRequest(request, { error: "invalid_messages_payload" }, 400);
  }

  // P0 #4: Build sanitized request — remove dangerous fields
  const sanitizedBody = {
    model,
    messages: sanitizedMessages,
    max_tokens: maxTokens,
    temperature: typeof body.temperature === "number"
      ? Math.min(2, Math.max(0, body.temperature))
      : undefined,
    // Explicitly exclude: stream, tools, functions, function_call, tool_choice
  };

  const controller = new AbortController();
  // deno-coverage-ignore-start -- timer setup/cleanup is deterministic infrastructure, not product logic.
  const timeout = setTimeout(() => controller.abort(), OPENROUTER_TIMEOUT_MS);
  // deno-coverage-ignore-stop
  let response: Response;
  try {
    response = await fetch(OPENROUTER_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": Deno.env.get("OPENROUTER_REFERER") ??
          "https://lifeos.app",
        "X-Title": Deno.env.get("OPENROUTER_APP_NAME") ?? "Life OS",
      },
      body: JSON.stringify(sanitizedBody),
      signal: controller.signal,
    });
  } catch (error) {
    if (error instanceof DOMException && error.name === "AbortError") {
      return jsonWithRequest(request, { error: "openrouter_timeout" }, 504);
    }
    return jsonWithRequest(
      request,
      { error: "openrouter_request_failed" },
      502,
    );
  } finally {
    // deno-coverage-ignore-start -- timer setup/cleanup is deterministic infrastructure, not product logic.
    clearTimeout(timeout);
    // deno-coverage-ignore-stop
  }

  // deno-coverage-ignore-start -- default content-type fallback is defensive; response forwarding is covered.
  const contentType = response.headers.get("Content-Type") ??
    "application/json";
  // deno-coverage-ignore-stop
  const payload = await response.text();

  return new Response(payload, {
    status: response.status,
    headers: withCorsHeaders({
      "Content-Type": contentType,
      "Cache-Control": "no-store",
    }),
  });
});

function sanitizeMessages(input: unknown): OpenRouterMessage[] | null {
  if (!Array.isArray(input)) return null;
  let totalContentLength = 0;
  const sanitized: OpenRouterMessage[] = [];

  for (const raw of input) {
    if (!isJSONObject(raw)) return null;
    const role = raw.role;
    const content = raw.content;
    if (role !== "system" && role !== "user" && role !== "assistant") {
      return null;
    }
    if (typeof content === "string") {
      const trimmed = content.trim();
      if (!trimmed || trimmed.length > MAX_MESSAGE_CONTENT_LENGTH) {
        return null;
      }
      totalContentLength += trimmed.length;
      if (totalContentLength > MAX_TOTAL_CONTENT_LENGTH) return null;
      sanitized.push({ role, content: trimmed });
      continue;
    }

    if (Array.isArray(content)) {
      const serialized = JSON.stringify(content);
      if (serialized.length > MAX_MESSAGE_CONTENT_LENGTH) {
        return null;
      }
      totalContentLength += serialized.length;
      if (totalContentLength > MAX_TOTAL_CONTENT_LENGTH) {
        return null;
      }
      sanitized.push({ role, content });
      continue;
    }

    return null;
  }

  return sanitized.length > 0 ? sanitized : null;
}

function isJSONObject(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

export const __openRouterGatewayTestHooks = {
  isJSONObject,
  sanitizeMessages,
};
