# LIFE OS — SUPABASE API SPECIFICATION

**Version:** 2.3
**Date:** February 12, 2026
**Database:** PostgreSQL 15 (via Supabase)  
**Auth:** Supabase Auth (JWT)

---

## DATABASE SCHEMA

### Prerequisites (run once)

```sql
-- Required for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Generic updated_at trigger helper
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

### Table: `users`

Core user profile data.

```sql
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Auth reference
    auth_id UUID NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Profile
    email TEXT UNIQUE,
    display_name TEXT,
    date_of_birth DATE,
    age_range TEXT CHECK (age_range IN ('under_18', '18_24', '25_34', '35_44', '45_54', '55_64', '65_plus')),
    
    -- Biometrics
    sex TEXT CHECK (sex IN ('male', 'female', 'other')),
    height_cm NUMERIC(5,2),
    weight_kg NUMERIC(5,2),
    
    -- Goals
    primary_goal TEXT CHECK (primary_goal IN ('recovery', 'performance', 'weight', 'general_health')),
    activity_level TEXT CHECK (activity_level IN ('sedentary', 'light', 'moderate', 'active', 'very_active')),
    
    -- Baselines (calculated after 3-7 days)
    baseline_hrv_ms NUMERIC(5,2),
    baseline_rhr_bpm INTEGER,
    baseline_sleep_hours NUMERIC(4,2),
    
    -- Preferences
    timezone TEXT DEFAULT 'UTC',
    units TEXT DEFAULT 'metric' CHECK (units IN ('metric', 'imperial')),
    notification_enabled BOOLEAN DEFAULT TRUE,
    
    -- Metadata
    onboarding_completed BOOLEAN DEFAULT FALSE,
    calibration_days_remaining INTEGER DEFAULT 3,

    -- Account deletion workflow
    deletion_scheduled_at TIMESTAMPTZ,
    deletion_reason TEXT,
    deletion_in_progress BOOLEAN DEFAULT FALSE
);

-- Indexes
CREATE INDEX idx_users_auth_id ON users(auth_id);
CREATE INDEX idx_users_email ON users(email);

-- Trigger for updated_at
CREATE TRIGGER set_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `user_health_flags`

Health screening flags from onboarding (PRD v7.13). Stored **locally by default** for privacy. Only synced to server if user opts in to cloud backup.
**Sync mechanism:** When `cloud_backup_enabled = TRUE` in user settings, the sync engine
includes `user_health_flags` in the pull/push cycle using standard outbox + cursor pattern.
When `cloud_backup_enabled = FALSE` (default), the table is excluded from all sync operations
and data remains in the local GRDB store only. The GET/PATCH endpoints are available for
explicit user-initiated sync but are NOT called automatically.

> [!IMPORTANT]
> These flags affect app behavior (e.g., disableHRV, hideCalories).
> They are **never** used for diagnosis or shared with third parties.

```sql
CREATE TABLE user_health_flags (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Cardiac
    has_cardiac_condition BOOLEAN DEFAULT FALSE,
    has_pacemaker BOOLEAN DEFAULT FALSE,
    on_beta_blockers BOOLEAN DEFAULT FALSE,

    -- Reproductive
    is_pregnant BOOLEAN DEFAULT FALSE,
    menstrual_tracking_enabled BOOLEAN DEFAULT FALSE,

    -- Mental health
    has_eating_disorder_history BOOLEAN DEFAULT FALSE,
    has_chronic_fatigue BOOLEAN DEFAULT FALSE,

    -- App behavior overrides (derived from flags)
    disable_hrv BOOLEAN GENERATED ALWAYS AS (
        has_pacemaker OR has_cardiac_condition
    ) STORED,
    hide_calories BOOLEAN GENERATED ALWAYS AS (
        has_eating_disorder_history
    ) STORED,
    pregnancy_mode BOOLEAN GENERATED ALWAYS AS (
        is_pregnant
    ) STORED
);

CREATE INDEX idx_user_health_flags_user ON user_health_flags(user_id);

CREATE TRIGGER set_user_health_flags_updated_at
    BEFORE UPDATE ON user_health_flags
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

## TIME ZONE + LOCAL DATE MODEL (IMPORTANT)

Life OS stores timestamps as `TIMESTAMPTZ` (UTC) but all diaries and “by day” summaries must group entries by the user’s **local date**.

To avoid off-by-one-day issues around midnight and travel, all diary-relevant logs include an explicit `*_date` column:
- `food_logs.logged_date`
- `supplement_logs.taken_date`
- `workout_sessions.session_date`

To preserve **travel-correct historical time display**, logs may also store:
- `food_logs.logged_timezone`, `food_logs.logged_utc_offset_minutes`
- `supplement_logs.taken_timezone`, `supplement_logs.taken_utc_offset_minutes`
- `workout_sessions.started_timezone`, `workout_sessions.started_utc_offset_minutes`

Other daily tables are already date-based:
- `physiological_states.date`
- `training_loads.date`
- `wellness_checks.date`
- `training_plan_sessions.planned_date`

**Rules:**
1. `users.timezone` must be an IANA timezone string (e.g., `Europe/Moscow`).
2. The client should compute `*_date` from the timestamp in the user’s timezone and send it.
3. If omitted, the server MAY derive it using the user timezone at log time.
4. Diary endpoints treat `*_date` as authoritative; timestamps are used for ordering within a day.
5. The client SHOULD send `*_timezone` + `*_utc_offset_minutes` for travel-correct historical time display.
6. UI should display times using stored timezone/offset when present; fallback to the user’s current timezone.

### Table: `notification_settings`

User-specific notification preferences (source of truth for PRD notification controls).

```sql
CREATE TABLE notification_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Toggles
    morning_brief_enabled BOOLEAN DEFAULT TRUE,
    positive_enabled BOOLEAN DEFAULT TRUE,
    nudges_enabled BOOLEAN DEFAULT TRUE,
    celebration_enabled BOOLEAN DEFAULT TRUE,
    critical_only BOOLEAN DEFAULT FALSE,

    -- Scheduling
    -- Note: TIME columns store wall-clock time in the user's local timezone.
    -- The server MUST combine these with `users.timezone` to compute UTC delivery times.
    -- When the user travels (timezone changes), the Edge Function that schedules
    -- the morning brief must re-resolve against the current `users.timezone`.
    morning_brief_time_local TIME DEFAULT '07:00',
    quiet_hours_start TIME DEFAULT '22:00',
    quiet_hours_end TIME DEFAULT '07:00',

    -- Limits (mirrors PRD defaults)
    max_positive_per_day INTEGER DEFAULT 3 CHECK (max_positive_per_day BETWEEN 0 AND 3),
    max_nudges_per_day INTEGER DEFAULT 2 CHECK (max_nudges_per_day BETWEEN 0 AND 2),
    max_celebration_per_day INTEGER DEFAULT 2 CHECK (max_celebration_per_day BETWEEN 0 AND 2),
    max_total_per_day INTEGER DEFAULT 6 CHECK (max_total_per_day BETWEEN 1 AND 6),

    -- Control level (app authority)
    control_level TEXT NOT NULL DEFAULT 'advisory'
      CHECK (control_level IN ('advisory', 'protective', 'guardian')),
    focus_control_enabled BOOLEAN DEFAULT FALSE,   -- mirrors iOS permission state
    focus_control_last_granted_at TIMESTAMPTZ,

    UNIQUE(user_id)
);

CREATE INDEX idx_notification_settings_user ON notification_settings(user_id);

CREATE TRIGGER set_notification_settings_updated_at
    BEFORE UPDATE ON notification_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

### Table: `physiological_states`

Daily recovery scores and biomarkers.

```sql
CREATE TABLE physiological_states (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Recovery Score Components
    hrv_ms NUMERIC(5,2),                    -- Heart Rate Variability (SDNN from HealthKit, ms)
    hrv_score NUMERIC(5,2),                 -- 0-100, weighted by baseline
    
    resting_heart_rate_bpm INTEGER,
    rhr_score NUMERIC(5,2),                 -- 0-100
    
    wrist_temperature_deviation_c NUMERIC(4,2),  -- °C deviation from personal baseline (Apple Watch provides deviation)
    temp_score NUMERIC(5,2),                -- 0-100
    
    sleep_duration_hours NUMERIC(4,2),
    sleep_quality_percent NUMERIC(5,2),     -- 0-100
    sleep_score NUMERIC(5,2),               -- 0-100
    
    -- Composite
    recovery_score NUMERIC(5,2) NOT NULL,   -- 0-100 (final weighted score)
    -- v7.2: Simplified 4-zone model (was 6 zones before)
    recovery_zone TEXT NOT NULL CHECK (recovery_zone IN ('critical', 'caution', 'ready', 'optimal')),
    -- Optional: Pro/Athlete micro-zone within 'optimal' (NULL if not optimal or micro-zones disabled)
    micro_zone TEXT CHECK (micro_zone IN ('solid', 'strong', 'peak')),
    
    -- Additional biomarkers
    respiratory_rate_bpm NUMERIC(4,2),
    blood_oxygen_percent NUMERIC(5,2),
    
    -- Autonomic balance
    autonomic_state TEXT CHECK (autonomic_state IN ('sympathetic', 'parasympathetic', 'balanced')),
    
    -- Allostatic load (cumulative stress)
    allostatic_load NUMERIC(4,2),           -- 0-10 scale
    
    -- Sleep breakdown
    deep_sleep_percent NUMERIC(5,2),
    rem_sleep_percent NUMERIC(5,2),
    light_sleep_percent NUMERIC(5,2),
    awake_percent NUMERIC(5,2),
    
    -- Activity
    active_calories INTEGER,                -- From workouts
    total_calories INTEGER,                 -- Active + BMR
    steps INTEGER,
    exercise_minutes INTEGER,
    
    -- Metadata
    data_completeness NUMERIC(3,2),         -- 0-1 (how much data we have)
    confidence_score NUMERIC(3,2),          -- 0-1 (how confident in score)
    
    -- Constraints
    UNIQUE(user_id, date)
);

-- Indexes
CREATE INDEX idx_physio_user_date ON physiological_states(user_id, date DESC);
CREATE INDEX idx_physio_recovery_score ON physiological_states(recovery_score);
CREATE INDEX idx_physio_date ON physiological_states(date DESC);

-- Function to calculate recovery zone (v7.2 — 4-zone model)
CREATE OR REPLACE FUNCTION calculate_recovery_zone(score NUMERIC)
RETURNS TEXT AS $$
BEGIN
    RETURN CASE
        WHEN score >= 75 THEN 'optimal'
        WHEN score >= 50 THEN 'ready'
        WHEN score >= 25 THEN 'caution'
        ELSE 'critical'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to calculate optional micro-zone (Pro/Athlete feature)
CREATE OR REPLACE FUNCTION calculate_micro_zone(score NUMERIC)
RETURNS TEXT AS $$
BEGIN
    IF score < 75 THEN
        RETURN NULL;  -- Micro-zones only apply to 'optimal' zone
    END IF;

    RETURN CASE
        WHEN score >= 90 THEN 'peak'
        WHEN score >= 80 THEN 'strong'
        ELSE 'solid'
    END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Trigger to auto-set recovery zone
CREATE OR REPLACE FUNCTION set_recovery_zone()
RETURNS TRIGGER AS $$
BEGIN
    NEW.recovery_zone := calculate_recovery_zone(NEW.recovery_score);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_set_recovery_zone
    BEFORE INSERT OR UPDATE OF recovery_score ON physiological_states
    FOR EACH ROW
    EXECUTE FUNCTION set_recovery_zone();

-- Trigger for updated_at
CREATE TRIGGER set_physiological_states_updated_at
    BEFORE UPDATE ON physiological_states
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `food_logs`

Individual meal entries.

```sql
CREATE TABLE food_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    logged_at TIMESTAMPTZ NOT NULL,         -- When meal was actually eaten
    logged_date DATE NOT NULL,              -- User-local date (authoritative for diaries)
    logged_timezone TEXT,                   -- IANA timezone at log time (travel-correct display)
    logged_utc_offset_minutes INTEGER,      -- UTC offset at log time (minutes)
    
    -- Input method
    input_method TEXT NOT NULL CHECK (input_method IN ('vision', 'barcode', 'batch', 'manual', 'voice', 'template')),
    
    -- Context
    meal_type TEXT CHECK (meal_type IN ('breakfast', 'lunch', 'dinner', 'snack')),
    context TEXT CHECK (context IN ('home', 'restaurant', 'party', 'work', 'other', 'unknown')),
    -- Location is stored only with explicit user opt-in. Default: null (local-only).
    location_lat NUMERIC(10,8),
    location_lng NUMERIC(11,8),
    
    -- Timing context
    pre_workout BOOLEAN DEFAULT FALSE,
    post_workout BOOLEAN DEFAULT FALSE,
    minutes_since_workout INTEGER,
    
    -- Macros
    calories NUMERIC(8,2) NOT NULL,
    protein_g NUMERIC(6,2) NOT NULL,
    fat_g NUMERIC(6,2) NOT NULL,
    carbs_g NUMERIC(6,2) NOT NULL,
    fiber_g NUMERIC(6,2),
    sugar_g NUMERIC(6,2),

    -- Recovery-related inputs
    alcohol_units NUMERIC(4,1),          -- 1 unit = 10g ethanol
    caffeine_mg INTEGER,                 -- Estimated caffeine in mg
    
    -- Micronutrients (optional, for advanced tracking)
    sodium_mg NUMERIC(8,2),
    potassium_mg NUMERIC(8,2),
    calcium_mg NUMERIC(8,2),
    iron_mg NUMERIC(6,2),
    vitamin_d_mcg NUMERIC(6,2),
    vitamin_b12_mcg NUMERIC(6,2),
    
    -- AI data
    image_url TEXT,                         -- Supabase Storage URL
    image_uploaded_at TIMESTAMPTZ,          -- For 90-day retention enforcement
    -- JSON Schema: [{name: string, weight_g: number, calories: number,
    --   protein_g: number, fat_g: number, carbs_g: number,
    --   confidence: number (0-1), category?: string}]
    ai_detected_items JSONB,                -- Array of detected items
    ai_confidence NUMERIC(3,2),             -- 0-1
    ai_context_analysis TEXT,               -- AI's interpretation
    
    -- User feedback
    user_corrected BOOLEAN DEFAULT FALSE,
    user_notes TEXT,
    
    -- AI Feedback (for improving accuracy)
    ai_feedback TEXT CHECK (ai_feedback IN ('accurate', 'slightly_off', 'very_wrong')),
    ai_feedback_details TEXT,              -- What was wrong
    ai_feedback_at TIMESTAMPTZ,
    
    -- Soft Delete (allows undo)
    deleted_at TIMESTAMPTZ,                -- NULL = active, set = deleted
    deleted_reason TEXT CHECK (deleted_reason IN ('user_deleted', 'merged', 'duplicate')),
    
    -- Metadata
    synced_to_vector_db BOOLEAN DEFAULT FALSE,
    vector_id TEXT                          -- Pinecone vector ID
);
-- Vector sync: A scheduled Edge Function (cron: daily 03:00 UTC) processes
-- opt-in sources (food_logs, workout_sessions, health_measurements, body_composition,
-- physiological_states, insights, experiments, supplement_logs, wellness_checks),
-- generates embeddings via OpenRouter text-embedding-3-small, upserts to Pinecone
-- namespace(user_id), then writes/updates vector_memory rows.
-- This is opt-in only (requires user consent for AI memory features).

-- Indexes
CREATE INDEX idx_food_logs_user ON food_logs(user_id, logged_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_food_logs_meal_type ON food_logs(meal_type) WHERE deleted_at IS NULL;
CREATE INDEX idx_food_logs_date ON food_logs(user_id, logged_date DESC) WHERE deleted_at IS NULL;

-- Soft delete index for recovery/undo (last 24 hours)
CREATE INDEX idx_food_logs_recently_deleted 
  ON food_logs(user_id, deleted_at DESC) 
  WHERE deleted_at IS NOT NULL 
    AND deleted_at > NOW() - INTERVAL '24 hours';

-- AI feedback for model improvement
CREATE INDEX idx_food_logs_ai_feedback 
  ON food_logs(ai_feedback, ai_confidence) 
  WHERE ai_feedback IS NOT NULL;

-- Trigger for updated_at
CREATE TRIGGER set_food_logs_updated_at
    BEFORE UPDATE ON food_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- View: Daily nutrition summary (derived)
-- Note: we use a normal VIEW (not a materialized view) to avoid refresh complexity
-- and to keep Row Level Security behavior consistent with food_logs.
CREATE VIEW daily_nutrition_summary AS
SELECT
    user_id,
    logged_date as date,
    SUM(calories) as total_calories,
    SUM(protein_g) as total_protein,
    SUM(fat_g) as total_fat,
    SUM(carbs_g) as total_carbs,
    SUM(fiber_g) as total_fiber,
    SUM(alcohol_units) as alcohol_units,
    SUM(caffeine_mg) as caffeine_mg_total,
    SUM(
      CASE
        WHEN EXTRACT(HOUR FROM (logged_at AT TIME ZONE COALESCE(logged_timezone, 'UTC'))) >= 14
        THEN COALESCE(caffeine_mg, 0)
        ELSE 0
      END
    ) as caffeine_mg_after_14,
    MAX(CASE WHEN COALESCE(caffeine_mg, 0) > 0 THEN logged_at ELSE NULL END) as last_caffeine_at,
    COUNT(*) as meal_count,
    ARRAY_AGG(meal_type ORDER BY logged_at) as meal_sequence
FROM food_logs
WHERE deleted_at IS NULL
GROUP BY user_id, logged_date;
```

---

### Table: `daily_nutrition_targets`

Daily macro targets (base + adjustments from training load and recovery state).

```sql
CREATE TABLE daily_nutrition_targets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL,

    -- Base targets
    base_calories INTEGER,
    base_protein_g INTEGER,
    base_fat_g INTEGER,
    base_carbs_g INTEGER,

    -- Adjustments
    training_adjustment_kcal INTEGER,  -- +/- calories based on training load
    recovery_adjustment_kcal INTEGER,  -- +/- calories based on recovery state

    -- Final targets
    final_calories INTEGER,
    final_protein_g INTEGER,
    final_fat_g INTEGER,
    final_carbs_g INTEGER,

    -- Rationale
    adjustment_reason TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(user_id, date)
);

CREATE INDEX idx_daily_nutrition_targets_user ON daily_nutrition_targets(user_id, date DESC);

CREATE TRIGGER set_daily_nutrition_targets_updated_at
    BEFORE UPDATE ON daily_nutrition_targets
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

**Adjustment formulas (V1):**
- Training adjustment (kcal):
  - `weight_kg` = `getEffectiveWeight(userId).weightKg` *(dynamic weight from body_composition; see recovery_algorithms §27)*
  - **Fallback chain:** (1) Rolling 7-day average from `body_composition` (≥ 2 measurements in 14 days) → (2) Most recent single measurement (< 30 days) → (3) Static `users.weight_kg` from profile. When divergence > 2kg, notify user to update profile.
  - `weight_factor = clamp(weight_kg / 70, 0.75, 1.25)`
  - If `active_energy_kcal` available: `clamp(active_energy_kcal * 0.4 * weight_factor, 0, 600)`
  - Else: `clamp(daily_trimp * 1.3 * weight_factor, 0, 600)`
- Recovery adjustment (macros) — continuous linear interpolation *(see recovery_algorithms §10)*:
  - Recovery 0→50: `protein_delta = lerp(recovery, 0, 50, +0.30, 0) g/kg`, `carb_mult = lerp(0.85, 1.00)`, `cal_mult = lerp(0.95, 1.00)`
  - Recovery 50→100: baseline (no adjustment)
  - *Note: Replaces previous discrete 4-zone step-function to eliminate boundary discontinuities*

---

### Table: `food_catalog_items`

Cached food database items (barcode + search results) normalized into a stable schema.

> [!IMPORTANT]
> Life OS treats the external food database as a **pluggable provider**.  
> This table is a **cache** of items we have looked up (barcode/search), not the full upstream dataset.

```sql
CREATE TABLE food_catalog_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Provider identity (pluggable)
    provider TEXT NOT NULL CHECK (provider IN ('open_food_facts', 'lifeos_label_ocr', 'usda', 'edamam', 'manual_import', 'other')),
    provider_item_id TEXT,
    barcode TEXT,
    created_by_user_id UUID REFERENCES users(id) ON DELETE SET NULL, -- For Life OS OCR-created catalog items
    
    -- Display
    name TEXT NOT NULL,
    brand TEXT,
    locale TEXT,                            -- e.g., "en_US"
    image_url TEXT,
    
    -- Nutrition (normalized)
    serving_size_g NUMERIC(8,2),            -- If known (pack-defined serving)
    calories_per_100g NUMERIC(8,2) NOT NULL,
    protein_per_100g NUMERIC(6,2) NOT NULL,
    fat_per_100g NUMERIC(6,2) NOT NULL,
    carbs_per_100g NUMERIC(6,2) NOT NULL,
    fiber_per_100g NUMERIC(6,2),
    sugar_per_100g NUMERIC(6,2),
    sodium_mg_per_100g NUMERIC(8,2),
    source_confidence NUMERIC(3,2),         -- 0-1 (provider trust or OCR confidence)
    
    -- Cache control
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(provider, provider_item_id),
    UNIQUE(provider, barcode)
);

CREATE INDEX idx_food_catalog_barcode ON food_catalog_items(provider, barcode) WHERE barcode IS NOT NULL;
CREATE INDEX idx_food_catalog_name ON food_catalog_items(name);

CREATE TRIGGER set_food_catalog_items_updated_at
    BEFORE UPDATE ON food_catalog_items
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `user_foods`

User-created custom foods (for reuse and accurate manual logging).

```sql
CREATE TABLE user_foods (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    name TEXT NOT NULL,
    brand TEXT,
    barcode TEXT,                           -- Optional: personal override for barcode scans
    default_serving_g NUMERIC(8,2),
    
    calories_per_100g NUMERIC(8,2) NOT NULL,
    protein_per_100g NUMERIC(6,2) NOT NULL,
    fat_per_100g NUMERIC(6,2) NOT NULL,
    carbs_per_100g NUMERIC(6,2) NOT NULL,
    fiber_per_100g NUMERIC(6,2),
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_foods_user ON user_foods(user_id, created_at DESC);
CREATE INDEX idx_user_foods_name ON user_foods(user_id, name);
CREATE INDEX idx_user_foods_barcode ON user_foods(user_id, barcode) WHERE barcode IS NOT NULL;

-- One barcode override per user (optional)
ALTER TABLE user_foods
  ADD CONSTRAINT user_foods_unique_barcode_per_user UNIQUE (user_id, barcode);

CREATE TRIGGER set_user_foods_updated_at
    BEFORE UPDATE ON user_foods
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `user_food_favorites`

Favorites for fast logging (supports both catalog + custom foods).

```sql
CREATE TABLE user_food_favorites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    ref_type TEXT NOT NULL CHECK (ref_type IN ('catalog', 'custom')),
    ref_id UUID NOT NULL,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, ref_type, ref_id)
);

CREATE INDEX idx_user_food_favorites_user ON user_food_favorites(user_id, created_at DESC);

CREATE TRIGGER set_user_food_favorites_updated_at
    BEFORE UPDATE ON user_food_favorites
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `food_items`

Individual food items within a meal (normalized).

```sql
CREATE TABLE food_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    food_log_id UUID NOT NULL REFERENCES food_logs(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Item details
    name TEXT NOT NULL,
    brand TEXT,
    barcode TEXT,
    catalog_item_id UUID REFERENCES food_catalog_items(id) ON DELETE SET NULL,
    user_food_id UUID REFERENCES user_foods(id) ON DELETE SET NULL,
    batch_recipe_id UUID REFERENCES batch_recipes(id) ON DELETE SET NULL,
    weight_g NUMERIC(8,2) NOT NULL,
    
    -- Macros (per item)
    calories NUMERIC(8,2) NOT NULL,
    protein_g NUMERIC(6,2) NOT NULL,
    fat_g NUMERIC(6,2) NOT NULL,
    carbs_g NUMERIC(6,2) NOT NULL,
    fiber_g NUMERIC(6,2),
    
    -- AI detection
    confidence NUMERIC(3,2),
    detected_by_ai BOOLEAN DEFAULT TRUE,
    
    -- User corrections
    user_adjusted BOOLEAN DEFAULT FALSE,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT food_items_single_ref CHECK (num_nonnulls(catalog_item_id, user_food_id, batch_recipe_id) <= 1)
);

CREATE INDEX idx_food_items_log ON food_items(food_log_id);
CREATE INDEX idx_food_items_user ON food_items(user_id);
CREATE INDEX idx_food_items_name ON food_items(name);
CREATE INDEX idx_food_items_barcode ON food_items(barcode) WHERE barcode IS NOT NULL;
CREATE INDEX idx_food_items_catalog_item ON food_items(catalog_item_id) WHERE catalog_item_id IS NOT NULL;
CREATE INDEX idx_food_items_user_food ON food_items(user_food_id) WHERE user_food_id IS NOT NULL;
CREATE INDEX idx_food_items_batch_recipe ON food_items(batch_recipe_id) WHERE batch_recipe_id IS NOT NULL;

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION set_food_items_user_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        SELECT user_id INTO NEW.user_id FROM food_logs WHERE id = NEW.food_log_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_food_items_user_id
    BEFORE INSERT OR UPDATE OF food_log_id ON food_items
    FOR EACH ROW
    EXECUTE FUNCTION set_food_items_user_id();

CREATE TRIGGER set_food_items_updated_at
    BEFORE UPDATE ON food_items
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `batch_recipes`

User-created batch cooking recipes.

**Consumption tracking (source of truth):**
- A batch is “consumed” when the user logs a `food_item` with `batch_recipe_id = batch_recipes.id`.
- Remaining weight is derived by summing those item weights across **non-deleted** `food_logs`.
- This avoids drift and automatically supports undo (soft delete) of meal logs.

```sql
CREATE TABLE batch_recipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Recipe info
    name TEXT NOT NULL,
    description TEXT,
    image_url TEXT,
    
    -- Batch details
    total_weight_g NUMERIC(8,2) NOT NULL,
    total_portions INTEGER CHECK (total_portions > 0),  -- Optional convenience; logging is always by grams
    weight_per_portion_g NUMERIC(8,2) GENERATED ALWAYS AS (
        CASE WHEN total_portions IS NOT NULL AND total_portions > 0
             THEN total_weight_g / total_portions
             ELSE NULL
        END
    ) STORED,
    
    -- Total macros (entire batch)
    total_calories NUMERIC(8,2) NOT NULL,
    total_protein_g NUMERIC(6,2) NOT NULL,
    total_fat_g NUMERIC(6,2) NOT NULL,
    total_carbs_g NUMERIC(6,2) NOT NULL,
    total_fiber_g NUMERIC(6,2),
    
    -- Per 100g (computed for quick reference)
    calories_per_100g NUMERIC(8,2) GENERATED ALWAYS AS ((total_calories / total_weight_g) * 100) STORED,
    protein_per_100g NUMERIC(6,2) GENERATED ALWAYS AS ((total_protein_g / total_weight_g) * 100) STORED,
    fat_per_100g NUMERIC(6,2) GENERATED ALWAYS AS ((total_fat_g / total_weight_g) * 100) STORED,
    carbs_per_100g NUMERIC(6,2) GENERATED ALWAYS AS ((total_carbs_g / total_weight_g) * 100) STORED,
    
    -- Tracking metadata
    cooked_at DATE,
    
    -- Metadata
    archived BOOLEAN DEFAULT FALSE,
    times_used INTEGER NOT NULL DEFAULT 0,
    last_used_at TIMESTAMPTZ,

    -- Soft delete (undo support)
    deleted_at TIMESTAMPTZ,
    deleted_reason TEXT
);

-- Indexes
CREATE INDEX idx_batch_recipes_user ON batch_recipes(user_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_batch_recipes_active ON batch_recipes(user_id) WHERE NOT archived AND deleted_at IS NULL;

-- Trigger for updated_at
CREATE TRIGGER set_batch_recipes_updated_at
    BEFORE UPDATE ON batch_recipes
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `batch_recipe_ingredients`

Ingredients for batch recipes.

```sql
CREATE TABLE batch_recipe_ingredients (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_recipe_id UUID NOT NULL REFERENCES batch_recipes(id) ON DELETE CASCADE,
    
    name TEXT NOT NULL,
    brand TEXT,
    barcode TEXT,
    catalog_item_id UUID REFERENCES food_catalog_items(id) ON DELETE SET NULL,
    user_food_id UUID REFERENCES user_foods(id) ON DELETE SET NULL,
    weight_g NUMERIC(8,2) NOT NULL,
    calories NUMERIC(8,2) NOT NULL,
    protein_g NUMERIC(6,2) NOT NULL,
    fat_g NUMERIC(6,2) NOT NULL,
    carbs_g NUMERIC(6,2) NOT NULL,
    fiber_g NUMERIC(6,2),
    sugar_g NUMERIC(6,2),
    sodium_mg NUMERIC(8,2),
    
    sort_order INTEGER DEFAULT 0,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT batch_ingredients_single_ref CHECK (NOT (catalog_item_id IS NOT NULL AND user_food_id IS NOT NULL))
);

CREATE INDEX idx_batch_ingredients ON batch_recipe_ingredients(batch_recipe_id, sort_order);
CREATE INDEX idx_batch_ingredients_barcode ON batch_recipe_ingredients(barcode) WHERE barcode IS NOT NULL;
CREATE INDEX idx_batch_ingredients_catalog_item ON batch_recipe_ingredients(catalog_item_id) WHERE catalog_item_id IS NOT NULL;
CREATE INDEX idx_batch_ingredients_user_food ON batch_recipe_ingredients(user_food_id) WHERE user_food_id IS NOT NULL;

-- Trigger for updated_at
CREATE TRIGGER set_batch_recipe_ingredients_updated_at
    BEFORE UPDATE ON batch_recipe_ingredients
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `meal_templates`

Reusable meal templates for one-tap logging (Quick Add).

```sql
CREATE TABLE meal_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    name TEXT NOT NULL,
    meal_type TEXT CHECK (meal_type IN ('breakfast', 'lunch', 'dinner', 'snack')),
    
    -- Snapshot of items at the time the template was created (avoid hidden drift)
    -- Shape: array of {name, brand?, barcode?, catalog_item_id?, user_food_id?, weight_g, macros...}
    template_items JSONB NOT NULL,
    
    -- Totals for quick list display
    calories NUMERIC(8,2) NOT NULL,
    protein_g NUMERIC(6,2) NOT NULL,
    fat_g NUMERIC(6,2) NOT NULL,
    carbs_g NUMERIC(6,2) NOT NULL,
    fiber_g NUMERIC(6,2),
    
    times_used INTEGER DEFAULT 0,
    last_used_at TIMESTAMPTZ,
    archived BOOLEAN DEFAULT FALSE,

    -- Soft delete (undo support)
    deleted_at TIMESTAMPTZ,
    deleted_reason TEXT
);

CREATE INDEX idx_meal_templates_user ON meal_templates(user_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_meal_templates_active ON meal_templates(user_id) WHERE archived = FALSE AND deleted_at IS NULL;
CREATE INDEX idx_meal_templates_last_used ON meal_templates(user_id, last_used_at DESC);

CREATE TRIGGER set_meal_templates_updated_at
    BEFORE UPDATE ON meal_templates
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `supplement_catalog`

Master list of common supplements (reference data only).

> [!IMPORTANT]
> This catalog MUST NOT contain dosing or medical guidance.  
> All dosing is user‑entered and stored only in `user_supplements` / `supplement_logs`.

```sql
CREATE TABLE supplement_catalog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    category TEXT NOT NULL CHECK (category IN (
        'vitamin', 'mineral', 'amino_acid', 'herbal', 
        'probiotic', 'omega', 'nootropic', 'performance', 'other'
    )),
    description TEXT,
    
    -- Timing recommendations
    best_time TEXT CHECK (best_time IN ('morning', 'with_food', 'before_bed', 'empty_stomach', 'any')),
    take_with_food BOOLEAN DEFAULT FALSE,
    
    -- Research backing
    evidence_level TEXT CHECK (evidence_level IN ('strong', 'moderate', 'weak', 'anecdotal')),
    primary_benefits TEXT[],
    
    -- Interactions
    avoid_with TEXT[],  -- Other supplements to avoid combining
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Trigger for updated_at
CREATE TRIGGER set_supplement_catalog_updated_at
    BEFORE UPDATE ON supplement_catalog
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Seed with common supplements
INSERT INTO supplement_catalog (name, category, best_time, take_with_food, evidence_level, primary_benefits) VALUES
('Magnesium Glycinate', 'mineral', 'before_bed', false, 'strong', ARRAY['sleep', 'recovery', 'stress']),
('Vitamin D3', 'vitamin', 'with_food', true, 'strong', ARRAY['immune', 'mood', 'bone_health']),
('Omega-3 Fish Oil', 'omega', 'with_food', true, 'strong', ARRAY['inflammation', 'heart', 'brain']),
('Creatine Monohydrate', 'performance', 'any', false, 'strong', ARRAY['strength', 'power', 'brain']),
('Ashwagandha', 'herbal', 'any', true, 'moderate', ARRAY['stress', 'anxiety', 'recovery']),
('L-Theanine', 'amino_acid', 'any', false, 'moderate', ARRAY['focus', 'calm', 'sleep']),
('Zinc', 'mineral', 'with_food', true, 'strong', ARRAY['immune', 'recovery']),
('B-Complex', 'vitamin', 'morning', true, 'moderate', ARRAY['energy', 'metabolism', 'nerve_health']),
('Probiotics', 'probiotic', 'morning', false, 'moderate', ARRAY['gut_health', 'immune', 'digestion']);
```

---

### Table: `user_supplements`

User's supplement stack (what they take regularly).

> [!IMPORTANT]
> All doses are **user‑entered**. The app must not prescribe or adjust supplement dosages.

```sql
CREATE TABLE user_supplements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Can reference catalog or be custom
    catalog_id UUID REFERENCES supplement_catalog(id) ON DELETE SET NULL,
    custom_name TEXT,  -- If not from catalog
    
    -- User-entered dosage (not prescribed by Life OS)
    dose_amount NUMERIC(10,2),
    dose_unit TEXT DEFAULT 'mg',
    CONSTRAINT user_dose_positive CHECK (dose_amount IS NULL OR dose_amount > 0),
    
    -- Schedule
    frequency TEXT NOT NULL CHECK (frequency IN ('daily', 'twice_daily', 'weekly', 'as_needed')),
    scheduled_times TIME[],  -- e.g., ['08:00', '20:00']
    days_of_week INTEGER[],  -- 0=Sun, 6=Sat (null = every day)
    
    -- Context
    take_with_food BOOLEAN DEFAULT FALSE,
    notes TEXT,
    
    -- Status
    active BOOLEAN DEFAULT TRUE,
    started_at DATE NOT NULL DEFAULT CURRENT_DATE,
    ended_at DATE,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT name_required CHECK (catalog_id IS NOT NULL OR custom_name IS NOT NULL)
);

CREATE INDEX idx_user_supplements_active ON user_supplements(user_id) WHERE active = TRUE;
CREATE INDEX idx_user_supplements_schedule ON user_supplements(user_id, scheduled_times);

-- Trigger for updated_at
CREATE TRIGGER set_user_supplements_updated_at
    BEFORE UPDATE ON user_supplements
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `supplement_logs`

Individual supplement intake logs (user-entered).

```sql
CREATE TABLE supplement_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_supplement_id UUID REFERENCES user_supplements(id) ON DELETE SET NULL,
    
    taken_at TIMESTAMPTZ NOT NULL,
    taken_date DATE NOT NULL,               -- User-local date (authoritative for diaries)
    taken_timezone TEXT,                    -- IANA timezone at intake time (travel-correct display)
    taken_utc_offset_minutes INTEGER,       -- UTC offset at intake time (minutes)
    
    -- Can log without user_supplement reference
    supplement_name TEXT NOT NULL,
    dose_amount NUMERIC(10,2),
    dose_unit TEXT DEFAULT 'mg',
    CONSTRAINT dose_positive CHECK (dose_amount IS NULL OR dose_amount > 0),
    
    -- Context
    with_food BOOLEAN,
    notes TEXT,
    
    -- For reminders
    was_scheduled BOOLEAN DEFAULT FALSE,
    scheduled_time TIME,
    
    -- Subjective tracking (optional)
    felt_effect TEXT CHECK (felt_effect IN ('positive', 'negative', 'neutral', 'none')),

    -- Soft delete (undo support)
    deleted_at TIMESTAMPTZ,                -- NULL = active, set = deleted
    deleted_reason TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_supplement_logs_user ON supplement_logs(user_id, taken_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_supplement_logs_date ON supplement_logs(user_id, taken_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_supplement_logs_effect ON supplement_logs(supplement_name, felt_effect) WHERE felt_effect IS NOT NULL;

-- Trigger for updated_at
CREATE TRIGGER set_supplement_logs_updated_at
    BEFORE UPDATE ON supplement_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `wellness_checks`

Daily morning wellness questionnaire (self-reported data).

```sql
CREATE TABLE wellness_checks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    date DATE NOT NULL,

    -- Core wellness scores (1-5 scale)
    perceived_sleep_quality INTEGER CHECK (perceived_sleep_quality BETWEEN 1 AND 5),
    energy_level INTEGER CHECK (energy_level BETWEEN 1 AND 5),
    muscle_soreness INTEGER CHECK (muscle_soreness BETWEEN 1 AND 5), -- 5 = very sore
    stress_level INTEGER CHECK (stress_level BETWEEN 1 AND 5),
    mood INTEGER CHECK (mood BETWEEN 1 AND 5),

    -- PSS-4: Perceived Stress Scale (validated 4-item version)
    -- Reference: Cohen, S. et al. (1983). "A Global Measure of Perceived Stress."
    -- J Health Soc Behav, 24:385-396. DOI: 10.2307/2136404
    -- Each item 0-4 scale (0=Never, 1=Almost Never, 2=Sometimes, 3=Fairly Often, 4=Very Often)
    pss4_q1 INTEGER CHECK (pss4_q1 BETWEEN 0 AND 4), -- "Unable to control important things"
    pss4_q2 INTEGER CHECK (pss4_q2 BETWEEN 0 AND 4), -- "Confident about handling problems" (reverse scored)
    pss4_q3 INTEGER CHECK (pss4_q3 BETWEEN 0 AND 4), -- "Things going your way" (reverse scored)
    pss4_q4 INTEGER CHECK (pss4_q4 BETWEEN 0 AND 4), -- "Difficulties piling up"
    pss4_total INTEGER GENERATED ALWAYS AS (
        COALESCE(pss4_q1, 0) +
        (4 - COALESCE(pss4_q2, 0)) +  -- Reverse score
        (4 - COALESCE(pss4_q3, 0)) +  -- Reverse score
        COALESCE(pss4_q4, 0)
    ) STORED,  -- Range 0-16, higher = more stressed

    -- Illness flags
    feeling_ill BOOLEAN DEFAULT FALSE,
    headache BOOLEAN DEFAULT FALSE,
    digestive_issues BOOLEAN DEFAULT FALSE,

    -- Notes
    notes TEXT,

    -- Menstrual data is on-device only by default (never stored server-side)

    -- Computed wellness score (calculated from inputs)
    wellness_score NUMERIC(5,2),

    -- Mental health resource flag (triggered when stress is high for extended period)
    mental_health_resources_shown BOOLEAN DEFAULT FALSE,

    -- Soft delete (undo support)
    deleted_at TIMESTAMPTZ,

    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE(user_id, date)
);

-- PSS-4 Interpretation
COMMENT ON COLUMN wellness_checks.pss4_total IS
    'PSS-4 Total Score (0-16). Interpretation: 0-4=Low stress, 5-8=Moderate stress, 9-12=High stress, 13-16=Very high stress';

CREATE INDEX idx_wellness_checks_user ON wellness_checks(user_id, date DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_wellness_checks_score ON wellness_checks(wellness_score);

-- Trigger for updated_at
CREATE TRIGGER set_wellness_checks_updated_at
    BEFORE UPDATE ON wellness_checks
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `body_composition`

Bioimpedance data from smart scales (optional, synced via HealthKit).

```sql
CREATE TABLE body_composition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    measured_at TIMESTAMPTZ NOT NULL,
    
    -- Input type
    input_type TEXT CHECK (input_type IN ('home_scale', 'professional_report')),
    
    -- Core metrics
    weight_kg NUMERIC(5,2) NOT NULL,
    body_fat_percent NUMERIC(4,2),
    muscle_mass_kg NUMERIC(5,2),
    water_percent NUMERIC(4,2),
    bone_mass_kg NUMERIC(4,2),
    visceral_fat_level INTEGER,      -- Typically 1-20
    metabolic_age INTEGER,
    
    -- Additional metrics
    bmi NUMERIC(4,2),
    bmr_kcal INTEGER,
    protein_kg NUMERIC(4,2),
    minerals_kg NUMERIC(4,2),
    skeletal_muscle_percent NUMERIC(4,2),
    
    -- Derived
    lean_body_mass_kg NUMERIC(5,2),
    fat_mass_kg NUMERIC(5,2),
    
    -- Professional report extras
    fitness_score INTEGER,            -- InBody Score (0-100)
    waist_hip_ratio NUMERIC(4,2),
    
    -- Weight control (from InBody)
    target_weight_kg NUMERIC(5,2),
    weight_control_kg NUMERIC(5,2),   -- Negative = to lose
    fat_control_kg NUMERIC(5,2),
    muscle_control_kg NUMERIC(5,2),
    
    -- Segmental Lean Analysis (JSONB for flexibility)
    segmental_lean JSONB,             -- {right_arm, left_arm, trunk, right_leg, left_leg}
    -- Example: {"right_arm": {"value": 4.31, "percent": 121.0}, ...}
    
    -- Segmental Fat Analysis (JSONB for flexibility)
    segmental_fat JSONB,              -- Same structure as segmental_lean
    
    -- Impedance data (professional only)
    impedance_data JSONB,             -- {20kHz: {...}, 100kHz: {...}}
    
    -- Data source
    source TEXT CHECK (source IN ('healthkit', 'manual', 'photo_scan', 'withings', 'renpho', 'xiaomi', 'tanita', 'garmin', 'inbody', 'seca', 'dexa', 'other')),
    device_name TEXT,
    report_date DATE,                 -- Date printed on report
    
    -- Photo scan data (when source = 'photo_scan')
    scan_image_url TEXT,              -- Supabase Storage URL
    ai_extraction_raw JSONB,          -- Full AI response for debugging
    ai_confidence NUMERIC(3,2),       -- Overall extraction confidence (0-1)
    user_corrected BOOLEAN DEFAULT FALSE,  -- Did user edit AI-extracted values?
    
    -- Comparison tracking
    previous_measurement_id UUID REFERENCES body_composition(id),
    
    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at TIMESTAMPTZ                -- NULL = active, set = soft-deleted
);

CREATE INDEX idx_body_comp_user ON body_composition(user_id, measured_at DESC);
CREATE INDEX idx_body_comp_weight ON body_composition(user_id, weight_kg);
CREATE INDEX idx_body_comp_source ON body_composition(source);
CREATE INDEX idx_body_comp_type ON body_composition(input_type);

-- Trigger for updated_at
CREATE TRIGGER set_body_composition_updated_at
    BEFORE UPDATE ON body_composition
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `hydration_logs`

Water intake logs (manual or wearable-imported). Used by recovery algorithms.

```sql
CREATE TABLE hydration_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    logged_at TIMESTAMPTZ NOT NULL,
    logged_date DATE NOT NULL,              -- User-local date (authoritative for diaries)
    logged_timezone TEXT,                   -- IANA timezone at log time
    logged_utc_offset_minutes INTEGER,      -- UTC offset at log time (minutes)

    water_ml INTEGER NOT NULL CHECK (water_ml BETWEEN 1 AND 5000),
    source TEXT NOT NULL CHECK (source IN ('manual', 'wearable', 'import', 'other')),
    notes TEXT,

    -- Soft delete (undo support)
    deleted_at TIMESTAMPTZ,
    deleted_reason TEXT CHECK (deleted_reason IN ('user_deleted', 'duplicate')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_hydration_logs_user ON hydration_logs(user_id, logged_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_hydration_logs_date ON hydration_logs(user_id, logged_date DESC) WHERE deleted_at IS NULL;

CREATE TRIGGER set_hydration_logs_updated_at
    BEFORE UPDATE ON hydration_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `training_loads`

Daily training load calculations (TRIMP, ACWR).

```sql
CREATE TABLE training_loads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    
    -- Daily load (from workouts)
    daily_trimp NUMERIC(8,2),        -- Training Impulse
    daily_duration_minutes INTEGER,
    daily_active_calories INTEGER,
    workout_count INTEGER DEFAULT 0,

    -- Optional heart-rate summary (when available)
    avg_heart_rate_bpm INTEGER,
    peak_heart_rate_bpm INTEGER,
    
    -- Optional heart-rate zone distribution (minutes)
    zone1_minutes INTEGER DEFAULT 0, -- Recovery <60% HRmax
    zone2_minutes INTEGER DEFAULT 0, -- Aerobic 60-70%
    zone3_minutes INTEGER DEFAULT 0, -- Tempo 70-80%
    zone4_minutes INTEGER DEFAULT 0, -- Threshold 80-90%
    zone5_minutes INTEGER DEFAULT 0, -- Max >90%
    
    -- Rolling averages (EWMA methodology — Williams et al., 2017)
    acute_load_7d NUMERIC(8,2),      -- 7-day EWMA
    chronic_load_28d NUMERIC(8,2),   -- 28-day EWMA
    acwr NUMERIC(4,2),               -- Acute:Chronic Workload Ratio

    -- EWMA parameters for reproducibility (DOI: 10.1136/bjsports-2016-096589)
    ewma_lambda_acute NUMERIC(4,3) DEFAULT 0.25,   -- λ = 2/(7+1) for 7-day
    ewma_lambda_chronic NUMERIC(4,3) DEFAULT 0.069, -- λ = 2/(28+1) for 28-day
    
    -- Training state
    training_zone TEXT CHECK (training_zone IN ('undertraining', 'optimal', 'overreaching', 'injury_risk')),
    weekly_trend TEXT CHECK (weekly_trend IN ('increasing', 'stable', 'decreasing')),
    
    -- Monotony and strain (Banister model)
    monotony_7d NUMERIC(4,2),        -- Training monotony
    strain_7d NUMERIC(8,2),          -- Monotony × Load
    
    -- Fitness and fatigue (Impulse-Response model)
    fitness_ctl NUMERIC(8,2),        -- Chronic Training Load
    fatigue_atl NUMERIC(8,2),        -- Acute Training Load
    form_tsb NUMERIC(8,2),           -- Training Stress Balance
    
    -- Metadata
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(user_id, date)
);

CREATE INDEX idx_training_loads_user ON training_loads(user_id, date DESC);
CREATE INDEX idx_training_loads_acwr ON training_loads(acwr);
CREATE INDEX idx_training_loads_zone ON training_loads(training_zone);

-- Trigger for updated_at
CREATE TRIGGER set_training_loads_updated_at
    BEFORE UPDATE ON training_loads
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `exercise_catalog`

System-wide exercise library with optional user-created entries.

```sql
CREATE TABLE exercise_catalog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    category TEXT NOT NULL CHECK (category IN ('strength', 'cardio', 'mobility', 'sport', 'other')),
    
    -- Targeting
    primary_muscles TEXT[] NOT NULL DEFAULT '{}',
    secondary_muscles TEXT[] NOT NULL DEFAULT '{}',
    equipment TEXT[] NOT NULL DEFAULT '{}',
    movement_pattern TEXT,                  -- e.g., "push", "pull", "hinge"
    unilateral BOOLEAN DEFAULT FALSE,
    difficulty TEXT CHECK (difficulty IN ('beginner', 'intermediate', 'advanced')),
    
    -- Coaching
    instructions TEXT,
    video_url TEXT,
    
    -- Custom exercises
    is_custom BOOLEAN DEFAULT FALSE,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_exercise_catalog_name ON exercise_catalog(name);
CREATE INDEX idx_exercise_catalog_category ON exercise_catalog(category);
CREATE INDEX idx_exercise_catalog_muscles ON exercise_catalog USING GIN(primary_muscles);

CREATE TRIGGER set_exercise_catalog_updated_at
    BEFORE UPDATE ON exercise_catalog
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `training_plans`

AI-generated or user-created training plans with adaptive rules.

```sql
CREATE TABLE training_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    name TEXT NOT NULL,
    goal TEXT NOT NULL CHECK (goal IN ('strength', 'hypertrophy', 'endurance', 'weight_loss', 'sport_specific', 'general_fitness')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'completed', 'archived')),
    
    start_date DATE,
    end_date DATE,
    duration_weeks INTEGER,
    days_per_week INTEGER,
    current_week INTEGER DEFAULT 1,
    
    ai_generated BOOLEAN DEFAULT FALSE,
    plan_json JSONB NOT NULL,               -- Full plan structure
    adaptive_rules JSONB,                   -- Adjustment rules for recovery and load
    
    last_adjusted_at TIMESTAMPTZ,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_training_plans_user ON training_plans(user_id, created_at DESC);
CREATE INDEX idx_training_plans_status ON training_plans(user_id, status);

CREATE TRIGGER set_training_plans_updated_at
    BEFORE UPDATE ON training_plans
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

**Adaptive Rules (JSONB) — Enum Contract**

`training_plans.adaptive_rules` stores a map of `reason -> adjustment` and MUST use the enums below.

**Valid `reason` values:**
- `recovery_low`
- `recovery_critical`
- `fatigue_accumulation`
- `injury_flag`
- `user_request`
- `schedule_conflict`
- `load_spike_acwr`

**Valid `adjustment` values:**
- `reduce_volume_30`
- `reduce_intensity_20`
- `skip_session`
- `swap_to_mobility`
- `extend_rest_day`
- `deload_week`

Example:
```json
{ "recovery_low": "reduce_volume_30", "load_spike_acwr": "deload_week" }
```

---

### Table: `workout_sessions`

Workout session logs (manual or wearable-imported).

```sql
CREATE TABLE workout_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    started_at TIMESTAMPTZ NOT NULL,
    session_date DATE NOT NULL,              -- User-local date (authoritative for diaries)
    started_timezone TEXT,                   -- IANA timezone at start time (travel-correct display)
    started_utc_offset_minutes INTEGER,      -- UTC offset at start time (minutes)
    ended_at TIMESTAMPTZ,
    duration_minutes INTEGER,
    
    source TEXT NOT NULL CHECK (source IN ('manual', 'wearable', 'plan', 'import')),
    import_provider TEXT CHECK (import_provider IN ('healthkit', 'strava', 'garmin', 'other')),
    import_source_id TEXT,                   -- External stable ID (e.g., HKWorkout UUID) for de-dupe
    workout_type TEXT CHECK (workout_type IN ('strength', 'cardio', 'mobility', 'mixed', 'sport', 'other')),
    location TEXT CHECK (location IN ('home', 'gym', 'outdoor', 'studio', 'other')),
    
    -- Pre-workout state
    pre_recovery_score NUMERIC(5,2),
    pre_energy_level INTEGER CHECK (pre_energy_level BETWEEN 1 AND 5),
    
    -- Session aggregates
    total_volume NUMERIC(10,2),
    total_sets INTEGER,
    total_reps INTEGER,
    estimated_calories INTEGER,
    trimp_score NUMERIC(8,2),
    perceived_exertion_rpe INTEGER CHECK (perceived_exertion_rpe BETWEEN 1 AND 10),
    
    -- Post-workout
    post_feeling INTEGER CHECK (post_feeling BETWEEN 1 AND 5),
    notes TEXT,

    -- Soft Delete (allows undo; required for import/manual conflict resolution UX)
    deleted_at TIMESTAMPTZ,                -- NULL = active, set = deleted
    deleted_reason TEXT CHECK (deleted_reason IN ('user_deleted', 'merged', 'duplicate')),
    
    -- Plan linkage
    training_plan_id UUID REFERENCES training_plans(id) ON DELETE SET NULL,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_workout_sessions_user ON workout_sessions(user_id, started_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_workout_sessions_date ON workout_sessions(user_id, session_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_workout_sessions_type ON workout_sessions(workout_type);
CREATE INDEX idx_workout_sessions_plan ON workout_sessions(training_plan_id);
CREATE INDEX idx_workout_sessions_import ON workout_sessions(user_id, import_provider, import_source_id) WHERE import_source_id IS NOT NULL;

-- Soft delete index for undo (last 24 hours)
CREATE INDEX idx_workout_sessions_recently_deleted 
  ON workout_sessions(user_id, deleted_at DESC) 
  WHERE deleted_at IS NOT NULL 
    AND deleted_at > NOW() - INTERVAL '24 hours';

CREATE TRIGGER set_workout_sessions_updated_at
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `workout_exercises`

Exercises within a workout session.

```sql
CREATE TABLE workout_exercises (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES workout_sessions(id) ON DELETE CASCADE,
    exercise_id UUID REFERENCES exercise_catalog(id) ON DELETE SET NULL,
    
    order_in_session INTEGER,
    total_sets INTEGER,
    total_reps INTEGER,
    total_volume NUMERIC(10,2),
    max_weight NUMERIC(8,2),
    duration_seconds INTEGER,
    notes TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_workout_exercises_session ON workout_exercises(session_id, order_in_session);
CREATE INDEX idx_workout_exercises_exercise ON workout_exercises(exercise_id);

CREATE TRIGGER set_workout_exercises_updated_at
    BEFORE UPDATE ON workout_exercises
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `workout_sets`

Sets within an exercise.

```sql
CREATE TABLE workout_sets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exercise_entry_id UUID NOT NULL REFERENCES workout_exercises(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    set_number INTEGER NOT NULL,
    weight NUMERIC(8,2),
    reps INTEGER,
    rpe INTEGER CHECK (rpe BETWEEN 1 AND 10),
    tempo TEXT,                             -- "3-1-2-1"
    
    is_warmup BOOLEAN DEFAULT FALSE,
    is_failure BOOLEAN DEFAULT FALSE,
    is_dropset BOOLEAN DEFAULT FALSE,
    
    rest_after_seconds INTEGER,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_workout_sets_exercise ON workout_sets(exercise_entry_id, set_number);
CREATE INDEX idx_workout_sets_user ON workout_sets(user_id);

CREATE OR REPLACE FUNCTION set_workout_sets_user_id()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        SELECT ws.user_id INTO NEW.user_id
        FROM workout_sessions ws
        JOIN workout_exercises we ON we.session_id = ws.id
        WHERE we.id = NEW.exercise_entry_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_workout_sets_user_id
    BEFORE INSERT OR UPDATE OF exercise_entry_id ON workout_sets
    FOR EACH ROW
    EXECUTE FUNCTION set_workout_sets_user_id();

CREATE TRIGGER set_workout_sets_updated_at
    BEFORE UPDATE ON workout_sets
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `training_plan_sessions`

Planned sessions for a training plan (calendar view + adherence).

```sql
CREATE TABLE training_plan_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    training_plan_id UUID NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    planned_date DATE NOT NULL,
    session_type TEXT NOT NULL CHECK (session_type IN ('strength', 'cardio', 'mobility', 'mixed', 'recovery')),
    planned_duration_minutes INTEGER,
    
    planned_exercises JSONB,                -- Array of exercises with sets/reps/targets
    
    status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'completed', 'skipped', 'rescheduled')),
    actual_session_id UUID REFERENCES workout_sessions(id) ON DELETE SET NULL,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(training_plan_id, planned_date, session_type)
);

CREATE INDEX idx_training_plan_sessions_user ON training_plan_sessions(user_id, planned_date DESC);
CREATE INDEX idx_training_plan_sessions_plan ON training_plan_sessions(training_plan_id);
CREATE INDEX idx_training_plan_sessions_status ON training_plan_sessions(user_id, status);

CREATE TRIGGER set_training_plan_sessions_updated_at
    BEFORE UPDATE ON training_plan_sessions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Menstrual Cycle Data (On-Device Only)

Menstrual cycle data is **processed on-device by default** and is not stored server-side.  
If the user opts in, the client may send a **derived, non-identifying feature** (e.g., `menstrual_phase` or a boolean adjustment flag) strictly for recovery scoring.

**Server policy:**
- Never store raw cycle dates or symptoms in the cloud
- Only accept optional derived fields from authenticated clients
- All menstrual features must be user-controlled and revocable

---

### Table: `experiments`

N-of-1 scientific experiments.

```sql
CREATE TABLE experiments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Experiment design
    title TEXT NOT NULL,
    hypothesis TEXT NOT NULL,
    variable TEXT NOT NULL,                 -- What's being changed
    control_description TEXT,               -- Baseline behavior
    intervention_description TEXT,          -- What to do differently
    
    -- Timeline
    status TEXT NOT NULL DEFAULT 'design' CHECK (status IN ('design', 'baseline', 'intervention', 'washout', 'completed', 'abandoned')),
    
    baseline_start_date DATE,
    baseline_end_date DATE,
    baseline_duration_days INTEGER,
    
    intervention_start_date DATE,
    intervention_end_date DATE,
    intervention_duration_days INTEGER,
    
    washout_start_date DATE,
    washout_end_date DATE,
    washout_duration_days INTEGER,
    
    -- Metrics to track
    primary_metric TEXT NOT NULL,           -- e.g., "sleep_quality"
    secondary_metrics TEXT[],               -- e.g., ["hrv", "energy_level"]
    
    -- Data collection
    measurement_frequency TEXT CHECK (measurement_frequency IN ('daily', 'twice_daily', 'weekly')),
    reminder_time TIME,
    
    -- Results (filled after completion)
    baseline_mean NUMERIC(10,4),
    baseline_std_dev NUMERIC(10,4),
    intervention_mean NUMERIC(10,4),
    intervention_std_dev NUMERIC(10,4),
    
    effect_size NUMERIC(10,4),              -- Cohen's d
    p_value NUMERIC(10,8),                  -- Statistical significance
    confidence_interval_lower NUMERIC(10,4),
    confidence_interval_upper NUMERIC(10,4),
    
    significant BOOLEAN,
    effect_direction TEXT CHECK (effect_direction IN ('positive', 'negative', 'neutral')),
    
    -- AI analysis
    ai_interpretation TEXT,
    ai_recommendation TEXT,
    
    -- User notes
    user_notes TEXT,
    compliance_percent NUMERIC(5,2),        -- % of days followed protocol

    -- Soft delete (undo support)
    deleted_at TIMESTAMPTZ,                -- NULL = active, set = deleted
    deleted_reason TEXT CHECK (deleted_reason IN ('user_deleted', 'merged', 'duplicate'))
);

-- Indexes
CREATE INDEX idx_experiments_user ON experiments(user_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_experiments_status ON experiments(status) WHERE deleted_at IS NULL;
CREATE INDEX idx_experiments_active ON experiments(user_id, status) WHERE status IN ('baseline', 'intervention', 'washout') AND deleted_at IS NULL;

-- Trigger for updated_at
CREATE TRIGGER set_experiments_updated_at
    BEFORE UPDATE ON experiments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `experiment_measurements`

Daily measurements during experiments.

```sql
CREATE TABLE experiment_measurements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id UUID NOT NULL REFERENCES experiments(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    measurement_date DATE NOT NULL,
    measurement_phase TEXT NOT NULL CHECK (measurement_phase IN ('baseline', 'intervention', 'washout')),
    
    -- Metric values
    metric_name TEXT NOT NULL,
    metric_value NUMERIC(10,4) NOT NULL,
    metric_unit TEXT,
    
    -- Compliance
    protocol_followed BOOLEAN DEFAULT TRUE,
    notes TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    UNIQUE(experiment_id, measurement_date, metric_name)
);

CREATE INDEX idx_experiment_measurements ON experiment_measurements(experiment_id, measurement_phase, measurement_date);

-- Trigger for updated_at
CREATE TRIGGER set_experiment_measurements_updated_at
    BEFORE UPDATE ON experiment_measurements
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `insights`

AI-generated insights and correlations.

```sql
-- Shared metric vocabulary for insights/recommendations
CREATE TYPE metric_key AS ENUM (
  'recovery_score',
  'hrv_ms',
  'rhr_bpm',
  'wrist_temperature_deviation_c',
  'sleep_duration_hours',
  'sleep_quality_percent',
  'sleep_efficiency_percent',
  'deep_sleep_percent',
  'rem_sleep_percent',
  'awake_percent',
  'training_trimp',
  'acwr',
  'active_energy_kcal',
  'calories',
  'protein_g',
  'carbs_g',
  'fat_g',
  'fiber_g',
  'sugar_g',
  'alcohol_units',
  'caffeine_mg',
  'hydration_ml',
  'stress_level',
  'energy_level',
  'muscle_soreness'
);
```

```sql
CREATE TABLE insights (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Insight type
    type TEXT NOT NULL CHECK (type IN ('pattern', 'correlation', 'trend', 'anomaly', 'recommendation', 'warning')),
    priority TEXT NOT NULL CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    
    -- Content
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    reasoning TEXT,                         -- Why AI thinks this
    
    -- Data backing
    correlation_coefficient NUMERIC(4,3),  -- -1 to 1 (if correlation)
    correlation_method TEXT CHECK (correlation_method IN ('spearman', 'pearson', 'partial_spearman')),
    p_value NUMERIC(6,5),
    lag_days INTEGER,                      -- 0..2 for time-lagged correlations
    confounders TEXT[],                    -- e.g., ["day_of_week"]
    confidence_score NUMERIC(3,2),         -- 0-1
    data_points INTEGER,                    -- How much data backs this
    
    -- Related data
    related_dates DATERANGE,                -- Date range analyzed
    related_metrics metric_key[],           -- Which metrics involved
    
    -- User interaction
    dismissed BOOLEAN DEFAULT FALSE,
    dismissed_at TIMESTAMPTZ,
    acted_upon BOOLEAN DEFAULT FALSE,
    action_taken TEXT,
    
    -- Follow-up
    suggested_experiment_id UUID REFERENCES experiments(id),
    
    -- Metadata
    shown_to_user BOOLEAN DEFAULT FALSE,
    shown_at TIMESTAMPTZ
);

-- Indexes
CREATE INDEX idx_insights_user ON insights(user_id, created_at DESC);
CREATE INDEX idx_insights_undismissed ON insights(user_id) WHERE NOT dismissed;
CREATE INDEX idx_insights_priority ON insights(priority, created_at DESC);

-- Trigger for updated_at
CREATE TRIGGER set_insights_updated_at
    BEFORE UPDATE ON insights
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `recommendations`

Daily AI recommendations and actions.

> [!IMPORTANT]
> Recommendations must never prescribe supplement dosages.  
> `take_supplement` is only a **reminder** for user‑entered schedules.
> `block_apps` is only allowed when `notification_settings.control_level = 'guardian'`
> AND `notification_settings.focus_control_enabled = true`. Otherwise it must not be emitted.

```sql
CREATE TABLE recommendations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Timing
    recommendation_date DATE NOT NULL,
    time_of_day TEXT CHECK (time_of_day IN ('morning', 'midday', 'afternoon', 'evening', 'night')),
    
    -- Type
    category TEXT NOT NULL CHECK (category IN ('nutrition', 'activity', 'sleep', 'recovery', 'supplement', 'behavior')),
    priority TEXT NOT NULL CHECK (priority IN ('low', 'medium', 'high', 'critical')),
    
    -- Content
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    reasoning TEXT NOT NULL,                -- Why this recommendation

    -- Link to originating insight (optional but preferred)
    insight_id UUID REFERENCES insights(id) ON DELETE SET NULL,
    
    -- Action (if applicable)
    action_type TEXT CHECK (action_type IN ('increase_sleep', 'cancel_workout', 'eat_protein', 'block_apps', 'take_supplement', 'hydrate', 'rest')),
    action_parameters JSONB,
    auto_execute BOOLEAN DEFAULT FALSE,     -- Did it happen automatically?
    
    -- User response
    dismissed BOOLEAN DEFAULT FALSE,
    followed BOOLEAN,
    user_feedback TEXT CHECK (user_feedback IN ('helpful', 'not_helpful', 'ignored')),
    
    -- Context
    recovery_score_at_time NUMERIC(5,2),
    trigger_condition TEXT                  -- What caused this recommendation
);

-- Indexes
CREATE INDEX idx_recommendations_user ON recommendations(user_id, recommendation_date DESC);
CREATE INDEX idx_recommendations_active ON recommendations(user_id) WHERE NOT dismissed;

-- Trigger for updated_at
CREATE TRIGGER set_recommendations_updated_at
    BEFORE UPDATE ON recommendations
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `weekly_strategy_reports`

AI-generated weekly review + strategy output (Prompt 5).

```sql
CREATE TABLE weekly_strategy_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    week_start DATE NOT NULL,
    week_end DATE NOT NULL,

    summary_stats JSONB NOT NULL,          -- Aggregated inputs used for the report
    report_markdown TEXT NOT NULL,         -- Final weekly strategy output

    model_used TEXT,
    prompt_version TEXT,

    UNIQUE(user_id, week_start)
);

CREATE INDEX idx_weekly_strategy_user ON weekly_strategy_reports(user_id, week_start DESC);

CREATE TRIGGER set_weekly_strategy_updated_at
    BEFORE UPDATE ON weekly_strategy_reports
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

> **Note:** Supplement tracking is modeled via `supplement_catalog`, `user_supplements`, and `supplement_logs` (defined above).  
> Do not create a separate per-user `supplements` table to avoid duplication and inconsistent logging.

### Table: `medical_scans`

OCR'd medical documents (InBody, blood tests, etc.)

> [!IMPORTANT]
> Privacy posture (see `life_os_privacy_architecture.md`):
> - Raw scans are **local-only by default**.
> - A `medical_scans` row is created server-side only when the user opts into syncing derived results
>   (and optionally the original document).

```sql
CREATE TABLE medical_scans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Scan info
    scan_type TEXT NOT NULL CHECK (scan_type IN ('inbody', 'dexa', 'blood_test', 'other')),
    scan_date DATE NOT NULL,
    lab_name TEXT,
    
    -- Storage mode (privacy)
    -- Default: local-only raw documents. Derived markers may still sync.
    storage_mode TEXT NOT NULL DEFAULT 'local_only' CHECK (storage_mode IN ('local_only', 'cloud')),
    store_original_in_cloud BOOLEAN DEFAULT FALSE,
    
    -- Files (only if cloud storage enabled)
    original_image_url TEXT,
    source_file_sha256 TEXT,               -- Optional dedupe fingerprint
    document_language TEXT,
    
    -- Metadata
    ocr_confidence NUMERIC(3,2),
    ai_confidence NUMERIC(3,2),
    manually_verified BOOLEAN DEFAULT FALSE,
    notes TEXT,
    
    -- Health markers extraction tracking (added for Universal Health Markers)
    extraction_status TEXT NOT NULL DEFAULT 'pending' 
        CHECK (extraction_status IN ('pending', 'processing', 'completed', 'failed', 'needs_review')),
    extraction_error TEXT,
    markers_extracted INTEGER DEFAULT 0,
    diagnoses_extracted INTEGER DEFAULT 0,
    
    -- Retention policy
    pinned_by_user BOOLEAN DEFAULT FALSE, -- If true, exempt from 90-day auto-deletion
    scheduled_deletion_at TIMESTAMPTZ,    -- Computed: created_at + 90 days (NULL if pinned)

    -- Results
    processed_data JSONB                  -- Extracted structured data (nullable until completed)
);

-- Indexes
CREATE INDEX idx_medical_scans_user ON medical_scans(user_id, scan_date DESC);
CREATE INDEX idx_medical_scans_type ON medical_scans(scan_type);
CREATE INDEX idx_medical_scans_status ON medical_scans(extraction_status);

-- Trigger for updated_at
CREATE TRIGGER set_medical_scans_updated_at
    BEFORE UPDATE ON medical_scans
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `health_marker_catalog`

System-wide catalog of known health markers. Seeded with common markers, not user-editable.
Used for normalizing extracted marker names across different languages and formats.

```sql
CREATE TABLE health_marker_catalog (
    id TEXT PRIMARY KEY,                    -- e.g., "vitamin_d_25oh"
    category TEXT NOT NULL CHECK (category IN (
        'vitamins', 'hormones', 'blood', 'metabolic', 'minerals', 
        'lipids', 'liver', 'kidney', 'inflammation', 'thyroid', 'other'
    )),
    display_name TEXT NOT NULL,             -- "Vitamin D (25-OH)"
    display_name_ru TEXT,                   -- "Витамин D (25-OH)"
    aliases TEXT[] NOT NULL DEFAULT '{}',   -- ["25-hydroxyvitamin D", "Vit D3", "холекальциферол"]
    
    -- Units
    standard_unit TEXT NOT NULL,            -- "ng/mL"
    alternative_units JSONB,                -- {"nmol/L": 2.496} — division factors
    
    -- Reference ranges
    optimal_range_male NUMRANGE,            -- [30, 100]
    optimal_range_female NUMRANGE,
    critical_low NUMERIC,                   -- 10
    critical_high NUMERIC,                  -- 150
    
    -- Recovery integration
    affects_recovery BOOLEAN DEFAULT FALSE,
    recovery_weight NUMERIC(3,2),           -- 0.05 = 5% max impact
    
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed core markers
INSERT INTO health_marker_catalog (id, category, display_name, display_name_ru, aliases, standard_unit, alternative_units, optimal_range_male, optimal_range_female, critical_low, affects_recovery, recovery_weight) VALUES
('vitamin_d_25oh', 'vitamins', 'Vitamin D (25-OH)', 'Витамин D (25-OH)', 
 ARRAY['25-hydroxyvitamin D', 'Vit D', 'Vit D3', 'холекальциферол', '25-OH D', 'D3'], 
 'ng/mL', '{"nmol/L": 2.496}', '[30,100]', '[30,100]', 10, TRUE, 0.05),
 
('vitamin_b12', 'vitamins', 'Vitamin B12', 'Витамин B12',
 ARRAY['cobalamin', 'кобаламин', 'цианокобаламин', 'B12'],
 'pg/mL', '{"pmol/L": 0.738}', '[200,900]', '[200,900]', 150, TRUE, 0.03),
 
('ferritin', 'minerals', 'Ferritin', 'Ферритин',
 ARRAY['serum ferritin', 'сывороточный ферритин'],
 'ng/mL', NULL, '[30,300]', '[15,150]', 10, TRUE, 0.04),
 
('hemoglobin', 'blood', 'Hemoglobin', 'Гемоглобин',
 ARRAY['Hb', 'Hgb', 'гемоглобин'],
 'g/dL', '{"g/L": 10}', '[13.5,17.5]', '[12.0,16.0]', 7, TRUE, 0.04),
 
('testosterone_total', 'hormones', 'Testosterone (Total)', 'Тестостерон общий',
 ARRAY['total testosterone', 'тестостерон', 'testosterone'],
 'ng/dL', '{"nmol/L": 0.0347}', '[300,1000]', '[15,70]', NULL, TRUE, 0.06),
 
('cortisol_morning', 'hormones', 'Cortisol (Morning)', 'Кортизол утренний',
 ARRAY['cortisol', 'кортизол', 'hydrocortisone', 'cortisol AM'],
 'μg/dL', '{"nmol/L": 0.0362}', '[10,20]', '[10,20]', 3, TRUE, 0.05),
 
('tsh', 'thyroid', 'TSH', 'ТТГ',
 ARRAY['thyroid stimulating hormone', 'тиреотропный гормон', 'тиреотропин'],
 'mIU/L', NULL, '[0.4,4.0]', '[0.4,4.0]', 0.1, TRUE, 0.04),
 
('glucose_fasting', 'metabolic', 'Glucose (Fasting)', 'Глюкоза натощак',
 ARRAY['fasting glucose', 'blood sugar', 'сахар крови', 'глюкоза'],
 'mg/dL', '{"mmol/L": 0.0555}', '[70,100]', '[70,100]', 54, FALSE, NULL),
 
('hba1c', 'metabolic', 'HbA1c', 'Гликированный гемоглобин',
 ARRAY['glycated hemoglobin', 'A1C', 'гликогемоглобин'],
 '%', NULL, '[4.0,5.6]', '[4.0,5.6]', NULL, FALSE, NULL),
 
('crp', 'inflammation', 'C-Reactive Protein', 'С-реактивный белок',
 ARRAY['CRP', 'hs-CRP', 'СРБ', 'high-sensitivity CRP'],
 'mg/L', NULL, '[0,3]', '[0,3]', NULL, TRUE, 0.04),
 
('iron', 'minerals', 'Iron', 'Железо',
 ARRAY['serum iron', 'сывороточное железо', 'Fe'],
 'μg/dL', '{"μmol/L": 5.587}', '[60,170]', '[50,150]', 30, TRUE, 0.03),
 
('cholesterol_total', 'lipids', 'Total Cholesterol', 'Холестерин общий',
 ARRAY['cholesterol', 'холестерин', 'TC'],
 'mg/dL', '{"mmol/L": 0.0259}', '[0,200]', '[0,200]', NULL, FALSE, NULL);

CREATE INDEX idx_health_marker_catalog_category ON health_marker_catalog(category);

-- Trigger for updated_at
CREATE TRIGGER set_health_marker_catalog_updated_at
    BEFORE UPDATE ON health_marker_catalog
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `health_measurements`

User's actual health marker measurements with full history.
Each scan creates NEW entries — values are NEVER overwritten.

```sql
CREATE TABLE health_measurements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    marker_id TEXT NOT NULL,                    -- FK to catalog or custom "other_xxx"
    
    -- Values (normalized)
    value NUMERIC NOT NULL,
    unit TEXT NOT NULL,
    
    -- Original values (before conversion)
    original_value NUMERIC,
    original_unit TEXT,
    
    -- Status assessment
    status TEXT CHECK (status IN ('critical_low', 'low', 'optimal', 'high', 'critical_high')),
    reference_range_low NUMERIC,
    reference_range_high NUMERIC,
    
    -- Source tracking
    measured_at DATE NOT NULL,                  -- When blood was drawn
    source_scan_id UUID REFERENCES medical_scans(id) ON DELETE SET NULL,
    source_type TEXT DEFAULT 'scan' CHECK (source_type IN ('scan', 'manual', 'healthkit')),
    original_label TEXT,                        -- Exact text from document
    
    -- Quality
    confidence NUMERIC(3,2),
    manually_verified BOOLEAN DEFAULT FALSE,
    notes TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Prevent exact duplicates
    UNIQUE(user_id, marker_id, measured_at, source_scan_id)
);

CREATE INDEX idx_health_measurements_user_marker ON health_measurements(user_id, marker_id, measured_at DESC);
CREATE INDEX idx_health_measurements_user_date ON health_measurements(user_id, measured_at DESC);
CREATE INDEX idx_health_measurements_scan ON health_measurements(source_scan_id);
CREATE INDEX idx_health_measurements_status ON health_measurements(user_id, status) WHERE status IN ('critical_low', 'low');

-- Trigger for updated_at
CREATE TRIGGER set_health_measurements_updated_at
    BEFORE UPDATE ON health_measurements
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `health_diagnoses`

Diagnoses and conditions extracted from medical documents.

```sql
CREATE TABLE health_diagnoses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    
    -- Diagnosis info
    condition_id TEXT,                          -- Normalized: "vitamin_d_deficiency"
    original_text TEXT NOT NULL,                -- "Недостаточность витамина D"
    severity TEXT CHECK (severity IN ('mild', 'moderate', 'severe')),
    
    -- Dates
    diagnosed_at DATE,
    source_scan_id UUID REFERENCES medical_scans(id) ON DELETE SET NULL,
    
    -- Resolution tracking
    is_resolved BOOLEAN DEFAULT FALSE,
    resolved_at DATE,
    resolution_notes TEXT,
    
    -- Quality
    confidence NUMERIC(3,2),
    notes TEXT,
    
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_health_diagnoses_user ON health_diagnoses(user_id, diagnosed_at DESC);
CREATE INDEX idx_health_diagnoses_active ON health_diagnoses(user_id) WHERE is_resolved = FALSE;

-- Trigger for updated_at
CREATE TRIGGER set_health_diagnoses_updated_at
    BEFORE UPDATE ON health_diagnoses
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

> **Note:** `training_loads` and `wellness_checks` are defined earlier in this document.  
> Do not duplicate table definitions — it creates drift and breaks RLS/offline sync assumptions.

### Table: `vector_memory`

Reference table for Pinecone vectors (for querying).

> [!IMPORTANT]
> Vector embeddings are **opt‑in**. Only derived, non-identifying summaries should be embedded.  
> Do **not** embed raw health metrics, menstrual data, or medical documents without explicit consent.

```sql
CREATE TABLE vector_memory (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Vector DB reference
    vector_id TEXT NOT NULL UNIQUE,         -- Pinecone vector ID
    vector_namespace TEXT,                  -- User-specific namespace
    
    -- Source data
    source_type TEXT NOT NULL CHECK (source_type IN (
      'food_log',
      'physiological_state',
      'workout_session',
      'health_measurement',
      'body_composition',
      'experiment',
      'insight',
      'supplement_log',
      'wellness_check'
    )),
    source_id UUID NOT NULL,                -- Reference to source table
    
    -- Temporal context
    event_date DATE NOT NULL,
    
    -- Metadata (denormalized for quick access)
    summary TEXT,                           -- Human-readable summary (derived)
    tags TEXT[],                            -- For filtering
    
    -- Search optimization
    searchable_text TEXT                    -- Full-text search column (derived)
);

-- Indexes
CREATE INDEX idx_vector_memory_user ON vector_memory(user_id, event_date DESC);
CREATE INDEX idx_vector_memory_source ON vector_memory(source_type, source_id);
CREATE INDEX idx_vector_memory_vector ON vector_memory(vector_id);
CREATE INDEX idx_vector_memory_fts ON vector_memory USING gin(to_tsvector('english', searchable_text));

-- Trigger for updated_at
CREATE TRIGGER set_vector_memory_updated_at
    BEFORE UPDATE ON vector_memory
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

**Vector sources (opt‑in):**
- `food_logs`
- `workout_sessions`
- `health_measurements`
- `body_composition`
- `physiological_states`
- `insights`, `experiments`, `supplement_logs`, `wellness_checks`

---

### Table: `onboarding_state`

Tracks onboarding step progression per user. Used by `POST /api/onboarding/profile` and the client-side resume logic.

> See `life_os_onboarding_backend.md` for the state machine definition.

```sql
CREATE TABLE onboarding_state (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    step TEXT NOT NULL DEFAULT 'not_started' CHECK (step IN (
      'not_started', 'auth_complete', 'profile_complete',
      'healthkit_prompted', 'healthkit_granted', 'healthkit_skipped',
      'backfill_in_progress', 'backfill_complete',
      'tutorial_shown', 'onboarding_complete'
    )),
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_onboarding_state_user ON onboarding_state(user_id);

CREATE TRIGGER set_onboarding_state_updated_at
    BEFORE UPDATE ON onboarding_state
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `user_baselines`

Stores computed HRV/RHR/Sleep baselines per user, populated during onboarding health backfill and updated daily.

> See `life_os_recovery_algorithms.md` §3 for EWMA baseline computation and `life_os_onboarding_backend.md` for initial population.

```sql
CREATE TABLE user_baselines (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    hrv_ln_rmssd_baseline NUMERIC(6,3),
    rhr_baseline NUMERIC(5,2),
    sleep_baseline_hours NUMERIC(4,2),
    data_days_available INTEGER NOT NULL DEFAULT 0,
    baseline_confidence NUMERIC(3,2) NOT NULL DEFAULT 0,
    last_computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_baselines_user ON user_baselines(user_id);

CREATE TRIGGER set_user_baselines_updated_at
    BEFORE UPDATE ON user_baselines
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `privacy_settings`

User privacy preferences, created with defaults during onboarding.

> See `life_os_privacy_architecture.md` for retention policies and `life_os_onboarding_backend.md` for default values.

```sql
CREATE TABLE privacy_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    menstrual_local_only BOOLEAN NOT NULL DEFAULT TRUE,
    medical_scan_local_only BOOLEAN NOT NULL DEFAULT TRUE,
    cloud_backup_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    vector_opt_in BOOLEAN NOT NULL DEFAULT FALSE,
    analytics_consent BOOLEAN NOT NULL DEFAULT FALSE,
    cloud_ocr_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_privacy_settings_user ON privacy_settings(user_id);

CREATE TRIGGER set_privacy_settings_updated_at
    BEFORE UPDATE ON privacy_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

---

### Table: `analytics_events`

Stores anonymized, opt-in product analytics events. Never contains PII.

> See `life_os_analytics_catalog.md` for the event taxonomy, privacy classification, and retention policy.

```sql
CREATE TABLE analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,  -- nullable after anonymization
    event_name TEXT NOT NULL,
    properties JSONB NOT NULL DEFAULT '{}',
    session_id UUID,
    app_version TEXT,
    os_version TEXT,
    device_model TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_analytics_events_name ON analytics_events(event_name, created_at DESC);
CREATE INDEX idx_analytics_events_user ON analytics_events(user_id, created_at DESC);
CREATE INDEX idx_analytics_events_retention ON analytics_events(created_at);  -- for retention policy cleanup
```

> **Retention:** Events older than 90 days (30 days for error/sync events) are automatically deleted by a scheduled job.

---

## ROW LEVEL SECURITY (RLS)

Enable RLS on all user tables:

```sql
-- Enable RLS
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE physiological_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE food_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE food_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE food_catalog_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_foods ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_food_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE meal_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE batch_recipes ENABLE ROW LEVEL SECURITY;
ALTER TABLE batch_recipe_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE experiments ENABLE ROW LEVEL SECURITY;
ALTER TABLE experiment_measurements ENABLE ROW LEVEL SECURITY;
ALTER TABLE insights ENABLE ROW LEVEL SECURITY;
ALTER TABLE recommendations ENABLE ROW LEVEL SECURITY;
ALTER TABLE weekly_strategy_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE daily_nutrition_targets ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_supplements ENABLE ROW LEVEL SECURITY;
ALTER TABLE supplement_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE medical_scans ENABLE ROW LEVEL SECURITY;
ALTER TABLE vector_memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_loads ENABLE ROW LEVEL SECURITY;
ALTER TABLE wellness_checks ENABLE ROW LEVEL SECURITY;
ALTER TABLE body_composition ENABLE ROW LEVEL SECURITY;
ALTER TABLE hydration_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE exercise_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_exercises ENABLE ROW LEVEL SECURITY;
ALTER TABLE workout_sets ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_plan_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE sleep_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE onboarding_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_baselines ENABLE ROW LEVEL SECURITY;
ALTER TABLE privacy_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE analytics_events ENABLE ROW LEVEL SECURITY;

-- Policies: Users can only access their own data
CREATE POLICY users_policy ON users
    FOR ALL USING (auth.uid() = auth_id);

CREATE POLICY physiological_states_policy ON physiological_states
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY food_logs_policy ON food_logs
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY food_items_policy ON food_items
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Food catalog cache is safe for read-only access by authenticated users.
-- Inserts/updates are performed by edge functions using the service role.
CREATE POLICY food_catalog_items_select_policy ON food_catalog_items
    FOR SELECT TO authenticated USING (true);

CREATE POLICY user_foods_policy ON user_foods
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY user_food_favorites_policy ON user_food_favorites
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY meal_templates_policy ON meal_templates
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY batch_recipes_policy ON batch_recipes
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY batch_recipe_ingredients_policy ON batch_recipe_ingredients
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = (SELECT user_id FROM batch_recipes WHERE id = batch_recipe_id)));

CREATE POLICY experiments_policy ON experiments
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY experiment_measurements_policy ON experiment_measurements
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY insights_policy ON insights
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY recommendations_policy ON recommendations
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY weekly_strategy_reports_policy ON weekly_strategy_reports
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY daily_nutrition_targets_policy ON daily_nutrition_targets
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY notification_settings_policy ON notification_settings
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY user_supplements_policy ON user_supplements
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY supplement_logs_policy ON supplement_logs
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY medical_scans_policy ON medical_scans
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY vector_memory_policy ON vector_memory
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY training_loads_policy ON training_loads
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY wellness_checks_policy ON wellness_checks
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY body_composition_policy ON body_composition
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY hydration_logs_policy ON hydration_logs
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Exercise catalog (global + user custom)
CREATE POLICY exercise_catalog_select_policy ON exercise_catalog
    FOR SELECT USING (
        is_custom = FALSE
        OR created_by = (SELECT id FROM users WHERE auth_id = auth.uid())
    );

CREATE POLICY exercise_catalog_insert_policy ON exercise_catalog
    FOR INSERT WITH CHECK (
        created_by = (SELECT id FROM users WHERE auth_id = auth.uid())
    );

CREATE POLICY exercise_catalog_update_policy ON exercise_catalog
    FOR UPDATE USING (
        created_by = (SELECT id FROM users WHERE auth_id = auth.uid())
    )
    WITH CHECK (
        created_by = (SELECT id FROM users WHERE auth_id = auth.uid())
    );

CREATE POLICY exercise_catalog_delete_policy ON exercise_catalog
    FOR DELETE USING (
        created_by = (SELECT id FROM users WHERE auth_id = auth.uid())
    );

-- Workout sessions
CREATE POLICY workout_sessions_policy ON workout_sessions
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY workout_exercises_policy ON workout_exercises
    FOR ALL USING (
        auth.uid() = (
            SELECT auth_id FROM users WHERE id = (
                SELECT user_id FROM workout_sessions WHERE id = session_id
            )
        )
    );

CREATE POLICY workout_sets_policy ON workout_sets
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Training plans
CREATE POLICY training_plans_policy ON training_plans
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY training_plan_sessions_policy ON training_plan_sessions
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY sleep_logs_policy ON sleep_logs
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

CREATE POLICY training_templates_policy ON training_templates
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Onboarding state (user can only read/write own state)
CREATE POLICY onboarding_state_policy ON onboarding_state
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- User baselines (read/write own baselines)
CREATE POLICY user_baselines_policy ON user_baselines
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Privacy settings (read/write own settings)
CREATE POLICY privacy_settings_policy ON privacy_settings
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Analytics events (write-only from client; reads are service-role only)
CREATE POLICY analytics_events_insert_policy ON analytics_events
    FOR INSERT WITH CHECK (
        user_id = (SELECT id FROM users WHERE auth_id = auth.uid())
    );


-- Health Markers (new tables)
ALTER TABLE health_measurements ENABLE ROW LEVEL SECURITY;
CREATE POLICY health_measurements_policy ON health_measurements
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

ALTER TABLE health_diagnoses ENABLE ROW LEVEL SECURITY;
CREATE POLICY health_diagnoses_policy ON health_diagnoses
    FOR ALL USING (auth.uid() = (SELECT auth_id FROM users WHERE id = user_id));

-- Note: health_marker_catalog and supplement_catalog are reference tables (no RLS needed; safe for read-only access)
```

---

## EDGE FUNCTIONS

### Function: `calculate-recovery-score`

**Endpoint:** `POST /functions/v1/calculate-recovery-score`

**Purpose:** Calculate daily recovery score from HealthKit data

**Input:**
```json
{
  "date": "2026-01-18",
  "hrv_ms": 62,
  "resting_heart_rate_bpm": 58,
  "wrist_temperature_deviation_c": 0.2,
  "sleep_duration_hours": 7.33,
  "sleep_quality_percent": 85,
  "deep_sleep_percent": 18,
  "rem_sleep_percent": 22,
  "light_sleep_percent": 55,
  "awake_percent": 5,
  "menstrual_phase": null
}
```

**Output:**
```json
{
  "recovery_score": 78,
  "recovery_zone": "optimal",
  "breakdown": {
    "hrv_score": 82,
    "rhr_score": 80,
    "temp_score": 75,
    "sleep_score": 85
  },
  "recommendation": "Your body is ready for moderate intensity training today"
}
```

**Implementation:**
```typescript
// Edge function (Deno)
// IMPORTANT: do NOT accept `user_id` from the client. Always derive user from the JWT.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

serve(async (req) => {
  const authHeader = req.headers.get('Authorization') ?? ''

  // 1) Validate JWT and get auth user
  const supabaseAuth = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  )

  const { data: auth, error: authError } = await supabaseAuth.auth.getUser()
  if (authError || !auth?.user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 })
  }

  // 2) Parse request body
  const {
    date,
    hrv_ms,
    resting_heart_rate_bpm,
    wrist_temperature_deviation_c,
    sleep_duration_hours,
    sleep_quality_percent,
    deep_sleep_percent,
    rem_sleep_percent,
    light_sleep_percent,
    awake_percent,
    menstrual_phase
  } = await req.json()

  // 3) Use service role for DB ops (still scoped to the requesting user)
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  // Map Supabase auth user -> Life OS internal user row
  const { data: user, error: userError } = await supabase
    .from('users')
    .select('id, sex, baseline_hrv_ms, baseline_rhr_bpm, baseline_sleep_hours')
    .eq('auth_id', auth.user.id)
    .single()

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User profile not found' }), { status: 404 })
  }

  // 4) Health markers (labs) — only those marked affects_recovery = TRUE
  const healthMarkers = await supabase
    .from('health_measurements')
    .select('marker_id, value, unit, measured_at, status, health_marker_catalog!inner(affects_recovery,recovery_weight,display_name,optimal_range_male,optimal_range_female)')
    .eq('user_id', user.id)
    .eq('health_marker_catalog.affects_recovery', true)
    .order('measured_at', { ascending: false });

  // 5) Menstrual phase (optional, on-device only)
  // The client may send a derived phase if the user explicitly opts in.

  // 6) Calculate using the single source of truth algorithm implementation
  // See: life_os_recovery_algorithms.md (do not maintain a separate "parallel" formula here).
  const result = calculateRecoveryScore({
    hrv_ms,
    resting_heart_rate_bpm,
    wrist_temperature_deviation_c,
    sleep_duration_hours,
    sleep_quality_percent,
    deep_sleep_percent,
    rem_sleep_percent,
    light_sleep_percent,
    awake_percent,
    baselines: {
      hrv_ms: user.baseline_hrv_ms,
      rhr_bpm: user.baseline_rhr_bpm,
      sleep_hours: user.baseline_sleep_hours
    },
    healthMarkers: healthMarkers?.data ?? [],
    menstrual_phase
  })

  // 7) Persist daily state (upsert)
  await supabase
    .from('physiological_states')
    .upsert({
      user_id: user.id,
      date,
      hrv_ms,
      hrv_score: result.breakdown.hrv_score,
      resting_heart_rate_bpm,
      rhr_score: result.breakdown.rhr_score,
      wrist_temperature_deviation_c,
      temp_score: result.breakdown.temp_score,
      sleep_duration_hours,
      sleep_quality_percent,
      deep_sleep_percent,
      rem_sleep_percent,
      light_sleep_percent,
      awake_percent,
      sleep_score: result.breakdown.sleep_score,
      recovery_score: result.recovery_score,
      recovery_zone: result.recovery_zone,
      micro_zone: result.micro_zone
    }, { onConflict: 'user_id,date' })

  return new Response(JSON.stringify(result), {
    headers: { 'Content-Type': 'application/json' }
  })
})

/**
 * calculateRecoveryScore — IMPLEMENTATION STUB
 * Full algorithm specification: life_os_recovery_algorithms.md
 * Helper function signatures: life_os_recovery_algorithms.md → Appendix
 * This stub shows edge function wiring only; real implementation
 * MUST follow the referenced algorithm spec.
 */
function calculateRecoveryScore(userId: string, date: string): Promise<RecoveryScore> {
  // See life_os_recovery_algorithms.md for complete implementation
  throw new Error('Implement per life_os_recovery_algorithms.md')
}
```

---

### Function: `analyze-food-image`

**Endpoint:** `POST /functions/v1/analyze-food-image`

**Purpose:** Process food photo with openai/gpt-4o (Vision via OpenRouter)

**Input:**
```json
{
  "image_base64": "data:image/jpeg;base64,...",
  "context": "restaurant",
  "timestamp": "2026-01-18T13:45:00Z",
  "post_workout": true
}
```

**Output:**
```json
{
  "detected_items": [
    {
      "name": "Chicken breast",
      "weight_g": 150,
      "calories": 248,
      "protein_g": 46,
      "fat_g": 5,
      "carbs_g": 0,
      "confidence": 0.92
    }
  ],
  "total_macros": {
    "calories": 520,
    "protein_g": 65,
    "fat_g": 18,
    "carbs_g": 35,
    "fiber_g": 6
  },
  "confidence": 0.87,
  "context_analysis": "Restaurant context detected. Added 25% hidden-calorie buffer for sauces. Post-workout meal - protein timing optimal.",
  "suggestions": [
    "Add 20g more carbs to maximize glycogen replenishment"
  ]
}
```

---

### Function: `analyze-batch-recipe-image`

**Endpoint:** `POST /functions/v1/analyze-batch-recipe-image`

**Purpose:** Fast meal-prep estimation when the user does not want to enter every ingredient manually.

**Notes:**
- This is a convenience feature; “precise mode” should be preferred for accuracy.
- The output MUST always be treated as a **draft** and require review before saving.

**Input:**
```json
{
  "recipe_name": "Meal prep (photo)",
  "total_weight_grams": 1800,
  "portions_planned": 9,
  "cooking_method": "baked",
  "known_ingredients": [],
  "image_base64": "data:image/jpeg;base64,..."
}
```

**Output:**
```json
{
  "recipe_name": "Meal prep (photo)",
  "ingredients_detected": [
    {
      "name": "Chicken breast",
      "estimated_raw_weight_g": 900,
      "estimated_cooked_weight_g": 700,
      "calories": 1100,
      "protein_g": 200,
      "fat_g": 25,
      "carbs_g": 0,
      "confidence": 0.78
    }
  ],
  "total_batch": { "weight_g": 1800, "calories": 2400, "protein_g": 180, "fat_g": 60, "carbs_g": 240, "fiber_g": 12 },
  "per_100g": { "calories": 133, "protein_g": 10.0, "fat_g": 3.3, "carbs_g": 13.3, "fiber_g": 0.7 },
  "per_portion": { "weight_g": 200, "calories": 266, "protein_g": 20, "fat_g": 7, "carbs_g": 27 },
  "notes": ["Estimates require review."],
  "storage": { "refrigerator_days": 4, "freezer_months": 2, "reheating_tip": "Reheat gently." },
  "confidence": 0.72
}
```

---

### Function: `foods-barcode-lookup`

**Endpoint:** `POST /functions/v1/foods-barcode-lookup`

**Purpose:** Barcode lookup for packaged foods with provider abstraction + caching into `food_catalog_items`.

**Source of truth:** `life_os_food_data_strategy.md` (provider choice + lookup precedence + normalization).

**Input:**
```json
{
  "barcode": "4601234567890",
  "locale": "ru_RU"
}
```

**Behavior:**
- Check `food_catalog_items` cache (same `provider` + `barcode`) and return if not expired.
- If missing or expired, call the configured provider (server-side secret).
- Normalize to Life OS schema (per-100g macros) and upsert into `food_catalog_items`.
- If provider returns per-serving only, compute per-100g using serving weight (if known); otherwise return `error: "insufficient_nutrition_data"`.

**Output (found):**
```json
{
  "type": "catalog",
  "provider": "open_food_facts",
  "id": "uuid",
  "name": "Chicken breast slices",
  "brand": "BrandName",
  "barcode": "4601234567890",
  "serving_size_g": 50,
  "macros_per_100g": { "calories": 110, "protein_g": 21, "fat_g": 2.0, "carbs_g": 1.5, "fiber_g": 0 },
  "fetched_at": "2026-02-04T10:12:30Z",
  "expires_at": "2026-03-05T10:12:30Z"
}
```

**Output (not found):**
```json
{ "error": "barcode_not_found" }
```

---

### Function: `foods-search`

**Endpoint:** `POST /functions/v1/foods-search`

**Purpose:** Food search that returns merged results: favorites + recent + user custom + cached catalog + optional provider search.

**Source of truth:** `life_os_food_data_strategy.md` (ranking + CIS language rules).

**Input:**
```json
{
  "query": "chicken",
  "limit": 20,
  "locale": "en_US"
}
```

**Output:**
```json
{
  "query": "chicken",
  "results": [
    {
      "type": "custom",
      "id": "uuid",
      "name": "Chicken breast (raw)",
      "brand": null,
      "barcode": null,
      "serving_size_g": 100,
      "macros_per_100g": { "calories": 120, "protein_g": 23, "fat_g": 2.6, "carbs_g": 0, "fiber_g": 0 },
      "tags": ["recent"]
    },
    {
      "type": "catalog",
      "provider": "open_food_facts",
      "id": "uuid",
      "name": "Chicken breast slices",
      "brand": "BrandName",
      "barcode": "4601234567890",
      "serving_size_g": 50,
      "macros_per_100g": { "calories": 110, "protein_g": 21, "fat_g": 2.0, "carbs_g": 1.5, "fiber_g": 0 },
      "tags": ["favorite"]
    }
  ],
  "warnings": []
}
```

---

### Function: `parse-food-text`

**Endpoint:** `POST /functions/v1/parse-food-text`

**Purpose:** Convert free-form text (typed or voice-to-text transcript) into structured meal items for quick logging.

**Input:**
```json
{
  "text": "Two eggs and a cappuccino",
  "locale": "en_US",
  "context": "home",
  "meal_type": "breakfast"
}
```

**Output (best-effort parse):**
```json
{
  "items": [
    {
      "name": "Egg",
      "quantity": 2,
      "unit": "piece",
      "weight_g": 100,
      "calories": 143,
      "protein_g": 13,
      "fat_g": 10,
      "carbs_g": 1,
      "confidence": 0.82
    },
    {
      "name": "Cappuccino",
      "quantity": 1,
      "unit": "cup",
      "weight_g": 180,
      "calories": 120,
      "protein_g": 6,
      "fat_g": 5,
      "carbs_g": 12,
      "confidence": 0.72
    }
  ],
  "confidence": 0.78,
  "needs_clarification": false,
  "clarifying_questions": []
}
```

**Output (needs clarification):**
```json
{
  "items": [
    { "name": "Pasta", "confidence": 0.58 }
  ],
  "confidence": 0.58,
  "needs_clarification": true,
  "clarifying_questions": [
    {
      "id": "pasta_portion",
      "question": "About how much pasta was it?",
      "options": ["1 cup", "2 cups", "3 cups", "I can weigh it"]
    }
  ]
}
```

**Rules:**
- Never ask more than **2** clarifying questions in a single parse.
- If still ambiguous, return a best-effort estimate with low confidence and force “Review Meal” UX before saving.

---

### Function: `analyze-food-label`

**Endpoint:** `POST /functions/v1/analyze-food-label`

**Purpose:** Extract nutrition information from a packaged product label (CIS-critical fallback when barcode databases miss).

**Source of truth:** `life_os_food_data_strategy.md` (Normalization rules + review gate).

**Input:**
```json
{
  "barcode": "4601234567890",
  "locale": "ru_RU",
  "images_base64": [
    "data:image/jpeg;base64,...",  // nutrition table (required)
    "data:image/jpeg;base64,..."   // front pack (optional)
  ]
}
```

**Output:**
```json
{
  "barcode": "4601234567890",
  "name": "Kefir 2.5%",
  "brand": "BrandName",
  "serving_size_g": 200,
  "macros_per_100g": {
    "calories": 53,
    "protein_g": 3.0,
    "fat_g": 2.5,
    "carbs_g": 4.0,
    "fiber_g": null,
    "sugar_g": null,
    "sodium_mg": null
  },
  "confidence": 0.84,
  "warnings": ["Serving size unclear", "Fiber not provided on label"],
  "needs_review": true
}
```

**Rules:**
- Always return per-100g macros (canonical).
- If kcal and macros disagree beyond tolerance, include a warning and set lower confidence.
- Never write to DB; this function is analysis-only.
- Client MUST show Review Product screen before calling `/api/foods/barcode/{code}/create`.

---

### Function: `analyze-medical-scan`

**Endpoint:** `POST /functions/v1/analyze-medical-scan`

**Purpose:** OCR + normalization of lab documents (blood tests, InBody, DEXA).

**Input:**
```json
{
  "scan_type": "blood_test",
  "image_base64": "data:image/jpeg;base64,...",
  "language_hint": "ru",
  "scan_date": "2026-01-18"
}
```

**Output:**
```json
{
  "document_language": "ru",
  "lab_name": "Invitro",
  "markers": [
    {
      "marker_id": "vitamin_d_25oh",
      "value": 24,
      "unit": "ng/mL",
      "original_label": "25-OH Витамин D",
      "reference_range": { "min": 30, "max": 100 },
      "status": "low",
      "confidence": 0.91
    }
  ],
  "diagnoses": [],
  "needs_review": false
}
```

---

### Function: `generate-training-plan`

**Endpoint:** `POST /functions/v1/generate-training-plan`

**Purpose:** Create a personalized, adaptive training plan.

**Input:**
```json
{
  "goal": "hypertrophy",
  "experience_level": "intermediate",
  "available_days": [1, 3, 5, 6],
  "session_duration_minutes": 60,
  "equipment_access": "gym",
  "injuries": ["shoulder_impingement"],
  "recovery_state": { "score": 72, "zone": "ready" },
  "training_history_summary": {
    "weekly_volume_last_4w": 12,
    "acwr": 1.1
  }
}
```

**Output:**
```json
{
  "plan_name": "4-Week Hypertrophy Block",
  "duration_weeks": 4,
  "days_per_week": 4,
  "plan_json": { "phases": [], "weeks": [] },
  "adaptive_rules": { "recovery_low": "reduce_volume_30" },
  "warnings": ["Avoid overhead press due to shoulder_impingement"],
  "confidence": 0.84
}
```

---

### Function: `generate-insights`

**Endpoint:** `POST /functions/v1/generate-insights`

**Purpose:** Use RAG to find patterns and correlations

**Correlation Engine (V1):**
- Method: Spearman rank correlation
- Time lags: 0–2 days (best |r| reported)
- Minimum n: 14 (7–13 allowed for exploratory, low confidence)
- Significance: p < 0.05 (two‑tailed) when n ≥ 14
- Confounders: partial correlation controlling for day_of_week
- Confidence score:
  - base = 0.2
  - effect = 0.6 × |r|
  - sample = 0.2 × min(1, (n − 14)/28)
  - confidence = clamp((base + effect + sample) × data_quality, 0, 1)

**Input:**
```json
{
  "query": "Why do I always feel tired on Thursdays?",
  "date_range": {
    "start": "2025-10-01",
    "end": "2026-01-18"
  }
}
```

**Output:**
```json
{
  "insights": [
    {
      "title": "Wednesday Sleep Debt Pattern",
      "description": "Analysis of 12 Thursdays shows consistent fatigue correlated with Wednesday late nights",
      "correlation": 0.76,
      "correlation_method": "spearman",
      "p_value": 0.021,
      "lag_days": 1,
      "confidence": 0.94,
      "data_points": 12,
      "reasoning": "Your Wednesday team calls (20:00-21:00) delay bedtime by 45 minutes on average...",
      "recommendation": "Move the meeting to 19:00 or set a hard bedtime of 22:30 on Wednesdays"
    }
  ]
}
```

---

### Function: `generate-weekly-strategy`

**Endpoint:** `POST /functions/v1/generate-weekly-strategy`

**Purpose:** Generate a weekly strategy report (Prompt 5) and persist it.

**Input:**
```json
{
  "week_start": "2026-01-12",
  "week_end": "2026-01-18",
  "summary_stats": {
    "avg_recovery_score": 72,
    "recovery_trend": "stable",
    "days_in_optimal_zone": 2,
    "days_in_critical_zone": 0,
    "avg_sleep_duration": 7.1,
    "sleep_consistency": 0.76,
    "nutrition_adherence": 0.82,
    "training_volume": 1850,
    "allostatic_load": 0.38
  },
  "notable_events": ["work travel", "late-night meeting"],
  "goals": ["improve endurance", "reduce sugar cravings"]
}
```

**Output:**
```json
{
  "report_id": "uuid",
  "week_start": "2026-01-12",
  "week_end": "2026-01-18",
  "report_markdown": "# Week 3 Review\n\n## By The Numbers\n...",
  "confidence": 0.88
}
```

---

## HEALTHKIT INTEGRATION (iOS CLIENT CONTRACT)

This section specifies how the iOS client should read Apple Health / HealthKit and map it into Life OS.

> **Source of truth:** `life_os_healthkit_spec.md`  
> (identifiers, units, aggregation windows, source precedence, anchors, travel/DST handling).

### Permissions (Read-only, V1 Minimal Set)

Required:
- Sleep (duration + stages)
- HRV (SDNN)
- Resting Heart Rate
- Workouts (HKWorkout)
- Active Energy + Steps

Optional (advanced, may be unavailable by device/region/user):
- Wrist temperature (sleep)
- Respiratory rate
- Blood oxygen

### Sync Strategy

1. **On connect (first time):** backfill last 14 days of sleep + HRV + RHR + workouts.
2. **Daily:** run background refresh in the user’s morning window (default 06:00–10:00).
3. **On app open:** refresh last 3 days.
4. **Manual:** pull-to-refresh triggers an immediate refresh for last 3 days.
5. **Incremental:** use anchored queries per type; recompute only impacted local days (see `life_os_healthkit_spec.md`).

### Derived Daily Aggregates (per local day)

For each `date`:
- Determine the main sleep window from HealthKit sleep records.
- Compute:
  - `sleep_duration_hours`
  - `deep_sleep_percent`, `rem_sleep_percent`, `light_sleep_percent`, `awake_percent`
- HRV:
  - Prefer HRV samples within the main sleep window.
  - If multiple samples exist, use **median** SDNN.
  - If none exist, fallback to last 24h median.
- RHR:
  - Use HealthKit resting heart rate daily average (or median).
- Temperature deviation:
  - Optional; only send if present.
- Always compute and persist `data_completeness` and `confidence_score` for `physiological_states`.

### Mapping Into Life OS

- Call `POST /functions/v1/calculate-recovery-score` once per day with aggregated inputs.
- Upsert `physiological_states` for that day.
- Workouts:
  - Create `workout_sessions` from HKWorkouts.
  - Compute and store `session_date` (user-local).
  - Set `source = 'import'`, `import_provider = 'healthkit'`, `import_source_id = <HKWorkout UUID>`.
  - Persist `started_timezone` + `started_utc_offset_minutes` when known (for travel-correct display).
  - If the user logs a manual strength workout that overlaps an imported workout, surface conflict resolution (merge/keep) in the client.
- Activity:
  - Update `steps`, `active_calories`, `exercise_minutes` inside `physiological_states` (if available).

### Trust / Conflict Rules (High Level)

1. Prefer Apple Watch samples over iPhone.
2. If two data sources disagree for the same day, keep both raw timestamps but compute the **daily aggregate** deterministically (median/average).
3. Always label source and confidence where applicable (see ecosystem spec data quality model).

## API ENDPOINTS (Client-facing)

### Authentication

All requests require JWT token:
```
Authorization: Bearer <supabase_jwt_token>
```

Supported auth modes (Supabase Auth):
- Anonymous (recommended for frictionless onboarding)
- Sign in with Apple
- Email OTP / magic link (fallback)

**First launch recommended flow:**
1. Client signs in anonymously to get a JWT.
2. Client upserts `users` row (keyed by `auth_id`).
3. User completes onboarding.
4. User may later upgrade/link identity (Apple/email) without losing data.

### Media Uploads

Used for food photos, label scans, and lab scans that must be stored server-side.

### POST `/api/media/upload`

Upload media to Supabase Storage and return a stable URL.

**Request (multipart or base64 JSON):**
```json
{
  "type": "food_photo | label_scan | lab_scan",
  "image_base64": "data:image/jpeg;base64,...",
  "storage_mode": "cloud | local_only"
}
```

**Response:**
```json
{
  "media_id": "uuid",
  "media_url": "https://...",
  "content_type": "image/jpeg",
  "size_bytes": 412345
}
```

**Notes:**
- If `storage_mode = local_only`, the client MAY skip upload and call the relevant `/functions/v1/*` analysis endpoint directly with base64.
- Use returned `media_url` for `food_logs.image_url`, `medical_scans.original_image_url`, and `body_composition.scan_image_url` when cloud storage is enabled.

### GET `/api/settings/notifications`

Fetch the user’s notification preferences.

**Response:**
```json
{
  "morning_brief_enabled": true,
  "positive_enabled": true,
  "nudges_enabled": true,
  "celebration_enabled": true,
  "critical_only": false,
  "morning_brief_time_local": "07:00",
  "quiet_hours_start": "22:00",
  "quiet_hours_end": "07:00",
  "max_positive_per_day": 3,
  "max_nudges_per_day": 2,
  "max_celebration_per_day": 2,
  "max_total_per_day": 6,
  "control_level": "advisory",
  "focus_control_enabled": false
}
```

### PATCH `/api/settings/notifications`

Update the user’s notification preferences.

**Request:**
```json
{
  "morning_brief_enabled": true,
  "positive_enabled": true,
  "nudges_enabled": true,
  "celebration_enabled": true,
  "critical_only": false,
  "morning_brief_time_local": "07:30",
  "quiet_hours_start": "22:00",
  "quiet_hours_end": "07:00",
  "max_positive_per_day": 3,
  "max_nudges_per_day": 2,
  "max_celebration_per_day": 2,
  "max_total_per_day": 6,
  "control_level": "protective",
  "focus_control_enabled": false
}
```

**Rules:**
1. `control_level='guardian'` is allowed only if `focus_control_enabled=true`.
2. If `critical_only=true`, the server must treat other toggles as disabled.
3. Times are interpreted in the user’s local timezone.
4. `focus_control_last_granted_at` is updated only when the system permission is granted (client‑reported).
5. If `critical_only=true`, server must force `control_level='advisory'` and `focus_control_enabled=false`.

---

### Notification Scheduler (Server-Side Logic)

The scheduler enforces caps and priority deterministically.

```
function scheduleNotifications(candidates, settings, nowLocal) {
  if (settings.critical_only) {
    candidates = candidates.filter(c => c.type === 'critical');
  }

  candidates = candidates.filter(c => !isQuietHours(c.sendAtLocal, settings));
  candidates = applyCategoryCaps(candidates, settings); // positive<=max_positive_per_day, nudges<=max_nudges_per_day, celebration<=max_celebration_per_day
  candidates = sortByPriority(candidates); // critical > morning > nudges > positive > celebration

  return candidates.slice(0, settings.max_total_per_day);
}
```

**Priority Order (fixed):**
1. critical
2. morning_brief
3. nudge
4. positive
5. celebration

**Guarantees:**
- Never exceed `max_total_per_day`.
- If a critical alert exists, it is always scheduled unless user disabled notifications entirely.

**Edge Cases:**
1. **Deduplication:** Do not schedule the same notification type more than once within 2 hours.
2. **Coalescing:** If multiple nudges trigger, keep only the highest priority for the next window.
3. **Quiet Hours:** Queue deferred items for the next allowed window (do not send immediately on exit).
4. **Revoked permission:** If notification permission is revoked, disable all non‑critical scheduling and show a banner on next app open.

### GET `/api/recovery/latest`

Get today's recovery score.

**Response:**
```json
{
  "date": "2026-01-18",
  "recovery_score": 78,
  "recovery_zone": "optimal",
  "breakdown": {
    "hrv": { "value": 62, "score": 82, "baseline": 58 },
    "rhr": { "value": 58, "score": 80, "baseline": 60 },
    "sleep": { "duration": 7.33, "quality": 85, "score": 85 },
    "temp": { "deviation_c": 0.2, "score": 75 }
  },
  "recommendation": "Your body is ready...",
  "prediction": {
    "tomorrow_if_sleep_8h": 88,
    "tomorrow_if_sleep_7h": 74,
    "tomorrow_if_sleep_6h": 58
  }
}
```

### GET `/api/recovery/daily?date=2026-01-18`

Get recovery for a specific local date (used by diaries and backfills).

**Response:**
```json
{
  "date": "2026-01-18",
  "recovery_score": 78,
  "recovery_zone": "optimal",
  "data_completeness": 0.92,
  "confidence_score": 0.86,
  "breakdown": {
    "hrv_score": 82,
    "rhr_score": 80,
    "temp_score": 75,
    "sleep_score": 85
  }
}
```

### GET `/api/recovery/trend?days=30`

Get recovery trend over time.

**Response:**
```json
{
  "data": [
    { "date": "2026-01-18", "score": 78 },
    { "date": "2026-01-17", "score": 72 },
    ...
  ],
  "statistics": {
    "average": 76,
    "min": 62,
    "max": 88,
    "std_dev": 6.2
  }
}
```

---

## Unified Daily Diary (V2)

### GET `/api/diary/daily?date=2026-01-18`

Get the full “day view” payload in one request (Recovery/Sleep + Meals + Workouts + Supplements + Labs).

**Goal:** avoid fan‑out API calls and keep the diary fast and deterministic.

**Response (example):**
```json
{
  "date": "2026-01-18",
  "status": "complete",
  "needs_review": false,
  "next_best_action": {
    "type": "log_meal",
    "label_copy_id": "nutrition.diary_log_primary",
    "payload": { "meal_type": "lunch" }
  },
  "recovery": {
    "recovery_score": 78,
    "recovery_zone": "optimal",
    "data_completeness": 0.92,
    "confidence_score": 0.86
  },
  "sleep": {
    "duration_hours": 7.33,
    "deep_sleep_percent": 18,
    "rem_sleep_percent": 22,
    "needs_permission": false
  },
  "nutrition": {
    "calories": { "current": 1420, "target": 1850 },
    "macros": { "protein_g": 95, "carbs_g": 140, "fat_g": 45 },
    "meals": [
      { "id": "uuid", "meal_type": "lunch", "logged_at": "2026-01-18T13:45:00Z", "calories": 520, "needs_review": false }
    ]
  },
  "training": {
    "planned_count": 1,
    "completed_count": 1,
    "sessions": [
      { "id": "uuid", "type": "strength", "duration_minutes": 65, "daily_trimp": 55.2, "needs_review": false }
    ]
  },
  "supplements": {
    "adherence_today_percent": 80,
    "schedule": [
      { "time": "08:00", "supplements": [{ "name": "Vitamin D3", "taken": true }] },
      { "time": "21:00", "supplements": [{ "name": "Magnesium Glycinate", "taken": false }] }
    ]
  },
  "labs": {
    "pending_review_count": 0,
    "recent_changes": []
  }
}
```

**Rules:**
1. `status` values: `no_data | incomplete | needs_review | complete`.
2. `needs_review=true` if any section includes low confidence items or pending OCR review.
3. This endpoint must never require >1 DB round-trip per section; prefer derived views.

### Next Best Action (Deterministic)

`next_best_action` is used by **Home** and **watchOS**. It must be stable for identical inputs.

**Inputs (server-side):**
- `needs_review`, `confidence_score`
- Supplements due soon (next scheduled slot within 0–120 minutes and not taken)
- Nutrition totals vs targets + last logged meal time
- Sleep permission state (`sleep.needs_permission`)
- Unread insights count (`GET /api/insights?unread=true`)

**Priority order (first match wins):**
1. If `needs_review = true` →  
   `type = open_diary`, `label_copy_id = diary.review_required`, payload `{ date, section: "needs_review" }`
2. If a supplement is due soon (≤ 2 hours) →  
   `type = supplement_taken`, `label_copy_id = supplements.log_primary`, payload `{ supplement_name, scheduled_time }`
3. If nutrition is under target and no meal logged in the last 4 hours →  
   `type = log_meal`, `label_copy_id = nutrition.diary_log_primary`, payload `{ meal_type }`
4. If sleep permission is missing →  
   `type = open_sleep`, `label_copy_id = sleep.connect_primary`, payload `{ }`
5. If unread insights exist →  
   `type = insight_acknowledge`, `label_copy_id = insights.acknowledge`, payload `{ insight_id }`
6. Fallback →  
   `type = open_diary`, `label_copy_id = diary.view_day`, payload `{ date }`

**Meal type heuristic (local time):**
- 05:00–10:59 → `breakfast`
- 11:00–14:59 → `lunch`
- 15:00–17:59 → `snack`
- 18:00–22:59 → `dinner`
- 23:00–04:59 → `snack`

**Low‑confidence safeguard:**
- If `confidence_score < 0.65`, do **not** return `supplement_taken` or `log_meal`.
- Use `open_diary` for iOS Home; for watch snapshot return `open_on_iphone` (see watch rules).

### GET `/api/diary/calendar?from=2026-01-01&to=2026-01-31`

Calendar range endpoint for the unified diary month grid (max 62 days).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "days": [
    { "date": "2026-01-18", "status": "complete", "needs_review": false, "recovery_zone": "optimal" },
    { "date": "2026-01-19", "status": "incomplete", "needs_review": false, "recovery_zone": "caution" }
  ]
}
```

---

## Sleep (V2)

### GET `/api/sleep/daily?date=2026-01-18`

Get sleep aggregates for a local date (server-side derived from `physiological_states`).

**Response:**
```json
{
  "date": "2026-01-18",
  "sleep_duration_hours": 7.33,
  "sleep_score": 85,
  "sleep_quality_percent": 85,
  "stages": {
    "deep_sleep_percent": 18,
    "rem_sleep_percent": 22,
    "light_sleep_percent": 55,
    "awake_percent": 5,
    "stages_available": true
  },
  "data_completeness": 0.92,
  "confidence_score": 0.86
}
```

### GET `/api/sleep/calendar?from=2026-01-01&to=2026-01-31`

Sleep diary month grid endpoint (max 62 days).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "days": [
    { "date": "2026-01-18", "sleep_score": 85, "sleep_duration_hours": 7.33, "status": "good" },
    { "date": "2026-01-19", "sleep_score": 58, "sleep_duration_hours": 5.9, "status": "low" }
  ]
}
```

**Status rules (default):**
- `no_data` if missing sleep duration
- `good` if `sleep_score >= 70`
- `low` otherwise

---

## watchOS (V2)

### GET `/api/watch/snapshot?date=2026-01-18`

Return a minimal, safe payload designed for watchOS surfaces (complications + glance view).

> The watch app must not call the backend directly in V2. The **iPhone host** calls this endpoint and syncs the payload to watch via WatchConnectivity (see `life_os_watchos_spec.md`).

**Query params:**
- `date` (optional): local date (YYYY-MM-DD). Defaults to “today” in the user’s configured timezone.

**Response (example):**
```json
{
  "date": "2026-01-18",
  "last_updated_at": "2026-01-18T07:12:00Z",
  "recovery_score": 78,
  "recovery_zone": "optimal",
  "confidence_score": 0.86,
  "next_best_action": {
    "type": "supplement_taken",
    "label_copy_id": "supplements.log_primary",
    "payload": { "supplement_name": "Magnesium Glycinate", "scheduled_time": "21:00" }
  },
  "sleep_duration_hours": 7.33,
  "sleep_quality_percent": 82,
  "nutrition_adherence_percent": 76,
  "supplements_due_soon": { "time": "21:00", "count": 1 }
}
```

**Rules:**
1. Must never include raw HealthKit samples, food photos, or medical documents (only aggregates + safe metadata).
2. Keep response under 4 KB when possible; omit optional fields when null.
3. `confidence_score < 0.65` is “low confidence” and must not drive any risky one‑tap actions on watch.
4. `next_best_action.type` must be in an allowlist:
   - `open_diary`, `open_sleep`, `log_meal`, `supplement_taken`, `insight_acknowledge`, `open_on_iphone`
5. If review/context is required, return:
   - `type='open_on_iphone'`
   - `label_copy_id='global.open_on_iphone'`

### POST `/api/food/log`

Log a meal.

**Request:**
```json
{
  "id": "uuid",
  "logged_at": "2026-01-18T13:45:00Z",
  "logged_date": "2026-01-18",
  "logged_timezone": "Europe/Moscow",
  "logged_utc_offset_minutes": 180,
  "input_method": "vision",
  "meal_type": "lunch",
  "context": "restaurant",
  "items": [
    {
      "id": "uuid",
      "name": "Chicken breast",
      "weight_g": 150,
      "calories": 248,
      "protein_g": 46,
      "fat_g": 5,
      "carbs_g": 0,
      "barcode": "4601234567890",
      "catalog_item_id": "uuid"
    }
  ],
  "image_url": "https://...",
  "ai_confidence": 0.87
}
```

**Item reference rules (authoritative):**
- Each item may reference **at most one** of:
  - `catalog_item_id` (global cached catalog)
  - `user_food_id` (user custom food)
  - `batch_recipe_id` (meal prep portion)
- For `batch_recipe_id` items, the server SHOULD compute macros from the batch’s per‑100g values and `weight_g`, then snapshot into `food_items` (historical logs must not drift when a batch is edited later).

**Response:**
```json
{
  "id": "uuid",
  "created_at": "2026-01-18T13:45:12Z",
  "macros": {
    "calories": 520,
    "protein_g": 65,
    "fat_g": 18,
    "carbs_g": 35
  },
  "daily_progress": {
    "calories": { "consumed": 1420, "target": 1850, "percent": 77 },
    "protein": { "consumed": 95, "target": 120, "percent": 79 }
  },
  "recommendation": "Good protein timing post-workout..."
}
```

### GET `/api/food/log/{id}`

Get a full meal (food log) including items. Used by “Meal Detail / Review Meal”.

**Response:**
```json
{
  "id": "uuid",
  "logged_at": "2026-01-18T13:45:00Z",
  "logged_date": "2026-01-18",
  "meal_type": "lunch",
  "context": "restaurant",
  "input_method": "vision",
  "macros": { "calories": 520, "protein_g": 65, "fat_g": 18, "carbs_g": 35, "fiber_g": 6 },
  "ai_confidence": 0.87,
  "user_corrected": false,
  "user_notes": null,
  "items": [
    {
      "id": "uuid",
      "name": "Chicken breast",
      "brand": null,
      "barcode": "4601234567890",
      "catalog_item_id": "uuid",
      "user_food_id": null,
      "batch_recipe_id": null,
      "weight_g": 150,
      "macros": { "calories": 248, "protein_g": 46, "fat_g": 5, "carbs_g": 0, "fiber_g": 0 },
      "confidence": 0.92,
      "detected_by_ai": true,
      "user_adjusted": false
    }
  ]
}
```

### PATCH `/api/food/log/{id}`

Edit a meal (time/type/context/items). This powers “Review Meal” edits and post-save corrections.

**Rules:**
- Server recalculates meal totals from items and persists authoritative values.
- If items are edited, `food_logs.user_corrected` MUST become `true`.
- Item reference rules are identical to `POST /api/food/log` (catalog/custom/batch are mutually exclusive).

**Request (replace items):**
```json
{
  "logged_at": "2026-01-18T13:55:00Z",
  "meal_type": "lunch",
  "context": "home",
  "items": [
    {
      "name": "Chicken breast",
      "weight_g": 180,
      "catalog_item_id": "uuid"
    }
  ],
  "user_notes": "Less oil than usual"
}
```

**Response:**
```json
{ "ok": true }
```

### DELETE `/api/food/log/{id}`

Soft delete a meal (supports undo for 24 hours).

**Behavior:**
- Sets `food_logs.deleted_at = now()` and `deleted_reason = 'user_deleted'`.
- Does not hard-delete rows (preserves audit + offline sync safety).

**Response:**
```json
{ "ok": true }
```

### POST `/api/food/log/{id}/undo`

Undo a recently deleted meal.

**Rules:**
- Allowed only if deleted within the last 24 hours (configurable).

**Response:**
```json
{ "ok": true }
```

### GET `/api/nutrition/daily?date=2026-01-18`

Get nutrition summary for a day.

**Response:**
```json
{
  "date": "2026-01-18",
  "meals": [
    {
      "id": "uuid",
      "time": "08:30",
      "type": "breakfast",
      "calories": 420,
      "macros": { "P": 25, "F": 18, "C": 45 },
      "input_method": "manual",
      "needs_review": false
    }
  ],
  "totals": {
    "calories": 1420,
    "protein_g": 95,
    "fat_g": 45,
    "carbs_g": 140
  },
  "targets": {
    "calories": 1850,
    "protein_g": 120,
    "fat_g": 60,
    "carbs_g": 180
  },
  "adherence_percent": 77
}
```

### GET `/api/nutrition/calendar?from=2026-01-01&to=2026-01-31`

Lightweight per-day nutrition summary for calendar UI (month/week overview).

**Rules:**
- The response MUST include every date in the inclusive range, even if `meal_count = 0`.
- Max range: 62 days (client should request month-by-month).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "days": [
    {
      "date": "2026-01-18",
      "meal_count": 3,
      "totals": { "calories": 1420, "protein_g": 95, "fat_g": 45, "carbs_g": 140 },
      "targets": { "calories": 1850, "protein_g": 120 },
      "status": "on_target",
      "ai_needs_review": false
    },
    {
      "date": "2026-01-19",
      "meal_count": 0,
      "totals": { "calories": 0, "protein_g": 0, "fat_g": 0, "carbs_g": 0 },
      "targets": { "calories": 1850, "protein_g": 120 },
      "status": "no_data",
      "ai_needs_review": false
    }
  ]
}
```

**Status values:**
- `no_data`
- `needs_review` (AI confidence low; user review required)
- `under_target`
- `on_target`
- `over_target`

**Computation notes (V1):**
- `ai_needs_review` is true if any meal in the day has `ai_confidence < 0.65` AND `user_corrected = false`.
- If `ai_needs_review` is true, `status` MUST be `needs_review`.
- Otherwise, `status` is derived from calorie adherence:
  - `under_target` < 90%
  - `on_target` 90–110%
  - `over_target` > 110%

### GET `/api/foods/search?q=chicken&limit=20`

Search foods for manual logging (merges favorites + recent + user custom + cached catalog items).

**Rules:**
- Always include the user’s favorites and recent foods first when relevant.
- If external provider search is enabled, results MAY include items fetched on-demand and cached into `food_catalog_items`.
- Max `limit`: 50 (default 20).
- Ranking + CIS language rules are defined in `life_os_food_data_strategy.md` (authoritative).

**Implementation note:**
- This endpoint should internally call `POST /functions/v1/foods-search` using a service role when provider search is enabled.

**Response:**
```json
{
  "query": "chicken",
  "limit": 20,
  "results": [
    {
      "type": "custom",
      "id": "uuid",
      "name": "Chicken breast (raw)",
      "brand": null,
      "barcode": null,
      "serving_size_g": 100,
      "macros_per_100g": { "calories": 120, "protein_g": 23, "fat_g": 2.6, "carbs_g": 0, "fiber_g": 0 },
      "tags": ["recent"]
    },
    {
      "type": "catalog",
      "id": "uuid",
      "provider": "open_food_facts",
      "name": "Chicken breast slices",
      "brand": "BrandName",
      "barcode": "4601234567890",
      "serving_size_g": 50,
      "macros_per_100g": { "calories": 110, "protein_g": 21, "fat_g": 2.0, "carbs_g": 1.5, "fiber_g": 0 },
      "tags": ["favorite"]
    }
  ]
}
```

### GET `/api/foods/barcode/4601234567890`

Barcode lookup for packaged foods. If not present in cache, the server will query the configured provider and cache the normalized item into `food_catalog_items`.

**Lookup precedence (authoritative):**
- See `life_os_food_data_strategy.md` (“Deterministic Lookup Order (Barcode)”).

**Implementation note:**
- This endpoint should internally call `POST /functions/v1/foods-barcode-lookup` using a service role.

**Response (found):**
```json
{
  "type": "catalog",
  "id": "uuid",
  "provider": "open_food_facts",
  "name": "Chicken breast slices",
  "brand": "BrandName",
  "barcode": "4601234567890",
  "serving_size_g": 50,
  "macros_per_100g": { "calories": 110, "protein_g": 21, "fat_g": 2.0, "carbs_g": 1.5, "fiber_g": 0 },
  "fetched_at": "2026-02-04T10:12:30Z",
  "expires_at": "2026-03-05T10:12:30Z"
}
```

**Response (user override found):**
```json
{
  "type": "custom",
  "id": "uuid",
  "name": "Chicken breast slices (corrected)",
  "brand": "BrandName",
  "barcode": "4601234567890",
  "serving_size_g": 50,
  "macros_per_100g": { "calories": 105, "protein_g": 22, "fat_g": 1.5, "carbs_g": 1.0, "fiber_g": 0 },
  "tags": ["user_override"]
}
```

**Response (not found):**
```json
{ "error": "barcode_not_found" }
```

### POST `/api/foods/barcode/4601234567890/create`

Create a reusable product for a barcode when providers cannot find it (CIS-critical fallback).

**Flow (must match UX):**
1. Client calls `POST /functions/v1/analyze-food-label` with label photos (no DB writes).
2. Client shows **Review Product** screen and allows edits.
3. Client calls this endpoint with **final normalized values**.

**Request:**
```json
{
  "provider": "lifeos_label_ocr",
  "name": "Kefir 2.5%",
  "brand": "BrandName",
  "serving_size_g": 200,
  "macros_per_100g": {
    "calories": 53,
    "protein_g": 3.0,
    "fat_g": 2.5,
    "carbs_g": 4.0,
    "fiber_g": null
  },
  "source_confidence": 0.84
}
```

**Response:**
```json
{
  "type": "catalog",
  "provider": "lifeos_label_ocr",
  "id": "uuid",
  "barcode": "4601234567890"
}
```

### POST `/api/foods/custom`

Create a custom food item (user-specific).

**Request:**
```json
{
  "id": "uuid",
  "name": "Oatmeal (dry)",
  "brand": null,
  "barcode": null,
  "default_serving_g": 40,
  "macros_per_100g": { "calories": 380, "protein_g": 13, "fat_g": 7, "carbs_g": 67, "fiber_g": 10 }
}
```

**Response:**
```json
{
  "id": "uuid",
  "name": "Oatmeal (dry)",
  "created_at": "2026-02-04T10:15:01Z"
}
```

### POST `/api/foods/favorites`

Add a food to favorites (catalog or custom).

**Request:**
```json
{ "id": "uuid", "ref_type": "catalog", "ref_id": "uuid" }
```

**Response:**
```json
{ "ok": true, "id": "uuid" }
```

### GET `/api/foods/favorites`

List the current user's favorites for local cache reconciliation.

**Response:**
```json
{
  "favorites": [
    {
      "id": "uuid",
      "ref_type": "catalog",
      "ref_id": "uuid",
      "created_at": "2026-02-04T10:15:01Z",
      "updated_at": "2026-02-04T10:15:01Z"
    }
  ]
}
```

### DELETE `/api/foods/favorites/{ref_type}/{ref_id}`

Remove a catalog or custom food from the current user's favorites. The operation
is idempotent and returns `{ "ok": true }` when the favorite is already absent.

### GET `/api/nutrition/templates?limit=20`

List meal templates (Quick Add).

**Response:**
```json
{
  "results": [
    { "id": "uuid", "name": "Protein breakfast", "meal_type": "breakfast", "calories": 520 }
  ]
}
```

### POST `/api/nutrition/templates`

Create a meal template.

**Request:**
```json
{
  "id": "uuid",
  "name": "Protein breakfast",
  "meal_type": "breakfast",
  "template_items": [
    { "name": "Egg", "weight_g": 100, "calories": 143, "protein_g": 13, "fat_g": 10, "carbs_g": 1 }
  ]
}
```

**Response:**
```json
{ "id": "uuid" }
```

### GET `/api/nutrition/templates/{template_id}`

Get full template detail (for edit/preview).

**Response:**
```json
{
  "id": "uuid",
  "name": "Protein breakfast",
  "meal_type": "breakfast",
  "template_items": [
    { "name": "Egg", "weight_g": 100, "calories": 143, "protein_g": 13, "fat_g": 10, "carbs_g": 1 }
  ],
  "archived": false
}
```

### PATCH `/api/nutrition/templates/{template_id}`

Update a template (rename, edit items, archive/unarchive).

**Request:**
```json
{
  "name": "Protein breakfast (v2)",
  "meal_type": "breakfast",
  "template_items": [
    { "name": "Egg", "weight_g": 120, "calories": 171.6, "protein_g": 15.6, "fat_g": 12, "carbs_g": 1.2 }
  ],
  "archived": false
}
```

**Rules:**
1. Editing a template must not mutate historical meal logs (templates are snapshots; logs store their own snapshots).
2. If `archived=true`, the template is hidden from Quick Add by default.

**Response:**
```json
{ "ok": true }
```

### POST `/api/nutrition/templates/{template_id}/log`

Log a meal from a template for a specific date/time (creates `food_logs` + `food_items`).

**Rules:**
- Server MUST set `food_logs.input_method = 'template'`.
- For offline-safe replay, the client SHOULD include a full `items[]` snapshot (with IDs) to avoid drift if the template is edited before the queued mutation is sent.

**Request:**
```json
{
  "food_log_id": "uuid",
  "logged_at": "2026-02-04T08:30:00Z",
  "logged_date": "2026-02-04",
  "logged_timezone": "Europe/Moscow",
  "logged_utc_offset_minutes": 180,
  "meal_type": "breakfast",
  "items": [
    {
      "id": "uuid",
      "name": "Egg",
      "weight_g": 100,
      "calories": 143,
      "protein_g": 13,
      "fat_g": 10,
      "carbs_g": 1,
      "fiber_g": null,
      "barcode": null,
      "catalog_item_id": "uuid",
      "user_food_id": null
    }
  ]
}
```

**Response:**
```json
{ "food_log_id": "uuid", "food_item_ids": ["uuid"] }
```

### GET `/api/nutrition/batches?status=active&limit=20`

List batch meal-prep recipes (each entry is a specific cooked batch with remaining weight tracking).

**Query params:**
- `status`: `active` (default) or `archived`
- `limit`: max 50 (default 20)

**Computation rules:**
- `consumed_weight_g` is derived from `food_items` where `batch_recipe_id = batch_id`, joined to `food_logs` where `deleted_at IS NULL`.
- `weight_remaining_g = max(total_weight_g - consumed_weight_g, 0)`
- `portions_remaining` is derived if `total_portions` is present.

**Response:**
```json
{
  "results": [
    {
      "id": "uuid",
      "name": "Chicken & Rice Meal Prep",
      "cooked_at": "2026-02-03",
      "total_weight_g": 2000,
      "consumed_weight_g": 600,
      "weight_remaining_g": 1400,
      "total_portions": 10,
      "portions_remaining": 7.0,
      "per_portion": { "weight_g": 200, "calories": 264, "protein_g": 27, "fat_g": 3, "carbs_g": 30 }
    }
  ]
}
```

### POST `/api/nutrition/batches`

Create a batch recipe (precise mode).

**Request:**
```json
{
  "id": "uuid",
  "name": "Chicken & Rice Meal Prep",
  "description": "4-day prep",
  "cooked_at": "2026-02-03",
  "total_weight_g": 2000,
  "total_portions": 10,
  "ingredients": [
    {
      "id": "uuid",
      "name": "Chicken breast",
      "brand": null,
      "barcode": null,
      "catalog_item_id": "uuid",
      "weight_g": 1000,
      "macros_total": { "calories": 1238, "protein_g": 232, "fat_g": 27, "carbs_g": 0, "fiber_g": 0 }
    },
    {
      "id": "uuid",
      "name": "Jasmine rice (dry)",
      "catalog_item_id": "uuid",
      "weight_g": 400,
      "macros_total": { "calories": 1440, "protein_g": 30, "fat_g": 3, "carbs_g": 320, "fiber_g": 4 }
    }
  ]
}
```

**Rules:**
- Server recalculates batch totals from ingredient totals and persists:
  - `batch_recipes.total_*` and per-100g derived fields
  - one row per ingredient in `batch_recipe_ingredients`
- The client may submit ingredient totals for offline-first UX, but the server is authoritative.

**Response:**
```json
{ "id": "uuid" }
```

### POST `/api/nutrition/batches/quick`

Create a batch recipe (quick AI mode).

**Request:**
```json
{
  "name": "Meal prep (photo)",
  "cooked_at": "2026-02-03",
  "total_weight_g": 1800,
  "total_portions": 9,
  "image_base64": "data:image/jpeg;base64,..."
}
```

**Behavior:**
- Server calls `POST /functions/v1/analyze-batch-recipe-image`.
- Returns `draft` object that MUST be reviewed client-side before final save.

**Response:**
```json
{
  "draft": {
    "name": "Meal prep (photo)",
    "total_weight_g": 1800,
    "total_portions": 9,
    "ingredients": [
      { "name": "Chicken breast", "weight_g": 900, "confidence": 0.78 }
    ],
    "total_macros": { "calories": 2400, "protein_g": 180, "fat_g": 60, "carbs_g": 240, "fiber_g": 12 },
    "per_100g": { "calories": 133, "protein_g": 10.0, "fat_g": 3.3, "carbs_g": 13.3, "fiber_g": 0.7 },
    "per_portion": { "weight_g": 200, "calories": 266, "protein_g": 20, "fat_g": 7, "carbs_g": 27 },
    "confidence": 0.72,
    "warnings": ["Estimates require review."],
    "needs_review": true
  }
}
```

### GET `/api/nutrition/batches/{batch_id}`

Get full batch recipe detail.

**Response:**
```json
{
  "id": "uuid",
  "name": "Chicken & Rice Meal Prep",
  "description": "4-day prep",
  "cooked_at": "2026-02-03",
  "total_weight_g": 2000,
  "consumed_weight_g": 600,
  "weight_remaining_g": 1400,
  "total_portions": 10,
  "portions_remaining": 7.0,
  "per_100g": { "calories": 132, "protein_g": 13.4, "fat_g": 1.5, "carbs_g": 15.2, "fiber_g": 0.4 },
  "per_portion": { "weight_g": 200, "calories": 264, "protein_g": 27, "fat_g": 3, "carbs_g": 30 },
  "ingredients": [
    { "name": "Chicken breast", "weight_g": 1000, "calories": 1238 }
  ]
}
```

### PATCH `/api/nutrition/batches/{batch_id}`

Update batch metadata (name/description/photo) or correct yield values.

**Rules:**
- Edits must not retroactively change existing `food_logs` already created from this batch.
- Future logs use the updated per-100g/per-portion macros.
- If `ingredients` is provided, the server SHOULD treat it as a full replacement of the ingredient list:
  - upsert by `ingredients[*].id`
  - delete removed ingredient rows for that batch
- If `ingredients` is omitted, the server MUST NOT mutate the ingredient list.

**Request:**
```json
{
  "name": "Chicken & Rice Meal Prep (v2)",
  "description": "5-day prep",
  "image_url": "https://...",
  "cooked_at": "2026-02-03",
  "total_weight_g": 2100,
  "total_portions": 10,
  "archived": false,
  "ingredients": [
    {
      "id": "uuid",
      "name": "Chicken breast",
      "catalog_item_id": "uuid",
      "weight_g": 1050,
      "macros_total": { "calories": 1299.9, "protein_g": 243.6, "fat_g": 28.35, "carbs_g": 0, "fiber_g": 0 }
    }
  ]
}
```

**Response:**
```json
{ "ok": true }
```

### POST `/api/nutrition/batches/{batch_id}/log`

Log a portion of a batch to a meal (creates a `food_log` + a `food_item` with `batch_recipe_id`).

**Rules:**
- Creates a new `food_logs` row with `input_method = 'batch'` (unless overridden by client).
- Creates exactly one `food_items` row:
  - `batch_recipe_id = {batch_id}`
  - `weight_g = portion_weight_g`
  - macros are computed from batch per‑100g values and snapshotted into the item
- If the client supplies `food_log_id` / `food_item_id`, the server MUST use them (offline-safe replay).
- If the client supplies `item_macros_override`, the server SHOULD store them as the snapshot (recommended for offline replay to avoid drift if the batch is edited before sync).
- Updates `batch_recipes.times_used += 1` and sets `last_used_at = now()` (non-authoritative convenience fields).

**Request:**
```json
{
  "food_log_id": "uuid",
  "food_item_id": "uuid",
  "logged_at": "2026-02-04T12:30:00Z",
  "logged_date": "2026-02-04",
  "logged_timezone": "Europe/Moscow",
  "logged_utc_offset_minutes": 180,
  "meal_type": "lunch",
  "portion_weight_g": 220,
  "item_macros_override": {
    "calories": 290,
    "protein_g": 29,
    "fat_g": 3.3,
    "carbs_g": 33,
    "fiber_g": 0.4
  }
}
```

**Response:**
```json
{
  "food_log_id": "uuid",
  "food_item_id": "uuid",
  "batch_id": "uuid",
  "weight_remaining_g": 1180
}
```

### POST `/api/nutrition/batches/{batch_id}/duplicate`

Duplicate a batch recipe to cook it again (keeps ingredients/description; no consumption logs are copied).

**Response:**
```json
{ "id": "new_uuid" }
```

### POST `/api/workouts/log`

Log a workout session with exercises and sets.

**Request:**
```json
{
  "id": "uuid",
  "started_at": "2026-01-18T18:00:00Z",
  "session_date": "2026-01-18",
  "started_timezone": "Europe/Moscow",
  "started_utc_offset_minutes": 180,
  "ended_at": "2026-01-18T19:05:00Z",
  "workout_type": "strength",
  "source": "manual",
  "exercises": [
    {
      "id": "uuid",
      "exercise_id": "uuid",
      "order_in_session": 1,
      "sets": [
        { "id": "uuid", "set_number": 1, "weight": 60, "reps": 8, "rpe": 7 },
        { "id": "uuid", "set_number": 2, "weight": 65, "reps": 8, "rpe": 8 }
      ]
    }
  ]
}
```

**Response:**
```json
{
  "id": "uuid",
  "total_volume": 1040,
  "estimated_calories": 320,
  "trimp_score": 55.2,
  "training_load_updated": true
}
```

### GET `/api/workouts/{session_id}`

Get full workout session detail (used by session detail screens and conflict resolution).

**Response:**
```json
{
  "id": "uuid",
  "started_at": "2026-01-18T18:00:00Z",
  "ended_at": "2026-01-18T19:05:00Z",
  "session_date": "2026-01-18",
  "workout_type": "strength",
  "source": "manual",
  "total_volume": 1040,
  "estimated_calories": 320,
  "trimp_score": 55.2,
  "notes": null,
  "exercises": [
    {
      "id": "uuid",
      "exercise_id": "uuid",
      "name": "Bench Press",
      "order_in_session": 1,
      "sets": [
        { "id": "uuid", "set_number": 1, "weight": 60, "reps": 8, "rpe": 7 }
      ]
    }
  ]
}
```

### PATCH `/api/workouts/{session_id}`

Edit a workout session. For simplicity and consistency, the server SHOULD support “replace exercises/sets” semantics.

**Rules:**
- If the session is `source='import'`, editing sets may be restricted; the client may still update `notes` and `perceived_exertion_rpe`.
- If a session is edited, downstream aggregates (training load, daily summaries) must be recomputed deterministically.

**Request (replace exercises/sets):**
```json
{
  "started_at": "2026-01-18T18:05:00Z",
  "ended_at": "2026-01-18T19:10:00Z",
  "workout_type": "strength",
  "perceived_exertion_rpe": 8,
  "notes": "Felt strong",
  "exercises": [
    {
      "id": "uuid",
      "exercise_id": "uuid",
      "order_in_session": 1,
      "sets": [
        { "id": "uuid", "set_number": 1, "weight": 62.5, "reps": 8, "rpe": 8 },
        { "id": "uuid", "set_number": 2, "weight": 67.5, "reps": 6, "rpe": 9 }
      ]
    }
  ]
}
```

**Response:**
```json
{ "ok": true }
```

### DELETE `/api/workouts/{session_id}`

Soft delete a workout session (supports undo for 24 hours).

**Behavior:**
- Sets `workout_sessions.deleted_at = now()` and `deleted_reason = 'user_deleted'`.

**Response:**
```json
{ "ok": true }
```

### POST `/api/workouts/{session_id}/undo`

Undo a recently deleted workout.

**Response:**
```json
{ "ok": true }
```

### GET `/api/exercises/search?q=bench&limit=20`

Search the exercise catalog (global + user custom exercises).

**Rules:**
- Default ordering: name match → recent usage → favorites (optional).
- The response MAY include both global exercises and user-created custom exercises.

**Response:**
```json
{
  "query": "bench",
  "results": [
    {
      "id": "uuid",
      "name": "Bench Press",
      "category": "strength",
      "equipment": ["barbell"],
      "is_custom": false
    }
  ]
}
```

### POST `/api/exercises/custom`

Create a custom exercise (user-owned).

**Request:**
```json
{
  "id": "uuid",
  "name": "Cable Y-Raise",
  "category": "strength",
  "primary_muscles": ["shoulders"],
  "equipment": ["cable"]
}
```

**Response:**
```json
{ "id": "uuid" }
```

### GET `/api/workouts/daily?date=2026-01-18`

Get workouts for a day.

**Rules:**
- Return only sessions where `workout_sessions.deleted_at IS NULL`.

**Response:**
```json
{
  "date": "2026-01-18",
  "sessions": [
    {
      "id": "uuid",
      "workout_type": "strength",
      "duration_minutes": 65,
      "total_volume": 1040
    }
  ]
}
```

### GET `/api/workouts/calendar?from=2026-01-01&to=2026-01-31`

Lightweight per-day training summary for calendar UI (planned vs logged).

**Rules:**
- The response MUST include every date in the inclusive range.
- Max range: 62 days.

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "days": [
    {
      "date": "2026-01-20",
      "planned_count": 1,
      "completed_count": 0,
      "workout_count": 0,
      "totals": { "duration_minutes": 0, "daily_trimp": 0 },
      "training_zone": "optimal",
      "status": "planned"
    },
    {
      "date": "2026-01-18",
      "planned_count": 0,
      "completed_count": 1,
      "workout_count": 1,
      "totals": { "duration_minutes": 65, "daily_trimp": 55.2 },
      "training_zone": "optimal",
      "status": "completed"
    }
  ]
}
```

**Status values:**
- `rest` (no plan, no workout)
- `planned`
- `completed`
- `missed` (plan existed, date passed, no completed workout)

**Computation notes (V1):**
- `planned_count` is derived from `training_plan_sessions` for that date (status in `planned|rescheduled` counts as planned).
- `completed_count` is derived from `training_plan_sessions` status `completed` OR a linked `actual_session_id`.
- `workout_count` is derived from `workout_sessions` on that `session_date` where `deleted_at IS NULL`.
- `status` logic:
  - if `completed_count > 0` OR `workout_count > 0` → `completed`
  - else if `planned_count > 0` and date is in the future or today → `planned`
  - else if `planned_count > 0` and date is in the past → `missed`
  - else → `rest`

### GET `/api/workouts/summary?days=30`

Get workout summary and trends.

**Rules:**
- Exclude sessions where `deleted_at IS NOT NULL`.

**Response:**
```json
{
  "range_days": 30,
  "workout_count": 12,
  "total_volume": 18240,
  "average_trimp": 42.5,
  "acwr": 1.12
}
```

### GET `/api/workouts/weekly?from=2026-01-01&to=2026-02-28`

Weekly session metrics (for Training Load Analysis).

**Rules:**
- Weeks are ISO weeks (Mon–Sun) based on user timezone.
- Exclude sessions where `deleted_at IS NOT NULL`.
- Max range: 26 weeks per request.

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-02-28",
  "weeks": [
    {
      "week_start": "2026-01-05",
      "week_end": "2026-01-11",
      "session_count": 4,
      "total_duration_minutes": 240,
      "total_trimp": 180.5,
      "average_trimp": 45.1
    }
  ]
}
```

### POST `/api/training/plan/generate`

Generate and store a new training plan.

**Request:**
```json
{
  "goal": "hypertrophy",
  "experience_level": "intermediate",
  "available_days": [1, 3, 5, 6],
  "session_duration_minutes": 60,
  "equipment_access": "gym",
  "injuries": ["shoulder_impingement"]
}
```

**Response:**
```json
{
  "plan_id": "uuid",
  "status": "active",
  "weeks_generated": 4
}
```

### GET `/api/training/plan/active`

Get the currently active training plan.

**Response:**
```json
{
  "plan_id": "uuid",
  "name": "4-Week Hypertrophy Block",
  "current_week": 2,
  "sessions": [
    { "date": "2026-01-20", "session_type": "strength", "status": "planned" }
  ]
}
```

### GET `/api/training/plan/{id}`

Fetch a specific training plan by ID (active or archived).

**Response (200):**
```json
{
  "id": "uuid",
  "name": "Hypertrophy Block A",
  "status": "active | paused | completed | archived",
  "goal": "strength | hypertrophy | endurance | general_fitness",
  "duration_weeks": 8,
  "sessions_per_week": 4,
  "adaptive_rules": { ... },
  "created_at": "ISO 8601",
  "updated_at": "ISO 8601"
}
```

**Errors:** `TrainingPlanError.planNotActive (6304)` if plan does not exist or does not belong to the user.

### GET `/api/training/plan/sessions?from=2026-01-01&to=2026-01-31`

Get planned sessions for the active plan in a date range (calendar view).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "sessions": [
    {
      "id": "uuid",
      "plan_id": "uuid",
      "planned_date": "2026-01-20",
      "session_type": "strength",
      "status": "planned",
      "title": "Upper A"
    }
  ]
}
```

### PATCH `/api/training/plan/{id}`

Update plan metadata or status (pause, resume, archive, complete).

**Request:**
```json
{
  "status": "paused",          // optional: active | paused | completed | archived
  "name": "Updated Plan Name"  // optional
}
```

**Response (200):**
```json
{ "ok": true, "plan_id": "uuid", "status": "paused" }
```

**Errors:** `TrainingPlanError.planNotActive (6304)` if plan not found.

### PATCH `/api/training/plan/{id}/adjust`

Apply adaptive adjustments based on recovery or load.

**Request:**
```json
{
  "reason": "recovery_low",
  "adjustment": "reduce_volume_30"
}
```

**Valid `reason` values:** `recovery_low | recovery_critical | fatigue_accumulation | injury_flag | user_request | schedule_conflict | load_spike_acwr`

**Valid `adjustment` values:** `reduce_volume_30 | reduce_intensity_20 | skip_session | swap_to_mobility | extend_rest_day | deload_week`

**Response:**
```json
{
  "plan_id": "uuid",
  "adjusted": true,
  "effective_from": "2026-01-19"
}
```

### POST `/api/user-supplements`

Create a supplement in the user stack (schedule + dosage).

**Request:**
```json
{
  "id": "uuid",
  "catalog_id": "uuid",
  "custom_name": null,
  "dose_amount": 200,
  "dose_unit": "mg",
  "frequency": "daily",
  "scheduled_times": ["08:00", "21:00"],
  "days_of_week": null,
  "take_with_food": false,
  "notes": "evening routine",
  "active": true
}
```

**Response:** Full `user_supplements` row as JSON.

### GET `/api/user-supplements`

List the user’s supplement stack (active by default).

**Response:**
```json
{
  "items": [
    { "id": "uuid", "name": "Magnesium Glycinate", "frequency": "daily", "scheduled_times": ["21:00"], "active": true }
  ]
}
```

### PATCH `/api/user-supplements/{id}`

Update schedule, dosage, or status.

**Request:** Partial `user_supplements` fields.

### DELETE `/api/user-supplements/{id}`

Deactivate a supplement (sets `active=false`, `ended_at=now()`).

### POST `/api/supplements/log`

Log supplement intake.

**Request:**
```json
{
  "id": "uuid",
  "supplement_name": "Magnesium Glycinate",
  "taken_at": "2026-01-18T21:00:00Z",
  "taken_date": "2026-01-18",
  "taken_timezone": "Europe/Moscow",
  "taken_utc_offset_minutes": 180,
  "dose_amount": 200,
  "dose_unit": "mg",
  "with_food": false,
  "felt_effect": "positive",
  "notes": "calmer"
}
```

**Response:**
```json
{
  "id": "uuid",
  "adherence_today_percent": 80
}
```

### GET `/api/supplements/schedule?date=2026-01-18`

Get supplement schedule for a day.

**Response:**
```json
{
  "date": "2026-01-18",
  "schedule": [
    { "time": "08:00", "supplements": ["Vitamin D3"] },
    { "time": "21:00", "supplements": ["Magnesium Glycinate"] }
  ]
}
```

### GET `/api/supplements/daily?date=2026-01-18`

Get supplement schedule + taken status for a day (diary-friendly).

**Response:**
```json
{
  "date": "2026-01-18",
  "adherence_today_percent": 80,
  "schedule": [
    {
      "time": "08:00",
      "supplements": [
        { "name": "Vitamin D3", "taken": true, "log_id": "uuid" }
      ]
    },
    {
      "time": "21:00",
      "supplements": [
        { "name": "Magnesium Glycinate", "taken": false, "log_id": null }
      ]
    }
  ],
  "unscheduled_logs": [
    { "time": "15:10", "name": "Zinc", "log_id": "uuid" }
  ]
}
```

### GET `/api/supplements/calendar?from=2026-01-01&to=2026-01-31`

Supplements diary month grid endpoint (max 62 days).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "days": [
    { "date": "2026-01-18", "adherence_today_percent": 80, "status": "complete" },
    { "date": "2026-01-19", "adherence_today_percent": 20, "status": "incomplete" }
  ]
}
```

**Status rules (default):**
- `no_data` if no scheduled supplements exist for that day
- `complete` if adherence_today_percent >= 80
- `incomplete` otherwise

### POST `/api/labs/scan`

Import a lab report and produce normalized markers (OCR + review workflow).

**Privacy:**
- Default: `storage_mode = "local_only"` (raw documents stay on device; only derived markers may sync).
- If the user opts in: `storage_mode = "cloud"` enables cloud OCR and optional cloud storage of the original scan.
- If the user does not opt into labs sync at all, the client MUST store scans and markers locally and SHOULD NOT call this endpoint.

**Request (cloud OCR):**
```json
{
  "scan_id": "uuid",
  "scan_type": "blood_test",
  "storage_mode": "cloud",
  "store_original_in_cloud": true,
  "image_base64": "data:image/jpeg;base64,...",
  "scan_date": "2026-01-18"
}
```

**Request (local-only raw, derived-only sync):**
```json
{
  "scan_id": "uuid",
  "scan_type": "blood_test",
  "storage_mode": "local_only",
  "scan_date": "2026-01-18",
  "processed_data": {
    "lab_name": "Invitro",
    "scan_date": "2026-01-18",
    "markers": [
      { "marker_id": "vitamin_d_25oh", "value": 24, "unit": "ng/mL", "confidence": 0.78 }
    ]
  }
}
```

**Response:**
```json
{
  "scan_id": "uuid",
  "status": "processing"
}
```

### GET `/api/labs/scan/{scan_id}`

Get scan status and extracted structured data.

**Response:**
```json
{
  "scan_id": "uuid",
  "storage_mode": "cloud",
  "original_image_url": "https://...",
  "status": "processing",
  "confidence": null,
  "processed_data": null
}
```

**Response (completed):**
```json
{
  "scan_id": "uuid",
  "storage_mode": "cloud",
  "original_image_url": "https://...",
  "status": "completed",
  "confidence": 0.82,
  "processed_data": {
    "lab_name": "Invitro",
    "scan_date": "2026-01-18",
    "markers": [
      {
        "marker_id": "vitamin_d_25oh",
        "original_label": "25-OH Витамин D",
        "value": 24,
        "unit": "ng/mL",
        "reference_range": { "low": 30, "high": 100 },
        "status": "low",
        "confidence": 0.78
      }
    ]
  }
}
```

### GET `/api/labs/markers?marker_id=vitamin_d_25oh`

Get biomarker history.

**Response:**
```json
{
  "marker_id": "vitamin_d_25oh",
  "history": [
    { "date": "2026-01-18", "value": 24, "unit": "ng/mL", "status": "low" },
    { "date": "2025-11-02", "value": 31, "unit": "ng/mL", "status": "optimal" }
  ]
}
```

### POST `/api/experiments/create`

Create a new experiment.

**Request:**
```json
{
  "id": "uuid",
  "title": "Supplement Routine & Sleep Quality",
  "hypothesis": "Consistent evening supplement timing improves sleep quality",
  "variable": "supplement_timing_routine",
  "control_description": "No planned supplement routine",
  "intervention_description": "User-provided supplement routine (timing only, no dosing)",
  "baseline_duration_days": 7,
  "intervention_duration_days": 14,
  "primary_metric": "sleep_quality",
  "secondary_metrics": ["deep_sleep_percent", "hrv_morning"]
}
```

**Response:**
```json
{
  "id": "uuid",
  "status": "baseline",
  "baseline_start_date": "2026-01-19",
  "baseline_end_date": "2026-01-25",
  "intervention_start_date": "2026-01-26",
  "intervention_end_date": "2026-02-08",
  "reminders_scheduled": true
}
```

### GET `/api/insights?unread=true`

Get AI-generated insights.

**Response:**
```json
{
  "insights": [
    {
      "id": "uuid",
      "type": "correlation",
      "priority": "high",
      "title": "Sleep-Sugar Correlation Detected",
      "description": "You consume 40% more sugar on days with less than 7 hours sleep",
      "confidence": 0.94,
      "data_points": 45,
      "created_at": "2026-01-18T09:00:00Z",
      "suggested_action": "Experiment: Track sleep vs sugar intake"
    }
  ],
  "count": 3
}
```

### GET `/api/insights/{id}`

Get full insight detail.

**Response:**
```json
{
  "id": "uuid",
  "type": "correlation",
  "priority": "high",
  "title": "Sleep-Sugar Correlation Detected",
  "description": "You consume 40% more sugar on days with less than 7 hours sleep",
  "reasoning": "Lower sleep duration correlates with higher evening sugar intake.",
  "confidence": 0.94,
  "data_points": 45,
  "related_dates": ["2026-01-01", "2026-01-18"],
  "related_metrics": ["sleep_duration_hours", "sugar_g"],
  "correlation_method": "spearman",
  "p_value": 0.0123,
  "lag_days": 1,
  "confounders": ["day_of_week"],
  "suggested_experiment_id": "uuid"
}
```

### GET `/api/weekly-strategy?week_start=2026-01-12`

Get the weekly strategy report for a given week.

**Response:**
```json
{
  "report_id": "uuid",
  "week_start": "2026-01-12",
  "week_end": "2026-01-18",
  "report_markdown": "# Week 3 Review\n\n## By The Numbers\n...",
  "summary_stats": {
    "avg_recovery_score": 72,
    "recovery_trend": "stable",
    "days_in_optimal_zone": 2,
    "days_in_critical_zone": 0,
    "avg_sleep_duration": 7.1,
    "sleep_consistency": 0.76,
    "nutrition_adherence": 0.82,
    "training_volume": 1850,
    "allostatic_load": 0.38
  }
}
```

**Insight JSON Schema (Validation):**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["id", "type", "priority", "title", "description", "confidence"],
  "properties": {
    "id": { "type": "string", "format": "uuid" },
    "type": { "type": "string", "enum": ["pattern", "correlation", "trend", "anomaly", "recommendation", "warning"] },
    "priority": { "type": "string", "enum": ["low", "medium", "high", "critical"] },
    "title": { "type": "string", "minLength": 3 },
    "description": { "type": "string", "minLength": 3 },
    "reasoning": { "type": ["string", "null"] },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
    "data_points": { "type": ["integer", "null"], "minimum": 1 },
    "related_metrics": { "type": ["array", "null"], "items": { "type": "string", "description": "metric_key enum" } },
    "correlation_method": { "type": ["string", "null"], "enum": ["spearman", "pearson", "partial_spearman"] },
    "p_value": { "type": ["number", "null"], "minimum": 0, "maximum": 1 },
    "lag_days": { "type": ["integer", "null"], "minimum": 0, "maximum": 2 },
    "confounders": { "type": ["array", "null"], "items": { "type": "string" } },
    "suggested_experiment_id": { "type": ["string", "null"], "format": "uuid" }
  }
}
```

**Insight Surfacing Rules (Server):**
1. `confidence_score < 0.65` → do not push notification; surface only in list with “Low confidence”.
2. `data_points < 7` → block suggestion for experiments.
3. `type='warning'` + `priority='critical'` may trigger a critical alert (if allowed).

### POST `/api/insights/{id}/acknowledge`

Mark an insight as seen/acknowledged.

**Response:**
```json
{ "ok": true }
```

### POST `/api/insights/{id}/dismiss`

Dismiss an insight (removes from active list).

**Response:**
```json
{ "ok": true }
```

### GET `/api/recommendations?date=2026-01-18`

Fetch daily recommendations for a date (defaults to today).

**Response:**
```json
{
  "date": "2026-01-18",
  "recommendations": [
    {
      "id": "uuid",
      "category": "recovery",
      "priority": "high",
      "title": "Prioritize an earlier bedtime",
      "description": "Aim for 8+ hours tonight to recover fully.",
      "dismissed": false
    }
  ]
}
```

### POST `/api/recommendations/{id}/dismiss`

Dismiss a recommendation.

**Response:**
```json
{ "ok": true }
```

### POST `/api/experiments/{id}/log`

Log daily experiment measurements.

**Request:**
```json
{
  "id": "uuid",
  "date": "2026-01-20",
  "measurements": {
    "sleep_quality": 82,
    "deep_sleep_percent": 19,
    "hrv_morning": 58
  },
  "notes": "Felt rested, low caffeine."
}
```

**Response:**
```json
{
  "measurement_id": "uuid",
  "status": "baseline",
  "logged": true
}
```

**Experiment Log JSON Schema (Validation):**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["date", "measurements"],
  "properties": {
    "date": { "type": "string", "format": "date" },
    "measurements": { "type": "object" },
    "notes": { "type": ["string", "null"], "maxLength": 500 }
  }
}
```

### DELETE `/api/supplements/log/{id}`

Soft delete a supplement log entry (supports undo for 24 hours).

**Behavior:**
- Sets `supplement_logs.deleted_at = now()` and `deleted_reason = 'user_deleted'`.

**Response:**
```json
{ "ok": true }
```

### POST `/api/supplements/log/{id}/undo`

Undo a recently deleted supplement log.

**Rules:**
- Allowed only if deleted within the last 24 hours.

**Response:**
```json
{ "ok": true }
```

### GET `/api/supplements/history?from=2026-01-01&to=2026-01-31`

Supplement intake history by date range (max 62 days).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "logs": [
    {
      "id": "uuid",
      "taken_date": "2026-01-18",
      "supplement_name": "Vitamin D3",
      "dose_amount": 5000,
      "dose_unit": "IU",
      "with_food": true,
      "felt_effect": "positive"
    }
  ]
}
```

### DELETE `/api/experiments/{id}`

Soft delete an experiment (supports undo for 24 hours).

**Behavior:**
- Sets `experiments.deleted_at = now()` and `deleted_reason = 'user_deleted'`.
- Preserves all measurement data for undo.

**Response:**
```json
{ "ok": true }
```

### POST `/api/experiments/{id}/undo`

Undo a recently deleted experiment.

**Response:**
```json
{ "ok": true }
```

### DELETE `/api/food/template/{id}`

Soft delete a meal template (supports undo for 24 hours).

**Behavior:**
- Sets `meal_templates.deleted_at = now()` and `deleted_reason = 'user_deleted'`.

**Response:**
```json
{ "ok": true }
```

### DELETE `/api/food/batch/{id}`

Soft delete a batch recipe (supports undo for 24 hours).

**Behavior:**
- Sets `batch_recipes.deleted_at = now()` and `deleted_reason = 'user_deleted'`.
- Does not affect food_logs that already referenced this batch.

**Response:**
```json
{ "ok": true }
```

### DELETE `/api/exercises/custom/{id}`

Delete a user-created custom exercise from the catalog.

**Rules:**
- Only exercises with `is_custom = TRUE` and `created_by = current_user` can be deleted.
- Existing workout_exercises referencing this exercise are preserved (SET NULL on FK).

**Response:**
```json
{ "ok": true }
```

### GET `/api/labs/markers/history?marker_id=vitamin_d_25oh&from=2025-07-01&to=2026-01-31`

Lab marker values over time (max 1 year).

**Response:**
```json
{
  "marker_id": "vitamin_d_25oh",
  "marker_name": "Vitamin D (25-OH)",
  "unit": "ng/mL",
  "history": [
    { "date": "2025-07-15", "value": 28.5, "status": "low", "scan_id": "uuid" },
    { "date": "2025-12-20", "value": 42.1, "status": "optimal", "scan_id": "uuid" }
  ]
}
```

### POST `/api/wellness/check`

Log a daily wellness check (subjective morning check-in).

**Request:**
```json
{
  "id": "uuid",
  "date": "2026-01-18",
  "perceived_sleep_quality": 4,
  "energy_level": 4,
  "muscle_soreness": 2,
  "stress_level": 3,
  "mood": 4,
  "pss4_q1": 1,
  "pss4_q2": 2,
  "pss4_q3": 2,
  "pss4_q4": 1,
  "feeling_ill": false,
  "notes": "Slept well"
}
```

**Response:**
```json
{ "ok": true, "date": "2026-01-18", "wellness_score": 78 }
```

### GET `/api/wellness/history?from=2026-01-01&to=2026-01-31`

Wellness check history including PSS-4 scores by date range (max 62 days).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "checks": [
    {
      "date": "2026-01-18",
      "energy_level": 4,
      "mood": 4,
      "stress_level": 2,
      "pss4_total": 6,
      "wellness_score": 78.5
    }
  ]
}
```

### POST `/api/hydration/log`

Log a water intake event.

**Request:**
```json
{
  "id": "uuid",
  "logged_at": "2026-01-18T12:30:00Z",
  "logged_date": "2026-01-18",
  "logged_timezone": "Europe/Moscow",
  "logged_utc_offset_minutes": 180,
  "water_ml": 350,
  "source": "manual",
  "notes": "Post-workout"
}
```

**Response:**
```json
{ "ok": true, "id": "uuid" }
```

### GET `/api/hydration/daily?date=2026-01-18`

Daily hydration totals + entries.

**Response:**
```json
{
  "date": "2026-01-18",
  "total_water_ml": 1850,
  "goal_ml": 2500,
  "entries": [
    { "id": "uuid", "logged_at": "2026-01-18T08:10:00Z", "water_ml": 300, "source": "manual" },
    { "id": "uuid", "logged_at": "2026-01-18T12:30:00Z", "water_ml": 350, "source": "manual" }
  ]
}
```

### GET `/api/hydration/history?from=2026-01-01&to=2026-01-31`

Hydration totals by date range (max 62 days).

**Response:**
```json
{
  "from": "2026-01-01",
  "to": "2026-01-31",
  "days": [
    { "date": "2026-01-18", "total_water_ml": 1850, "goal_ml": 2500 }
  ]
}
```

### PATCH `/api/hydration/log/{id}`

Update a previously logged hydration entry.

**Auth:** Bearer JWT (RLS: owner only)

**Headers:**
- `Idempotency-Key` (required)
- `X-Device-Id`

**Path:** `id` — UUID of the hydration_log

**Body (partial update):**
| Field | Type | Notes |
|-------|------|-------|
| `amount_ml` | integer | Optional |
| `beverage_type` | string | Optional (e.g., "water", "coffee", "tea") |
| `logged_date` | YYYY-MM-DD | Optional (local date) |
| `logged_timezone` | string | Optional |

**Response:** `200` — updated hydration_log object
**Errors:** `404` if not found or not owned by user

### DELETE `/api/hydration/log/{id}`

Soft-delete a hydration log entry (sets `deleted_at`).

**Auth:** Bearer JWT (RLS: owner only)

**Headers:**
- `Idempotency-Key` (required)
- `X-Device-Id`

**Path:** `id` — UUID of the hydration_log

**Response:** `200` — `{ "deleted": true, "id": "<id>" }`
**Errors:** `404` if not found or not owned by user

### POST `/api/body-composition`

Log a body composition measurement (manual or device-imported).

**Request:**
```json
{
  "id": "uuid",
  "measured_at": "2026-01-18T07:10:00Z",
  "input_type": "home_scale",
  "weight_kg": 72.4,
  "body_fat_percent": 18.2,
  "muscle_mass_kg": 32.1,
  "water_percent": 54.3,
  "visceral_fat_level": 8,
  "source": "withings",
  "scan_image_url": null
}
```

**Response:** Full `body_composition` row as JSON.

### GET `/api/body-composition/history?from=2026-01-01&to=2026-01-31`

Fetch body composition history (max 62 days).

### PATCH `/api/body-composition/{id}`

Update a measurement (e.g., correct a value).

### DELETE `/api/body-composition/{id}`

Delete a measurement (hard delete; no undo).

### GET `/api/user/profile`

Fetch the user’s profile data.

**Response:**
```json
{
  "id": "uuid",
  "email": "user@example.com",
  "display_name": "Alex",
  "date_of_birth": "1992-04-12",
  "sex": "female",
  "height_cm": 168,
  "weight_kg": 62.5,
  "primary_goal": "recovery",
  "activity_level": "moderate",
  "timezone": "Europe/Moscow",
  "units": "metric"
}
```

### PATCH `/api/user/profile`

Update user profile fields.

**Request:** Partial `users` profile fields (no auth_id changes).

### PATCH `/api/user/health-flags`

Create or update user health flags (onboarding screening).

**Request:**
```json
{
  "has_cardiac_condition": false,
  "has_pacemaker": false,
  "on_beta_blockers": false,
  "is_pregnant": false,
  "has_eating_disorder_history": false,
  "has_chronic_fatigue": false,
  "menstrual_tracking_enabled": false
}
```

**Response:**
```json
{
  "ok": true,
  "app_overrides": {
    "disable_hrv": false,
    "hide_calories": false,
    "pregnancy_mode": false
  }
}
```

### GET `/api/user/health-flags`

Retrieve current health flags and derived app behavior overrides.

**Response:**
```json
{
  "has_cardiac_condition": false,
  "has_pacemaker": false,
  "on_beta_blockers": false,
  "is_pregnant": false,
  "has_eating_disorder_history": false,
  "has_chronic_fatigue": false,
  "menstrual_tracking_enabled": false,
  "app_overrides": {
    "disable_hrv": false,
    "hide_calories": false,
    "pregnancy_mode": false
  }
}
```

---

## SLEEP DIARY (V2)

> [!NOTE]
> Sleep diary is a V2 feature. Tables and endpoints below are reserved for V2 implementation.
> V1 relies on HealthKit-derived sleep data only (see `life_os_healthkit_spec.md`).

### Table: `sleep_logs`

User-reported sleep diary entries (subjective data complementing HealthKit objective data).

```sql
CREATE TABLE sleep_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Date assignment
    sleep_date DATE NOT NULL,              -- The "night-of" date (morning after = this date)
    sleep_timezone TEXT,                   -- IANA timezone at bedtime
    sleep_utc_offset_minutes INTEGER,

    -- Subjective sleep data
    bedtime_intended TIME,                 -- When user intended to go to bed
    bedtime_actual TIME,                   -- When user actually got into bed
    waketime TIME,                         -- When user woke up
    time_to_fall_asleep_minutes INTEGER,   -- Estimated sleep onset latency
    interruptions INTEGER DEFAULT 0,       -- Number of wake-ups during night
    perceived_quality INTEGER CHECK (perceived_quality BETWEEN 1 AND 5), -- 1=terrible, 5=excellent

    -- Pre-sleep context
    caffeine_after_14 BOOLEAN,             -- Optional diary signal; not used when caffeine_mg is available
    alcohol BOOLEAN,
    screen_before_bed BOOLEAN,
    exercise_evening BOOLEAN,
    heavy_meal_late BOOLEAN,
    stressful_day BOOLEAN,

    -- Environment
    room_temperature TEXT CHECK (room_temperature IN ('too_cold', 'comfortable', 'too_hot')),
    room_darkness TEXT CHECK (room_darkness IN ('dark', 'some_light', 'bright')),
    noise_level TEXT CHECK (noise_level IN ('silent', 'some_noise', 'noisy')),

    -- Morning feel
    morning_energy INTEGER CHECK (morning_energy BETWEEN 1 AND 5),
    dream_recall BOOLEAN,
    notes TEXT,

    -- Soft delete
    deleted_at TIMESTAMPTZ,

    UNIQUE(user_id, sleep_date)
);

CREATE INDEX idx_sleep_logs_user ON sleep_logs(user_id, sleep_date DESC) WHERE deleted_at IS NULL;

CREATE TRIGGER set_sleep_logs_updated_at
    BEFORE UPDATE ON sleep_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

### POST `/api/sleep/log` (V2)

Log a subjective sleep diary entry.

**Request:**
```json
{
  "id": "uuid",
  "sleep_date": "2026-01-18",
  "bedtime_actual": "23:15",
  "waketime": "07:10",
  "time_to_fall_asleep_minutes": 12,
  "interruptions": 1,
  "perceived_quality": 4,
  "caffeine_after_14": false,
  "alcohol": false,
  "room_temperature": "comfortable",
  "morning_energy": 4,
  "notes": "Good night, one brief wake-up."
}
```

**Response:**
```json
{
  "log_id": "uuid",
  "sleep_date": "2026-01-18",
  "ok": true
}
```

### GET `/api/sleep/log?date=2026-01-18` (V2)

Retrieve a sleep diary entry for a specific date.

**Response:** Full `sleep_logs` row as JSON.

### PATCH `/api/sleep/log/{id}` (V2)

Update a previously logged sleep entry.

**Auth:** Bearer JWT (RLS: owner only)

**Headers:**
- `Idempotency-Key` (required)
- `X-Device-Id`

**Path:** `id` — UUID of the sleep_log

**Body (partial update):**
| Field | Type | Notes |
|-------|------|-------|
| `bedtime` | ISO 8601 | Optional |
| `wake_time` | ISO 8601 | Optional |
| `sleep_quality` | integer 1-5 | Optional |
| `notes` | string | Optional |
| `sleep_date` | YYYY-MM-DD | Optional (local date) |
| `sleep_timezone` | string | Optional |

**Response:** `200` — updated sleep_log object
**Errors:** `404` if not found or not owned by user

### DELETE `/api/sleep/log/{id}` (V2)

Soft-delete a sleep log entry (sets `deleted_at`).

**Auth:** Bearer JWT (RLS: owner only)

**Headers:**
- `Idempotency-Key` (required)
- `X-Device-Id`

**Path:** `id` — UUID of the sleep_log

**Response:** `200` — `{ "deleted": true, "id": "<id>" }`
**Errors:** `404` if not found or not owned by user

---

## TRAINING TEMPLATES (V2)

> [!NOTE]
> Training templates are a V2 feature. Distinct from AI-generated `training_plans`.
> Templates are user-created reusable workout structures for quick logging.

### Table: `training_templates`

Reusable workout templates for one-tap workout logging.

```sql
CREATE TABLE training_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    name TEXT NOT NULL,
    category TEXT CHECK (category IN ('strength', 'cardio', 'mobility', 'sport', 'other')),
    estimated_duration_minutes INTEGER,

    -- Snapshot of exercises at template creation time
    -- Shape: array of { exercise_id?, exercise_name, sets: [{ type, reps?, weight_kg?, duration_s?, rest_s? }] }
    template_exercises JSONB NOT NULL,

    -- Usage tracking
    times_used INTEGER DEFAULT 0,
    last_used_at TIMESTAMPTZ,
    archived BOOLEAN DEFAULT FALSE,

    -- Soft delete
    deleted_at TIMESTAMPTZ,
    deleted_reason TEXT
);

CREATE INDEX idx_training_templates_user ON training_templates(user_id, created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_training_templates_active ON training_templates(user_id) WHERE archived = FALSE AND deleted_at IS NULL;

CREATE TRIGGER set_training_templates_updated_at
    BEFORE UPDATE ON training_templates
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();
```

### POST `/api/training/template` (V2)

Create a new training template.

**Request:**
```json
{
  "id": "uuid",
  "name": "Push Day A",
  "category": "strength",
  "estimated_duration_minutes": 60,
  "template_exercises": [
    {
      "exercise_name": "Bench Press",
      "exercise_id": "uuid",
      "sets": [
        { "type": "working", "reps": 8, "weight_kg": 80, "rest_s": 120 },
        { "type": "working", "reps": 8, "weight_kg": 80, "rest_s": 120 }
      ]
    }
  ]
}
```

**Response:**
```json
{ "template_id": "uuid", "ok": true }
```

### GET `/api/training/templates` (V2)

List all active training templates for the current user.

**Response:**
```json
{
  "templates": [
    {
      "id": "uuid",
      "name": "Push Day A",
      "category": "strength",
      "estimated_duration_minutes": 60,
      "times_used": 12,
      "last_used_at": "2026-01-15T18:30:00Z"
    }
  ]
}
```

### PATCH `/api/training/template/{id}` (V2)

Update a training template.

**Auth:** Bearer JWT (RLS: owner only)

**Headers:**
- `Idempotency-Key` (required)
- `X-Device-Id`

**Path:** `id` — UUID of the training_template

**Body (partial update):**
| Field | Type | Notes |
|-------|------|-------|
| `name` | string | Optional |
| `exercises` | array | Optional — full replacement of exercise list |
| `is_active` | boolean | Optional |
| `notes` | string | Optional |

**Response:** `200` — updated training_template object
**Errors:** `404` if not found or not owned by user

### DELETE `/api/training/template/{id}` (V2)

Soft delete a training template.

**Response:**
```json
{ "ok": true }
```

---

## API PERFORMANCE SLOs

Life OS commits to the following latency targets for production deployments:

### Latency Targets

| Endpoint Category | p50 | p95 | p99 | Timeout |
|-------------------|-----|-----|-----|---------|
| **Critical Path** | | | | |
| `GET /api/recovery/latest` | 80ms | 200ms | 500ms | 5s |
| `GET /api/recovery/daily` | 90ms | 220ms | 550ms | 5s |
| `GET /api/diary/daily` | 160ms | 450ms | 1s | 5s |
| `GET /api/diary/calendar` | 180ms | 500ms | 1.2s | 5s |
| `GET /api/sleep/daily` | 110ms | 280ms | 650ms | 5s |
| `GET /api/sleep/calendar` | 140ms | 320ms | 750ms | 5s |
| `GET /api/watch/snapshot` | 120ms | 300ms | 700ms | 5s |
| `POST /api/food/log` | 150ms | 400ms | 800ms | 10s |
| `GET /api/food/log/{id}` | 120ms | 300ms | 700ms | 5s |
| `PATCH /api/food/log/{id}` | 180ms | 550ms | 1.2s | 10s |
| `DELETE /api/food/log/{id}` | 120ms | 300ms | 700ms | 5s |
| `POST /api/food/log/{id}/undo` | 150ms | 400ms | 800ms | 10s |
| `GET /api/foods/search` | 120ms | 350ms | 900ms | 5s |
| `GET /api/foods/barcode/{code}` | 120ms | 500ms | 2s | 10s |
| `POST /api/foods/barcode/{code}/create` | 200ms | 600ms | 1.5s | 10s |
| `GET /api/nutrition/templates` | 120ms | 300ms | 700ms | 5s |
| `POST /api/nutrition/templates` | 150ms | 400ms | 800ms | 10s |
| `GET /api/nutrition/templates/{id}` | 120ms | 300ms | 700ms | 5s |
| `PATCH /api/nutrition/templates/{id}` | 150ms | 450ms | 900ms | 10s |
| `POST /api/nutrition/templates/{id}/log` | 150ms | 400ms | 800ms | 10s |
| `GET /api/nutrition/batches` | 120ms | 300ms | 700ms | 5s |
| `POST /api/nutrition/batches` | 200ms | 600ms | 1.2s | 10s |
| `POST /api/nutrition/batches/quick` | 300ms | 900ms | 2s | 15s |
| `POST /api/nutrition/batches/{id}/log` | 150ms | 500ms | 1s | 10s |
| `GET /api/nutrition/daily` | 100ms | 250ms | 600ms | 5s |
| `GET /api/nutrition/calendar` | 120ms | 300ms | 700ms | 5s |
| `POST /api/workouts/log` | 200ms | 500ms | 900ms | 10s |
| `GET /api/workouts/{id}` | 150ms | 400ms | 900ms | 5s |
| `PATCH /api/workouts/{id}` | 200ms | 700ms | 1.5s | 10s |
| `DELETE /api/workouts/{id}` | 150ms | 400ms | 900ms | 5s |
| `POST /api/workouts/{id}/undo` | 180ms | 550ms | 1.2s | 10s |
| `GET /api/exercises/search` | 120ms | 300ms | 700ms | 5s |
| `POST /api/exercises/custom` | 150ms | 400ms | 800ms | 10s |
| `GET /api/workouts/calendar` | 150ms | 350ms | 800ms | 5s |
| `GET /api/training/plan/sessions` | 120ms | 300ms | 700ms | 5s |
| `POST /api/supplements/log` | 120ms | 300ms | 700ms | 5s |
| `GET /api/supplements/daily` | 120ms | 300ms | 700ms | 5s |
| `GET /api/supplements/calendar` | 140ms | 340ms | 750ms | 5s |
| `POST /api/labs/scan` | 250ms | 600ms | 1s | 10s |
| `GET /api/labs/scan/{scan_id}` | 120ms | 300ms | 700ms | 5s |
| **AI-Powered** | | | | |
| `POST /functions/v1/analyze-food-image` | 1.5s | 3s | 5s | 30s |
| `POST /functions/v1/analyze-batch-recipe-image` | 2s | 5s | 10s | 60s |
| `POST /functions/v1/analyze-medical-scan` | 3s | 8s | 15s | 60s |
| `POST /functions/v1/generate-training-plan` | 2s | 5s | 10s | 60s |
| `POST /functions/v1/generate-insights` | 2s | 4s | 8s | 60s |
| `POST /functions/v1/generate-weekly-strategy` | 2s | 5s | 10s | 60s |
| `POST /functions/v1/calculate-recovery-score` | 200ms | 500ms | 1s | 10s |
| **Food DB / Parsing** | | | | |
| `POST /functions/v1/foods-search` | 200ms | 800ms | 2s | 10s |
| `POST /functions/v1/foods-barcode-lookup` | 150ms | 2s | 5s | 15s |
| `POST /functions/v1/analyze-food-label` | 1.5s | 4s | 8s | 30s |
| `POST /functions/v1/parse-food-text` | 600ms | 1.5s | 3s | 15s |
| **Background** | | | | |
| `GET /api/export/full` | — | — | — | 60s |
| `POST /api/experiments/create` | 300ms | 600ms | 1s | 10s |

### Availability Targets

| Metric | Target | Measurement Window |
|--------|--------|-------------------|
| **Uptime** | 99.9% | Monthly |
| **Error Rate (5xx)** | < 0.1% | Daily |
| **Successful AI Analysis** | > 95% | Daily |

### Monitoring & Alerting

```typescript
// Latency monitoring configuration
const SLO_CONFIG = {
  critical_endpoints: {
    recovery_latest: { p50: 80, p95: 200, p99: 500 },
    food_log: { p50: 150, p95: 400, p99: 800 },
    nutrition_daily: { p50: 100, p95: 250, p99: 600 },
    workouts_log: { p50: 200, p95: 500, p99: 900 },
    supplements_log: { p50: 120, p95: 300, p99: 700 },
    labs_scan: { p50: 250, p95: 600, p99: 1000 }
  },
  alert_thresholds: {
    latency_breach_percent: 5,     // Alert if >5% requests exceed p99
    error_rate_percent: 1,         // Alert if >1% error rate
    consecutive_failures: 3        // Alert after 3 consecutive health check failures
  }
};

// Health check endpoint
// GET /api/health -> { status: 'healthy', latency_p50: 45, db_status: 'connected' }
```

### SLO Breach Response

| Breach Level | Trigger | Response |
|--------------|---------|----------|
| **Warning** | p95 exceeded for 5 min | Log to monitoring dashboard |
| **Minor** | p99 exceeded for 10 min | Slack alert to on-call |
| **Major** | Error rate > 1% for 5 min | PagerDuty alert, incident created |
| **Critical** | Service unavailable > 2 min | Auto-failover, all-hands alert |

---

## RATE LIMITS

```
Tier: Free
- API calls: 100/minute
- Food image analysis: 50/day
- AI insights generation: 10/day
- Medical scan analysis: 10/day
- Training plan generation: 5/day

Tier: Premium (future)
- API calls: 1000/minute
- Food image analysis: Unlimited
- AI insights generation: Unlimited
- Medical scan analysis: Unlimited
- Training plan generation: Unlimited

AI Endpoint Limits (all tiers):
- analyze-food-image: 50 calls/day (prevents cost abuse)
- analyze-food-label: 50 calls/day (label OCR cost protection)
- analyze-batch-recipe-image: 20 calls/day (meal prep analysis throttle)
- parse-food-text: 200 calls/day (voice/text parsing throttle)
- generate-insights: 10 calls/hour (expensive RAG + LLM)
- generate-weekly-strategy: 3 calls/week (weekly report cadence)
- analyze-medical-scan: 10 calls/day (OCR + normalization cost)
- generate-training-plan: 5 calls/day (planning cost)
- foods-barcode-lookup: 300 calls/day (external provider + cache protection)
- foods-search: 500 calls/day (external provider + cache protection)
- Emergency prompt rate: 5 calls/hour (safety throttle)
```

Rate limit headers returned:
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 87
X-RateLimit-Reset: 1642694400
```

---

## AUTHENTICATION (via Supabase Auth)

Life OS uses Supabase Auth for authentication. All auth flows are handled by Supabase client SDK.

### Sign In / Sign Up (Email OTP / Magic Link)

```typescript
const { data, error } = await supabase.auth.signInWithOtp({
  email: 'user@example.com',
  options: {
    emailRedirectTo: 'lifeos://auth/callback',
    data: {
      display_name: 'John Doe',
      agreed_to_terms: true,
      agreed_at: new Date().toISOString()
    }
  }
});
```

After sign up, create user profile:
```sql
-- Trigger function to create user profile on auth signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO users (auth_id, email, display_name)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data->>'display_name'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();
```

### Sign In with Apple

```typescript
const { data, error } = await supabase.auth.signInWithOAuth({
  provider: 'apple',
  options: {
    redirectTo: 'lifeos://auth/callback'
  }
});
```

### Sign Out

```typescript
const { error } = await supabase.auth.signOut();
```

### Account Deletion (GDPR)

> [!IMPORTANT]
> **Deletion Order is Critical:** Pinecone vectors MUST be deleted BEFORE SQL cascade to prevent orphaned data and ensure GDPR compliance.

**Edge Function: `POST /api/account/delete`**

**Request:**
```json
{ "immediate": false }
```

**Notes:**
- User is derived from JWT (`Authorization` header). `user_id` is not accepted in the request body.

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"
import { Pinecone } from '@pinecone-database/pinecone';

interface DeletionResult {
  success: boolean;
  vectorsDeleted: boolean;
  postgresDeleted: boolean;
  auditLogId: string;
  error?: string;
}

serve(async (req) => {
  const { immediate = false } = await req.json();

  const authHeader = req.headers.get('Authorization') ?? '';
  const supabaseUser = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: authData, error: authError } = await supabaseUser.auth.getUser();
  if (authError || !authData?.user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  // Validate user exists and get auth_id
  const { data: user, error: userError } = await supabase
    .from('users')
    .select('id, auth_id, email')
    .eq('auth_id', authData.user.id)
    .single();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not found' }), { status: 404 });
  }

  if (!immediate) {
    // Mark for deletion (30-day grace period)
    await supabase
      .from('users')
      .update({ 
        deletion_scheduled_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
        deletion_reason: 'user_requested'
      })
      .eq('id', user.id);

    // Send confirmation email
    await sendDeletionScheduledEmail(user.email);

    return new Response(JSON.stringify({ 
      scheduled: true, 
      deletion_date: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
    }));
  }

  // Immediate deletion - execute full deletion flow
  const result = await executeFullDeletion(user.id, user.auth_id, supabase);
  return new Response(JSON.stringify(result), { status: result.success ? 200 : 500 });
});

/**
 * Full Account Deletion Flow
 * 
 * CRITICAL: Order matters for GDPR compliance!
 * 1. Block new RAG queries for this user (prevent race condition)
 * 2. Delete Pinecone vectors (external system first)
 * 3. Delete PostgreSQL data (CASCADE handles all tables)
 * 4. Delete auth.users entry
 * 5. Log deletion for compliance audit
 */
async function executeFullDeletion(
  userId: string, 
  authId: string,
  supabase: any
): Promise<DeletionResult> {
  const auditLogId = crypto.randomUUID();
  let vectorsDeleted = false;
  let postgresDeleted = false;

  try {
    // STEP 1: Block new RAG queries by marking user as "deleting"
    await supabase
      .from('users')
      .update({ deletion_in_progress: true })
      .eq('id', userId);

    // STEP 2: Wait for any active RAG queries to complete (max 10 seconds)
    await new Promise(resolve => setTimeout(resolve, 2000));

    // STEP 3: Delete Pinecone vectors FIRST
    try {
      await deleteUserVectorData(userId);
      vectorsDeleted = true;
    } catch (pineconeError) {
      // Log but continue - Pinecone deletion can be retried
      console.error(`Pinecone deletion failed for ${userId}:`, pineconeError);
      // Store for retry in deletion_failures table
      await supabase
        .from('deletion_failures')
        .insert({ user_id: userId, failure_type: 'pinecone', error: String(pineconeError) });
    }

    // STEP 4: Delete PostgreSQL data (CASCADE handles all related tables)
    const { error: deleteError } = await supabase.rpc('delete_user_account', { 
      user_uuid: userId 
    });

    if (deleteError) throw deleteError;
    postgresDeleted = true;

    // STEP 5: Delete from auth.users
    const { error: authError } = await supabase.auth.admin.deleteUser(authId);
    if (authError) console.error('Auth deletion error:', authError);

    // STEP 6: Log deletion for GDPR compliance audit
    await supabase
      .from('deletion_audit_log')
      .insert({
        id: auditLogId,
        user_id_deleted: userId,
        deleted_at: new Date().toISOString(),
        vectors_deleted: vectorsDeleted,
        postgres_deleted: postgresDeleted,
        compliance_verified: vectorsDeleted && postgresDeleted
      });

    return { success: true, vectorsDeleted, postgresDeleted, auditLogId };

  } catch (error) {
    return { 
      success: false, 
      vectorsDeleted, 
      postgresDeleted, 
      auditLogId,
      error: String(error)
    };
  }
}

/**
 * Delete all user vectors from Pinecone
 */
async function deleteUserVectorData(userId: string): Promise<void> {
  const pinecone = new Pinecone({
    apiKey: Deno.env.get('PINECONE_API_KEY')!
  });

  const index = pinecone.index('lifeos-user-memory');
  const namespace = `user_${userId}`;

  // Delete entire user namespace (all vectors)
  await index.namespace(namespace).deleteAll();

  console.log(`Deleted all vectors for user namespace: ${namespace}`);
}
```

**SQL Function (called by Edge Function above):**

```sql
-- Stored procedure for PostgreSQL account deletion
CREATE OR REPLACE FUNCTION delete_user_account(user_uuid UUID)
RETURNS VOID AS $$
BEGIN
  -- All tables have ON DELETE CASCADE from users table
  -- This cascades to: physiological_states, food_logs, food_items,
  -- user_foods, user_food_favorites,
  -- meal_templates,
  -- batch_recipes, experiments, insights, recommendations, notification_settings, user_supplements,
  -- supplement_logs, medical_scans, health_measurements, health_diagnoses,
  -- training_loads, workout_sessions, workout_exercises, workout_sets,
  -- training_plans, training_plan_sessions, wellness_checks, body_composition, hydration_logs,
  -- vector_memory (reference table only - actual vectors in Pinecone)
  -- NOTE: food_catalog_items is a shared cache and is NOT deleted per user.
  DELETE FROM users WHERE id = user_uuid;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Audit log table for GDPR compliance
CREATE TABLE IF NOT EXISTS deletion_audit_log (
    id UUID PRIMARY KEY,
    user_id_deleted UUID NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL,
    vectors_deleted BOOLEAN NOT NULL,
    postgres_deleted BOOLEAN NOT NULL,
    compliance_verified BOOLEAN NOT NULL,
    notes TEXT
);

-- Note: deletion_audit_log and deletion_failures are service-role-only tables.
-- RLS is intentionally NOT enabled; these tables are accessed exclusively by
-- the account-deletion Edge Function using the service_role key.
-- Justification: audit tables must support cross-user compliance verification
-- and are never exposed via user-facing endpoints. All access is server-side,
-- logged, and restricted to service role only (no client JWT access).

-- Deletion failures table for retry mechanism
CREATE TABLE IF NOT EXISTS deletion_failures (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    failure_type TEXT NOT NULL CHECK (failure_type IN ('pinecone', 'postgres', 'auth')),
    error TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    retried_at TIMESTAMPTZ,
    resolved BOOLEAN DEFAULT FALSE
);
```

**Calculation Rules (Source of Truth):**
1. If heart‑rate zones are available, compute `daily_trimp` as a weighted sum of zone minutes.
2. If zones are missing, compute `daily_trimp = duration_minutes * perceived_exertion_rpe` (RPE 1–10).
3. `acute_load_7d` and `chronic_load_28d` use EWMA with the provided lambdas.
4. `acwr = acute_load_7d / max(chronic_load_28d, cold_start_baseline, 1)`.
   - `cold_start_baseline = (avg_daily_trimp * 0.5)` when <14 days of data, floored at 50.
5. Training zones from ACWR:
- undertraining: < 0.8
- optimal: 0.8–1.3
- overreaching: 1.3–1.5
- injury_risk: > 1.5

**Zone multipliers (exponential, Banister-style):**
- zone1_minutes * 1.0
- zone2_minutes * 2.0
- zone3_minutes * 4.0
- zone4_minutes * 7.0
- zone5_minutes * 12.0

**RPE fallback (imported workouts):**
- If `perceived_exertion_rpe` is null:
  - Derive RPE from HR zones if available.
  - Else default RPE = 3 (light‑moderate), cap TRIMP at 200, and mark training load confidence as low.

**Race Condition Handling:**

| Scenario | Mitigation |
|----------|------------|
| RAG query during deletion | `deletion_in_progress` flag blocks new queries; 2-second wait for active queries |
| Pinecone deletion fails | Logged to `deletion_failures` table for async retry; PostgreSQL deletion continues |
| PostgreSQL deletion fails | Full rollback not possible; logged for manual intervention |
| User cancels during grace period | `deletion_scheduled_at` cleared; no data deleted |

### POST `/api/account/delete/cancel`

Cancel a previously scheduled account deletion during the 30-day grace period.

**Auth:** Bearer JWT (RLS: owner only)

**Headers:**
- `Idempotency-Key` (required)

**Request:** _(empty body)_

**Logic:**
1. Verify the authenticated user has a non-null `deletion_scheduled_at`.
2. Verify `deletion_in_progress` is `false` (once the deletion job starts, it cannot be cancelled).
3. Clear `deletion_scheduled_at` and `deletion_reason`.

```typescript
serve(async (req) => {
  const authHeader = req.headers.get('Authorization') ?? '';
  const supabaseUser = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: authData, error: authError } = await supabaseUser.auth.getUser();
  if (authError || !authData?.user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401 });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  const { data: user, error: userError } = await supabase
    .from('users')
    .select('id, deletion_scheduled_at, deletion_in_progress')
    .eq('auth_id', authData.user.id)
    .single();

  if (userError || !user) {
    return new Response(JSON.stringify({ error: 'User not found' }), { status: 404 });
  }

  if (!user.deletion_scheduled_at) {
    return new Response(JSON.stringify({ error: 'No deletion scheduled' }), { status: 409 });
  }

  if (user.deletion_in_progress) {
    return new Response(JSON.stringify({ error: 'Deletion already in progress — cannot cancel' }), { status: 409 });
  }

  await supabase
    .from('users')
    .update({
      deletion_scheduled_at: null,
      deletion_reason: null
    })
    .eq('id', user.id);

  return new Response(JSON.stringify({ cancelled: true }));
});
```

**Response (200):**
```json
{ "cancelled": true }
```

**Errors:**
| Status | Condition |
|--------|-----------|
| `401` | Invalid or missing JWT |
| `404` | User not found |
| `409` | No deletion scheduled, or deletion already in progress |

### Session Management

```typescript
// Get current session
const { data: { session } } = await supabase.auth.getSession();

// Refresh session
const { data, error } = await supabase.auth.refreshSession();

// Listen to auth changes
supabase.auth.onAuthStateChange((event, session) => {
  if (event === 'SIGNED_OUT') {
    // Clear local data, navigate to login
  }
});
```

---

## ONBOARDING ENDPOINTS

> Full specifications for onboarding endpoints are defined in `life_os_onboarding_backend.md`.

| Endpoint | Purpose | Rate Limit | See |
|----------|---------|------------|-----|
| `POST /api/onboarding/profile` | Create user profile + defaults (notification_settings, privacy_settings, onboarding_state) | 5/min per IP | `life_os_onboarding_backend.md` §2.1 |
| `POST /api/onboarding/health-backfill` | Trigger HealthKit backfill (last 14 days) and compute initial baselines | 2/min per user | `life_os_onboarding_backend.md` §2.2 |

---

## PREDICTIVE ANALYTICS / WHAT-IF

### POST `/api/insights/predict` (Edge Function)

**Purpose:** Runs a predictive What-If Scenario simulation by gathering 14-30 days of N=1 historical context (RAG) and passing it to the LLM (OpenRouter) with the user's hypothetical scenario.

**Request Body:**
```json
{
  "target_date": "2026-02-22",
  "scenario_text": "If I sleep at 01:00 today after my workout",
  "scenario_type": "sleep" // Enum: sleep, workout, nutrition, general
}
```

**Response (200 OK):**
```json
{
  "predicted_recovery_range": [30, 42],
  "predicted_zone": "Caution",
  "explanation": "Из-за позднего отбоя (01:00) твой сон сократится минимум на полтора часа по сравнению с базовой линией. Исторически, когда ты засыпаешь после полуночи в день тренировки, твоему телу не хватает времени на полноценную регенерацию мышц в глубокой фазе сна. Ожидай снижения HRV на 10-15%.",
  "confidence_score": 0.85
}
```

**Flow:**
1. Fetch recent `physiological_states`, `workout_sessions`, `sleep_logs`.
2. Find similar past days matching `scenario_type`.
3. Construct `Predictive What-If Simulation` prompt.
4. Call OpenRouter (`gpt-4o` or `claude-3-5-sonnet`).
5. Ensure `predicted_recovery_range` respects invariant bounds before returning.

---

## ANALYTICS

### POST `/api/analytics/batch`

> Source of truth: `life_os_analytics_catalog.md`

Receives batched analytics events from the client. Events are buffered client-side (max 50 events or 60s interval) and sent as a single batch.

**Rate Limit:** 10 requests/minute per user.

**Headers:**
```
Authorization: Bearer {jwt_token}
Content-Type: application/json
X-Device-Id: {device_uuid}
```

**Request Body:**
```json
{
  "events": [
    {
      "name": "food_log_created",
      "timestamp": "2026-01-18T12:30:00Z",
      "properties": {
        "input_method": "photo",
        "items_count": 3,
        "ai_used": true
      },
      "session_id": "uuid"
    }
  ]
}
```

**Validation:**
- `events` array: max 50 items per request.
- `name`: must be a string, max 100 chars.
- `timestamp`: must be ISO 8601, not in the future, not older than 7 days.
- `properties`: optional JSONB, max 1KB per event.
- `session_id`: optional UUID for session grouping.

**Response (202 Accepted):**
```json
{
  "accepted": 3,
  "rejected": 0
}
```

**Error Codes:**
| Code | Meaning |
|------|---------|
| 400 | Invalid event format or batch too large |
| 429 | Rate limit exceeded |

**Implementation Notes:**
- Events are inserted into `analytics_events` table.
- Events are **anonymized** — `user_id` is stored as a separate column but stripped from the event payload for analytics queries.
- No PII is ever stored in `properties`.
- Events older than 90 days are auto-deleted by a scheduled cron job.

---

## DATA EXPORT (GDPR Compliance)

### GET `/api/export/full`

Export all user data in JSON format (GDPR Article 20).

**Headers:**
```
Authorization: Bearer {jwt_token}
```

**Response:**
```json
{
  "export_id": "uuid",
  "generated_at": "2026-01-18T12:00:00Z",
  "user": {
    "email": "user@example.com",
    "display_name": "John Doe",
    "date_of_birth": "1995-03-15",
    "created_at": "2025-06-01T10:00:00Z"
  },
  "physiological_data": [
    {
      "date": "2026-01-18",
      "recovery_score": 78,
      "hrv_ms": 62.5,
      "rhr_bpm": 58,
      "sleep_duration_hours": 7.33
    }
  ],
  "food_logs": [
    {
      "logged_at": "2026-01-18T12:30:00Z",
      "meal_type": "lunch",
      "total_calories": 520,
      "items": [...]
    }
  ],
  "daily_nutrition_targets": [...],
  "experiments": [...],
  "insights": [...],
  "weekly_strategy_reports": [...],
  "user_supplements": [...],
  "supplement_logs": [...],
  "workout_sessions": [...],
  "training_plans": [...],
  "medical_scans": [...],
  "health_measurements": [...],
  "body_composition": [...],
  "wellness_checks": [...],
  "hydration_logs": [...],
  "sleep_logs": [...],
  "user_foods": [...],
  "user_food_favorites": [...],
  "notification_settings": {...},
  "privacy_settings": {...},
  "training_templates": [...],
  "total_records": 4521
}
```

Processing time: Up to 24 hours for large datasets. User receives email notification when ready.

---

## OFFLINE SYNC STRATEGY

> Source of truth: `life_os_sync_engine_spec.md` (local schema, outbox ordering, backoff).

### Idempotency & Client-Generated IDs (Required)

Life OS is offline-first. To prevent duplicates and make replay safe:

1. **All mutation requests MUST include:**
   - `Idempotency-Key: <uuid>` (use Outbox event ID)
   - `X-Device-Id: <uuid>` (stable device id; diagnostics only)
2. **Create endpoints MUST accept client-generated IDs** (UUID) and upsert by them:
   - If the client includes an explicit ID in a create payload (`id` or endpoint-specific fields like `food_log_id`, `food_item_id`, `scan_id`), the server MUST use it.
   - For nested creates (e.g., food log + items), the client may include `id` for child rows; the server MUST upsert by those IDs too.
3. **Replays must be safe:** if the same create is sent twice (timeout/retry), the second request must return success without creating duplicates.

### Offline‑Safe Create Contract (Required)

For offline-first UX, the client often **creates records locally first**, then replays the corresponding mutations later.
To make this deterministic (no ID remapping), these endpoints MUST accept client-generated UUIDs and upsert by them.

**Rule:** when enqueuing an Outbox event for an offline create, the client MUST include the listed ID fields.
(For online-only flows, the client MAY omit them and let the server generate IDs.)

| Endpoint | Creates (tables) | Client-generated IDs (payload fields) | Notes |
|---|---|---|---|
| `POST /api/food/log` | `food_logs`, `food_items` | `id`, `items[*].id` | Item IDs are required for deterministic offline meal editing/review later. |
| `POST /api/wellness/check` | `wellness_checks` | `id` | Daily check-ins may be logged offline. |
| `POST /api/hydration/log` | `hydration_logs` | `id` | Include `logged_at`, `logged_date`, and timezone fields. |
| `POST /api/workouts/log` | `workout_sessions`, `workout_exercises`, `workout_sets` | `id`, `exercises[*].id`, `exercises[*].sets[*].id` | Nested IDs must upsert safely on replay. |
| `POST /api/supplements/log` | `supplement_logs` | `id` | `id` is the log id (not the supplement id). |
| `POST /api/foods/custom` | `user_foods` | `id` | Enables offline creation of custom foods. |
| `POST /api/foods/favorites` | `user_food_favorites` | `id` (optional) | Can also upsert by unique `(user_id, ref_type, ref_id)`; `id` is recommended for strict offline symmetry. |
| `POST /api/exercises/custom` | `exercise_catalog` | `id` | Custom exercises are rows with `is_custom=true`. |
| `POST /api/nutrition/templates` | `meal_templates` | `id` | Template items are stored as a JSON snapshot (no child table IDs). |
| `POST /api/nutrition/batches` | `batch_recipes`, `batch_recipe_ingredients` | `id`, `ingredients[*].id` | Ingredient IDs are required to support offline editing/reordering. |
| `POST /api/nutrition/templates/{template_id}/log` | `food_logs`, `food_items` | `food_log_id`, `items[*].id` | Offline replay SHOULD include full `items[]` snapshot to avoid drift if template changes before sync. |
| `POST /api/nutrition/batches/{batch_id}/log` | `food_logs`, `food_items` | `food_log_id`, `food_item_id` | Offline replay SHOULD include `item_macros_override` to avoid drift if batch values change before sync. |
| `POST /api/labs/scan` | `medical_scans` (and derived markers optionally) | `scan_id` | `scan_id` maps to `medical_scans.id` (client-generated for offline placeholder + later sync). |
| `POST /api/experiments/create` | `experiments` | `id` | Experiment schedule dates are server-computed. |
| `POST /api/experiments/{id}/log` | `experiment_measurements` | `id` | `id` is the measurement row id. |
| `POST /api/sleep/log` | `sleep_logs` | `id` | V2 sleep diary logs must support offline create. |
| `POST /api/training/template` | `training_templates` | `id` | V2 training templates must support offline create. |
| `POST /api/body-composition` | `body_composition` | `id` | Measurements may be logged offline and synced later. |

### Conflict Resolution

Life OS uses **server-authoritative last-write-wins** based on `updated_at`.

Key rules:
- **Server timestamps win:** the server sets `updated_at` on every update (clients never trust their own clocks).
- **Soft deletes where needed:** tables that support undo use `deleted_at` tombstones (e.g., `food_logs`, `workout_sessions`).
- **Safe merges only:** when both sides changed the same record, we merge only fields that are explicitly safe to merge; otherwise the server version wins and the client shows a “Review changes” UI (rare).

```typescript
type ISO8601 = string;

interface SyncableRecord {
  id: string;
  user_id: string;
  created_at: ISO8601;
  updated_at: ISO8601;
  deleted_at?: ISO8601 | null; // Only for tables that implement soft delete
}

// Local-only envelope for pending operations
// Writes are executed via `/api/*` endpoints (Edge Functions) to preserve validation and business rules.
// `id` is used as the Idempotency-Key to make replay safe.
interface OutboxEvent {
  id: string; // UUID (Idempotency-Key)
  method: 'POST' | 'PATCH' | 'DELETE';
  path: string; // e.g., '/api/food/log'
  headers: Record<string, string>; // must include Idempotency-Key + X-Device-Id
  body?: any;
  enqueued_at: ISO8601;
}
```

### Sync Flow

1. **On app launch:**
   ```typescript
   // Fetch server changes since last sync (repeat per syncable table)
   const lastSync = await getLastSyncTimestamp();
   const tables = [
     'food_logs',
     'food_items',
     'user_foods',
     'user_food_favorites',
     'meal_templates',
     'batch_recipes',
     'batch_recipe_ingredients',
     'workout_sessions',
     'workout_exercises',
     'workout_sets',
     'training_plans',
     'training_plan_sessions',
     'sleep_logs',
     'training_templates',
     'user_supplements',
     'supplement_logs',
     'wellness_checks',
     'body_composition',
     'hydration_logs',
     'experiments',
     'experiment_measurements',
     'medical_scans',
     'insights',
     'recommendations',
     'health_measurements',
     'health_diagnoses',
     'notification_settings',
     'onboarding_state',
     'user_baselines',
     'privacy_settings'
   ];

   for (const table of tables) {
     const { data: serverChanges } = await supabase
       .from(table)
       .select('*')
       .gte('updated_at', lastSync); // use >= to avoid missing same-timestamp updates; dedupe on apply
     
     await applyServerChanges(table, serverChanges ?? []);
   }
   ```

2. **Conflict detection:**
   ```typescript
   function resolveConflict(local: SyncableRecord, server: SyncableRecord): SyncableRecord {
     // Server is authoritative; only merge known-safe fields.
     if (new Date(local.updated_at) <= new Date(server.updated_at)) return server;
     return mergeSafely(local, server); // e.g., merge notes fields, never merge IDs or timestamps
   }
   ```

3. **Offline queue:**
   - SQLite local store for full history
   - Pending mutation queue with retry + exponential backoff
   - If the queue is blocked >24h, show a banner; if >7 days, show a blocking “Fix sync” screen

---

## VALIDATION RULES

Server-side validation for all inputs:

| Field | Type | Validation |
|-------|------|------------|
| `weight_kg` | NUMERIC | 20 ≤ x ≤ 500 |
| `height_cm` | NUMERIC | 50 ≤ x ≤ 300 |
| `hrv_ms` | NUMERIC | 0 < x ≤ 300 |
| `resting_heart_rate_bpm` | INTEGER | 30 ≤ x ≤ 200 |
| `wrist_temperature_deviation_c` | NUMERIC | -3 ≤ x ≤ 3 |
| `sleep_duration_hours` | NUMERIC | 0 ≤ x ≤ 24 |
| `*_utc_offset_minutes` | INTEGER | -840 ≤ x ≤ 840 |
| `*_timezone` | TEXT | IANA timezone string (e.g., `Europe/Moscow`) |
| `barcode` | TEXT | 8–18 digits, numbers only |
| `calories` | NUMERIC | 0 ≤ x ≤ 10000 |
| `protein_g` | NUMERIC | 0 ≤ x ≤ 500 |
| `body_fat_percent` | NUMERIC | 1 ≤ x ≤ 70 |
| `photo_size` | FILE | ≤ 10MB, JPEG/PNG/HEIC only |

Error response for validation failures:
```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Input validation failed",
    "details": [
      {
        "field": "weight_kg",
        "constraint": "range",
        "message": "Weight must be between 20 and 500 kg"
      }
    ]
  }
}
```

---

## WEBHOOKS (Future)

```
POST /webhooks/apple-health
- Triggered when HealthKit data syncs
- Updates physiological_states table
- Recalculates recovery score

POST /webhooks/experiment-complete
- Triggered when experiment ends
- Runs statistical analysis
- Generates insight

POST /webhooks/pattern-detected
- Triggered when RAG finds new correlation
- Creates insight record
- Sends notification
```

---

## RATE LIMITING

All API endpoints enforce rate limiting to protect against abuse and ensure fair usage.

### Default Limits

| Tier | Limit | Window | Applies To |
|------|-------|--------|------------|
| **Standard** | 120 requests | 1 minute | All authenticated endpoints |
| **Write-heavy** | 30 requests | 1 minute | `POST /api/food/log`, `POST /api/workouts/log`, `POST /api/supplements/log` |
| **AI / Vision** | 10 requests | 1 minute | `POST /api/food/analyze-photo`, `POST /functions/v1/analyze-food-label`, `POST /functions/v1/analyze-food-image`, `POST /api/labs/scan`, `POST /api/insights/generate` |
| **AI / Vision (hourly hard cap)** | 30 requests | 1 hour | Same endpoints as AI/Vision above — prevents sustained cost abuse even within per-minute limits |
| **Search** | 60 requests | 1 minute | `GET /api/foods/search`, `GET /api/foods/barcode/*`, `GET /api/exercises/search` |
| **Auth** | 5 requests | 1 minute | `POST /api/auth/*` |
| **Export** | 1 request | 1 hour | `POST /api/account/export` |

### Response Headers

All responses include rate-limit headers:

```
X-RateLimit-Limit: 120
X-RateLimit-Remaining: 118
X-RateLimit-Reset: 1707000060
```

### Exceeded Limit Response

```json
HTTP 429 Too Many Requests
{
  "error": "rate_limit_exceeded",
  "message": "Too many requests. Try again in 42 seconds.",
  "retry_after_seconds": 42
}
```

### Implementation Notes

- Rate limiting is per-user (identified by JWT `sub` claim), not per-IP.
- Supabase Edge Functions use an in-memory sliding window counter backed by a shared KV store.
- Offline sync replay (outbox drain) is exempt from write-heavy limits when the `X-Outbox-Replay: true` header is present, but is capped at **300 requests / 5 minutes** to prevent runaway replays.
- The AI/Vision tier is intentionally low because each call incurs OpenRouter costs. The client must queue and debounce photo analysis requests.
- The hourly hard cap (30/hour) applies independently of the per-minute limit. A user hitting 10/min consistently would be stopped at 30 total within the hour.
- When the hourly cap is reached, the 429 response includes `"tier": "ai_vision_hourly"` to help client-side UX distinguish this from the per-minute limit.

---

## PAGINATION CONVENTION

All list endpoints must support cursor-based pagination to prevent unbounded responses.

### Request Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `limit` | integer | 25 | Max items to return (1-100) |
| `after` | string (UUID) | — | Cursor: return items after this ID |
| `before` | string (UUID) | — | Cursor: return items before this ID (for backward navigation) |

### Response Shape

```json
{
  "data": [...],
  "pagination": {
    "has_more": true,
    "next_cursor": "uuid-of-last-item",
    "prev_cursor": "uuid-of-first-item",
    "total_count": 142
  }
}
```

**Notes:**
- `total_count` is optional and only included if the query is not expensive. For expensive queries, omit it and use `has_more` only.
- Default ordering is `created_at DESC` unless the endpoint specifies otherwise.
- Cursors are opaque to the client — they are stable UUIDs (not offsets) to avoid issues with concurrent inserts.

### Endpoints Requiring Pagination

| Endpoint | Default Sort |
|----------|-------------|
| `GET /api/foods/search` | `relevance_score DESC` |
| `GET /api/nutrition/templates` | `usage_count DESC, name ASC` |
| `GET /api/supplements/daily` | `scheduled_time ASC` |
| `GET /api/workouts/history` | `started_at DESC` |
| `GET /api/experiments/list` | `created_at DESC` |
| `GET /api/insights/list` | `created_at DESC` |
| `GET /api/foods/favorites` | `usage_count DESC` |
| `GET /api/user-foods` | `created_at DESC` |
| `GET /api/exercises/search` | `relevance_score DESC` |

---

## PUSH NOTIFICATION PAYLOAD SPEC

All push notifications sent via APNs follow this canonical payload structure.

### Payload Schema

```json
{
  "aps": {
    "alert": {
      "title": "string (≤ 50 chars)",
      "subtitle": "string (≤ 80 chars, optional)",
      "body": "string (≤ 200 chars)"
    },
    "badge": 0,
    "sound": "default",
    "category": "string",
    "thread-id": "string",
    "interruption-level": "passive | active | time-sensitive | critical",
    "relevance-score": 0.0
  },
  "data": {
    "type": "string",
    "deep_link": "string",
    "payload": {}
  }
}
```

### Notification Categories (APNs `category`)

| Category ID | Actions | Use Case |
|-------------|---------|----------|
| `MORNING_BRIEF` | "View", "Dismiss" | Daily recovery summary |
| `SUPPLEMENT_REMINDER` | "Taken ✓", "Skip", "Snooze 30m" | Scheduled supplement reminders |
| `MEAL_REMINDER` | "Log Meal", "Dismiss" | Nudge to log a meal |
| `RECOVERY_ALERT` | "View Recovery", "Dismiss" | Critical/caution zone alerts |
| `INSIGHT` | "View", "Dismiss" | New AI insight available |
| `CELEBRATION` | "View" | Streak or goal achievement |
| `EXPERIMENT` | "Log Now", "Skip" | Experiment measurement reminder |

### Notification Types (`data.type`)

| Type | Deep Link Pattern | Payload |
|------|-------------------|---------|
| `morning_brief` | `lifeos://diary/{date}` | `{ date, recovery_score, recovery_zone }` |
| `supplement_reminder` | `lifeos://supplements/log` | `{ supplement_id, supplement_name, dose }` |
| `meal_nudge` | `lifeos://food/log` | `{ meal_type, remaining_macros }` |
| `recovery_alert` | `lifeos://recovery/{date}` | `{ recovery_score, zone, guidance }` |
| `insight` | `lifeos://insights/{insight_id}` | `{ insight_id, title, priority }` |
| `celebration` | `lifeos://achievements` | `{ achievement_type, streak_days? }` |
| `experiment_reminder` | `lifeos://experiments/{id}/log` | `{ experiment_id, metric_name }` |

### Interruption Level Rules

| Level | When Used |
|-------|-----------|
| `passive` | Celebrations, low-priority insights |
| `active` | Supplement reminders, meal nudges, morning brief |
| `time-sensitive` | Recovery alerts (caution/critical zone) |
| `critical` | Never used (reserved for medical devices only) |

### Sending Rules (Enforced Server-Side)

1. All notifications pass through the Edge Function `send-notification` which enforces:
   - Daily cap (`notification_settings.max_total_per_day`, default 6)
   - Per-category caps (`max_positive_per_day`, `max_nudges_per_day`, `max_celebration_per_day`)
   - Quiet hours window (`quiet_hours_start` to `quiet_hours_end` in user's timezone)
   - `critical_only` mode (only `recovery_alert` with zone = critical)
2. Morning Brief is delivered at `morning_brief_time_local` resolved against `users.timezone`.
3. The function logs every sent notification to an `notification_log` table for cap enforcement and analytics.

---

## OPS TABLES (SERVER)

These tables are part of the backend operational schema and are required for runtime guarantees
(notification caps, GDPR workflows, deletion auditability, consent versioning).

### Table: `notification_log`
Operational log of delivered notifications used for:
- daily cap enforcement (`max_total_per_day`)
- per-category dedup/cooldown checks
- timezone-correct local-day accounting (`delivered_date_local`, `timezone`)

### Table: `export_jobs`
Asynchronous GDPR export jobs:
- request lifecycle (`requested` → `completed` / `failed`)
- secure download URL + expiry handling
- polling via export status endpoint

### Table: `deletion_audit_log`
Immutable compliance log for account erasure:
- who/when was deleted
- subsystem completion flags (vectors/postgres)
- compliance verification metadata

### Table: `deletion_failures`
Retryable dead-letter queue for deletion pipeline failures:
- failure type + error details
- retry tracking (`retried_at`)
- resolution marker (`resolved`)

### Table: `consent_records`
Versioned consent events:
- consent type
- granted/revoked state
- consent version and timestamp
- evidence metadata for audits

---

## CHANGELOG

### v2.3 (February 12, 2026)
- Fixed `batch_recipes.total_portions`: now nullable with `CHECK (total_portions > 0)`, `weight_per_portion_g` handles NULL safely
- Added JSON schema comment for `food_logs.ai_detected_items` JSONB column
- Added timezone handling documentation for `notification_settings.morning_brief_time_local`
- Added `getEffectiveWeight()` fallback chain summary to daily nutrition targets adjustment docs
- Added Rate Limiting specification section
- Added Push Notification Payload specification section

### v2.2 (February 9, 2026)
- Added deterministic `next_best_action` algorithm and low‑confidence safeguards for Home/watch.

### v2.1 (February 9, 2026)
- Added `POST /api/account/delete/cancel` — cancel scheduled deletion during 30-day grace period.
- Added CRUD endpoints: `PATCH /api/hydration/log/{id}`, `DELETE /api/hydration/log/{id}`, `PATCH /api/sleep/log/{id}`, `DELETE /api/sleep/log/{id}`, `PATCH /api/training/template/{id}`.

### v2.0 (February 6, 2026)
- Promoted to v2.0 as part of V2 spec freeze baseline.
- Added V2 sleep diary endpoints: `POST /api/sleep/log`, `GET /api/sleep/log`, `GET /api/sleep/daily`, `GET /api/sleep/calendar`.
- Added V2 training templates: `POST /api/training/template`, `GET /api/training/templates`.
- Added body composition endpoint: `POST /api/body-composition`.
- Added account deletion flow: `POST /api/account/delete`, `POST /api/account/delete/cancel`, `GET /api/account/delete/status`.
- Added GDPR async export: `POST /api/account/export`, `GET /api/account/export/{id}`.
- Expanded GDPR export response to include: `wellness_checks`, `hydration_logs`, `body_composition`, `user_food_favorites`.
- Added watch snapshot endpoint reference corrections.
- Synchronized Offline-Safe Create Contract table with all V2 entities.

### v1.9 (February 4, 2026)
- Added explicit request payload examples for previously underspecified PATCH endpoints:
  - `PATCH /api/nutrition/batches/{batch_id}` (metadata/yield + optional ingredient replacement by `ingredients[*].id`)
  - `PATCH /api/workouts/{session_id}` (replace exercises/sets semantics with nested IDs)

### v1.8 (February 4, 2026)
- Added an explicit Offline‑Safe Create Contract table (required ID fields per endpoint) to make outbox replay deterministic.
- Updated create endpoints to accept client-generated IDs in request payloads:
  - `POST /api/foods/custom` (`id`)
  - `POST /api/foods/favorites` (`id`, optional)
  - `POST /api/exercises/custom` (`id`)
  - `POST /api/nutrition/templates` (`id`)
  - `POST /api/nutrition/batches` (`id`, `ingredients[*].id`)
  - `POST /api/nutrition/templates/{template_id}/log` (`food_log_id`, `items[*].id`, optional `items[]` snapshot)
  - `POST /api/nutrition/batches/{batch_id}/log` (`food_log_id`, `food_item_id`, optional `item_macros_override`)
  - `POST /api/labs/scan` (`scan_id`)
  - `POST /api/experiments/create` (`id`)
  - `POST /api/experiments/{id}/log` (`id` = measurement id; response now returns `measurement_id`)

### v1.7 (February 4, 2026)
- Locked offline-first idempotency rules:
  - mutation requests require `Idempotency-Key` + `X-Device-Id`
  - create endpoints accept client-generated UUIDs and must upsert by them
- Updated Offline Sync Strategy section to use an HTTP Outbox event envelope (push via `/api/*`, pull via tables with `updated_at >= watermark`)
- Updated request examples to include optional `id` fields for offline-safe creates (`/api/food/log`, `/api/workouts/log`, `/api/supplements/log`)

### v1.6 (February 4, 2026)
- Added V2 surfaces endpoints:
  - Unified Daily Diary: `GET /api/diary/daily`, `GET /api/diary/calendar`
  - Sleep Diary: `GET /api/sleep/daily`, `GET /api/sleep/calendar`
  - Supplements month grid: `GET /api/supplements/calendar`
  - Templates management: `GET/PATCH /api/nutrition/templates/{id}`
- Added watchOS host endpoint: `GET /api/watch/snapshot`
- Expanded API SLO table for new V2 endpoints

### v1.5 (February 4, 2026)
- Added meal detail + edit + soft delete + undo endpoints (`/api/food/log/{id}`)
- Added workout detail + edit + soft delete + undo endpoints (`/api/workouts/{session_id}`) and soft-delete columns on `workout_sessions`
- Refactored meal prep tracking to be drift-proof:
  - moved batch references to `food_items.batch_recipe_id`
  - derived batch consumption/remaining from logged items on non-deleted meals
- Updated nutrition daily response to include meal `id` and `needs_review` for navigation UX
- Expanded batch endpoints (`/api/nutrition/batches`) docs: `status` param + derived remaining rules

### v1.4 (February 4, 2026)
- Added travel-correct timestamp fields for diary logs (`*_timezone`, `*_utc_offset_minutes`)
- Added food database cache + user foods tables (`food_catalog_items`, `user_foods`, `user_food_favorites`) + RLS policies
- Added meal templates for Quick Add (`meal_templates` + templates endpoints)
- Added food search + barcode lookup endpoints (`/api/foods/search`, `/api/foods/barcode/{code}`) and related edge functions
- Added `parse-food-text` edge function for voice/text meal parsing with max-2 clarification rule
- Added workout import metadata fields (`import_provider`, `import_source_id`) to support HealthKit de-dupe
- Updated labs import to support local-only raw scans by default (`medical_scans.storage_mode`, nullable `original_image_url`)
- Added exercise catalog endpoints for workout logging (`/api/exercises/search`, `/api/exercises/custom`)
- Linked HealthKit contract to `life_os_healthkit_spec.md` as source of truth

### v1.3 (February 3, 2026)
- Added explicit local date columns for diary grouping (`logged_date`, `taken_date`, `session_date`)
- Added calendar range endpoints for Nutrition and Training
- Added recovery by-date endpoint and diary-friendly supplements daily endpoint
- Added lab scan status endpoint
- Added HealthKit client contract section
- Added barcode as a food log input method; made supplement dose optional in stack + logs
- Allowed nullable email for anonymous/Apple auth flows; documented auth modes and first-launch flow
- Aligned `users.primary_goal` enum with onboarding goals (recovery/performance/weight/general_health)
- Added `users.age_range` to support privacy-friendly onboarding without requiring DOB
- Expanded food log context/input enums to match Nutrition spec (`barcode`, `unknown`)
