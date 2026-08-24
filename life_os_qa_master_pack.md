# LIFE OS — QA Master Pack (Unified)

**Version:** 0.3  
**Date:** February 4, 2026  
**Purpose:** Single, unified QA pack that combines:
- E2E scenarios (checklists)
- Acceptance criteria (subsystem pass/fail)
- Master Matrix (scenario → UX → API → errors → copy)
- CIS edge cases
- Data lineage (scenario → tables → fields)

This file is designed so QA can run one “master checklist” without jumping between documents.

---

## 1) E2E Scenarios (Index)

| ID | Scenario | Source |
|---|---|---|
| A | Barcode miss → Label OCR → Save → Repeat log | `life_os_e2e_test_checklists.md` |
| B | Meal Prep (Batch) → Create → Log portion → Undo | `life_os_e2e_test_checklists.md` |
| C | HealthKit Sync + Travel/Timezone | `life_os_e2e_test_checklists.md` |
| D | Manual vs Imported Workout Conflict | `life_os_e2e_test_checklists.md` |
| E | Labs OCR (Async + Privacy + Duplicates) | `life_os_e2e_test_checklists.md` |
| F | Supplements (Schedule + Adherence + Reminders) | `life_os_e2e_test_checklists.md` |
| G | Notifications + Control + Focus Control | `life_os_e2e_test_checklists.md` |
| H | Unified Daily Diary (V2) | `life_os_e2e_test_checklists.md` |
| I | Sleep Diary (V2) | `life_os_e2e_test_checklists.md` |
| J | watchOS Companion (V2) | `life_os_e2e_test_checklists.md` |
| K | GDPR + Consent | `life_os_e2e_test_checklists.md` |
| L | Insights + Experiments | `life_os_e2e_test_checklists.md` |
| M | Offline Sync Resilience | `life_os_e2e_test_checklists.md` |
| N | Sleep Manual Entry (V2) | `life_os_e2e_test_checklists.md` |
| O | Training Plan Generation + Management | `life_os_e2e_test_checklists.md` |
| P | Templates V2 Management | `life_os_e2e_test_checklists.md` |
| Q | Accessibility Validation | `life_os_e2e_test_checklists.md` |

---

## 2) Acceptance Criteria (Pass/Fail)

> **Run once per release**. All must pass.

### 2.1 Onboarding & Auth
1. Silent auth creates `users` row on first launch.
2. Onboarding required steps ≤ 6.
3. HealthKit prompt only after value demo.
4. Notifications prompt only after first insight.
5. User reaches Home without permissions.
6. Account upgrade preserves data.

### 2.1A Control & Notifications
1. Notification settings load and save successfully.
2. Max total notifications per day enforced at 6.
3. Guardian control is blocked unless Focus Control is enabled.
4. If "Critical alerts only" is enabled, Control Level is forced to Advisory.

### 2.2 Nutrition Diary & Logging
1. Day view uses `GET /api/nutrition/daily`.
2. Month grid uses `GET /api/nutrition/calendar`.
3. Calendar cells never rely on color only.
4. `logged_date` is authoritative for grouping.
5. Offline logging queues and syncs without duplication.

### 2.3 Barcode & Food Data
1. OFF is primary provider; attribution shown in Settings.
2. Barcode miss shows Search/Photo/Manual/Scan Label.
3. Label OCR never saves without Review Product.
4. User overrides win on re-scan.
5. Label photos are not stored by default.

### 2.4 Meal Prep / Batch
1. Precise mode requires total cooked grams.
2. Quick mode is draft + review required.
3. Portion log creates a single item with `batch_recipe_id`.
4. Remaining weight derived from non-deleted meals.
5. Editing batch affects future logs only.

### 2.5 Training
1. Training calendar uses `/api/workouts/calendar`.
2. Manual logging supports set/rep/weight.
3. Conflict resolution prompts user, never silent.
4. Workout delete is soft + undoable.

### 2.6 HealthKit
1. 14-day backfill on first connect.
2. Anchors prevent duplicates.
3. Recovery scores computed per spec.
4. Travel doesn’t shift diary days.

### 2.7 Labs
1. OCR is async and non-blocking.
2. Low confidence requires review.
3. Duplicate detection triggers on overlap.
4. Default storage is local-only.

### 2.8 Supplements
1. Schedule visible in `/api/supplements/daily`.
2. One-tap "Taken" logs successfully.
3. Adherence updates after log.
4. Timing tips are non-medical.
5. Supplements month grid loads via `GET /api/supplements/calendar?from=...&to=...` (max 62 days).

### 2.9 Insights & Experiments
1. Insights list loads and shows confidence.
2. Insight detail shows “Why this”.
3. Experiment create works from insight.
4. Daily experiment log is non-blocking.

### 2.10 Unified Daily Diary (V2)
1. Day view loads via `GET /api/diary/daily` (single request).
2. Month grid loads via `GET /api/diary/calendar` (max 62 days).
3. `needs_review` propagates to the month grid status.
4. `next_best_action` maps to a real in-app action.

### 2.11 Sleep (V2)
1. Sleep day view loads via `GET /api/sleep/daily?date=...`.
2. Sleep month grid loads via `GET /api/sleep/calendar?from=...&to=...` (max 62 days).
3. Missing/partial permission states are non-blocking and show correct copy IDs.

### 2.12 watchOS Companion (V2)
1. iPhone host fetches `GET /api/watch/snapshot?date=...` and syncs to watch.
2. watch never calls backend directly in V2.
3. Offline watch shows cached snapshot and disables actions safely.
4. One-tap “Taken” triggers `POST /api/supplements/log` on iPhone and updates watch within 5 seconds (reachable phone).

---

## 3) Master Matrix (Scenario → UX → API → Errors → Copy)

> Condensed version; full table remains in `life_os_e2e_master_matrix.md`.

| Scenario | UX | API | Errors | Copy |
|---|---|---|---|---|
| Barcode miss | 3.11–3.11A | foods/barcode + analyze-food-label + create | FoodDBError.label* | nutrition.barcode_* + label_scan_* |
| Meal prep | 3.16 | /nutrition/batches | BatchRecipeError.* | nutrition.batch_* |
| HealthKit sync | Step 3 + Sleep detail | recovery + HK sync | HealthKitError.* | onboarding.healthkit_* |
| Workout conflict | 4.6 | workouts/{id} + undo | WorkoutError.* | training.merge_* |
| Labs OCR | 6.x | labs/scan | OCR errors | labs.* |
| Supplements | Supplements screens | supplements/daily + log | SupplementError.* + DatabaseError.syncConflict | supplements.* |
| Notifications + Control | 8.x | settings/notifications | FocusControlError.* | settings.* |
| Unified Diary (V2) | 5.x | diary/daily + diary/calendar | NetworkError.* | diary.* |
| Sleep (V2) | Sleep surfaces | sleep/daily + sleep/calendar | HealthKitError.* | sleep.* |
| watchOS (V2) | 11.x | watch/snapshot | NetworkError.* | watch.* + global.open_on_iphone |

---

## 4) CIS Edge Cases (Must Pass)

1. Cyrillic labels with Б/Ж/У, ккал.
2. Only kJ provided → kcal conversion.
3. Salt only → sodium derived.
4. Comma decimals parsed correctly.
5. Mixed-language product names (RU + EN).
6. Barcode misses treated as normal (label scan first-class).
7. Week starts Monday; 24h time format.
8. Cyrillic marker names (e.g., "ТТГ" for TSH, "ЛПНП" for LDL) must match `health_marker_catalog` aliases.
9. CIS-specific lab units (e.g., "мкМЕ/мл" for mIU/mL) must be normalized to canonical units.
10. Reference ranges with em-dashes (e.g., "3,5—5,0") must be parsed correctly (not rejected as invalid).

---

## 5) Data Lineage (Critical Fields)

| Scenario | Tables | Critical Fields |
|---|---|---|
| Nutrition day view | `food_logs`, `food_items` | `logged_date`, macro totals |
| Barcode lookup | `food_catalog_items`, `user_foods` | `barcode`, `provider`, `macros_per_100g` |
| Meal prep log | `food_items`, `batch_recipes` | `batch_recipe_id`, `weight_g` |
| Training | `workout_sessions`, `workout_sets` | `session_date`, sets data |
| Recovery | `physiological_states` | `recovery_score`, `confidence_score` |
| Wellness check‑in | `wellness_checks` | `date`, `pss4_total`, `wellness_score` |
| Hydration logging | `hydration_logs` | `logged_date`, `water_ml` |
| Unified diary (V2) | `physiological_states`, `food_logs`, `workout_sessions`, `supplement_logs` | `*_date`, `needs_review`, `recovery_zone` |
| watch snapshot (V2) | `physiological_states`, `recommendations`, `supplement_logs`, `insights` | `recovery_score`, `confidence_score`, `next_best_action` |
| Labs | `medical_scans`, `health_measurements` | `storage_mode`, `processed_data` |
| Supplements | `user_supplements`, `supplement_logs` | `scheduled_times`, `taken_at` |
| Insights | `insights`, `recommendations` | `type`, `priority`, `confidence` |
| Custom exercises | `exercise_catalog` | `is_custom`, `created_by`, `name` |
| Vector memory | `vector_memory` | `vector_id`, `source_type`, `summary` |

---

## 6) Release Gate (Minimal)

The release is **blocked** if:
1. Any acceptance criterion fails.
2. Any E2E scenario A–Q fails.
3. CIS edge cases 1–10 fail.
4. Data lineage fields are missing or null for critical paths.
5. Accessibility checklist fails (VoiceOver, Dynamic Type, contrast).
