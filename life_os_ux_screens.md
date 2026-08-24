# LIFE OS — UX Screen Specifications

**Version:** 0.12
**Date:** February 16, 2026
**Purpose:** Implementation-ready UX specs for onboarding, nutrition/training/supplements diaries + fast logging flows, unified daily diary (V2), sleep surfaces (V2), insights/experiments, notifications/control, labs OCR import, watchOS companion (V2), account upgrade, and offline photo queue. Aligns with PRD v7.13, Design System v2.24, API Spec v2.3, HealthKit Spec v1.2, Copy Catalog v1.14, Invariants v0.5, and watchOS Spec v0.3.

---

## 0) Global UX Principles (Applied Here)

- Value before friction. Ask for permissions only after the user understands the benefit.
- Max 6 **required** onboarding steps. Extra setup is **optional**.
- One primary action per screen.
- Never more than 2 taps to any action.
- Touch targets ≥ 44×44pt, 8pt grid.
- AI data always shows confidence; low confidence forces a quick review.
- No guilt language. Every skip is safe and reversible.
- Copy must map to `life_os_copy_catalog.md`.

---

## 1) User Journey (New User, First 2 Minutes)

**Success definition:** user feels “calm, minimal, warm”, understands what Life OS does, and gets a first useful insight.

1. Step 1: Value proposition (no permission, no forms)
2. Step 2: Demo of food photo analysis (instant gratification)
3. Step 3: HealthKit permission (with strong privacy assurance, skippable)
4. Step 4: Baseline profile (short form) + optional setup (supplements/labs)
5. Step 5: First insight (real if data exists, demo fallback if not)
6. Step 6: Notifications ask (after value)
7. Land on Home with a single “next best action” card + central Log

---

## 2) Onboarding (6 Required Steps + Optional Setup)

### 2.0 Auth (Silent by Default)

To keep onboarding friction low while still enabling cloud-backed features, the client should:
- Sign in anonymously on first launch (no UI).
- Create the `users` row keyed by `auth_id`.
- Let the user upgrade/link identity later (Apple/email) without data loss.

This avoids forcing an account wall before the user sees value.

### 2.0A Auth Screens (Link/Sign-In)

When the user chooses to link identity (Settings or post-onboarding):

**Screens:**
1. **Auth Welcome**
   - Title: `auth.welcome_title`
   - Helper: `auth.welcome_helper`
   - CTAs: `auth.continue_apple`, `auth.continue_email`
2. **Email OTP**
   - Inline email entry + code input
   - Errors: `auth.error_invalid_email`, `auth.error_wrong_code`
   - CTA: `auth.sign_in`

**Rules:**
- Email auth uses OTP/magic link only (no passwords).
- Account linking preserves all existing anonymous data.

### 2.1 Progress Indicator (Required on all onboarding screens)

- Top: horizontal bar + “Step X of 6”
- Under bar: step labels (hide on small screens)
- Completed: ✓, Current: ●, Future: ○

**Accessibility:** step progress included in screen title label, e.g. “Step 3 of 6. Connect Apple Health.”

---

### Step 1 — Value Proposition

**Goal:** Answer “why should I care?” in 10 seconds.

**Primary CTA:** `global.continue`

**Layout blocks:**
- Hero title (Large Title)
- 1–2 lines helper
- 3 value bullets max
- Subtle trust footer

**Wireframe (concept)**
```text
┌──────────────────────────────────────────────┐
│ Step 1 of 6                                  │
│ ━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━         │
│                                              │
│ Your health, clarified                        │
│ Sleep, training, nutrition, supplements       │
│ — connected.                                  │
│                                              │
│ • Recovery in plain language                  │
│ • Fast logging (photo or manual)              │
│ • Sustainable training                         │
│                                              │
│ Private by default. You stay in control.      │
│                                              │
│ [ Continue ]                                  │
└──────────────────────────────────────────────┘
```

**Data:** none.

**Edge cases:** none.

---

### Step 2 — Quick Win (Food Photo Demo)

**Goal:** Show AI power without requiring camera or permissions.

**Primary CTA:** `global.continue`

**Behavior:**
- Auto-play the demo once: “Analyzing meal…” → results.
- Tapping toggles Before/After (photo vs identified items).
- No real capture here; it stays a demo to keep the flow fast.

**Wireframe (concept)**
```text
┌──────────────────────────────────────────────┐
│ Step 2 of 6                                  │
│ ━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━━━━━         │
│                                              │
│ See it in action                              │
│ Snap a meal photo — we’ll estimate macros     │
│ and let you edit.                             │
│                                              │
│ [ demo meal image ]                           │
│                                              │
│ Analyzing meal…                               │
│ (then)                                        │
│ Chicken salad • 520 kcal                      │
│ P 45g  F 18g  C 35g                            │
│                                              │
│ [ Continue ]                                  │
└──────────────────────────────────────────────┘
```

**Data:** none.

---

### Step 3 — Apple Health / HealthKit Permission

**Goal:** Ask for HealthKit access with privacy clarity.

**Primary CTA:** `onboarding.healthkit_primary` (copy id)

**Secondary CTA:** `global.skip`

**Permission ask strategy:**
- Ask only after the user saw value (Step 2).
- Make “Skip” safe and non-judgmental.
- If skipped: a gentle re-prompt later after another “aha” moment (PRD).

**V1 data scope (minimal):**
- Sleep duration + stages (core/light, deep, REM, awake — per `life_os_healthkit_spec.md` §4.1)
- HRV (SDNN from HealthKit → transformed to lnRMSSD for recovery algorithms; see `life_os_healthkit_spec.md` §4.2)
- Resting heart rate
- Workouts summary (HKWorkout)
- Active energy + steps

**Wireframe (concept)**
```text
┌──────────────────────────────────────────────┐
│ Step 3 of 6                                  │
│ ━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━━━━           │
│                                              │
│ Connect Apple Health                          │
│ Your data stays protected. Disconnect anytime │
│                                              │
│ What you’ll get:                              │
│ • Recovery Score (daily)                      │
│ • Sleep trend + gentle guidance               │
│ • Auto-detected workouts                       │
│                                              │
│ [ Connect HealthKit ]                         │
│ Skip for now (limited features)               │
└──────────────────────────────────────────────┘
```

**Data:** store permission status for onboarding completion.

**Error states:**
- “No health data found” uses existing error message mapping in `life_os_error_handling.md`.

---

### Step 4 — Baseline Profile + Optional Setup Entry

**Goal:** Collect the minimum baseline and preferences.

**Primary CTA:** `global.continue`

**Inputs (required):**
- Age range
- Height
- Weight
- Primary goal

**Inputs (optional in this step):**
- Sex at birth
- Diet preference
- Allergies/intolerances
- Training experience
- Days/week
- Session length
- Equipment access

**Optional setup actions (not required):**
- `onboarding.add_supplements`
- `onboarding.import_labs`

**Validation rules:**
- Height: 80–250 cm (or 2'8"–8'2")
- Weight: 25–350 kg (or 55–770 lb)
- Extreme values prompt: non-blocking confirm (“Does this look right?”)

**Wireframe (concept)**
```text
┌──────────────────────────────────────────────┐
│ Step 4 of 6                                  │
│ ━━━━━━━━━━━━━●━━━━━━━━━━━━━━━━━━━━           │
│                                              │
│ Set your baseline                             │
│ A few details help personalize targets.       │
│                                              │
│ Age range   [ 25–34 ▾ ]                       │
│ Height      [ 178 ] (cm ▾)                    │
│ Weight      [ 76  ] (kg ▾)                    │
│                                              │
│ Goal  [ Recovery ] [ Performance ]            │
│       [ Weight ]    [ General ]               │
│                                              │
│ Optional setup                                │
│ [ Add Supplements ]   [ Import Labs ]         │
│                                              │
│ [ Continue ]                                  │
└──────────────────────────────────────────────┘
```

**Data mapping:**
- `users.age_range`
- `users.height_cm`, `users.weight_kg`
- `users.primary_goal` (map from UI)
- `users.units`, `users.timezone`

---

### Optional Step 4A — Add Supplements (Optional)

**Goal:** quick stack setup in < 20 seconds.

**Primary CTA:** `supplements.add_primary`

**Secondary CTA:** `supplements.add_secondary`

**Fast path UI:**
- Quick picks (chips): Magnesium, Vitamin D3, Omega‑3, Creatine, Zinc, L‑Theanine
- For each: choose time preference (morning / with food / before bed / any)
- Dose field is optional and user-entered (never suggested)

**Data mapping:**
- `user_supplements` create rows (active = true)
- schedule lives in `scheduled_times` + `frequency` fields (per API spec)

**Safety:**
- Interactions show “Timing Tip” banner (`supplements.warn_*`).

---

### Optional Step 4B — Import Labs (Optional)

**Goal:** capture a lab report quickly without derailing onboarding.

**Primary CTA:** `labs.scan_primary`

**Secondary CTA:** `labs.scan_secondary`

**Key constraints (privacy):**
- Raw scans local-only by default; cloud sync is opt-in.
- Always require review before saving extracted values.

**Data mapping:**
- `medical_scans` create row, async OCR

---

### Step 5 — First Insight

**Goal:** deliver a “wow, that’s useful” moment.

**Primary CTA:** `global.continue`

**Layout blocks:**
- Recovery Score hero number + zone label
- 1-sentence recommendation
- “Why” (2–3 factors)
- “Next best action” single CTA (contextual)

**Fallback:** if HealthKit is not connected or no data → demo insight clearly labeled.

---

### Step 6 — Notifications (Delayed)

**Goal:** ask permission only after value delivery.

**Primary CTA:** `onboarding.notify_primary`

**Secondary CTA:** `global.skip`

**V1 notifications:**
- Morning brief
- Supplement reminders (if schedule exists)
- Lab review reminder (if scan is pending)

**Hard rule:** never notify during user sleep hours (PRD).

---

## 2.5) Home Screen (Core)

**Goal:** a single, calm screen that answers “what should I do next?” and provides one-tap logging.

**Data sources (priority):**
- `GET /api/recovery/latest`
- `GET /api/diary/daily?date=YYYY-MM-DD`
- `GET /api/insights?unread=true`
- `GET /api/experiments?status=active|completed`
- `GET /api/supplements/daily?date=YYYY-MM-DD`

**Next Best Action (source of truth):**
- Use the deterministic server algorithm in `life_os_api_specification.md` (Unified Diary → “Next Best Action”).
- If `confidence_score < 0.65` or `needs_review = true`, the Home CTA must route to review (never one‑tap log).

**Layout blocks (top to bottom):**
- Top bar: date + avatar (Settings)
- Recovery card: score, zone label, confidence badge
- Next Best Action card: single primary CTA
- Quick Log row: Food / Training / Supplement / Lab
- Context cards (1–2 rows max): Sleep, Training, Nutrition, Supplements
- Insights/Experiments preview (if present)

**States:**
- No data: show demo recovery card + CTA to connect HealthKit
- Low confidence: show banner + require review before one-tap actions
- Empty insights: show insights empty state copy IDs

**Primary CTA:** `home.next_best_action`

**Secondary CTAs:** `home.quick_log_food`, `home.quick_log_training`, `home.quick_log_supplement`, `home.quick_log_lab`

---

## 2.6) Out-of-Scope Surfaces (V2)

The following features have API support but **no V2 UI surface**. Do not implement screens for them in V2:
- Hydration logging
- Body composition
- Weekly strategy report
- Standalone recommendations feed

---

## 3) Calendar Diary — Nutrition

### 3.1 Default Navigation

- Entry: Nutrition tab.
- Default: **Day view** (today).
- Week strip visible at top.
- Month grid opens as a sheet when user taps “Feb 2026 ▾”.

### 3.2 Month Grid Status Rules (Nutrition)

We must not rely on color alone.

- No logs: empty cell (no dot)
- Logs exist: dot + icon
  - ✓ = within target range
  - ↗ = above target range
  - ↘ = below target range
  - ? = low-confidence day (many unverified AI estimates)

**Target range heuristic (initial):** 90–110% of calorie target OR protein target hit.

### 3.3 Day View Layout (Concept)

```text
┌──────────────────────────────────────────────┐
│ Nutrition           Feb 2026 ▾               │
│ [Mon Tue Wed Thu Fri Sat Sun] (week strip)   │
│                                              │
│ 1,420 / 1,850 kcal   77%                     │
│ Protein 95/120g  ━━━━━━━░░                   │
│ Carbs   140/180g ━━━━━━━░░                   │
│ Fat      45/60g  ━━━━━━━░░                   │
│                                              │
│ Breakfast  08:30  420 kcal  P25 F18 C45       │
│ Lunch      13:45  520 kcal  P45 F18 C35       │
│ Snack      17:10  180 kcal  P 5 F 7 C24       │
│                                              │
│ [ Log Meal ] (camera default)                 │
└──────────────────────────────────────────────┘
```

### 3.4 Core Interactions

- Tap day on week strip → load that day.
- Swipe left/right → move week.
- Tap month label → month grid sheet.
- Tap meal row → meal detail.
- Long press day (week strip or month grid) → quick add “Log Meal for {date}”.

### 3.5 Data Requirements

- Day: `GET /api/nutrition/daily?date=YYYY-MM-DD`
- Meal detail: `GET /api/food/log/{id}`
- Write: `POST /api/food/log`
- Edit: `PATCH /api/food/log/{id}`
- Delete + undo: `DELETE /api/food/log/{id}`, `POST /api/food/log/{id}/undo`
- Month/week overview (required addition): `GET /api/nutrition/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD`

### 3.6 States

- Loading: skeleton (warm theme). Copy: `loading.food_title` for photo analysis.
- Empty day: `nutrition.empty_*`.
- Offline: banner `error.offline_*`, queue log locally.
- Low confidence meal: modal `nutrition.ai_low_*` before saving.

### 3.7 Accessibility

- Calendar cell label must include date + totals + status icon meaning.
- VoiceOver rotor: Meals + Nutrients (already in design system examples).

---

### 3.8 Meal Detail / Review (Tap a Meal)

Two closely related screens share the same layout:
- **Meal Detail** (read-first)
- **Review Meal** (edit-first, used after photo/voice/AI)

**Header:**
- Meal name + meal type
- Time + context (home/restaurant/etc)
- Input method badge (photo/barcode/manual/voice)

**Body:**
- Totals card (kcal + P/F/C)
- Items list (each item has portion + macros)
- Confidence indicators per item and overall

**Primary CTA:** `nutrition.meal_save_primary` (Review Meal)
**Secondary CTA:** `nutrition.meal_save_secondary`

**Rule:** if overall confidence is low, require a quick review before allowing save.

---

### 3.9 Log Meal — Method Picker (Fast, 1 Tap)

**Goal:** let the user choose the fastest input method without cognitive load.

**Entry points:**
- Nutrition Day view CTA `nutrition.diary_log_primary`
- Unified Diary “Meals” CTA
- Long press on week strip/day cell → “Log Meal for {date}”

**Default behavior:**
- Opens a bottom sheet over the current day.
- Preselects:
  - `date`: currently selected diary date
  - `time`: now (editable)
  - `meal_type`: inferred from time (editable)
  - `method`: last used method (fallback: Photo)

**Sheet layout (top → bottom):**
- Title: “Log Meal”
- Row 1: Meal type chips: Breakfast / Lunch / Dinner / Snack
- Row 2: Time picker (compact) + “Now” quick button
- Row 3: Method tiles (large, tappable)
  - Photo (primary)
  - Barcode
  - Voice
  - Search
  - Quick Add
  - Recipe (batch)

**Hard UX rule:** selecting a method immediately transitions to that flow (no extra confirm).

**Accessibility:** tiles must announce “Method: Photo. Recommended.” etc.

---

### 3.10 Log Meal — Photo Capture (Real, Not Demo)

**Goal:** fastest path to a complete meal with review safety.

**Primary CTA:** `nutrition.photo_log_primary`  
**Secondary CTA:** `nutrition.photo_log_secondary`

**Camera screen requirements:**
- Warm neutral background around the live camera feed (avoid stark black).
- Overlay:
  - Plate framing guide
  - “Include the full plate” helper (`nutrition.photo_log_helper`)
  - Confidence tips button (“Lighting / angle” micro-help)
- Controls:
  - Capture
  - Flash toggle
  - Photo library picker
  - Back

**After capture:**
- Quick preview with crop/rotate.
- CTAs: Retake / Use Photo.

**AI analyze step:**
- Call `POST /functions/v1/analyze-food-image`.
- Show loading state (`loading.food_title`) with progress microcopy:
  - “Detecting foods…”
  - “Estimating portions…”
  - “Calculating macros…”

**Result routing:**
- Always land on **Review Meal** (see 3.8) with:
  - item list + per-item confidence
  - overall confidence
  - editable portions
- If confidence < 0.65:
  - show `nutrition.ai_low_*` modal (Review / Retake)
  - default action is Review (never block the user from saving after review)

**Offline behavior:**
- If offline, photo analysis is unavailable:
  - Show banner `error.offline_*`
  - Offer: “Enter Manually” and “Save Photo For Later” (optional V1.1)
  - Default recommended: enter manually (fast + reliable)

---

### 3.11 Log Meal — Barcode Scan

**Goal:** packaged food logging with near-zero friction.

**Entry:** Method picker → Barcode.

**Scanner screen:**
- Live camera with scanning frame.
- “Align barcode in frame” helper.
- Manual entry fallback link (“Type code”).

**On barcode detected:**
1. Immediate haptic (Selection)
2. Freeze frame 300ms (perceived stability)
3. Call `GET /api/foods/barcode/{code}`

**If found: Product sheet**
- Header: product name + brand
- Image thumbnail (if available)
- Macro preview per serving and per 100g
- Portion picker:
  - default: serving size if known
  - toggle: Serving / Grams
  - big stepper + numeric input
- “Add to favorites” heart toggle
- Primary CTA: `nutrition.add_to_meal`

After `nutrition.add_to_meal`:
- If meal has only this item → allow one-tap “Save Meal”
- If user wants multiple packaged items → remain in “Current Meal tray” mode (see 3.13)

**If not found:**
- Show calm empty state (no blame):
  - Title: “Barcode not found”
  - Helper: “You can still log it in seconds.”
  - CTAs (copy IDs):
    - `nutrition.barcode_not_found_search`
    - `nutrition.barcode_not_found_photo`
    - `nutrition.barcode_not_found_manual`
    - `nutrition.barcode_not_found_scan_label`
- Provide “Scan again”.

**Quality rules:**
- If provider returns incomplete nutrition (missing serving weight and no per-100g):
  - force Review Meal screen and ask for serving weight or grams
  - mark low confidence and require review before save

---

### 3.11A Scan Nutrition Label (Barcode Fallback — CIS Critical)

**Goal:** turn “barcode not found” into a 30–60s one-time setup, then future logs become instant.

**Entry points:**
- Barcode not found state → “Scan label”
- Product sheet → “Fix macros” (creates user override, optional)

**Copy IDs (required):**
- Label capture: `nutrition.label_scan_*`
- Review Product: `nutrition.product_review_*`, `nutrition.product_save_*`, `nutrition.product_fix_macros`

**Capture requirements:**
- Photo 1 (required): nutrition table (Б/Ж/У, ккал)
- Photo 2 (optional): front pack (helps name/brand)

**Flow:**
1. Capture label photo(s)
2. Call `POST /functions/v1/analyze-food-label`
3. Open **Review Product** screen:
   - editable name/brand
   - serving size grams (if present)
   - per-100g macros (canonical)
   - warnings + confidence
4. On Save:
   - Call `POST /api/foods/barcode/{code}/create` (provider=`lifeos_label_ocr`)
5. Return to product sheet (now found) → portion → “Add to Meal”

**Hard rules:**
- No DB write before user review confirmation.
- If confidence is low, still allow saving after review (the review is the safety gate).

**Offline behavior:**
- If offline:
  - allow “Create custom product” (manual macros entry)
  - store as `user_foods` with barcode for personal override
  - sync later is optional (catalog contribution not required)

---

### 3.12 Log Meal — Voice (Transcript → Parse → Clarify → Review)

**Goal:** fastest hands-free logging with minimal back-and-forth.

**Entry:** Method picker → Voice.

**Voice screen layout:**
- Title: “Tell us what you ate”
- Microcopy: “Short is fine. Example: ‘Two eggs and cappuccino’.”
- Big record button (tap to start/stop)
- Live transcript area (editable)
- Primary CTA: “Continue” (enabled when transcript has text)

**Pipeline:**
1. Record → local speech-to-text
2. User can edit transcript (single-line edits, no heavy editor)
3. Call `POST /functions/v1/parse-food-text`
4. If `needs_clarification = false` → open Review Meal (3.8)
5. If clarification needed:
   - show inline question card(s), max 2
   - user chooses an option or taps “I can weigh it” to enter grams
   - re-run parse with the added answers OR compute the missing weights locally
   - then open Review Meal (3.8)

**Hard rules:**
- Max 2 clarification questions per log.
- If still ambiguous, do not keep asking. Mark low confidence and route to Review Meal.

**Error handling:**
- Transcription failed: show “Type instead” CTA (routes to manual)
- Parse failed: route to Review Meal with empty items + “Add item” primary (includes Scan label option)

---

### 3.13 Log Meal — Manual Search + Current Meal Tray

**Goal:** power-user flow similar to FatSecret/MyFitnessPal: fast search + multi-item meal assembly.

**Entry:** Method picker → Search.

**Screen layout:**
- Search bar (sticky)
- Tabs (optional):
  - Recents
  - Favorites
  - Catalog
- Result rows:
  - name + brand
  - kcal per 100g + quick serving hint
  - optional barcode icon if available

**Current Meal tray (persistent bottom):**
- Shows:
  - item count
  - kcal total
  - primary CTA: “Review & Save”
- Tray expands to list selected items with remove/edit

**Interactions:**
- Typing runs `GET /api/foods/search?q=...`
- Tap result → Portion sheet (3.14) → “Add”
- “Create custom food” appears when:
  - no results OR user taps “+ Custom”
  - opens a small form (name + macros per 100g + optional default serving)
- If no results, show “Scan label” CTA (label‑scan fallback) before custom entry. Barcode is optional; if present, attach it on save.

**Save behavior:**
- “Review & Save” opens Review Meal (3.8) with all selected items.

---

### 3.14 Portion Editor (Shared Component)

**Goal:** make portion edits fast, unambiguous, and accessible.

**Inputs supported:**
- grams (always)
- serving (if serving_size_g known)
- pieces/cups/spoons (optional; only if catalog item defines it)

**Rules:**
- Always show grams as the canonical value.
- Macros update live while editing.
- Provide quick buttons: 50g, 100g, 150g (context-aware).

**Validation:**
- grams must be > 0
- cap to 2000g per single item (soft warning above 800g)

---

### 3.15 Quick Add (Templates + Repeat Last)

**Goal:** one-tap logging for routine meals.

**Sources:**
- “Repeat last meal” (same meal_type)
- Saved templates (“Protein breakfast”, “Work lunch”)

**Template creation (from Review Meal):**
- “Save as Template” secondary action (persists to `meal_templates`)
- Template stores items + default portions (user-editable)

**Quick Add screen:**
- list of templates sorted by recency
- tap → adds to current day with current time (editable) → Save

**Data requirements:**
- List: `GET /api/nutrition/templates`
- Log from template: `POST /api/nutrition/templates/{template_id}/log`
  - Server sets `food_logs.input_method = template`

### 3.15A Template Library (V2)

**Goal:** manage templates so “log in seconds” stays clean over months.

**Entry points:**
- Quick Add screen → “Manage templates”
- Nutrition → Settings → Templates (optional shortcut)
**Title:** `nutrition.templates_title`
**Manage CTA copy:** `nutrition.templates_manage`

**Primary CTA:** `nutrition.templates_create_primary`
**Secondary CTA:** `global.done`

**List row fields:**
- Name
- Macro chip (kcal + P/F/C)
- “Last used” (optional)

**Row actions:**
- Tap → preview and “Log now”
- Swipe actions:
  - `nutrition.templates_edit`
  - `nutrition.templates_archive`

**Template edit screen:**
- Rename
- Change default meal type
- Edit items/portions (opens existing portion editor)
- Archive/unarchive

**API:**
- `GET /api/nutrition/templates?limit=...`
- `GET /api/nutrition/templates/{id}`
- `PATCH /api/nutrition/templates/{id}`
- `POST /api/nutrition/templates/{id}/log`

---

### 3.16 Recipes / Meal Prep (Batch)

**Goal:** “Cook once → log portions in seconds” with weight-based tracking and review-first UX.

**Entry points:**
- Log Meal method picker → `nutrition.method_recipe`
- (Optional) Nutrition tab card “Meal Prep”
- Unified Diary → “Log Meal” → Recipe

**Copy IDs (required):** `nutrition.batch_*` (library/create/review/log/duplicate/archive)

#### 3.16.1 Batch Library (List)

**Primary CTA:** `nutrition.batch_library_create_primary`

**Layout blocks:**
- Header: `nutrition.batch_library_title`
- Segmented control (optional): Active / Archived
- List of batch cards (active):
  - name
  - cooked date (if present)
  - remaining weight + (optional) portions remaining
  - per-portion macro preview
  - quick action: “Log portion” (opens 3.22)

**Sorting:**
- Active: by `cooked_at DESC NULLS LAST`, then `updated_at DESC`
- Archived: by `updated_at DESC`

**Data requirements:**
- Active list: `GET /api/nutrition/batches?status=active&limit=20`
- Archived list: `GET /api/nutrition/batches?status=archived&limit=20`

**States:**
- Empty: `nutrition.batch_library_empty_*` with CTA to create
- Offline: show cached list; allow create (queued) and log (queued) with banner `error.offline_*`

---

#### 3.16.2 Create Batch — Mode Picker

**Goal:** choose accuracy vs speed without confusion.

**Screen copy:** `nutrition.batch_create_title`, `nutrition.batch_create_helper`

**Two tiles:**
- `nutrition.batch_mode_precise` (recommended): ingredient-driven accuracy
- `nutrition.batch_mode_quick` (fast): photo-based draft, review required

**Rule:** choosing a tile immediately starts that flow (no extra confirm).

---

#### 3.16.3 Create Batch — Precise Mode (Ingredients)

**Goal:** best accuracy, still fast.

**Required inputs:**
- Name (free text, default: “Meal prep”)
- Cooked date (default today)
- Total cooked weight in grams (required; measured after cooking)

**Optional inputs:**
- Portions (default 1; used for convenience per-portion display)
- Description / notes

**Ingredient list:**
- Each ingredient row shows:
  - name + brand
  - weight (grams)
  - macros total for the ingredient (kcal + P/F/C)
- “Add ingredient” opens ingredient picker (3.16.4)
- Removing an ingredient recalculates totals immediately

**Totals preview (sticky):**
- Total batch macros (kcal + P/F/C + fiber if known)
- Per 100g preview (canonical)
- Per portion preview (if portions > 1)

**Save behavior:**
- On Save, call `POST /api/nutrition/batches` (precise mode)
- Server is authoritative: recalculates totals from ingredient totals

**Offline behavior:**
- Save creates a local draft batch; queue sync.
- If a queued create fails later (validation/server conflict), keep local batch and show a non-blocking “Needs sync” badge.

---

#### 3.16.4 Add Ingredient (Shared Picker)

**Goal:** reuse the same best-in-class food selection flows.

**Entry:** “Add ingredient” from precise mode or from Review Batch.

**Picker options:**
- Search (default): uses `GET /api/foods/search?q=...`
- Barcode (optional): uses `GET /api/foods/barcode/{code}` (with label-scan fallback)
- Create custom ingredient: uses `POST /api/foods/custom`

**After selecting ingredient:**
- Portion editor opens in “grams” mode (ingredient weight in grams)
- The app computes ingredient totals from per-100g macros * weight

**Hard rule:** if ingredient macros are incomplete (missing kcal or P/F/C), user must fill or choose another item (don’t save silently).

---

#### 3.16.5 Create Batch — Quick Mode (Photo Draft)

**Goal:** fastest meal prep creation with mandatory review gate.

**Required before analyze:**
- Total cooked weight (grams)

**Flow:**
1. Enter Name + Cooked date + Total cooked weight (+ optional portions)
2. Capture photo (containers or the whole cooked batch)
3. Call `POST /api/nutrition/batches/quick`
4. Route to Review Batch (3.16.6) with `needs_review = true`

**Rules:**
- If confidence is low, show a “Needs review” banner and default focus to the ingredient list.
- Provide “Switch to Precise” link (keeps entered yield fields).

---

#### 3.16.6 Review Batch (Before Save)

**Goal:** turn AI drafts into user-trusted reusable batches.

**Primary CTA:** `nutrition.batch_save_primary`  
**Secondary CTA:** `nutrition.batch_save_secondary`

**Layout blocks:**
- Totals (batch), per 100g, per portion
- Ingredient list (editable)
- Warnings list (if any)
- Confidence badge (high/medium/low)

**Save behavior:**
- Review screen always saves via `POST /api/nutrition/batches` (precise endpoint) with final normalized totals.

---

#### 3.16.7 Batch Detail (Read-First + Quick Log)

**Entry:** Batch Library row tap.

**Layout blocks:**
- Remaining tracker:
  - remaining grams (primary)
  - portions remaining (secondary, if portions > 1)
- Per 100g and per portion macros
- Ingredient list (collapsible)
- Actions:
  - Log portion (3.16.8)
  - Cook again (duplicate)
  - Archive
  - Edit (PATCH metadata / yield corrections)

**Data requirements:**
- Detail: `GET /api/nutrition/batches/{batch_id}`
- Updates: `PATCH /api/nutrition/batches/{batch_id}`
- Duplicate: `POST /api/nutrition/batches/{batch_id}/duplicate`

---

#### 3.16.8 Log Portion (Batch → Meal)

**Goal:** log a portion to a meal in < 10 seconds.

**Entry:** Batch Detail → “Log portion”, or quick action in Batch Library.

**Sheet defaults (same rules as method picker):**
- date = currently selected diary date
- time = now
- meal_type inferred from time (editable)

**Inputs:**
- Portion weight (grams) — stepper + numeric input
- Preview: kcal + P/F/C for that portion
- Context (optional): home/restaurant/etc (default home)

**Primary CTA:** `nutrition.batch_log_primary`

**Save behavior:**
- Call `POST /api/nutrition/batches/{batch_id}/log`
- On success:
  - route to Meal Detail (3.8 read-first) OR return to Nutrition Day view with a confirmation toast

**Guards:**
- If portion > remaining grams: show warning and suggest max remaining (do not allow save).

**Offline behavior:**
- Create a local meal log immediately + decrement local remaining.
- Queue sync. If server rejects due to remaining mismatch, show a conflict banner on the batch (“Needs review”) and let user adjust.

## 4) Calendar Diary — Training

### 4.1 Default Navigation

- Entry: Training tab.
- Default: **Day view** (today).
- Week strip visible at top.
- Month grid opens as a sheet when user taps “Feb 2026 ▾”.

**TRIMP definition:** Training load score computed from duration + intensity (see `life_os_health_ecosystem_spec.md`). Display only; do not expose formula in UI.

### 4.2 Month Grid Status Rules (Training)

- Planned exists: hollow dot
- Completed exists: filled dot + ✓
- Planned missed: dot + ! (after plan date passes)
- Multiple sessions: show stacked dots (max 2) then “+N”

### 4.3 Day View Layout (Concept)

```text
┌──────────────────────────────────────────────┐
│ Training            Feb 2026 ▾               │
│ [Mon Tue Wed Thu Fri Sat Sun] (week strip)   │
│                                              │
│ Today summary                                 │
│ 65 min • TRIMP 55 • Load zone: Optimal        │
│                                              │
│ Planned                                       │
│ Upper A — Hypertrophy   18:00   Planned       │
│ [ Start ]                                     │
│                                              │
│ Logged                                        │
│ Strength • 65 min • Volume 1040   ✓           │
└──────────────────────────────────────────────┘
```

### 4.4 Core Interactions

- Tap day on week strip → load that day.
- Swipe left/right → move week.
- Tap month label → month grid sheet.
- Tap a session → detail.
- Filter chips: `training.diary_filter_planned`, `training.diary_filter_logged`.

### 4.5 Data Requirements

- Day: `GET /api/workouts/daily?date=YYYY-MM-DD`
- Session detail: `GET /api/workouts/{session_id}`
- Planned range (required addition): `GET /api/training/plan/sessions?from=YYYY-MM-DD&to=YYYY-MM-DD`
- Calendar overview (required addition): `GET /api/workouts/calendar?from=YYYY-MM-DD&to=YYYY-MM-DD`
- Write: `POST /api/workouts/log`
- Edit: `PATCH /api/workouts/{session_id}`
- Delete + undo: `DELETE /api/workouts/{session_id}`, `POST /api/workouts/{session_id}/undo`

### 4.6 Conflict Resolution (Wearable import vs manual)

**Default:** keep both drafts and require user choice if the app detects the “same workout”.

- Merge (recommended): keep manual sets; attach imported calories/HR/time if available.
- Keep manual: discard imported (soft delete with undo).
- Keep imported: discard manual (soft delete with undo).

Copy IDs: `training.merge_*`.

### 4.7 Recovery-Adjusted Training Session

**Goal:** When recovery is low (Caution or Critical zone), the app adjusts the planned training session and shows the user what changed and why.

**Trigger:** User opens a planned session day view while `recovery_zone` is `caution` or `critical`.

**Visual Treatment:**

```text
┌──────────────────────────────────────────────┐
│ Upper A — Hypertrophy       18:00   Adjusted │
│                                              │
│ ⚠️  Recovery is low (Caution, 38)             │
│ Volume reduced by 30% to protect recovery.    │
│ [ Use adjusted ] [ Use original ]             │
│                                              │
│ Bench Press                                   │
│   Original: 4×8 @ 80kg  ←── strikethrough    │
│   Adjusted: 3×6 @ 72kg  ←── bold, amber      │
│                                              │
│ Incline DB Press                              │
│   Original: 3×10 @ 24kg ←── strikethrough    │
│   Adjusted: 2×8 @ 20kg  ←── bold, amber      │
│                                              │
│ (remaining exercises...)                      │
│                                              │
│ Adjustment reason:                            │
│ "Your HRV is 22% below baseline. Reducing    │
│  volume helps prevent overtraining."          │
│                                              │
│ [ Start Adjusted Session ]                    │
└──────────────────────────────────────────────┘
```

**Adjustment rules (from `life_os_health_ecosystem_spec.md` §3):**

| Zone | Volume reduction | Intensity reduction | Skip suggestion |
|------|-----------------|--------------------|----|
| Caution (25-49) | −30% sets | −10% load | No |
| Critical (0-24) | −50% sets | −20% load | "Consider rest day" option |

**UX rules:**
- Original plan values are shown with `~~strikethrough~~` (design system: `textSecondary` color).
- Adjusted values are shown in **bold** with amber accent color.
- User can always choose "Use original" — this is logged as `training.adjustment_overridden`.
- If user consistently overrides (≥3 times), reduce future adjustment frequency and log `training.adjustment_fatigue`.
- Copy IDs: `training.adjust_banner`, `training.adjust_reason`, `training.adjust_use_adjusted`, `training.adjust_use_original`.

### 4.7 States

- Empty day: `empty.training_*`.
- Recovery critical: warning banner before starting a planned session.
- Offline: save locally + `syncFailed` message from error handling.

---

### 4.8 Start Workout (Manual Logging Entry)

**Goal:** start a workout in < 5 seconds with optional structure.

**Entry points:**
- Training Day view: “Start”
- Unified Diary: “Start Workout”
- Central Log: “Workout”

**Primary CTA:** `training.start_primary`  
**Secondary CTA:** `training.start_secondary`

**Screen layout:**
- Title + helper (`training.start_*`)
- Workout type selector:
  - Strength / Cardio / Mobility / Mixed / Sport
- If a planned session exists for that day:
  - show plan card with “Start planned session” (recommended)
  - allow “Start empty workout” (secondary)
- If templates exist:
  - show 3 recent templates

**Rules:**
- Starting a planned session pre-populates exercises and target sets (editable).
- Starting empty creates an empty session with a single “Add exercise” CTA.

---

### 4.9 Workout Session (Strength — Sets/Reps/Weight)

**Goal:** fast, low-friction set logging with safe validation.

**Header:**
- Elapsed time
- “Finish” CTA (always visible)
- Optional: live heart rate (if available)

**Body (scroll):**
- Exercise cards in order
  - exercise name
  - set list
  - “+ Add set” row
- “Add exercise” floating CTA at bottom

**Set row UI:**
- Columns: Set # | Weight | Reps | RPE
- Each field is tappable and uses a numeric keypad
- “Done” check toggles set completion
- Warmup toggle (optional)

**Rest timer (optional but recommended):**
- Starts automatically when a set is marked done
- Small, dismissible countdown pill

**Validation rules:**
- If a set has missing reps or weight, show inline warning (`training.error_missing_sets`)
- User can still finish:
  - “Fix Set” (recommended)
  - “Save as is” (allowed, but flagged low quality)

**Save behavior:**
- Finish writes `workout_sessions` + nested exercises/sets via `POST /api/workouts/log`.
- On success: show “Finish Workout” summary (4.11).

**Offline behavior:**
- Create local draft session immediately.
- Queue sync; show subtle offline banner.

---

### 4.10 Exercise Picker (Search + Filters)

**Goal:** add exercises quickly without scrolling a massive catalog.

**Layout:**
- Search bar
- Quick filters:
  - Muscle group
  - Equipment
  - Favorites
  - Recent
- Results list with “Add” on each row

**Rules:**
- If session is plan-based, show plan exercises pinned at top.
- Adding an exercise creates the first empty set row to encourage logging.

---

### 4.11 Finish Workout (Summary + Notes)

**Goal:** close the loop and make the user feel progress without guilt.

**Primary CTA:** `training.finish_primary`  
**Secondary CTA:** `training.finish_secondary`

**Summary blocks:**
- Duration
- Total volume (strength) OR distance/time (cardio, if available later)
- Estimated calories (if available)
- Training load update confirmation (“Load updated”)
- Notes field (optional)

**Post-save routing:**
- Return to Training Day view (selected date), session row shows ✓ and summary.

## 5) Daily Diary — Unified (Recommended)

This screen solves the “what did I eat / train / take on that day?” request in one place.
It complements (not replaces) the module diaries.

### Entry Points

- Home avatar → Diary
- Central Log (long press) → “View Day”
- From Nutrition/Training diaries: “View full day”

### Default View

- Opens on **Day view** (today)
- Week strip always visible
- Month grid sheet for fast jumping

### Sections (Day View)

Order is intentional: start with biology, then inputs.
- Sleep + Recovery summary (short)
- Meals (from Nutrition)
- Workouts (from Training)
- Supplements (from Supplements)
- Labs (only if scan pending review or recent marker changes)

Each section has one primary action (e.g., “Log Meal”, “Start Workout”, “Taken”, “Scan”).

**Wireframe (concept)**
```text
┌──────────────────────────────────────────────┐
│ Diary              Feb 2026 ▾                │
│ [Mon Tue Wed Thu Fri Sat Sun] (week strip)   │
│                                              │
│ Recovery  73% ✓ Ready                         │
│ Sleep     7h 20m  (Deep 18% • REM 22%)        │
│                                              │
│ Meals (3)                                     │
│ Lunch 13:45 • 520 kcal                        │
│ [ Log Meal ]                                  │
│                                              │
│ Training (1)                                  │
│ Strength • 65 min • TRIMP 55                  │
│ [ Start Workout ]                             │
│                                              │
│ Supplements                                   │
│ 08:00  ✓ Vitamin D3                            │
│ 21:00  ○ Magnesium                              │
│ [ Taken ]                                     │
└──────────────────────────────────────────────┘
```

### Data Requirements (V2)

**Day view (single request):**
- `GET /api/diary/daily?date=...`

**Month grid (single request, max 62 days):**
- `GET /api/diary/calendar?from=...&to=...`

**Fallback (V1 only):**
- If Unified Diary endpoints are unavailable, the client may call module endpoints in parallel:
  - Recovery: `GET /api/recovery/daily?date=...`
  - Nutrition: `GET /api/nutrition/daily?date=...`
  - Training: `GET /api/workouts/daily?date=...` + planned range
  - Supplements: `GET /api/supplements/daily?date=...`
  - Labs: `GET /api/labs/scan/{scan_id}` if pending

### UX States

- Empty day: show calm empty state with 1 “next best action” CTA
- Offline: show `error.offline_*`, all logging actions go to offline queue
- Low confidence data: show needs-review badge and route to edit

### Month Grid Status Rules (Unified Diary)

Use `status` from `/api/diary/calendar`:
- `complete` → `checkmark.circle`
- `needs_review` → `questionmark.circle`
- `incomplete` → `circle`
- `no_data` → no status icon

**Accessibility:** each cell label includes the status text (never icon‑only).

---

## 5.5) Supplements Diary (V2)

**Goal:** schedule-driven supplement adherence with one-tap “Taken”, without medical claims.

**Entry:** Supplements tab (default to today).

**Default view:** Day view with week strip + month grid sheet.

**Primary CTA:** `supplements.log_primary` (Taken / Log intake)

**Day view content:**
- Adherence today (percent + fraction)
- Time slots with supplement chips
- Unscheduled logs section (if any)

**Data requirements:**
- Day view: `GET /api/supplements/daily?date=...`
- Month grid: `GET /api/supplements/calendar?from=...&to=...`
- Log: `POST /api/supplements/log`

**Month grid icon rules (supplements):**
- `complete` → `checkmark.circle`
- `incomplete` → `circle`
- `no_data` → none

**Safety:**
- Never suggest doses; dose is user-entered only.
- Timing tips are informational only.

---

## 5.6) Sleep (V2)

### Sleep Detail (Tap Sleep Row)

**Goal:** give the user a clear view of sleep quality + actionable, non-medical recommendations.

**Entry points:**
- Unified Diary: tap the “Sleep” row
- Home: “Sleep” card (if present)

**Primary CTA:** none (read-first screen)
**Secondary CTA:** “Connect HealthKit” if missing sleep permissions

**Layout blocks (top → bottom):**
- Sleep Score (0–100) + label (explain it is a quality score, not medical)
- Duration, bedtime, wake time (if available)
- Sleep stages:
  - Deep / REM / Light / Awake (percent + minutes)
  - If stages unavailable, show “Stages unavailable” and hide breakdown
- Trend: 7-day mini chart
- “What affected sleep” (2–3 bullets, evidence-weighted)
- “Try tonight” (1–2 gentle actions)

**Data sources:**
- Summary: `GET /api/sleep/daily?date=...`
- Timeline (optional, on-device): read from HealthKit directly for a stage timeline chart

**States:**
- No HealthKit: show empty state with value proposition + CTA to connect
- Partial permissions: show banner “Some sleep data is missing” (non-blocking)
- Low confidence day: show `global.estimate_badge` and prompt to verify bedtime/wake time (optional)

---

### Sleep Diary (V2)

**Goal:** month/week/day navigation for sleep, optimized for trends over single nights.

**Entry points:**
- Home → Sleep
- Unified Diary → tap Sleep row → “View history”

**Views:**
- Day view (default): score + duration + stages (if available) + 7-day trend
- Month grid (sheet): jump to date

**Primary CTA:** none (read-first)
**Secondary CTA:** `sleep.connect_primary` if missing permission

**Data requirements:**
- Day view: `GET /api/sleep/daily?date=...`
- Month grid: `GET /api/sleep/calendar?from=...&to=...` (max 62 days)

**Month grid icon rules (sleep):**
- `good` → `checkmark.circle`
- `low` → `arrow.down.right.circle`
- `no_data` → none

## 6) Lab Import (Onboarding Optional + Labs Tab)

### 6.1 Capture Screen

- Entry: Onboarding 4B or Supplements → Labs → Scan.
- Primary CTA: `labs.scan_primary`
- Secondary CTA: `labs.scan_secondary`

**Capture hints:** lighting, glare avoidance, include header + table.

### 6.2 OCR + Review

Flow:
1. Capture photo / upload PDF
2. Loading: `loading.ocr_title`
3. Review Values table
4. Save

Review table:
- marker name, value, unit, reference range, status chip
- tap value to edit; unit selector when needed
- low confidence blocks save until reviewed

#### 6.2.1 Asynchronous UX (Don’t Trap the User)

OCR is async and may take time. The user must be able to:
- leave the screen while processing
- return later from Labs tab
- receive a reminder (optional) if a scan is pending review

Processing states:
- `uploading` → show progress (photo compression + upload)
- `processing` → show shimmer + “This can take up to 30s”
- `completed` → auto-route to Review
- `failed` → show error + offer Retry/Upload PDF

#### 6.2.2 Marker Normalization Rules (Human-Checkable)

In Review:
- Always show BOTH:
  - parsed marker name (normalized)
  - original label from document (small secondary line)
- If the marker cannot be mapped to `health_marker_catalog` confidently:
  - show it as “Unrecognized marker”
  - require user to pick from a short list of likely matches OR mark as “Keep as custom”

Unit handling:
- If unit is missing/ambiguous, require unit selection (disable Save until fixed).
- If unit is uncommon but convertible (e.g., mmol/L ↔ mg/dL), show conversion helper:
  - “Converted to {target_unit} for consistency” (info tooltip)

Reference ranges:
- If reference range is present, show it.
- If missing, show “No reference range in report” (do not invent).

#### 6.2.3 Duplicate Detection (Same Day / Same Marker)

Before final save:
- Detect likely duplicates:
  - same `scan_date` ± 2 days AND same lab name AND overlapping marker set ≥ 60%
- If duplicates found:
  - show warning sheet:
    - “Possible duplicate test”
    - options:
      - Keep both
      - Replace previous
      - Review differences

Replace rules (safe default):
- Never auto-delete without explicit confirmation.
- Always allow Undo after replacing.

#### 6.2.4 Privacy Toggles (Onboarding-Friendly)

At first labs import, show a lightweight privacy row:
- “Store scans on this device only” (default)
- “Sync scans to cloud” (opt-in, explains tradeoff)

#### 6.2.5 Post-Save Confirmation

After save:
- Show summary:
  - “Saved {markers_count} markers”
  - “{N} out of range” (non-diagnostic language)
- Provide next CTAs:
  - “View trends”
  - “Add note”

### 6.3 Data Requirements

- Existing: `POST /api/labs/scan` async
- Required addition: `GET /api/labs/scan/{scan_id}` to check status + extracted markers

### 6.4 States

- Low confidence: `labs.ocr_low_*`
- Offline: local save until sync

---

## 6.5 Data Sources (Settings — Attribution)

**Goal:** transparent attribution + trust for food data sources (legal/store readiness + user confidence).

**Entry points:**
- Settings → About → Data Sources
- (Optional) Nutrition → “i” on a product source badge

**Copy IDs:** `settings.data_sources_*`

**Content (minimal, calm):**
- Row: “Product data” → “From Open Food Facts (ODbL)” + external link
- Row: “Community products” → “Added by users via label scan”
- Footer disclaimer: “Verify nutrition labels if unsure.”

**Hard rules:**
- Never imply medical accuracy; always frame as user-verifiable data.
- Links open in in-app browser; back returns to Settings.

---

## 7) Copy IDs

These copy IDs are required by this spec and are now defined in `life_os_copy_catalog.md` (v1.14).

- Onboarding: `onboarding.*`
- Nutrition diary + logging (photo/barcode/voice/manual), label scan (barcode fallback), meal prep (batch recipes): `nutrition.*`
- Training diary + merge: `training.diary_*`, `training.merge_*`
- Unified diary: `diary.*`
- Labs scan + review: `labs.*`
- Sleep detail: `sleep.*`

---

## 8) Suggested Analytics Events (Optional)

- `onboarding_step_viewed` { step }
- `onboarding_step_completed` { step }
- `onboarding_healthkit_connected` { status }
- `nutrition_date_selected` { date }
- `nutrition_meal_logged` { method, confidence }
- `nutrition_log_method_selected` { method }
- `nutrition_barcode_scanned` { status: found|not_found|error }
- `nutrition_voice_parsed` { needs_clarification, confidence }
- `training_date_selected` { date }
- `training_workout_logged` { source, type }
- `training_conflict_resolved` { resolution }
- `labs_scan_started` { source: photo|pdf }
- `labs_scan_saved` { markers_count, confidence }

---

## 9) Insights & Experiments (NEW)

### 9.1 Insights List

**Entry points:**
- Home “Insights” card
- Module-specific “Insights” sub‑section

**Primary CTA:** `insights.open_detail`
**Copy IDs:** `insights.list_title`, `insights.open_detail`

**Layout blocks:**
- Section header + filter (All / Nutrition / Training / Sleep / Supplements / Labs)
- Insight cards (title, 1‑line summary, confidence badge)
- Unread indicator

**Card rules:**
- Show “Why” snippet (first sentence).
- Show confidence (High/Medium/Low).
- Dismiss action is secondary and confirms.
  - Use `insights.dismiss` copy ID.

**API:**
- `GET /api/insights?unread=true`

### 9.2 Insight Detail

**Primary CTAs:** `insights.start_experiment` (if eligible), `insights.acknowledge`
**Copy IDs:** `insights.start_experiment`, `insights.acknowledge`, `insights.why_this`

**Layout blocks:**
- Title + category tag
- Pattern observed
- Why it matters (1–2 short paragraphs)
- Recommended action (specific, time‑bound)
- “Why this” button (educational context)
- Optional experiment CTA (if data supports it)

**Rules:**
- Always show confidence.
- Never claim causality without an experiment.
- Provide one clear next action only.
 - If confidence < 0.65, do not show “Start experiment”.

**API:**
- `GET /api/insights/{id}`
- `POST /api/insights/{id}/acknowledge`
- `POST /api/insights/{id}/dismiss`

### 9.3 Experiments List

**Entry points:**
- Insight detail “Start experiment”
- Home “Experiments” card (if active or completed)
**Copy IDs:** `experiments.list_title`, `experiments.empty_*`

**Layout blocks:**
- Active experiments list
- Completed experiments list
- Empty state encourages starting from an insight

**API:**
- `GET /api/experiments?status=active|completed`

### 9.4 Experiment Detail

**Primary CTA:** `experiments.log_daily`
**Copy IDs:** `experiments.log_daily`, `experiments.stop`

**Layout blocks:**
- Hypothesis (short)
- Protocol summary (duration, steps)
- Daily measurement prompt(s)
- Progress timeline
- Stop experiment CTA (secondary)

**Rules:**
- Daily logging should take < 20 seconds.
- If user misses a day, show a non‑judgmental reminder.

**API:**
- `POST /api/experiments/{id}/log`

### 9.5 Experiment Results

**Goal:** show a clear summary of outcome after completion.

**Copy IDs:** `experiments.results_title`, `experiments.results_summary`

**Layout blocks:**
- Result summary (positive/neutral/negative)
- Effect size + confidence
- Compliance percent
- Key chart (baseline vs intervention)
- Suggested next step (continue, modify, or stop)

**API:**
- `GET /api/experiments/{id}`

### 9.6 Predictive Simulation (What-If) (NEW)

**Goal:** allow the user to simulate the biological impact of a hypothetical decision (e.g., late sleep, missed workout) before they make it.

**Entry points:**
- Home "Unified Diary" (Recovery card CTA: "Simulate")
- Insights List (sticky header CTA: "New Simulation")

**Primary CTA:** `insights.simulate_primary` (Run Simulation)
**Copy IDs:** `insights.simulate_title`, `insights.simulate_placeholder`, `insights.simulate_disclaimer`

**Layout blocks (Input State):**
- Title: "What-If Simulation"
- Disclaimer: "Predictions are based on your biological history. This is not medical advice."
- Text Input: "What do you plan to do?" (e.g., "Sleep at 02:00 today")
- Category chips (optional shortcut): [Sleep] [Training] [Nutrition] [Other]
- Primary CTA: "Run Simulation"

**Layout blocks (Result State):**
- Loading shimmer: "Analyzing your biological patterns..." -> `loading.what_if`
- Predicted Zone: Large gradient bar highlighting the `predicted_zone` (Optimal/Ready/Caution/Critical).
- Predicted Range: "Estimated Recovery: 30% - 42%"
- AI Explanation: Short text block explaining *why* based on historical precedent (from LLM).
- Secondary CTA: "Discard"
- Tertiary CTA: "Adjust and rerun"

**Rules:**
- Do not let the user save a simulation as actual data. It is inherently ephemeral.
- If the predicted bounds are Critical, show the standard Critical red color but keep wording advisory.

**API:**
- `POST /api/insights/predict`

---

## 10) Notifications & Control (NEW)

### 10.1 Notification Settings

**Entry:** Settings → Notifications  
**API:** `GET/PATCH /api/settings/notifications`
**Copy IDs:** `settings.notifications_title`

**Controls:**
- Morning Brief toggle + time picker
- Positive reinforcement toggle (max 3/day)
- Gentle nudges toggle (max 2/day)
- Critical alerts only toggle
- Quiet hours start/end

**Rules:**
- If “Critical only” is enabled, other toggles are visually disabled.
- Max total notifications per day is 6 (hard cap).
- If “Critical only” is enabled, Control Level is forced to Advisory.

### 10.2 Control Level

**Entry:** Settings → Control  
**Copy IDs:** `settings.control_*`

**Options:**
- Advisory
- Protective
- Guardian

**Guardrails:**
- Guardian requires explicit consent and iOS Focus/Screen Time permission.
- If permission is not granted, show inline banner and fall back to Protective.
- Provide “Pause control for today” quick action (`settings.control_pause_today`).
- When Guardian is enabled, show a list of blocked apps and the time window.

### 10.3 Focus Control Permission Flow (FamilyControls)

**Entry:** Control Level → select Guardian

**Step 1 — Explain**
- Title: `settings.focus_title`
- Helper: `settings.focus_helper`
- Primary CTA: `settings.focus_continue`
- Secondary CTA: `global.cancel`
- Tertiary CTA: `settings.focus_learn_more`

**Learn more sheet (content):**
- Title: `settings.focus_learn_more_title`
- Body: `settings.focus_learn_more_body`
- CTA: `global.done`

**Step 2 — System Permission**
- Trigger iOS Screen Time authorization prompt.
- If denied, show banner `settings.control_permission_needed` and revert to Protective.

**Step 3 — Choose Apps**
- Present app selection UI (iOS FamilyControls picker).
- User selects apps to block (can be empty; if empty, Guardian behaves like Protective).

**Step 4 — Confirmation**
- Show list of selected apps + default window length (max 2h).
- Primary CTA: `settings.focus_confirm`
- Secondary CTA: `settings.focus_edit_apps`

**Rules:**
- Never block Health, Emergency, or Phone apps.
- Selected app list is stored locally only (see privacy).

---

## 11) watchOS Companion (V2)

> Source of truth for full contract + sync details: `life_os_watchos_spec.md`.

### 11.1 Complications (Recovery)

**Goal:** recovery at a glance.

**Supported types:**
- Circular
- Rectangular
- Corner

**Content:**
- Recovery % (or score)
- Zone icon + short label (never color-only)

**Interaction:**
- Tapping complication opens the watch Glance view.

**Update rules:**
- Update after the morning recovery refresh completes.
- Update immediately when `recovery_zone` changes.

### 11.2 Watch App — Glance View (Primary Screen)

**Entry points:**
- Open Life OS on watch
- Tap complication

**Goal:** show “what to do now” in < 3 seconds.

**Layout (top → bottom):**
- Recovery score + zone
- Confidence (if `< 0.65`, show `global.estimate_badge` and avoid any action that could be harmful without iPhone review)
- One Next Best Action (single CTA)
- Optional: “Due soon” pill (supplements / sleep prep) — `watch.due_soon`
- Footer: “Last updated {time}” — `watch.last_updated`

**CTA behavior:**
- If action is safe + one-tap (supplement taken / insight acknowledge), execute on watch and sync via iPhone.
- Otherwise route to iPhone via `global.open_on_iphone` deep link.

### 11.3 Lightweight Actions (Allowed)

**A) Mark supplement as taken**
- CTA label: `supplements.log_primary`
- Host iPhone performs `POST /api/supplements/log`.
- Expect updated snapshot on watch within 5 seconds (when phone is reachable).

**B) Acknowledge an insight**
- CTA label: `insights.acknowledge`
- Host iPhone performs `POST /api/insights/{id}/acknowledge`.
- Expect updated snapshot on watch within 5 seconds.

**Safety rules:**
- Never allow edits of meals/workouts/labs or supplement doses on watch.
- If phone is unreachable, disable actions and show `global.open_on_iphone`.

### 11.4 Deep Link Routing (Watch → iPhone)

When routing to iPhone, deep link into the most specific screen available:
- Unified Diary day view for `date`
- Sleep detail for `date`
- Supplements day view for `date`
- Insight detail for `id`

---

## CHANGELOG

### v0.10 (February 4, 2026)
- Initial fast logging flows and diary specs

### v0.11 (February 9, 2026)
- Aligns with API spec v2.2 and HealthKit spec v1.1
- Added explicit “Out-of-Scope Surfaces (V2)” section
- Clarified Next Best Action source-of-truth link to API spec
- Unified V1/V2 diary flows

### v0.12 (February 16, 2026)
- Added Account Upgrade / Link flow (§12)
- Added Offline Photo Save-for-Later queue (§13)
- Updated alignment references to PRD v7.13, API Spec v2.3, HealthKit Spec v1.2, Invariants v0.5

---

## 12) Account Upgrade / Link Flow

### 8.1 Overview

Users start with **silent anonymous auth** (no email/password wall). Account upgrade allows linking Apple ID or email to preserve data and enable multi-device sync.

**Entry points:**
- Settings → Account → "Link Account"
- Prompted automatically when enabling multi-device sync or GDPR export
- Prompted on watchOS first pairing (watchOS requires authenticated account)

### 8.2 Link Apple ID

**Flow:**
1. User taps "Link Apple ID"
2. System presents Apple Sign-In sheet (native `ASAuthorizationAppleIDProvider`)
3. On success: Supabase `linkIdentity()` merges Apple credential into existing anonymous account
4. On success confirmation: show `account.link_success` toast with checkmark
5. On error (`AUTH_LINK_CONFLICT`): show `account.link_conflict_title` + `account.link_conflict_body` → "This Apple ID is already linked to another account. Contact support or use a different Apple ID."

**Data preservation guarantee:**
- All existing data stays intact. No data is deleted or moved.
- User sees `account.link_data_preserved_message`: "All your data has been preserved."

### 8.3 Link Email / Password

**Flow:**
1. User taps "Link Email"
2. Email input + password creation form (min 8 chars, 1 uppercase, 1 number)
3. Supabase `updateUser()` attaches email credential
4. Verification email sent → user taps link → account confirmed
5. Until confirmed: show `account.verify_email_pending` banner in Settings

**Error states:**
- Email already in use: `account.email_taken_message`
- Weak password: inline validation, non-blocking
- Verification expired: "Resend verification" button

### 8.4 Account Status Display (Settings)

```
┌────────────────────────────────────┐
│  Account                          │
│                                   │
│  Status: Anonymous account        │  ← or "Linked (Apple ID)" or "Linked (email)"
│                                   │
│  [Link Apple ID]                  │  ← hidden if already linked
│  [Link Email]                     │  ← hidden if already linked
│                                   │
│  ⚠️ Link your account to enable   │  ← only for anonymous users
│     multi-device sync and export  │
└────────────────────────────────────┘
```

**Rules:**
- Anonymous users cannot enable multi-device sync or GDPR data export. When they try, redirect to this screen.
- Linking is non-destructive and one-way: once linked, the user cannot unlink (they can delete the account instead).
- After linking, the app immediately triggers a full Outbox push to ensure all local data reaches the server.

---

## 13) Offline Photo Save-for-Later Queue

### 9.1 Overview

When the user takes a food photo while offline, the photo is saved locally and queued for AI analysis when connectivity returns.

### 9.2 Photo Capture (Offline)

**Flow:**
1. User opens Photo logging (3.10) while offline
2. Camera opens normally; user takes photo
3. App detects no connectivity → shows `nutrition.photo_saved_offline` toast: "Photo saved. We'll analyze it when you're back online."
4. Saves photo to local storage (App Group shared container, same as widget data)
5. Creates a `pending_photo_analysis` local record:
   - `id` (UUID)
   - `photo_local_path` (string)
   - `captured_at` (TIMESTAMPTZ)
   - `meal_type` (inferred from time of day)
   - `status`: `pending | analyzing | completed | stale`

### 9.3 Pending Queue Badge

- Diary day view shows an orange badge next to the meal section: `nutrition.pending_analysis_badge` (e.g., "1 photo pending")
- Tapping the badge opens the Pending Queue list

### 9.4 Pending Queue List

```
┌────────────────────────────────────────┐
│  Pending Analysis (2)                  │
│                                        │
│  ┌──────┐  Lunch · 2h ago             │
│  │ 📷   │  Waiting for connection...  │
│  └──────┘  [Retry Now] [Enter Manual] │
│                                        │
│  ┌──────┐  Dinner · 26h ago     ⚠️    │
│  │ 📷   │  Photo may be stale         │
│  └──────┘  [Analyze Anyway] [Manual]  │
└────────────────────────────────────────┘
```

### 9.5 Stale Photo Handling

- Photos older than **24 hours** are marked `stale` and show a warning: `nutrition.photo_stale_warning`: "This photo is over 24 hours old. AI analysis may be less accurate since your memory of the meal may have faded."
- Stale photos are **not auto-deleted**. User can still choose "Analyze Anyway" or switch to manual entry.
- Photos older than **7 days** are auto-archived with a notification: `nutrition.photo_expired`: "A saved food photo expired. You can still log this meal manually."

### 9.6 Re-Analysis Trigger

- When connectivity returns, the app automatically processes the pending queue in FIFO order.
- Each photo goes through the standard photo analysis pipeline (3.10).
- On success: the Review Meal screen (3.8) opens with a "From saved photo" label.
- On failure: show `nutrition.photo_analysis_failed_retry` with manual entry fallback.
- Maximum concurrent analyses: 1 (serial queue to avoid API rate-limit issues).

**Priority:** Pending photo analysis is **lower priority** than user-initiated real-time photo analysis. If the user takes a new photo while the queue is processing, pause queue and process the new photo first.

---

## CHANGELOG

### v0.12 (February 16, 2026)
- Added Account Upgrade / Link flow (§12)
- Added Offline Photo Save-for-Later queue (§13)

### v0.11 (February 9, 2026)
- Unified V1/V2 diary flows
- Updated API spec reference to v2.0
- Added Home Screen core spec
- Added Auth screens (link/sign-in)
- Added Experiment Results screen
- Fixed section numbering

### v0.9 (February 4, 2026)
- Added Insights list/detail and Experiments list/detail UX
- Added Notification Settings and Control Level UX
- Added watchOS companion UX surfaces (complication + glance + lightweight actions)

### v0.8 (February 4, 2026)
- Added barcode fallback flow: Scan Nutrition Label → analyze-food-label → Review Product → save reusable barcode product
- Added Meal Prep / batch recipes UX: library, create (precise + quick), review, detail, log portion
- Updated barcode not-found CTAs to use explicit copy IDs
- Added Settings “Data Sources” attribution screen spec (Open Food Facts + community products)
- Aligned barcode product CTA to `nutrition.add_to_meal` and updated Copy Catalog reference to v1.10

### v0.7 (February 4, 2026)
- Added deep Nutrition logging flows: method picker, photo, barcode, voice, manual search, portion editor, quick add
- Expanded Labs import: async states, normalization rules, duplicate detection, privacy toggles, post-save confirmation
- Added Training workout logging flows: start workout, exercise picker, set logging, finish summary

### v0.6 (February 3, 2026)
- Added wireframe for unified Daily Diary screen

### v0.5 (February 3, 2026)
- Added Nutrition meal detail/review spec (tap a meal from diary)

### v0.4 (February 3, 2026)
- Added silent-by-default auth guidance to support frictionless onboarding

### v0.3 (February 3, 2026)
- Added unified Daily Diary concept (all modules in one day view)

### v0.2 (February 3, 2026)
- Expanded onboarding (wireframes, validation, optional steps)
- Defined calendar diary status rules and required API range endpoints
- Added lab scan status polling requirement
