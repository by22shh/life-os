# LIFE OS — HEALTH ECOSYSTEM EXPANSION

**Version:** 1.1  
**Date:** February 3, 2026  
**Purpose:** Comprehensive expansion of Life OS into a holistic health ecosystem covering Food, Workouts, and Supplements
**Detailed spec:** See `life_os_health_ecosystem_spec.md` for exhaustive functional and UX requirements.

> [!IMPORTANT]
> **Design Philosophy:** All modules are interconnected. Changes in one domain automatically trigger analysis and recommendations in others. This "ecosystem effect" is the core differentiator from competitors.

---

## EXECUTIVE SUMMARY

### Vision: The Interconnected Health OS

Life OS evolves from a recovery-focused app into a **complete health operating system** where every health factor is:
1. **Tracked** — with minimal friction (AI-powered input)
2. **Analyzed** — in context of all other factors
3. **Optimized** — through personalized, science-based recommendations
4. **Validated** — through N-of-1 experiments and biomarker tracking

### The Ecosystem Effect

```
┌─────────────────────────────────────────────────────────────────┐
│                    LIFE OS HEALTH ECOSYSTEM                     │
│                                                                 │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐ │
│   │  SLEEP   │◄──►│ RECOVERY │◄──►│NUTRITION │◄──►│ WORKOUT  │ │
│   │  & HRV   │    │  SCORE   │    │  & FOOD  │    │  & LOAD  │ │
│   └────┬─────┘    └────┬─────┘    └────┬─────┘    └────┬─────┘ │
│        │               │               │               │        │
│        └───────────────┼───────────────┼───────────────┘        │
│                        │               │                        │
│                   ┌────▼───────────────▼────┐                   │
│                   │   SUPPLEMENTS & BADS    │                   │
│                   │   + BLOOD BIOMARKERS    │                   │
│                   └────────────┬────────────┘                   │
│                                │                                │
│                   ┌────────────▼────────────┐                   │
│                   │ AI BRAIN (OpenRouter     │                   │
│                   │   openai/gpt-4o)        │                   │
│                   │  • Pattern Detection    │                   │
│                   │  • Cross-Domain Analysis│                   │
│                   │  • Personalized Recs    │                   │
│                   └─────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────┘
```

### Competitive Advantages Over Existing Apps

| Feature | FatSecret / MFP | Hevy / Strong | InsideTracker | **Life OS** |
|---------|-----------------|---------------|---------------|-------------|
| AI Food Recognition | ✓ Basic | ✗ | ✗ | ✓✓ Context-aware |
| Macro Tracking | ✓ | ✗ | ✗ | ✓✓ + Recovery-adjusted |
| Workout Logging | ✗ | ✓ | ✗ | ✓✓ + Auto-periodization |
| Training Load (ACWR) | ✗ | ✗ | ✗ | ✓ Scientific |
| Supplement Tracking | ✗ | ✗ | Limited | ✓✓ + Timing optimization |
| Blood Test Analysis | ✗ | ✗ | ✓ | ✓✓ + Photo OCR |
| Cross-Domain AI | ✗ | ✗ | ✗ | ✓✓ Unique |
| N-of-1 Experiments | ✗ | ✗ | ✗ | ✓ |
| Recovery Integration | ✗ | ✗ | Limited | ✓✓ Core feature |

---

## MODULE 1: ADVANCED NUTRITION TRACKING

### 1.1 Overview

Building on existing food logging, this expansion creates a **FatSecret Pro** experience with AI superiority.

### 1.2 AI-Powered Food Recognition (Enhanced)

#### Multi-Modal Input
```yaml
INPUT_METHODS:
  photo_single:
    description: "Snap photo of meal"
    ai_model: "openai/gpt-4o (via OpenRouter Edge Function)"
    latency_target: "p95 < 5 seconds"
    accuracy_target: "90%+ common foods"
    
  photo_batch:
    description: "Photo of meal prep container"
    calculates: "per-portion macros"
    requires: "total weight input"
    
  voice:
    description: "Just tell what you ate"
    example: "I had a chicken salad with olive oil dressing"
    ai_model: "openai/whisper-1 + openai/gpt-4o (via OpenRouter Edge Functions)"
    
  barcode:
    description: "Scan packaged foods"
    database: "OpenFoodFacts + custom verified"
    fallback: "AI estimation from package photo"
    
  quick_add:
    description: "Favorites, recents, meal templates"
    ml_powered: true
    learns_from: "user patterns"
```

#### Context-Aware Analysis
```yaml
CONTEXT_FACTORS:
  timing:
    - pre_workout (within 2h before)
    - post_workout (within 2h after)
    - breakfast/lunch/dinner/snack
    - late_night (after 21:00)
    
  location:
    - home (trust visual cues)
    - restaurant (hidden-calorie model by cuisine + dish type)
    - party (higher uncertainty; adjust confidence + hidden calories by variance model)
    
  recovery_state:
    - critical (0-24%): suggest anti-inflammatory
    - caution (25-49%): extra protein focus
    - ready (50-74%): balanced performance nutrition
    - optimal (75-100%): performance nutrition
    
  training_day:
    - rest_day: maintenance calories
    - light_training: training_adjustment_kcal (see formula below)
    - heavy_training: training_adjustment_kcal (see formula below)
    - competition: specific protocols
```

### 1.3 Advanced Nutritional Tracking

#### Micronutrient Dashboard (Like Cronometer)
```yaml
TRACKED_NUTRIENTS:
  macros:
    - calories, protein, fat, carbs, fiber, sugar
    - net_carbs (for keto users)
    - saturated_fat, trans_fat
    
  vitamins:
    - A, C, D, E, K
    - B1, B2, B3, B5, B6, B7, B9, B12
    
  minerals:
    - calcium, iron, magnesium, zinc
    - potassium, sodium, phosphorus
    - selenium, copper, manganese
    
  special:
    - omega_3, omega_6, omega_ratio
    - cholesterol
    - caffeine (tracked separately for sleep impact)
    - alcohol (recovery impact calculation)
```

> **Data source:** Micronutrient data is sourced from Open Food Facts `nutriments` object
> where available. Coverage varies by product (~40% of CIS products have micronutrient data).
> For products without micronutrient data, the app shows "Micronutrient data unavailable"
> rather than zeros. V3+ will add manual micronutrient entry and supplement-derived values.

**Micronutrient Data Pipeline (V3+):**
1. **Primary:** Open Food Facts `nutriments` (barcode match → canonical nutrient map).
2. **Secondary:** USDA FoodData Central (name + brand match when barcode missing).
3. **Tertiary:** Label OCR (user scans nutrition label → `lifeos_label_ocr` item with micros).
4. **Overrides:** Manual micronutrient edits are stored as user overrides.

**Storage (V3+ schema addition):**
- Add `micronutrients_json` to `food_catalog_items` (canonical per‑100g micros).
- Denormalize to `food_logs.micronutrients_json` at log time (snapshot for history).
- Missing values stay `null` (never zero‑filled).

#### Personalized Targets (Not Generic)
```typescript
interface NutritionTargets {
  // Base from user profile
  bmr_kcal: number;
  tdee_kcal: number;
  
  // Adjusted daily based on:
  adjustments: {
    training_load: number;      // +/- based on planned workout
    recovery_state: number;     // +protein if recovering
    sleep_debt: number;         // +carbs if sleep deprived
    menstrual_phase?: string;   // Phase-specific adjustments
    goal_phase: string;         // cut/bulk/maintain
  };
  
  // Final daily targets
  targets: {
    calories: { min: number; target: number; max: number };
    protein_g: number;          // activity/goal-specific (e.g., 1.6-2.2g/kg strength, 1.2-1.6g/kg endurance)
    fat_g: number;              // 0.8-1.2g per kg
    carbs_g: number;            // Remainder
    fiber_g: number;            // 25-38g based on sex
  };
  
  // Meal timing windows
  eating_window: {
    first_meal: string;         // Based on chronotype
    last_meal: string;          // 3h before sleep target
    pre_workout: string;
    post_workout: string;
  };
}
```

### 1.4 Meal Planning & Recipe Analysis

#### AI Meal Planner
```yaml
MEAL_PLANNER_FEATURES:
  daily_suggestions:
    - Based on remaining macros
    - Considers what's in your fridge (manual input)
    - Respects dietary preferences
    - Optimizes for variety
    
  weekly_planning:
    - Batch cooking recommendations
    - Grocery list generation
    - Prep time estimation
    - Aligned with training schedule
    
  recipe_analysis:
    - Photo of recipe or URL input
    - Complete macro breakdown
    - Portion scaling
    - Healthier substitution suggestions
```

### 1.5 Integration with Ecosystem

```yaml
NUTRITION_ECOSYSTEM_LINKS:
  recovery_impact:
    - Low protein → recovery warning
    - High alcohol → sleep quality alert
    - Caffeine timing → sleep prediction
    - Inflammatory foods → HRV impact estimation
    
  workout_sync:
    - Pre-workout nutrition suggestions
    - Post-workout recovery meals
    - Training day vs rest day calories
    - Glycogen replenishment tracking
    
  supplements:
    - "You're low on Vitamin D in food → supplement reminder"
    - "High iron foods today → skip iron supplement"
    - Nutrient interaction warnings
    
  health_measurements:
    - Correlate cholesterol with fat intake
    - Iron deficiency → iron-rich food suggestions
    - B12 tracking for vegans
```

---

## MODULE 2: INTELLIGENT WORKOUT TRACKING

### 2.1 Overview

Create the most intelligent workout tracking system by combining:
- **Hevy's** clean UX and social features
- **TrainHeroic's** periodization science
- **Strong's** simplicity
- **Life OS's** recovery integration (unique advantage)

### 2.2 Workout Logging

#### Exercise Library
```yaml
EXERCISE_DATABASE:
  total_exercises: 2000+
  categories:
    - strength (compound, isolation)
    - cardio (steady, HIIT, sport-specific)
    - flexibility (yoga, stretching)
    - functional (kettlebell, bodyweight)
    
  per_exercise:
    - video_demonstration: true
    - muscles_targeted: [primary, secondary]
    - equipment_required: []
    - difficulty_level: beginner|intermediate|advanced
    - alternatives: []  # For when equipment unavailable
    
  custom_exercises:
    - user_created: unlimited
    - ai_form_analysis: for video uploads
```

#### Workout Session Tracking
```typescript
interface WorkoutSession {
  id: string;
  started_at: Date;
  ended_at: Date;
  
  // Pre-workout context
  pre_workout_recovery: number;
  pre_workout_energy: 1-5;
  pre_workout_motivation: 1-5;
  
  exercises: Exercise[];
  
  // Each exercise
  interface Exercise {
    exercise_id: string;
    sets: Set[];
    rest_between_sets: number[];
    total_volume: number;  // weight × reps
    
    interface Set {
      weight: number;
      reps: number;
      rpe?: number;        // Rate of Perceived Exertion
      is_warmup: boolean;
      is_failure: boolean;
      is_dropset: boolean;
      tempo?: string;      // "3-1-2-1"
    }
  }
  
  // Session summary
  total_volume: number;
  total_sets: number;
  muscles_worked: string[];
  estimated_calories: number;
  trimp_score: number;
  
  // Post-workout
  post_workout_feeling: 1-5;
  notes: string;
}
```

### 2.3 AI-Powered Training Plan Generation

#### Personalized Plan Creation
```yaml
PLAN_GENERATION_INPUTS:
  user_profile:
    - training_experience: beginner|intermediate|advanced|elite
    - available_days: [1-7]
    - session_duration: minutes
    - equipment_access: home|gym|both
    - injuries: []
    - preferences: []
    
  current_state:
    - recovery_score: from Life OS
    - training_load_acwr: current ratio
    - sleep_quality_7d: average
    - nutrition_adherence: percentage
    
  goals:
    - primary: strength|hypertrophy|endurance|weight_loss|sport_specific
    - secondary: []
    - target_timeline: weeks
    - specific_targets: ["squat 100kg", "run 5K in 25min"]
    
PLAN_GENERATION_OUTPUT:
  mesocycle:
    duration: 4-8 weeks
    phases: [accumulation, intensification, realization, deload]
    
  weekly_structure:
    - day_1: "Push (Chest/Shoulders/Triceps)"
    - day_2: "Pull (Back/Biceps)"
    - day_3: "Active Recovery / Cardio"
    - day_4: "Legs"
    - day_5: "Upper Body"
    - day_6: "Conditioning"
    - day_7: "Rest"
    
  progressive_overload:
    method: "linear|undulating|block"
    weekly_progression: "2.5-5% volume increase"
    deload_frequency: "every 4th week"
```

#### Dynamic Plan Adjustment
```yaml
AUTO_ADJUSTMENT_TRIGGERS:
  recovery_low:
    condition: "recovery_score < 50"
    action: "Reduce volume by 30%, suggest active recovery"
    
  recovery_critical:
    condition: "recovery_score < 25"
    action: "Replace workout with mobility/stretching"
    
  acwr_high:
    condition: "acwr > 1.5"
    action: "Reduce intensity, add recovery exercises"
    
  sleep_debt:
    condition: "sleep_debt > 5 hours"
    action: "Shorter session, higher rest periods"
    
  missed_workouts:
    condition: "2+ consecutive missed"
    action: "Adjust weekly plan, don't try to 'catch up'"
    
  exceeded_performance:
    condition: "All sets completed at RPE < 7"
    action: "Suggest weight increase for next session"
```

### 2.4 Training Load Management (Scientific)

#### ACWR Implementation (Enhanced from existing)
```yaml
TRAINING_LOAD_METRICS:
  daily:
    - session_rpe: user-reported
    - duration_minutes: tracked
    - daily_trimp: calculated
    - training_stress_score: if power/HR available
    
  rolling:
    - acute_load_7d: EWMA calculation
    - chronic_load_28d: EWMA calculation
    - acwr: acute/chronic ratio
    - monotony: within-week variance
    - strain: monotony × weekly load
    
  zones:
    undertraining:
      range: "acwr < 0.8"
      message: "You can safely increase training load"
      
    optimal:
      range: "acwr 0.8-1.3"
      message: "Optimal training zone for adaptation"
      
    overreaching:
      range: "acwr 1.3-1.5"
      message: "High load - monitor recovery closely"
      
    injury_risk:
      range: "acwr > 1.5"
      message: "⚠️ Injury risk elevated - reduce load"
```

### 2.5 Integration with Ecosystem

```yaml
WORKOUT_ECOSYSTEM_LINKS:
  recovery:
    - Pre-workout: Show recovery score, adjust recommendation
    - Post-workout: Predict tomorrow's recovery impact
    - Weekly: Correlate training load with recovery trends
    
  nutrition:
    - Pre-workout meal timing and composition
    - Post-workout nutrition window alert
    - Training day calorie adjustment
    - Protein timing for muscle synthesis
    
  supplements:
    - Creatine timing around workouts
    - Pre-workout caffeine optimization
    - Post-workout recovery stack
    - Beta-alanine for specific training types
    
  sleep:
    - Evening workout impact on sleep
    - Recommend workout timing based on chronotype
    - Sleep need increase after heavy training
```

---

## MODULE 3: SUPPLEMENTS & BIOMARKERS

### 3.1 Overview

Create the most comprehensive supplement management system with:
- **Smart tracking** with timing optimization
- **Blood test analysis** via photo OCR
- **AI recommendations** based on personal data
- **Evidence grading** from scientific literature

> [!IMPORTANT]
> Life OS does not prescribe supplement dosages. It only tracks user-entered routines and provides timing guidance.

### 3.2 Supplement Stack Management

#### Supplement Database
```yaml
SUPPLEMENT_CATALOG:
  sources:
    - Examine.com research summaries
    - PubMed meta-analyses
    - User-submitted (verified)
    
  per_supplement:
    name: string
    category: vitamin|mineral|amino|herbal|nootropic|performance
    
    evidence:
      level: strong|moderate|weak|anecdotal
      studies_count: number
      key_benefits: []
      potential_risks: []
      
    timing:
      best_time: morning|with_food|before_bed|pre_workout|post_workout
      take_with_food: boolean
      interactions: []  # What to avoid combining
      synergies: []     # What enhances absorption
```

#### User Stack Configuration
```typescript
interface UserSupplementStack {
  supplements: UserSupplement[];
  
  interface UserSupplement {
    catalog_id: string;
    custom_name?: string;
    
    // User-entered dose (not prescribed by Life OS)
    dose: { amount: number; unit: string };
    frequency: 'daily' | 'twice_daily' | 'weekly' | 'as_needed';
    
    // Schedule
    scheduled_times: string[];  // ["08:00", "20:00"]
    with_meal: boolean;
    
    // Tracking
    started_at: Date;
    reason: string;  // Why taking this
    target_duration?: number;  // Weeks, if cycling
    
    // Effectiveness tracking
    perceived_benefit: 1-5 | null;
    side_effects: string[];
  }
  
  // AI-generated optimization
  optimization: {
    timing_conflicts: string[];
    synergy_suggestions: string[];
    redundancy_warnings: string[];  // "You're taking 3 forms of magnesium"
  };
}
```

### 3.3 Blood Test / Analysis Photo Recognition

#### Lab Report OCR
```yaml
BLOOD_TEST_FEATURES:
  input_methods:
    - photo: "Take picture of lab results"
    - pdf_upload: "Upload PDF report"
    - manual: "Enter values manually"
    
  ai_extraction:
    model: "openai/gpt-4o (via OpenRouter Edge Function)"
    confidence_threshold: 0.85
    # Note: The OCR confidence threshold (0.85) is intentionally stricter than the global AI confidence threshold (0.65)
    # because misread lab values could lead to incorrect medical interpretations. Values between 0.65 and 0.85 still
    # trigger mandatory user review.
    user_verification: required
    
  supported_markers:
    basic_panel:
      - glucose, HbA1c
      - total_cholesterol, LDL, HDL, triglycerides
      - creatinine, BUN, eGFR
      
    complete_blood:
      - RBC, WBC, hemoglobin, hematocrit
      - platelets, MCV, MCH, MCHC
      
    hormones:
      - testosterone, estradiol, progesterone
      - TSH, T3, T4
      - cortisol, DHEA
      
    vitamins_minerals:
      - vitamin_D, vitamin_B12, folate
      - iron, ferritin, TIBC
      - magnesium, zinc, selenium
      
    inflammation:
      - CRP, ESR
      - homocysteine
      - uric_acid
      
    liver:
      - ALT, AST, GGT
      - bilirubin, albumin
```

#### Historical Comparison
```typescript
interface BiomarkerHistory {
  marker: string;
  history: {
    date: Date;
    value: number;
    unit: string;
    reference_range: { min: number; max: number };
    status: 'low' | 'optimal' | 'high' | 'critical';
  }[];
  
  trend: 'improving' | 'stable' | 'declining';
  trend_significance: number;  // Statistical confidence
  
  // AI analysis
  interpretation: string;
  recommendations: string[];
  related_factors: {
    nutrition: string[];
    supplements: string[];
    lifestyle: string[];
  };
}
```

### 3.4 AI-Powered Supplement Recommendations

#### Recommendation Engine
```yaml
RECOMMENDATION_TRIGGERS:
  blood_test_deficiency:
    example: "Vitamin D at 18 ng/mL (low)"
    recommendation: "Discuss potential supplementation with a clinician; if you already take D3, keep timing consistent with meals"
    evidence: "Strong — clinical guidance exists, but dosing is medical advice"
    
  nutrition_gap:
    example: "Average omega-3 intake: 200mg (RDI: 1600mg)"
    recommendation: "Increase omega‑3 food sources; if you already take omega‑3, keep routine consistent"
    
  training_goal:
    example: "Goal: increase strength"
    recommendation: "If you already use creatine, maintain consistent timing; otherwise discuss with a clinician or follow product label"
    
  recovery_support:
    example: "Average recovery score: 58% (below baseline)"
    recommendation: "Prioritize sleep and recovery routines; if you use magnesium, keep timing consistent"
    
  user_request:
    example: "What should I take for better sleep?"
    response: "We can't recommend doses. If you already use supplements, we can help with timing; for new supplements, consult a clinician."
```

#### Evidence-Based Scoring
```yaml
EVIDENCE_LEVELS:
  A_STRONG:
    criteria: "Multiple RCTs, meta-analyses, consistent results"
    supplements: [vitamin_D, creatine, omega_3, protein]
    
  B_MODERATE:
    criteria: "Some RCTs, generally positive but mixed"
    supplements: [ashwagandha, magnesium, zinc, melatonin]
    
  C_WEAK:
    criteria: "Limited studies, promising but unconfirmed"
    supplements: [lion_mane, rhodiola, cordyceps]
    
  D_ANECDOTAL:
    criteria: "Mostly user reports, minimal research"
    supplements: [many_nootropics, herbal_blends]
    
UI_DISPLAY:
  - Show evidence level prominently
  - Link to research summaries
  - Never recommend D-level with high confidence
```

### 3.5 Integration with Ecosystem

```yaml
SUPPLEMENT_ECOSYSTEM_LINKS:
  nutrition:
    - "High iron meal today → skip iron supplement"
    - "Calcium-rich dinner → take magnesium separately"
    - "Vitamin C with iron for absorption"
    
  workouts:
    - "Pre-workout caffeine timing"
    - "Post-workout creatine with carbs"
    - "Beta-alanine on training days"
    
  recovery:
    - "Low recovery → emphasize recovery routines and timing consistency"
    - "High stress (HRV) → prioritize sleep, breathwork, and recovery routines"
    - "Poor sleep → optimize evening routine and supplement timing (if user-entered)"
    
  blood_tests:
    - "If supplementing under clinician guidance → retest as advised"
    - "Track supplement impact on markers"
    - "Adjust routines only with clinician guidance"
```

---

## MODULE 4: ECOSYSTEM INTELLIGENCE

### 4.1 Cross-Domain Analysis Engine

```yaml
BACKGROUND_ANALYSIS:
  trigger: "New data arrives in any domain"
  
  analysis_types:
    correlation_detection:
      - "Your HRV drops 15% on days after >2 drinks"
      - "Sleep quality +20% when dinner before 20:00"
      - "Recovery 12% higher on training rest days"
      
    pattern_recognition:
      - "Thursday fatigue pattern (Wednesday late nights)"
      - "Weekend nutrition slip pattern"
      - "Menstrual cycle impact on performance"
      
    anomaly_detection:
      - "Unusual RHR elevation → check temperature"
      - "Unexpected weight spike → hydration or sodium"
      - "Performance plateau → training variety needed"
      
    prediction:
      - "Based on tonight's meal, sleep prediction: affected"
      - "Training load this week → expect 72% recovery Monday"
      - "Current trajectory → goal reached in 6 weeks"
```

### 4.2 Integrated Dashboard

```yaml
HOME_SCREEN_SECTIONS:
  hero:
    content: "Recovery score + zone"
    secondary: "Today's key action"
    
  quick_actions:
    - log_food (camera icon)
    - log_workout (dumbbell icon)
    - log_supplement (pill icon)
    
  daily_summary:
    - calories: "1420/1850 kcal"
    - protein: "85/120g"
    - workout: "Completed: Push day"
    - supplements: "3/5 taken"
    
  insights:
    - contextual_tip: "Based on your training, add 20g protein at dinner"
    - ai_observation: "Your HRV correlates with sleep timing (r=0.72)"
    
  trends:
    - mini_chart: 7-day recovery trend
    - highlight: "↑ 8% vs last week"
```

### 4.3 Intelligent Notifications (Enhanced)

```yaml
CROSS_DOMAIN_NOTIFICATIONS:
  morning_brief:
    content: |
      Recovery: 73% ✓ Ready
      Today: Push workout recommended
      Nutrition focus: +30g protein (heavy training)
      Supplements: Take D3 with breakfast
      
  pre_workout:
    trigger: "1 hour before scheduled workout"
    content: "Workout in 1h. Consider: banana + coffee for optimal performance"
    
  post_workout:
    trigger: "Training session completed"
    content: "Great session! Recovery window: ~0.4 g/kg protein + ~1.0 g/kg carbs within 2h"
    
  meal_suggestion:
    trigger: "12:00 if no lunch logged"
    content: "You're 35g short on protein. Lunch idea: Grilled chicken salad"
    
  supplement_reminder:
    trigger: "Scheduled supplement time"
    content: "Time for Magnesium (take without calcium)"
    
  evening_prep:
    trigger: "3 hours before target bedtime"
    content: "Sleep prep starting. Last caffeine was 8h ago ✓. Magnesium at 21:00"
```

> All notifications are subject to the global hard cap (≤ 6/day) and quiet hours enforcement. See notification orchestration in `life_os_api_specification.md`.

---

## DATABASE SCHEMA ADDITIONS

### New Tables Required

```sql
-- Workout sessions
CREATE TABLE workout_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,
    
    -- Pre-workout state
    pre_recovery_score NUMERIC(5,2),
    pre_energy_level INTEGER CHECK (pre_energy_level BETWEEN 1 AND 5),
    
    -- Session data
    workout_type TEXT,  -- strength, cardio, flexibility, mixed
    planned_routine_id UUID,
    
    -- Calculated totals
    total_volume NUMERIC(10,2),
    total_sets INTEGER,
    total_reps INTEGER,
    duration_minutes INTEGER,
    estimated_calories INTEGER,
    trimp_score NUMERIC(8,2),
    
    -- Post-workout
    post_feeling INTEGER CHECK (post_feeling BETWEEN 1 AND 5),
    notes TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Individual exercises within workout
CREATE TABLE workout_exercises (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID REFERENCES workout_sessions(id) ON DELETE CASCADE,
    exercise_id UUID REFERENCES exercise_catalog(id),
    
    order_in_session INTEGER,
    
    -- Aggregates
    total_sets INTEGER,
    total_reps INTEGER,
    total_volume NUMERIC(10,2),
    max_weight NUMERIC(8,2),
    
    notes TEXT
);

-- Individual sets
CREATE TABLE workout_sets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    exercise_entry_id UUID REFERENCES workout_exercises(id) ON DELETE CASCADE,
    
    set_number INTEGER,
    weight NUMERIC(8,2),
    reps INTEGER,
    rpe INTEGER CHECK (rpe BETWEEN 1 AND 10),
    
    is_warmup BOOLEAN DEFAULT FALSE,
    is_failure BOOLEAN DEFAULT FALSE,
    is_dropset BOOLEAN DEFAULT FALSE,
    
    rest_after_seconds INTEGER
);

-- Training plans
CREATE TABLE training_plans (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    
    name TEXT NOT NULL,
    goal TEXT,  -- strength, hypertrophy, endurance, etc.
    
    -- Plan structure
    duration_weeks INTEGER,
    days_per_week INTEGER,
    current_week INTEGER DEFAULT 1,
    
    -- AI-generated content
    ai_generated BOOLEAN DEFAULT FALSE,
    plan_json JSONB,  -- Full plan structure
    
    -- Status
    status TEXT DEFAULT 'active',  -- active, completed, paused
    started_at DATE,
    ended_at DATE,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Blood biomarkers (canonical table name: health_measurements)
CREATE TABLE health_measurements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    
    test_date DATE NOT NULL,
    lab_name TEXT,
    
    -- Input method
    input_type TEXT,  -- photo, pdf, manual
    source_image_url TEXT,
    ai_confidence NUMERIC(3,2),
    user_verified BOOLEAN DEFAULT FALSE,
    
    -- All markers stored as JSONB for flexibility
    markers JSONB NOT NULL,
    -- Example: {"vitamin_d": {"value": 32, "unit": "ng/mL", "range": {"min": 30, "max": 100}}}
    
    -- AI analysis
    ai_summary TEXT,
    ai_recommendations JSONB,
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Daily nutrition targets (dynamic)
CREATE TABLE daily_nutrition_targets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    
    -- Base targets
    base_calories INTEGER,
    base_protein_g INTEGER,
    base_fat_g INTEGER,
    base_carbs_g INTEGER,
    
    -- Adjustments
    training_adjustment INTEGER,  -- +/- calories for training
    recovery_adjustment INTEGER,  -- +/- for recovery state
    
    -- Final targets
    final_calories INTEGER,
    final_protein_g INTEGER,
    final_fat_g INTEGER,
    final_carbs_g INTEGER,
    
    -- Rationale
    adjustment_reason TEXT,
    
    UNIQUE(user_id, date)
);
```

**Adjustment formulas (V1):**

```yaml
training_adjustment_kcal:
  # weight_kg MUST come from getEffectiveWeight() (Section 27 of recovery_algorithms)
  # NOT from static userProfile.weight_kg — see Dynamic Weight integration table
  effective_weight_kg = getEffectiveWeight(userId).weightKg
  weight_factor = clamp(effective_weight_kg / 70, 0.75, 1.25)
  if active_energy_kcal:
    adjustment_kcal = clamp(active_energy_kcal * 0.4 * weight_factor, 0, 600)
  else:
    adjustment_kcal = clamp(daily_trimp * 1.3 * weight_factor, 0, 600)

recovery_adjustment (continuous linear interpolation):
  # Smooth adjustment eliminates zone-boundary discontinuities
  recovery 0→50:
    protein_delta = lerp(recovery, 0, 50, +0.30, 0) g/kg
    carb_mult     = lerp(recovery, 0, 50, 0.85, 1.00)
    cal_mult      = lerp(recovery, 0, 50, 0.95, 1.00)
  recovery 50→100:
    protein_delta = 0
    carb_mult     = lerp(recovery, 50, 100, 1.00, 1.05)
    cal_mult      = lerp(recovery, 50, 100, 1.00, 1.05)

post_workout_window:
  protein_target_g = 0.4 * weight_kg (range 0.3–0.5)
  carb_target_g = 1.0 * weight_kg (range 0.8–1.2)
```

---

## VERIFICATION PLAN

### Automated Testing
Since this is documentation/planning work, no code tests required at this stage.

### Manual Verification
1. **User Review**: Present this expansion plan for approval
2. **Completeness Check**: Ensure all user requirements addressed:
   - ✓ Food tracking with AI recognition
   - ✓ Workout planning with AI generation
   - ✓ Supplements with blood test analysis
   - ✓ Cross-domain integration ("ecosystem effect")
3. **Competitor Comparison**: Verify feature parity or superiority

---

## IMPLEMENTATION PHASES

### Phase 1: Enhanced Nutrition (Weeks 1-3)
- Expand food logging with micronutrients
- Add meal planning suggestions
- Nutrition-recovery integration

### Phase 2: Workout Module (Weeks 4-6)
- Exercise database and logging
- Training plan generation
- ACWR enhancement

### Phase 3: Supplements & Biomarkers (Weeks 7-9)
- Blood test OCR
- Supplement optimization
- Evidence-based recommendations

### Phase 4: Ecosystem Integration (Weeks 10-12)
- Cross-domain AI analysis
- Unified dashboard
- Intelligent notifications

---

## CHANGELOG

### v1.0 (February 3, 2026)
- Initial comprehensive expansion plan
- Three new modules: Nutrition, Workouts, Supplements
- Ecosystem integration architecture
- Database schema additions
- Competitor analysis and differentiation strategy
