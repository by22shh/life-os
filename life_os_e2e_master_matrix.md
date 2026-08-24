# LIFE OS — E2E Master Matrix (Scenario → UX → API → Errors → Copy)

**Version:** 0.2  
**Date:** February 4, 2026  
**Purpose:** One canonical matrix linking each end‑to‑end scenario to UX screens, API endpoints, error codes, and copy IDs.

> This matrix is intentionally compact and implementation-ready. It acts as a QA + dev cross‑reference.

---

## Matrix Legend
- **Scenario**: E2E flow name
- **UX Screens**: canonical sections from `life_os_ux_screens.md`
- **API Endpoints**: primary client calls (from `life_os_api_specification.md`)
- **Error Codes**: from `life_os_error_handling.md`
- **Copy IDs**: minimal set of required copy for the flow

---

## Matrix

| Scenario | UX Screens | API Endpoints | Error Codes | Copy IDs |
|---|---|---|---|---|
| Barcode miss → Scan Label → Review → Save → Repeat log | 3.11–3.11A, 3.8 | `GET /api/foods/barcode/{code}`, `POST /functions/v1/analyze-food-label`, `POST /api/foods/barcode/{code}/create`, `POST /api/food/log` | `FoodDBError.barcodeNotFound`, `labelImageBlurry`, `labelNoNutritionTable`, `labelMacroMismatch` | `nutrition.barcode_*`, `nutrition.label_scan_*`, `nutrition.product_review_*`, `nutrition.add_to_meal` |
| Barcode found (OFF) → Log meal | 3.11, 3.8 | `GET /api/foods/barcode/{code}`, `POST /api/food/log` | `FoodDBError.insufficientNutritionData`, `providerUnavailable` | `nutrition.barcode_*`, `nutrition.add_to_meal` |
| Voice log → Parse → Clarify → Review | 3.12, 3.8 | `POST /functions/v1/parse-food-text`, `POST /api/food/log` | `FoodDBError.parseFailed` | `nutrition.voice_*`, `nutrition.meal_*` |
| Photo log → Analyze → Review | 3.10, 3.8 | `POST /functions/v1/analyze-food-image`, `POST /api/food/log` | `VisionError.*` | `nutrition.photo_log_*`, `nutrition.meal_*` |
| Template library → Edit → Log | 3.15–3.15A | `GET /api/nutrition/templates`, `GET /api/nutrition/templates/{id}`, `PATCH /api/nutrition/templates/{id}`, `POST /api/nutrition/templates/{id}/log` | `ValidationError.*` | `nutrition.save_as_template`, `nutrition.template_*`, `nutrition.templates_*` |
| Meal Prep create (precise) → Save | 3.16.2–3.16.6 | `POST /api/nutrition/batches` | `BatchRecipeError.invalidTotalWeight`, `ingredientMissingMacros` | `nutrition.batch_*` |
| Meal Prep quick (photo) → Review → Save | 3.16.5–3.16.6 | `POST /api/nutrition/batches/quick`, `POST /api/nutrition/batches` | `BatchRecipeError.analysisUnavailable`, `draftLowConfidence` | `nutrition.batch_*` |
| Log batch portion → Day view | 3.16.8, 3.8 | `POST /api/nutrition/batches/{id}/log`, `GET /api/nutrition/daily` | `BatchRecipeError.portionExceedsRemaining` | `nutrition.batch_log_*` |
| Onboarding (6 steps) | 2.x | (auth bootstrap + profile upsert) | `AuthError.*`, `HealthKitError.*` | `onboarding.*` |
| Training log (manual strength) | 4.8–4.11 | `POST /api/workouts/log` | `WorkoutError.*` | `training.*` |
| Conflict manual vs import → Merge/Keep/Undo | 4.6 | `GET /api/workouts/daily`, `PATCH /api/workouts/{id}`, `DELETE /api/workouts/{id}`, `POST /api/workouts/{session_id}/undo` | `WorkoutError.*` | `training.merge_*` |
| Labs OCR → Review → Save | 6.x | `POST /api/labs/scan`, `GET /api/labs/scan/{scan_id}` | `HealthMarkersError.*`, custom lab OCR errors | `labs.*` |
| Supplements daily → Taken | 5.x (Supplements screens) | `GET /api/supplements/daily`, `POST /api/supplements/log` | `SupplementError.*`, `DatabaseError.syncConflict` | `supplements.*` |
| Data Sources (Settings) | 6.5 | N/A (static) | N/A | `settings.data_sources_*` |
| Notification settings → Save | 8.x | `GET /api/settings/notifications`, `PATCH /api/settings/notifications` | `ValidationError.*` | `settings.notifications_title` |
| Control level change | 8.x | `PATCH /api/settings/notifications` | `ValidationError.*` | `settings.control_*` |
| Guardian enable → Focus Control permission | 8.x | `PATCH /api/settings/notifications` | `FocusControlError.*` | `settings.focus_*`, `settings.control_permission_needed` |
| Focus Control app selection | 8.x | N/A (local only) | `FocusControlError.*` | `settings.focus_*` |
| Insight detail → Start experiment | 7.x | `GET /api/insights/{id}`, `POST /api/experiments/create` | `AIError.*` | `insights.*`, `experiments.*` |
| Experiment daily log | 7.x | `POST /api/experiments/{id}/log` | `ValidationError.*` | `experiments.*` |
| Unified diary day view | 5.x | `GET /api/diary/daily` | `NetworkError.*`, `DatabaseError.*` | `diary.*`, `global.*` |
| Unified diary month grid | 5.x | `GET /api/diary/calendar` | `NetworkError.*` | `diary.*` |
| Sleep diary month grid | Sleep surfaces | `GET /api/sleep/calendar`, `GET /api/sleep/daily` | `HealthKitError.*`, `NetworkError.*` | `sleep.*` |
| watchOS glance → one-tap action → sync | 11.x | `GET /api/watch/snapshot`, `POST /api/supplements/log`, `POST /api/insights/{id}/acknowledge` | `NetworkError.*`, `AuthError.*` | `watch.*`, `global.open_on_iphone`, `supplements.log_primary`, `insights.acknowledge` |
| Retention policy enforcement (photos + scans) | Settings → Privacy | N/A (server job) | `DatabaseError.*` | `privacy.retention_*` |
| Data anonymization / k‑anonymity (analytics export) | Settings → Privacy | N/A (analytics pipeline) | N/A | `privacy.anonymization_*` |
| Breach response procedures | Settings → Privacy | N/A (incident playbook) | N/A | `privacy.breach_*` |
| Offline queue dead‑letter handling | Global sync error state | N/A (outbox worker) | `DatabaseError.syncConflict` | `sync.dead_letter_*` |
| Conflict resolution (offline vs server) | Conflict modal | `PATCH /api/*` | `DatabaseError.syncConflict` | `sync.conflict_*` |
| Sleep diary manual entry | Sleep surfaces | `POST /api/sleep/log`, `GET /api/sleep/daily` | `ValidationError.*` | `sleep.manual_*` |
| Training plan AI generation | Training plan creation | `POST /api/training/plan/generate` | `TrainingPlanError.*` | `training.plan_*` |
| Templates V2 (manage/archive) | 3.15A | `GET /api/nutrition/templates`, `PATCH /api/nutrition/templates/{id}` | `ValidationError.*` | `nutrition.templates_*` |
| watchOS accessibility (VoiceOver + contrast) | 11.x | `GET /api/watch/snapshot` | N/A | `watch.*` |
| Labs OCR accessibility | 6.x | `POST /api/labs/scan`, `GET /api/labs/scan/{scan_id}` | `HealthMarkersError.*` | `labs.*` |
| Color palette validation (warm neutrals + Okabe‑Ito) | Design system QA | N/A | N/A | N/A (visual QA only — no runtime copy) |
