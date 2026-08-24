# LIFE OS — End-to-End Test Checklists (Implementation-Ready)

**Version:** 0.4  
**Date:** February 4, 2026  
**Purpose:** Exhaustive, cross-document, end-to-end QA checklists for the highest-impact journeys across V1 + V2:
- Barcode fallback (CIS): label OCR → save reusable barcode product → repeat log
- Meal Prep (batch recipes): create → log portion → calendar/undo
- HealthKit sync + travel/timezones, workout conflicts, labs OCR, supplements adherence
- Notifications/control (Advisory/Protective/Guardian) + Focus Control
- V2 surfaces: Unified Daily Diary, Sleep Diary, watchOS companion

These checklists are written so a dev team (or another LLM) can implement the app and validate behavior without ambiguity.

**Sources of truth referenced:**
- UX: `life_os_ux_screens.md`
- API: `life_os_api_specification.md`
- Food providers strategy: `life_os_food_data_strategy.md`
- Design system: `life_os_design_system.md`
- Copy IDs: `life_os_copy_catalog.md`
- Errors: `life_os_error_handling.md`
- Privacy: `life_os_privacy_architecture.md`
- HealthKit: `life_os_healthkit_spec.md`
- Labs OCR: `life_os_ux_screens.md` (Labs), `life_os_api_specification.md` (labs endpoints), `life_os_privacy_architecture.md`
- Supplements: `life_os_health_ecosystem_spec.md` (supplement rules), `life_os_api_specification.md` (supplement endpoints)
- watchOS: `life_os_watchos_spec.md`

---

## 0) Global Test Setup (Mandatory)

### 0.1 Devices / OS
1. iPhone with camera autofocus and flash (primary).
2. iPhone without flash or with limited camera capability (secondary).
3. Optional: iPad (layout sanity).

### 0.2 Locales / Units (CIS focus)
1. Locale: `ru_RU`, units metric, timezone `Europe/Moscow`.
2. Locale: `en_US` (control), units metric or imperial.
3. Optional: `uk_UA` / `kk_KZ` (search behavior sanity).

### 0.3 Networking Modes
1. Online, stable (Wi‑Fi).
2. Online, poor (high latency, packet loss).
3. Offline (Airplane mode).
4. Online but provider down simulation:
   - Open Food Facts unreachable.
   - Vision endpoints failing.

### 0.4 Test User States (create separate test accounts)
1. New user, onboarding complete, HealthKit not connected.
2. New user, HealthKit connected, has recovery data.
3. Existing user, has favorites and recents (nutrition).

### 0.5 Required Test Fixtures (real-world)
1. Packaged CIS product with barcode that is likely **missing** in providers.
2. Packaged product with barcode that is **present** in Open Food Facts (control).
3. Nutrition label in Cyrillic with typical table: kcal, protein, fat, carbs per 100g and/or per serving.
4. A label that shows only kJ (edge).
5. A label that shows salt but not sodium (edge).
6. A blurry/glare label photo (edge).

### 0.6 Ground Rules for “Pass”
1. No journey may end in a dead-end when logging is the goal.
2. Any AI/OCR-derived structured data must be reviewable and editable before it becomes reusable.
3. Diary grouping is by local date (`*_date` fields), resilient to travel/timezone changes.
4. All user-visible strings used in core flows must map to `copy_id` in `life_os_copy_catalog.md`.

---

## 1) E2E Checklist A — Barcode Miss (CIS) → Label OCR → Save Product → Repeat Log

### A0) Preconditions
1. App locale is `ru_RU`.
2. User is signed in (silent auth ok).
3. Nutrition Day view is open for “today”.
4. Ensure barcode chosen is not already in user overrides or cached catalog for that user.

### A1) Happy Path (Online): Barcode Not Found → Scan Label → Save Product → Log Meal

**Goal:** Turn a barcode miss into a reusable product in 30–60s, then complete a meal log.

**Steps**
1. Open Nutrition day view.
2. Tap `nutrition.diary_log_primary`.
3. Choose method tile `nutrition.method_barcode`.
4. Scan barcode.
5. Expect:
   - selection haptic on detection
   - `GET /api/foods/barcode/{code}` is called
6. When not found, expect “Barcode not found” empty state:
   - `nutrition.barcode_not_found_title`
   - `nutrition.barcode_not_found_helper`
   - CTAs present (and tappable):  
     `nutrition.barcode_not_found_search`, `nutrition.barcode_not_found_photo`, `nutrition.barcode_not_found_manual`, `nutrition.barcode_not_found_scan_label`
7. Tap CTA `nutrition.barcode_not_found_scan_label`.
8. On “Scan Nutrition Label” capture screen, verify:
   - title `nutrition.label_scan_title`
   - helper `nutrition.label_scan_helper`
   - primary action `nutrition.label_scan_primary`
   - optional secondary `nutrition.label_scan_secondary`
   - clear “photo 1 required / photo 2 optional” guidance (UX requirement)
9. Capture label photos:
   - Photo 1: nutrition table in focus
   - Photo 2: front pack (optional)
10. App calls `POST /functions/v1/analyze-food-label` (analysis-only).
11. Expect loading state:
   - uses `loading.food_title` but label-specific helper is allowed (“Reading label…”)
12. On response, route to “Review Product” screen:
   - title `nutrition.product_review_title`
   - helper `nutrition.product_review_helper`
   - fields editable: name, brand, serving_size_g (optional), per-100g kcal/P/F/C
   - warnings list visible if present
   - source badge shows “Community (Label scan)” (design-system source badge spec)
13. On Review Product:
   - Edit at least one field (e.g., brand capitalization) and confirm edits persist in UI.
14. Tap `nutrition.product_save_primary`.
15. Expect server call:
   - `POST /api/foods/barcode/{code}/create` with provider `lifeos_label_ocr`.
16. After save, expect routing back to product sheet for that barcode:
   - now `GET /api/foods/barcode/{code}` returns found (type `catalog`, provider `lifeos_label_ocr`).
17. In product sheet:
   - per serving and per 100g are visible
   - grams/serving toggle works
   - portion stepper updates macros live
18. Tap CTA `nutrition.add_to_meal` and then “Save Meal”.
19. Expect:
   - `POST /api/food/log` creates meal with `input_method='barcode'` or `manual` depending on implementation; must be consistent across app.
   - meal appears in Nutrition day view under correct meal type and time.

**Expected data integrity (must verify via API logs / DB inspection during dev)**
1. `food_catalog_items` has barcode row with `provider='lifeos_label_ocr'`.
2. Per-100g values are canonical and non-negative.
3. Label photos are not stored (privacy default).

### A2) Repeatability (Online): Scan Same Barcode Again → Instant Product

**Goal:** Subsequent barcode scans are “instant”.

**Steps**
1. Return to barcode scanner.
2. Scan the same barcode again.
3. Expect `GET /api/foods/barcode/{code}` to return found without needing OCR.
4. Expect product source badge shows the same source.
5. Log again; ensure it takes < 10 seconds from scan to saved meal.

### A3) Deterministic Lookup Precedence (User Override Wins)

**Goal:** user correction always wins over community/provider data.

**Setup**
1. Ensure barcode exists in `food_catalog_items` (from A1) OR from Open Food Facts.

**Steps**
1. In product sheet, tap CTA `nutrition.product_fix_macros` (“Fix macros”).
2. Enter corrected per-100g macros (make a visible change).
3. Save as user-specific override (expected: `POST /api/foods/custom` with `barcode` set OR dedicated override UX that writes `user_foods`).
4. Scan the barcode again.
5. Expect `GET /api/foods/barcode/{code}` returns **type `custom`** with tag `user_override`.
6. Confirm UI badge shows “You”.

### A4) Barcode Found (Control Path): Open Food Facts Product

**Goal:** verify the “normal” barcode flow.

**Steps**
1. Scan a known OFF barcode.
2. Expect product sheet opens without “not found”.
3. Verify source badge shows “Open Food Facts”.
4. Portion adjust works, meal saves.

### A5) Error Handling: Invalid Barcode

**Steps**
1. Use manual “Type code” and input invalid string (letters, too short, too long).
2. Expect `FoodDBError.invalidBarcode` UX:
   - non-blocking message
   - action to rescan (`FallbackBehavior.rescanBarcode`)

### A6) Error Handling: Provider Unavailable / Rate Limited

**Steps**
1. Simulate provider outage or 429 while scanning a barcode that is not cached.
2. Expect:
   - warn banner or modal (non-panic)
   - fallback behavior `useCachedCatalogOnly`
   - still provides alternative logging: Search/Photo/Manual/Scan label

### A7) Error Handling: Label OCR Failures (CIS-critical)

Test each error with real capture conditions.

**Cases**
1. Blurry/glare photo → `FoodDBError.labelImageBlurry`:
   - message suggests lighting/glare fix
   - fallback: retake photo
2. No nutrition table in image → `FoodDBError.labelNoNutritionTable`:
   - message instructs to capture nutrition panel only
   - fallback: retake photo
3. Unsupported language (rare) → `FoodDBError.labelUnsupportedLanguage`:
   - fallback: manual entry
4. kcal vs macros mismatch beyond tolerance → `FoodDBError.labelMacroMismatch`:
   - review screen shows warning
   - save allowed after review (review is the gate, not a blocker)
5. Serving size missing but per-100g exists:
   - save allowed; serving remains null
6. Only per-serving values and serving grams missing:
   - must force user to enter grams or mark low confidence
   - do not silently “invent” per-100g

### A8) Offline Path: Barcode Miss While Offline

**Goal:** barcode miss never blocks logging even offline.

**Steps**
1. Turn on Airplane mode.
2. Scan barcode.
3. Expect:
   - cached lookup only
   - if not cached: “Barcode not found” state appears
4. Tap “Scan label”.
5. Expect:
   - if OCR requires network, app offers “Create custom product” (manual macros entry)
   - saving creates `user_foods` with `barcode` set (personal override)
6. Scan barcode again offline:
   - expect product found from user override
7. Log meal offline:
   - expect local save + sync queue
8. Turn network on:
   - expect sync without duplicates

### A9) Privacy / Retention Assertions (Critical)

**Checks**
1. Label photos are not written to storage/DB by default (ephemeral).
2. Only structured nutrition values persist after Review Product.
3. Data Sources screen exists in Settings and shows OFF attribution.

### A10) Accessibility Assertions

**Checks**
1. All CTAs are >= 44×44pt.
2. Scanner screen has accessible fallback “Type code”.
3. “Barcode not found” state reads well in VoiceOver and exposes all CTAs.
4. Source badge is announced as one element: “Data source: …”.

### A11) Performance / SLO Assertions

**Targets (from API SLOs)**
1. `GET /api/foods/barcode/{code}` p95 <= 2s.
2. `POST /functions/v1/analyze-food-label` p95 <= 4s (soft, network dependent).
3. After first save, repeat scan should feel instant (no perceivable spinner).

---

## 2) E2E Checklist B — Meal Prep (Batch) → Create → Log Portion → Calendar + Undo + Edits

### B0) Preconditions
1. App locale `ru_RU` or `en_US` (either is fine; CIS is preferred).
2. Nutrition day view is open.
3. User has at least one searchable ingredient (catalog or custom).

### B1) Happy Path (Precise): Create Batch With Ingredients

**Goal:** Create a batch with deterministic macros and yield.

**Steps**
1. Open Log Meal method picker.
2. Tap `nutrition.method_recipe` (Recipe / Meal Prep).
3. Land on Meal Prep library screen:
   - title `nutrition.batch_library_title`
   - CTA `nutrition.batch_library_create_primary`
4. Tap “Create batch”.
5. Mode picker shows two tiles:
   - `nutrition.batch_mode_precise` (recommended)
   - `nutrition.batch_mode_quick`
6. Choose “Precise”.
7. Enter required fields:
   - name
   - cooked date (default today)
   - total cooked weight grams (required)
   - portions (optional, default 1)
8. Add ingredient (reuses food search):
   - search ingredient
   - set ingredient weight in grams
   - ingredient totals are computed and shown
9. Add 2–3 ingredients.
10. Confirm totals preview updates live:
   - total batch macros
   - per 100g (canonical)
   - per portion (if portions > 1)
11. Tap “Save batch”.
12. Expect call: `POST /api/nutrition/batches`.
13. Return to library; new batch appears with remaining weight == total weight.

**Data assertions**
1. `batch_recipes.total_*` equals sum of ingredient totals (server authoritative).
2. `batch_recipe_ingredients` rows exist and retain brand/barcode/catalog refs when present.

### B2) Log Portion: Batch → Meal

**Goal:** Log portion in < 10 seconds and decrement remaining weight deterministically.

**Steps**
1. From batch library, open batch detail.
2. Tap CTA `nutrition.batch_log_action`.
3. Log portion sheet opens:
   - date defaults to currently selected diary date
   - time defaults now
   - meal_type inferred from time
4. Enter portion weight grams.
5. Verify portion macro preview changes live.
6. Tap `nutrition.batch_log_primary` (“Add to meal”).
7. Expect call: `POST /api/nutrition/batches/{batch_id}/log`.
8. Confirm:
   - new meal appears in Nutrition day view at correct time/meal type
   - batch detail shows reduced remaining weight

**Critical non-drift assertion**
1. The created meal contains one `food_item` that references `batch_recipe_id` and snapshots macros.

### B3) Calendar Integration (Nutrition Month Grid / Week Strip)

**Goal:** day status updates correctly.

**Steps**
1. Open month grid on Nutrition.
2. Navigate to day where portion was logged.
3. Expect day cell indicates logs exist (status icon).
4. Tap the day; day view lists the meal containing the batch portion.

### B4) Undo / Soft Delete Impacts Remaining (Drift-Proof)

**Goal:** deleting a meal restores remaining grams because consumption is derived from non-deleted meals.

**Steps**
1. Open the meal detail for the batch portion.
2. Delete the meal:
   - call `DELETE /api/food/log/{id}` (soft delete)
3. Return to batch detail:
   - remaining weight must increase back (derived recomputation)
4. Undo deletion:
   - call `POST /api/food/log/{id}/undo`
5. Remaining weight decreases again accordingly.

### B5) Edit Batch After Logging (No Retroactive Drift)

**Goal:** editing batch affects future logs, not past.

**Steps**
1. Ensure at least one meal already logged from batch.
2. Edit batch (PATCH) changing total macros or description (depending on allowed fields).
3. Log a new portion after edit.
4. Expect:
   - previously logged meal items keep original snapped macros
   - new meal reflects updated per‑100g computations

### B6) Quick Mode (Photo Draft): Must Require Review

**Goal:** AI draft never saves silently.

**Steps**
1. Create batch → choose “Quick (Photo)”.
2. Enter total cooked weight (required) and optional portions.
3. Capture a photo and submit.
4. Expect call: `POST /api/nutrition/batches/quick`.
5. App routes to Review Batch:
   - shows confidence and warnings
   - edit ingredient list is possible
6. Save final batch only via `POST /api/nutrition/batches` (precise endpoint).

### B7) Duplicate (“Cook again”) and Archive

**Steps**
1. From batch detail, tap “Cook again”:
   - call `POST /api/nutrition/batches/{batch_id}/duplicate`
2. Verify new batch:
   - new id
   - remaining == total
   - ingredients cloned
3. Archive a batch:
   - either via `PATCH /api/nutrition/batches/{batch_id}` setting `archived=true` (implementation detail)
4. Verify:
   - active list excludes archived
   - archived list shows it

### B8) Error Handling Cases

**Cases**
1. Portion > remaining:
   - block save with clear message
2. Ingredient missing macros:
   - block batch save until fixed
3. Quick mode analysis unavailable:
   - offer switch to precise
4. Offline:
   - creating batch queues a pending mutation
   - logging portion queues and does not duplicate on reconnect

### B9) Accessibility Assertions

**Checks**
1. Portion grams input is accessible and uses proper numeric keypad.
2. Remaining weight is readable and not color-only.
3. Batch library cards are navigable via VoiceOver as single coherent elements.

### B10) Performance / SLO Assertions

**Targets (from API SLOs)**
1. `GET /api/nutrition/batches` p95 <= 700ms.
2. `POST /api/nutrition/batches` p95 <= 1.2s.
3. Portion log p95 <= 1s.

---

## 3) E2E Checklist C — HealthKit Sync + Travel/Timezone Correctness

### C0) Preconditions
1. iPhone with HealthKit enabled.
2. Apple Watch paired (recommended for sleep + HRV accuracy).
3. User has granted HealthKit permissions for:
   - Sleep, HRV, Resting HR, Workouts, Active Energy, Steps.
4. Test data exists for multiple days including:
   - Sleep across midnight
   - Workout near midnight (23:30 local)
   - Day with no data (control)

### C1) Initial Connect + Backfill

**Goal:** On first connect, last 14 days are backfilled and aggregated correctly.

**Steps**
1. In onboarding (or Settings), connect HealthKit.
2. Expect permissions screen with minimum required types.
3. After allow, app triggers backfill:
   - 14 days sleep, HRV, RHR, workouts.
4. Verify:
   - `physiological_states` rows exist for each day.
   - Each row has `data_completeness` and `confidence_score`.
   - Recovery score is calculated via `calculate-recovery-score`.

### C2) Daily Aggregation Rules (Correctness)

**Goal:** Aggregates follow spec for sleep window + HRV/RHR selection.

**Checks**
1. Sleep duration uses main sleep window, not naps.
2. HRV:
   - Prefer samples during main sleep window.
   - If none, fallback to last 24h median.
3. RHR:
   - Daily average/median.
4. Sleep stages:
   - If available, show percent + minutes.
   - If not available, hide stage breakdown but still show total sleep.

### C3) Background Sync + Anchored Queries

**Goal:** incremental sync works without duplicates.

**Steps**
1. Run app background refresh (morning window).
2. Simulate new HealthKit data added after last sync.
3. Expect:
   - only new data imported (anchored query).
   - no duplicate `workout_sessions` with same `import_source_id`.

### C4) Travel / Timezone Correctness

**Goal:** diaries group by local day and never “shift” after travel.

**Scenario**
1. Log a meal and workout on **Day 1** at 23:30 in `Europe/Moscow` (UTC+3).
2. Change device timezone to `Asia/Almaty` (UTC+5) the next morning.
3. Open diaries for Day 1.

**Expect**
1. Meal and workout remain on Day 1 (original local date).
2. Stored fields:
   - `logged_date` and `session_date` reflect the original local day.
   - `*_timezone` and `*_utc_offset_minutes` are preserved.
3. Displayed timestamps use the stored timezone/offset for that log.

### C5) DST Boundary (Edge Case)

**Goal:** DST does not shift log dates.

**Steps**
1. Simulate a day where DST changes (if applicable in locale).
2. Log an item around DST shift.
3. Verify:
   - `*_date` remains correct
   - time shown uses stored offset (not current offset)

### C6) Partial Permission / Missing Data

**Goal:** missing permissions degrade confidence, not break UX.

**Steps**
1. Revoke sleep stages permission, keep sleep duration.
2. Open Sleep detail.
3. Expect:
   - banner `sleep.partial_*`
   - stages section shows “Stages unavailable”
4. Recovery score still computed with reduced confidence.

### C7) Performance / SLO

**Targets**
1. `GET /api/recovery/latest` p95 <= 200ms.
2. `GET /api/recovery/daily` p95 <= 220ms.
3. Sync time for last 3 days <= 10s on normal network.

---

## 4) E2E Checklist D — Manual vs Imported Workout Conflict Resolution + Undo

### D0) Preconditions
1. HealthKit connected, workout imports enabled.
2. User logs manual strength session.
3. HealthKit imports a workout that overlaps in time with manual session.

### D1) Conflict Detection Trigger

**Goal:** the app detects overlap and prompts user.

**Steps**
1. Create manual workout from 18:00–19:00.
2. Ensure HealthKit import occurs for 18:10–18:55.
3. Open Training day view.
4. Expect:
   - Conflict modal `training.merge_*` is shown.
   - No silent deletion.

### D2) Merge (Recommended Path)

**Steps**
1. In modal, choose “Merge”.
2. Expected result:
   - Manual sets/reps remain.
   - Imported calories/HR/time are attached to the session.
   - Only one session is shown in diary.
3. Confirm:
   - `workout_sessions.source` remains `manual` (or explicit merged flag).
   - Imported metadata stored (e.g., `import_provider`, `import_source_id`).

### D3) Keep Manual

**Steps**
1. Choose “Keep Manual”.
2. Expect:
   - Manual session remains.
   - Imported session is soft-deleted (`deleted_at`, `deleted_reason='duplicate'`).
3. Verify undo is possible within 24h.

### D4) Keep Imported

**Steps**
1. Choose “Keep Imported”.
2. Expect:
   - Imported session remains.
   - Manual session soft-deleted with undo option.

### D5) Undo / Recovery

**Steps**
1. After any deletion, tap “Undo”.
2. Expect:
   - `POST /api/workouts/{session_id}/undo`
   - session restored to diary
3. If both sessions exist, conflict modal should appear again or show a resolution banner.

### D6) Edge Cases

**Cases**
1. Multiple overlapping imports with the same manual session:
   - Only one conflict modal shown at a time.
2. Overlap < 10 minutes:
   - No conflict unless heuristic says “same workout”.
3. Imported workout has no calories:
   - merge still allowed; missing metrics remain null.

### D7) Performance / SLO

**Targets**
1. `POST /api/workouts/log` p95 <= 900ms.
2. `GET /api/workouts/daily` p95 <= 400ms.
3. Conflict modal must appear within 1s after day view loads.

---

## 5) E2E Checklist E — Labs OCR (Async + Privacy + Duplicate Detection)

### E0) Preconditions
1. User is onboarded.
2. Labs import is accessible (Onboarding optional or Settings/Labs tab).
3. Have at least two lab reports for the same marker set (to test duplicates).

### E1) Happy Path (Cloud OCR Enabled)

**Goal:** capture → async OCR → review → save.

**Steps**
1. Open Labs scan screen.
2. Choose `labs.scan_primary` (capture) or `labs.scan_secondary` (PDF).
3. Capture a clear lab report.
4. Expect upload state → processing state:
   - uses `loading.ocr_title`
   - helper `labs.processing_helper`
5. App polls `GET /api/labs/scan/{scan_id}` until status `completed`.
6. Review screen:
   - title `labs.review_title`
   - helper `labs.review_helper`
   - table shows markers with original label + normalized label
   - low confidence markers are highlighted
7. Edit one marker value and unit, confirm edits persist.
8. Tap `labs.review_primary` to save.
9. Expect post-save confirmation:
   - `labs.saved_title`, `labs.saved_helper`

### E2) Local-Only Default (Privacy)

**Goal:** raw scans remain on-device by default.

**Steps**
1. Ensure “Store scans on this device only” is ON.
2. Capture a lab report.
3. Expect:
   - `storage_mode = local_only` in request.
   - If user opted out of cloud OCR, client stores raw locally and does not call OCR endpoint.
4. Verify:
   - no `original_image_url` is stored.
   - derived markers may sync only if user opts in.

### E3) Low Confidence Gate (Must Review)

**Steps**
1. Upload a low-quality scan (blurry or rotated).
2. Expect:
   - `labs.ocr_low_*` modal
   - save disabled until review is completed.

### E4) Duplicate Detection

**Goal:** avoid accidental duplicates when same-day labs are imported.

**Steps**
1. Import a lab report (first time).
2. Import another report within ±2 days with similar markers (>=60% overlap).
3. Expect duplicate sheet:
   - `labs.duplicate_title`, `labs.duplicate_helper`
   - options: keep both / replace / review differences
4. Choose each option in separate runs and verify:
   - Keep both: two entries exist
   - Replace: older entry marked replaced (soft delete if implemented) + undo option
   - Review: diff view appears before final choice

### E5) Error Handling

**Cases**
1. OCR processing fails:
   - show retry + “Upload PDF” fallback
2. Missing unit:
   - block save until unit selected
3. Unrecognized marker:
   - user selects from suggested list or marks as custom

### E6) Performance / SLO

**Targets**
1. OCR async completion p95 <= 30s.
2. `GET /api/labs/scan/{scan_id}` p95 <= 600ms.

---

## 6) E2E Checklist F — Supplements (Schedule + Adherence + Reminders)

### F0) Preconditions
1. User has at least one supplement in `user_supplements` with schedule.
2. Notification permission granted (for reminder checks).

### F1) Add Supplement + Schedule

**Steps**
1. Open Supplements screen → Add.
2. Choose supplement from quick picks or search.
3. Set timing (morning/with food/before bed).
4. Save.
5. Verify:
   - schedule appears in `GET /api/supplements/daily?date=...`.

### F2) One-Tap “Taken” Logging

**Steps**
1. On the daily schedule, tap `supplements.log_primary` (“Taken”).
2. Expect call: `POST /api/supplements/log`.
3. Verify:
   - taken status becomes true in schedule
   - adherence_today_percent updates

### F3) Late / Missed Supplements

**Goal:** logging after scheduled time still allowed.

**Steps**
1. Wait until after the scheduled time (or simulate).
2. Tap “Taken”.
3. Ensure:
   - log is recorded with actual timestamp
   - schedule row shows taken

### F4) Reminders

**Steps**
1. Ensure reminder time exists.
2. Verify push notifications trigger within allowed window.
3. Confirm no notifications during quiet hours.

### F5) Evidence/Timing Tips (Non-Medical)

**Steps**
1. Add two supplements with known interaction (e.g., Calcium + Iron).
2. Expect non-blocking “Timing Tip” banner (`supplements.warn_*`).
3. Confirm it suggests timing change, not dose changes.

### F6) Performance / SLO

**Targets**
1. `POST /api/supplements/log` p95 <= 700ms.
2. `GET /api/supplements/daily` p95 <= 700ms.

---

## 7) E2E Checklist G — Notifications + Control + Focus Control

### G0) Preconditions
1. User is signed in.
2. Settings → Notifications is available.

### G1) Notification Settings (Happy Path)
1. Open Settings → Notifications.
2. Toggle Morning Brief OFF → Save.
3. Verify `GET /api/settings/notifications` reflects the change.
4. Set Quiet Hours start/end → Save.
5. Verify server returns updated times.

### G2) Hard Cap Enforcement
1. Enable Positive + Nudges.
2. Ensure max total per day is 6.
3. Trigger simulated notification queue of 7 items.
4. Verify only 6 are scheduled; lowest priority is dropped.

### G3) Control Level — Guardian Permission
1. Set Control Level to Guardian.
2. If Focus Control permission is not granted:
3. Show banner `settings.control_permission_needed`.
4. Control level falls back to Protective.
5. If permission is granted:
6. Guardian stays active.
7. A time‑bound Focus rule is applied and is reversible.

### G4) Focus Control Revoked
1. Revoke Screen Time permission in system settings.
2. Open app → expect banner and control level fallback to Protective.
3. Verify no restrictions are applied.

### G5) Focus Control App Selection
1. Enter Guardian mode.
2. Complete app selection.
3. Verify selected app list is shown in Settings → Control.
4. Verify selected app list is stored locally only (no network call).

---

## 8) E2E Checklist H — Unified Daily Diary (V2)

### H0) Preconditions
1. User has at least 7 days of recovery/sleep data OR use seeded test data.
2. User has at least 1 meal log and 1 workout log in the past week.
3. Supplements schedule exists (at least 1 item).

### H1) Day View Loads in One Request
1. Open Diary (Unified) day view.
2. Verify a single call to `GET /api/diary/daily?date=...`.
3. Verify all sections render:
   - Recovery + Sleep summary
   - Meals list + Log Meal CTA
   - Training sessions + Start Workout CTA
   - Supplements schedule + Taken CTA
   - Labs section only when pending review or recent changes exist

### H2) Month Grid Loads in One Request
1. Tap month label to open month grid.
2. Verify one call to `GET /api/diary/calendar?from=...&to=...`.
3. Verify status icons match:
   - complete → checkmark.circle
   - needs_review → questionmark.circle
   - incomplete → circle
   - no_data → no icon

### H3) Needs Review Propagates
1. Create a low-confidence meal (ai_confidence < 0.65) without user correction.
2. Open unified day view for that date.
3. Verify `needs_review=true` and UI shows “needs review” badge.
4. Open month grid and verify that date status becomes `needs_review`.

### H4) Offline Mode
1. Enable Airplane mode.
2. Open unified day view.
3. Verify offline banner and cached values render.
4. Perform a log action (meal or supplement taken) → queued locally.
5. Disable Airplane mode and verify sync completes without duplicates.

---

## 9) E2E Checklist I — Sleep Diary (V2)

### I0) Preconditions
1. HealthKit Sleep permission is granted and user has at least 3 nights of data.
2. User is signed in.

### I1) Day View (Happy Path)
1. Open Sleep (from Home or Unified Diary → Sleep row → View history).
2. Verify one call to `GET /api/sleep/daily?date=...`.
3. Verify the screen shows:
   - sleep score
   - duration + bedtime/wake time (if available)
   - stages breakdown when `stages_available=true`
   - 7-day mini trend

### I2) Stages Unavailable
1. Use a device/user where stages are not available.
2. Verify UI hides breakdown and shows `sleep.stages_unavailable`.

### I3) Month Grid
1. Open month grid.
2. Verify one call to `GET /api/sleep/calendar?from=...&to=...`.
3. Verify icon rules:
   - good → checkmark.circle
   - low → arrow.down.right.circle
   - no_data → no icon

### I4) Missing Permission
1. Revoke Sleep permission.
2. Open Sleep.
3. Verify empty state `sleep.missing_*` + CTA `sleep.connect_primary`.

---

## 10) E2E Checklist J — watchOS Companion (V2)

### J0) Preconditions
1. Paired Apple Watch with watchOS 9+.
2. Life OS watch app installed, complication added to a watch face.
3. iPhone host is signed in and has recovery/sleep data.

### J1) Snapshot Sync (Host-driven)
1. On iPhone, trigger refresh and fetch `GET /api/watch/snapshot?date=...`.
2. Verify watch receives snapshot via WatchConnectivity (no direct backend calls on watch).
3. Verify Glance view reflects new recovery zone and shows `watch.last_updated`.

### J2) Complication → Glance
1. View complication on watch face.
2. Verify it shows recovery score + zone label (never color-only).
3. Tap complication → opens Glance view.

### J3) Low Confidence Safeguards
1. Force snapshot `confidence_score < 0.65`.
2. Verify Glance shows `global.estimate_badge`.
3. Verify any potentially harmful CTA routes via `global.open_on_iphone`.

### J4) One-Tap Actions (Reachable Phone)
1. Ensure at least one supplement is due soon in snapshot.
2. Tap `supplements.log_primary` on watch.
3. Verify iPhone performs `POST /api/supplements/log` and watch reflects updated state within 5 seconds.
4. If snapshot includes an unread insight action, tap `insights.acknowledge`.
5. Verify iPhone performs `POST /api/insights/{id}/acknowledge` and watch updates within 5 seconds.

### J5) Offline / Unreachable Phone
1. Disable Bluetooth or move watch out of range.
2. Open Glance view.
3. Verify cached snapshot is shown and actions are disabled.
4. Verify `global.open_on_iphone` is available as the safe fallback.

---

## K) GDPR + Consent

### K0) Preconditions
1. User has at least 14 days of data across food, workouts, supplements, labs, and insights.
2. Cloud storage enabled for scans where applicable.

### K1) GDPR Export (Full — Async)
1. Call `POST /api/account/export` to initiate export job.
2. Poll `GET /api/account/export/{id}` until `status=completed`.
3. Verify response includes required tables: users, food_logs, food_items, workout_sessions, user_supplements, supplement_logs, medical_scans, health_measurements, insights, recommendations, experiments, experiment_measurements, wellness_checks, hydration_logs, body_composition, user_food_favorites.
4. Verify no raw HealthKit samples are present (aggregates only).

### K2) Account Deletion (Scheduled + Immediate)
1. Call `POST /api/account/delete` with `immediate=false`.
2. Verify `users.deletion_scheduled_at` set and confirmation email sent.
3. Call `POST /api/account/delete` with `immediate=true`.
4. Verify vector store entries deleted, SQL rows removed, auth.users removed.

### K3) Consent Management
1. Toggle cloud storage for labs to OFF.
2. Verify scans are stored local-only (`storage_mode=local_only`, no `original_image_url`).
3. Toggle ON and verify uploads go through `/api/media/upload` with retention.

### K4) Retention Policy Enforcement
1. Seed food photos + lab scans older than 90 days.
2. Run retention job (server task) or simulate scheduled enforcement.
3. Verify old media removed from storage and references nulled (`food_logs.image_url`, `medical_scans.original_image_url`).
4. Verify derived nutrition/lab data remains intact.

### K5) Data Anonymization / k‑Anonymity (Analytics)
1. Trigger analytics export pipeline for aggregate metrics.
2. Verify no user-level identifiers are present.
3. Verify k‑anonymity threshold is enforced (e.g., cohorts < k are suppressed or bucketed).

### K6) Breach Response Procedure (Tabletop)

---

## L) Onboarding (Offline Fallback)

### L0) Preconditions
1. Fresh install, no existing account.
2. Device is in airplane mode (no network).

### L1) Offline Profile Creation
1. Start onboarding in airplane mode.
2. Complete profile step (name, goal, age_range).
3. Verify profile saved locally (`onboarding_state.step = profile_complete`).
4. Verify `notification_settings` and `privacy_settings` created locally with defaults.
5. Verify HealthKit permission prompt appears even offline.

### L2) Backfill Resume on Reconnect
1. Enable network.
2. Verify `POST /api/onboarding/profile` fires automatically.
3. Verify `POST /api/onboarding/health-backfill` fires after profile sync.
4. Verify `user_baselines` populated within 10 seconds.
5. Verify first recovery score appears on home screen.

### L3) Interrupted Onboarding Resume
1. Start onboarding, complete profile, force-quit app.
2. Relaunch app.
3. Verify app resumes from last completed step (reads `onboarding_state`).
4. Verify no duplicate profile creation (`ON CONFLICT DO NOTHING`).

### L4) Onboarding with Denied HealthKit
1. Start onboarding, deny HealthKit permission.
2. Verify `error.onboarding_healthkit_denied_title` copy shown.
3. Verify user can proceed without health data (cold-start fallback).
4. Verify recovery score shows "Insufficient data" state.
1. Simulate breach alert in incident system.
2. Verify runbook steps: isolate system, revoke tokens, notify users, log incident.
3. Confirm audit log entry created and post‑incident review checklist completed.

---

## L) Insights + Experiments

### L0) Preconditions
1. Seed at least 7 days of data to enable insights.

### L1) Insights List + Detail
1. Open Insights list.
2. Verify unread indicators and confidence badges.
3. Open detail, tap `insights.acknowledge`, verify POST is sent.
4. Tap `insights.dismiss`, verify item removed.

### L2) Experiments Flow + Results
1. Start experiment from insight.
2. Log daily measurements for baseline + intervention.
3. Complete experiment and open results.
4. Verify summary + effect size + compliance shown.

---

## M) Offline Sync Resilience

### M0) Preconditions
1. Disable network (Airplane mode).
2. Ensure Outbox is enabled with max retries configured.

### M1) Dead‑Letter Handling
1. Create an offline log with intentionally invalid payload (e.g., missing required field).
2. Re‑enable network and let sync retries exhaust.
3. Verify item moves to dead‑letter queue and user sees “Fix sync” screen/banner.
4. Fix payload and retry; verify item exits dead‑letter and sync succeeds.

### M2) Conflict Resolution (Offline vs Server)
1. Edit the same meal/workout on two devices while one is offline.
2. Sync offline device after server update.
3. Verify server‑authoritative merge with “Review changes” UI when needed.

---

## N) Sleep Diary Manual Entry (V2)

### N0) Preconditions
1. HealthKit not connected or sleep permissions denied.
2. Sleep diary enabled.

### N1) Manual Entry Flow
1. Open Sleep day view and tap “Add sleep”.
2. Enter bedtime + wake time + optional notes.
3. Save; verify `POST /api/sleep/log` and entry appears in day view.
4. Open month grid; verify status icon updates for that date.

---

## O) Training Plan AI Generation + Management

### O0) Preconditions
1. User has training profile fields completed.

### O1) Plan Generation
1. Start plan creation in Training tab.
2. Submit goals + schedule; verify `POST /api/training/plan/generate`.
3. Verify plan_id returned and plan appears in calendar.

### O2) Plan Detail + Status Controls
1. Open plan detail; verify `GET /api/training/plan/{id}`.
2. Pause plan; verify `PATCH /api/training/plan/{id}` status=paused.
3. Resume/Archive plan; verify status reflects in UI and calendar.

---

## P) Templates V2 Management

### P0) Preconditions
1. Create at least one meal template from Review Meal.

### P1) Manage Templates
1. Open Template Library (3.15A).
2. Edit name/macros; verify `PATCH /api/nutrition/templates/{id}`.
3. Archive template; verify it disappears from Quick Add list.

---

## Q) Accessibility Validation (Core)

### Q1) watchOS Accessibility
1. Enable VoiceOver on watch.
2. Open Glance view; verify labels read recovery score + zone + CTA.
3. Verify contrast on complication and glance (no color‑only meaning).

### Q2) Labs OCR Accessibility
1. Run Labs OCR flow with VoiceOver on.
2. Verify capture instructions and Review fields are readable and focusable.
3. Ensure error states are announced and actionable.

### Q3) Color Palette Validation
1. Validate warm neutral surfaces against WCAG AA text contrast.
2. Validate Okabe‑Ito semantic colors in charts and status pills.
3. Confirm status meaning is never color‑only (icons + labels required).

---

## R) Photo Meal Logging (P0 — Happy Path)

### R1) Photo → AI Parse → Review → Save

1. Open Nutrition tab → tap "Log Meal" → select "From Photo."
2. Capture or choose a photo of a meal.
3. Verify loading state with skeleton/progress indicator.
4. AI returns parsed food items with confidence scores.
5. **Low-confidence gate:** If any item has `confidence < 0.65`, verify the review banner is shown and "Save" requires explicit confirmation.
6. Review parsed items — verify each shows: name, estimated portion, calories, protein, carbs, fat.
7. Edit any incorrect item (tap to modify name, portion, or macros).
8. Add a missing item manually if needed.
9. Tap "Save."
10. Verify the meal appears in the Diary with correct `logged_date` in user's timezone.
11. Verify outbox event is created with `Idempotency-Key`.
12. **Offline variant:** Repeat steps 1-10 in airplane mode → verify local save succeeds → go online → verify sync.

**Pass criteria:** Meal saved with all items; low-confidence items required review before save; offline save + sync works.

---

## S) Voice Meal Logging (P0 — Happy Path)

### S1) Voice → AI Parse → Review → Save

1. Open Nutrition tab → tap "Log Meal" → select "By Voice."
2. Speak a meal description (e.g., "I had a chicken breast with rice and broccoli for lunch").
3. Verify speech-to-text transcription appears for confirmation.
4. AI parses the transcription into food items with confidence scores.
5. **Low-confidence gate:** If any item has `confidence < 0.65`, verify review banner and explicit confirmation required.
6. Review parsed items — verify each shows: name, estimated portion, calories, protein, carbs, fat.
7. Edit or add items as needed.
8. Tap "Save."
9. Verify the meal appears in the Diary with correct `logged_date`.
10. Verify outbox event is created.

**Pass criteria:** Voice input correctly parsed; review gate enforced; meal saved accurately.

---

## T) Onboarding Flow (P0 — Happy Path)

### T1) Complete Onboarding

1. Fresh install → app launches to Welcome screen.
2. Tap "Get Started."
3. **Step 1 — Profile basics:** Enter name, date of birth, sex at birth (skippable). Tap Next.
4. **Step 2 — Goals:** Select at least one goal from the list. Tap Next.
5. **Step 3 — Connect Apple Health:** Tap "Connect Apple Health" → iOS permission dialog appears → grant permissions → verify HealthKit data sync begins.
   - **Variant: Deny permissions** → verify app continues without HealthKit, shows graceful empty state for health data.
6. **Step 4 — Notification preferences:** Configure notification toggles (positive reinforcement, gentle nudges, critical alerts). Set quiet hours. Tap Next.
7. **Step 5 — Control model:** Select advisory/protective/guardian level.
   - If Guardian selected, verify FamilyControls permission is requested.
8. **Step 6 — Supplements (optional):** Add current supplements or skip.
9. Onboarding completes → user lands on Diary (Today) screen.
10. Verify user profile saved with all entered data.
11. Verify `user_settings` record created with selected control_level and notification prefs.

**Pass criteria:** All steps completable; permissions handled gracefully; profile + settings persisted.

### T2) Onboarding — Minimal Path (Skip Everything)

1. Fresh install → Welcome → "Get Started."
2. Enter only required fields (name), skip sex at birth.
3. Skip goals (if allowed) or select one.
4. Deny HealthKit.
5. Accept default notifications.
6. Accept default control model (Advisory).
7. Skip supplements.
8. Verify onboarding completes and Diary shows with empty states.

**Pass criteria:** App functional with minimal input; no crashes; empty states shown correctly.

---

## U) Auth Bootstrap (P0)

### U1) Sign Up → First Sync

1. Open app → tap "Create Account."
2. Enter email + password (or Apple Sign-In).
3. Verify account created on Supabase Auth.
4. Verify JWT stored securely in Keychain.
5. Verify initial pull-sync completes (empty tables, no errors).
6. Verify `X-Device-Id` is generated and stored in Keychain.
7. App navigates to onboarding flow.

**Pass criteria:** Auth token stored; device ID persisted; initial sync successful.

### U2) Sign In → Resume Session

1. Sign out → sign back in with same credentials.
2. Verify JWT refreshed and stored.
3. Verify pull-sync resumes from last `updated_at` watermarks.
4. Verify all previously logged data appears in Diary.
5. Verify outbox replays any pending events from previous session.

**Pass criteria:** Session restored; data intact; pending outbox events replayed.

### U3) Token Expiry → Silent Refresh

1. Simulate JWT expiry (or wait for expiry).
2. Perform any action that triggers an API call.
3. Verify token is silently refreshed via Supabase Auth refresh token.
4. Verify the API call succeeds after refresh.
5. Verify no user-visible error or interruption.

**Pass criteria:** Token refreshed transparently; no user disruption.

---

## V) Performance SLOs

### V1) Diary Day Load

1. With 30+ days of data logged, navigate to Diary (Today).
2. Measure time from tap to full content render.
3. **SLO: < 500ms** from local cache, **< 2s** cold load from server.

### V2) Sleep Day Load

1. With 14+ nights of sleep data, navigate to Sleep day view.
2. Measure time from tap to full content render.
3. **SLO: < 500ms** from local cache, **< 2s** cold load from server.

### V3) Meal Photo Parse

1. Log a meal from photo.
2. Measure time from photo submission to parsed results displayed.
3. **SLO: < 5s** (AI round-trip via Edge Function).

### V4) Outbox Replay

1. Log 10 items offline (mix of meals, workouts, supplements).
2. Go online.
3. Measure time for all 10 outbox events to replay successfully.
4. **SLO: All 10 replayed within 30s** (sequential, with backoff).
