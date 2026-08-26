// MARK: - GRDB Migrations
// Source of truth: life_os_api_specification.md (full schema)
// life_os_sync_engine_spec.md §4 (sync tables)

import Foundation
import GRDB

enum Migrations {

    /// Keep in sync with the latest registered migration version.
    static let latestSchemaVersion = 31

    static func registerAll(migrator: inout DatabaseMigrator) {
        registerV1(migrator: &migrator)
    }

    // MARK: - V1: Initial Schema

    private static func registerV1(migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial") { db in

            // ────────────────────────────────────────────
            // SYNC INFRASTRUCTURE
            // ────────────────────────────────────────────

            try db.create(table: "local_meta") { t in
                t.column("device_id", .text).notNull().primaryKey()
                t.column("schema_version", .integer).notNull()
            }

            try db.create(table: "sync_state") { t in
                t.column("table_name", .text).notNull().primaryKey()
                t.column("last_pulled_at_server", .datetime)
                t.column("last_pull_attempt_at", .datetime)
                t.column("last_pull_success_at", .datetime)
                t.column("last_error_code", .text)
            }

            try db.create(table: "outbox_events") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("created_at_local", .datetime).notNull()
                t.column("updated_at_local", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("priority", .integer).notNull().defaults(to: 100)
                t.column("depends_on", .text)
                // Request envelope
                t.column("http_method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("headers_json", .blob).notNull()
                t.column("body_json", .blob).notNull()
                // Tracking
                t.column("attempt_count", .integer).notNull().defaults(to: 0)
                t.column("next_attempt_at", .datetime)
                t.column("last_attempt_at", .datetime)
                t.column("last_error_category", .text)
                t.column("last_error_code", .text)
                t.column("last_error_message", .text)
                // UX
                t.column("user_visible_blocker", .boolean).notNull().defaults(to: false)
                t.column("ui_hint_json", .blob)
            }
            try db.create(index: "idx_outbox_status", on: "outbox_events", columns: ["status", "priority", "created_at_local"])

            // ────────────────────────────────────────────
            // USERS & SETTINGS
            // ────────────────────────────────────────────

            try db.create(table: "users") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("auth_id", .text).notNull()
                t.column("email", .text)
                t.column("display_name", .text)
                t.column("date_of_birth", .date)
                t.column("age_range", .text)
                t.column("sex", .text)
                t.column("height_cm", .double)
                t.column("weight_kg", .double)
                t.column("primary_goal", .text)
                t.column("activity_level", .text)
                t.column("baseline_hrv_ms", .double)
                t.column("baseline_rhr_bpm", .integer)
                t.column("baseline_sleep_hours", .double)
                t.column("timezone", .text).notNull().defaults(to: "UTC")
                t.column("units", .text).notNull().defaults(to: "metric")
                t.column("notification_enabled", .boolean).notNull().defaults(to: true)
                t.column("onboarding_completed", .boolean).notNull().defaults(to: false)
                t.column("calibration_days_remaining", .integer).notNull().defaults(to: 3)
                t.column("deletion_scheduled_at", .datetime)
                t.column("deletion_reason", .text)
                t.column("deletion_in_progress", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "user_health_flags") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("has_cardiac_condition", .boolean).notNull().defaults(to: false)
                t.column("has_pacemaker", .boolean).notNull().defaults(to: false)
                t.column("on_beta_blockers", .boolean).notNull().defaults(to: false)
                t.column("is_pregnant", .boolean).notNull().defaults(to: false)
                t.column("menstrual_tracking_enabled", .boolean).notNull().defaults(to: false)
                t.column("has_eating_disorder_history", .boolean).notNull().defaults(to: false)
                t.column("has_chronic_fatigue", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "notification_settings") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("morning_brief_enabled", .boolean).notNull().defaults(to: true)
                t.column("positive_enabled", .boolean).notNull().defaults(to: true)
                t.column("nudges_enabled", .boolean).notNull().defaults(to: true)
                t.column("celebration_enabled", .boolean).notNull().defaults(to: true)
                t.column("critical_only", .boolean).notNull().defaults(to: false)
                t.column("morning_brief_time_local", .text).notNull().defaults(to: "07:00")
                t.column("quiet_hours_start", .text).notNull().defaults(to: "22:00")
                t.column("quiet_hours_end", .text).notNull().defaults(to: "07:00")
                t.column("max_positive_per_day", .integer).notNull().defaults(to: 3)
                t.column("max_nudges_per_day", .integer).notNull().defaults(to: 2)
                t.column("max_celebration_per_day", .integer).notNull().defaults(to: 2)
                t.column("max_total_per_day", .integer).notNull().defaults(to: 6)
                t.column("control_level", .text).notNull().defaults(to: "advisory")
                t.column("focus_control_enabled", .boolean).notNull().defaults(to: false)
                t.column("focus_control_last_granted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // ────────────────────────────────────────────
            // ONBOARDING & PRIVACY
            // ────────────────────────────────────────────

            try db.create(table: "onboarding_state") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().unique()
                    .references("users", onDelete: .cascade)
                t.column("step", .text).notNull().defaults(to: "not_started")
                t.column("completed_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_onboarding_state_user", on: "onboarding_state", columns: ["user_id"])

            try db.create(table: "user_baselines") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().unique()
                    .references("users", onDelete: .cascade)
                t.column("hrv_ln_rmssd_baseline", .double)
                t.column("rhr_baseline", .double)
                t.column("sleep_baseline_hours", .double)
                t.column("data_days_available", .integer).notNull().defaults(to: 0)
                t.column("baseline_confidence", .double).notNull().defaults(to: 0)
                t.column("last_computed_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_user_baselines_user", on: "user_baselines", columns: ["user_id"])

            try db.create(table: "privacy_settings") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().unique()
                    .references("users", onDelete: .cascade)
                t.column("menstrual_local_only", .boolean).notNull().defaults(to: true)
                t.column("medical_scan_local_only", .boolean).notNull().defaults(to: true)
                t.column("vector_opt_in", .boolean).notNull().defaults(to: false)
                t.column("analytics_consent", .boolean).notNull().defaults(to: false)
                t.column("cloud_ocr_enabled", .boolean).notNull().defaults(to: true)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_privacy_settings_user", on: "privacy_settings", columns: ["user_id"])

            // ────────────────────────────────────────────
            // RECOVERY & PHYSIOLOGICAL STATE
            // ────────────────────────────────────────────

            try db.create(table: "physiological_states") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("hrv_ms", .double)
                t.column("hrv_score", .double)
                t.column("resting_heart_rate_bpm", .integer)
                t.column("rhr_score", .double)
                t.column("wrist_temperature_deviation_c", .double)
                t.column("temp_score", .double)
                t.column("sleep_duration_hours", .double)
                t.column("sleep_quality_percent", .double)
                t.column("sleep_score", .double)
                t.column("recovery_score", .double).notNull()
                t.column("recovery_zone", .text).notNull()
                t.column("micro_zone", .text)
                t.column("respiratory_rate_bpm", .double)
                t.column("blood_oxygen_percent", .double)
                t.column("autonomic_state", .text)
                t.column("allostatic_load", .double)
                t.column("deep_sleep_percent", .double)
                t.column("rem_sleep_percent", .double)
                t.column("light_sleep_percent", .double)
                t.column("awake_percent", .double)
                t.column("active_calories", .integer)
                t.column("total_calories", .integer)
                t.column("steps", .integer)
                t.column("exercise_minutes", .integer)
                t.column("environmental_context", .blob)
                t.column("data_completeness", .double)
                t.column("confidence_score", .double)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["user_id", "date"])
            }

            // ────────────────────────────────────────────
            // NUTRITION
            // ────────────────────────────────────────────

            try db.create(table: "food_logs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("logged_at", .datetime).notNull()
                t.column("logged_date", .text).notNull()
                t.column("logged_timezone", .text)
                t.column("logged_utc_offset_minutes", .integer)
                t.column("input_method", .text).notNull()
                t.column("meal_type", .text)
                t.column("context", .text)
                t.column("pre_workout", .boolean).notNull().defaults(to: false)
                t.column("post_workout", .boolean).notNull().defaults(to: false)
                t.column("minutes_since_workout", .integer)
                t.column("calories", .double).notNull()
                t.column("protein_g", .double).notNull()
                t.column("fat_g", .double).notNull()
                t.column("carbs_g", .double).notNull()
                t.column("fiber_g", .double)
                t.column("sugar_g", .double)
                t.column("alcohol_units", .double)
                t.column("caffeine_mg", .integer)
                t.column("sodium_mg", .double)
                t.column("potassium_mg", .double)
                t.column("calcium_mg", .double)
                t.column("iron_mg", .double)
                t.column("vitamin_d_mcg", .double)
                t.column("vitamin_b12_mcg", .double)
                t.column("image_url", .text)
                t.column("image_uploaded_at", .datetime)
                t.column("ai_detected_items", .blob)
                t.column("ai_confidence", .double)
                t.column("ai_context_analysis", .text)
                t.column("user_corrected", .boolean).notNull().defaults(to: false)
                t.column("user_notes", .text)
                t.column("ai_feedback", .text)
                t.column("ai_feedback_details", .text)
                t.column("ai_feedback_at", .datetime)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
                t.column("synced_to_vector_db", .boolean).notNull().defaults(to: false)
                t.column("vector_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_food_logs_user_date", on: "food_logs",
                          columns: ["user_id", "logged_date"],
                          condition: Column("deleted_at") == nil)

            try db.create(table: "food_items") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("food_log_id", .text).notNull()
                    .references("food_logs", onDelete: .cascade)
                t.column("user_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("brand", .text)
                t.column("barcode", .text)
                t.column("catalog_item_id", .text)
                t.column("user_food_id", .text)
                t.column("batch_recipe_id", .text)
                t.column("weight_g", .double).notNull()
                t.column("calories", .double).notNull()
                t.column("protein_g", .double).notNull()
                t.column("fat_g", .double).notNull()
                t.column("carbs_g", .double).notNull()
                t.column("fiber_g", .double)
                t.column("confidence", .double)
                t.column("detected_by_ai", .boolean).notNull().defaults(to: false)
                t.column("user_adjusted", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_food_items_log", on: "food_items", columns: ["food_log_id"])

            try db.create(table: "daily_nutrition_targets") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("base_calories", .integer)
                t.column("base_protein_g", .integer)
                t.column("base_fat_g", .integer)
                t.column("base_carbs_g", .integer)
                t.column("training_adjustment_kcal", .integer)
                t.column("recovery_adjustment_kcal", .integer)
                t.column("final_calories", .integer)
                t.column("final_protein_g", .integer)
                t.column("final_fat_g", .integer)
                t.column("final_carbs_g", .integer)
                t.column("adjustment_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["user_id", "date"])
            }

            try db.create(table: "food_catalog_items") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("provider", .text).notNull()
                t.column("provider_item_id", .text)
                t.column("barcode", .text)
                t.column("created_by_user_id", .text)
                t.column("name", .text).notNull()
                t.column("brand", .text)
                t.column("locale", .text)
                t.column("image_url", .text)
                t.column("serving_size_g", .double)
                t.column("calories_per_100g", .double).notNull()
                t.column("protein_per_100g", .double).notNull()
                t.column("fat_per_100g", .double).notNull()
                t.column("carbs_per_100g", .double).notNull()
                t.column("fiber_per_100g", .double)
                t.column("sugar_per_100g", .double)
                t.column("sodium_mg_per_100g", .double)
                t.column("source_confidence", .double)
                t.column("fetched_at", .datetime).notNull()
                t.column("expires_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_food_catalog_barcode", on: "food_catalog_items",
                          columns: ["barcode"], condition: Column("barcode") != nil)

            try db.create(table: "user_foods") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("brand", .text)
                t.column("barcode", .text)
                t.column("default_serving_g", .double)
                t.column("calories_per_100g", .double).notNull()
                t.column("protein_per_100g", .double).notNull()
                t.column("fat_per_100g", .double).notNull()
                t.column("carbs_per_100g", .double).notNull()
                t.column("fiber_per_100g", .double)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "user_food_favorites") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("ref_type", .text).notNull()
                t.column("ref_id", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["user_id", "ref_type", "ref_id"])
            }

            try db.create(table: "batch_recipes") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("image_url", .text)
                t.column("total_weight_g", .double).notNull()
                t.column("total_portions", .integer)
                t.column("total_calories", .double).notNull()
                t.column("total_protein_g", .double).notNull()
                t.column("total_fat_g", .double).notNull()
                t.column("total_carbs_g", .double).notNull()
                t.column("total_fiber_g", .double)
                t.column("cooked_at", .text)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("times_used", .integer).notNull().defaults(to: 0)
                t.column("last_used_at", .datetime)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "batch_recipe_ingredients") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("batch_recipe_id", .text).notNull()
                    .references("batch_recipes", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("brand", .text)
                t.column("barcode", .text)
                t.column("catalog_item_id", .text)
                t.column("user_food_id", .text)
                t.column("weight_g", .double).notNull()
                t.column("calories", .double).notNull()
                t.column("protein_g", .double).notNull()
                t.column("fat_g", .double).notNull()
                t.column("carbs_g", .double).notNull()
                t.column("fiber_g", .double)
                t.column("sugar_g", .double)
                t.column("sodium_mg", .double)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "meal_templates") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("meal_type", .text)
                t.column("template_items", .blob).notNull()
                t.column("calories", .double).notNull()
                t.column("protein_g", .double).notNull()
                t.column("fat_g", .double).notNull()
                t.column("carbs_g", .double).notNull()
                t.column("fiber_g", .double)
                t.column("times_used", .integer).notNull().defaults(to: 0)
                t.column("last_used_at", .datetime)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // ────────────────────────────────────────────
            // TRAINING
            // ────────────────────────────────────────────

            try db.create(table: "exercise_catalog") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("category", .text).notNull()
                t.column("primary_muscles", .text).notNull().defaults(to: "[]")
                t.column("secondary_muscles", .text).notNull().defaults(to: "[]")
                t.column("equipment", .text).notNull().defaults(to: "[]")
                t.column("movement_pattern", .text)
                t.column("unilateral", .boolean).notNull().defaults(to: false)
                t.column("difficulty", .text)
                t.column("instructions", .text)
                t.column("video_url", .text)
                t.column("is_custom", .boolean).notNull().defaults(to: false)
                t.column("created_by", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "training_plans") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("goal", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "active")
                t.column("start_date", .text)
                t.column("end_date", .text)
                t.column("duration_weeks", .integer)
                t.column("days_per_week", .integer)
                t.column("current_week", .integer).notNull().defaults(to: 1)
                t.column("ai_generated", .boolean).notNull().defaults(to: false)
                t.column("plan_json", .blob).notNull()
                t.column("adaptive_rules", .blob)
                t.column("last_adjusted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "workout_sessions") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("started_at", .datetime).notNull()
                t.column("session_date", .text).notNull()
                t.column("started_timezone", .text)
                t.column("started_utc_offset_minutes", .integer)
                t.column("ended_at", .datetime)
                t.column("duration_minutes", .integer)
                t.column("source", .text).notNull()
                t.column("import_provider", .text)
                t.column("import_source_id", .text)
                t.column("workout_type", .text)
                t.column("location", .text)
                t.column("pre_recovery_score", .double)
                t.column("pre_energy_level", .integer)
                t.column("total_volume", .double)
                t.column("total_sets", .integer)
                t.column("total_reps", .integer)
                t.column("estimated_calories", .integer)
                t.column("trimp_score", .double)
                t.column("perceived_exertion_rpe", .integer)
                t.column("post_feeling", .integer)
                t.column("notes", .text)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
                t.column("training_plan_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_workout_sessions_user", on: "workout_sessions",
                          columns: ["user_id", "started_at"],
                          condition: Column("deleted_at") == nil)

            try db.create(table: "workout_exercises") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("session_id", .text).notNull()
                    .references("workout_sessions", onDelete: .cascade)
                t.column("exercise_id", .text)
                t.column("order_in_session", .integer)
                t.column("total_sets", .integer)
                t.column("total_reps", .integer)
                t.column("total_volume", .double)
                t.column("max_weight", .double)
                t.column("duration_seconds", .integer)
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "workout_sets") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("exercise_entry_id", .text).notNull()
                    .references("workout_exercises", onDelete: .cascade)
                t.column("user_id", .text).notNull()
                t.column("set_number", .integer).notNull()
                t.column("weight", .double)
                t.column("reps", .integer)
                t.column("rpe", .integer)
                t.column("tempo", .text)
                t.column("is_warmup", .boolean).notNull().defaults(to: false)
                t.column("is_failure", .boolean).notNull().defaults(to: false)
                t.column("is_dropset", .boolean).notNull().defaults(to: false)
                t.column("rest_after_seconds", .integer)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "training_plan_sessions") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("training_plan_id", .text).notNull()
                    .references("training_plans", onDelete: .cascade)
                t.column("user_id", .text).notNull()
                t.column("planned_date", .text).notNull()
                t.column("session_type", .text).notNull()
                t.column("planned_duration_minutes", .integer)
                t.column("title", .text)
                t.column("session_json", .blob)
                t.column("status", .text).notNull().defaults(to: "planned")
                t.column("linked_workout_id", .text)
                t.column("skipped_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "training_loads") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("date", .text).notNull()
                t.column("daily_trimp", .double)
                t.column("daily_duration_minutes", .integer)
                t.column("daily_active_calories", .integer)
                t.column("workout_count", .integer).notNull().defaults(to: 0)
                t.column("avg_heart_rate_bpm", .integer)
                t.column("peak_heart_rate_bpm", .integer)
                t.column("zone1_minutes", .integer).notNull().defaults(to: 0)
                t.column("zone2_minutes", .integer).notNull().defaults(to: 0)
                t.column("zone3_minutes", .integer).notNull().defaults(to: 0)
                t.column("zone4_minutes", .integer).notNull().defaults(to: 0)
                t.column("zone5_minutes", .integer).notNull().defaults(to: 0)
                t.column("acute_load_7d", .double)
                t.column("chronic_load_28d", .double)
                t.column("acwr", .double)
                t.column("training_zone", .text)
                t.column("weekly_trend", .text)
                t.column("monotony_7d", .double)
                t.column("strain_7d", .double)
                t.column("fitness_ctl", .double)
                t.column("fatigue_atl", .double)
                t.column("form_tsb", .double)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["user_id", "date"])
            }

            // ────────────────────────────────────────────
            // SUPPLEMENTS
            // ────────────────────────────────────────────

            try db.create(table: "supplement_catalog") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull().unique()
                t.column("category", .text).notNull()
                t.column("description", .text)
                t.column("best_time", .text)
                t.column("take_with_food", .boolean).notNull().defaults(to: false)
                t.column("evidence_level", .text)
                t.column("primary_benefits", .text).notNull().defaults(to: "[]")
                t.column("avoid_with", .text).notNull().defaults(to: "[]")
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "user_supplements") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("catalog_id", .text)
                t.column("custom_name", .text)
                t.column("dose_amount", .double)
                t.column("dose_unit", .text).notNull().defaults(to: "mg")
                t.column("frequency", .text).notNull()
                t.column("scheduled_times", .text).notNull().defaults(to: "[]")
                t.column("days_of_week", .text)
                t.column("take_with_food", .boolean).notNull().defaults(to: false)
                t.column("notes", .text)
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("started_at", .text).notNull()
                t.column("ended_at", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "supplement_logs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("user_supplement_id", .text)
                t.column("taken_at", .datetime).notNull()
                t.column("taken_date", .text).notNull()
                t.column("taken_timezone", .text)
                t.column("taken_utc_offset_minutes", .integer)
                t.column("supplement_name", .text).notNull()
                t.column("dose_amount", .double)
                t.column("dose_unit", .text).notNull().defaults(to: "mg")
                t.column("with_food", .boolean)
                t.column("notes", .text)
                t.column("was_scheduled", .boolean).notNull().defaults(to: false)
                t.column("scheduled_time", .text)
                t.column("felt_effect", .text)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_supplement_logs_date", on: "supplement_logs",
                          columns: ["user_id", "taken_date"],
                          condition: Column("deleted_at") == nil)

            // ────────────────────────────────────────────
            // HEALTH & WELLNESS
            // ────────────────────────────────────────────

            try db.create(table: "wellness_checks") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("checked_at", .datetime).notNull()
                t.column("date", .text).notNull()
                t.column("checked_timezone", .text)
                t.column("checked_utc_offset_minutes", .integer)
                t.column("perceived_sleep_quality", .integer)
                t.column("energy_level", .integer)
                t.column("muscle_soreness", .integer)
                t.column("stress_level", .integer)
                t.column("mood", .integer)
                t.column("pss4_q1", .integer)
                t.column("pss4_q2", .integer)
                t.column("pss4_q3", .integer)
                t.column("pss4_q4", .integer)
                t.column("feeling_ill", .boolean).notNull().defaults(to: false)
                t.column("headache", .boolean).notNull().defaults(to: false)
                t.column("digestive_issues", .boolean).notNull().defaults(to: false)
                t.column("notes", .text)
                t.column("wellness_score", .double)
                t.column("mental_health_resources_shown", .boolean).notNull().defaults(to: false)
                t.column("deleted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.uniqueKey(["user_id", "date"])
            }

            try db.create(table: "body_composition") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("measured_at", .datetime).notNull()
                t.column("measured_date", .text).notNull()
                t.column("measured_timezone", .text)
                t.column("measured_utc_offset_minutes", .integer)
                t.column("input_type", .text)
                t.column("weight_kg", .double).notNull()
                t.column("body_fat_percent", .double)
                t.column("muscle_mass_kg", .double)
                t.column("water_percent", .double)
                t.column("bone_mass_kg", .double)
                t.column("visceral_fat_level", .integer)
                t.column("metabolic_age", .integer)
                t.column("bmi", .double)
                t.column("bmr_kcal", .integer)
                t.column("skeletal_muscle_percent", .double)
                t.column("lean_body_mass_kg", .double)
                t.column("fat_mass_kg", .double)
                t.column("fitness_score", .integer)
                t.column("waist_hip_ratio", .double)
                t.column("source", .text)
                t.column("device_name", .text)
                t.column("report_date", .text)
                t.column("scan_image_url", .text)
                t.column("ai_extraction_raw", .blob)
                t.column("ai_confidence", .double)
                t.column("user_corrected", .boolean).notNull().defaults(to: false)
                t.column("previous_measurement_id", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
            try db.create(
                index: "idx_body_composition_user_measured_date",
                on: "body_composition",
                columns: ["user_id", "measured_date"]
            )

            try db.create(table: "hydration_logs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("logged_at", .datetime).notNull()
                t.column("logged_date", .text).notNull()
                t.column("logged_timezone", .text)
                t.column("logged_utc_offset_minutes", .integer)
                t.column("water_ml", .integer).notNull()
                t.column("source", .text).notNull()
                t.column("notes", .text)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_hydration_logs_date", on: "hydration_logs",
                          columns: ["user_id", "logged_date"],
                          condition: Column("deleted_at") == nil)

            // ────────────────────────────────────────────
            // LABS
            // ────────────────────────────────────────────

            try db.create(table: "medical_scans") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("scan_type", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("image_url", .text)
                t.column("image_uploaded_at", .datetime)
                t.column("ai_extraction_raw", .blob)
                t.column("ai_confidence", .double)
                t.column("user_reviewed", .boolean).notNull().defaults(to: false)
                t.column("user_reviewed_at", .datetime)
                t.column("notes", .text)
                t.column("deleted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "health_measurements") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("medical_scan_id", .text)
                t.column("biomarker_name", .text).notNull()
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.column("reference_range_low", .double)
                t.column("reference_range_high", .double)
                t.column("measured_at", .datetime)
                t.column("measured_date", .text)
                t.column("ai_confidence", .double)
                t.column("user_corrected", .boolean).notNull().defaults(to: false)
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // ────────────────────────────────────────────
            // AI & EXPERIMENTS
            // ────────────────────────────────────────────

            try db.create(table: "insights") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("category", .text).notNull()
                t.column("title", .text).notNull()
                t.column("body", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("inputs_used", .text)
                t.column("priority", .integer).notNull().defaults(to: 5)
                t.column("actionable", .boolean).notNull().defaults(to: false)
                t.column("action_type", .text)
                t.column("read", .boolean).notNull().defaults(to: false)
                t.column("read_at", .datetime)
                t.column("acknowledged", .boolean).notNull().defaults(to: false)
                t.column("acknowledged_at", .datetime)
                t.column("dismissed", .boolean).notNull().defaults(to: false)
                t.column("expires_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "experiments") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                    .references("users", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("hypothesis", .text)
                t.column("variable", .text).notNull()
                t.column("metric", .text).notNull()
                t.column("duration_days", .integer).notNull()
                t.column("status", .text).notNull().defaults(to: "planned")
                t.column("start_date", .text)
                t.column("end_date", .text)
                t.column("baseline_data", .blob)
                t.column("result_summary", .text)
                t.column("ai_analysis", .text)
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "experiment_measurements") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("experiment_id", .text).notNull()
                    .references("experiments", onDelete: .cascade)
                t.column("user_id", .text).notNull()
                t.column("date", .text).notNull()
                t.column("value", .double).notNull()
                t.column("unit", .text)
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
        }

        // MARK: - V2 Migration: sleep_logs + notification_log

        migrator.registerMigration("v2_sleep_and_notifications") { db in

            // Sleep logs (pulled from HealthKit or entered manually)
            try db.create(table: "sleep_logs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                t.column("date", .text).notNull()               // YYYY-MM-DD
                t.column("bed_time", .datetime)
                t.column("wake_time", .datetime)
                t.column("total_duration_minutes", .integer)
                t.column("time_in_bed_minutes", .integer)
                t.column("deep_sleep_minutes", .integer)
                t.column("rem_sleep_minutes", .integer)
                t.column("light_sleep_minutes", .integer)
                t.column("awake_minutes", .integer)
                t.column("sleep_efficiency", .double)
                t.column("sleep_quality_score", .double)
                t.column("number_of_awakenings", .integer)
                t.column("source", .text).notNull().defaults(to: "healthkit")
                t.column("device_name", .text)
                t.column("sleep_timezone", .text)
                t.column("sleep_utc_offset_minutes", .integer)
                t.column("deleted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // Notification log (for daily cap counter + dedup)
            try db.create(table: "notification_log") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("category", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("title", .text).notNull()
                t.column("delivered_at", .datetime).notNull()
            }

            // Index for efficient date-range queries on sleep
            try db.create(
                index: "idx_sleep_logs_user_date",
                on: "sleep_logs",
                columns: ["user_id", "date"]
            )

            // Index for notification daily counter
            try db.create(
                index: "idx_notification_log_delivered",
                on: "notification_log",
                columns: ["delivered_at"]
            )
        }

        // MARK: - V3 Migration: outbox idempotency_key (P0-2)

        migrator.registerMigration("v3_outbox_idempotency_key") { db in
            // Per sync engine spec §6.2: idempotency_key stored per outbox row,
            // distinct from id to allow key rotation after 409 conflicts.
            try db.alter(table: "outbox_events") { t in
                t.add(column: "idempotency_key", .text)
            }

            // Backfill: set idempotency_key = id for existing rows
            try db.execute(sql: """
                UPDATE outbox_events SET idempotency_key = id WHERE idempotency_key IS NULL
                """)
        }

        // MARK: - V4 Migration: server timestamp mirror per synced row

        migrator.registerMigration("v4_sync_row_state") { db in
            try db.create(table: "sync_row_state") { t in
                t.column("table_name", .text).notNull()
                t.column("row_id", .text).notNull()
                t.column("updated_at_server", .datetime).notNull()
                t.primaryKey(["table_name", "row_id"])
            }
            try db.create(
                index: "idx_sync_row_state_table",
                on: "sync_row_state",
                columns: ["table_name", "updated_at_server"]
            )
        }

        // MARK: - V5 Migration: API schema parity tables

        migrator.registerMigration("v5_api_schema_parity") { db in
            // AI recommendations (pull-only)
            try db.create(table: "recommendations") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().references("users", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("recommendation_date", .text).notNull()
                t.column("time_of_day", .text)
                t.column("category", .text).notNull()
                t.column("priority", .text).notNull()
                t.column("title", .text).notNull()
                t.column("description", .text).notNull()
                t.column("reasoning", .text).notNull()
                t.column("insight_id", .text)
                t.column("action_type", .text)
                t.column("action_parameters", .blob)
                t.column("auto_execute", .boolean).notNull().defaults(to: false)
                t.column("dismissed", .boolean).notNull().defaults(to: false)
                t.column("followed", .boolean)
                t.column("user_feedback", .text)
                t.column("recovery_score_at_time", .double)
                t.column("trigger_condition", .text)
            }
            try db.create(index: "idx_recommendations_user_date", on: "recommendations", columns: ["user_id", "recommendation_date"])
            try db.create(index: "idx_recommendations_active", on: "recommendations", columns: ["user_id"], condition: Column("dismissed") == false)

            // Weekly strategy reports (pull-only)
            try db.create(table: "weekly_strategy_reports") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().references("users", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("week_start", .text).notNull()
                t.column("week_end", .text).notNull()
                t.column("summary_stats", .blob).notNull()
                t.column("report_markdown", .text).notNull()
                t.column("model_used", .text)
                t.column("prompt_version", .text)
                t.uniqueKey(["user_id", "week_start"])
            }
            try db.create(index: "idx_weekly_strategy_user", on: "weekly_strategy_reports", columns: ["user_id", "week_start"])

            // Health marker reference catalog (pull-only)
            try db.create(table: "health_marker_catalog") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("category", .text).notNull()
                t.column("display_name", .text).notNull()
                t.column("display_name_ru", .text)
                t.column("aliases", .text).notNull().defaults(to: "[]")
                t.column("standard_unit", .text).notNull()
                t.column("alternative_units", .blob)
                t.column("optimal_range_male", .text)
                t.column("optimal_range_female", .text)
                t.column("critical_low", .double)
                t.column("critical_high", .double)
                t.column("affects_recovery", .boolean).notNull().defaults(to: false)
                t.column("recovery_weight", .double)
                t.column("description", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_health_marker_catalog_category", on: "health_marker_catalog", columns: ["category"])

            // Diagnoses (restricted, local-first)
            try db.create(table: "health_diagnoses") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().references("users", onDelete: .cascade)
                t.column("condition_id", .text)
                t.column("original_text", .text).notNull()
                t.column("severity", .text)
                t.column("diagnosed_at", .text)
                t.column("source_scan_id", .text)
                t.column("is_resolved", .boolean).notNull().defaults(to: false)
                t.column("resolved_at", .text)
                t.column("resolution_notes", .text)
                t.column("confidence", .double)
                t.column("notes", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "idx_health_diagnoses_user", on: "health_diagnoses", columns: ["user_id", "diagnosed_at"])
            try db.create(index: "idx_health_diagnoses_active", on: "health_diagnoses", columns: ["user_id"], condition: Column("is_resolved") == false)

            // Vector memory metadata (opt-in only)
            try db.create(table: "vector_memory") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().references("users", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("vector_id", .text).notNull().unique()
                t.column("vector_namespace", .text)
                t.column("source_type", .text).notNull()
                t.column("source_id", .text).notNull()
                t.column("event_date", .text).notNull()
                t.column("summary", .text)
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("searchable_text", .text)
            }
            try db.create(index: "idx_vector_memory_user", on: "vector_memory", columns: ["user_id", "event_date"])
            try db.create(index: "idx_vector_memory_source", on: "vector_memory", columns: ["source_type", "source_id"])
            try db.create(index: "idx_vector_memory_vector", on: "vector_memory", columns: ["vector_id"])

            // Analytics (push-only)
            try db.create(table: "analytics_events") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text)
                t.column("event_name", .text).notNull()
                t.column("properties", .blob).notNull().defaults(to: Data("{}".utf8))
                t.column("session_id", .text)
                t.column("app_version", .text)
                t.column("os_version", .text)
                t.column("device_model", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_analytics_events_name", on: "analytics_events", columns: ["event_name", "created_at"])
            try db.create(index: "idx_analytics_events_user", on: "analytics_events", columns: ["user_id", "created_at"])
            try db.create(index: "idx_analytics_events_retention", on: "analytics_events", columns: ["created_at"])

            // Training templates (V2)
            try db.create(table: "training_templates") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().references("users", onDelete: .cascade)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("name", .text).notNull()
                t.column("category", .text)
                t.column("estimated_duration_minutes", .integer)
                t.column("template_exercises", .blob).notNull()
                t.column("times_used", .integer).notNull().defaults(to: 0)
                t.column("last_used_at", .datetime)
                t.column("archived", .boolean).notNull().defaults(to: false)
                t.column("deleted_at", .datetime)
                t.column("deleted_reason", .text)
            }
            try db.create(
                index: "idx_training_templates_user",
                on: "training_templates",
                columns: ["user_id", "created_at"],
                condition: Column("deleted_at") == nil
            )
            try db.create(
                index: "idx_training_templates_active",
                on: "training_templates",
                columns: ["user_id"],
                condition: Column("archived") == false && Column("deleted_at") == nil
            )
        }

        // MARK: - V6 Migration: privacy retention support

        migrator.registerMigration("v6_privacy_retention_support") { db in
            try db.create(table: "ai_cache") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("cache_key", .text).notNull().unique()
                t.column("payload", .blob).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("expires_at", .datetime).notNull()
            }
            try db.create(index: "idx_ai_cache_expires", on: "ai_cache", columns: ["expires_at"])
        }

        // MARK: - V7 Migration: notification invariant guardrails

        migrator.registerMigration("v7_notification_guardrails") { db in
            try db.execute(sql: """
                UPDATE notification_settings
                SET max_total_per_day = CASE
                    WHEN max_total_per_day < 1 THEN 1
                    WHEN max_total_per_day > 6 THEN 6
                    ELSE max_total_per_day
                END
                """)

            try db.execute(sql: """
                UPDATE notification_settings
                SET control_level = 'advisory',
                    focus_control_enabled = 0
                WHERE critical_only = 1
                """)
        }

        // MARK: - V8 Migration: health_measurements parity columns

        migrator.registerMigration("v8_health_measurements_parity") { db in
            try db.alter(table: "health_measurements") { t in
                t.add(column: "marker_id", .text)
                t.add(column: "original_value", .double)
                t.add(column: "original_unit", .text)
                t.add(column: "status", .text)
                t.add(column: "source_scan_id", .text)
                t.add(column: "source_type", .text).notNull().defaults(to: "scan")
                t.add(column: "original_label", .text)
                t.add(column: "confidence", .double)
                t.add(column: "manually_verified", .boolean).notNull().defaults(to: false)
            }

            // Backfill best-effort values from legacy columns.
            try db.execute(sql: """
                UPDATE health_measurements
                SET marker_id = COALESCE(marker_id, LOWER(REPLACE(biomarker_name, ' ', '_'))),
                    source_scan_id = COALESCE(source_scan_id, medical_scan_id),
                    confidence = COALESCE(confidence, ai_confidence)
                """)
        }

        // MARK: - V9 Migration: low-confidence review flags

        migrator.registerMigration("v9_low_confidence_review_flags") { db in
            try db.alter(table: "insights") { t in
                t.add(column: "needs_review", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "food_logs") { t in
                t.add(column: "needs_review", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "medical_scans") { t in
                t.add(column: "needs_review", .boolean).notNull().defaults(to: false)
            }

            try db.execute(sql: """
                UPDATE insights
                SET needs_review = CASE WHEN confidence < 0.65 THEN 1 ELSE 0 END
                """)
            try db.execute(sql: """
                UPDATE food_logs
                SET needs_review = CASE WHEN ai_confidence IS NOT NULL AND ai_confidence < 0.65 THEN 1 ELSE 0 END
                """)
            try db.execute(sql: """
                UPDATE medical_scans
                SET needs_review = CASE WHEN ai_confidence IS NOT NULL AND ai_confidence < 0.65 THEN 1 ELSE 0 END
                """)
        }

        // MARK: - V10 Migration: experiments soft-delete parity

        migrator.registerMigration("v10_experiments_soft_delete") { db in
            try db.alter(table: "experiments") { t in
                t.add(column: "deleted_at", .datetime)
                t.add(column: "deleted_reason", .text)
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_experiments_user
                ON experiments(user_id, created_at DESC)
                WHERE deleted_at IS NULL
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_experiments_status
                ON experiments(status)
                WHERE deleted_at IS NULL
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_experiments_active
                ON experiments(user_id, status)
                WHERE deleted_at IS NULL
                  AND status IN ('baseline', 'intervention', 'washout')
                """)
        }

        // MARK: - V11 Migration: confidence review-gate triggers

        migrator.registerMigration("v11_confidence_review_gate_triggers") { db in
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_insights_needs_review_insert
                AFTER INSERT ON insights
                FOR EACH ROW
                BEGIN
                    UPDATE insights
                    SET needs_review = CASE WHEN NEW.confidence < 0.65 THEN 1 ELSE 0 END
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_insights_needs_review_update
                AFTER UPDATE OF confidence ON insights
                FOR EACH ROW
                BEGIN
                    UPDATE insights
                    SET needs_review = CASE WHEN NEW.confidence < 0.65 THEN 1 ELSE 0 END
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_food_logs_needs_review_insert
                AFTER INSERT ON food_logs
                FOR EACH ROW
                BEGIN
                    UPDATE food_logs
                    SET needs_review = CASE
                        WHEN NEW.ai_confidence IS NOT NULL AND NEW.ai_confidence < 0.65 THEN 1
                        ELSE 0
                    END
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_food_logs_needs_review_update
                AFTER UPDATE OF ai_confidence ON food_logs
                FOR EACH ROW
                BEGIN
                    UPDATE food_logs
                    SET needs_review = CASE
                        WHEN NEW.ai_confidence IS NOT NULL AND NEW.ai_confidence < 0.65 THEN 1
                        ELSE 0
                    END
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_medical_scans_needs_review_insert
                AFTER INSERT ON medical_scans
                FOR EACH ROW
                BEGIN
                    UPDATE medical_scans
                    SET needs_review = CASE
                        WHEN NEW.ai_confidence IS NOT NULL AND NEW.ai_confidence < 0.65 THEN 1
                        ELSE 0
                    END
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_medical_scans_needs_review_update
                AFTER UPDATE OF ai_confidence ON medical_scans
                FOR EACH ROW
                BEGIN
                    UPDATE medical_scans
                    SET needs_review = CASE
                        WHEN NEW.ai_confidence IS NOT NULL AND NEW.ai_confidence < 0.65 THEN 1
                        ELSE 0
                    END
                    WHERE id = NEW.id;
                END
                """)
        }

        // MARK: - V12 Migration: experiment schema parity

        migrator.registerMigration("v12_experiment_schema_parity") { db in
            try db.alter(table: "experiments") { t in
                t.add(column: "control_description", .text)
                t.add(column: "intervention_description", .text)
                t.add(column: "baseline_start_date", .text)
                t.add(column: "baseline_end_date", .text)
                t.add(column: "baseline_duration_days", .integer)
                t.add(column: "intervention_start_date", .text)
                t.add(column: "intervention_end_date", .text)
                t.add(column: "intervention_duration_days", .integer)
                t.add(column: "washout_start_date", .text)
                t.add(column: "washout_end_date", .text)
                t.add(column: "washout_duration_days", .integer)
                t.add(column: "primary_metric", .text)
                t.add(column: "secondary_metrics", .text)
                t.add(column: "measurement_frequency", .text)
                t.add(column: "reminder_time", .text)
                t.add(column: "baseline_mean", .double)
                t.add(column: "baseline_std_dev", .double)
                t.add(column: "intervention_mean", .double)
                t.add(column: "intervention_std_dev", .double)
                t.add(column: "effect_size", .double)
                t.add(column: "p_value", .double)
                t.add(column: "confidence_interval_lower", .double)
                t.add(column: "confidence_interval_upper", .double)
                t.add(column: "significant", .boolean)
                t.add(column: "effect_direction", .text)
                t.add(column: "ai_interpretation", .text)
                t.add(column: "ai_recommendation", .text)
                t.add(column: "user_notes", .text)
                t.add(column: "compliance_percent", .double)
            }

            try db.execute(sql: """
                UPDATE experiments
                SET primary_metric = COALESCE(primary_metric, metric),
                    ai_interpretation = COALESCE(ai_interpretation, ai_analysis),
                    user_notes = COALESCE(user_notes, notes),
                    baseline_duration_days = COALESCE(baseline_duration_days, duration_days)
                """)

            try db.alter(table: "experiment_measurements") { t in
                t.add(column: "measurement_date", .text)
                t.add(column: "measurement_phase", .text).notNull().defaults(to: "baseline")
                t.add(column: "metric_name", .text)
                t.add(column: "metric_value", .double)
                t.add(column: "metric_unit", .text)
                t.add(column: "protocol_followed", .boolean).notNull().defaults(to: true)
            }

            try db.execute(sql: """
                UPDATE experiment_measurements
                SET measurement_date = COALESCE(measurement_date, date),
                    metric_name = COALESCE(metric_name, 'primary_metric'),
                    metric_value = COALESCE(metric_value, value),
                    metric_unit = COALESCE(metric_unit, unit)
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_experiment_measurements
                ON experiment_measurements(experiment_id, measurement_phase, measurement_date)
                """)
        }

        // MARK: - V13 Migration: close API parity gaps + GDPR audit support

        migrator.registerMigration("v13_schema_gap_closure") { db in
            try db.create(table: "deletion_audit_log") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id_deleted", .text).notNull()
                t.column("deleted_at", .datetime).notNull()
                t.column("postgres_deleted", .boolean).notNull().defaults(to: false)
                t.column("vectors_deleted", .boolean).notNull().defaults(to: false)
                t.column("storage_deleted", .boolean).notNull().defaults(to: false)
                t.column("compliance_verified", .boolean).notNull().defaults(to: false)
                t.column("notes", .text)
            }
            try db.create(index: "idx_deletion_audit_user", on: "deletion_audit_log", columns: ["user_id_deleted", "deleted_at"])

            try db.create(table: "deletion_failures") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull()
                t.column("failure_type", .text).notNull()
                t.column("error", .text).notNull()
                t.column("resolved", .boolean).notNull().defaults(to: false)
                t.column("retried_at", .datetime)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_deletion_failures_user", on: "deletion_failures", columns: ["user_id", "created_at"])

            try db.alter(table: "food_logs") { t in
                t.add(column: "location_lat", .double)
                t.add(column: "location_lng", .double)
            }

            try db.alter(table: "batch_recipes") { t in
                t.add(column: "calories_per_100g", .double)
                t.add(column: "protein_per_100g", .double)
                t.add(column: "fat_per_100g", .double)
                t.add(column: "carbs_per_100g", .double)
                t.add(column: "weight_per_portion_g", .double)
            }
            try db.execute(sql: """
                UPDATE batch_recipes
                SET calories_per_100g = CASE WHEN total_weight_g > 0 THEN total_calories * 100.0 / total_weight_g END,
                    protein_per_100g = CASE WHEN total_weight_g > 0 THEN total_protein_g * 100.0 / total_weight_g END,
                    fat_per_100g = CASE WHEN total_weight_g > 0 THEN total_fat_g * 100.0 / total_weight_g END,
                    carbs_per_100g = CASE WHEN total_weight_g > 0 THEN total_carbs_g * 100.0 / total_weight_g END,
                    weight_per_portion_g = CASE WHEN total_portions IS NOT NULL AND total_portions > 0 THEN total_weight_g * 1.0 / total_portions END
                """)

            try db.alter(table: "body_composition") { t in
                t.add(column: "protein_kg", .double)
                t.add(column: "minerals_kg", .double)
                t.add(column: "target_weight_kg", .double)
                t.add(column: "weight_control_kg", .double)
                t.add(column: "fat_control_kg", .double)
                t.add(column: "muscle_control_kg", .double)
                t.add(column: "segmental_lean", .blob)
                t.add(column: "segmental_fat", .blob)
                t.add(column: "impedance_data", .blob)
            }

            try db.alter(table: "insights") { t in
                t.add(column: "type", .text)
                t.add(column: "description", .text)
                t.add(column: "reasoning", .text)
                t.add(column: "data_points", .integer)
                t.add(column: "correlation_method", .text)
                t.add(column: "correlation_coefficient", .double)
                t.add(column: "p_value", .double)
                t.add(column: "lag_days", .integer)
                t.add(column: "confounders", .text)
                t.add(column: "related_metrics", .blob)
                t.add(column: "related_dates", .blob)
                t.add(column: "suggested_experiment_id", .text)
                t.add(column: "shown_to_user", .boolean).notNull().defaults(to: false)
                t.add(column: "shown_at", .datetime)
                t.add(column: "dismissed_at", .datetime)
                t.add(column: "acted_upon", .boolean).notNull().defaults(to: false)
                t.add(column: "action_taken", .text)
                t.add(column: "confidence_score", .double)
            }
            try db.execute(sql: """
                UPDATE insights
                SET description = COALESCE(description, body),
                    confidence_score = COALESCE(confidence_score, confidence),
                    dismissed_at = CASE WHEN dismissed = 1 THEN COALESCE(dismissed_at, updated_at) ELSE dismissed_at END
                """)

            try db.alter(table: "medical_scans") { t in
                t.add(column: "ocr_confidence", .double)
                t.add(column: "extraction_status", .text)
                t.add(column: "extraction_error", .text)
                t.add(column: "markers_extracted", .integer)
                t.add(column: "diagnoses_extracted", .integer)
                t.add(column: "processed_data", .blob)
                t.add(column: "manually_verified", .boolean).notNull().defaults(to: false)
                t.add(column: "pinned_by_user", .boolean).notNull().defaults(to: false)
                t.add(column: "scan_date", .text)
                t.add(column: "lab_name", .text)
                t.add(column: "document_language", .text)
                t.add(column: "source_file_sha256", .text)
                t.add(column: "original_image_url", .text)
                t.add(column: "storage_mode", .text)
                t.add(column: "store_original_in_cloud", .boolean)
                t.add(column: "scheduled_deletion_at", .datetime)
            }
            try db.execute(sql: """
                UPDATE medical_scans
                SET ocr_confidence = COALESCE(ocr_confidence, ai_confidence),
                    extraction_status = COALESCE(extraction_status, status),
                    original_image_url = COALESCE(original_image_url, image_url)
                """)

            try db.alter(table: "sleep_logs") { t in
                t.add(column: "sleep_date", .text)
                t.add(column: "bedtime_intended", .datetime)
                t.add(column: "bedtime_actual", .datetime)
                t.add(column: "waketime", .datetime)
                t.add(column: "time_to_fall_asleep_minutes", .integer)
                t.add(column: "perceived_quality", .integer)
                t.add(column: "morning_energy", .integer)
                t.add(column: "interruptions", .integer)
                t.add(column: "notes", .text)
                t.add(column: "alcohol", .double)
                t.add(column: "caffeine_after_14", .boolean)
                t.add(column: "heavy_meal_late", .boolean)
                t.add(column: "exercise_evening", .boolean)
                t.add(column: "stressful_day", .boolean)
                t.add(column: "screen_before_bed", .boolean)
                t.add(column: "room_darkness", .integer)
                t.add(column: "room_temperature", .double)
                t.add(column: "noise_level", .integer)
                t.add(column: "dream_recall", .boolean)
            }
            try db.execute(sql: """
                UPDATE sleep_logs
                SET sleep_date = COALESCE(sleep_date, date),
                    bedtime_actual = COALESCE(bedtime_actual, bed_time),
                    waketime = COALESCE(waketime, wake_time)
                """)

            try db.alter(table: "training_loads") { t in
                t.add(column: "ewma_lambda_acute", .double)
                t.add(column: "ewma_lambda_chronic", .double)
            }
            try db.execute(sql: """
                UPDATE training_loads
                SET ewma_lambda_acute = COALESCE(ewma_lambda_acute, 0.25),
                    ewma_lambda_chronic = COALESCE(ewma_lambda_chronic, 0.08)
                """)

            try db.alter(table: "training_plan_sessions") { t in
                t.add(column: "planned_exercises", .blob)
                t.add(column: "actual_session_id", .text)
            }
            try db.execute(sql: """
                UPDATE training_plan_sessions
                SET planned_exercises = COALESCE(planned_exercises, session_json),
                    actual_session_id = COALESCE(actual_session_id, linked_workout_id)
                """)

            try db.alter(table: "user_health_flags") { t in
                t.add(column: "disable_hrv", .boolean).notNull().defaults(to: false)
                t.add(column: "hide_calories", .boolean).notNull().defaults(to: false)
                t.add(column: "pregnancy_mode", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                UPDATE user_health_flags
                SET disable_hrv = CASE WHEN has_cardiac_condition = 1 OR has_pacemaker = 1 THEN 1 ELSE 0 END,
                    hide_calories = CASE WHEN has_eating_disorder_history = 1 THEN 1 ELSE 0 END,
                    pregnancy_mode = CASE WHEN is_pregnant = 1 THEN 1 ELSE 0 END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_user_health_flags_derived_insert
                AFTER INSERT ON user_health_flags
                FOR EACH ROW
                BEGIN
                    UPDATE user_health_flags
                    SET disable_hrv = CASE WHEN NEW.has_cardiac_condition = 1 OR NEW.has_pacemaker = 1 THEN 1 ELSE 0 END,
                        hide_calories = CASE WHEN NEW.has_eating_disorder_history = 1 THEN 1 ELSE 0 END,
                        pregnancy_mode = CASE WHEN NEW.is_pregnant = 1 THEN 1 ELSE 0 END
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_user_health_flags_derived_update
                AFTER UPDATE OF has_cardiac_condition, has_pacemaker, has_eating_disorder_history, is_pregnant ON user_health_flags
                FOR EACH ROW
                BEGIN
                    UPDATE user_health_flags
                    SET disable_hrv = CASE WHEN NEW.has_cardiac_condition = 1 OR NEW.has_pacemaker = 1 THEN 1 ELSE 0 END,
                        hide_calories = CASE WHEN NEW.has_eating_disorder_history = 1 THEN 1 ELSE 0 END,
                        pregnancy_mode = CASE WHEN NEW.is_pregnant = 1 THEN 1 ELSE 0 END
                    WHERE id = NEW.id;
                END
                """)

            try db.alter(table: "wellness_checks") { t in
                t.add(column: "pss4_total", .integer)
            }
            try db.execute(sql: """
                UPDATE wellness_checks
                SET pss4_total = CASE
                    WHEN pss4_q1 IS NOT NULL AND pss4_q2 IS NOT NULL AND pss4_q3 IS NOT NULL AND pss4_q4 IS NOT NULL
                    THEN pss4_q1 + (4 - pss4_q2) + (4 - pss4_q3) + pss4_q4
                    ELSE NULL
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_wellness_checks_pss4_insert
                AFTER INSERT ON wellness_checks
                FOR EACH ROW
                BEGIN
                    UPDATE wellness_checks
                    SET pss4_total = CASE
                        WHEN NEW.pss4_q1 IS NOT NULL AND NEW.pss4_q2 IS NOT NULL AND NEW.pss4_q3 IS NOT NULL AND NEW.pss4_q4 IS NOT NULL
                        THEN NEW.pss4_q1 + (4 - NEW.pss4_q2) + (4 - NEW.pss4_q3) + NEW.pss4_q4
                        ELSE NULL
                    END
                    WHERE id = NEW.id;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_wellness_checks_pss4_update
                AFTER UPDATE OF pss4_q1, pss4_q2, pss4_q3, pss4_q4 ON wellness_checks
                FOR EACH ROW
                BEGIN
                    UPDATE wellness_checks
                    SET pss4_total = CASE
                        WHEN NEW.pss4_q1 IS NOT NULL AND NEW.pss4_q2 IS NOT NULL AND NEW.pss4_q3 IS NOT NULL AND NEW.pss4_q4 IS NOT NULL
                        THEN NEW.pss4_q1 + (4 - NEW.pss4_q2) + (4 - NEW.pss4_q3) + NEW.pss4_q4
                        ELSE NULL
                    END
                    WHERE id = NEW.id;
                END
                """)
        }

        // MARK: - V14 Migration: consent versioning persistence

        migrator.registerMigration("v14_consent_records") { db in
            try db.create(table: "consent_records") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().references("users", onDelete: .cascade)
                t.column("consent_type", .text).notNull()
                t.column("granted", .boolean).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("version", .text).notNull()
                t.column("ip_address", .text)
                t.column("created_at", .datetime).notNull()
            }

            try db.create(index: "idx_consent_records_user_type", on: "consent_records", columns: ["user_id", "consent_type", "timestamp"])
        }

        // MARK: - V15 Migration: notification control-level invariant triggers

        migrator.registerMigration("v15_notification_control_invariants") { db in
            try db.execute(sql: """
                UPDATE notification_settings
                SET control_level = 'advisory',
                    focus_control_enabled = 0
                WHERE critical_only = 1
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_notification_settings_critical_only_insert
                AFTER INSERT ON notification_settings
                FOR EACH ROW
                WHEN NEW.critical_only = 1
                BEGIN
                    UPDATE notification_settings
                    SET control_level = 'advisory',
                        focus_control_enabled = 0
                    WHERE id = NEW.id;
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS trg_notification_settings_critical_only_update
                AFTER UPDATE OF critical_only, control_level, focus_control_enabled ON notification_settings
                FOR EACH ROW
                WHEN NEW.critical_only = 1
                BEGIN
                    UPDATE notification_settings
                    SET control_level = 'advisory',
                        focus_control_enabled = 0
                    WHERE id = NEW.id;
                END
                """)
        }

        // MARK: - V16 Migration: privacy cloud-backup opt-in flag

        migrator.registerMigration("v16_privacy_cloud_backup_flag") { db in
            try db.alter(table: "privacy_settings") { t in
                t.add(column: "cloud_backup_enabled", .boolean).notNull().defaults(to: false)
            }
        }

        // MARK: - V17 Migration: ops-table parity with backend schema

        migrator.registerMigration("v17_ops_table_parity") { db in
            // notification_log parity (server keeps additional metadata for cap + dedup by local day)
            try addColumnIfMissing(db: db, table: "notification_log", sql: "ALTER TABLE notification_log ADD COLUMN user_id TEXT NOT NULL DEFAULT ''")
            try addColumnIfMissing(db: db, table: "notification_log", sql: "ALTER TABLE notification_log ADD COLUMN body TEXT NOT NULL DEFAULT ''")
            try addColumnIfMissing(db: db, table: "notification_log", sql: "ALTER TABLE notification_log ADD COLUMN deep_link TEXT")
            try addColumnIfMissing(db: db, table: "notification_log", sql: "ALTER TABLE notification_log ADD COLUMN delivered_date_local TEXT NOT NULL DEFAULT '1970-01-01'")
            try addColumnIfMissing(db: db, table: "notification_log", sql: "ALTER TABLE notification_log ADD COLUMN timezone TEXT NOT NULL DEFAULT 'UTC'")
            try addColumnIfMissing(db: db, table: "notification_log", sql: "ALTER TABLE notification_log ADD COLUMN created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_notification_log_user_day ON notification_log(user_id, delivered_date_local)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_notification_log_user_category ON notification_log(user_id, category, delivered_at DESC)")

            // export_jobs parity
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS export_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    user_id TEXT NOT NULL,
                    status TEXT NOT NULL,
                    download_url TEXT,
                    requested_at DATETIME NOT NULL,
                    completed_at DATETIME,
                    failure_reason TEXT,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_export_jobs_user_requested ON export_jobs(user_id, requested_at DESC)")

            // deletion_audit_log parity (spec shape)
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN user_id_deleted TEXT")
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN deleted_at DATETIME")
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN vectors_deleted BOOLEAN NOT NULL DEFAULT 0")
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN postgres_deleted BOOLEAN NOT NULL DEFAULT 0")
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN storage_deleted BOOLEAN NOT NULL DEFAULT 0")
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN compliance_verified BOOLEAN NOT NULL DEFAULT 0")
            try addColumnIfMissing(db: db, table: "deletion_audit_log", sql: "ALTER TABLE deletion_audit_log ADD COLUMN notes TEXT")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_deletion_audit_user_new ON deletion_audit_log(user_id_deleted, deleted_at)")

            // deletion_failures parity (spec shape)
            try addColumnIfMissing(db: db, table: "deletion_failures", sql: "ALTER TABLE deletion_failures ADD COLUMN failure_type TEXT")
            try addColumnIfMissing(db: db, table: "deletion_failures", sql: "ALTER TABLE deletion_failures ADD COLUMN error TEXT")
            try addColumnIfMissing(db: db, table: "deletion_failures", sql: "ALTER TABLE deletion_failures ADD COLUMN resolved BOOLEAN NOT NULL DEFAULT 0")
            try addColumnIfMissing(db: db, table: "deletion_failures", sql: "ALTER TABLE deletion_failures ADD COLUMN retried_at DATETIME")
        }

        // MARK: - V18 Migration: notification max_total_per_day clamp parity [1...6]

        migrator.registerMigration("v18_notification_total_cap_floor") { db in
            try db.execute(sql: """
                UPDATE notification_settings
                SET max_total_per_day = CASE
                    WHEN max_total_per_day < 1 THEN 1
                    WHEN max_total_per_day > 6 THEN 6
                    ELSE max_total_per_day
                END
                """)
        }

        // MARK: - V19 Migration: menstrual local-only table in unified migrator

        migrator.registerMigration("v19_menstrual_local_only_table") { db in
            try db.create(table: "menstrual_logs", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("user_id", .text).notNull().indexed()
                t.column("date", .text).notNull().indexed()
                t.column("flow", .text)
                t.column("pain_level", .integer)
                t.column("deleted_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try addColumnIfMissing(db: db, table: "menstrual_logs", sql: "ALTER TABLE menstrual_logs ADD COLUMN deleted_at DATETIME")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_menstrual_logs_user_date ON menstrual_logs(user_id, date)")
        }

        // MARK: - V20 Migration: menstrual deleted_at compatibility for existing installs

        migrator.registerMigration("v20_menstrual_deleted_at_backfill") { db in
            try addColumnIfMissing(db: db, table: "menstrual_logs", sql: "ALTER TABLE menstrual_logs ADD COLUMN deleted_at DATETIME")
        }

        // MARK: - V21 Migration: menstrual_logs.user_id FK cascade parity

        migrator.registerMigration("v21_menstrual_user_fk_cascade") { db in
            try applyV21MenstrualUserFkCascadeMigration(db: db)
        }

        // MARK: - V22 Migration: medical_scans.scan_type canonicalization parity

        migrator.registerMigration("v22_medical_scan_type_canonicalization") { db in
            try applyV22MedicalScanTypeCanonicalizationMigration(db: db)
        }

        // MARK: - V23 Migration: health_measurements canonical contract hardening

        migrator.registerMigration("v23_health_measurements_contract_hardening") { db in
            try applyV23HealthMeasurementsContractHardeningMigration(db: db)
        }

        // v24: Local feature flags cache + screen time events
        migrator.registerMigration("v24_feature_flags_and_screen_time") { db in
            // Feature flags cache (synced from server on launch)
            try db.create(table: "feature_flags_cache", ifNotExists: true) { t in
                t.column("flag_key", .text).primaryKey()
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("variant", .text)       // A/B test variant, if applicable
                t.column("fetched_at", .datetime).notNull()
            }

            // Guardian screen time events (drained from shared UserDefaults)
            try db.create(table: "screen_time_events", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("user_id", .text).notNull()
                t.column("event_type", .text).notNull()
                t.column("event_detail", .text)
                t.column("recorded_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }
            try db.create(
                index: "idx_screen_time_events_user",
                on: "screen_time_events",
                columns: ["user_id", "recorded_at"],
                ifNotExists: true
            )
        }

        // MARK: - V25 Migration: local at-rest encryption for sensitive fields

        migrator.registerMigration("v25_local_sensitive_field_encryption") { db in
            try applyV25LocalSensitiveFieldEncryptionMigration(db: db)
        }

        // MARK: - V26 Migration: canonical training plan session statuses

        migrator.registerMigration("v26_training_plan_session_status_canonicalization") { db in
            try applyV26TrainingPlanSessionStatusCanonicalizationMigration(db: db)
        }

        // MARK: - V27 Migration: historical timezone-aware local days

        migrator.registerMigration("v27_historical_timezone_local_days") { db in
            try applyV27HistoricalTimeZoneLocalDaysMigration(db: db)
        }

        // MARK: - V28 Migration: wellness/body composition local-day metadata

        migrator.registerMigration("v28_wellness_body_composition_local_days") { db in
            try applyV28WellnessAndBodyCompositionLocalDayMigration(db: db)
        }

        // MARK: - V29 Migration: timezone_history GRDB column parity

        migrator.registerMigration("v29_timezone_history_column_parity") { db in
            try applyV29TimezoneHistoryColumnParityMigration(db: db)
        }

        // MARK: - V30 Migration: experiments sync quarantine marker

        migrator.registerMigration("v30_experiments_sync_quarantine") { db in
            let hasColumn = try Bool.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) > 0 FROM pragma_table_info('experiments')
                    WHERE name = 'sync_quarantine_reason'
                    """
            ) ?? false
            guard !hasColumn else { return }

            try db.alter(table: "experiments") { t in
                t.add(column: "sync_quarantine_reason", .text)
            }
        }

        // MARK: - V31 Migration: menstrual_logs local field encryption

        migrator.registerMigration("v31_menstrual_local_field_encryption") { db in
            try applyV31MenstrualLocalFieldEncryptionMigration(db: db)
        }
    }

    private static func applyV21MenstrualUserFkCascadeMigration(db: Database) throws {
        let fkRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(menstrual_logs)")
        let hasCascadeUserFk = fkRows.contains { row in
            let table = lowercasedString(from: row["table"])
            let from = lowercasedString(from: row["from"])
            let to = lowercasedString(from: row["to"])
            let onDelete = uppercasedString(from: row["on_delete"])
            return table == "users" && from == "user_id" && to == "id" && onDelete == "CASCADE"
        }
        guard !hasCascadeUserFk else { return }

        try db.execute(sql: """
            CREATE TABLE menstrual_logs_new (
                id TEXT PRIMARY KEY NOT NULL,
                user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                date TEXT NOT NULL,
                flow TEXT,
                pain_level INTEGER,
                deleted_at DATETIME,
                created_at DATETIME NOT NULL,
                updated_at DATETIME NOT NULL
            )
            """)

        try db.execute(sql: """
            INSERT INTO menstrual_logs_new (
                id, user_id, date, flow, pain_level, deleted_at, created_at, updated_at
            )
            SELECT
                m.id, m.user_id, m.date, m.flow, m.pain_level, m.deleted_at, m.created_at, m.updated_at
            FROM menstrual_logs m
            WHERE EXISTS (
                SELECT 1 FROM users u WHERE u.id = m.user_id
            )
            """)

        try db.execute(sql: "DROP TABLE menstrual_logs")
        try db.execute(sql: "ALTER TABLE menstrual_logs_new RENAME TO menstrual_logs")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_menstrual_logs_user_date ON menstrual_logs(user_id, date)")
    }

    private static func applyV22MedicalScanTypeCanonicalizationMigration(db: Database) throws {
        try db.execute(sql: """
            UPDATE medical_scans
            SET scan_type = CASE lower(trim(scan_type))
                WHEN 'bloodwork' THEN 'blood_test'
                WHEN 'blood_test' THEN 'blood_test'
                WHEN 'inbody' THEN 'inbody'
                WHEN 'dexa' THEN 'dexa'
                WHEN 'urine' THEN 'other'
                WHEN 'body_composition' THEN 'other'
                WHEN 'other' THEN 'other'
                ELSE 'other'
            END
            """)

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, body_json
                FROM outbox_events
                WHERE path = ?
                """,
            arguments: ["rest/v1/medical_scans"]
        )

        for row in rows {
            guard let eventId = row["id"] as String?,
                  let bodyJson = row["body_json"] as Data?,
                  let normalizedBody = normalizeMedicalScanOutboxBody(bodyJson),
                  normalizedBody != bodyJson else {
                continue
            }

            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET body_json = ?, updated_at_local = ?
                    WHERE id = ?
                    """,
                arguments: [normalizedBody, Date(), eventId]
            )
        }
    }

    private static func normalizeMedicalScanOutboxBody(_ data: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let rawScanType = (object["scan_type"] as? String) ?? (object["scanType"] as? String)
        guard let normalizedScanType = ScanType.canonicalRawValue(for: rawScanType) else {
            return nil
        }

        if object["scan_type"] != nil {
            object["scan_type"] = normalizedScanType
        }
        if object["scanType"] != nil {
            object["scanType"] = normalizedScanType
        }
        if object["scan_type"] == nil && object["scanType"] == nil {
            object["scan_type"] = normalizedScanType
        }

        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func applyV23HealthMeasurementsContractHardeningMigration(db: Database) throws {
        try db.execute(sql: """
            UPDATE health_measurements
            SET marker_id = COALESCE(
                    NULLIF(marker_id, ''),
                    LOWER(REPLACE(COALESCE(NULLIF(original_label, ''), biomarker_name), ' ', '_'))
                ),
                source_scan_id = COALESCE(source_scan_id, medical_scan_id),
                confidence = COALESCE(confidence, ai_confidence),
                source_type = COALESCE(NULLIF(source_type, ''), 'scan'),
                original_value = COALESCE(original_value, value),
                original_unit = COALESCE(NULLIF(original_unit, ''), unit),
                original_label = COALESCE(NULLIF(original_label, ''), biomarker_name),
                measured_date = COALESCE(
                    measured_date,
                    CASE
                        WHEN measured_at IS NOT NULL THEN strftime('%Y-%m-%d', measured_at)
                        ELSE NULL
                    END
                )
            """)

        try db.execute(sql: """
            UPDATE health_measurements
            SET status = CASE
                WHEN status IS NULL OR trim(status) = '' THEN CASE
                    WHEN reference_range_low IS NOT NULL AND value < reference_range_low THEN 'low'
                    WHEN reference_range_high IS NOT NULL AND value > reference_range_high THEN 'high'
                    WHEN reference_range_low IS NOT NULL OR reference_range_high IS NOT NULL THEN 'optimal'
                    ELSE NULL
                END
                WHEN lower(trim(status)) IN ('critical_low', 'low', 'optimal', 'high', 'critical_high') THEN lower(trim(status))
                WHEN lower(trim(status)) IN ('normal', 'within_range', 'within range', 'in_range') THEN 'optimal'
                WHEN lower(trim(status)) IN ('out_of_range', 'out of range', 'abnormal') THEN CASE
                    WHEN reference_range_low IS NOT NULL AND value < reference_range_low THEN 'low'
                    WHEN reference_range_high IS NOT NULL AND value > reference_range_high THEN 'high'
                    ELSE NULL
                END
                ELSE CASE
                    WHEN reference_range_low IS NOT NULL AND value < reference_range_low THEN 'low'
                    WHEN reference_range_high IS NOT NULL AND value > reference_range_high THEN 'high'
                    WHEN reference_range_low IS NOT NULL OR reference_range_high IS NOT NULL THEN 'optimal'
                    ELSE NULL
                END
            END
            """)

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, body_json
                FROM outbox_events
                WHERE path = ?
                """,
            arguments: ["rest/v1/health_measurements"]
        )

        for row in rows {
            guard let eventId = row["id"] as String?,
                  let bodyJson = row["body_json"] as Data?,
                  let normalizedBody = normalizeHealthMeasurementOutboxBody(bodyJson),
                  normalizedBody != bodyJson else {
                continue
            }

            try db.execute(
                sql: """
                    UPDATE outbox_events
                    SET body_json = ?, updated_at_local = ?
                    WHERE id = ?
                    """,
                arguments: [normalizedBody, Date(), eventId]
            )
        }
    }

    private static func applyV25LocalSensitiveFieldEncryptionMigration(db: Database) throws {
        // After this migration these columns become ciphertext-at-rest in SQLite.
        // Future raw SQL must not assume plaintext numerics/URLs for these fields.
        try encryptFoodLogSensitiveFields(db: db)
        try encryptMedicalScanSensitiveFields(db: db)
        try encryptHealthMeasurementSensitiveFields(db: db)
    }

    private static func applyV26TrainingPlanSessionStatusCanonicalizationMigration(db: Database) throws {
        try db.execute(sql: """
            UPDATE training_plan_sessions
            SET status = CASE LOWER(COALESCE(status, ''))
                WHEN 'scheduled' THEN 'planned'
                WHEN 'modified' THEN 'rescheduled'
                ELSE status
            END
            WHERE LOWER(COALESCE(status, '')) IN ('scheduled', 'modified')
            """)
    }

    private static func applyV27HistoricalTimeZoneLocalDaysMigration(db: Database) throws {
        try addColumnIfMissing(
            db: db,
            table: "physiological_states",
            sql: "ALTER TABLE physiological_states ADD COLUMN local_timezone TEXT"
        )
        try addColumnIfMissing(
            db: db,
            table: "physiological_states",
            sql: "ALTER TABLE physiological_states ADD COLUMN local_utc_offset_minutes INTEGER"
        )

        try db.create(table: "timezone_history", ifNotExists: true) { t in
            t.column("id", .text).notNull().primaryKey()
            t.column("user_id", .text).notNull()
                .references("users", onDelete: .cascade)
            t.column("recorded_at", .datetime).notNull()
            t.column("time_zone_identifier", .text).notNull()
            t.column("utc_offset_minutes", .integer).notNull()
            t.column("source", .text).notNull().defaults(to: TimeZoneHistorySource.healthSync.rawValue)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_timezone_history_user_recorded_at",
            on: "timezone_history",
            columns: ["user_id", "recorded_at"],
            ifNotExists: true
        )
    }

    private static func applyV28WellnessAndBodyCompositionLocalDayMigration(db: Database) throws {
        try addColumnIfMissing(
            db: db,
            table: "wellness_checks",
            sql: "ALTER TABLE wellness_checks ADD COLUMN checked_timezone TEXT"
        )
        try addColumnIfMissing(
            db: db,
            table: "wellness_checks",
            sql: "ALTER TABLE wellness_checks ADD COLUMN checked_utc_offset_minutes INTEGER"
        )
        try addColumnIfMissing(
            db: db,
            table: "body_composition",
            sql: "ALTER TABLE body_composition ADD COLUMN measured_date TEXT"
        )
        try addColumnIfMissing(
            db: db,
            table: "body_composition",
            sql: "ALTER TABLE body_composition ADD COLUMN measured_timezone TEXT"
        )
        try addColumnIfMissing(
            db: db,
            table: "body_composition",
            sql: "ALTER TABLE body_composition ADD COLUMN measured_utc_offset_minutes INTEGER"
        )

        try backfillWellnessLocalDayMetadata(db: db)
        try backfillBodyCompositionLocalDayMetadata(db: db)

        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_body_composition_user_measured_date
            ON body_composition(user_id, measured_date DESC)
            """)
    }

    private static func applyV29TimezoneHistoryColumnParityMigration(db: Database) throws {        let columns = try columnNames(db: db, table: "timezone_history")
        guard !columns.isEmpty else { return }

        let hasCanonicalColumn = columns.contains("time_zone_identifier")
        let hasLegacyColumn = columns.contains("timezone_identifier")

        if !hasCanonicalColumn {
            try db.execute(sql: "ALTER TABLE timezone_history ADD COLUMN time_zone_identifier TEXT")
        }

        if hasLegacyColumn {
            try db.execute(sql: """
                UPDATE timezone_history
                SET time_zone_identifier = COALESCE(
                    NULLIF(time_zone_identifier, ''),
                    NULLIF(timezone_identifier, ''),
                    'UTC'
                )
                """)
        } else {
            try db.execute(sql: """
                UPDATE timezone_history
                SET time_zone_identifier = COALESCE(NULLIF(time_zone_identifier, ''), 'UTC')
                """)
        }
    }

    private static func applyV31MenstrualLocalFieldEncryptionMigration(db: Database) throws {
        // Menstrual data is the most privacy-sensitive category in Life OS and
        // is local-only by default; its fields must meet the same
        // ciphertext-at-rest bar as health_measurements (v25).
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT rowid AS local_rowid, id, flow, pain_level
                FROM menstrual_logs
                WHERE flow IS NOT NULL
                   OR pain_level IS NOT NULL
                """
        )

        for row in rows {
            guard let localRowID = migrationSQLiteRowID(row) else {
                throw localEncryptionMigrationError(
                    column: "rowid",
                    rowIdentifier: migrationRowIdentifier(row) ?? "menstrual_logs"
                )
            }
            let rowIdentifier = migrationRowIdentifier(row) ?? "menstrual_logs"

            try db.execute(
                sql: """
                    UPDATE menstrual_logs
                    SET flow = ?,
                        pain_level = ?
                    WHERE rowid = ?
                    """,
                arguments: [
                    try encryptedStorageString(from: row, column: "flow", rowIdentifier: rowIdentifier),
                    try encryptedStorageDouble(from: row, column: "pain_level", rowIdentifier: rowIdentifier),
                    localRowID
                ]
            )
        }
    }

    private static func backfillWellnessLocalDayMetadata(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, user_id, checked_at, date, checked_timezone, checked_utc_offset_minutes
                FROM wellness_checks
                """
        )

        for row in rows {
            guard let recordId = MixedUUIDStorage.decode(from: row, column: "id"),
                  let userId = MixedUUIDStorage.decode(from: row, column: "user_id"),
                  let checkedAt: Date = row["checked_at"] else {
                continue
            }

            let existingDay = normalizedLocalDay(row["date"] as String?)
            let context = try TimeZoneHistoryStore.resolveLocalDayContext(
                forDayString: existingDay ?? HistoricalLocalDayContext.dayString(for: checkedAt, timeZone: .current),
                userId: userId,
                preferredDate: checkedAt,
                db: db
            )
            let resolvedTimeZone = normalizedTimeZoneIdentifier(
                row["checked_timezone"] as String?,
                fallbackOffsetMinutes: row["checked_utc_offset_minutes"] as Int?,
                fallback: context.timeZoneIdentifier
            )
            let resolvedOffset = (row["checked_utc_offset_minutes"] as Int?)
                ?? resolvedTimeZone.secondsFromGMT(for: checkedAt) / 60
            let resolvedDay = existingDay ?? context.dayString

            try db.execute(
                sql: """
                    UPDATE wellness_checks
                    SET date = ?,
                        checked_timezone = ?,
                        checked_utc_offset_minutes = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    resolvedDay,
                    resolvedTimeZone.identifier,
                    resolvedOffset,
                    recordId,
                    recordId.uuidString
                ]
            )
        }
    }

    private static func backfillBodyCompositionLocalDayMetadata(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, user_id, measured_at, measured_date, measured_timezone, measured_utc_offset_minutes
                FROM body_composition
                """
        )

        for row in rows {
            guard let recordId = MixedUUIDStorage.decode(from: row, column: "id"),
                  let userId = MixedUUIDStorage.decode(from: row, column: "user_id"),
                  let measuredAt: Date = row["measured_at"] else {
                continue
            }

            let context = try TimeZoneHistoryStore.resolveLocalDayContext(
                for: measuredAt,
                userId: userId,
                db: db
            )
            let resolvedTimeZone = normalizedTimeZoneIdentifier(
                row["measured_timezone"] as String?,
                fallbackOffsetMinutes: row["measured_utc_offset_minutes"] as Int?,
                fallback: context.timeZoneIdentifier
            )
            let resolvedDay = normalizedLocalDay(row["measured_date"] as String?)
                ?? HistoricalLocalDayContext.dayString(for: measuredAt, timeZone: resolvedTimeZone)
            let resolvedOffset = (row["measured_utc_offset_minutes"] as Int?)
                ?? resolvedTimeZone.secondsFromGMT(for: measuredAt) / 60

            try db.execute(
                sql: """
                    UPDATE body_composition
                    SET measured_date = ?,
                        measured_timezone = ?,
                        measured_utc_offset_minutes = ?
                    WHERE id = ? OR id = ?
                    """,
                arguments: [
                    resolvedDay,
                    resolvedTimeZone.identifier,
                    resolvedOffset,
                    recordId,
                    recordId.uuidString
                ]
            )
        }
    }

    private static func normalizedLocalDay(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              HistoricalLocalDayContext.referenceDate(for: trimmed, timeZone: .current) != nil else {
            return nil
        }
        return trimmed
    }

    private static func normalizedTimeZoneIdentifier(
        _ value: String?,
        fallbackOffsetMinutes: Int?,
        fallback: String
    ) -> TimeZone {
        let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let timeZone = TimeZone(identifier: candidate) {
            return timeZone
        }
        return HistoricalLocalDayContext.safeTimeZone(
            identifier: fallback,
            fallbackOffsetMinutes: fallbackOffsetMinutes
        )
    }

    private static func encryptFoodLogSensitiveFields(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT rowid AS local_rowid, id, location_lat, location_lng
                FROM food_logs
                WHERE location_lat IS NOT NULL
                   OR location_lng IS NOT NULL
                """
        )

        for row in rows {
            guard let localRowID = migrationSQLiteRowID(row) else {
                throw localEncryptionMigrationError(column: "rowid", rowIdentifier: migrationRowIdentifier(row) ?? "food_logs")
            }
            let rowIdentifier = migrationRowIdentifier(row) ?? "food_logs"

            try db.execute(
                sql: """
                    UPDATE food_logs
                    SET location_lat = ?,
                        location_lng = ?
                    WHERE rowid = ?
                    """,
                arguments: [
                    try encryptedStorageDouble(from: row, column: "location_lat", rowIdentifier: rowIdentifier),
                    try encryptedStorageDouble(from: row, column: "location_lng", rowIdentifier: rowIdentifier),
                    localRowID
                ]
            )
        }
    }

    private static func encryptMedicalScanSensitiveFields(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT rowid AS local_rowid, id, image_url, original_image_url
                FROM medical_scans
                WHERE image_url IS NOT NULL
                   OR original_image_url IS NOT NULL
                """
        )

        for row in rows {
            guard let localRowID = migrationSQLiteRowID(row) else {
                throw localEncryptionMigrationError(column: "rowid", rowIdentifier: migrationRowIdentifier(row) ?? "medical_scans")
            }
            let rowIdentifier = migrationRowIdentifier(row) ?? "medical_scans"

            try db.execute(
                sql: """
                    UPDATE medical_scans
                    SET image_url = ?,
                        original_image_url = ?
                    WHERE rowid = ?
                    """,
                arguments: [
                    try encryptedStorageString(from: row, column: "image_url", rowIdentifier: rowIdentifier),
                    try encryptedStorageString(from: row, column: "original_image_url", rowIdentifier: rowIdentifier),
                    localRowID
                ]
            )
        }
    }

    private static func encryptHealthMeasurementSensitiveFields(db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT rowid AS local_rowid, id, value, original_value
                FROM health_measurements
                """
        )

        for row in rows {
            guard let localRowID = migrationSQLiteRowID(row) else {
                throw localEncryptionMigrationError(column: "rowid", rowIdentifier: migrationRowIdentifier(row) ?? "health_measurements")
            }
            let rowIdentifier = migrationRowIdentifier(row) ?? "health_measurements"

            try db.execute(
                sql: """
                    UPDATE health_measurements
                    SET value = ?,
                        original_value = ?
                    WHERE rowid = ?
                    """,
                arguments: [
                    try encryptedStorageDouble(from: row, column: "value", rowIdentifier: rowIdentifier),
                    try encryptedStorageDouble(from: row, column: "original_value", rowIdentifier: rowIdentifier),
                    localRowID
                ]
            )
        }
    }

    private static func encryptedStorageString(
        from row: Row,
        column: String,
        rowIdentifier: String
    ) throws -> String? {
        let value: DatabaseValue = row[column]
        if value.isNull {
            return nil
        }

        guard let rawValue = String.fromDatabaseValue(value) else {
            throw localEncryptionMigrationError(column: column, rowIdentifier: rowIdentifier)
        }

        if FieldEncryption.isStorageEncrypted(rawValue) {
            return rawValue
        }

        let plaintext = FieldEncryption.decryptStoredString(rawValue) ?? rawValue
        return try FieldEncryption.encryptForStorage(plaintext)
    }

    private static func encryptedStorageDouble(
        from row: Row,
        column: String,
        rowIdentifier: String
    ) throws -> String? {
        let value: DatabaseValue = row[column]
        if value.isNull {
            return nil
        }

        if let numericValue = Double.fromDatabaseValue(value) {
            return try FieldEncryption.encryptDoubleForStorage(numericValue)
        }

        if let integerValue = Int.fromDatabaseValue(value) {
            return try FieldEncryption.encryptDoubleForStorage(Double(integerValue))
        }

        if let rawValue = String.fromDatabaseValue(value) {
            if FieldEncryption.isStorageEncrypted(rawValue) {
                return rawValue
            }

            if let plaintextNumericValue = FieldEncryption.decryptStoredDouble(rawValue) {
                return try FieldEncryption.encryptDoubleForStorage(plaintextNumericValue)
            }
        }

        throw localEncryptionMigrationError(column: column, rowIdentifier: rowIdentifier)
    }

    private static func migrationRowIdentifier(_ row: Row) -> String? {
        if let id: String = row["id"] {
            return id
        }
        return MixedUUIDStorage.decode(from: row, column: "id").map(MixedUUIDStorage.encode)
    }

    private static func migrationSQLiteRowID(_ row: Row) -> Int64? {
        if let rowID: Int64 = row["local_rowid"] {
            return rowID
        }
        if let rowID: Int = row["local_rowid"] {
            return Int64(rowID)
        }
        return nil
    }

    private static func localEncryptionMigrationError(column: String, rowIdentifier: String) -> NSError {
        NSError(
            domain: "Migrations",
            code: 2501,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to encrypt local sensitive field \(column) for row \(rowIdentifier)."
            ]
        )
    }

    private static func normalizeHealthMeasurementOutboxBody(_ data: Data) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let biomarkerName = normalizedString(in: object, keys: ["biomarker_name", "biomarkerName"])
        let originalLabel = normalizedString(in: object, keys: ["original_label", "originalLabel"]) ?? biomarkerName
        let markerId = HealthMeasurement.canonicalMarkerId(
            markerId: normalizedString(in: object, keys: ["marker_id", "markerId"]),
            biomarkerName: biomarkerName,
            originalLabel: originalLabel
        )
        if let markerId {
            object["marker_id"] = markerId
        }

        let sourceScanId = normalizedString(in: object, keys: ["source_scan_id", "sourceScanId"])
            ?? normalizedString(in: object, keys: ["medical_scan_id", "medicalScanId"])
        if let sourceScanId {
            object["source_scan_id"] = sourceScanId
        }

        if let originalLabel {
            object["original_label"] = originalLabel
        }

        if let userId = normalizedString(in: object, keys: ["user_id", "userId"]) {
            object["user_id"] = userId
        }
        if let createdAt = normalizedString(in: object, keys: ["created_at", "createdAt"]) {
            object["created_at"] = createdAt
        }
        if let updatedAt = normalizedString(in: object, keys: ["updated_at", "updatedAt"]) {
            object["updated_at"] = updatedAt
        }

        let numericValue = normalizedNumber(in: object, keys: ["value"])
        if let numericValue {
            object["value"] = numericValue
        }

        if let unit = normalizedString(in: object, keys: ["unit"]) {
            object["unit"] = unit
            object["original_unit"] = normalizedString(in: object, keys: ["original_unit", "originalUnit"]) ?? unit
        }

        if let originalValue = normalizedNumber(in: object, keys: ["original_value", "originalValue"]) ?? numericValue {
            object["original_value"] = originalValue
        }

        let referenceRangeLow = normalizedNumber(in: object, keys: ["reference_range_low", "referenceRangeLow"])
        let referenceRangeHigh = normalizedNumber(in: object, keys: ["reference_range_high", "referenceRangeHigh"])
        if let referenceRangeLow {
            object["reference_range_low"] = referenceRangeLow
        }
        if let referenceRangeHigh {
            object["reference_range_high"] = referenceRangeHigh
        }

        if let measuredAt = normalizedDateOnlyString(
            normalizedString(
                in: object,
                keys: ["measured_at", "measuredAt", "measured_date", "measuredDate", "created_at", "createdAt"]
            )
        ) {
            object["measured_at"] = measuredAt
        }

        let normalizedStatus = HealthMeasurementStatus.canonicalRawValue(
            for: normalizedString(in: object, keys: ["status"]),
            value: numericValue,
            referenceRangeLow: referenceRangeLow,
            referenceRangeHigh: referenceRangeHigh
        )
        if let normalizedStatus {
            object["status"] = normalizedStatus
        } else {
            object.removeValue(forKey: "status")
        }

        if let confidence = normalizedNumber(in: object, keys: ["confidence", "ai_confidence", "aiConfidence"]) {
            object["confidence"] = confidence
        }

        object["source_type"] = HealthMeasurement.normalizedSourceType(
            normalizedString(in: object, keys: ["source_type", "sourceType"])
        ) ?? "scan"
        object["manually_verified"] = normalizedBool(
            in: object,
            keys: ["manually_verified", "manuallyVerified"]
        ) ?? false

        [
            "medical_scan_id", "medicalScanId",
            "biomarker_name", "biomarkerName",
            "measured_date", "measuredDate",
            "ai_confidence", "aiConfidence",
            "user_corrected", "userCorrected",
            "sourceScanId", "markerId", "originalLabel",
            "originalUnit", "originalValue", "referenceRangeLow", "referenceRangeHigh",
            "sourceType", "manuallyVerified", "userId", "createdAt", "updatedAt"
        ].forEach { object.removeValue(forKey: $0) }

        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func addColumnIfMissing(db: Database, table: String, sql: String) throws {
        let parts = sql.lowercased().components(separatedBy: " add column ")
        guard parts.count == 2 else {
            try db.execute(sql: sql)
            return
        }
        let remainder = parts[1]
        let columnName = remainder.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init) ?? ""
        if columnName.isEmpty {
            try db.execute(sql: sql)
        } else {
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
            let names = Set(rows.compactMap { ($0["name"] as String?)?.lowercased() })
            if !names.contains(columnName.lowercased()) {
                try db.execute(sql: sql)
            }
        }
    }

    private static func columnNames(db: Database, table: String) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
        return Set(rows.compactMap { ($0["name"] as String?)?.lowercased() })
    }

    private static func normalizedString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let rawValue = object[key] else { continue }
            if let stringValue = rawValue as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func normalizedNumber(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let rawValue = object[key] else { continue }
            if let number = rawValue as? NSNumber {
                return number.doubleValue
            }
            if let stringValue = rawValue as? String,
               let number = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
        }
        return nil
    }

    private static func normalizedBool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let rawValue = object[key] else { continue }
            if let boolValue = rawValue as? Bool {
                return boolValue
            }
            if let numberValue = rawValue as? NSNumber {
                return numberValue.boolValue
            }
            if let stringValue = rawValue as? String {
                switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "1":
                    return true
                case "false", "0":
                    return false
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func normalizedDateOnlyString(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        if HealthMeasurement.dateOnlyDate(from: rawValue) != nil {
            return rawValue
        }
        if let parsedDate = ISO8601DateFormatter.supabaseDate(from: rawValue) {
            return HealthMeasurement.dateOnlyString(from: parsedDate)
        }
        if let parsedDate = ISO8601DateFormatter.noFractionalDate(from: rawValue) {
            return HealthMeasurement.dateOnlyString(from: parsedDate)
        }
        return nil
    }

    private static func lowercasedString(from value: (any DatabaseValueConvertible)?) -> String {
        guard let raw = value as? String else { return "" }
        return raw.lowercased()
    }

    private static func uppercasedString(from value: (any DatabaseValueConvertible)?) -> String {
        guard let raw = value as? String else { return "" }
        return raw.uppercased()
    }
}

#if DEBUG
extension Migrations {
    static func _testApplyV21MenstrualUserFkCascadeMigration(db: Database) throws {
        try applyV21MenstrualUserFkCascadeMigration(db: db)
    }

    static func _testApplyV22MedicalScanTypeCanonicalizationMigration(db: Database) throws {
        try applyV22MedicalScanTypeCanonicalizationMigration(db: db)
    }

    static func _testNormalizeMedicalScanOutboxBody(_ data: Data) -> Data? {
        normalizeMedicalScanOutboxBody(data)
    }

    static func _testApplyV23HealthMeasurementsContractHardeningMigration(db: Database) throws {
        try applyV23HealthMeasurementsContractHardeningMigration(db: db)
    }

    static func _testApplyV25LocalSensitiveFieldEncryptionMigration(db: Database) throws {
        try applyV25LocalSensitiveFieldEncryptionMigration(db: db)
    }

    static func _testApplyV26TrainingPlanSessionStatusCanonicalizationMigration(db: Database) throws {
        try applyV26TrainingPlanSessionStatusCanonicalizationMigration(db: db)
    }

    static func _testNormalizeHealthMeasurementOutboxBody(_ data: Data) -> Data? {
        normalizeHealthMeasurementOutboxBody(data)
    }

    static func _testAddColumnIfMissing(db: Database, table: String, sql: String) throws {
        try addColumnIfMissing(db: db, table: table, sql: sql)
    }
}
#endif
