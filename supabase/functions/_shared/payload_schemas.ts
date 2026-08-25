import { v } from "./runtime_schema.ts";

const NOTIFICATION_CATEGORIES = [
  "MORNING_BRIEF",
  "SUPPLEMENT_REMINDER",
  "MEAL_REMINDER",
  "RECOVERY_ALERT",
  "INSIGHT",
  "CELEBRATION",
  "EXPERIMENT",
] as const;

const NOTIFICATION_PRIORITIES = [
  "passive",
  "active",
  "time_sensitive",
] as const;

const INPUT_METHODS = [
  "vision",
  "barcode",
  "batch",
  "manual",
  "voice",
  "template",
] as const;

const MENSTRUAL_FLOWS = [
  "light",
  "medium",
  "heavy",
  "spotting",
] as const;

const CONTROL_LEVELS = [
  "advisory",
  "protective",
  "guardian",
] as const;

const MEAL_CONTEXTS = [
  "home",
  "restaurant",
  "party",
  "work",
  "other",
  "unknown",
] as const;

export const OpenRouterGatewayBodySchema = v.object({
  model: v.optional(v.string()),
  max_tokens: v.optional(v.number()),
  temperature: v.optional(v.number()),
  messages: v.optional(v.array(v.unknown())),
});

export const DeleteAccountBodySchema = v.object({
  immediate: v.optional(v.boolean()),
  reason: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(500))),
  ),
});

export const AnalyticsBatchEventSchema = v.object({
  name: v.optional(v.string()),
  timestamp: v.optional(v.string()),
  properties: v.optional(v.record(v.string(), v.unknown())),
  session_id: v.optional(v.string()),
});

export const AnalyticsBatchRequestSchema = v.object({
  events: v.optional(v.array(AnalyticsBatchEventSchema)),
  event_name: v.optional(v.string()),
  properties_json: v.optional(v.string()),
  created_at: v.optional(v.string()),
  session_id: v.optional(v.string()),
});

export const FoodLogPayloadSchema = v.object({
  id: v.optional(v.string()),
  user_id: v.optional(v.string()),
  logged_at: v.optional(v.string()),
  logged_date: v.optional(v.string()),
  logged_timezone: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(64))),
  ),
  logged_utc_offset_minutes: v.optional(v.nullable(v.number())),
  input_method: v.optional(v.picklist(INPUT_METHODS)),
  meal_type: v.optional(v.nullable(v.pipe(v.string(), v.maxLength(40)))),
  context: v.optional(v.nullable(v.pipe(v.string(), v.maxLength(240)))),
  pre_workout: v.optional(v.boolean()),
  post_workout: v.optional(v.boolean()),
  minutes_since_workout: v.optional(v.nullable(v.number())),
  calories: v.optional(v.number()),
  protein_g: v.optional(v.number()),
  fat_g: v.optional(v.number()),
  carbs_g: v.optional(v.number()),
  fiber_g: v.optional(v.nullable(v.number())),
  sugar_g: v.optional(v.nullable(v.number())),
  alcohol_units: v.optional(v.nullable(v.number())),
  caffeine_mg: v.optional(v.nullable(v.number())),
  sodium_mg: v.optional(v.nullable(v.number())),
  potassium_mg: v.optional(v.nullable(v.number())),
  calcium_mg: v.optional(v.nullable(v.number())),
  iron_mg: v.optional(v.nullable(v.number())),
  vitamin_d_mcg: v.optional(v.nullable(v.number())),
  vitamin_b12_mcg: v.optional(v.nullable(v.number())),
  image_url: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(2_048))),
  ),
  image_uploaded_at: v.optional(v.nullable(v.string())),
  ai_detected_items: v.optional(v.unknown()),
  ai_confidence: v.optional(v.nullable(v.number())),
  ai_context_analysis: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(1_000))),
  ),
  needs_review: v.optional(v.boolean()),
  user_corrected: v.optional(v.boolean()),
  user_notes: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(2_000))),
  ),
  ai_feedback: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(4_000))),
  ),
  ai_feedback_details: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(4_000))),
  ),
  ai_feedback_at: v.optional(v.nullable(v.string())),
  deleted_at: v.optional(v.nullable(v.string())),
  deleted_reason: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(120))),
  ),
  synced_to_vector_db: v.optional(v.boolean()),
  vector_id: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(128))),
  ),
});

export const InsightAcknowledgePayloadSchema = v.object({
  insight_id: v.optional(v.string()),
  acknowledged_at: v.optional(v.string()),
});

export const PredictEnvironmentalContextSchema = v.object({
  city: v.optional(v.pipe(v.string(), v.maxLength(100))),
  weather_condition: v.optional(v.pipe(v.string(), v.maxLength(50))),
  temperature_celsius: v.optional(
    v.pipe(v.number(), v.minValue(-90), v.maxValue(60)),
  ),
  aqi: v.optional(v.pipe(v.number(), v.minValue(0), v.maxValue(500))),
  moon_phase: v.optional(v.pipe(v.string(), v.maxLength(30))),
});

// MARK: - JSONB Field Schemas
// These schemas validate structured JSONB payloads before they hit the database.
// Prevents arbitrary/malformed data from being stored in untyped JSONB columns.

export const EnvironmentalContextSchema = v.object({
  weather_condition: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(50))),
  ),
  temperature_c: v.optional(
    v.nullable(v.pipe(v.number(), v.minValue(-90), v.maxValue(60))),
  ),
  pressure_hpa: v.optional(
    v.nullable(v.pipe(v.number(), v.minValue(800), v.maxValue(1100))),
  ),
  pressure_delta_hpa_24h: v.optional(
    v.nullable(v.pipe(v.number(), v.minValue(-50), v.maxValue(50))),
  ),
  aqi: v.optional(
    v.nullable(v.pipe(v.number(), v.minValue(0), v.maxValue(500))),
  ),
  indoor_co2_ppm: v.optional(
    v.nullable(v.pipe(v.number(), v.minValue(0), v.maxValue(10000))),
  ),
  moon_phase: v.optional(v.nullable(v.pipe(v.string(), v.maxLength(30)))),
  daylight_hours: v.optional(
    v.nullable(v.pipe(v.number(), v.minValue(0), v.maxValue(24))),
  ),
  city: v.optional(v.nullable(v.pipe(v.string(), v.maxLength(100)))),
});

export const AiExtractionRawSchema = v.object({
  model: v.optional(v.pipe(v.string(), v.maxLength(100))),
  prompt_version: v.optional(v.pipe(v.string(), v.maxLength(50))),
  raw_response: v.optional(v.string()),
  markers: v.optional(v.array(v.object({
    name: v.optional(v.string()),
    value: v.optional(v.number()),
    unit: v.optional(v.string()),
    confidence: v.optional(v.pipe(v.number(), v.minValue(0), v.maxValue(1))),
  }))),
  diagnoses: v.optional(v.array(v.object({
    text: v.optional(v.string()),
    severity: v.optional(v.string()),
    confidence: v.optional(v.pipe(v.number(), v.minValue(0), v.maxValue(1))),
  }))),
});

export const SegmentalDataSchema = v.record(
  v.string(),
  v.pipe(v.number(), v.minValue(0), v.maxValue(200)),
);

export const ImpedanceDataSchema = v.object({
  frequency_khz: v.optional(v.array(v.number())),
  impedance_ohm: v.optional(v.array(v.number())),
  phase_angle_deg: v.optional(v.number()),
});

export const PredictRequestSchema = v.object({
  target_date: v.optional(v.string()),
  scenario_text: v.optional(v.string()),
  scenario_type: v.optional(v.string()),
  environmental_context: v.optional(
    v.nullable(PredictEnvironmentalContextSchema),
  ),
});

export const AnalyzeFoodImageBodySchema = v.object({
  image_base64: v.optional(v.string()),
  context: v.optional(v.picklist(MEAL_CONTEXTS)),
  timestamp: v.optional(v.string()),
  pre_workout: v.optional(v.boolean()),
  post_workout: v.optional(v.boolean()),
  recent_activity: v.optional(v.string()),
  recovery_score: v.optional(v.number()),
  recognized_text: v.optional(v.string()),
  barcodes: v.optional(v.array(v.string())),
  locale: v.optional(v.string()),
});

export const AnalyzeFoodLabelBodySchema = v.object({
  barcode: v.optional(v.nullable(v.string())),
  locale: v.optional(v.string()),
  images_base64: v.array(v.string()),
});

export const AnalyzeBatchRecipeImageBodySchema = v.object({
  recipe_name: v.pipe(v.string(), v.maxLength(200)),
  total_weight_grams: v.number(),
  portions_planned: v.number(),
  cooking_method: v.optional(
    v.nullable(v.pipe(v.string(), v.maxLength(100))),
  ),
  known_ingredients: v.optional(
    v.pipe(
      v.array(
        v.object({
          name: v.pipe(v.string(), v.maxLength(160)),
          raw_weight_g: v.optional(v.number()),
        }),
      ),
      v.maxLength(50),
    ),
  ),
  image_base64: v.string(),
  locale: v.optional(v.pipe(v.string(), v.maxLength(32))),
});

export const ParseFoodTextBodySchema = v.object({
  text: v.optional(v.pipe(v.string(), v.maxLength(4_000))),
  locale: v.optional(v.pipe(v.string(), v.maxLength(32))),
  context: v.optional(v.picklist(MEAL_CONTEXTS)),
  meal_type: v.optional(v.pipe(v.string(), v.maxLength(40))),
});

export const MenstrualPayloadSchema = v.object({
  id: v.optional(v.string()),
  date: v.optional(v.string()),
  flow: v.optional(v.nullable(v.picklist(MENSTRUAL_FLOWS))),
  pain_level: v.optional(v.nullable(v.number())),
  deleted: v.optional(v.boolean()),
});

export const NotificationSettingsPayloadSchema = v.object({
  morning_brief_enabled: v.optional(v.boolean()),
  positive_enabled: v.optional(v.boolean()),
  nudges_enabled: v.optional(v.boolean()),
  celebration_enabled: v.optional(v.boolean()),
  critical_only: v.optional(v.boolean()),
  morning_brief_time_local: v.optional(v.string()),
  quiet_hours_start: v.optional(v.string()),
  quiet_hours_end: v.optional(v.string()),
  max_positive_per_day: v.optional(v.number()),
  max_nudges_per_day: v.optional(v.number()),
  max_celebration_per_day: v.optional(v.number()),
  max_total_per_day: v.optional(v.number()),
  control_level: v.optional(v.picklist(CONTROL_LEVELS)),
  focus_control_enabled: v.optional(v.boolean()),
});

export const PrivacyPayloadSchema = v.object({
  menstrual_local_only: v.optional(v.boolean()),
  medical_scan_local_only: v.optional(v.boolean()),
  vector_opt_in: v.optional(v.boolean()),
  analytics_consent: v.optional(v.boolean()),
  cloud_ocr_enabled: v.optional(v.boolean()),
  cloud_backup_enabled: v.optional(v.boolean()),
});

export const ConsentPayloadSchema = v.object({
  id: v.optional(v.string()),
  consent_type: v.optional(v.string()),
  granted: v.optional(v.boolean()),
  version: v.optional(v.string()),
  ip_address: v.optional(v.nullable(v.string())),
  timestamp: v.optional(v.string()),
});

export const SupplementLogPayloadSchema = v.object({
  supplement_name: v.optional(v.string()),
  scheduled_time: v.optional(v.string()),
  taken_at: v.optional(v.string()),
});

export const ExportRequestBodySchema = v.object({
  export_id: v.optional(v.string()),
});

export const ExportStatusRequestBodySchema = v.object({
  export_id: v.optional(v.string()),
});

export const WatchSnapshotPostBodySchema = v.object({
  date: v.optional(v.string()),
});

export const SendNotificationPayloadSchema = v.object({
  user_id: v.optional(v.string()),
  title: v.pipe(v.string(), v.maxLength(120)),
  body: v.pipe(v.string(), v.maxLength(500)),
  category: v.picklist(NOTIFICATION_CATEGORIES),
  priority: v.picklist(NOTIFICATION_PRIORITIES),
  deep_link: v.optional(v.pipe(v.string(), v.maxLength(256))),
  scheduled_at_local: v.optional(v.pipe(v.string(), v.maxLength(40))),
  delivery_mode: v.optional(v.picklist(["remote_only", "local_scheduled"])),
});

export const PushDevicePayloadSchema = v.object({
  device_id: v.optional(v.pipe(v.string(), v.maxLength(128))),
  push_token: v.optional(v.pipe(v.string(), v.maxLength(512))),
  platform: v.optional(v.pipe(v.string(), v.maxLength(32))),
  environment: v.optional(v.pipe(v.string(), v.maxLength(16))),
  locale: v.optional(v.pipe(v.string(), v.maxLength(32))),
  timezone: v.optional(v.pipe(v.string(), v.maxLength(64))),
  app_version: v.optional(v.pipe(v.string(), v.maxLength(32))),
  build_number: v.optional(v.pipe(v.string(), v.maxLength(32))),
});
