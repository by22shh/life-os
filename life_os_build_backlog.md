# LIFE OS — Build Backlog (MVP → V2)

**Version:** 0.5
**Date:** February 4, 2026
**Purpose:** Concrete implementation backlog derived from PRD + UX + API specs.

---

## Release Mapping (Locked)

- **V1 (MVP):** all **P0** items.
- **V2:** all **P1** items + watchOS companion surfaces (complications + glance).
- **V3+:** **P2** items (hardening and future expansion).

## P0 (Must Ship for MVP)

0. Auth bootstrap (silent)
- Supabase anonymous sign-in on first launch
- Create/Upsert `users` row keyed by `auth_id`
- Support later upgrade/link to Apple/email without data loss

1. Onboarding (6 steps + optional)
- Implement progress indicator + 6 required screens
- Implement optional 4A (supplements) + 4B (labs import)
- Ensure “Skip” paths are safe and do not block app access

2. Apple Health / HealthKit connection + sync (per `life_os_healthkit_spec.md`)
- Implement permission request UX (Step 3, skippable)
- Implement initial backfill (14 days)
- Implement anchored incremental sync per type
- Implement background delivery (sleep/HRV/workouts) + morning refresh window
- Implement deterministic daily aggregation + `data_completeness` + `confidence_score`
- Implement source precedence defaults + Settings override (later UI ok; defaults required)

3. Offline sync engine (outbox + pull)
- Implement outbox enqueue for all create/update/delete flows
- Implement retry with exponential backoff + offline persistence
- Implement pull sync with per-table cursors and deterministic ordering
- Implement idempotency keys + conflict resolution (last-write-wins + server timestamps)
- Implement sync status banner + safe retry UX
- Align to `life_os_sync_engine_spec.md` and offline-safe contract in `life_os_api_specification.md`

4. Diary data model correctness (time zones)
- Ensure client sends `logged_date`, `taken_date`, `session_date`
- Ensure client sends `*_timezone` + `*_utc_offset_minutes` when possible
- Ensure server stores `TIMESTAMPTZ` + `*_date` and diaries group by `*_date`

5. Nutrition diary (month/week/day)
- Implement day view with macro summary + meal list
- Implement week strip + month grid sheet
- Implement quick add for a specific date

6. Nutrition logging (method picker + flows)
- Implement Log Meal method picker sheet (photo/barcode/voice/search/quick add)
- Implement photo capture → analyze → Review Meal → save (low-confidence gating)
- Implement manual search + current meal tray + portion editor
- Implement barcode scan → lookup → portion → add (Open Food Facts + cache)
- Implement CIS-critical fallback: “Scan Nutrition Label” → `analyze-food-label` → Review Product → `POST /api/foods/barcode/{code}/create`
- Implement voice transcript → parse-food-text → max 2 clarifications → Review Meal
- Implement Meal Detail + edit + delete/undo (`GET/PATCH/DELETE /api/food/log/{id}` + undo)

7. Foods API + caching tables
- Implement `food_catalog_items`, `user_foods`, `user_food_favorites` + RLS policies
- Implement `GET /api/foods/search`
- Implement `GET /api/foods/barcode/{code}`
- Implement `POST /api/foods/barcode/{code}/create` (persist reviewed label OCR product)
- Implement `POST /api/foods/custom`
- Implement `POST /api/foods/favorites`
- Implement edge functions: `foods-search`, `foods-barcode-lookup`, `analyze-food-label`
- Add Settings → Data Sources screen (Open Food Facts attribution + community label scan disclosure)

8. Training diary (month/week/day) + workout logging
- Implement planned vs logged in one day view
- Implement week strip + month grid sheet
- Implement “Start” planned session and “View logged” session
- Implement workout session logging UI (sets/reps/weight) for manual strength
- Implement Workout Detail + edit + delete/undo (`GET/PATCH/DELETE /api/workouts/{id}` + undo)

9. Training imports + conflict resolution
- Import workouts from HealthKit into `workout_sessions` (`source='import'`, `import_provider='healthkit'`, `import_source_id`)
- Implement de-dupe on `import_source_id`
- Implement duplicate detection heuristics (time overlap) for edge cases
- Implement merge/keep modal + undo for manual vs import conflicts

10. Calendar range APIs
- Implement `GET /api/nutrition/calendar`
- Implement `GET /api/workouts/calendar`
- Implement `GET /api/training/plan/sessions`

11. Labs import
- Implement `POST /api/labs/scan` async flow
- Implement `GET /api/labs/scan/{scan_id}` for status + extracted markers
- Implement review screen that blocks saving on low confidence

12. Copy system
- Enforce copy-by-`copy_id` rule
- Add missing copy ids only through `life_os_copy_catalog.md`

13. Notification settings + control level
- Implement `notification_settings` table + RLS
- Implement `GET/PATCH /api/settings/notifications`
- Wire Settings → Notifications UI + Control Level UI
- Enforce max total notifications per day (6)
- Implement Focus Control integration for Guardian (iOS Screen Time/FamilyControls)
  - Permission flow + app picker UI
  - Local-only storage of selected app list

14. Account deletion + GDPR export
- Implement `POST /api/account/delete` (JWT-derived user; async delete scheduling)
- Implement `GET /api/account/delete/status` (progress + ETA)
- Implement `POST /api/account/export` + `GET /api/account/export/{id}`
- Add in-app “Privacy & Data” screen with export/delete entry points

---

## P1 (High Value Soon After MVP)

1. Unified daily diary
- One screen aggregating Sleep/Recovery + Meals + Workouts + Supplements + Labs

2. Supplements daily endpoint
- Implement `GET /api/supplements/daily` (schedule + taken status)

3. Supplements calendar (month grid)
- Add month grid view in Supplements diary
- Implement `GET /api/supplements/calendar`

4. Recovery by date
- Implement `GET /api/recovery/daily?date=...`

5. Meal templates + Quick Add persistence (explicit entities)
- Decision: templates are explicit entities (not derived-only)
- Add entities/tables for templates
- Add template creation from Review Meal

6. Sleep UX surfaces
- Dedicated Sleep detail screen (stages, trends, recommendations)
- Sleep diary view (month/week/day or integrate into Unified Diary)

7. Meal Prep / Batch Recipes
- Implement batch library + detail screens (active/archived)
- Implement create flow: precise ingredients + quick photo draft (review required)
- Implement logging a portion to a meal + remaining weight tracking
- Implement duplicate (“cook again”) + archive
- Implement `analyze-batch-recipe-image` edge function wiring + cost throttles

8. Insights + Experiments UX
- Implement Insights list + detail with confidence and “Why this”
- Implement Experiment create + detail + daily logging

9. watchOS companion (V2)
- Implement `GET /api/watch/snapshot?date=...` (minimal safe payload)
- Implement iPhone → watch snapshot sync via WatchConnectivity (encrypted local cache)
- Implement complications (recovery score + zone label)
- Implement watch Glance view (recovery + next best action + due soon + last updated)
- Implement safe one-tap actions: supplement “Taken”, insight “Got it” (host executes API calls)

10. Training plan management UX + endpoints
- Plan detail screen + status controls (pause/resume/archive)
- Implement `GET /api/training/plan/{id}`
- Implement `PATCH /api/training/plan/{id}` (status updates)

11. Training load analysis surfaces
- Weekly/rolling ACWR + TRIMP summaries
- Trend charts + “load spike” warnings
- API contract for weekly metrics (see item 12)

12. Weekly session metrics API
- Implement `GET /api/workouts/weekly?from=...&to=...` (session counts, duration, TRIMP)
- Add response schema to `life_os_api_specification.md`

---

## P2 (Nice to Have)

1. Food database strategy (hardening)
- Monitor OFF coverage + not-found rate (CIS)
- Add transliteration-tolerant search (V1+)
- Add additional provider fallback only if OFF+OCR coverage is insufficient (future)

2. Experiments UX
- Surface N-of-1 experiments in a friendly way

---

## Acceptance Criteria (Key)

- Diaries:
  - Meals logged at 00:30 local time must appear on the correct local date.
  - Month grid must load in one request per module (no 30-request fan-out).
  - Timestamps displayed in day view must respect stored `*_timezone` / `*_utc_offset_minutes` when present.

- Onboarding:
  - User can complete onboarding without HealthKit and still reach the Home screen.
  - Notification permission is never asked before Step 6.

- HealthKit:
  - Imported workouts must de-dupe by `import_source_id` (HealthKit UUID).
  - Travel across time zones must not shift historical diary dates.

- Nutrition logging:
  - Barcode not found must offer Search/Photo/Manual without blocking logging.
  - Barcode miss must offer “Scan label” (CIS-critical) and require Review Product before saving a reusable barcode product.
  - Voice parsing must never ask more than 2 clarification questions per meal.
  - Meal delete must be soft + undoable within 24 hours.
  - Workout delete must be soft + undoable within 24 hours.

- Labs:
  - Low-confidence OCR cannot be saved without review.

- watchOS:
  - watch never calls backend directly in V2 (host-only networking).
  - Offline watch shows cached snapshot and disables actions safely.
  - One-tap watch actions reflect updated state within 5 seconds when phone is reachable.
