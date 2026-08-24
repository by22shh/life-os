import { assertEquals } from "https://deno.land/std@0.224.0/assert/assert_equals.ts";
import { parseWithSchema, v } from "../_shared/runtime_schema.ts";
import {
  AnalyticsBatchRequestSchema,
  AnalyzeFoodImageBodySchema,
  ConsentPayloadSchema,
  DeleteAccountBodySchema,
  ExportRequestBodySchema,
  ExportStatusRequestBodySchema,
  FoodLogPayloadSchema,
  InsightAcknowledgePayloadSchema,
  MenstrualPayloadSchema,
  NotificationSettingsPayloadSchema,
  OpenRouterGatewayBodySchema,
  PredictRequestSchema,
  PrivacyPayloadSchema,
  PushDevicePayloadSchema,
  SendNotificationPayloadSchema,
  SupplementLogPayloadSchema,
  WatchSnapshotPostBodySchema,
} from "../_shared/payload_schemas.ts";

type RuntimeSchema = v.BaseSchema<unknown, unknown, v.BaseIssue<unknown>>;

function expectInvalid<TSchema extends RuntimeSchema>(
  schema: TSchema,
  input: unknown,
): void {
  const parsed = parseWithSchema(schema, input);
  assertEquals(parsed.ok, false);
}

function expectValid<TSchema extends RuntimeSchema>(
  schema: TSchema,
  input: unknown,
): void {
  const parsed = parseWithSchema(schema, input);
  assertEquals(parsed.ok, true);
}

Deno.test("openrouter schema rejects malformed payload", () => {
  expectInvalid(OpenRouterGatewayBodySchema, {
    model: "openai/gpt-4o",
    messages: "should_be_array",
  });
});

Deno.test("delete-account schema rejects malformed payload", () => {
  expectInvalid(DeleteAccountBodySchema, {
    immediate: "yes",
    reason: 123,
  });
});

Deno.test("analytics batch schema rejects malformed payload", () => {
  expectInvalid(AnalyticsBatchRequestSchema, {
    events: "not_array",
  });
});

Deno.test("food log schema rejects malformed payload", () => {
  expectInvalid(FoodLogPayloadSchema, {
    id: "c8f64186-7d89-4b11-9d9d-13f8d2b94e4f",
    logged_at: "2026-02-22T10:00:00.000Z",
    logged_date: "2026-02-22",
    input_method: "manual",
    calories: "450",
  });
});

Deno.test("insight acknowledge schema rejects malformed payload", () => {
  expectInvalid(InsightAcknowledgePayloadSchema, {
    insight_id: 100,
  });
});

Deno.test("predict schema rejects malformed payload", () => {
  expectInvalid(PredictRequestSchema, {
    target_date: 20260222,
    scenario_text: "sleep less",
    scenario_type: "sleep",
  });
});

Deno.test("analyze-food-image schema rejects malformed payload", () => {
  expectInvalid(AnalyzeFoodImageBodySchema, {
    image_base64: 42,
    barcodes: "4601234567890",
  });
});

Deno.test("analyze-food-image schema accepts valid payload", () => {
  expectValid(AnalyzeFoodImageBodySchema, {
    image_base64: "data:image/jpeg;base64,ZmFrZQ==",
    context: "restaurant",
    timestamp: "2026-03-14T12:30:00Z",
    post_workout: true,
    recognized_text: "Chicken bowl",
    barcodes: ["4601234567890"],
    locale: "ru-RU",
  });
});

Deno.test("menstrual schema rejects malformed payload", () => {
  expectInvalid(MenstrualPayloadSchema, {
    id: "c8f64186-7d89-4b11-9d9d-13f8d2b94e4f",
    pain_level: "high",
  });
});

Deno.test("notification settings schema rejects malformed payload", () => {
  expectInvalid(NotificationSettingsPayloadSchema, {
    critical_only: false,
    max_total_per_day: "6",
  });
});

Deno.test("privacy schema rejects malformed payload", () => {
  expectInvalid(PrivacyPayloadSchema, {
    analytics_consent: "true",
  });
});

Deno.test("consent schema rejects malformed payload", () => {
  expectInvalid(ConsentPayloadSchema, {
    consent_type: "privacy.analytics",
    granted: "yes",
    version: "1.0",
  });
});

Deno.test("supplement schema rejects malformed payload", () => {
  expectInvalid(SupplementLogPayloadSchema, {
    supplement_name: 12,
  });
});

Deno.test("export schema rejects malformed payload", () => {
  expectInvalid(ExportRequestBodySchema, {
    export_id: 99,
  });
});

Deno.test("export status schema rejects malformed payload", () => {
  expectInvalid(ExportStatusRequestBodySchema, {
    export_id: 99,
  });
});

Deno.test("watch snapshot schema rejects malformed payload", () => {
  expectInvalid(WatchSnapshotPostBodySchema, {
    date: 20260222,
  });
});

Deno.test("send-notification schema rejects malformed payload", () => {
  expectInvalid(SendNotificationPayloadSchema, {
    title: "Recovery Alert",
    body: "Your score dropped",
    category: "RECOVERY_ALERT",
    priority: "urgent",
  });
});

Deno.test("send-notification schema accepts valid payload", () => {
  expectValid(SendNotificationPayloadSchema, {
    title: "Recovery Alert",
    body: "Your score dropped",
    category: "RECOVERY_ALERT",
    priority: "time_sensitive",
    deep_link: "lifeos://home",
    delivery_mode: "remote_only",
  });
});

Deno.test("send-notification schema rejects invalid delivery mode", () => {
  expectInvalid(SendNotificationPayloadSchema, {
    title: "Recovery Alert",
    body: "Your score dropped",
    category: "RECOVERY_ALERT",
    priority: "time_sensitive",
    delivery_mode: "server_only",
  });
});

Deno.test("push-device schema rejects malformed payload", () => {
  expectInvalid(PushDevicePayloadSchema, {
    device_id: 42,
    push_token: ["bad"],
  });
});

Deno.test("push-device schema accepts valid payload", () => {
  expectValid(PushDevicePayloadSchema, {
    device_id: "device-123",
    push_token: "abcdef123456",
    platform: "ios",
    environment: "development",
    locale: "ru-RU",
    timezone: "Asia/Novosibirsk",
    app_version: "1.0",
    build_number: "42",
  });
});
