# LIFE OS — Data Lineage Matrix (Scenario → Tables → Views → Fields)

**Version:** 0.4  
**Date:** June 23, 2026  
**Purpose:** Trace each major scenario to the exact tables, derived views, and critical fields to eliminate ambiguity during implementation and QA.

---

## Legend
- **Tables**: PostgreSQL tables in `life_os_api_specification.md`
- **Views**: derived views (e.g., `daily_nutrition_summary`)
- **Critical fields**: minimum fields required for correctness

---

## Lineage Table

| Scenario | Tables | Views | Critical Fields |
|---|---|---|---|
| Onboarding baseline profile | `users` | — | `age_range`, `height_cm`, `weight_kg`, `primary_goal`, `units`, `timezone` |
| Nutrition day view | `food_logs`, `food_items`, `daily_nutrition_targets` | `daily_nutrition_summary` | `logged_date`, `logged_timezone`, `logged_utc_offset_minutes`, `calories`, `protein_g`, `fat_g`, `carbs_g`, `ai_confidence`, `user_corrected`, `final_*` targets |
| Nutrition calendar | `food_logs`, `daily_nutrition_targets` | — | `logged_date`, `logged_timezone`, totals by day, `ai_confidence`, `final_*` targets |
| Barcode lookup | `food_catalog_items`, `user_foods` | — | `barcode`, `provider`, `macros_per_100g`, `expires_at` |
| Label OCR fallback | `food_catalog_items` | — | `provider=lifeos_label_ocr`, `macros_per_100g`, `source_confidence` |
| User override for barcode | `user_foods` | — | `barcode`, `macros_per_100g` |
| Meal log (photo/voice/manual) | `food_logs`, `food_items` | — | `input_method`, `logged_date`, `logged_timezone`, `logged_utc_offset_minutes`, item macros snapshot |
| Meal detail | `food_logs`, `food_items` | — | `food_log_id`, item list |
| Meal edit/undo | `food_logs`, `food_items` | — | `deleted_at`, `deleted_reason` |
| Meal prep (batch create) | `batch_recipes`, `batch_recipe_ingredients` | — | `total_weight_g`, `total_*`, `ingredients[*]` |
| Meal prep log portion | `food_logs`, `food_items`, `batch_recipes` | — | `batch_recipe_id`, `weight_g`, per‑100g macros snapshot |
| Training day view | `workout_sessions`, `training_plan_sessions` | — | `session_date`, `started_timezone`, `started_utc_offset_minutes`, `duration_minutes`, `workout_type` |
| Workout detail | `workout_sessions`, `workout_exercises`, `workout_sets` | — | `exercise_id`, set data |
| Workout conflict resolution | `workout_sessions`, `outbox_events`, `sync_state` | — | `updated_at`, `deleted_at`, `deleted_reason`, `import_source_id`, `source`, `status`, `idempotency_key`; V2 sync uses server-authoritative entity-level LWW, not manual sync conflict UI |
| Recovery daily | `physiological_states` | — | `recovery_score`, `data_completeness`, `confidence_score` |
| Wellness check‑in | `wellness_checks` | — | `date`, `checked_timezone`, `checked_utc_offset_minutes`, `pss4_total`, `wellness_score`, `feeling_ill` |
| Hydration logging | `hydration_logs` | — | `logged_date`, `logged_timezone`, `logged_utc_offset_minutes`, `water_ml`, `source` |
| Sleep detail | `physiological_states`, `sleep_logs` | — | `sleep_date`, `sleep_timezone`, `sleep_utc_offset_minutes`, `sleep_duration_hours`, `deep_sleep_percent`, `rem_sleep_percent` |
| Supplements daily | `user_supplements`, `supplement_logs` | — | `scheduled_times`, `taken_at`, `taken_date`, `taken_timezone`, `taken_utc_offset_minutes` |
| Labs import | `medical_scans`, `health_measurements` | — | `storage_mode`, `processed_data`, `source_scan_id`, `marker_id`, `measured_at`, `confidence`, `manually_verified` |
| Labs history | `health_measurements` | — | `marker_id`, `measured_at`, `value`, `unit`, `reference_range_low`, `reference_range_high`, `status` |
| Insights list/detail | `insights`, `recommendations` | — | `type`, `priority`, `confidence_score`, `related_metrics`, `recommendations.insight_id` |
| Body composition trends | `body_composition` | — | `measured_at`, `measured_date`, `measured_timezone`, `measured_utc_offset_minutes`, `weight_kg`, `body_fat_percent`, `lean_mass_kg` |
| Experiments dashboard | `experiments`, `experiment_measurements` | — | `status`, `primary_metric`, `measurement_phase`, `metric_value` |
| Hydration day view | `hydration_logs` | — | `logged_date`, `logged_timezone`, `logged_utc_offset_minutes`, `water_ml`, `source` |
| Weekly strategy report | `weekly_strategy_reports` | — | `week_start`, `week_end`, `report_markdown`, `summary_stats` |
| Custom exercises | `exercise_catalog` | — | `is_custom`, `created_by`, `name` |
| Unified diary (day) | `physiological_states`, `food_logs`, `workout_sessions`, `training_plan_sessions`, `user_supplements`, `supplement_logs`, `sleep_logs`, `medical_scans`, `body_composition` | — | `*_date` fields, matching timezone and UTC offset fields, section `needs_review`, `recovery_zone`, counts |
| Unified diary (calendar) | same as above (aggregated) | — | per-day `status`, `needs_review`, `recovery_zone` |
| watchOS snapshot (glance/complication) | `physiological_states`, `recommendations`, `user_supplements`, `supplement_logs`, `insights` | — | `recovery_score`, `recovery_zone`, `confidence_score`, safe `next_best_action`, `last_updated_at` |
| Notification settings | `notification_settings` | — | `morning_brief_enabled`, `quiet_hours_start`, `max_total_per_day`, `control_level` |
| Onboarding flow | `onboarding_state`, `user_baselines`, `privacy_settings`, `notification_settings` | — | `step`, `completed_at`, HRV/RHR/sleep baselines, privacy defaults |
| Focus Control app list | Local only (device storage) | — | `selected_app_bundle_ids` |
| Vector memory (RAG) | `vector_memory` + Pinecone namespace | — | `vector_id`, `vector_namespace`, `source_type`, `source_id`, `summary` |
| Recommendation feedback loop | `recommendations`, `recommendation_outcomes` | — | `recommendation_id`, `action_taken`, `pre_recovery_score`, `post_recovery_score`, `outcome_delta`, `outcome_quality` |
| Supplement effectiveness | `user_supplements`, `health_measurements`, `supplement_catalog` | — | `supplement_id`, `started_at`, `marker_id`, pre/post `value`, `assessment` |
| Dynamic weight | `body_composition`, `users` | — | `weight_kg`, `measured_at`, `measured_date`, rolling 7-day average, `divergenceFromProfile` |
| Offline sync queue | local `outbox_events`, local `sync_state`, local `local_meta` | — | `status`, `attempt_count`, `next_attempt_at`, `last_error_category`, `user_visible_blocker`, `idempotency_key`, `device_id`, per-table watermarks |
