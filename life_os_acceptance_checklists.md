# LIFE OS — Acceptance Checklists (Subsystem-Level)

**Version:** 0.2  
**Date:** February 4, 2026  
**Purpose:** Concrete acceptance criteria per subsystem that QA and developers can use to validate a “done” implementation without ambiguity.

> These checklists are intentionally blunt: each item is pass/fail.

---

## 1) Onboarding & Auth

1. Silent anonymous auth creates a valid `users` row on first launch.
2. Onboarding is max 6 required steps (optional steps do not block progress).
3. HealthKit permission request happens **after** Step 2 (value demo).
4. Notifications permission is asked **after** Step 6 (first insight).
5. User can reach Home without granting HealthKit or Notifications.
6. Upgrade/link Apple/email does **not** lose data.

---

## 1.5) Control & Notifications

1. Notification settings load via `GET /api/settings/notifications`.
2. Notification settings save via `PATCH /api/settings/notifications`.
3. Max total notifications per day is enforced at 6.
4. `control_level='guardian'` is blocked unless Focus Control is enabled.
5. Focus Control app selection is stored locally only and never synced.
6. If “Critical alerts only” is enabled, Control Level is forced to Advisory.

---

## 2) Nutrition Diary (Calendar + Day View)

1. Day view loads via `GET /api/nutrition/daily?date=...`.
2. Month grid loads via `GET /api/nutrition/calendar?from=...&to=...` (max 62 days).
3. Each calendar cell has icon + text label (no color-only meaning).
4. Diary grouping always uses `logged_date` (local date), not UTC.
5. Offline logging queues locally and syncs later without duplicates.

---

## 3) Nutrition Logging (Photo / Barcode / Voice / Manual / Quick Add)

1. Method picker opens in 1 tap from day view.
2. Photo log flow always routes to Review Meal before save.
3. Voice log asks max 2 clarification questions.
4. Manual search uses favorites + recents ranking; search works for Cyrillic.
5. Portion editor always shows grams as canonical.
6. `POST /api/food/log` snapshots item macros and totals.
7. Meal detail screen uses `GET /api/food/log/{id}`.
8. Meal edit uses `PATCH /api/food/log/{id}`.
9. Delete uses soft delete + undo within 24h.

---

## 3.5) Templates (V2)

1. Templates list loads via `GET /api/nutrition/templates`.
2. Template detail loads via `GET /api/nutrition/templates/{id}`.
3. Template edit/rename/archive works via `PATCH /api/nutrition/templates/{id}`.
4. Logging from template works via `POST /api/nutrition/templates/{id}/log`.

---

## 4) Barcode & Food Data (CIS-Optimized)

1. Primary provider is Open Food Facts; attribution exists in Settings → Data Sources.
2. Barcode lookup precedence matches `life_os_food_data_strategy.md`.
3. Barcode “not found” state offers Search/Photo/Manual/Scan Label.
4. Label scan → OCR → Review Product → Save; no DB write before review.
5. User overrides (custom food with barcode) always win on scan.
6. Label photos are **not stored** by default.

---

## 5) Meal Prep / Batch Recipes

1. Library lists active/archived batches correctly.
2. Precise mode requires total cooked weight grams.
3. Quick (photo) mode always marks draft `needs_review = true`.
4. Logging a portion creates a single `food_item` with `batch_recipe_id`.
5. Remaining weight is derived from non-deleted meal logs (no drift).
6. Editing a batch affects future logs, not historical logs.
7. Duplicate (“Cook again”) creates a new batch with new id.

---

## 6) Training Diary & Logging

1. Training calendar loads via `GET /api/workouts/calendar`.
2. Day view shows planned vs logged sessions.
3. Manual strength logging supports set/rep/weight entry.
4. Rest timer (if enabled) triggers after set completion.
5. `POST /api/workouts/log` creates a valid session with exercises/sets.
6. Workout detail uses `GET /api/workouts/{id}`.
7. Delete is soft delete + undo within 24h.

---

## 6.5) Unified Diary (V2)

1. Day view loads via `GET /api/diary/daily?date=...`.
2. Month grid loads via `GET /api/diary/calendar?from=...&to=...` (max 62 days).
3. If any section has low confidence or pending review, the day status becomes `needs_review`.
4. `next_best_action` is present and maps to a real in-app action (log meal/workout/taken/scan).
5. When Unified Diary endpoints are unavailable, app falls back to module endpoints without breaking the day view.

---

## 7) HealthKit Sync

1. Initial backfill imports last 14 days of sleep + HRV + RHR + workouts.
2. Anchored queries prevent duplicates across syncs.
3. Recovery scores are computed per spec.
4. `session_date` / `logged_date` / `taken_date` are correct for travel.

---

## 7.5) Sleep (V2)

1. Sleep day view loads via `GET /api/sleep/daily?date=...`.
2. Sleep month grid loads via `GET /api/sleep/calendar?from=...&to=...` (max 62 days).
3. If sleep stages are unavailable, UI hides stage breakdown and shows `sleep.stages_unavailable`.
4. If Sleep permission is missing, UI shows `sleep.missing_*` + `sleep.connect_primary`.

---

## 8) Labs (OCR + Review + Privacy)

1. Labs OCR is async; user can leave and return later.
2. Low-confidence OCR blocks save until review.
3. Duplicate detection triggers on same-day same-marker overlap ≥ 60%.
4. Default storage mode is local-only for raw scans.
5. Derived markers can sync only when allowed by privacy settings.

---

## 9) Supplements

1. Schedule is visible in `GET /api/supplements/daily`.
2. One-tap “Taken” writes `POST /api/supplements/log`.
3. Adherence percentage updates correctly.
4. Timing tips are informational only (no dose guidance).
5. Supplements month grid loads via `GET /api/supplements/calendar?from=...&to=...` (max 62 days).

---

## 10) Privacy & Data Control

1. Data sources are disclosed (Open Food Facts, community label scan).
2. Food label photos are ephemeral by default.
3. Food photos are deleted at 90 days (retention).
4. Medical scans are local-only by default.
5. Data export contains all core data types.
6. Delete account deletes all data, including vectors.

---

## 11) Insights & Experiments

1. Insights list loads via `GET /api/insights`.
2. Insight detail shows confidence and “Why this”.
3. Starting an experiment creates a record via `POST /api/experiments/create`.
4. Daily experiment logging takes < 20 seconds and is non-blocking.

---

## 12) watchOS Companion (V2)

1. iPhone host can fetch a minimal payload via `GET /api/watch/snapshot?date=...`.
2. watch app never calls backend directly in V2 (all network is host-only).
3. Complication shows recovery score + zone label (never color-only).
4. Glance view shows “Last updated {time}” and the snapshot’s `confidence_score`.
5. If `confidence_score < 0.65`, watch does not offer any risky one-tap actions (routes to iPhone instead).
6. Offline watch shows cached snapshot and disables actions safely (routes via `global.open_on_iphone`).
7. “Taken” on watch results in `POST /api/supplements/log` on iPhone and watch reflects updated state within 5 seconds when reachable.
8. “Got it” on watch results in `POST /api/insights/{id}/acknowledge` on iPhone and watch reflects updated state within 5 seconds.
