# LIFE OS - HEALTH ECOSYSTEM DETAILED SPEC

**Version:** 1.5
**Date:** February 16, 2026  
**Purpose:** Deep functional + UX + AI + data specification for Nutrition, Training, Supplements, and Labs with cross-domain intelligence.

> [!IMPORTANT]
> This document is intentionally exhaustive. It complements (and does not replace) the PRD, API spec, recovery algorithms, and privacy architecture.

---

## 0) SCOPE AND AUDIENCE

**Audience:** "All segments" by default. The system must serve:
1. Beginners (low friction, guidance, and safety-first defaults)
2. Fitness enthusiasts (depth, progression, performance metrics)
3. Biohacking/analytics users (labs, experiments, correlations)

**Non-negotiables**
- Low friction logging (<= 15 seconds for common actions)
- Explainability (every recommendation has a reason)
- Safety and non-medical positioning
- Cross-domain intelligence (sleep, recovery, nutrition, training, supplements, labs)
- Data quality transparency (AI confidence + user verification)

**Non-goals (for V1)**
- Medical diagnosis or clinical dosing
- Prescription medication management
- Real-time coaching or supervision

---

## 1) SHARED FOUNDATIONS

### 1.1 Data Quality Model
All data points must be labeled with **source** and **confidence**:

```yaml
DATA_QUALITY:
  sources:
    - user_manual
    - ai_estimated
    - wearable_synced
    - lab_ocr
    - external_db (barcode/catalog)
  confidence:
    high: ">=0.85"
    medium: "0.65-0.84"
    low: "<0.65"
  rules:
    - low confidence always triggers edit confirmation
    - user edits override AI values and are marked user_manual
    - UI must display confidence in a lightweight way (icon + tooltip)
```

### 1.2 Cross-Domain Trigger Engine
Any new data in one module can trigger analysis in others:
- Food log -> adjust training fuel suggestions and supplement timing
- Workout -> adjust nutrition targets, recovery prediction
- Lab scan -> update nutrition gaps and supplement suggestions
- Sleep dip -> recommend training volume reduction and caffeine timing

### 1.3 Safety Rules (Global)
- No diagnosis language
- No supplement dosing changes (timing only)
- All lab discussions include an explicit "consult clinician" reminder for abnormal results
- Never claim causality without experiment or strong evidence

### 1.4 Control Levels (Global)

Life OS must obey the user’s **Control Level** (see PRD). This affects recommendation tone and enforcement.

**Levels:**
- Advisory: recommendations only
- Protective: strong discouragement + schedule adjustments, no app blocking
- Guardian: may enforce Focus/Screen Time restrictions only if permission is granted

**Rules:**
- Guardian requires explicit opt‑in and Focus Control permission.
- If permission is missing, fall back to Protective and log a warning.
- All automatic restrictions are time‑bound and reversible.

### 1.5 Data Gaps & Check‑ins (Global)

The system must request missing data **without nagging**.

**Rules:**
- Only ask for one missing domain per check‑in.
- Do not ask more than once per 6 hours.
- If the user dismisses a check‑in twice in 7 days, pause for 7 days.
- Always provide a one‑tap “Not now” option.

**Priority order (highest to lowest):**
- Recovery inputs missing (sleep/HRV)
- Training log missing when a workout is detected
- Nutrition gaps for the current day
- Supplements scheduled but unlogged

---

## 2) NUTRITION MODULE (FOOD + MEAL INTELLIGENCE)

### 2.1 Core Entities
```yaml
ENTITIES:
  food_log:
    - meal_type
    - logged_at
    - logged_date (user-local, for diary grouping)
    - context (home|restaurant|party|unknown)
    - input_method (vision|barcode|voice|manual|batch|template)
    - totals (kcal, P/F/C, micro)
    - confidence
  food_item:
    - name
    - portion_size
    - macros
    - micro
    - confidence
  batch_recipe:
    - ingredients
    - cooked_at
    - total_weight_g (cooked yield; ground truth)
    - total_macros (entire batch)
    - per_100g_macros (canonical)
    - total_portions (optional convenience)
    - remaining_weight_g (derived from logged portions)
  meal_template:
    - quick-add with prefilled items
```

### 2.2 Input Methods (Priority Order)
1. **Photo (single/multi)**: default for most users
2. **Barcode**: packaged foods
3. **Voice**: fast logging with clarification questions
4. **Manual**: full control
5. **Recipe**: batch cooking and meal prep

### 2.2A Food Data Strategy (Barcode + Search) — CIS-Optimized

**Source of truth:** `life_os_food_data_strategy.md` (provider choice, caching, attribution, deterministic lookup order).

**Locked decisions (must match UX + API):**
- Primary provider for barcode + search: **Open Food Facts** (`open_food_facts`)
- CIS-critical fallback when barcode is missing: **Scan nutrition label** → OCR → **mandatory review** → save as reusable product (`lifeos_label_ocr`)
- Personal truth always wins: user can create a custom override with the same barcode in `user_foods`

**User experience rules:**
- A barcode miss must never block logging (offer Search/Photo/Manual/Scan label).
- OCR-derived products are never persisted without a review screen.
- The app must display the food data source (Open Food Facts vs Community vs You).

### 2.3 Photo Analysis Pipeline
```yaml
PIPELINE:
  1_capture:
    - validate lighting
    - confirm full plate visibility
    - optional reference object (hand/utensil)
  2_preprocess:
    - crop and de-skew
    - detect non-food objects
  3_segment:
    - detect multiple foods
  4_classify:
    - food category and likely variants
  5_portion_estimate:
    - size heuristics + reference object
    - fallback to typical serving sizes
  6_macro_calc:
    - compute macro and micro
  7_context_adjust:
    - context adjustment (hidden calories model based on cuisine + dish type + uncertainty)
    - post-workout fuel adjustment
  8_user_confirm:
    - show confidence and allow edit
```

### 2.4 Portion Estimation Rules
- If plate size is unknown and no reference object, default to **standard serving size** and label **medium confidence**
- If user provides weight, use weight and override AI estimate
- If item is mixed (stew/pasta/salad), show **range estimate** and prompt for a quick correction

### 2.5 Nutrition Targets (Dynamic)
Targets are recalculated daily:

```yaml
TARGETS:
  base:
    - derived from BMR/TDEE + goal
  adjustments:
    - training_load:
        # weight_kg MUST come from getEffectiveWeight() (Section 27 of recovery_algorithms)
        # NOT from static userProfile.weight_kg — see Dynamic Weight integration table
        effective_weight_kg = getEffectiveWeight(userId).weightKg
        weight_factor = clamp(effective_weight_kg / 70, 0.75, 1.25)
        if active_energy_kcal:
          adjustment_kcal = clamp(active_energy_kcal * 0.4 * weight_factor, 0, 600)
        else:
          adjustment_kcal = clamp(daily_trimp * 1.3 * weight_factor, 0, 600)
    - recovery_state (continuous linear interpolation):
        # Replaces discrete step-function to eliminate zone-boundary discontinuities
        recovery 0→50:
          protein_delta_g_per_kg = lerp(recovery, 0, 50, +0.30, 0)
          carb_multiplier        = lerp(recovery, 0, 50, 0.85, 1.00)
          calorie_multiplier     = lerp(recovery, 0, 50, 0.95, 1.00)
        recovery 50→100:
          protein_delta_g_per_kg = 0
          carb_multiplier        = lerp(recovery, 50, 100, 1.00, 1.05)
          calorie_multiplier     = lerp(recovery, 50, 100, 1.00, 1.05)
    - sleep_debt:
        if debt_hours >= 2:
          caffeine_cutoff = bedtime - 10h (min 12:00)
          dinner_deadline = bedtime - 3.5h
        if debt_hours >= 3.5:
          caffeine_cutoff = bedtime - 12h (min 10:00)
          dinner_deadline = bedtime - 4.0h
    - menstrual_phase (optional): adjust carbs and hydration
```

### 2.6 Meal Planning
- Daily meal suggestions based on remaining macros
- Weekly batch plan with grocery list
- Quick replacement suggestions if user misses a meal

### 2.6A Meal Prep (Batch Recipes) — Accuracy Model

Batch recipes are designed for real-world meal prep: the user cooks once, measures total cooked weight, and then logs by grams.

**Two creation modes (must match UX):**
1. **Precise (recommended):** user adds ingredients (search/barcode/custom) + weights → totals are computed deterministically.
2. **Quick (photo draft):** AI estimates ingredients and totals from a photo, but the result is always marked `needs_review = true` and must be confirmed before saving.

**Ground truth rule:**
- `total_weight_g` is user-measured (kitchen scale) and overrides AI assumptions about water loss.

**Logging rule:**
- Logging a portion is done by grams (`portion_weight_g`), not “1/3 container” heuristics.
- Remaining weight tracking is always shown to the user (trust + adherence).

### 2.7 Edge Cases
- Mixed plates with hidden sauces
- Restaurant meals with unknown oils
- Packaged foods without barcode match
- Cultural foods with limited database coverage
- Late-night meals affecting sleep

---

## 3) TRAINING MODULE (LOGGING + PLAN INTELLIGENCE)

### 3.1 Core Entities
```yaml
ENTITIES:
  exercise_catalog:
    - name, muscles, equipment, difficulty
  workout_session:
    - started_at, ended_at, type
    - session_date (user-local, for diary grouping)
    - pre_recovery_score
    - total_volume, calories, trimp_score
  workout_exercise:
    - exercise_id, sets, volume
  workout_set:
    - reps, weight, rpe, tempo
  training_plan:
    - goal, phases, weeks
    - adaptive rules
```
### 3.2 Training Load Calculations (Source of Truth)

**Purpose:** deterministic load metrics used by recommendations and recovery adjustments.

**Daily TRIMP (zone‑based or RPE‑based):**
```
if HR zones available:
  daily_trimp = sum(minutes_in_zone_i * zone_multiplier_i)
else:
  daily_trimp = duration_minutes * RPE
```

**Zone multipliers (exponential, Banister-style):**
- Zone 1: 1.0
- Zone 2: 2.0
- Zone 3: 4.0
- Zone 4: 7.0
- Zone 5: 12.0

> Linear multipliers are deprecated. Exponential scaling prevents HIIT from being undervalued.

**RPE fallback rules (imported workouts):**
- If the session is imported and RPE is missing:
  - Use `workout_sessions.perceived_exertion_rpe` if the user adds it post‑import.
  - Else derive RPE from HR zones if available.
  - Else default RPE = 3 (light‑moderate), cap TRIMP at 200, and mark training load confidence as low.

**ACWR (Acute : Chronic Workload Ratio, EWMA):**
```
acute_7d = EWMA(daily_trimp, lambda=0.25)   // 2/(7+1)
chronic_28d = EWMA(daily_trimp, lambda=0.069) // 2/(28+1)
ACWR = acute_7d / max(chronic_28d, cold_start_baseline, 1)

cold_start_baseline:
  - if < 14 days of data: max(avg_daily_trimp * 0.5, 50)
  - else: 0
```

**Zones:**
- undertraining: ACWR < 0.8
- optimal: 0.8–1.3
- overreaching: 1.3–1.5
- injury_risk: > 1.5

**Rules:**
- ACWR uses only non‑deleted sessions.
- If data completeness < 0.65, show "low confidence" and avoid strict enforcement.
- If ACWR > 1.5, reduce intensity and volume (see Adaptive Rules).

**Storage:** use `training_loads.daily_trimp` (daily aggregate) and `workout_sessions.trimp_score` (per-session).


### 3.3 Logging Modes
1. **Manual** (strength)
2. **Auto-detected** (cardio/steps via wearables)
3. **Template-based** (repeated workouts)
4. **AI plan-based** (auto-filled from plan)

### 3.4 Supplementary Nutrition Tracking

**Alcohol:**
- Field: `alcohol_units NUMERIC(4,1)` on `food_logs` (per-meal estimate)
- Derivation: User logs drinks; each standard drink = 1 unit (10g ethanol)
- Used by: Recovery algorithms (sleep + next-day penalty)

**Caffeine:**
- Field: `caffeine_mg INTEGER` on `food_logs` (per-meal estimate)
- Derivation: Estimated from food/drink type (coffee ~95mg, tea ~47mg, cola ~34mg)
- Used by: Sleep impact model (remaining caffeine at bedtime using half-life)

**Hydration:**
- Tracked via dedicated `hydration_logs` table:
  - `id UUID PRIMARY KEY, user_id UUID, logged_at TIMESTAMPTZ, water_ml INTEGER, source TEXT`
- Daily goal: `user_settings.daily_water_ml_goal` (default 2500ml)
- Used by: Recovery algorithms (dehydration detection)

### 3.5 Training Plan Generator
```yaml
INPUTS:
  - goals (strength, hypertrophy, endurance, weight_loss)
  - available_days, session_duration
  - equipment_access
  - injuries + constraints
  - recovery baseline + sleep trend

OUTPUTS:
  - mesocycle (4-8 weeks)
  - weekly split
  - per-session exercise list + set/rep targets
  - progression rules
```

### 3.6 Adaptive Plan Rules
- If recovery < 50: reduce volume by 30%
- If recovery < 25 (Critical zone): replace with mobility + walking

> Rules are evaluated most-restrictive first: if recovery < 25 (Critical zone), replace with mobility; else if recovery < 50 (Caution zone), reduce volume by 30%.
- If ACWR > 1.5: reduce intensity and volume
- If 2+ missed workouts: reflow schedule without doubling volume

**Compound rule resolution:**
- If recovery < 25: always swap to mobility (overrides ACWR).
- If recovery 25–49 AND ACWR > 1.5: reduce volume 30% + reduce intensity 20% (same day).
- If recovery 25–49 AND ACWR 1.3–1.5: reduce volume 30% only.
- If recovery ≥ 50 AND ACWR > 1.5: reduce volume 20% + reduce intensity 20%.

**Adaptive rule enums (must match API):**
- `reason`: `recovery_low | recovery_critical | fatigue_accumulation | injury_flag | user_request | schedule_conflict | load_spike_acwr`
- `adjustment`: `reduce_volume_30 | reduce_intensity_20 | skip_session | swap_to_mobility | extend_rest_day | deload_week`

### 3.7 Safety + Injury Prevention
- Flag imbalanced muscle group load
- Identify too-rapid volume jumps
- Explicit rest-day recommendations

### 3.8 Edge Cases
- Travel weeks (equipment limited)
- Illness/fever signals (override plan)
- Conflicting goals (strength + marathon)

---

## 4) SUPPLEMENTS MODULE (STACK + TIMING)

### 4.1 Core Entities
```yaml
ENTITIES:
  supplement_catalog:
    - evidence_level
    - interactions
  user_supplement:
    - user-entered dose (not prescribed)
    - schedule + reminders
  supplement_log:
    - taken_at, with_food, felt_effect
    - taken_date (user-local, for diary grouping)
```

### 4.2 Timing Optimization (Allowed)
- Suggest **timing only** for user-entered supplements
- Avoid suggesting new supplements with dosage
- Provide evidence level and caution

### 4.3 Interaction Checks

**Interaction rules are enforced when the user schedules or logs a supplement.** The system checks the user's entire active stack for conflicts.

#### Interaction Rules Database

| Supplement A | Supplement B / Factor | Interaction Type | Severity | Action | Evidence |
|-------------|----------------------|-----------------|----------|--------|----------|
| Calcium | Iron | Absorption interference | `warning` | Suggest 2+ hour separation | Strong (multiple RCTs) |
| Magnesium | High fiber meal | Absorption interference | `info` | Suggest taking on empty stomach or 1h after meals | Moderate |
| Caffeine (any source) | Sleep window | Timing conflict | `warning` | Suggest consuming ≥ `caffeine_cutoff` hours before bedtime (see sleep debt rules) | Strong |
| Zinc | Copper | Depletion risk | `warning` | If zinc > 30mg/day for > 8 weeks, suggest copper co-supplementation | Moderate |
| Vitamin D | Vitamin K2 | Synergy | `info` | Suggest pairing for optimal calcium metabolism | Moderate |
| Fish oil / Omega-3 | Blood thinners (user-reported) | Safety concern | `caution` | Display: "Fish oil may increase bleeding risk. Consult your clinician." | Strong |
| Iron | Coffee / Tea | Absorption interference | `warning` | Suggest 1+ hour separation from coffee/tea | Strong |
| Vitamin C | Iron | Synergy | `info` | Suggest pairing to enhance iron absorption | Strong |
| Melatonin | Morning/afternoon timing | Timing conflict | `warning` | Suggest taking only within 1h of bedtime | Strong |
| Creatine | Caffeine | Potential interference | `info` | "Some evidence suggests caffeine may reduce creatine uptake. Consider separating." | Weak |

#### Severity Levels

| Severity | UI Treatment | Blocking? |
|----------|-------------|----------|
| `caution` | Red alert banner with "Consult clinician" | Non-blocking, but requires explicit "I understand" tap to dismiss |
| `warning` | Amber alert with timing suggestion | Non-blocking |
| `info` | Blue info chip, subtle | Non-blocking |

#### Rules
- **Non-prescriptive:** The system never prevents the user from taking a supplement. It only surfaces information.
- **User override:** If the user dismisses an interaction warning, it is suppressed for that specific pair for 30 days (stored in `user_supplement_interaction_dismissals`).
- **Client/server split:** Interaction rules are stored server-side in `supplement_interactions` table and cached locally (TTL: 24h). This allows rules to be updated without app releases.
- **Maintenance:** Interaction rules are reviewed quarterly against ISSN Position Stands, Examine.com updates, and new meta-analyses.
- **Custom supplements:** User-created supplements do not trigger interaction checks (no data to check against).

### 4.4 Adherence + Insights
- % of supplements taken on schedule
- Correlations with sleep or recovery (if enough data)

---

## 5) LABS + BIOMARKERS MODULE

### 5.1 Input Methods
1. Photo scan (phone camera)
2. PDF upload
3. Manual entry

### 5.2 OCR + Normalization Pipeline
```yaml
PIPELINE:
  - detect document type + language
  - extract markers + values
  - map to canonical marker IDs
  - convert units to standard
  - compute status vs reference range
  - require user verification
```

### 5.2.1 Canonical Lab Marker Dictionary

> [!IMPORTANT]
> All lab markers must be normalized to a canonical ID before storage. The OCR pipeline uses this dictionary during the "map to canonical marker IDs" step.

**Dictionary structure** (stored in `lab_marker_dictionary` table, cached locally with TTL: 7 days):

| Canonical ID | Display Name (EN) | Display Name (RU) | Aliases | Standard Unit | Reference Range (general adult) |
|---|---|---|---|---|---|
| `tsh` | TSH | ТТГ | Thyroid Stimulating Hormone, Тиреотропный гормон | mIU/L | 0.4 – 4.0 |
| `free_t4` | Free T4 | Свободный Т4 | FT4, Thyroxine Free, Тироксин свободный | pmol/L | 10 – 22 |
| `free_t3` | Free T3 | Свободный Т3 | FT3, Triiodothyronine Free | pmol/L | 3.1 – 6.8 |
| `total_cholesterol` | Total Cholesterol | Общий холестерин | TC, Холестерин общий | mmol/L | < 5.2 |
| `hdl` | HDL Cholesterol | ЛПВП | HDL-C, Холестерин ЛПВП | mmol/L | > 1.0 (M), > 1.2 (F) |
| `ldl` | LDL Cholesterol | ЛПНП | LDL-C, Холестерин ЛПНП | mmol/L | < 3.0 |
| `triglycerides` | Triglycerides | Триглицериды | TG, ТГ | mmol/L | < 1.7 |
| `glucose_fasting` | Fasting Glucose | Глюкоза натощак | Blood Sugar, Сахар крови | mmol/L | 3.9 – 5.6 |
| `hba1c` | HbA1c | Гликированный гемоглобин | Glycated Hemoglobin | % | < 5.7 |
| `hemoglobin` | Hemoglobin | Гемоглобин | Hb, Hgb | g/L | 130-170 (M), 120-150 (F) |
| `ferritin` | Ferritin | Ферритин | — | µg/L | 30-300 (M), 15-150 (F) |
| `iron` | Serum Iron | Железо сыворотки | Fe | µmol/L | 11-30 (M), 9-30 (F) |
| `vitamin_d` | Vitamin D (25-OH) | Витамин D (25-OH) | 25-hydroxyvitamin D, Кальциферол | ng/mL | 30 – 100 |
| `vitamin_b12` | Vitamin B12 | Витамин B12 | Cobalamin, Цианокобаламин | pg/mL | 200 – 900 |
| `creatinine` | Creatinine | Креатинин | — | µmol/L | 62-115 (M), 44-97 (F) |
| `alt` | ALT | АЛТ | Alanine Aminotransferase, SGPT | U/L | < 41 (M), < 33 (F) |
| `ast` | AST | АСТ | Aspartate Aminotransferase, SGOT | U/L | < 40 (M), < 32 (F) |
| `testosterone_total` | Total Testosterone | Тестостерон общий | — | nmol/L | 8.6-29 (M), 0.3-1.7 (F) |
| `cortisol` | Cortisol | Кортизол | — | nmol/L | 138-635 (AM) |
| `crp` | C-Reactive Protein | С-реактивный белок | CRP, СРБ | mg/L | < 5.0 |

**Rules:**
- The OCR pipeline attempts fuzzy matching against all aliases (Levenshtein distance ≤ 2 for short names, ≤ 3 for long names).
- Unknown markers are stored with `canonical_id = NULL` and flagged for user review.
- Unit conversions are applied automatically (e.g., µg/dL → nmol/L for testosterone) using stored conversion factors.
- Reference ranges are sex-dependent where applicable; the system uses `users.sex` to select the correct range.
- The dictionary is maintainable — new markers can be added server-side without app updates.

### 5.3 Trends + Comparisons
- Show trend for each marker
- Identify meaningful changes vs last test
- Provide non-medical context for lifestyle correlation

### 5.4 Safety
- Critical flags always suggest clinician review
- Never provide medication guidance

---

## 6) ECOSYSTEM INTELLIGENCE

### 6.1 Correlation Engine
```yaml
RULES:
  method: Spearman rank correlation (robust to outliers)

  minimum_n:
    actionable: 21       # Minimum for actionable insights shown with normal confidence
    exploratory: 14      # Minimum for exploratory insights (always labeled "preliminary")
    suppressed: "<14"    # Never surface correlations below 14 data points

  time_lags_days: [0, 1, 2] (select best |r| and report lag)

  significance: p < 0.05 (two-tailed) when n >= 21; p < 0.01 when 14 <= n < 21

  confounders:
    always_controlled:
      - day_of_week
      - menstrual_phase (if tracking enabled; null otherwise)
    conditional_controls:
      - training_load_zone:   # Control when analyzing nutrition/sleep correlations
          applies_to: [nutrition_*, sleep_*, supplement_*]
      - sleep_debt_hours:     # Control when analyzing training/nutrition correlations
          applies_to: [training_*, nutrition_*]
      - alcohol_units_48h:    # Control when analyzing HRV/sleep correlations
          applies_to: [hrv_*, sleep_*, recovery_*]
    method: partial Spearman (rank-based partial correlation)
    note: >
      Each analysis selects relevant confounders from the conditional set based on
      the variable pair being tested. This avoids over-controlling (which reduces
      statistical power) while removing the most common spurious associations.

  effect_size:
    metric: Cohen's d (computed from r via d = 2r / sqrt(1 - r²))
    interpretation:
      negligible: "d < 0.2"
      small: "0.2 <= d < 0.5"
      medium: "0.5 <= d < 0.8"
      large: "d >= 0.8"
    rule: >
      Recommendations require at least "small" effect size (d >= 0.2).
      Insights with negligible effect size are never surfaced to the user,
      even if statistically significant.

  confidence_score:
      base = 0.15
      effect = 0.45 * abs(r)
      effect_size_bonus = 0.15 * min(1, cohens_d / 0.8)
      sample = 0.15 * min(1, (n - 21) / 28)
      quality = data_quality_score (0..1)
      confounder_penalty = 0.10 * (1 - partial_r_stability)
        # partial_r_stability = 1 - abs(r_raw - r_partial) / max(abs(r_raw), 0.01)
        # If controlling for confounders significantly changes r, confidence drops
      confidence = clamp((base + effect + effect_size_bonus + sample - confounder_penalty) * quality, 0, 1)

  causal_language:
    - Never use causal language without N-of-1 experiments
    - Use: "associated with", "correlated with", "linked to"
    - Never use: "causes", "leads to", "results in"

  granger_causality (V3+):
    note: >
      Future enhancement: implement Granger causality testing for time-series
      pairs with >= 60 days of data. This will test whether past values of X
      improve prediction of Y beyond Y's own history, providing stronger
      (though still not causal) evidence for directional relationships.
    status: planned
```

### 6.2 Recommendation Structure
```json
{
  "title": "Protein timing opportunity",
  "reason": "Post-workout meal lacked protein and recovery was low",
  "action": "Add 25g protein within 2h of training",
  "confidence": 0.78,
  "effect_size": "medium",
  "cohens_d": 0.62,
  "correlation_r": 0.48,
  "sample_n": 28,
  "confounders_controlled": ["day_of_week", "training_load_zone"],
  "evidence_type": "correlation"
}
```

---

## 7) UX FLOWS (HIGH-LEVEL)

### 7.1 First Week
1. Onboarding: goals, schedule, equipment, diet preferences
2. First food log (photo)
3. First workout log or plan generation
4. Optional supplement stack setup
5. Optional lab scan

### 7.2 Daily Loop
- Morning readiness + plan summary
- Quick add for meals and supplements
- Training prompt based on readiness
- Evening check-in + insights

---

## 8) NON-FUNCTIONAL REQUIREMENTS

```yaml
PERFORMANCE:
  food_photo_analysis: p95 < 5s
  workout_log_submit: p95 < 400ms
  lab_ocr_processing: p95 < 30s (async)

RELIABILITY:
  - graceful fallback to manual entry
  - offline queue for logs
  - conflict resolution by latest edit + user audit trail
```

---

## 9) SUCCESS METRICS

```yaml
CORE:
  - activation: % users who log food + workout within first 7 days
  - retention: weekly active users after 30 days
  - adherence: plan adherence % and supplement adherence %
  - data_quality: % logs verified by user
```

---

## 10) RESOLVED ITEMS (Previously Open)

### 10.1 Evidence Grading Criteria
**Decision:** Use a 4-level evidence grading system aligned with the supplement catalog.

| Level | Label | Criteria |
|-------|-------|----------|
| **Strong** | Backed by multiple RCTs or meta-analyses | ≥ 3 RCTs, consistent results, relevant population |
| **Moderate** | Supported by limited RCTs or observational studies | 1-2 RCTs or large cohort studies |
| **Weak** | Preliminary evidence only | Pilot studies, small samples, animal studies |
| **Anecdotal** | User/community reports only | No published research, N-of-1 only |

**Sources priority:** PubMed, Cochrane, ISSN Position Stands, EFSA opinions. For supplements, Examine.com summaries are acceptable as secondary references. All insight-level claims must cite the underlying correlation statistics (r, p, n, method) per Health Ecosystem §6.1.

### 10.2 Onboarding Questionnaire Length
**Decision:** Maximum **8 screens** for the V1 onboarding flow (target < 90 seconds completion time).

| Screen | Content |
|--------|---------|
| 1 | Welcome + value proposition |
| 2 | Goal selection (single primary goal) |
| 3 | Basic biometrics (sex, height, weight, date of birth) |
| 4 | Activity level (5-level picker) |
| 5 | Health screening flags (cardiac, eating disorder, pregnancy — checkbox list) |
| 6 | Diet preferences (optional, can skip) |
| 7 | HealthKit permission request |
| 8 | Notification preferences + morning brief time |

**Rules:**
- Every screen except #3 must have a "Skip" option.
- Health flags (#5) must include a "None of the above" option to confirm conscious review.
- HealthKit (#7) explains what data is read and why, before the system dialog.
- Progress bar visible on all screens.

### 10.3 Exercise Library Size (V1 Release)
**Decision:** V1 ships with **120–150 exercises** covering the following mandatory categories:

| Category | Min Count | Coverage |
|----------|-----------|----------|
| Strength — Compound | 25 | Squat, deadlift, bench, row, press, pull-up variants |
| Strength — Isolation | 30 | Bicep, tricep, lateral raise, leg curl/extension, etc. |
| Cardio | 15 | Running, cycling, rowing, swimming, HIIT, jump rope, elliptical |
| Mobility/Flexibility | 15 | Yoga poses, stretches, foam rolling, band work |
| Sport | 10 | Boxing, basketball, soccer, tennis, martial arts |
| Bodyweight | 15 | Push-ups, pull-ups, dips, planks, lunges (no equipment) |
| Other | 10 | Miscellaneous + placeholder for user custom |

**Rules:**
- Each exercise has: name, category, primary/secondary muscles, equipment, difficulty, movement pattern.
- Users can create custom exercises (stored as `is_custom = true` in `exercise_catalog`).
- Library is seeded via migration; additions don't require app updates (server-side catalog).

---

## CHANGELOG

### v1.4 (February 12, 2026)
- Closed all open items (Section 10): evidence grading criteria, onboarding questionnaire length, exercise library size
- Open items section renamed to "Resolved Items" with concrete decisions

### v1.3 (February 4, 2026)
- Added CIS-optimized food data strategy reference (Open Food Facts + label OCR fallback + user overrides)
- Expanded meal prep (batch recipes) accuracy model and ground-truth rules
- Updated batch recipe entity definition to match weight-based tracking

### v1.2 (February 4, 2026)
- Added `template` as a Nutrition `input_method` (Quick Add / meal templates)

### v1.1 (February 3, 2026)
- Added explicit user-local diary grouping fields for Nutrition/Training/Supplements logs
