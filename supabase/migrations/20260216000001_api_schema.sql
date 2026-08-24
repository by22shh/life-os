
-- Shared helper used by all updated_at triggers.
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Table: users
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


-- Table: user_health_flags
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


-- Table: notification_settings
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


-- Table: physiological_states
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
    
    -- Context
    environmental_context JSONB,            -- Weather, sunlight, AQI, moon phase
    
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


-- Table: food_logs
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
    needs_review BOOLEAN DEFAULT FALSE,      -- confidence < 0.65 review gate

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
  WHERE deleted_at IS NOT NULL;

-- AI feedback for model improvement
CREATE INDEX idx_food_logs_ai_feedback 
  ON food_logs(ai_feedback, ai_confidence) 
  WHERE ai_feedback IS NOT NULL;

-- Trigger for updated_at
CREATE TRIGGER set_food_logs_updated_at
    BEFORE UPDATE ON food_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE OR REPLACE FUNCTION set_food_log_needs_review()
RETURNS TRIGGER AS $$
BEGIN
    NEW.needs_review := CASE
        WHEN NEW.ai_confidence IS NOT NULL AND NEW.ai_confidence < 0.65 THEN TRUE
        ELSE FALSE
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_food_logs_needs_review
    BEFORE INSERT OR UPDATE OF ai_confidence ON food_logs
    FOR EACH ROW
    EXECUTE FUNCTION set_food_log_needs_review();

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


-- Table: daily_nutrition_targets
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


-- Table: food_catalog_items
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


-- Table: user_foods
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


-- Table: user_food_favorites
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


-- Table: food_items
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
    batch_recipe_id UUID,
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


-- Table: batch_recipes
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

ALTER TABLE food_items
    ADD CONSTRAINT food_items_batch_recipe_id_fkey
    FOREIGN KEY (batch_recipe_id) REFERENCES batch_recipes(id) ON DELETE SET NULL;


-- Table: batch_recipe_ingredients
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


-- Table: meal_templates
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


-- Table: supplement_catalog
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


-- Table: user_supplements
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


-- Table: supplement_logs
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

CREATE OR REPLACE FUNCTION public.sync_wellness_checks_local_day_metadata()
RETURNS TRIGGER AS $$
DECLARE
    resolved_timezone TEXT;
BEGIN
    resolved_timezone := NULLIF(BTRIM(NEW.checked_timezone), '');
    IF resolved_timezone IS NULL THEN
        SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
        INTO resolved_timezone
        FROM users u
        WHERE u.id = NEW.user_id;
    END IF;
    resolved_timezone := COALESCE(resolved_timezone, 'UTC');

    IF NEW.date IS NULL AND NEW.checked_at IS NOT NULL THEN
        NEW.date := (NEW.checked_at AT TIME ZONE resolved_timezone)::date;
    END IF;

    IF NEW.checked_at IS NULL THEN
        NEW.checked_at := ((COALESCE(NEW.date, CURRENT_DATE)::text || ' 12:00:00')::timestamp AT TIME ZONE resolved_timezone);
    END IF;

    NEW.checked_timezone := resolved_timezone;
    NEW.checked_utc_offset_minutes := (
        EXTRACT(EPOCH FROM (
            (NEW.checked_at AT TIME ZONE resolved_timezone) -
            (NEW.checked_at AT TIME ZONE 'UTC')
        )) / 60
    )::INTEGER;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.sync_body_composition_local_day_metadata()
RETURNS TRIGGER AS $$
DECLARE
    resolved_timezone TEXT;
BEGIN
    resolved_timezone := NULLIF(BTRIM(NEW.measured_timezone), '');
    IF resolved_timezone IS NULL THEN
        SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
        INTO resolved_timezone
        FROM users u
        WHERE u.id = NEW.user_id;
    END IF;
    resolved_timezone := COALESCE(resolved_timezone, 'UTC');

    NEW.measured_timezone := resolved_timezone;
    NEW.measured_date := (NEW.measured_at AT TIME ZONE resolved_timezone)::date;
    NEW.measured_utc_offset_minutes := (
        EXTRACT(EPOCH FROM (
            (NEW.measured_at AT TIME ZONE resolved_timezone) -
            (NEW.measured_at AT TIME ZONE 'UTC')
        )) / 60
    )::INTEGER;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Table: wellness_checks
CREATE TABLE wellness_checks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    checked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    date DATE NOT NULL,
    checked_timezone TEXT,
    checked_utc_offset_minutes INTEGER,

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
CREATE TRIGGER sync_wellness_checks_local_day_metadata
    BEFORE INSERT OR UPDATE OF checked_at, date, checked_timezone ON wellness_checks
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_wellness_checks_local_day_metadata();

CREATE TRIGGER set_wellness_checks_updated_at
    BEFORE UPDATE ON wellness_checks
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- Table: body_composition
CREATE TABLE body_composition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    measured_at TIMESTAMPTZ NOT NULL,
    measured_date DATE,
    measured_timezone TEXT,
    measured_utc_offset_minutes INTEGER,
    
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
CREATE INDEX idx_body_comp_user_measured_date ON body_composition(user_id, measured_date DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_body_comp_weight ON body_composition(user_id, weight_kg);
CREATE INDEX idx_body_comp_source ON body_composition(source);
CREATE INDEX idx_body_comp_type ON body_composition(input_type);

-- Trigger for updated_at
CREATE TRIGGER sync_body_composition_local_day_metadata
    BEFORE INSERT OR UPDATE OF measured_at, measured_timezone ON body_composition
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_body_composition_local_day_metadata();

CREATE TRIGGER set_body_composition_updated_at
    BEFORE UPDATE ON body_composition
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- Table: hydration_logs
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


-- Table: training_loads
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


-- Table: exercise_catalog
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


-- Table: training_plans
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


-- Table: workout_sessions
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
  WHERE deleted_at IS NOT NULL;

CREATE TRIGGER set_workout_sessions_updated_at
    BEFORE UPDATE ON workout_sessions
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- Table: workout_exercises
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


-- Table: workout_sets
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


-- Table: training_plan_sessions
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


-- Table: experiments
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


-- Table: experiment_measurements
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


-- Table: insights
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

CREATE TABLE insights (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Classification
    category TEXT NOT NULL CHECK (category IN ('recovery', 'nutrition', 'training', 'sleep', 'supplement', 'health', 'experiment', 'general')),
    type TEXT,
    priority INTEGER DEFAULT 5,

    -- Core content
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    description TEXT,
    reasoning TEXT,

    -- Confidence + provenance
    confidence NUMERIC(3,2) NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    confidence_score NUMERIC(3,2) CHECK (confidence_score >= 0 AND confidence_score <= 1),
    inputs_used JSONB,
    needs_review BOOLEAN DEFAULT FALSE,

    -- Correlation metadata
    data_points INTEGER,
    correlation_method TEXT,
    correlation_coefficient NUMERIC(6,4),
    p_value NUMERIC(8,6),
    lag_days INTEGER,
    confounders TEXT[],
    related_metrics metric_key[],
    related_dates DATE[],

    -- Actionability
    actionable BOOLEAN DEFAULT FALSE,
    action_type TEXT,
    suggested_experiment_id UUID REFERENCES experiments(id) ON DELETE SET NULL,

    -- User interaction state
    shown_to_user BOOLEAN DEFAULT FALSE,
    shown_at TIMESTAMPTZ,
    read BOOLEAN DEFAULT FALSE,
    read_at TIMESTAMPTZ,
    acknowledged BOOLEAN DEFAULT FALSE,
    acknowledged_at TIMESTAMPTZ,
    dismissed BOOLEAN DEFAULT FALSE,
    dismissed_at TIMESTAMPTZ,
    acted_upon BOOLEAN DEFAULT FALSE,
    action_taken TEXT,

    -- Lifecycle
    expires_at TIMESTAMPTZ
);

CREATE INDEX idx_insights_user_created ON insights(user_id, created_at DESC);
CREATE INDEX idx_insights_category ON insights(user_id, category, created_at DESC);
CREATE INDEX idx_insights_active ON insights(user_id, dismissed) WHERE dismissed = FALSE;

CREATE TRIGGER set_insights_updated_at
    BEFORE UPDATE ON insights
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- Table: recommendations
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


-- Table: weekly_strategy_reports
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


-- Table: medical_scans
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


-- Table: health_marker_catalog
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


-- Table: health_measurements
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


-- Table: health_diagnoses
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


-- Table: vector_memory
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


-- Table: onboarding_state
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


-- Table: user_baselines
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


-- Table: privacy_settings
CREATE TABLE privacy_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    menstrual_local_only BOOLEAN NOT NULL DEFAULT TRUE,
    medical_scan_local_only BOOLEAN NOT NULL DEFAULT TRUE,
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


-- Table: analytics_events
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


-- Table: sleep_logs
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


-- Table: training_templates
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

-- ============================================================
-- CONSOLIDATED MIGRATIONS (002–019)
-- All incremental migrations merged into a single initial schema.
-- ============================================================


-- ============================================================
-- [002] Ops tables (notification scheduler + GDPR export jobs)
-- ============================================================

CREATE TABLE IF NOT EXISTS notification_log (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    priority TEXT NOT NULL,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    deep_link TEXT,
    delivered_at TIMESTAMPTZ NOT NULL,
    delivered_date_local DATE NOT NULL,
    timezone TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notification_log_user_day
    ON notification_log(user_id, delivered_date_local);

CREATE INDEX IF NOT EXISTS idx_notification_log_user_category
    ON notification_log(user_id, category, delivered_at DESC);

CREATE TABLE IF NOT EXISTS export_jobs (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('pending', 'processing', 'ready', 'failed', 'expired')),
    download_url TEXT,
    requested_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    failure_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_export_jobs_user_requested
    ON export_jobs(user_id, requested_at DESC);

CREATE TABLE IF NOT EXISTS deletion_audit_log (
    id UUID PRIMARY KEY,
    user_id_deleted UUID NOT NULL,
    deleted_at TIMESTAMPTZ NOT NULL,
    vectors_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    postgres_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    compliance_verified BOOLEAN NOT NULL DEFAULT FALSE,
    notes TEXT
);

CREATE INDEX IF NOT EXISTS idx_deletion_audit_user
    ON deletion_audit_log(user_id_deleted, deleted_at DESC);

CREATE TABLE IF NOT EXISTS deletion_failures (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    failure_type TEXT NOT NULL CHECK (failure_type IN ('pinecone', 'postgres', 'auth')),
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    retried_at TIMESTAMPTZ,
    resolved BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX IF NOT EXISTS idx_deletion_failures_user_created
    ON deletion_failures(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS consent_records (
    id UUID PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    consent_type TEXT NOT NULL,
    granted BOOLEAN NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    version TEXT NOT NULL,
    ip_address TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_consent_records_user_type
    ON consent_records(user_id, consent_type, timestamp DESC);

ALTER TABLE privacy_settings
    ADD COLUMN IF NOT EXISTS cloud_backup_enabled BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE export_jobs
    ADD COLUMN IF NOT EXISTS failure_reason TEXT;

ALTER TABLE deletion_audit_log
    ADD COLUMN IF NOT EXISTS user_id_deleted UUID,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS vectors_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS postgres_deleted BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS compliance_verified BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS notes TEXT;

ALTER TABLE deletion_failures
    ADD COLUMN IF NOT EXISTS failure_type TEXT,
    ADD COLUMN IF NOT EXISTS error TEXT,
    ADD COLUMN IF NOT EXISTS retried_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS resolved BOOLEAN NOT NULL DEFAULT FALSE;

-- NOTE: insights table is already created in the main schema section (line ~1522).
-- The ops_tables version was a duplicate with a slightly different schema.
-- Removed to avoid confusion. The canonical definition is the one with
-- NUMERIC types and TEXT[] arrays in the main schema block.


-- ============================================================
-- [003] food_logs needs_review column + trigger
-- ============================================================

ALTER TABLE food_logs
  ADD COLUMN IF NOT EXISTS needs_review BOOLEAN DEFAULT FALSE;

UPDATE food_logs
SET needs_review = CASE
  WHEN ai_confidence IS NOT NULL AND ai_confidence < 0.65 THEN TRUE
  ELSE FALSE
END
WHERE TRUE;

CREATE OR REPLACE FUNCTION set_food_log_needs_review()
RETURNS TRIGGER AS $$
BEGIN
    NEW.needs_review := CASE
        WHEN NEW.ai_confidence IS NOT NULL AND NEW.ai_confidence < 0.65 THEN TRUE
        ELSE FALSE
    END;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_food_logs_needs_review ON food_logs;

CREATE TRIGGER set_food_logs_needs_review
    BEFORE INSERT OR UPDATE OF ai_confidence ON food_logs
    FOR EACH ROW
    EXECUTE FUNCTION set_food_log_needs_review();


-- ============================================================
-- [004] Security baseline: RLS, menstrual_logs
-- ============================================================
-- NOTE: update_updated_at_column() already defined at top of file (line 3).

CREATE TABLE IF NOT EXISTS menstrual_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    flow TEXT CHECK (flow IN ('light', 'medium', 'heavy', 'spotting')),
    pain_level INTEGER CHECK (pain_level BETWEEN 1 AND 5),
    deleted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, date)
);

CREATE INDEX IF NOT EXISTS idx_menstrual_logs_user_date
    ON menstrual_logs(user_id, date DESC)
    WHERE deleted_at IS NULL;

DROP TRIGGER IF EXISTS set_menstrual_logs_updated_at ON menstrual_logs;
CREATE TRIGGER set_menstrual_logs_updated_at
    BEFORE UPDATE ON menstrual_logs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'users'
          AND policyname = 'users_self_access'
    ) THEN
        CREATE POLICY users_self_access ON public.users
            FOR ALL
            USING (auth_id = auth.uid())
            WITH CHECK (auth_id = auth.uid());
    END IF;
END;
$$;

DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT DISTINCT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema
         AND t.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND c.column_name = 'user_id'
          AND t.table_type = 'BASE TABLE'
          AND c.table_name <> 'users'
    LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.table_name);

        PERFORM 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = r.table_name
          AND policyname = 'user_isolation';

        IF NOT FOUND THEN
            EXECUTE format(
                'CREATE POLICY user_isolation ON public.%I
                 FOR ALL
                 USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()))
                 WITH CHECK (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()))',
                r.table_name
            );
        END IF;
    END LOOP;
END;
$$;


-- ============================================================
-- [005] Runtime hardening: rate limits, notification helper, delete_user_account
-- ============================================================

CREATE TABLE IF NOT EXISTS rate_limit_windows (
    bucket_key TEXT PRIMARY KEY,
    count INTEGER NOT NULL CHECK (count >= 0),
    window_seconds INTEGER NOT NULL CHECK (window_seconds > 0),
    reset_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_windows_reset_at
    ON rate_limit_windows(reset_at);

CREATE OR REPLACE FUNCTION public.check_rate_limit_bucket(
    p_bucket_key TEXT,
    p_limit INTEGER,
    p_window_seconds INTEGER
)
RETURNS TABLE (
    ok BOOLEAN,
    retry_after_seconds INTEGER,
    remaining INTEGER,
    reset_epoch_seconds BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_now TIMESTAMPTZ := NOW();
    v_count INTEGER;
    v_reset TIMESTAMPTZ;
BEGIN
    IF p_bucket_key IS NULL OR btrim(p_bucket_key) = '' OR p_limit <= 0 OR p_window_seconds <= 0 THEN
        RETURN QUERY
        SELECT FALSE, 60, 0, EXTRACT(EPOCH FROM (v_now + INTERVAL '60 seconds'))::BIGINT;
        RETURN;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(p_bucket_key));

    SELECT count, reset_at
      INTO v_count, v_reset
      FROM rate_limit_windows
     WHERE bucket_key = p_bucket_key
     FOR UPDATE;

    IF NOT FOUND OR v_reset <= v_now THEN
        v_count := 0;
        v_reset := v_now + make_interval(secs => p_window_seconds);

        INSERT INTO rate_limit_windows (bucket_key, count, window_seconds, reset_at, updated_at)
        VALUES (p_bucket_key, 0, p_window_seconds, v_reset, v_now)
        ON CONFLICT (bucket_key)
        DO UPDATE SET
            count = 0,
            window_seconds = EXCLUDED.window_seconds,
            reset_at = EXCLUDED.reset_at,
            updated_at = EXCLUDED.updated_at;
    END IF;

    IF v_count >= p_limit THEN
        RETURN QUERY
        SELECT
            FALSE,
            GREATEST(1, CEIL(EXTRACT(EPOCH FROM (v_reset - v_now)))::INTEGER),
            0,
            EXTRACT(EPOCH FROM v_reset)::BIGINT;
        RETURN;
    END IF;

    v_count := v_count + 1;

    UPDATE rate_limit_windows
       SET count = v_count,
           window_seconds = p_window_seconds,
           updated_at = v_now
     WHERE bucket_key = p_bucket_key;

    RETURN QUERY
    SELECT
        TRUE,
        0,
        GREATEST(0, p_limit - v_count),
        EXTRACT(EPOCH FROM v_reset)::BIGINT;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_user_account(user_uuid UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted INTEGER := 0;
BEGIN
    IF user_uuid IS NULL THEN
        RETURN FALSE;
    END IF;

    DELETE FROM public.users WHERE id = user_uuid;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN v_deleted > 0;
END;
$$;

-- Note: attempt_insert_notification_log is defined in its final form
-- from migration 008 (dedup window fix) below, superseding the versions
-- from migrations 005 and 007.

DO $$
BEGIN
    EXECUTE 'ALTER VIEW public.daily_nutrition_summary SET (security_invoker = true)';
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.check_rate_limit_bucket(TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_user_account(UUID) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.check_rate_limit_bucket(TEXT, INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.delete_user_account(UUID) TO service_role;


-- ============================================================
-- [006] Auth user bootstrap trigger
-- ============================================================

CREATE OR REPLACE FUNCTION public.bootstrap_user_from_auth()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.users (
        id,
        auth_id,
        email,
        timezone,
        units,
        notification_enabled,
        onboarding_completed,
        calibration_days_remaining,
        deletion_in_progress
    )
    VALUES (
        NEW.id,
        NEW.id,
        NEW.email,
        COALESCE(NULLIF(NEW.raw_user_meta_data ->> 'timezone', ''), 'UTC'),
        'metric',
        TRUE,
        FALSE,
        3,
        FALSE
    )
    ON CONFLICT (auth_id) DO UPDATE
    SET email = COALESCE(EXCLUDED.email, public.users.email),
        updated_at = NOW();

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.bootstrap_user_from_auth();

-- Backfill existing auth users that are missing public.users records.
INSERT INTO public.users (
    id,
    auth_id,
    email,
    timezone,
    units,
    notification_enabled,
    onboarding_completed,
    calibration_days_remaining,
    deletion_in_progress
)
SELECT
    au.id,
    au.id,
    au.email,
    COALESCE(NULLIF(au.raw_user_meta_data ->> 'timezone', ''), 'UTC'),
    'metric',
    TRUE,
    FALSE,
    3,
    FALSE
FROM auth.users AS au
LEFT JOIN public.users AS pu
    ON pu.auth_id = au.id
WHERE pu.id IS NULL
ON CONFLICT DO NOTHING;


-- ============================================================
-- [007+008] Notification helper: critical cap bypass + symmetric dedup window
-- (Final version — supersedes 005/007 definitions)
-- ============================================================

DROP FUNCTION IF EXISTS public.attempt_insert_notification_log(
    UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, DATE, TEXT, INTEGER, INTEGER
);

CREATE OR REPLACE FUNCTION public.attempt_insert_notification_log(
    p_id UUID,
    p_user_id UUID,
    p_category TEXT,
    p_priority TEXT,
    p_title TEXT,
    p_body TEXT,
    p_deep_link TEXT,
    p_delivered_at TIMESTAMPTZ,
    p_delivered_date_local DATE,
    p_timezone TEXT,
    p_dedup_seconds INTEGER,
    p_max_per_day INTEGER,
    p_bypass_daily_cap BOOLEAN DEFAULT FALSE
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_day_count INTEGER := 0;
BEGIN
    IF p_id IS NULL OR p_user_id IS NULL THEN
        RETURN 'invalid_arguments';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext(p_user_id::TEXT));

    IF EXISTS (
        SELECT 1
        FROM notification_log
        WHERE id = p_id
          AND user_id = p_user_id
    ) THEN
        RETURN 'accepted';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM notification_log
        WHERE id = p_id
          AND user_id <> p_user_id
    ) THEN
        RETURN 'id_conflict';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM notification_log
        WHERE user_id = p_user_id
          AND category = p_category
          AND delivered_at BETWEEN
              (p_delivered_at - make_interval(secs => GREATEST(1, p_dedup_seconds)))
              AND
              (p_delivered_at + make_interval(secs => GREATEST(1, p_dedup_seconds)))
    ) THEN
        RETURN 'category_dedup';
    END IF;

    IF NOT COALESCE(p_bypass_daily_cap, FALSE) THEN
        SELECT COUNT(*)
          INTO v_day_count
          FROM notification_log
         WHERE user_id = p_user_id
           AND delivered_date_local = p_delivered_date_local;

        IF v_day_count >= GREATEST(1, p_max_per_day) THEN
            RETURN 'daily_cap';
        END IF;
    END IF;

    INSERT INTO notification_log (
        id,
        user_id,
        category,
        priority,
        title,
        body,
        deep_link,
        delivered_at,
        delivered_date_local,
        timezone
    ) VALUES (
        p_id,
        p_user_id,
        p_category,
        p_priority,
        p_title,
        p_body,
        p_deep_link,
        p_delivered_at,
        p_delivered_date_local,
        p_timezone
    );

    RETURN 'accepted';
END;
$$;

REVOKE ALL ON FUNCTION public.attempt_insert_notification_log(
    UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, DATE, TEXT, INTEGER, INTEGER, BOOLEAN
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.attempt_insert_notification_log(
    UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TIMESTAMPTZ, DATE, TEXT, INTEGER, INTEGER, BOOLEAN
) TO service_role;


-- ============================================================
-- [009] Rate limit windows housekeeping + pg_cron
-- ============================================================

CREATE OR REPLACE FUNCTION public.cleanup_rate_limit_windows(
    p_batch_size INTEGER DEFAULT 5000
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_batch_size INTEGER := GREATEST(1, COALESCE(p_batch_size, 5000));
    v_deleted INTEGER := 0;
BEGIN
    WITH stale AS (
        SELECT bucket_key
        FROM public.rate_limit_windows
        WHERE reset_at <= NOW()
        ORDER BY reset_at ASC
        LIMIT v_batch_size
    )
    DELETE FROM public.rate_limit_windows AS w
    USING stale
    WHERE w.bucket_key = stale.bucket_key;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_rate_limit_windows(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_rate_limit_windows(INTEGER) TO service_role;

DO $$
DECLARE
    v_jobid BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid
          INTO v_jobid
          FROM cron.job
         WHERE jobname = 'cleanup_rate_limit_windows'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        PERFORM cron.schedule(
            'cleanup_rate_limit_windows',
            '*/15 * * * *',
            $cron$SELECT public.cleanup_rate_limit_windows(5000);$cron$
        );
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- pg_cron can be unavailable in local/dev environments.
        NULL;
END;
$$;


-- ============================================================
-- [010] Account deletion jobs state machine
-- ============================================================

CREATE TABLE IF NOT EXISTS account_deletion_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    idempotency_key TEXT NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('scheduled', 'immediate')),
    state TEXT NOT NULL CHECK (
        state IN (
            'requested',
            'scheduled',
            'auth_deleting',
            'data_deleting',
            'vector_verifying',
            'retry_scheduled',
            'completed',
            'failed',
            'cancelled'
        )
    ),
    reason TEXT,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_retry_at TIMESTAMPTZ,
    last_error TEXT,
    last_failure_type TEXT CHECK (last_failure_type IN ('auth', 'postgres', 'pinecone')),
    scheduled_for TIMESTAMPTZ,
    audit_log_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_user_updated
    ON account_deletion_jobs(user_id, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_retry
    ON account_deletion_jobs(state, next_retry_at)
    WHERE state = 'retry_scheduled';

ALTER TABLE account_deletion_jobs
    ADD COLUMN IF NOT EXISTS id UUID DEFAULT gen_random_uuid(),
    ADD COLUMN IF NOT EXISTS user_id UUID,
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT,
    ADD COLUMN IF NOT EXISTS mode TEXT,
    ADD COLUMN IF NOT EXISTS state TEXT,
    ADD COLUMN IF NOT EXISTS reason TEXT,
    ADD COLUMN IF NOT EXISTS attempt_count INTEGER DEFAULT 0,
    ADD COLUMN IF NOT EXISTS next_retry_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_error TEXT,
    ADD COLUMN IF NOT EXISTS last_failure_type TEXT,
    ADD COLUMN IF NOT EXISTS scheduled_for TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS audit_log_id UUID,
    ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW(),
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

UPDATE account_deletion_jobs
SET attempt_count = 0
WHERE attempt_count IS NULL;

ALTER TABLE account_deletion_jobs
    ALTER COLUMN id SET DEFAULT gen_random_uuid(),
    ALTER COLUMN user_id SET NOT NULL,
    ALTER COLUMN idempotency_key SET NOT NULL,
    ALTER COLUMN mode SET NOT NULL,
    ALTER COLUMN state SET NOT NULL,
    ALTER COLUMN attempt_count SET NOT NULL,
    ALTER COLUMN created_at SET NOT NULL,
    ALTER COLUMN updated_at SET NOT NULL;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'account_deletion_jobs_user_id_fkey'
    ) THEN
        ALTER TABLE account_deletion_jobs
            DROP CONSTRAINT account_deletion_jobs_user_id_fkey;
    END IF;
END;
$$;

ALTER TABLE account_deletion_jobs
    DROP CONSTRAINT IF EXISTS account_deletion_jobs_mode_check,
    ADD CONSTRAINT account_deletion_jobs_mode_check
        CHECK (mode IN ('scheduled', 'immediate'));

ALTER TABLE account_deletion_jobs
    DROP CONSTRAINT IF EXISTS account_deletion_jobs_state_check,
    ADD CONSTRAINT account_deletion_jobs_state_check
        CHECK (
            state IN (
                'requested',
                'scheduled',
                'auth_deleting',
                'data_deleting',
                'vector_verifying',
                'retry_scheduled',
                'completed',
                'failed',
                'cancelled'
            )
        );

ALTER TABLE account_deletion_jobs
    DROP CONSTRAINT IF EXISTS account_deletion_jobs_last_failure_type_check,
    ADD CONSTRAINT account_deletion_jobs_last_failure_type_check
        CHECK (
            last_failure_type IS NULL OR
            last_failure_type IN ('auth', 'postgres', 'pinecone')
        );

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'account_deletion_jobs_user_key'
    ) THEN
        ALTER TABLE account_deletion_jobs
            ADD CONSTRAINT account_deletion_jobs_user_key
            UNIQUE (user_id, idempotency_key);
    END IF;
END;
$$;

DROP TRIGGER IF EXISTS set_account_deletion_jobs_updated_at ON account_deletion_jobs;
CREATE TRIGGER set_account_deletion_jobs_updated_at
    BEFORE UPDATE ON account_deletion_jobs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- ============================================================
-- [011] Observability: sync queue SLO dashboard + alert evaluator
-- ============================================================

CREATE TABLE IF NOT EXISTS ops_alert_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source TEXT NOT NULL,
    alert_key TEXT NOT NULL,
    severity TEXT NOT NULL CHECK (severity IN ('warning', 'critical')),
    dedup_window_start TIMESTAMPTZ NOT NULL,
    summary TEXT NOT NULL,
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    triggered_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_ops_alert_events_dedup
    ON ops_alert_events(source, alert_key, severity, dedup_window_start);

CREATE INDEX IF NOT EXISTS idx_ops_alert_events_triggered
    ON ops_alert_events(triggered_at DESC);

CREATE OR REPLACE VIEW ops_sync_queue_slo_dashboard_5m AS
WITH normalized AS (
    SELECT
        created_at,
        user_id,
        COALESCE(properties->>'severity', 'warning') AS severity,
        CASE
            WHEN COALESCE(properties->>'failure_rate', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
                THEN (properties->>'failure_rate')::DOUBLE PRECISION
            ELSE NULL
        END AS failure_rate,
        CASE
            WHEN COALESCE(properties->>'dead_letter_rate', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
                THEN (properties->>'dead_letter_rate')::DOUBLE PRECISION
            ELSE NULL
        END AS dead_letter_rate
    FROM analytics_events
    WHERE event_name = 'sync_queue_slo_alert'
      AND created_at >= NOW() - INTERVAL '24 hours'
)
SELECT
    TIMESTAMPTZ 'epoch' +
        FLOOR(EXTRACT(EPOCH FROM created_at) / 300.0) * INTERVAL '300 seconds' AS bucket_5m,
    COUNT(*) AS alert_events,
    COUNT(*) FILTER (WHERE severity = 'critical') AS critical_alerts,
    COUNT(*) FILTER (WHERE severity = 'warning') AS warning_alerts,
    COUNT(DISTINCT user_id) AS affected_users,
    AVG(failure_rate) AS avg_failure_rate,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY failure_rate) AS p95_failure_rate,
    AVG(dead_letter_rate) AS avg_dead_letter_rate
FROM normalized
GROUP BY 1
ORDER BY 1 DESC;

CREATE OR REPLACE VIEW ops_server_queue_dashboard_5m AS
SELECT
    TIMESTAMPTZ 'epoch' +
        FLOOR(EXTRACT(EPOCH FROM updated_at) / 300.0) * INTERVAL '300 seconds' AS bucket_5m,
    COUNT(*) AS total_jobs,
    COUNT(*) FILTER (
        WHERE state IN ('requested', 'scheduled', 'retry_scheduled', 'auth_deleting', 'data_deleting')
    ) AS queued_jobs,
    COUNT(*) FILTER (WHERE state = 'retry_scheduled') AS retry_scheduled_jobs,
    COUNT(*) FILTER (WHERE state = 'failed') AS failed_jobs,
    AVG(attempt_count)::DOUBLE PRECISION AS avg_attempt_count,
    MAX(next_retry_at) FILTER (WHERE state = 'retry_scheduled') AS farthest_retry_at
FROM account_deletion_jobs
WHERE updated_at >= NOW() - INTERVAL '24 hours'
GROUP BY 1
ORDER BY 1 DESC;

CREATE OR REPLACE VIEW ops_alerts_recent AS
SELECT
    id,
    source,
    alert_key,
    severity,
    summary,
    details,
    triggered_at
FROM ops_alert_events
WHERE triggered_at >= NOW() - INTERVAL '7 days'
ORDER BY triggered_at DESC;

CREATE OR REPLACE FUNCTION public.evaluate_ops_queue_alerts()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_now TIMESTAMPTZ := NOW();
    v_hour_bucket TIMESTAMPTZ := date_trunc('hour', v_now);
    v_inserted INTEGER := 0;
    v_last_row_count INTEGER := 0;
    v_sync_critical_count INTEGER := 0;
    v_sync_warning_count INTEGER := 0;
    v_sync_avg_failure DOUBLE PRECISION := 0;
    v_retry_scheduled_count INTEGER := 0;
    v_failed_last_hour_count INTEGER := 0;
BEGIN
    WITH normalized AS (
        SELECT
            COALESCE(properties->>'severity', 'warning') AS severity,
            CASE
                WHEN COALESCE(properties->>'failure_rate', '') ~ '^-?[0-9]+(\.[0-9]+)?$'
                    THEN (properties->>'failure_rate')::DOUBLE PRECISION
                ELSE NULL
            END AS failure_rate
        FROM analytics_events
        WHERE event_name = 'sync_queue_slo_alert'
          AND created_at >= v_now - INTERVAL '15 minutes'
    )
    SELECT
        COUNT(*) FILTER (WHERE severity = 'critical'),
        COUNT(*) FILTER (WHERE severity = 'warning'),
        COALESCE(AVG(failure_rate), 0)
    INTO
        v_sync_critical_count,
        v_sync_warning_count,
        v_sync_avg_failure
    FROM normalized;

    IF v_sync_critical_count >= 3 OR v_sync_avg_failure >= 0.15 THEN
        INSERT INTO ops_alert_events (
            source, alert_key, severity, dedup_window_start, summary, details
        ) VALUES (
            'sync_queue',
            'sync_queue_degradation',
            'critical',
            v_hour_bucket,
            'Critical sync queue degradation detected from client SLO telemetry.',
            jsonb_build_object(
                'critical_alerts_15m', v_sync_critical_count,
                'warning_alerts_15m', v_sync_warning_count,
                'avg_failure_rate_15m', v_sync_avg_failure
            )
        )
        ON CONFLICT (source, alert_key, severity, dedup_window_start) DO NOTHING;

        GET DIAGNOSTICS v_inserted = ROW_COUNT;
    ELSIF v_sync_warning_count >= 5 OR v_sync_avg_failure >= 0.07 THEN
        INSERT INTO ops_alert_events (
            source, alert_key, severity, dedup_window_start, summary, details
        ) VALUES (
            'sync_queue',
            'sync_queue_degradation',
            'warning',
            v_hour_bucket,
            'Warning-level sync queue degradation detected from client SLO telemetry.',
            jsonb_build_object(
                'critical_alerts_15m', v_sync_critical_count,
                'warning_alerts_15m', v_sync_warning_count,
                'avg_failure_rate_15m', v_sync_avg_failure
            )
        )
        ON CONFLICT (source, alert_key, severity, dedup_window_start) DO NOTHING;

        GET DIAGNOSTICS v_inserted = ROW_COUNT;
    END IF;

    SELECT
        COUNT(*) FILTER (WHERE state = 'retry_scheduled'),
        COUNT(*) FILTER (WHERE state = 'failed' AND updated_at >= v_now - INTERVAL '1 hour')
    INTO
        v_retry_scheduled_count,
        v_failed_last_hour_count
    FROM account_deletion_jobs;

    IF v_retry_scheduled_count >= 20 OR v_failed_last_hour_count >= 5 THEN
        INSERT INTO ops_alert_events (
            source, alert_key, severity, dedup_window_start, summary, details
        ) VALUES (
            'server_queue',
            'account_deletion_queue_degradation',
            'critical',
            v_hour_bucket,
            'Critical degradation in account deletion server queue.',
            jsonb_build_object(
                'retry_scheduled_jobs', v_retry_scheduled_count,
                'failed_jobs_last_hour', v_failed_last_hour_count
            )
        )
        ON CONFLICT (source, alert_key, severity, dedup_window_start) DO NOTHING;

        GET DIAGNOSTICS v_last_row_count = ROW_COUNT;
        v_inserted := v_inserted + v_last_row_count;
    ELSIF v_retry_scheduled_count >= 10 OR v_failed_last_hour_count >= 2 THEN
        INSERT INTO ops_alert_events (
            source, alert_key, severity, dedup_window_start, summary, details
        ) VALUES (
            'server_queue',
            'account_deletion_queue_degradation',
            'warning',
            v_hour_bucket,
            'Warning-level degradation in account deletion server queue.',
            jsonb_build_object(
                'retry_scheduled_jobs', v_retry_scheduled_count,
                'failed_jobs_last_hour', v_failed_last_hour_count
            )
        )
        ON CONFLICT (source, alert_key, severity, dedup_window_start) DO NOTHING;

        GET DIAGNOSTICS v_last_row_count = ROW_COUNT;
        v_inserted := v_inserted + v_last_row_count;
    END IF;

    RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION public.evaluate_ops_queue_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.evaluate_ops_queue_alerts() TO service_role;

DO $$
DECLARE
    v_jobid BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid
          INTO v_jobid
          FROM cron.job
         WHERE jobname = 'evaluate_ops_queue_alerts'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        PERFORM cron.schedule(
            'evaluate_ops_queue_alerts',
            '*/5 * * * *',
            $cron$SELECT public.evaluate_ops_queue_alerts();$cron$
        );
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- pg_cron can be unavailable in local/dev environments.
        NULL;
END;
$$;


-- ============================================================
-- [012] Account deletion jobs hardening: FK + RLS
-- ============================================================

DELETE FROM public.account_deletion_jobs j
WHERE NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = j.user_id
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'account_deletion_jobs_user_id_fkey'
    ) THEN
        ALTER TABLE public.account_deletion_jobs
            ADD CONSTRAINT account_deletion_jobs_user_id_fkey
            FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;
    END IF;
END;
$$;

ALTER TABLE public.account_deletion_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_deletion_jobs FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'account_deletion_jobs'
          AND policyname = 'account_deletion_jobs_user_isolation'
    ) THEN
        CREATE POLICY account_deletion_jobs_user_isolation
            ON public.account_deletion_jobs
            FOR ALL
            USING (
                user_id IN (
                    SELECT id
                    FROM public.users
                    WHERE auth_id = auth.uid()
                )
            )
            WITH CHECK (
                user_id IN (
                    SELECT id
                    FROM public.users
                    WHERE auth_id = auth.uid()
                )
            );
    END IF;
END;
$$;


-- ============================================================
-- [013] Scheduled account deletion worker
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_scheduled_due
    ON public.account_deletion_jobs (scheduled_for, created_at)
    WHERE mode = 'scheduled' AND state = 'scheduled';

CREATE OR REPLACE FUNCTION public.account_deletion_retry_delay_seconds(
    p_attempt_count INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_attempt INTEGER := GREATEST(1, COALESCE(p_attempt_count, 1));
    v_backoff INTEGER;
BEGIN
    -- 5m, 10m, 20m, 40m, capped at 6h.
    v_backoff := 300 * CAST(POWER(2, v_attempt - 1) AS INTEGER);
    RETURN LEAST(21600, GREATEST(300, v_backoff));
END;
$$;

CREATE OR REPLACE FUNCTION public.classify_account_deletion_failure_type(
    p_error TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_error TEXT := LOWER(COALESCE(p_error, ''));
BEGIN
    IF v_error LIKE '%vector%' OR v_error LIKE '%pinecone%' THEN
        RETURN 'pinecone';
    END IF;

    IF v_error LIKE '%auth%' THEN
        RETURN 'auth';
    END IF;

    RETURN 'postgres';
END;
$$;

CREATE OR REPLACE FUNCTION public.process_due_account_deletion_job(
    p_job_id UUID,
    p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_now TIMESTAMPTZ := COALESCE(p_now, NOW());
    v_job public.account_deletion_jobs%ROWTYPE;
    v_auth_id UUID;
    v_effective_reason TEXT;
    v_deleted_auth_rows INTEGER := 0;
    v_remaining_vectors BIGINT := 0;
    v_attempt_count INTEGER := 0;
    v_audit_log_id UUID;
BEGIN
    SELECT j.*
    INTO v_job
    FROM public.account_deletion_jobs AS j
    JOIN public.users AS u
      ON u.id = j.user_id
    WHERE j.id = p_job_id
      AND j.mode = 'scheduled'
    FOR UPDATE OF j, u;

    IF NOT FOUND THEN
        RETURN 'skipped_missing_job';
    END IF;

    SELECT
        u.auth_id,
        COALESCE(NULLIF(v_job.reason, ''), NULLIF(u.deletion_reason, ''), 'user_requested')
    INTO
        v_auth_id,
        v_effective_reason
    FROM public.users AS u
    WHERE u.id = v_job.user_id;

    IF v_job.state = 'cancelled' THEN
        RETURN 'skipped_cancelled';
    END IF;

    IF v_job.state = 'scheduled' AND (
        v_job.scheduled_for IS NULL OR v_job.scheduled_for > v_now
    ) THEN
        RETURN 'skipped_not_due';
    END IF;

    IF v_job.state = 'retry_scheduled' AND (
        v_job.next_retry_at IS NULL OR v_job.next_retry_at > v_now
    ) THEN
        RETURN 'skipped_not_due';
    END IF;

    IF v_job.state NOT IN ('scheduled', 'retry_scheduled') THEN
        RETURN 'skipped_terminal';
    END IF;

    v_attempt_count := GREATEST(0, COALESCE(v_job.attempt_count, 0)) + 1;

    UPDATE public.users
       SET deletion_in_progress = TRUE,
           deletion_reason = v_effective_reason
     WHERE id = v_job.user_id;

    UPDATE public.account_deletion_jobs
       SET state = 'auth_deleting',
           attempt_count = v_attempt_count,
           reason = v_effective_reason,
           next_retry_at = NULL,
           last_error = NULL,
           last_failure_type = NULL
     WHERE id = v_job.id
       AND state = v_job.state;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'deletion_job_state_conflict:%', v_job.id;
    END IF;

    DELETE FROM auth.users
     WHERE id = v_auth_id;

    GET DIAGNOSTICS v_deleted_auth_rows = ROW_COUNT;
    IF v_deleted_auth_rows = 0 THEN
        RAISE EXCEPTION 'auth_user_not_found';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.users
        WHERE id = v_job.user_id
    ) THEN
        RAISE EXCEPTION 'public_user_remaining_after_auth_delete';
    END IF;

    SELECT COUNT(*)
      INTO v_remaining_vectors
      FROM public.vector_memory
     WHERE user_id = v_job.user_id;

    IF v_remaining_vectors > 0 THEN
        RAISE EXCEPTION 'vector_records_remaining_after_delete';
    END IF;

    v_audit_log_id := COALESCE(v_job.audit_log_id, gen_random_uuid());

    INSERT INTO public.deletion_audit_log (
        id,
        user_id_deleted,
        deleted_at,
        vectors_deleted,
        postgres_deleted,
        compliance_verified,
        notes
    ) VALUES (
        v_audit_log_id,
        v_job.user_id,
        v_now,
        TRUE,
        TRUE,
        TRUE,
        NULL
    )
    ON CONFLICT (id) DO UPDATE
    SET deleted_at = EXCLUDED.deleted_at,
        vectors_deleted = EXCLUDED.vectors_deleted,
        postgres_deleted = EXCLUDED.postgres_deleted,
        compliance_verified = EXCLUDED.compliance_verified,
        notes = EXCLUDED.notes;

    UPDATE public.deletion_failures
       SET resolved = TRUE,
           retried_at = v_now
     WHERE user_id = v_job.user_id
       AND resolved = FALSE;

    RETURN 'completed';
END;
$$;

CREATE OR REPLACE FUNCTION public.handle_due_account_deletion_job_failure(
    p_job_id UUID,
    p_error TEXT,
    p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
    v_now TIMESTAMPTZ := COALESCE(p_now, NOW());
    v_job public.account_deletion_jobs%ROWTYPE;
    v_effective_reason TEXT;
    v_user_exists BOOLEAN := FALSE;
    v_failure_type TEXT;
    v_next_attempt INTEGER := 0;
    v_next_retry_at TIMESTAMPTZ;
    v_retry_delay_seconds INTEGER := 0;
    v_audit_log_id UUID;
    v_error TEXT := LEFT(COALESCE(p_error, 'scheduled_deletion_failed'), 2048);
BEGIN
    SELECT j.*
    INTO v_job
    FROM public.account_deletion_jobs AS j
    WHERE j.id = p_job_id
      AND j.mode = 'scheduled'
    FOR UPDATE OF j;

    IF NOT FOUND THEN
        RETURN 'skipped_missing_job';
    END IF;

    SELECT
        COALESCE(NULLIF(v_job.reason, ''), NULLIF(u.deletion_reason, ''), 'user_requested'),
        (u.id IS NOT NULL)
    INTO
        v_effective_reason,
        v_user_exists
    FROM (SELECT 1) AS seed
    LEFT JOIN public.users AS u
      ON u.id = v_job.user_id;

    IF v_job.state IN ('cancelled', 'completed', 'failed') THEN
        RETURN 'skipped_terminal';
    END IF;

    v_failure_type := public.classify_account_deletion_failure_type(v_error);
    v_next_attempt := GREATEST(0, COALESCE(v_job.attempt_count, 0)) + 1;

    INSERT INTO public.deletion_failures (
        user_id,
        failure_type,
        error,
        created_at,
        resolved
    ) VALUES (
        v_job.user_id,
        v_failure_type,
        v_error,
        v_now,
        FALSE
    );

    IF v_next_attempt < 5 THEN
        v_retry_delay_seconds := public.account_deletion_retry_delay_seconds(v_next_attempt);
        v_next_retry_at := v_now + make_interval(secs => v_retry_delay_seconds);

        UPDATE public.account_deletion_jobs
           SET state = 'retry_scheduled',
               attempt_count = v_next_attempt,
               next_retry_at = v_next_retry_at,
               last_error = v_error,
               last_failure_type = v_failure_type,
               reason = v_effective_reason
         WHERE id = v_job.id;

        IF v_user_exists THEN
            UPDATE public.users
               SET deletion_in_progress = FALSE,
                   deletion_reason = v_effective_reason,
                   deletion_scheduled_at = v_next_retry_at
             WHERE id = v_job.user_id;
        END IF;

        RETURN 'retry_scheduled';
    END IF;

    v_audit_log_id := COALESCE(v_job.audit_log_id, gen_random_uuid());

    INSERT INTO public.deletion_audit_log (
        id,
        user_id_deleted,
        deleted_at,
        vectors_deleted,
        postgres_deleted,
        compliance_verified,
        notes
    ) VALUES (
        v_audit_log_id,
        v_job.user_id,
        v_now,
        FALSE,
        FALSE,
        FALSE,
        v_error
    )
    ON CONFLICT (id) DO UPDATE
    SET deleted_at = EXCLUDED.deleted_at,
        vectors_deleted = EXCLUDED.vectors_deleted,
        postgres_deleted = EXCLUDED.postgres_deleted,
        compliance_verified = EXCLUDED.compliance_verified,
        notes = EXCLUDED.notes;

    UPDATE public.account_deletion_jobs
       SET state = 'failed',
           attempt_count = v_next_attempt,
           next_retry_at = NULL,
           last_error = v_error,
           last_failure_type = v_failure_type,
           audit_log_id = v_audit_log_id,
           reason = v_effective_reason
     WHERE id = v_job.id;

    IF v_user_exists THEN
        UPDATE public.users
           SET deletion_in_progress = FALSE,
               deletion_reason = v_effective_reason,
               deletion_scheduled_at = NULL
         WHERE id = v_job.user_id;
    END IF;

    RETURN 'failed';
END;
$$;

REVOKE ALL ON FUNCTION public.account_deletion_retry_delay_seconds(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.classify_account_deletion_failure_type(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_due_account_deletion_job(UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.handle_due_account_deletion_job_failure(UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.account_deletion_retry_delay_seconds(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION public.classify_account_deletion_failure_type(TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.process_due_account_deletion_job(UUID, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION public.handle_due_account_deletion_job_failure(UUID, TEXT, TIMESTAMPTZ) TO service_role;

DO $$
DECLARE
    v_jobid BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid
          INTO v_jobid
          FROM cron.job
         WHERE jobname = 'process_due_account_deletion_jobs'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        PERFORM cron.schedule(
            'process_due_account_deletion_jobs',
            '*/5 * * * *',
            $cron$SELECT public.process_due_account_deletion_jobs(25);$cron$
        );
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- pg_cron can be unavailable in local/dev environments.
        NULL;
END;
$$;


-- ============================================================
-- [014] Push devices and export artifacts
-- ============================================================

CREATE TABLE IF NOT EXISTS public.push_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ios')),
    push_token TEXT NOT NULL,
    environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
    locale TEXT,
    timezone TEXT,
    app_version TEXT,
    build_number TEXT,
    registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_push_devices_user_device
    ON public.push_devices(user_id, device_id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_push_devices_active_token
    ON public.push_devices(push_token)
    WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_push_devices_dispatch
    ON public.push_devices(user_id, platform, revoked_at, last_seen_at DESC);

ALTER TABLE public.push_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.push_devices FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'push_devices'
          AND policyname = 'push_devices_user_isolation'
    ) THEN
        CREATE POLICY push_devices_user_isolation
            ON public.push_devices
            FOR ALL
            USING (
                EXISTS (
                    SELECT 1
                    FROM public.users AS u
                    WHERE u.id = push_devices.user_id
                      AND u.auth_id = auth.uid()
                )
            )
            WITH CHECK (
                EXISTS (
                    SELECT 1
                    FROM public.users AS u
                    WHERE u.id = push_devices.user_id
                      AND u.auth_id = auth.uid()
                )
            );
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.export_artifacts (
    job_id UUID PRIMARY KEY REFERENCES public.export_jobs(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    download_token UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    payload_json JSONB NOT NULL,
    content_type TEXT NOT NULL DEFAULT 'application/json',
    file_name TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_export_artifacts_user_expiry
    ON public.export_artifacts(user_id, expires_at DESC);

ALTER TABLE public.export_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.export_artifacts FORCE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'export_artifacts'
          AND policyname = 'export_artifacts_user_isolation'
    ) THEN
        CREATE POLICY export_artifacts_user_isolation
            ON public.export_artifacts
            FOR ALL
            USING (
                EXISTS (
                    SELECT 1
                    FROM public.users AS u
                    WHERE u.id = export_artifacts.user_id
                      AND u.auth_id = auth.uid()
                )
            )
            WITH CHECK (
                EXISTS (
                    SELECT 1
                    FROM public.users AS u
                    WHERE u.id = export_artifacts.user_id
                      AND u.auth_id = auth.uid()
                )
            );
    END IF;
END;
$$;


-- ============================================================
-- [015] Medical scan type canonicalization
-- ============================================================

CREATE OR REPLACE FUNCTION public.normalize_medical_scan_type_value(raw_value TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF raw_value IS NULL OR trim(raw_value) = '' THEN
        RETURN NULL;
    END IF;

    CASE lower(trim(COALESCE(raw_value, '')))
        WHEN 'blood_test' THEN RETURN 'blood_test';
        WHEN 'bloodwork' THEN RETURN 'blood_test';
        WHEN 'inbody' THEN RETURN 'inbody';
        WHEN 'dexa' THEN RETURN 'dexa';
        WHEN 'other' THEN RETURN 'other';
        WHEN 'urine' THEN RETURN 'other';
        WHEN 'body_composition' THEN RETURN 'other';
        ELSE RETURN 'other';
    END CASE;
END;
$$;

CREATE OR REPLACE FUNCTION public.normalize_medical_scans_scan_type()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.scan_type := public.normalize_medical_scan_type_value(NEW.scan_type);
    RETURN NEW;
END;
$$;

UPDATE public.medical_scans
SET scan_type = public.normalize_medical_scan_type_value(scan_type);

DROP TRIGGER IF EXISTS trg_normalize_medical_scans_scan_type ON public.medical_scans;

CREATE TRIGGER trg_normalize_medical_scans_scan_type
    BEFORE INSERT OR UPDATE OF scan_type ON public.medical_scans
    FOR EACH ROW
    EXECUTE FUNCTION public.normalize_medical_scans_scan_type();


-- ============================================================
-- [016] Service-role audit logging
-- ============================================================

CREATE TABLE IF NOT EXISTS public.service_role_audit_log (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoked_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    function_name   TEXT NOT NULL,
    invoking_role   TEXT NOT NULL DEFAULT current_setting('role', true),
    target_user_id  UUID,
    args_summary    JSONB,
    result_summary  TEXT,
    duration_ms     DOUBLE PRECISION
);

CREATE INDEX IF NOT EXISTS idx_sra_user
    ON public.service_role_audit_log (target_user_id, invoked_at DESC)
    WHERE target_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_sra_function
    ON public.service_role_audit_log (function_name, invoked_at DESC);

ALTER TABLE public.service_role_audit_log ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE tablename = 'service_role_audit_log'
          AND policyname = 'service_role_audit_log_service_only'
    ) THEN
        CREATE POLICY service_role_audit_log_service_only
            ON public.service_role_audit_log
            FOR ALL
            USING (false)
            WITH CHECK (false);
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.log_service_role_invocation(
    p_function_name TEXT,
    p_target_user_id UUID DEFAULT NULL,
    p_args_summary JSONB DEFAULT NULL,
    p_result_summary TEXT DEFAULT 'ok',
    p_duration_ms DOUBLE PRECISION DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO service_role_audit_log
        (function_name, invoking_role, target_user_id, args_summary, result_summary, duration_ms)
    VALUES
        (p_function_name, current_setting('role', true), p_target_user_id, p_args_summary, p_result_summary, p_duration_ms);
$$;

GRANT EXECUTE ON FUNCTION public.log_service_role_invocation(TEXT, UUID, JSONB, TEXT, DOUBLE PRECISION) TO service_role;

CREATE OR REPLACE FUNCTION public.cleanup_service_role_audit_log(p_retention_days INTEGER DEFAULT 90)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM service_role_audit_log
    WHERE invoked_at < NOW() - (p_retention_days || ' days')::INTERVAL;
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_service_role_audit_log(INTEGER) TO service_role;

-- process_due_account_deletion_jobs with audit logging (final version from 016)
CREATE OR REPLACE FUNCTION public.process_due_account_deletion_jobs(
    p_batch_size INTEGER DEFAULT 5,
    p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(job_id UUID, status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    rec RECORD;
    v_start TIMESTAMPTZ;
    v_elapsed DOUBLE PRECISION;
BEGIN
    FOR rec IN
        SELECT adj.id, adj.user_id
        FROM account_deletion_jobs adj
        WHERE adj.status = 'pending'
          AND adj.scheduled_at <= p_now
        ORDER BY adj.scheduled_at ASC
        LIMIT p_batch_size
        FOR UPDATE SKIP LOCKED
    LOOP
        v_start := clock_timestamp();
        BEGIN
            PERFORM process_due_account_deletion_job(rec.id, p_now);
            v_elapsed := EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000;

            PERFORM log_service_role_invocation(
                'process_due_account_deletion_job',
                rec.user_id,
                jsonb_build_object('job_id', rec.id),
                'ok',
                v_elapsed
            );

            job_id := rec.id;
            status := 'ok';
            detail := NULL;
            RETURN NEXT;
        EXCEPTION WHEN OTHERS THEN
            v_elapsed := EXTRACT(EPOCH FROM clock_timestamp() - v_start) * 1000;

            PERFORM handle_due_account_deletion_job_failure(rec.id, SQLERRM, p_now);

            PERFORM log_service_role_invocation(
                'process_due_account_deletion_job',
                rec.user_id,
                jsonb_build_object('job_id', rec.id),
                'error: ' || SQLERRM,
                v_elapsed
            );

            job_id := rec.id;
            status := 'error';
            detail := SQLERRM;
            RETURN NEXT;
        END;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.process_due_account_deletion_jobs(INTEGER, TIMESTAMPTZ) TO service_role;


-- ============================================================
-- [017] Explicit RLS policies (replaces blanket FOR ALL policies)
-- ============================================================

-- 1. users table: replace users_self_access (FOR ALL)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'users_self_access') THEN
        DROP POLICY users_self_access ON public.users;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'users_select_own') THEN
        CREATE POLICY users_select_own ON public.users
            FOR SELECT USING (auth_id = auth.uid());
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'users_update_own') THEN
        CREATE POLICY users_update_own ON public.users
            FOR UPDATE USING (auth_id = auth.uid()) WITH CHECK (auth_id = auth.uid());
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'users_insert_own') THEN
        CREATE POLICY users_insert_own ON public.users
            FOR INSERT WITH CHECK (auth_id = auth.uid());
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'users' AND policyname = 'users_no_delete') THEN
        CREATE POLICY users_no_delete ON public.users
            FOR DELETE USING (false);
    END IF;
END;
$$;

-- 2. All user_id-scoped tables: replace user_isolation (FOR ALL)
DO $$
DECLARE
    tbl TEXT;
    user_id_subquery TEXT := '(SELECT id FROM public.users WHERE auth_id = auth.uid())';
BEGIN
    FOR tbl IN
        SELECT DISTINCT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND c.column_name = 'user_id'
          AND t.table_type = 'BASE TABLE'
          AND c.table_name <> 'users'
          AND c.table_name NOT IN ('service_role_audit_log')
    LOOP
        IF EXISTS (
            SELECT 1 FROM pg_policies
            WHERE tablename = tbl AND policyname = 'user_isolation'
        ) THEN
            EXECUTE format('DROP POLICY user_isolation ON public.%I', tbl);
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE tablename = tbl AND policyname = 'user_select_own'
        ) THEN
            EXECUTE format(
                'CREATE POLICY user_select_own ON public.%I FOR SELECT USING (user_id IN %s)',
                tbl, user_id_subquery
            );
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE tablename = tbl AND policyname = 'user_insert_own'
        ) THEN
            EXECUTE format(
                'CREATE POLICY user_insert_own ON public.%I FOR INSERT WITH CHECK (user_id IN %s)',
                tbl, user_id_subquery
            );
        END IF;

        IF NOT EXISTS (
            SELECT 1 FROM pg_policies
            WHERE tablename = tbl AND policyname = 'user_update_own'
        ) THEN
            EXECUTE format(
                'CREATE POLICY user_update_own ON public.%I FOR UPDATE USING (user_id IN %s) WITH CHECK (user_id IN %s)',
                tbl, user_id_subquery, user_id_subquery
            );
        END IF;

        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = tbl AND column_name = 'deleted_at'
        ) THEN
            IF NOT EXISTS (
                SELECT 1 FROM pg_policies
                WHERE tablename = tbl AND policyname = 'user_no_hard_delete'
            ) THEN
                EXECUTE format(
                    'CREATE POLICY user_no_hard_delete ON public.%I FOR DELETE USING (false)',
                    tbl
                );
            END IF;
        ELSE
            IF NOT EXISTS (
                SELECT 1 FROM pg_policies
                WHERE tablename = tbl AND policyname = 'user_delete_own'
            ) THEN
                EXECUTE format(
                    'CREATE POLICY user_delete_own ON public.%I FOR DELETE USING (user_id IN %s)',
                    tbl, user_id_subquery
                );
            END IF;
        END IF;
    END LOOP;
END;
$$;

-- 3. push_devices: replace blanket policy
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'push_devices' AND policyname = 'push_devices_user_isolation') THEN
        DROP POLICY push_devices_user_isolation ON public.push_devices;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'push_devices' AND policyname = 'push_devices_select_own') THEN
        CREATE POLICY push_devices_select_own ON public.push_devices
            FOR SELECT USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'push_devices' AND policyname = 'push_devices_insert_own') THEN
        CREATE POLICY push_devices_insert_own ON public.push_devices
            FOR INSERT WITH CHECK (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'push_devices' AND policyname = 'push_devices_update_own') THEN
        CREATE POLICY push_devices_update_own ON public.push_devices
            FOR UPDATE USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()))
                        WITH CHECK (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'push_devices' AND policyname = 'push_devices_delete_own') THEN
        CREATE POLICY push_devices_delete_own ON public.push_devices
            FOR DELETE USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
END;
$$;

-- 4. export_artifacts: replace blanket policy
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'export_artifacts' AND policyname = 'export_artifacts_user_isolation') THEN
        DROP POLICY export_artifacts_user_isolation ON public.export_artifacts;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'export_artifacts' AND policyname = 'export_artifacts_select_own') THEN
        CREATE POLICY export_artifacts_select_own ON public.export_artifacts
            FOR SELECT USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'export_artifacts' AND policyname = 'export_artifacts_insert_own') THEN
        CREATE POLICY export_artifacts_insert_own ON public.export_artifacts
            FOR INSERT WITH CHECK (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'export_artifacts' AND policyname = 'export_artifacts_update_own') THEN
        CREATE POLICY export_artifacts_update_own ON public.export_artifacts
            FOR UPDATE USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()))
                        WITH CHECK (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'export_artifacts' AND policyname = 'export_artifacts_no_delete') THEN
        CREATE POLICY export_artifacts_no_delete ON public.export_artifacts
            FOR DELETE USING (false);
    END IF;
END;
$$;

-- 5. account_deletion_jobs: replace blanket policy
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'account_deletion_jobs' AND policyname = 'account_deletion_jobs_user_access') THEN
        DROP POLICY account_deletion_jobs_user_access ON public.account_deletion_jobs;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'account_deletion_jobs' AND policyname = 'adj_select_own') THEN
        CREATE POLICY adj_select_own ON public.account_deletion_jobs
            FOR SELECT USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'account_deletion_jobs' AND policyname = 'adj_insert_own') THEN
        CREATE POLICY adj_insert_own ON public.account_deletion_jobs
            FOR INSERT WITH CHECK (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'account_deletion_jobs' AND policyname = 'adj_no_update') THEN
        CREATE POLICY adj_no_update ON public.account_deletion_jobs
            FOR UPDATE USING (false) WITH CHECK (false);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'account_deletion_jobs' AND policyname = 'adj_no_delete') THEN
        CREATE POLICY adj_no_delete ON public.account_deletion_jobs
            FOR DELETE USING (false);
    END IF;
END;
$$;


-- ============================================================
-- [018] Soft-delete hard-purge cron
-- ============================================================

CREATE OR REPLACE FUNCTION public.purge_soft_deleted_rows(
    p_retention_days INTEGER DEFAULT 30,
    p_batch_limit INTEGER DEFAULT 5000
)
RETURNS TABLE(table_name TEXT, rows_deleted BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    tbl TEXT;
    cnt BIGINT;
    cutoff TIMESTAMPTZ := NOW() - (p_retention_days || ' days')::INTERVAL;
BEGIN
    FOR tbl IN
        SELECT DISTINCT c.table_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND c.column_name = 'deleted_at'
          AND t.table_type = 'BASE TABLE'
          AND c.table_name NOT IN (
              'deletion_audit_log',
              'deletion_failures',
              'consent_records',
              'service_role_audit_log',
              'account_deletion_jobs'
          )
        ORDER BY c.table_name
    LOOP
        EXECUTE format(
            'WITH purge_batch AS (
                SELECT ctid
                FROM public.%I
                WHERE deleted_at IS NOT NULL
                  AND deleted_at < $1
                LIMIT $2
            )
            DELETE FROM public.%I
            WHERE ctid IN (SELECT ctid FROM purge_batch)',
            tbl, tbl
        ) USING cutoff, p_batch_limit;

        GET DIAGNOSTICS cnt = ROW_COUNT;

        IF cnt > 0 THEN
            table_name := tbl;
            rows_deleted := cnt;
            RETURN NEXT;

            PERFORM log_service_role_invocation(
                'purge_soft_deleted_rows',
                NULL,
                jsonb_build_object('table', tbl, 'rows_deleted', cnt, 'retention_days', p_retention_days),
                'ok'
            );
        END IF;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.purge_soft_deleted_rows(INTEGER, INTEGER) TO service_role;

DO $$
DECLARE
    v_jobid BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid
          INTO v_jobid
          FROM cron.job
         WHERE jobname = 'purge-soft-deleted-rows'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        PERFORM cron.schedule(
            'purge-soft-deleted-rows',
            '0 3 * * *',
            $cron$SELECT * FROM public.purge_soft_deleted_rows(30, 5000);$cron$
        );
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        -- pg_cron can be unavailable in local/dev environments.
        NULL;
END;
$$;


-- ============================================================
-- [019] Feature flags / A/B testing infrastructure
-- ============================================================

CREATE TABLE IF NOT EXISTS public.feature_flags (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key    TEXT NOT NULL UNIQUE,
    description TEXT,
    enabled     BOOLEAN,
    rollout_pct SMALLINT CHECK (rollout_pct BETWEEN 0 AND 100),
    targeting   JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_feature_flags_key
    ON public.feature_flags (flag_key);

DROP TRIGGER IF EXISTS set_feature_flags_updated_at ON public.feature_flags;
CREATE TRIGGER set_feature_flags_updated_at
    BEFORE UPDATE ON public.feature_flags
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS public.ab_tests (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_key    TEXT NOT NULL UNIQUE,
    description TEXT,
    variants    TEXT[] NOT NULL DEFAULT ARRAY['control', 'variant'],
    weights     SMALLINT[] NOT NULL DEFAULT ARRAY[50, 50],
    flag_id     UUID REFERENCES feature_flags(id) ON DELETE SET NULL,
    status      TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'running', 'paused', 'completed')),
    started_at  TIMESTAMPTZ,
    ended_at    TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TRIGGER IF EXISTS set_ab_tests_updated_at ON public.ab_tests;
CREATE TRIGGER set_ab_tests_updated_at
    BEFORE UPDATE ON public.ab_tests
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE IF NOT EXISTS public.ab_test_assignments (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    test_id     UUID NOT NULL REFERENCES ab_tests(id) ON DELETE CASCADE,
    variant     TEXT NOT NULL,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, test_id)
);

CREATE INDEX IF NOT EXISTS idx_ab_assignments_user
    ON public.ab_test_assignments (user_id);

CREATE INDEX IF NOT EXISTS idx_ab_assignments_test
    ON public.ab_test_assignments (test_id, variant);

CREATE TABLE IF NOT EXISTS public.user_feature_overrides (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    flag_id     UUID NOT NULL REFERENCES feature_flags(id) ON DELETE CASCADE,
    enabled     BOOLEAN NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, flag_id)
);

CREATE INDEX IF NOT EXISTS idx_user_feature_overrides_user
    ON public.user_feature_overrides (user_id);

ALTER TABLE public.feature_flags ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ab_tests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ab_test_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_feature_overrides ENABLE ROW LEVEL SECURITY;

CREATE POLICY feature_flags_read ON public.feature_flags
    FOR SELECT USING (true);
CREATE POLICY feature_flags_no_write ON public.feature_flags
    FOR INSERT WITH CHECK (false);
CREATE POLICY feature_flags_no_update ON public.feature_flags
    FOR UPDATE USING (false) WITH CHECK (false);
CREATE POLICY feature_flags_no_delete ON public.feature_flags
    FOR DELETE USING (false);

CREATE POLICY ab_tests_read ON public.ab_tests
    FOR SELECT USING (true);
CREATE POLICY ab_tests_no_write ON public.ab_tests
    FOR INSERT WITH CHECK (false);
CREATE POLICY ab_tests_no_update ON public.ab_tests
    FOR UPDATE USING (false) WITH CHECK (false);
CREATE POLICY ab_tests_no_delete ON public.ab_tests
    FOR DELETE USING (false);

CREATE POLICY ab_assignments_select ON public.ab_test_assignments
    FOR SELECT USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
CREATE POLICY ab_assignments_no_modify ON public.ab_test_assignments
    FOR INSERT WITH CHECK (false);
CREATE POLICY ab_assignments_no_update ON public.ab_test_assignments
    FOR UPDATE USING (false) WITH CHECK (false);
CREATE POLICY ab_assignments_no_delete ON public.ab_test_assignments
    FOR DELETE USING (false);

CREATE POLICY user_overrides_select ON public.user_feature_overrides
    FOR SELECT USING (user_id IN (SELECT id FROM public.users WHERE auth_id = auth.uid()));
CREATE POLICY user_overrides_no_modify ON public.user_feature_overrides
    FOR INSERT WITH CHECK (false);
CREATE POLICY user_overrides_no_update ON public.user_feature_overrides
    FOR UPDATE USING (false) WITH CHECK (false);
CREATE POLICY user_overrides_no_delete ON public.user_feature_overrides
    FOR DELETE USING (false);

CREATE OR REPLACE FUNCTION public.resolve_feature_flags_for_user(p_user_id UUID)
RETURNS TABLE(flag_key TEXT, enabled BOOLEAN, variant TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    SELECT
        ff.flag_key,
        COALESCE(
            ufo.enabled,
            ff.enabled,
            (ff.rollout_pct IS NOT NULL
             AND abs(hashtext(p_user_id::TEXT || ff.flag_key)) % 100 < ff.rollout_pct)
        ) AS enabled,
        aba.variant
    FROM feature_flags ff
    LEFT JOIN user_feature_overrides ufo
        ON ufo.flag_id = ff.id AND ufo.user_id = p_user_id
    LEFT JOIN ab_tests abt
        ON abt.flag_id = ff.id AND abt.status = 'running'
    LEFT JOIN ab_test_assignments aba
        ON aba.test_id = abt.id AND aba.user_id = p_user_id
    WHERE ff.expires_at IS NULL OR ff.expires_at > NOW();
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_feature_flags_for_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_feature_flags_for_user(UUID) TO service_role;

CREATE OR REPLACE FUNCTION public.cleanup_expired_feature_flags()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM feature_flags WHERE expires_at IS NOT NULL AND expires_at < NOW();
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.cleanup_expired_feature_flags() TO service_role;


-- ============================================================
-- Missing updated_at triggers (found during verification)
-- ============================================================

CREATE TRIGGER set_rate_limit_windows_updated_at
    BEFORE UPDATE ON rate_limit_windows
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER set_export_jobs_updated_at
    BEFORE UPDATE ON export_jobs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER set_export_artifacts_updated_at
    BEFORE UPDATE ON export_artifacts
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- service_role_audit_log: intentionally NO updated_at trigger —
-- audit entries are write-once and should never be modified.
