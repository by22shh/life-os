# LIFE OS — RECOVERY SCORE ALGORITHMS

**Version:** 3.5 (Canonical Pipeline + Cross-Domain Fixes + Zone Boundary + HRV Aggregation)
**Date:** February 9, 2026  
**Scientific Basis:** grounded in peer-reviewed literature and public health guidance (citations in “References & Citations”)  
**Validation:** validation plan includes benchmarking against user outcomes and (where available) comparisons with Oura/WHOOP/Apple Watch

> [!IMPORTANT]
> Life OS is a wellness tool, not a medical device. It does not diagnose, treat, cure, or prevent disease.

---

## SCIENTIFIC FOUNDATION

### Core Principle: Autonomic Nervous System Balance

Recovery is fundamentally about the balance between the **sympathetic** (fight-or-flight) and **parasympathetic** (rest-and-digest) branches of the autonomic nervous system. Our algorithms quantify this balance using validated biomarkers.

> **"Heart rate variability is the gold standard for measuring autonomic nervous system activity and is predictive of morbidity, mortality, and athletic performance."**  
> — Shaffer & Ginsberg, 2017 • [DOI: 10.3389/fpubh.2017.00258](https://doi.org/10.3389/fpubh.2017.00258)

### Key Research Papers

| Topic | Authors | Year | Journal | DOI/Citation |
|-------|---------|------|---------|--------------|
| HRV Metrics Overview | Shaffer & Ginsberg | 2017 | Front. Public Health | 10.3389/fpubh.2017.00258 |
| HRV in Athletes | Plews et al. | 2013 | Int J Sports Physiol | 10.1123/ijspp.8.6.688 |
| Sleep Stages | Walker, M. | 2017 | "Why We Sleep" | ISBN: 978-1501144318 |
| RHR & Overtraining | Buchheit, M. (2014a) | 2014 | Sports Med | 10.1007/s40279-014-0169-7 |
| HRV & Training Status | Buchheit, M. (2014b) | 2014 | Front Physiol | 10.3389/fphys.2014.00073 |
| Temperature & Illness | Smarr et al. | 2020 | Scientific Reports | 10.1038/s41598-020-78355-6 |
| Log-HRV Metrics (RMSSD/SDNN) | Esco & Flatt | 2014 | EJAP | 10.1007/s00421-014-2847-8 |
| Sleep & Memory | Diekelmann & Born | 2010 | Nature Reviews | 10.1038/nrn2762 |
| Circadian RHR Rhythms | Vandewalle et al. | 2007 | Sleep | 10.1093/sleep/30.11.1437 |
| Age-Related HRV Changes | Bonnemeier et al. | 2003 | Heart | 10.1136/heart.89.12.1387 |
| Wearable Sleep Accuracy | de Zambotti et al. | 2019 | Sleep | 10.1093/sleep/zsz098 |

---

## COMPOSITE RECOVERY SCORE FORMULA

### Evidence-Based Weight Distribution

```
Recovery Score = (HRV Score × 0.40) +
                 (Sleep Score × 0.30) +
                 (RHR Score × 0.15) +
                 (Temperature Score × 0.15)
```

If any component is missing (e.g., no temperature data), reweight the remaining components proportionally.

> **Note:** Weights standardized per PRD v7.13 and API specification.
> **Canonical implementation:** Section 13 (`calculateComprehensiveRecoveryScore`).  
> Any alternate formulas elsewhere are deprecated and must reference Section 13.

### Weight Justification

| Metric | Weight | Scientific Rationale |
|--------|--------|---------------------|
| **HRV** | 40% | Primary proxy for autonomic balance and day-to-day stress/recovery. We score HRV **relative to the user’s own baseline distribution**, not population norms, and prioritize trends/variability over single readings. |
| **Sleep** | 30% | Sleep supports cognitive and physiological recovery. We use duration/quality plus stage estimates, while avoiding overprecision to reduce orthosomnia risk. |
| **RHR** | 15% | Secondary readiness marker that can be influenced by hydration, caffeine, heat, and acute stress. Most useful as a **baseline-relative** signal when interpreted with HRV/sleep. Weight reduced from 20% to 15% to balance with temperature's complementary signal. |
| **Temperature** | 15% | Wrist temperature is treated as **deviation-from-baseline + trend** (not absolute "fever" thresholds). Useful as a context-dependent signal of illness/physiological stress; never diagnostic on its own. Weight raised from 10% to 15% based on Smarr et al. (2020) evidence for temperature as an early illness/stress indicator. |

---

## 1. HRV SCORE (40% Weight)

### The Science of Heart Rate Variability

Heart Rate Variability (HRV) measures the variation in time intervals between consecutive heartbeats (R-R intervals). This variability is controlled by the **vagus nerve**, the primary conduit of the parasympathetic nervous system.

**Why HRV Matters:**
- Higher HRV = Greater parasympathetic activation = Better recovery capacity
- Lower HRV = Sympathetic dominance = Stress, fatigue, or illness

### Selected Metric: log‑transformed HRV (HealthKit SDNN by default)

Life OS supports multiple HRV sources. In iOS/HealthKit, Apple Watch exposes HRV as **SDNN** (`HKQuantityTypeIdentifier.heartRateVariabilitySDNN`) in milliseconds. If another sensor provides **RR‑intervals** (or RMSSD directly), RMSSD can be computed — but the *scoring* pipeline stays consistent.

We compute a log-transformed HRV value:

1. Convert HRV (ms) → `ln(hrv_ms)`.
   - **SDNN → lnRMSSD approximation (HealthKit):** When the source is Apple Watch SDNN, use `ln(SDNN_ms × 1.1)` to approximate lnRMSSD. The `× 1.1` correction factor accounts for the empirical SDNN/RMSSD ratio in resting overnight measurements (Esco & Flatt, 2014). If the source provides RMSSD directly, use `ln(RMSSD_ms)` without correction.
   - **Noise rejection:** SDNN values < 5 ms are rejected as sensor noise.
2. Compare today to the user’s rolling baseline distribution
3. Score via z‑score (relative, not absolute)

**Why log-transform?**
1. **Stabilizes skew:** HRV values are typically right‑skewed; log transform reduces the impact of extremes.
2. **Improves comparability:** day‑to‑day changes are easier to interpret relative to baseline.
3. **Supports robust baselines:** CV and z‑score behave better on log scale.

```typescript
type HRVMetric = 'sdnn' | 'rmssd';

interface HRVReading {
  metric: HRVMetric;
  value_ms: number;
  measured_at: string; // ISO 8601
}

/**
 * Convert HRV (ms) to a log scale for baseline comparisons.
 * Works for both SDNN and RMSSD (if available).
 */
function lnHRV(valueMs: number): number {
  if (!Number.isFinite(valueMs) || valueMs <= 0) return NaN;
  return Math.log(valueMs);
}

interface HRVValidationResult {
  valid: boolean;
  error?: string;
  warningMessage?: string;
}

function validateHRVReading(reading: HRVReading): HRVValidationResult {
  if (!Number.isFinite(reading.value_ms) || reading.value_ms <= 0) {
    return { valid: false, error: 'HRV must be a positive number (ms).' };
  }

  // Conservative plausibility bounds for consumer wearables; tune via real validation.
  if (reading.value_ms < 5 || reading.value_ms > 300) {
    return { valid: true, warningMessage: 'HRV value is atypical; treat with lower confidence.' };
  }

  return { valid: true };
}

/**
 * Optional: RMSSD from RR-intervals (for sensors that provide them).
 * Apple Watch/HealthKit does NOT provide RR-interval arrays via standard APIs.
 */
function calculateRMSSD(rrIntervalsMs: number[]): number {
  if (rrIntervalsMs.length < 2) return NaN;
  let sumSquaredDiffs = 0;
  for (let i = 1; i < rrIntervalsMs.length; i++) {
    const diff = rrIntervalsMs[i] - rrIntervalsMs[i - 1];
    sumSquaredDiffs += diff * diff;
  }
  return Math.sqrt(sumSquaredDiffs / (rrIntervalsMs.length - 1));
}
```

### Baseline Establishment

Following Plews et al. (2013) protocol, we use a **7-day rolling baseline** (last 7 readings) with outlier exclusion:

```typescript
interface HRVBaseline {
  metric: HRVMetric;
  lnHRV_mean: number;        // Rolling average of ln(HRV)
  lnHRV_cv: number;          // Coefficient of Variation on ln-scale (%)
  hrv_mean_ms: number;       // Back-transformed mean for interpretability
  sample_count: number;
  confidence: number;        // 0-1 based on data completeness
}

/**
 * Baseline calculation using robust statistics
 * 
 * Reference: Plews, D.J. et al. (2013). "Monitoring training adaptation 
 * with heart rate measures: A methodological comparison"
 * DOI: 10.1123/ijspp.8.6.688
 */
function calculateHRVBaseline(readings: HRVReading[]): HRVBaseline {
  // Require minimum 5 days for valid baseline (Plews recommendation)
  if (readings.length < 5) {
    return createPendingBaseline(readings.length);
  }
  
  // Establish baseline per metric (sdnn vs rmssd). Do not mix metrics in one baseline.
  const metric: HRVMetric = readings[readings.length - 1]?.metric ?? 'sdnn';

  // Use last 7 readings (or days) for rolling baseline window
  const recent = readings.filter(r => r.metric === metric).slice(-7);
  const lnValues = recent
    .map(r => lnHRV(r.value_ms))
    .filter(v => Number.isFinite(v));
  
  // Remove outliers using IQR method (Tukey, 1977)
  const cleaned = removeOutliersIQR(lnValues);
  
  // Calculate statistics
  const mean = calculateMean(cleaned);
  const stdDev = calculateStdDev(cleaned, mean);
  const cv = (stdDev / mean) * 100;  // Coefficient of Variation as %
  
  return {
    metric,
    lnHRV_mean: mean,
    lnHRV_cv: cv,
    hrv_mean_ms: Math.exp(mean), // Convert back to ms for interpretability
    sample_count: cleaned.length,
    confidence: Math.min(1, cleaned.length / 7)
  };
}
```

### Coefficient of Variation (CV) — Critical Metric

The **log‑HRV CV** is as important as the mean itself:
- Higher mean + lower variability can indicate stable adaptation
- Rising variability (CV) can indicate accumulating fatigue, stress, or inconsistent sleep/hydration

```typescript
interface HRVTrainingState {
  state: 'OPTIMAL' | 'FUNCTIONAL_OVERREACHING' | 'NON_FUNCTIONAL_OVERREACHING' | 'MALADAPTATION';
  recommendation: string;
  /** Set when a non-training confounder overrides the classification */
  contextOverride?: 'ALCOHOL_CONFOUND' | 'ILLNESS_CONFOUND' | 'SLEEP_DEBT_CONFOUND' | 'JET_LAG_CONFOUND';
}

/**
 * Cross-domain context for training state classification.
 * Prevents misclassifying non-training stressors (alcohol, illness, jet lag)
 * as overreaching/maladaptation.
 */
interface TrainingStateContext {
  alcoholUnits48h: number;           // Total alcohol units in last 48 hours
  illnessRiskIndex: number;          // 0-100 from calculateIllnessRisk()
  sleepDebtHours: number;            // From calculateSleepDebt()
  travelTimeZoneShift: number | null;// Hours of timezone change in last 72h
  feelingIll: boolean;               // From morning wellness check
}

/**
 * Training state detection using CV patterns with cross-domain context filters
 * Based on: Plews (2014), Flatt & Esco (2016)
 *
 * v3.4 Enhancement: Before classifying HRV changes as training-related,
 * the algorithm now checks for confounding factors (alcohol, illness, sleep
 * debt, jet lag) that can produce identical HRV suppression patterns.
 * This prevents false overreaching alerts and provides domain-specific
 * recommendations instead.
 */
function assessTrainingState(
  baselineCV: number,
  currentCV: number,
  baselineMean: number,
  currentMean: number,
  context?: TrainingStateContext
): HRVTrainingState {
  const cvChange = ((currentCV - baselineCV) / baselineCV) * 100;
  const meanChange = ((currentMean - baselineMean) / baselineMean) * 100;

  // === Cross-domain context filters ===
  // Check if HRV disruption is likely caused by non-training factors
  if (context && (cvChange >= 10 || meanChange < -5)) {

    // Filter 1: Alcohol — can suppress HRV for 24-48h (Sagawa et al., 2011)
    if (context.alcoholUnits48h >= 3) {
      return {
        state: 'OPTIMAL', // Do not escalate training state
        recommendation: 'HRV disruption likely caused by recent alcohol consumption ' +
          `(${context.alcoholUnits48h} units in 48h). Allow 48-72h for HRV to normalize. ` +
          'Training readiness will be reassessed after recovery.',
        contextOverride: 'ALCOHOL_CONFOUND'
      };
    }

    // Filter 2: Illness — elevated illness risk explains HRV/RHR changes
    if (context.illnessRiskIndex >= 40 || context.feelingIll) {
      return {
        state: 'OPTIMAL', // Do not classify as overreaching
        recommendation: 'HRV changes appear illness-related rather than training-induced. ' +
          'Prioritize rest, hydration, and monitoring symptoms. ' +
          'Avoid training until illness risk returns to low.',
        contextOverride: 'ILLNESS_CONFOUND'
      };
    }

    // Filter 3: Sleep debt — severe sleep debt mimics overreaching patterns
    if (context.sleepDebtHours >= 15) {
      return {
        state: 'FUNCTIONAL_OVERREACHING', // Cap at functional, not escalate
        recommendation: `Significant sleep debt (${context.sleepDebtHours.toFixed(0)}h over 14 days) ` +
          'is the primary stressor. Prioritize sleep before reducing training. ' +
          '1-2 easy days + early bedtime recommended.',
        contextOverride: 'SLEEP_DEBT_CONFOUND'
      };
    }

    // Filter 4: Jet lag — timezone shift disrupts circadian HRV patterns
    if (context.travelTimeZoneShift && Math.abs(context.travelTimeZoneShift) >= 3) {
      return {
        state: 'FUNCTIONAL_OVERREACHING', // Cap at functional
        recommendation: `Recent timezone shift (${Math.abs(context.travelTimeZoneShift)}h) ` +
          'is affecting HRV patterns. Allow 1 day per timezone hour for adaptation. ' +
          'Light training is fine; avoid maximal efforts.',
        contextOverride: 'JET_LAG_CONFOUND'
      };
    }
  }

  // === Standard training state classification (no confounders detected) ===
  if (cvChange < 10 && meanChange >= 0) {
    return {
      state: 'OPTIMAL',
      recommendation: 'Training is well-tolerated. Maintain or increase load.'
    };
  }

  if (cvChange >= 10 && cvChange < 25 && meanChange >= -5) {
    return {
      state: 'FUNCTIONAL_OVERREACHING',
      recommendation: 'Some fatigue accumulation detected. 1-2 easy days recommended before next hard session.'
    };
  }

  if (cvChange >= 25 || meanChange < -10) {
    return {
      state: 'NON_FUNCTIONAL_OVERREACHING',
      recommendation: '⚠️ Significant fatigue. Reduce training volume by 40-60% for 3-7 days.'
    };
  }

  return {
    state: 'MALADAPTATION',
    recommendation: '🚨 Extended rest required. Consider medical evaluation if persists >7 days.'
  };
}
```

### Daily HRV Score Calculation

```typescript
interface HRVScore {
  score: number;               // 0-100
  lnHRV: number;               // Log-transformed value used for scoring
  percentileRank: number;      // vs personal history
  trendDirection: 'improving' | 'stable' | 'declining';
  trainingState: HRVTrainingState;
}

/**
 * Calculate HRV score using z-score methodology
 * 
 * This approach, recommended by Plews et al. (2013), compares today's
 * reading to your personal baseline distribution.
 * 
 * Formula: Score = 50 + (z-score × 15), clamped to 0-100
 * A z-score of 0 = baseline = 50 points
 * Each standard deviation = ±15 points
 */
function calculateHRVScore(
  current_lnHRV: number,
  baseline: HRVBaseline
): HRVScore {
  // Z-score calculation
  const stdDev = baseline.lnHRV_mean * (baseline.lnHRV_cv / 100);
  const zScore = (current_lnHRV - baseline.lnHRV_mean) / stdDev;
  
  // Convert to 0-100 scale
  // +2 SD → 80 points, -2 SD → 20 points
  const rawScore = 50 + (zScore * 15);
  const score = Math.max(0, Math.min(100, rawScore));
  
  // Calculate 7-day trend
  const trend = calculateTrend(/* last 7 days */);
  
  return {
    score: Math.round(score),
    lnHRV: current_lnHRV,
    percentileRank: calculatePercentile(current_lnHRV, /* historical data */),
    trendDirection: trend,
    trainingState: assessTrainingState(/* params */)
  };
}
```

### Measurement Guidelines (Based on Research)

Per Plews et al. (2013) and Buchheit (2014):

| Factor | Recommendation | Rationale |
|--------|---------------|-----------|
| **Timing** | Upon waking, before standing | Minimizes external influences |
| **Position** | Supine or seated (consistent) | Posture affects HRV significantly |
| **Duration** | 60 seconds minimum | Ultra-short <30s shows high error |
| **Breathing** | Natural, no pacing | Paced breathing artificially inflates HRV |
| **Frequency** | Daily for 7+ days | Single readings are unreliable |

> [!NOTE]
> These guidelines apply to **guided HRV measurements** (e.g., chest strap or apps that expose RR‑intervals).  
> Passive Apple Watch HRV (SDNN) readings should be treated as **trend signals**, not clinical-grade measurements.

---

## 2. SLEEP SCORE (30% Weight)

> **Sleep session selection:** The primary sleep session for a given date D is resolved by `life_os_healthkit_spec.md` §7.2 using a candidate window of D-1 18:00 → D 18:00 (local time). The longest `HKCategoryValueSleepAnalysis.asleepUnspecified` or staged session in this window is selected. This algorithm does not re-define the selection logic — it consumes the resolved sleep metrics.

### The Science of Sleep

Sleep is not a passive state but an active process of restoration, consolidation, and detoxification.

> **"Sleep is the Swiss army knife of health. When sleep is deficient, there is sickness and disease. When sleep is abundant, there is vitality and health."**
> — Dr. Matthew Walker, UC Berkeley

### Sleep Architecture (Evidence-Based Targets)

Based on Walker (2017), NIH guidelines, and polysomnography studies:

| Stage | Target % | Function | Research Basis |
|-------|----------|----------|----------------|
| **N1 (Light)** | 5% | Transition stage | Considered non-restorative |
| **N2 (Light)** | 45-55% | Memory consolidation, metabolic regulation | Sleep spindles protect memories |
| **N3 (Deep/SWS)** | 13-23% | Physical restoration, immune function, glymphatic clearance | Walker: "Deep sleep is the brain's laundry cycle" |
| **REM** | 20-25% | Emotional processing, creative problem-solving, memory integration | Diekelmann & Born (2010) |
| **Wake** | <5% | Normal micro-arousals | >5% indicates fragmentation |

### Glymphatic System: Why Deep Sleep Matters

A breakthrough discovery (Xie et al., 2013 • [DOI: 10.1126/science.1241224](https://doi.org/10.1126/science.1241224)):

> During deep sleep, brain cells shrink by ~60%, allowing cerebrospinal fluid to flush out metabolic waste, including **beta-amyloid** (linked to Alzheimer's). This process is 10x more active during sleep than waking.

```typescript
/**
 * Deep Sleep Adequacy Score
 * Based on age-adjusted targets from Walker (2017)
 */
function calculateDeepSleepAdequacy(
  deepSleepMinutes: number,
  totalSleepMinutes: number,
  age: number
): DeepSleepScore {
  const deepPercent = (deepSleepMinutes / totalSleepMinutes) * 100;
  
  // Age-adjusted targets (Walker, 2017)
  // Deep sleep naturally declines: ~20% at age 20 → ~5% at age 70
  const ageAdjustedTarget = calculateAgeTarget(age);
  
  // Score calculation
  const ratio = deepPercent / ageAdjustedTarget.optimal;
  let score: number;
  
  if (ratio >= 1.0) {
    score = 100;  // At or above target
  } else if (ratio >= 0.7) {
    score = 70 + (ratio - 0.7) * 100;  // 70-100 range
  } else if (ratio >= 0.4) {
    score = 40 + (ratio - 0.4) * 100;  // 40-70 range
  } else {
    score = ratio * 100;  // Below 40
  }
  
  return {
    score: Math.round(score),
    deepPercent,
    targetPercent: ageAdjustedTarget.optimal,
    adequacy: ratio >= 0.8 ? 'OPTIMAL' : ratio >= 0.6 ? 'ADEQUATE' : 'INSUFFICIENT',
    insight: generateDeepSleepInsight(ratio, age)
  };
}

/**
 * Age-adjusted deep sleep targets
 * Source: Ohayon et al. (2004), Walker (2017)
 */
function calculateAgeTarget(age: number): { minimum: number; optimal: number } {
  // Linear decline model based on meta-analyses
  if (age < 20) return { minimum: 15, optimal: 22 };
  if (age < 30) return { minimum: 13, optimal: 20 };
  if (age < 40) return { minimum: 12, optimal: 18 };
  if (age < 50) return { minimum: 10, optimal: 15 };
  if (age < 60) return { minimum: 8, optimal: 12 };
  if (age < 70) return { minimum: 5, optimal: 10 };
  return { minimum: 3, optimal: 8 };
}
```

### REM Sleep Scoring

```typescript
/**
 * REM Sleep Adequacy Score
 * 
 * REM is critical for:
 * - Emotional regulation (van der Helm & Walker, 2009)
 * - Memory consolidation (Diekelmann & Born, 2010)
 * - Creativity and problem-solving (Cai et al., 2009)
 */
function calculateREMScore(
  remMinutes: number,
  totalSleepMinutes: number,
  age: number
): REMScore {
  const remPercent = (remMinutes / totalSleepMinutes) * 100;
  
  // Age-adjusted REM targets (Ohayon et al., 2004)
  const ageTarget = getAgeAdjustedREMTarget(age);
  const optimalCenter = (ageTarget.min + ageTarget.max) / 2;
  const deviation = Math.abs(remPercent - optimalCenter);
  
  let score: number;
  if (remPercent >= ageTarget.min && remPercent <= ageTarget.max) {
    score = 100;  // Within optimal range for age
  } else if (deviation <= 5) {
    // Smooth, continuous falloff near the target band
    // 0% deviation -> 100, 5% deviation -> 85
    score = 100 - (deviation * 3);
  } else {
    // Continue downward without a discontinuity at 5%
    score = 85 - ((deviation - 5) * 4);
  }
  score = Math.max(0, score);
  
  return {
    score: Math.round(score),
    remPercent,
    targetRange: `${ageTarget.min}-${ageTarget.max}%`,
    ageAdjusted: true,
    adequacy: remPercent >= ageTarget.min * 0.9 && remPercent <= ageTarget.max * 1.1 
      ? 'OPTIMAL' 
      : remPercent >= ageTarget.min * 0.75 ? 'ADEQUATE' : 'LOW'
  };
}

/**
 * Age-adjusted REM sleep targets
 * Source: Ohayon et al. (2004) - Meta-analysis of 65 studies
 */
function getAgeAdjustedREMTarget(age: number): { min: number; max: number } {
  // REM percentage remains relatively stable but does decline slightly with age
  if (age < 20) return { min: 20, max: 25 };  // Teens/young adults
  if (age < 40) return { min: 18, max: 24 };  // Young adults
  if (age < 60) return { min: 17, max: 23 };  // Middle age
  if (age < 70) return { min: 15, max: 22 };  // Early seniors
  return { min: 13, max: 20 };                 // 70+
}
```

---

### Age-Adjusted Sleep Architecture Reference

> [!NOTE]
> **Based on Ohayon et al. (2004)** — "Meta-analysis of quantitative sleep parameters from childhood to old age in healthy individuals." Sleep, 27(7):1255-73.

| Age Group | Total Sleep (hours) | Deep Sleep % | REM Sleep % | Wake After Sleep Onset |
|-----------|---------------------|--------------|-------------|------------------------|
| **16-19** | 7.5 - 9.0 | 18-22% | 20-25% | < 5% |
| **20-29** | 7.0 - 8.5 | 15-20% | 18-24% | 5-7% |
| **30-39** | 7.0 - 8.0 | 13-18% | 17-23% | 6-9% |
| **40-49** | 6.5 - 7.5 | 10-15% | 17-22% | 8-12% |
| **50-59** | 6.5 - 7.5 | 8-12% | 16-21% | 10-15% |
| **60-69** | 6.0 - 7.0 | 5-10% | 15-20% | 12-18% |
| **70+** | 5.5 - 7.0 | 3-8% | 13-18% | 15-25% |

**Key Age-Related Changes:**

1. **Deep Sleep (Slow Wave):**
   - Declines ~2% per decade after age 20
   - By age 70, may have only 25-40% of young adult levels
   - This is physiologically normal, NOT pathological

2. **REM Sleep:**
   - More stable across lifespan
   - Slight decline in absolute minutes (fewer total hours)
   - Percentage remains 15-25% in most healthy adults

3. **Sleep Efficiency:**
   - Young adults: 90-95%
   - Elderly: 75-85%
   - More wake-after-sleep-onset is expected

**Algorithm Implications:**

```typescript
/**
 * Generate age-appropriate sleep insight
 * Avoids alarming older users about normal age-related changes
 */
function generateAgeAppropriateInsight(
  age: number,
  deepPercent: number,
  remPercent: number,
  sleepEfficiency: number
): string {
  const deepTarget = calculateAgeTarget(age);
  const remTarget = getAgeAdjustedREMTarget(age);
  
  // Check if values are within age-appropriate ranges
  const deepOK = deepPercent >= deepTarget.minimum;
  const remOK = remPercent >= remTarget.min;
  
  if (deepOK && remOK) {
    return age >= 50 
      ? "Your sleep architecture is excellent for your age. Keep up the good routine!"
      : "Great sleep quality! Your deep and REM sleep are both in the optimal range.";
  }
  
  if (!deepOK && age >= 60) {
    return "Your deep sleep is lower than optimal, but this is common after 60. " +
           "Focus on sleep hygiene: cool room, no screens, consistent bedtime.";
  }
  
  if (!remOK) {
    return "REM sleep is below target. Consider: reducing alcohol, managing stress, " +
           "and avoiding late-night eating.";
  }
  
  return "Sleep quality could be improved. Review your sleep hygiene habits.";
}
```

### Sleep Debt: Cumulative Deficit Tracking

> **"Sleep debt is like a credit card. You can borrow against it, but you will always pay interest."**
> — William Dement (Stanford Sleep Research)

```typescript
interface SleepDebt {
  debtHours: number;
  debtDays: number;
  severity: 'NONE' | 'MILD' | 'MODERATE' | 'SEVERE' | 'CRITICAL';
  recoveryTimeEstimate: string;
}

/**
 * Sleep Debt Calculation
 * 
 * Research shows sleep debt accumulates but cannot be fully "repaid"
 * in a single night. Recovery requires multiple nights of adequate sleep.
 * 
 * Reference: Kitamura et al. (2016) "Estimating individual optimal sleep duration"
 * DOI: 10.1038/srep35812
 */
function calculateSleepDebt(
  sleepLogs: SleepLog[],
  optimalDuration: number
): SleepDebt {
  // Calculate 14-day cumulative deficit
  const twoWeeks = sleepLogs.slice(-14);
  
  let totalDebt = 0;
  for (const log of twoWeeks) {
    const deficit = Math.max(0, optimalDuration - log.duration);
    totalDebt += deficit;
  }
  
  // Severity classification (based on Van Dongen et al., 2003)
  let severity: SleepDebt['severity'];
  let recoveryEstimate: string;
  
  if (totalDebt <= 5) {
    severity = 'NONE';
    recoveryEstimate = 'No recovery needed';
  } else if (totalDebt <= 10) {
    severity = 'MILD';
    recoveryEstimate = '1-2 nights of extra sleep';
  } else if (totalDebt <= 20) {
    severity = 'MODERATE';
    recoveryEstimate = '3-5 nights of extended sleep';
  } else if (totalDebt <= 35) {
    severity = 'SEVERE';
    recoveryEstimate = '1-2 weeks of consistent sleep';
  } else {
    severity = 'CRITICAL';
    recoveryEstimate = 'Extended recovery period required. Consider sleep hygiene intervention.';
  }
  
  return {
    debtHours: Math.round(totalDebt * 10) / 10,
    debtDays: twoWeeks.length,
    severity,
    recoveryTimeEstimate: recoveryEstimate
  };
}
```

### Sleep Data & Baseline Interfaces

```typescript
interface SleepData {
  totalMinutes: number;          // Total sleep time
  timeAsleepMinutes: number;     // Time actually asleep (for efficiency)
  timeInBedMinutes: number;      // Total time in bed (for efficiency)
  deepMinutes: number;           // N3 / Slow Wave Sleep minutes
  remMinutes: number;            // REM sleep minutes
  awakenings: number;            // Number of wake episodes
  wakeMinutes: number;           // Total wake-after-sleep-onset minutes
  efficiency: number;            // Pre-computed efficiency % (timeAsleep/timeInBed×100)
  sleepStart: Date | string;     // Sleep onset time
  sleepEnd: Date | string;       // Wake time
  sleepStartLocal?: string;      // Local timezone sleep start (ISO)
}

interface SleepBaseline {
  optimalDuration: number;       // Optimal sleep duration in HOURS
  averageDuration: number;       // Recent average in hours
  averageEfficiency: number;     // Recent average efficiency %
  averageDeepPercent: number;    // Recent average deep sleep %
  averageRemPercent: number;     // Recent average REM %
  daysOfData: number;            // Days used to compute baseline
  confidence: number;            // 0-1 based on data completeness
}

interface SleepLog {
  date: string;                  // YYYY-MM-DD
  duration: number;              // Total sleep in hours
  quality?: number;              // Optional quality rating
}
```

### Composite Sleep Score

```typescript
interface SleepScore {
  overall: number;           // 0-100
  components: {
    duration: number;        // Was sleep long enough?
    efficiency: number;      // % time asleep vs in bed
    deepSleep: number;       // Adequate N3?
    remSleep: number;        // Adequate REM?
    continuity: number;      // Few awakenings?
  };
  debtPenalty: number;       // Reduction from sleep debt
  insights: string[];
}

/**
 * Composite Sleep Score
 * 
 * Weighting based on relative importance for recovery
 * (literature synthesis from Walker, Oura research, WHOOP methodology)
 */
function calculateSleepScore(
  sleepData: SleepData,
  baseline: SleepBaseline,
  age: number,
  recentSleepLogs?: SleepLog[]
): SleepScore {
  // Component calculations
  const duration = calculateDurationScore(sleepData.totalMinutes / 60, baseline.optimalDuration);
  const efficiency = calculateEfficiencyScore(sleepData.timeAsleepMinutes, sleepData.timeInBedMinutes);
  const deep = calculateDeepSleepAdequacy(sleepData.deepMinutes, sleepData.totalMinutes, age);
  const rem = calculateREMScore(sleepData.remMinutes, sleepData.totalMinutes, age);
  const continuity = calculateContinuityScore(sleepData.awakenings, sleepData.totalMinutes);

  // Weighted composite
  // Deep and REM weighted higher based on restoration research
  const raw = (
    duration.score * 0.20 +
    efficiency.score * 0.15 +
    deep.score * 0.30 +      // Walker emphasizes deep sleep
    rem.score * 0.25 +       // REM critical for cognition
    continuity.score * 0.10
  );

  // Apply sleep debt penalty
  const debt = recentSleepLogs
    ? calculateSleepDebt(recentSleepLogs, baseline.optimalDuration)
    : null;
  const debtPenalty = debt ? calculateDebtPenalty(debt) : 0;
  
  const overall = Math.max(0, raw - debtPenalty);
  
  return {
    overall: Math.round(overall),
    components: {
      duration: duration.score,
      efficiency: efficiency.score,
      deepSleep: deep.score,
      remSleep: rem.score,
      continuity: continuity.score
    },
    debtPenalty,
    insights: generateSleepInsights(/* analysis data */)
  };
}
```

---

## 3. RESTING HEART RATE SCORE (15% Weight)

### Scientific Context

RHR is a secondary but valuable recovery indicator.

> **"While RHR shows moderate sensitivity for detecting overreaching, it is more variable than HRV and susceptible to confounders including hydration, caffeine, ambient temperature, and time of measurement."**
> — Buchheit, M. (2014) • [DOI: 10.1007/s40279-014-0169-7](https://doi.org/10.1007/s40279-014-0169-7)

### Key Finding: Elevated RHR as Illness Indicator

An elevated RHR relative to your baseline can sometimes precede illness or reflect accumulated stress. Interpret it alongside HRV, sleep, and symptoms.

```typescript
/**
 * RHR Score using relative comparison to baseline
 * 
 * Note: We use sleep-measured RHR (lowest nocturnal HR) for consistency,
 * as morning RHR upon waking varies with wake time and hydration.
 */
function calculateRHRScore(
  current_rhr: number,
  baseline: RHRBaseline
): RHRScore {
  // RHR works inversely: lower is better
  const deviation = current_rhr - baseline.mean;
  const deviationPercent = (deviation / baseline.mean) * 100;
  
  // Scoring:
  // -10% (lower) = excellent (100 points)
  // Baseline = normal (60 points) — note: not 50, as baseline is "normal"
  // +10% (higher) = concerning (20 points)
  // +15% or more = critical (0 points)
  
  let score: number;
  if (deviationPercent <= -10) {
    score = 100;
  } else if (deviationPercent <= 0) {
    score = 60 + (Math.abs(deviationPercent) * 4);  // 60-100
  } else if (deviationPercent <= 10) {
    score = 60 - (deviationPercent * 4);  // 60-20
  } else if (deviationPercent <= 15) {
    score = 20 - ((deviationPercent - 10) * 4);  // 20-0
  } else {
    score = 0;
  }
  
  return {
    score: Math.round(score),
    current: current_rhr,
    baseline: baseline.mean,
    deviation: Math.round(deviation),
    alertLevel: deviationPercent > 10 ? 'HIGH' : deviationPercent > 5 ? 'MODERATE' : 'NORMAL'
  };
}
```

---

## 4. BODY TEMPERATURE SCORE (15% Weight)

### Scientific Basis

Wrist skin temperature (WST) is a promising biomarker for early illness/physiological stress signals.

WST deviations during sleep can be informative, especially when elevation is sustained across multiple nights, but should be treated as **non-diagnostic**.

> Smarr et al. (2020) demonstrated feasibility of continuous fever monitoring using wearable devices.  
> — *Scientific Reports* • [DOI: 10.1038/s41598-020-78355-6](https://doi.org/10.1038/s41598-020-78355-6)

### Apple Watch Temperature Sensing

Apple Watch (supported models) provides **wrist temperature during sleep** as a **deviation from a personal baseline**.  
This is **not** a core body temperature measurement and must be interpreted as a trend signal.

```typescript
interface TemperatureAlert {
  type: 'ILLNESS_RISK' | 'HIGH_TEMPERATURE_DEVIATION';
  severity: 'low' | 'moderate' | 'high';
  message: string;
  actions: string[];
}

interface TemperatureScore {
  score: number;
  currentDeviation: number;      // °C from baseline
  trend: 'stable' | 'rising' | 'falling';
  alert: TemperatureAlert | null;
}

/**
 * Temperature Score Calculation
 * 
 * Wrist temperature is treated as deviation-from-baseline (°C) + trend.
 * Thresholds below are heuristics and MUST be calibrated on real data.
 */
function calculateTemperatureScore(
  currentDeviation: number,    // °C from baseline (Apple provides this)
  recentDeviations: number[]   // Last 7 nights
): TemperatureScore {
  const absDeviation = Math.abs(currentDeviation);
  
  // Scoring thresholds (heuristic; tune via validation)
  let score: number;
  if (absDeviation <= 0.2) {
    score = 100;  // Normal variation
  } else if (absDeviation <= 0.5) {
    score = 100 - ((absDeviation - 0.2) * 100);  // 100-70
  } else if (absDeviation <= 1.0) {
    score = 70 - ((absDeviation - 0.5) * 80);   // 70-30
  } else if (absDeviation <= 1.5) {
    score = 30 - ((absDeviation - 1.0) * 60);   // 30-0
  } else {
    score = 0;  // Significant deviation (non-diagnostic)
  }
  
  // Trend analysis
  const trend = analyzeTemperatureTrend(recentDeviations);
  
  // Alert generation
  const alert = generateTemperatureAlert(currentDeviation, trend);
  
  return {
    score: Math.round(score),
    currentDeviation,
    trend,
    alert
  };
}

function generateTemperatureAlert(
  deviation: number,
  trend: string
): TemperatureAlert | null {
  // Sustained elevation across multiple nights can be a useful early warning signal.
  if (deviation > 0.5 && trend === 'rising') {
    return {
      type: 'ILLNESS_RISK',
      severity: 'high',
      message: 'Your wrist temperature deviation has been elevated for multiple nights. This can happen with illness or high physiological stress.',
      actions: [
        'Reduce training intensity and prioritize recovery',
        'Prioritize sleep',
        'Increase hydration',
        'Monitor for symptoms; consider taking a thermometer measurement if you feel unwell',
        'Seek medical advice if symptoms are severe or persist'
      ]
    };
  }
  
  if (deviation >= 1.0) {
    return {
      type: 'HIGH_TEMPERATURE_DEVIATION',
      severity: 'high',
      message: 'Large sustained wrist temperature deviation detected. This may indicate illness or significant stress, but it is not diagnostic.',
      actions: [
        'Rest and avoid intense exercise',
        'Stay hydrated and prioritize sleep',
        'If you feel unwell, consider measuring your body temperature with a thermometer',
        'Seek medical care if you have severe symptoms or are concerned'
      ]
    };
  }
  
  return null;
}
```

### Menstrual Cycle Adjustment

For users tracking their menstrual cycle, temperature interpretation must account for the luteal phase rise:

```typescript
/**
 * Menstrual Cycle Temperature Adjustment
 * 
 * After ovulation (days ~14-28), progesterone causes a 0.3-0.5°C
 * rise in basal body temperature. This is normal physiology,
 * not illness.
 * 
 * Reference: Barron & Fehring (2005), "Basal body temperature assessment"
 */
function adjustTemperatureForCycle(
  deviation: number,
  cycleDay: number | null,
  cycleLength: number
): number {
  if (!cycleDay) return deviation;  // No cycle tracking
  
  // Luteal phase starts around day 14 (varies)
  const ovulationDay = Math.round(cycleLength * 0.48);
  
  if (cycleDay > ovulationDay) {
    // In luteal phase — subtract expected progesterone effect
    const lutealAdjustment = 0.3;  // Conservative estimate
    return deviation - lutealAdjustment;
  }
  
  return deviation;
}
```

---

## 5. RECOVERY ZONES

### Evidence-Based Zone Classification (v7.2 — Simplified 4-Zone Model)

> [!IMPORTANT]
> **v7.1 Update:** Simplified from 6 zones to 4 for instant recognition and reduced cognitive load.
> **Rationale:**
> 1. Traffic light metaphor is universal
> 2. Fewer categories = clearer action
> 3. Better accessibility for color-blind users (4 colors easier to distinguish)
> 4. Matches competitors (WHOOP/Oura use 3-4 zones)
> 5. Pro/Athlete micro-zones available as optional feature

```typescript
/**
 * Recovery Zones — 4-Zone Model (PRD v7.13)
 *
 * CRITICAL: All documents (API, algorithms, PRD) MUST use this model.
 * The 6-zone model is DEPRECATED.
 */
type RecoveryZone =
  | 'optimal'   // 75-100: Ready for anything
  | 'ready'     // 50-74:  Good to go
  | 'caution'   // 25-49:  Take it easy
  | 'critical'; // 0-24:   Rest required

/**
 * Optional Pro/Athlete Micro-Zones (within Optimal zone only)
 * Enabled via: Settings → Recovery → Show Micro-Zones
 * Default: OFF
 */
type OptionalMicroZone =
  | 'peak'    // 90-100: Maximum capacity — push hard today
  | 'strong'  // 80-89:  Very ready — high intensity OK
  | 'solid';  // 75-79:  Good — moderate-high intensity

interface ZoneMetadata {
  zone: RecoveryZone;
  microZone?: OptionalMicroZone;  // Only if score >= 75 and micro-zones enabled
  score: number;
  icon: string;       // Accessibility: always include icon
  label: string;      // Accessibility: always include text label
  colorToken: 'recoveryOptimal' | 'recoveryReady' | 'recoveryCaution' | 'recoveryCritical';
  trainingGuidance: string;
  nutritionGuidance: string;
  sleepGuidance: string;
}

function determineRecoveryZone(score: number, showMicroZones: boolean = false): ZoneMetadata {
  // OPTIMAL ZONE (75-100)
  if (score >= 75) {
    // Determine micro-zone if enabled
    let microZone: OptionalMicroZone | undefined;
    if (showMicroZones) {
      if (score >= 90) microZone = 'peak';
      else if (score >= 80) microZone = 'strong';
      else microZone = 'solid';
    }

	    return {
	      zone: 'optimal',
	      microZone,
	      score,
	      icon: '✓',
	      label: microZone ? `Optimal (${microZone})` : 'Optimal',
	      colorToken: 'recoveryOptimal',
	      trainingGuidance: score >= 90
	        ? 'Peak readiness. Ideal for competition, max-effort workouts, or skill acquisition. Your nervous system is primed for high performance.'
	        : score >= 80
	          ? 'Strong readiness. Good day for challenging workouts, speed work, or strength training.'
	          : 'Good readiness. Fine for moderate to high intensity. Great for consistent training.',
	      nutritionGuidance: 'Fuel for performance. Adequate carbs before intense sessions. Prioritize protein around workouts.',
	      sleepGuidance: 'Maintain your current sleep pattern. It\'s working well.'
	    };
	  }

  // READY ZONE (50-74)
  if (score >= 50) {
	    return {
	      zone: 'ready',
	      score,
	      icon: '↗',
	      label: 'Ready',
	      colorToken: 'recoveryReady',
	      trainingGuidance: 'Adequate readiness. Normal training appropriate. Avoid setting PRs or extremely intense sessions.',
	      nutritionGuidance: 'Focus on recovery-supporting foods (fiber, colorful plants, adequate protein). Include omega‑3‑rich foods if possible.',
	      sleepGuidance: 'There\'s room for improvement. Review your sleep environment and pre-bed routine.'
	    };
	  }
  
  // CAUTION ZONE (25-49)
  if (score >= 25) {
	    return {
	      zone: 'caution',
	      score,
	      icon: '⚠',
	      label: 'Caution',
	      colorToken: 'recoveryCaution',
	      trainingGuidance: 'Reduced capacity. Light activity only — walking, yoga, mobility work. Hard training will deepen fatigue.',
	      nutritionGuidance: 'Prioritize recovery foods: antioxidants, protein, and complex carbs. Avoid alcohol.',
	      sleepGuidance: 'Your body is asking for more rest. Consider going to bed 30-60 minutes earlier tonight.'
	    };
	  }

	  // CRITICAL ZONE (0-24)
	  return {
	    zone: 'critical',
	    score,
	    icon: '✕',
	    label: 'Critical',
	    colorToken: 'recoveryCritical',
	    trainingGuidance: 'Very low capacity. Prioritize rest and reduce additional stressors. If this persists for multiple days or you feel unwell, consider seeking medical advice.',
	    nutritionGuidance: 'Easy-to-digest, nutrient-dense foods and hydration. If you use electrolytes, follow label instructions. Avoid alcohol.',
	    sleepGuidance: 'Prioritize sleep and low stimulation today. If possible, aim for an earlier bedtime and protect a full night of sleep.'
	  };
	}

/**
 * Legacy Zone Migration Helper
 *
 * For migrating existing data from 6-zone to 4-zone model.
 * Use during database migration only.
 */
function migrateLegacyZone(legacyZone: string): RecoveryZone {
  const mapping: Record<string, RecoveryZone> = {
    'supercharged': 'optimal',
    'charged': 'optimal',
    'moderate': 'ready',
    'depleted': 'caution',
    'drained': 'caution',
    'emergency': 'critical'
  };
  return mapping[legacyZone] || 'ready';
}
```

---

## 6. CIRCADIAN RHYTHM NORMALIZATION

### Why Measurement Time Matters

HRV and RHR follow circadian rhythms. A measurement at 3 AM (during deep sleep) differs from 7 AM (after waking).

```typescript
/**
 * Circadian Adjustment for HRV Measurements
 * 
 * Research (Vandewalle et al., 2007) shows HRV peaks during
 * early morning sleep (3-5 AM) and is lowest in early afternoon.
 * 
 * Our normalization ensures measurements taken at different times
 * are comparable.
 */
function normalizeForCircadian(
  value: number,
  measurementHour: number,
  metric: 'HRV' | 'RHR'
): number {
  // Reference point: 4 AM (optimal measurement time during sleep)
  const referenceHour = 4;
  const hourDiff = Math.abs(measurementHour - referenceHour);
  
  // HRV adjustment factors (empirically derived)
  //
  // Complete 24-hour circadian curve based on:
  // - Vandewalle et al. (2007): HRV peaks during early morning sleep
  // - Bonnemeier et al. (2003): Circadian modulation of HRV in healthy subjects
  // - Huikuri et al. (1994): Diurnal HRV patterns — nadir at 12-14:00
  //
  // Factors > 1.0 mean HRV is typically lower → we divide to normalize UP
  // Factors < 1.0 mean HRV is typically higher → we divide to normalize DOWN
  // Reference point: 4 AM = 1.0 (optimal measurement during sleep)
  //
  const HRV_CIRCADIAN_CURVE: Record<number, number> = {
    // Night sleep period (elevated HRV due to parasympathetic dominance)
    0: 1.05,   // Midnight: slightly below 4 AM optimal
    1: 1.03,   // Deep sleep phase, HRV climbing
    2: 1.01,   // Approaching peak
    3: 1.00,   // 3-5 AM: optimal measurement window (peak parasympathetic)
    4: 1.00,   // Reference point
    5: 1.00,   // Still in optimal window

    // Morning transition (cortisol awakening response → HRV drops)
    6: 0.98,   // Post-waking: HRV starts declining
    7: 0.95,   // Cortisol peak, sympathetic activation
    8: 0.92,   // Morning activity
    9: 0.90,   // Active day beginning

    // Daytime (lowest HRV due to sympathetic dominance)
    10: 0.88,  // Mid-morning
    11: 0.86,  // Pre-lunch
    12: 0.85,  // NADIR - lowest HRV (Huikuri et al., 1994)
    13: 0.85,  // Post-lunch, still low
    14: 0.86,  // Slight recovery begins
    15: 0.87,  // Afternoon

    // Evening transition (parasympathetic reactivation)
    16: 0.88,  // Late afternoon
    17: 0.90,  // Evening approach
    18: 0.92,  // Dinner time
    19: 0.94,  // Early evening relaxation

    // Night preparation (HRV climbing toward sleep)
    20: 0.96,  // Evening wind-down
    21: 0.98,  // Pre-sleep preparation
    22: 1.00,  // Early sleep phase
    23: 1.02   // Transitioning to deep sleep
  };
  
  if (metric === 'HRV') {
    const factor = HRV_CIRCADIAN_CURVE[measurementHour] || 1.0;
    return value / factor;  // Normalize to 4 AM equivalent
  }
  
  // RHR works inversely
  // ... similar logic
  
  return value;
}
```

---

## 7. ILLNESS DETECTION ALGORITHM

### Multi-Metric Early Warning System

Combining multiple biomarkers can produce more reliable **early-warning signals** than any single metric.

```typescript
interface IllnessSignal {
  metric: 'HRV' | 'RHR' | 'Temperature' | 'Respiratory Rate';
  severity: 'low' | 'moderate' | 'high';
  message: string;
}

interface IllnessRisk {
  risk_index: number;        // 0-100 heuristic index (NOT a calibrated probability)
  level: 'low' | 'moderate' | 'high';
  confidence: number;        // 0-1 (signal strength + data quality)
  time_window: string;       // e.g., "next 24-48h"
  signals: IllnessSignal[];
  recommendation: string;
  limitations: string[];
}

/**
 * Early Illness Detection
 * 
 * Multi-signal early warning (non-diagnostic).
 *
 * Combines baseline-relative signals (HRV, RHR, wrist temperature deviation, optional respiratory rate).
 * Thresholds/weights are heuristics and MUST be calibrated on real user data before presenting them
 * as numeric "probabilities".
 */
function calculateIllnessRisk(
  hrvDeviationPercent: number,     // % below baseline
  rhrDeviationBpm: number,         // bpm above baseline
  wristTempDeviationC: number,     // °C deviation from personal baseline (wrist, not core temp)
  respiratoryRate: number | null,  // breaths/min if available
  trendDays: number          // How many days showing this pattern
): IllnessRisk {
  const signals: IllnessSignal[] = [];
  let riskScore = 0;
  
  // HRV suppression (strong signal)
  if (hrvDeviationPercent < -10) {
    riskScore += 25;
    signals.push({
      metric: 'HRV',
      severity: hrvDeviationPercent < -20 ? 'high' : 'moderate',
      message: `HRV is ${Math.abs(hrvDeviationPercent).toFixed(0)}% below your baseline`
    });
  }
  
  // RHR elevation (strong signal)
  if (rhrDeviationBpm > 5) {
    riskScore += 25;
    signals.push({
      metric: 'RHR',
      severity: rhrDeviationBpm > 10 ? 'high' : 'moderate',
      message: `RHR is ${rhrDeviationBpm} bpm above baseline`
    });
  }
  
  // Wrist temperature deviation (strong signal; not core body temperature)
  if (wristTempDeviationC > 0.3) {
    riskScore += 30;
    signals.push({
      metric: 'Temperature',
      severity: wristTempDeviationC > 0.7 ? 'high' : 'moderate',
      message: `Wrist temperature deviation is +${wristTempDeviationC.toFixed(1)}°C vs your baseline`
    });
  }
  
  // Respiratory rate (if available - Apple Watch data)
  // Weight = 30 (updated per P2-006; matches ILLNESS_DETECTION_WEIGHTS.RESPIRATORY_RATE)
  if (respiratoryRate && respiratoryRate > 17) {
    riskScore += 30;
    signals.push({
      metric: 'Respiratory Rate',
      severity: respiratoryRate > 20 ? 'high' : 'moderate',
      message: `Breathing rate elevated at ${respiratoryRate} breaths/min`
    });
  }

  // Trend multiplier (sustained elevation is more concerning)
  // Uses else-if to prevent cascading multiplication:
  //   2 days → ×1.3, 3+ days → ×1.5 (intentionally NOT 1.3×1.2=1.56)
  if (trendDays >= 3) {
    riskScore *= 1.5;
  } else if (trendDays >= 2) {
    riskScore *= 1.3;
  }
  
  const risk_index = Math.min(100, Math.round(riskScore));
  const level: IllnessRisk['level'] = risk_index >= 70 ? 'high' : risk_index >= 40 ? 'moderate' : 'low';

  return {
    risk_index,
    level,
    confidence: signals.length >= 3 ? 0.85 : signals.length >= 2 ? 0.65 : 0.40,
    time_window: trendDays >= 2 ? 'next 24-48h' : 'next 24h',
    signals,
    recommendation: generateIllnessRecommendation(risk_index, signals),
    limitations: [
      'Not a diagnosis. This signal may produce false positives/negatives.',
      'Wrist temperature deviation is not a core body temperature measurement.',
      'If you have severe symptoms or are concerned, seek medical care.'
    ]
	  };
}
```

### Recovery → Nutrition Targets (Dynamic)

Recovery directly adjusts macro targets (in addition to training adjustments).

**Mapping (continuous linear interpolation, per kg bodyweight):**

| Recovery Score | Protein Adjustment | Carb Multiplier | Calorie Multiplier | Guidance |
|---|---|---|---|---|
| 0 | +0.30 g/kg | ×0.85 | ×0.95 | Anti-inflammatory focus, avoid alcohol |
| 25 | +0.15 g/kg | ×0.925 | ×0.975 | Recovery-supporting foods |
| 50 | Baseline | ×1.00 | ×1.00 | Maintain normal intake |
| 75 | Baseline | ×1.025 | ×1.025 | Moderate adaptation surplus |
| 100 | Baseline | ×1.05 | ×1.05 | Full performance surplus |

> **v3.4 Change:** Replaced discrete step-function with continuous linear interpolation.
> This eliminates abrupt target swings when recovery fluctuates near zone boundaries
> (e.g., score 49→50 previously caused a 0.20 g/kg protein drop).

```typescript
/**
 * Linear interpolation helper for smooth recovery-based adjustments.
 * Eliminates zone-boundary discontinuities that caused unstable recommendations
 * when recovery score fluctuated near 25, 50, or 75.
 */
function lerp(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number {
  const t = Math.max(0, Math.min(1, (value - inMin) / (inMax - inMin)));
  return outMin + t * (outMax - outMin);
}

/**
 * Recovery → Nutrition Adjustment (Continuous Model)
 *
 * Replaces the previous step-function (v3.3) with linear interpolation
 * to prevent abrupt target swings at zone boundaries.
 *
 * Mapping (continuous):
 *   recovery 0   → protein +0.30 g/kg, carbs ×0.85, calories ×0.95
 *   recovery 50  → protein +0.00 g/kg, carbs ×1.00, calories ×1.00
 *   recovery 100 → protein +0.00 g/kg, carbs ×1.05, calories ×1.05
 */
function applyRecoveryNutritionAdjustment(
  baseTargets: NutritionTargets,
  recoveryScore: number,
  weightKg: number
): NutritionTargets {
  let proteinDeltaGPerKg: number;
  let carbMultiplier: number;
  let calorieMultiplier: number;

  if (recoveryScore <= 50) {
    // 0→50: linearly interpolate from max adjustment to baseline
    proteinDeltaGPerKg = lerp(recoveryScore, 0, 50, 0.30, 0.00);
    carbMultiplier     = lerp(recoveryScore, 0, 50, 0.85, 1.00);
    calorieMultiplier  = lerp(recoveryScore, 0, 50, 0.95, 1.00);
  } else {
    // 50→100: linearly interpolate from baseline to performance surplus
    proteinDeltaGPerKg = 0; // No extra protein needed at high recovery
    carbMultiplier     = lerp(recoveryScore, 50, 100, 1.00, 1.05);
    calorieMultiplier  = lerp(recoveryScore, 50, 100, 1.00, 1.05);
  }

  const proteinDeltaG = proteinDeltaGPerKg * weightKg;
  const proteinG = Math.round(baseTargets.protein_g + proteinDeltaG);
  const carbsG = Math.round(baseTargets.carbs_g * carbMultiplier);
  const calories = Math.round(baseTargets.calories * calorieMultiplier);

  // Keep fat as the balancing macro to hit calorie target
  const fatCalories = calories - (proteinG * 4) - (carbsG * 4);
  const fatG = Math.max(0, Math.round(fatCalories / 9));

  return { ...baseTargets, calories, protein_g: proteinG, carbs_g: carbsG, fat_g: fatG };
}
```

---

## 8. COMPLETE DATA SOURCE INTEGRATION

### Overview: Multi-Source Holistic Analysis

Life OS uses **ALL available data sources** to build the most complete picture of user health:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    LIFE OS DATA ECOSYSTEM                           │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
│  │  APPLE WATCH    │  │   NUTRITION     │  │  BIOIMPEDANCE   │     │
│  │  (Automatic)    │  │  (User Input)   │  │  (If available) │     │
│  │                 │  │                 │  │                 │     │
│  │  • HRV (SDNN)   │  │  • Food photos  │  │  • Body fat %   │     │
│  │  • Sleep stages │  │  • Manual entry │  │  • Muscle mass  │     │
│  │  • RHR          │  │  • Supplements  │  │  • Hydration    │     │
│  │  • Temperature  │  │  • Macros       │  │  • Visceral fat │     │
│  │  • Steps        │  │  • Meal timing  │  │  • Bone mass    │     │
│  │  • Workouts     │  │                 │  │                 │     │
│  │  • VO2 Max      │  │                 │  │                 │     │
│  │  • SpO2         │  │                 │  │                 │     │
│  │  • Respiratory  │  │                 │  │                 │     │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘     │
│           │                    │                    │               │
│           └──────────┬─────────┴──────────┬─────────┘               │
│                      │                    │                         │
│                      ▼                    ▼                         │
│              ┌───────────────────────────────────┐                  │
│              │      SELF-REPORTED DATA           │                  │
│              │                                   │                  │
│              │  • Morning wellness check         │                  │
│              │  • Energy levels                  │                  │
│              │  • Mood/stress                    │                  │
│              │  • Subjective sleep quality       │                  │
│              │  • Menstrual cycle                │                  │
│              │  • Injury/pain status             │                  │
│              └───────────────────────────────────┘                  │
│                              │                                      │
│                              ▼                                      │
│              ┌───────────────────────────────────┐                  │
│              │     HOLISTIC ANALYSIS ENGINE      │                  │
│              │                                   │                  │
│              │  Recovery Score + Insights +      │                  │
│              │  Personalized Recommendations     │                  │
│              └───────────────────────────────────┘                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 9. APPLE WATCH DATA INTEGRATION

### Complete HealthKit Metrics Used

| Metric | HealthKit Type | Use in Algorithm | Priority |
|--------|---------------|------------------|----------|
| **Heart Rate Variability** | `HKQuantityTypeIdentifier.heartRateVariabilitySDNN` | HRV Score (primary) | Critical |
| **Resting Heart Rate** | `HKQuantityTypeIdentifier.restingHeartRate` | RHR Score, Illness detection | High |
| **Sleep Analysis** | `HKCategoryTypeIdentifier.sleepAnalysis` | Sleep stages, duration | Critical |
| **Wrist Temperature** | `HKQuantityTypeIdentifier.appleSleepingWristTemperature` | Temperature Score | High |
| **Respiratory Rate** | `HKQuantityTypeIdentifier.respiratoryRate` | Illness detection | Medium |
| **Blood Oxygen** | `HKQuantityTypeIdentifier.oxygenSaturation` | Illness detection | Medium |
| **Active Energy** | `HKQuantityTypeIdentifier.activeEnergyBurned` | Training Load | High |
| **Basal Energy** | `HKQuantityTypeIdentifier.basalEnergyBurned` | TDEE calculation | High |
| **Step Count** | `HKQuantityTypeIdentifier.stepCount` | Activity context | Low |
| **Walking/Running Distance** | `HKQuantityTypeIdentifier.distanceWalkingRunning` | Cardio load | Medium |
| **VO2 Max** | `HKQuantityTypeIdentifier.vo2Max` | Fitness baseline | Medium |
| **Walking Heart Rate Average** | `HKQuantityTypeIdentifier.walkingHeartRateAverage` | Recovery indicator | Medium |
| **Walking Steadiness** | `HKQuantityTypeIdentifier.appleWalkingSteadiness` | Long-term mobility context | Low |
| **Workout Data** | `HKWorkoutType.workoutType()` | Training Load | High |

### Training Load Calculation

```typescript
interface TrainingLoad {
  acute: number;       // EWMA 7-day (full history, lambda=2/(7+1))
  chronic: number;     // EWMA 28-day (full history, lambda=2/(28+1))
  ratio: number;       // Acute:Chronic ratio
  zone: 'undertraining' | 'optimal' | 'overreaching' | 'injury_risk';
  weeklyTrend: 'increasing' | 'stable' | 'decreasing';
}

/**
 * Training Load using TRIMP (Training Impulse)
 *
 * Default model (HR-zone based):
 * TRIMP = sum(minutes_in_zone_i * zone_multiplier_i)
 *
 * Zone multipliers are exponential (Banister-style) to avoid
 * underweighting high-intensity work. Linear multipliers are deprecated.
 *
 * Fallback (no HR zones):
 * TRIMP = duration_minutes * RPE
 */
const DEFAULT_ZONE_MULTIPLIERS = [1.0, 2.0, 4.0, 7.0, 12.0]; // Zone 5 ≈ 12× Zone 1

function calculateTRIMP(
  workout: WorkoutData
): number {
  if (workout.minutesInZones) {
    const multipliers = (workout.zoneMultipliers && workout.zoneMultipliers.length === workout.minutesInZones.length)
      ? workout.zoneMultipliers
      : DEFAULT_ZONE_MULTIPLIERS;

    return workout.minutesInZones.reduce((sum, minutes, i) => {
      return sum + (minutes * multipliers[i]);
    }, 0);
  }

  if (workout.rpe) {
    return workout.durationMinutes * workout.rpe;
  }

  // Conservative fallback if no intensity signal (low confidence)
  const fallbackRPE = 3; // light-moderate
  return Math.min(workout.durationMinutes * fallbackRPE, 200);
}

/**
 * Exponentially Weighted Moving Average (EWMA) — P1-002 Audit Fix
 * 
 * EWMA provides more stable load calculations than simple moving averages.
 * Lambda (λ) determines recency weighting: higher λ = more recent emphasis.
 * 
 * Formula: EWMA_today = λ × Load_today + (1 - λ) × EWMA_yesterday
 * 
 * Standard λ values (Williams et al., 2017):
 *   - Acute (7-day):  λ = 2/(N+1) = 2/(7+1) = 0.25
 *   - Chronic (28-day): λ = 2/(N+1) = 2/(28+1) ≈ 0.069
 * 
 * Reference: Williams, S. et al. (2017). "Better way to determine ACWR."
 * Br J Sports Med, 51:209-210. DOI: 10.1136/bjsports-2016-096589
 */
const EWMA_LAMBDA = {
  ACUTE_7_DAY: 0.25,      // λ = 2/(7+1)
  CHRONIC_28_DAY: 0.069,  // λ = 2/(28+1)
  ACUTE_14_DAY: 0.133,    // λ = 2/(14+1) - alternative
} as const;

function calculateEWMA(
  dailyLoads: number[],
  lambda: number = EWMA_LAMBDA.ACUTE_7_DAY
): number {
  if (dailyLoads.length === 0) return 0;
  
  let ewma = dailyLoads[0];
  for (let i = 1; i < dailyLoads.length; i++) {
    ewma = lambda * dailyLoads[i] + (1 - lambda) * ewma;
  }
  
  return ewma;
}

/**
 * Acute:Chronic Workload Ratio
 * 
 * Note: While ACWR has limitations (see Gabbett critique), 
 * it remains useful as ONE component of load monitoring.
 * We use exponentially weighted moving averages for stability.
 */
function calculateACWR(
  dailyLoads: number[],
  acuteDays: number = 7,
  chronicDays: number = 28
): TrainingLoad {
  // Use full history with different lambda values for proper EWMA decay
  const acuteLambda = 2 / (acuteDays + 1);    // ~0.25 for 7-day
  const chronicLambda = 2 / (chronicDays + 1); // ~0.069 for 28-day
  const acute = calculateEWMA(dailyLoads, acuteLambda);
  const chronic = calculateEWMA(dailyLoads, chronicLambda);
  
  // Cold-start protection: avoid extreme ratios when <14 days of history
  const availableDays = dailyLoads.length;
  const averageLoad = availableDays > 0
    ? dailyLoads.reduce((sum, v) => sum + v, 0) / availableDays
    : 0;
  const coldStartBaseline = availableDays < 14
    ? Math.max(averageLoad * 0.5, 50) // 50 TRIMP floor to prevent 1st-session spikes
    : 0;

  const effectiveChronic = Math.max(chronic, coldStartBaseline, 1.0);
  const ratio = acute / effectiveChronic;
  
  let zone: TrainingLoad['zone'];
  if (ratio < 0.8) zone = 'undertraining';
  else if (ratio <= 1.3) zone = 'optimal';
  else if (ratio <= 1.5) zone = 'overreaching';
  else zone = 'injury_risk';
  
  return { acute, chronic, ratio, zone, weeklyTrend: analyzeTrend(dailyLoads) };
}
```

> [!IMPORTANT]  
> **ACWR Limitations Disclaimer**  
> The Acute:Chronic Workload Ratio is ONE tool for load monitoring, not a definitive injury predictor.  
> 
> **What ACWR does NOT account for:**
> - Training modality differences (strength vs cardio vs sport-specific)
> - Individual recovery capacity and training age
> - External life stressors (work, relationships, travel)
> - Sleep quality and nutrition status
> - Psychological readiness and motivation
> - Prior injury history
>
> **Scientific Context:** Gabbett (2020) critiqued ACWR's oversimplification. We use it alongside HRV, sleep, and subjective wellness for a holistic view. Never make training decisions based on ACWR alone.
>
> *Reference: Gabbett, T.J. (2020). "Debunking the myths about training load, injury and performance." Br J Sports Med, 54:58-66. [DOI: 10.1136/bjsports-2019-101402](https://doi.org/10.1136/bjsports-2019-101402)*

### Blood Oxygen (SpO2) Analysis

```typescript
/**
 * SpO2 Analysis for Recovery and Illness Detection
 * 
 * Normal range: 95-100%
 * Below 94%: May indicate respiratory issues, sleep apnea, or altitude effects
 */
function analyzeBloodOxygen(
  recentReadings: SpO2Reading[],
  baseline: number
): SpO2Analysis {
  const avgOvernight = calculateOvernightAverage(recentReadings);
  const lowestReading = Math.min(...recentReadings.map(r => r.value));
  const dipsBelow90 = recentReadings.filter(r => r.value < 90).length;
  
  // Sleep apnea indicator
  const sleepApneaRisk = dipsBelow90 >= 5 ? 'HIGH' : dipsBelow90 >= 2 ? 'MODERATE' : 'LOW';
  
  // IMPORTANT: This is a SCREENING indicator, not a diagnosis
  // If HIGH risk detected, recommend professional sleep study (polysomnography)
  const medicalDisclaimer = sleepApneaRisk === 'HIGH' 
    ? 'Frequent SpO2 dips detected during sleep. This may indicate sleep-disordered breathing. ' +
      'Consider consulting a sleep specialist for a professional evaluation (polysomnography). ' +
      'This is not a medical diagnosis.'
    : null;
  
  return {
    overnightAverage: avgOvernight,
    lowestReading,
    dipsBelow90Count: dipsBelow90,
    sleepApneaRisk,
    alert: lowestReading < 88 ? createLowSpO2Alert(lowestReading) : null
  };
}
```

---

## 10. NUTRITION IMPACT ON RECOVERY

### Protein Targets by Activity Level (ISSN Position Stand)

> [!IMPORTANT]
> **Reference:** Jäger, R. et al. (2017). "International Society of Sports Nutrition Position Stand: Protein and Exercise."
> *J Int Soc Sports Nutr*, 14:20. [DOI: 10.1186/s12970-017-0177-8](https://doi.org/10.1186/s12970-017-0177-8)

```typescript
/**
 * ISSN-Based Protein Recommendations
 *
 * Protein needs vary significantly based on activity level and goals.
 * These targets are evidence-based per ISSN Position Stand (2017).
 */
interface ProteinTarget {
  gPerKgMin: number;
  gPerKgMax: number;
  gPerKgOptimal: number;
  rationale: string;
}

const PROTEIN_TARGETS: Record<ActivityLevel, ProteinTarget> = {
  sedentary: {
    gPerKgMin: 0.8,
    gPerKgMax: 1.0,
    gPerKgOptimal: 0.8,
    rationale: 'RDA for general health. Adequate for non-exercising individuals.'
  },

  light: {
    gPerKgMin: 1.0,
    gPerKgMax: 1.2,
    gPerKgOptimal: 1.1,
    rationale: 'Light exercise (1-3 days/week). Modest increase supports recovery.'
  },

  moderate: {
    gPerKgMin: 1.2,
    gPerKgMax: 1.6,
    gPerKgOptimal: 1.4,
    rationale: 'Regular exercise (3-5 days/week). Higher needs for adaptation.'
  },

  active: {
    gPerKgMin: 1.4,
    gPerKgMax: 2.0,
    gPerKgOptimal: 1.7,
    rationale: 'High-volume training. Supports muscle protein synthesis.'
  },

  very_active: {
    gPerKgMin: 1.6,
    gPerKgMax: 2.2,
    gPerKgOptimal: 2.0,
    rationale: 'Athletes with high training loads. May need up to 2.2g/kg.'
  },

  // Special cases
  strength_athlete: {
    gPerKgMin: 1.6,
    gPerKgMax: 2.2,
    gPerKgOptimal: 2.0,
    rationale: 'ISSN: "1.6-2.2 g/kg for strength athletes to maximize MPS."'
  },

  endurance_athlete: {
    gPerKgMin: 1.2,
    gPerKgMax: 1.6,
    gPerKgOptimal: 1.4,
    rationale: 'ISSN: "1.2-1.6 g/kg for endurance athletes."'
  },

  weight_loss: {
    gPerKgMin: 1.6,
    gPerKgMax: 2.4,
    gPerKgOptimal: 2.0,
    rationale: 'Higher protein preserves lean mass during caloric deficit. ISSN recommends up to 2.4g/kg.'
  },

  elderly_active: {
    gPerKgMin: 1.2,
    gPerKgMax: 1.6,
    gPerKgOptimal: 1.4,
    rationale: 'Age 60+: Higher needs due to anabolic resistance. ISSN + ESPEN guidelines.'
  }
};

/**
 * Calculate personalized protein target
 */
function calculateProteinTarget(
  weightKg: number,
  activityLevel: ActivityLevel,
  goal: UserGoal,
  age: number
): number {
  let target = PROTEIN_TARGETS[activityLevel];

  // Adjust for specific goals
  if (goal === 'weight_loss' && target.gPerKgOptimal < 1.6) {
    target = PROTEIN_TARGETS.weight_loss;
  }

  // Adjust for age (anabolic resistance)
  let optimalGPerKg = target.gPerKgOptimal;
  if (age >= 60) {
    optimalGPerKg = Math.max(optimalGPerKg, 1.2);
  }

  return Math.round(weightKg * optimalGPerKg);
}
```

### Protein Distribution (Per-Meal Optimization)

```typescript
/**
 * Protein Distribution per ISSN and Schoenfeld & Aragon (2018)
 *
 * Reference: Schoenfeld, B.J. & Aragon, A.A. (2018). "How much protein can the
 * body use in a single meal for muscle-building?" J Int Soc Sports Nutr, 15:10.
 * DOI: 10.1186/s12970-018-0215-1
 */
const PROTEIN_DISTRIBUTION = {
  minPerMeal: 20,        // g — minimum to stimulate MPS
  optimalPerMeal: 40,    // g — maximal MPS stimulation
  maxUseful: 55,         // g — diminishing returns above this
  preWorkout: '20-40g 1-2 hours before',
  postWorkout: '0.3–0.5 g/kg within 2 hours after',
  beforeSleep: '30-40g casein or slow-digesting protein',
  mealSpacing: '3-5 hours between protein-rich meals',
};
```

### How Food Data Affects Recovery Calculations

Nutrition directly impacts recovery through multiple pathways:

| Factor | Impact on Recovery | Algorithm Integration |
|--------|-------------------|----------------------|
| **Protein Timing** | Muscle repair, sleep quality | Adjusts recovery forecast |
| **Carb Intake** | Glycogen replenishment | Post-workout recovery speed |
| **Caloric Deficit** | Impairs recovery capacity | Reduces recovery ceiling |
| **Hydration** | Blood volume, HRV accuracy | Adjusts HRV interpretation |
| **Alcohol** | Suppresses REM, elevates RHR | Next-day penalty |
| **Caffeine Timing** | Disrupts deep sleep | Sleep score adjustment |
| **Anti-inflammatory Foods** | Reduces inflammation markers | Long-term recovery boost |

### Nutrition Recovery Modifiers

```typescript
interface NutritionImpact {
  modifier: number;        // Multiplier on recovery (0.8 - 1.2)
  factors: NutritionFactor[];
  recommendations: string[];
}

/**
 * Calculate nutrition's impact on recovery
 * 
 * This adjusts the base recovery score based on nutritional factors
 * from the previous 24-48 hours.
 */
function calculateNutritionImpact(
  nutritionLogs: FoodLog[],
  userGoals: NutritionGoals,
  workoutData: WorkoutData | null,
  sleepData?: SleepData | null,
  userProfile?: UserProfile
): NutritionImpact {
  let modifier = 1.0;
  const factors: NutritionFactor[] = [];
  const recommendations: string[] = [];
  
  // Get yesterday's nutrition summary
  const yesterday = getNutritionSummary(nutritionLogs, -1);
  
  // 1. Protein adequacy (critical for recovery)
  const proteinRatio = yesterday.protein / userGoals.protein;
  if (proteinRatio < 0.7) {
    modifier *= 0.92;  // 8% penalty
    factors.push({ factor: 'LOW_PROTEIN', impact: -0.08 });
    recommendations.push('Increase protein intake toward your activity-level target (e.g., 1.6-2.2g/kg strength, 1.2-1.6g/kg endurance).');
  } else if (proteinRatio >= 1.0) {
    modifier *= 1.03;  // 3% boost
    factors.push({ factor: 'ADEQUATE_PROTEIN', impact: +0.03 });
  }
  
  // 2. Post-workout nutrition (if workout yesterday)
  if (workoutData && workoutData.endTime) {
    const postWorkoutMeal = findMealAfterWorkout(nutritionLogs, workoutData.endTime, 2); // Within 2 hours
    if (!postWorkoutMeal) {
      modifier *= 0.95;  // 5% penalty
      factors.push({ factor: 'MISSED_POST_WORKOUT', impact: -0.05 });
      recommendations.push('Consume protein + carbs within 2 hours of training');
    } else {
      // Scale post-workout targets by body weight when available
      const weightKg = userProfile?.weightKg;
      const proteinTarget = weightKg ? (weightKg * 0.4) : 35; // 0.3–0.5 g/kg → use mid-point
      const carbTarget = weightKg ? (weightKg * 1.0) : 60;    // 0.8–1.2 g/kg → use mid-point

      const proteinRatio = postWorkoutMeal.protein / proteinTarget;
      const carbRatio = postWorkoutMeal.carbs / carbTarget;

      if (proteinRatio < 0.6 || carbRatio < 0.6) {
        modifier *= 0.96;  // 4% penalty for under-fueling
        factors.push({ factor: 'POST_WORKOUT_UNDERFUEL', impact: -0.04 });
        recommendations.push(
          `Post-workout targets scale by body weight. Aim for ~${Math.round(proteinTarget)}g protein ` +
          `and ~${Math.round(carbTarget)}g carbs within 2 hours.`
        );
      }
    }
  }
  
  // 3. Caloric deficit severity
  const caloricBalance = yesterday.calories - userGoals.tdee;
  if (caloricBalance < -500) {
    const deficitPenalty = Math.min(0.1, Math.abs(caloricBalance - 500) / 5000);
    modifier *= (1 - deficitPenalty);
    factors.push({ factor: 'CALORIC_DEFICIT', impact: -deficitPenalty });
    if (caloricBalance < -750) {
      recommendations.push('Large caloric deficit may impair recovery. Consider a refeed day.');
    }
  }
  
  // 4. Alcohol consumption (significant REM suppressant)
  //
  // Quantified REM Suppression Effects (Ebrahim et al., 2013, Alcoholism: Clinical & Experimental Research):
  // - 1-2 drinks: REM sleep reduced 9-24% in first half of night
  // - 3-4 drinks: REM sleep reduced 25-40%, with rebound fragmentation in second half
  // - 5+ drinks:  REM sleep reduced >50%, severely fragmented architecture
  //
  // Additional findings:
  // - Alcohol increases N3 (deep sleep) in first half but disrupts it later
  // - Half-life of alcohol effects: ~4-5 hours
  // - Even 1 drink within 4 hours of bed measurably affects HRV (Sagawa et al., 2011)
  //
  // DOI: 10.1111/acer.12006 (Ebrahim et al., 2013)
  // DOI: 10.1093/alcalc/agr045 (Sagawa et al., 2011)
  //
  const alcoholUnits = yesterday.alcoholUnits || 0;
  if (alcoholUnits > 0) {
    // Penalty scale based on Ebrahim meta-analysis:
    // 1 unit = 5% penalty, 2 units = 10%, 3+ = up to 15% max
    const alcoholPenalty = Math.min(0.15, alcoholUnits * 0.05);
    modifier *= (1 - alcoholPenalty);
    factors.push({
      factor: 'ALCOHOL',
      impact: -alcoholPenalty,
      detail: `${alcoholUnits} unit(s) → estimated ${Math.round(alcoholUnits * 12)}% REM reduction`
    });

    if (alcoholUnits >= 3) {
      recommendations.push('3+ drinks severely fragments REM sleep (>25% reduction). Recovery will be impaired for 24-36 hours.');
    } else if (alcoholUnits >= 2) {
      recommendations.push('2 drinks moderately disrupts REM sleep (~20% reduction). Consider alcohol-free days for better recovery.');
    } else {
      recommendations.push('Even 1 drink affects sleep architecture. For optimal recovery, avoid alcohol within 4 hours of bed.');
    }
  }
  
  // 5. Caffeine timing (pharmacokinetic model)
  const bedtime = sleepData?.sleepStartLocal ?? sleepData?.sleepStart ?? userProfile?.bedtimeTarget;
  const caffeineRemainingMg = bedtime
    ? estimateCaffeineRemainingMg(nutritionLogs, bedtime)
    : estimateCaffeineRemainingMgAfter14(nutritionLogs);

  if (caffeineRemainingMg > 50) {  // >50mg remaining at bedtime
    modifier *= 0.97;
    factors.push({ factor: 'LATE_CAFFEINE', impact: -0.03 });
    recommendations.push('Caffeine still in your system at bedtime can reduce deep sleep. Consider an earlier cutoff.');
  }
  
  // 6. Hydration (affects HRV accuracy)
  const hydrationRatio = yesterday.waterML / (userGoals.waterML || 2500);
  if (hydrationRatio < 0.6) {
    modifier *= 0.95;
    factors.push({ factor: 'DEHYDRATION', impact: -0.05 });
    recommendations.push('Dehydration may have affected your HRV readings');
  }
  
  return {
    modifier: Math.max(0.75, Math.min(1.2, modifier)),
    factors,
    recommendations
  };
}

/**
 * Estimate caffeine remaining at bedtime using a half-life model.
 * Half-life ≈ 5.5h (population average).
 */
function estimateCaffeineRemainingMg(nutritionLogs: FoodLog[], bedtime: Date | string): number {
  const bedtimeDate = new Date(bedtime);
  const halfLifeHours = 5.5;
  const logs = nutritionLogs.filter(l => Number(l.caffeineMg) > 0 && l.loggedAt);

  return logs.reduce((sum, log) => {
    const hoursToBed = (bedtimeDate.getTime() - new Date(log.loggedAt).getTime()) / 36e5;
    if (hoursToBed <= 0) return sum + (log.caffeineMg || 0);
    const remaining = (log.caffeineMg || 0) * Math.pow(0.5, hoursToBed / halfLifeHours);
    return sum + remaining;
  }, 0);
}

/**
 * Fallback when bedtime is unknown: treat caffeine after 14:00 as "late".
 */
function estimateCaffeineRemainingMgAfter14(nutritionLogs: FoodLog[]): number {
  return nutritionLogs.reduce((sum, log) => {
    if (!log.loggedAt || !log.caffeineMg) return sum;
    const hour = new Date(log.loggedAt).getHours();
    return hour >= 14 ? sum + log.caffeineMg : sum;
  }, 0);
}
```

### Food Photo Analysis Context

When analyzing food photos, we extract data that feeds into recovery calculations:

```typescript
interface MealAnalysis {
  // Basic macros (from OpenRouter (openai/gpt-4o))
  calories: number;
  protein: number;
  fat: number;
  carbs: number;
  fiber: number;
  
  // Recovery-relevant signals
  isHighProtein: boolean;          // >30g protein
  hasAntiInflammatory: boolean;    // Omega-3, turmeric, berries, etc.
  hasPotentialAllergens: string[]; // Dairy, gluten, etc.
  estimatedGlycemicLoad: 'low' | 'medium' | 'high';
  alcoholPresent: boolean;
  caffeineEstimate: number;        // mg
  
  // Context
  mealType: 'breakfast' | 'lunch' | 'dinner' | 'snack';
  timingContext: 'pre_workout' | 'post_workout' | 'normal';
  minutesSinceLastMeal: number;
}
```

---

## 11. BIOIMPEDANCE INTEGRATION

### Smart Scale Data (Optional Enhancement)

For users with bioimpedance-capable smart scales (Withings, Renpho, Xiaomi, etc.):

```typescript
interface BioimpedanceData {
  // Core metrics
  weight: number;           // kg
  bodyFatPercent: number;   // %
  muscleMass: number;       // kg
  waterPercent: number;     // %
  boneMass: number;         // kg
  visceralFatLevel: number; // 1-20 scale typically
  metabolicAge: number;     // years
  
  // Derived
  leanBodyMass: number;     // weight - fat mass
  fatMass: number;          // weight × body fat%
  
  // Timestamps
  measurementDate: Date;
  deviceType: string;
}

/**
 * Body Composition Recovery Adjustments
 * 
 * Body composition affects recovery capacity:
 * - Higher muscle mass = higher metabolic rate = faster recovery
 * - Higher body fat = increased inflammation = slower recovery
 * - Hydration status = affects HRV accuracy
 */
function calculateBodyCompositionFactor(
  current: BioimpedanceData,
  baseline: BioimpedanceData | null,
  userGoals: UserGoals
): BodyCompFactor {
  let modifier = 1.0;
  const insights: string[] = [];
  
  // 1. Hydration status (critical for HRV accuracy)
  if (current.waterPercent < 50) {
    modifier *= 0.95;
    insights.push('Low hydration detected. HRV may be less accurate. Drink more water.');
  } else if (current.waterPercent >= 55) {
    modifier *= 1.02;
    insights.push('Good hydration levels support accurate recovery measurement.');
  }
  
  // 2. Body composition trends (if baseline exists)
  if (baseline) {
    const muscleChange = current.muscleMass - baseline.muscleMass;
    const fatChange = current.fatMass - baseline.fatMass;
    
    // Gaining muscle = better recovery capacity
    if (muscleChange > 0.5) {
      modifier *= 1.03;
      insights.push(`Muscle mass increased by ${muscleChange.toFixed(1)}kg — improved recovery capacity.`);
    }
    
    // Losing fat while maintaining muscle = reduced inflammation
    if (fatChange < -0.5 && muscleChange >= 0) {
      modifier *= 1.02;
      insights.push('Body recomposition trending positively.');
    }
    
    // Rapid weight loss = may impair recovery
    const weightChange = current.weight - baseline.weight;
    if (weightChange < -2 && baseline.measurementDate > daysAgo(7)) {
      modifier *= 0.95;
      insights.push('Rapid weight loss may temporarily impair recovery. Prioritize protein and sleep.');
    }
  }
  
  // 3. Visceral fat (inflammation marker)
  if (current.visceralFatLevel > 12) {
    modifier *= 0.97;
    insights.push('Elevated visceral fat may increase systemic inflammation.');
  }
  
  return {
    modifier: Math.max(0.85, Math.min(1.1, modifier)),
    hydrationStatus: current.waterPercent >= 55 ? 'OPTIMAL' : current.waterPercent >= 50 ? 'ADEQUATE' : 'LOW',
    insights
  };
}
```

### HealthKit Integration for Body Composition

```typescript
/**
 * Fetch body composition data from HealthKit
 * (synced from smart scales via their companion apps)
 */
async function fetchBioimpedanceFromHealthKit(): Promise<BioimpedanceData | null> {
  const healthStore = HKHealthStore();
  
  // These are written by third-party apps like Withings, Renpho, etc.
  const types = [
    HKQuantityType.quantityType(forIdentifier: .bodyMass),
    HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage),
    HKQuantityType.quantityType(forIdentifier: .leanBodyMass),
    HKQuantityType.quantityType(forIdentifier: .bodyMassIndex)
  ];
  
  // Query most recent readings
  const results = await Promise.all(types.map(type => 
    fetchMostRecentSample(healthStore, type)
  ));
  
  if (!results[0]) return null;  // No weight data
  
  return {
    weight: results[0].value,
    bodyFatPercent: results[1]?.value ?? null,
    leanBodyMass: results[2]?.value ?? null,
    // ... etc
  };
}
```

---

## 12. SELF-REPORTED WELLNESS DATA

### Morning Wellness Check

A brief daily check-in (optional but valuable) that collects subjective data:

```typescript
interface MorningWellnessCheck {
  timestamp: Date;
  
  // Core questions (1-5 scale or emoji picker)
  perceivedSleepQuality: number;    // "How did you sleep?" 1-5
  energyLevel: number;              // "How's your energy?" 1-5
  muscleSoreness: number;           // "Any soreness?" 1-5 (5=very sore)
  stressLevel: number;              // "Stress level?" 1-5
  mood: number;                     // "Overall mood?" 1-5
  
  // Optional flags
  feelingIll: boolean;              // "Feeling sick?"
  headache: boolean;
  digestiveIssues: boolean;
  
  // Free text (optional)
  notes: string | null;
  
  // Menstrual cycle (if tracking)
  periodStarted: boolean | null;
  periodEnded: boolean | null;
}
```

### Subjective Data Integration

```typescript
/**
 * Wellness Questionnaire Score
 * 
 * Research shows subjective wellness correlates with objective metrics
 * but also captures factors wearables miss (stress, mood, life events).
 * 
 * Reference: Saw et al. (2015) "Monitoring the athlete training response"
 * DOI: 10.1136/bjsports-2015-094758
 */
function calculateSubjectiveWellnessScore(
  wellness: MorningWellnessCheck
): SubjectiveScore {
  // Invert soreness (lower is better)
  const sorenessScore = 6 - wellness.muscleSoreness;
  // Invert stress (lower is better)
  const stressScore = 6 - wellness.stressLevel;
  
  // Weighted average
  const raw = (
    wellness.perceivedSleepQuality * 0.25 +
    wellness.energyLevel * 0.25 +
    sorenessScore * 0.20 +
    stressScore * 0.15 +
    wellness.mood * 0.15
  );
  
  // Scale to 0-100
  const score = ((raw - 1) / 4) * 100;
  
  // Illness flags override
  let adjustedScore = score;
  if (wellness.feelingIll) adjustedScore *= 0.6;
  if (wellness.headache) adjustedScore *= 0.9;
  if (wellness.digestiveIssues) adjustedScore *= 0.9;
  
  return {
    score: Math.round(adjustedScore),
    sleepPerception: wellness.perceivedSleepQuality,
    energyLevel: wellness.energyLevel,
    stressLevel: wellness.stressLevel,
    recoveryReady: adjustedScore >= 60,
    alerts: generateWellnessAlerts(wellness)
  };
}

/**
 * Objective vs Subjective Discrepancy Detection
 * 
 * When objective data (HRV high) conflicts with subjective data (feeling tired),
 * we flag this for investigation — often indicates:
 * - Mental/emotional stress not captured by HRV
 * - Early illness before physiological markers appear
 * - Life stressors (work, relationships, etc.)
 */
function detectObjectiveSubjectiveDiscrepancy(
  objectiveScore: number,
  subjectiveScore: number
): Discrepancy | null {
  const difference = objectiveScore - subjectiveScore;
  
  if (Math.abs(difference) > 25) {
    return {
      type: difference > 0 ? 'OBJECTIVE_HIGHER' : 'SUBJECTIVE_HIGHER',
      objectiveScore,
      subjectiveScore,
      difference,
      insight: difference > 0 
        ? 'Your body metrics look good, but you feel off. Mental stress, poor mood, or early illness may be factors. How was your day yesterday?'
        : 'You feel better than your metrics suggest. This could be temporary — listen to your body and avoid overexertion today.'
    };
  }
  
  return null;
}

/**
 * Adaptive blending weights for objective vs subjective signals.
 *
 * Rationale:
 * - Base: 70% objective / 30% subjective
 * - If subjective is low or discrepancy is large, trust subjective more
 * - If data confidence is low, lean further on subjective
 */
function getSubjectiveBlendWeights(
  objectiveScore: number,
  subjectiveScore: number,
  confidence: number
): { objective: number; subjective: number } {
  const discrepancy = Math.abs(objectiveScore - subjectiveScore);
  let subjectiveWeight = 0.30;

  if (subjectiveScore <= 40 || discrepancy >= 20) {
    subjectiveWeight = 0.40;
  }

  if (confidence < 0.60) {
    subjectiveWeight = Math.max(subjectiveWeight, 0.45);
  }

  subjectiveWeight = Math.min(subjectiveWeight, 0.50);
  return { objective: 1 - subjectiveWeight, subjective: subjectiveWeight };
}
```

### Menstrual Cycle Integration

#### Local Schema (GRDB / SQLite)

> [!IMPORTANT]
> Menstrual data is **on-device only** — raw cycle data is never sent to the server.
> Only derived `currentPhase` may be shared if the user explicitly opts in.

```sql
-- Local SQLite table (GRDB)
CREATE TABLE menstrual_cycles (
    id TEXT PRIMARY KEY,                -- UUID (client-generated)
    period_start_date TEXT NOT NULL,    -- YYYY-MM-DD (local calendar date)
    period_end_date TEXT,               -- YYYY-MM-DD (null if period ongoing)
    flow_intensity TEXT CHECK (flow_intensity IN ('light', 'medium', 'heavy', 'unspecified')),
    cycle_length_days INTEGER,          -- Computed: days until next period_start_date
    source TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'healthkit')),
    healthkit_sample_ids TEXT,          -- JSON array of HKSample UUIDs for dedup
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX idx_menstrual_cycles_date ON menstrual_cycles(period_start_date DESC);

-- Trigger for updated_at
CREATE TRIGGER set_menstrual_cycles_updated_at
    AFTER UPDATE ON menstrual_cycles
    FOR EACH ROW
    BEGIN
        UPDATE menstrual_cycles SET updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = NEW.id;
    END;
```

#### Phase Derivation Algorithm

```typescript
/**
 * Derive the current menstrual cycle phase from stored flow records.
 *
 * Phase model (28-day reference cycle, scaled to actual cycle length):
 *   MENSTRUAL   — days 1–5      (period bleeding)
 *   FOLLICULAR  — days 6–13     (estrogen rise, high energy)
 *   OVULATION   — days 14–16    (peak fertility window)
 *   LUTEAL      — days 17–end   (progesterone rise, temp ↑, HRV ↓)
 *
 * If cycle length differs from 28 days, phases are proportionally scaled.
 * Returns null if insufficient data (< 2 recorded periods).
 */
function deriveMenstrualPhase(
  records: MenstrualCycleRecord[],
  today: Date
): MenstrualCycleData | null {
  // Need at least 2 periods to compute cycle length
  const sorted = records
    .filter(r => r.period_start_date != null)
    .sort((a, b) => b.period_start_date.localeCompare(a.period_start_date));

  if (sorted.length < 2) return null;

  // Average cycle length from last 6 cycles (or fewer if unavailable)
  const recentCycles = sorted.slice(0, Math.min(7, sorted.length));
  const cycleLengths: number[] = [];
  for (let i = 0; i < recentCycles.length - 1; i++) {
    const diff = daysBetween(recentCycles[i + 1].period_start_date, recentCycles[i].period_start_date);
    if (diff >= 18 && diff <= 45) {  // Plausible range
      cycleLengths.push(diff);
    }
  }

  if (cycleLengths.length === 0) return null;

  const avgCycleLength = Math.round(calculateMean(cycleLengths));
  const lastPeriodStart = parseDate(sorted[0].period_start_date);
  const cycleDay = daysSince(lastPeriodStart) + 1;  // Day 1 = first day of period

  // Phase boundaries (proportionally scaled)
  const menstrualEnd = Math.round(avgCycleLength * 5 / 28);      // ~5 days
  const follicularEnd = Math.round(avgCycleLength * 13 / 28);    // ~13 days
  const ovulationEnd = Math.round(avgCycleLength * 16 / 28);     // ~16 days
  // Luteal = remainder

  let currentPhase: MenstrualCycleData['currentPhase'];
  if (cycleDay <= menstrualEnd) {
    currentPhase = 'MENSTRUAL';
  } else if (cycleDay <= follicularEnd) {
    currentPhase = 'FOLLICULAR';
  } else if (cycleDay <= ovulationEnd) {
    currentPhase = 'OVULATION';
  } else if (cycleDay <= avgCycleLength) {
    currentPhase = 'LUTEAL';
  } else {
    // Past expected cycle length — period may be late
    currentPhase = 'LUTEAL';  // Assume late luteal until next period recorded
  }

  const predictedNext = new Date(lastPeriodStart);
  predictedNext.setDate(predictedNext.getDate() + avgCycleLength);

  return {
    cycleDay: cycleDay > avgCycleLength ? null : cycleDay,
    cycleLength: avgCycleLength,
    currentPhase,
    lastPeriodStart,
    predictedNextPeriod: predictedNext,
    healthKitSynced: sorted[0].source === 'healthkit',
    lastSyncAt: null  // Set by HealthKit sync layer
  };
}

function daysBetween(dateStrA: string, dateStrB: string): number {
  const a = new Date(dateStrA);
  const b = new Date(dateStrB);
  return Math.round(Math.abs(b.getTime() - a.getTime()) / (1000 * 60 * 60 * 24));
}
```

#### HealthKit Sync for Menstrual Cycle

Life OS reads menstrual cycle data from Apple Health using the following HealthKit types:

```swift
// HealthKit Menstrual Data Types
let menstrualTypes: Set<HKCategoryType> = [
    HKObjectType.categoryType(forIdentifier: .menstrualFlow)!,      // Period days
    HKObjectType.categoryType(forIdentifier: .intermenstrualBleeding)!,
    HKObjectType.categoryType(forIdentifier: .ovulationTestResult)!,
    HKObjectType.categoryType(forIdentifier: .sexualActivity)!      // For prediction
]

// Read menstrual flow data
let menstrualQuery = HKSampleQuery(
    sampleType: HKObjectType.categoryType(forIdentifier: .menstrualFlow)!,
    predicate: HKQuery.predicateForSamples(
        withStart: Calendar.current.date(byAdding: .month, value: -3, to: Date())!,
        end: Date(),
        options: .strictStartDate
    ),
    limit: HKObjectQueryNoLimit,
    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
) { query, samples, error in
    guard let samples = samples as? [HKCategorySample] else { return }
    
    // Process menstrual flow samples
    // value: 1 = unspecified, 2 = light, 3 = medium, 4 = heavy
}
```

**Sync Strategy:**
- Background sync every 6 hours
- Immediate sync on app launch if >3 hours since last sync
- User can manually refresh via pull-to-refresh
- Data stored locally for offline access

**Privacy Considerations:**
- Menstrual data is on-device by default; raw cycle data is never sent to the server
- If the user explicitly opts in, the client may share **derived phase** (e.g., luteal) for scoring
- User can disable cycle tracking without affecting other features
- Data encrypted with device passcode

```typescript
interface MenstrualCycleData {
  cycleDay: number | null;
  cycleLength: number;       // Typically 24-35 days
  currentPhase: 'MENSTRUAL' | 'FOLLICULAR' | 'OVULATION' | 'LUTEAL' | null;
  lastPeriodStart: Date | null;
  predictedNextPeriod: Date | null;
  healthKitSynced: boolean;   // True if data came from HealthKit
  lastSyncAt: Date | null;    // Last HealthKit sync timestamp
}

/**
 * Menstrual Cycle Phase Adjustments
 * 
 * Hormonal fluctuations affect:
 * - HRV (lower in luteal phase)
 * - Body temperature (higher in luteal phase)
 * - Recovery capacity
 * - Performance potential
 * 
 * Reference: McNulty et al. (2020) "The Effects of Menstrual Cycle Phase 
 * on Exercise Performance in Eumenorrheic Women"
 */
function adjustForMenstrualPhase(
  baseScore: number,
  cycleData: MenstrualCycleData
): AdjustedScore {
  if (!cycleData.currentPhase) return { score: baseScore, adjustment: 0, phase: null };
  
  let adjustment = 0;
  let note = '';
  
  switch (cycleData.currentPhase) {
    case 'MENSTRUAL':
      // Days 1-5: Energy may be lower, that's normal
      adjustment = +3;
      note = 'Menstrual phase — be gentle with yourself. Light activity is fine.';
      break;
      
    case 'FOLLICULAR':
      // Days 6-13: Rising estrogen, high energy, best for hard training
      adjustment = 0;
      note = 'Follicular phase — great time for challenging workouts!';
      break;
      
    case 'OVULATION':
      // Days 14-16: Peak performance potential, but injury risk slightly higher
      adjustment = 0;
      note = 'Ovulation — peak strength potential. Mind your joints.';
      break;
      
    case 'LUTEAL':
      // Days 17-28: Progesterone rises, HRV naturally lower, temp higher
      adjustment = +5;  // Compensate for natural HRV suppression
      note = 'Luteal phase — HRV may be lower. This is physiologically normal.';
      break;
  }
  
  return {
    score: Math.min(100, baseScore + adjustment),
    adjustment,
    phase: cycleData.currentPhase,
    note
  };
}
```

---

## 13. ENHANCED COMPOSITE RECOVERY SCORE

### Integrating All Data Sources

```typescript
interface ComprehensiveRecoveryScore {
  // Primary score
  overall: number;                    // 0-100
  confidence: number;                 // 0-1 based on data completeness
  
  // Component breakdown
  components: {
    hrv: HRVScore;
    sleep: SleepScore;
    rhr: RHRScore;
    temperature: TemperatureScore;
  };
  
  // Modifying factors
  modifiers: {
    nutrition: NutritionImpact;
    training: TrainingLoad;
    markers: MarkerImpact | null;
    bodyComp: BodyCompFactor | null;
    subjective: SubjectiveScore | null;
    menstrualCycle: AdjustedScore | null;
  };
  
  // Final outputs
  zone: RecoveryZone;
  recommendations: PrioritizedRecommendation[];
  alerts: Alert[];
  discrepancies: Discrepancy[];
}

/**
 * Master Recovery Calculation
 * 
 * Combines all data sources into a single holistic score.
 */
async function calculateComprehensiveRecoveryScore(
  // Apple Watch data
  healthKitData: HealthKitData,
  
  // Nutrition data
  nutritionLogs: FoodLog[],
  nutritionGoals: NutritionGoals,
  
  // Bioimpedance (optional)
  bioimpedance: BioimpedanceData | null,
  
  // Self-reported
  wellnessCheck: MorningWellnessCheck | null,
  
  // Context
  userProfile: UserProfile,
  baselines: UserBaselines
): Promise<ComprehensiveRecoveryScore> {
  
  // === STEP 1: Calculate base physiological scores ===
  const hrvScore = calculateHRVScore(healthKitData.hrv, baselines.hrv);

  // Sleep score uses training-load-adjusted duration target (Section 26)
  const yesterdayTrimp = healthKitData.dailyTrainingLoads?.slice(-1)?.[0] ?? 0;
  const chronicTrimp = healthKitData.dailyTrainingLoads
    ? calculateEWMA(healthKitData.dailyTrainingLoads, EWMA_LAMBDA.CHRONIC_28_DAY)
    : 0;
  const sleepScore = calculateTrainingAwareSleepScore(
    healthKitData.sleep, baselines.sleep, userProfile.age,
    yesterdayTrimp, chronicTrimp
  );

  const rhrScore = calculateRHRScore(healthKitData.rhr, baselines.rhr);
  const tempScore = calculateTemperatureScore(healthKitData.temperature, baselines.temperature);

  // Base weighted composite (physiological only) with missing-signal reweight
  const weights = { hrv: 0.40, sleep: 0.30, rhr: 0.15, temp: 0.15 };
  const availability = {
    hrv: !!healthKitData.hrv,
    sleep: !!healthKitData.sleep,
    rhr: !!healthKitData.rhr,
    temp: !!healthKitData.temperature
  };

  const weightSum =
    (availability.hrv ? weights.hrv : 0) +
    (availability.sleep ? weights.sleep : 0) +
    (availability.rhr ? weights.rhr : 0) +
    (availability.temp ? weights.temp : 0);

  const baseScore = weightSum > 0
    ? (
        (availability.hrv ? hrvScore.score * weights.hrv : 0) +
        (availability.sleep ? sleepScore.overall * weights.sleep : 0) +
        (availability.rhr ? rhrScore.score * weights.rhr : 0) +
        (availability.temp ? tempScore.score * weights.temp : 0)
      ) / weightSum
    : 0;
  
  // === STEP 2: Calculate modifying factors ===

  // 2.1 Use dynamic weight (Section 27) instead of static profile weight
  const { weightKg: effectiveWeight } = await getEffectiveWeight(userProfile.userId);

  // 2.2 Nutrition impact
  const nutritionImpact = calculateNutritionImpact(
    nutritionLogs,
    nutritionGoals,
    healthKitData.lastWorkout,
    healthKitData.sleep,
    { ...userProfile, weightKg: effectiveWeight }
  );

  // 2.3 Training load (guard against undefined/empty dailyTrainingLoads)
  const trainingLoad = (healthKitData.dailyTrainingLoads && healthKitData.dailyTrainingLoads.length > 0)
    ? calculateACWR(healthKitData.dailyTrainingLoads, 7, 28)
    : { acute: 0, chronic: 0, ratio: 1.0, zone: 'optimal' as const, weeklyTrend: 'stable' as const };

  // 2.4 Health markers (labs) — cached (slow-changing)
  const markerImpact = await getCachedOrCalculate(
    `marker_impact_${userProfile.userId}`,
    () => calculateMarkerImpact(userProfile.userId),
    24 * 60 * 60 * 1000
  );

  // 2.5 Body composition (if available)
  const bodyCompFactor = bioimpedance
    ? calculateBodyCompositionFactor(bioimpedance, baselines.bodyComp, userProfile.goals)
    : null;

  // 2.6 Subjective wellness (if completed today)
  const subjectiveScore = wellnessCheck
    ? calculateSubjectiveWellnessScore(wellnessCheck)
    : null;

  // 2.7 Menstrual cycle adjustment (if tracking)
  const cycleAdjustment = userProfile.menstrualCycle
    ? adjustForMenstrualPhase(baseScore, userProfile.menstrualCycle)
    : null;

  // 2.8 Enhanced illness detection (Section 25 — cross-domain)
  const nutritionIllnessSignals = detectNutritionIllnessSignals(
    nutritionLogs.filter(l => daysSince(l.loggedAt) <= 3),
    nutritionLogs.filter(l => daysSince(l.loggedAt) <= 14),
    nutritionGoals,
    userProfile.isOnDiet ?? false
  );
  const illnessRisk = calculateEnhancedIllnessRisk(
    hrvScore.deviationPercent ?? 0,
    rhrScore.deviationBpm ?? 0,
    tempScore.deviationC ?? 0,
    healthKitData.respiratoryRate ?? null,
    tempScore.trendDays ?? 0,
    nutritionIllnessSignals
  );

  // === STEP 3: Apply modifiers (Section 30 — canonical composition) ===
  let modifiedScore = baseScore;

  // 3.1 Compute all multiplicative modifiers
  // Training modifier uses continuous interpolation based on ACWR ratio
  // to eliminate zone-boundary discontinuities (see Section 30 rationale).
  //   ratio ≤ 1.3 (optimal):     1.0    (no penalty)
  //   ratio  1.3→1.5 (overreaching): lerp 1.0 → 0.95
  //   ratio  1.5→2.0 (injury_risk):  lerp 0.95 → 0.88
  //   ratio ≥ 2.0:                0.88   (floor)
  const trainingModifier = trainingLoad.ratio <= 1.3
    ? 1.0
    : trainingLoad.ratio <= 1.5
      ? lerp(trainingLoad.ratio, 1.3, 1.5, 1.0, 0.95)
      : trainingLoad.ratio <= 2.0
        ? lerp(trainingLoad.ratio, 1.5, 2.0, 0.95, 0.88)
        : 0.88;

  // 3.2 Single-product composition with single clamp (order-independent)
  // See Section 30 for rationale and required unit tests
  const { clamped: modifierProduct } = composeModifiers({
    nutrition: nutritionImpact.modifier,
    bodyComp: bodyCompFactor ? bodyCompFactor.modifier : 1.0,
    training: trainingModifier,
    markers: markerImpact ? (1 + markerImpact.totalImpact) : 1.0
  });
  modifiedScore *= modifierProduct;

  // 3.3 Menstrual cycle adjustment (additive, not multiplicative)
  if (cycleAdjustment && cycleAdjustment.adjustment !== 0) {
    modifiedScore += cycleAdjustment.adjustment;
  }
  
  // === STEP 4: Calculate confidence (quality-weighted composed model) ===
  // Uses calculateComposedConfidence which accounts for both availability AND
  // data quality (e.g., HRV sample count, sleep stage confidence, nutrition completeness).
  // The binary calculateDataConfidence is retained as a fallback but should not be
  // used in the primary pipeline — see Section 14 for both implementations.
  const confidence = calculateComposedConfidence({
    hrv: {
      available: !!healthKitData.hrv,
      quality: hrvScore.sampleQuality ?? (healthKitData.hrv ? 0.7 : 0)
    },
    sleep: {
      available: !!healthKitData.sleep,
      quality: sleepScore.stageConfidence ?? (healthKitData.sleep ? 0.7 : 0)
    },
    rhr: {
      available: !!healthKitData.rhr,
      quality: healthKitData.rhr ? 0.85 : 0  // RHR is generally reliable when present
    },
    temperature: {
      available: !!healthKitData.temperature,
      quality: healthKitData.temperature ? 0.75 : 0
    },
    nutrition: {
      available: nutritionLogs.length > 0,
      quality: nutritionLogs.length >= 3 ? 0.9 : nutritionLogs.length / 3 * 0.7
    },
    bioimpedance: {
      available: !!bioimpedance,
      quality: bioimpedance ? 0.8 : 0
    },
    wellnessCheck: {
      available: !!wellnessCheck,
      quality: wellnessCheck ? 1.0 : 0  // Self-reported = full quality when present
    }
  }, baselines.daysOfData);

  // === STEP 5: Blend objective and subjective ===
  let finalScore: number;
  let discrepancy: Discrepancy | null = null;
  
  if (subjectiveScore) {
    const weights = getSubjectiveBlendWeights(modifiedScore, subjectiveScore.score, confidence);
    finalScore = (modifiedScore * weights.objective) + (subjectiveScore.score * weights.subjective);

    // Check for discrepancies
    discrepancy = detectObjectiveSubjectiveDiscrepancy(modifiedScore, subjectiveScore.score);
  } else {
    finalScore = modifiedScore;
  }
  
  // Clamp to valid range
  finalScore = Math.max(0, Math.min(100, finalScore));
  
  // === STEP 6: Generate zone and recommendations ===
  const zone = determineRecoveryZone(finalScore);
  const recommendations = generatePrioritizedRecommendations({
    score: finalScore,
    hrvScore,
    sleepScore,
    nutritionImpact,
    trainingLoad,
    subjectiveScore,
    cycleAdjustment
  });
  
  return {
    overall: Math.round(finalScore),
    confidence,
    components: { hrv: hrvScore, sleep: sleepScore, rhr: rhrScore, temperature: tempScore },
    modifiers: {
      nutrition: nutritionImpact,
      training: trainingLoad,
      markers: markerImpact,
      bodyComp: bodyCompFactor,
      subjective: subjectiveScore,
      menstrualCycle: cycleAdjustment
    },
    zone,
    recommendations,
    alerts: collectAlerts({ hrvScore, sleepScore, tempScore, trainingLoad, illnessRisk }),
    illnessRisk,
    discrepancies: discrepancy ? [discrepancy] : []
  };
}
```

---

## 14. DATA CONFIDENCE SCORING

### Measuring Reliability of the Recovery Score

```typescript
interface DataConfidence {
  overall: number;           // 0-1
  breakdown: {
    metric: string;
    available: boolean;
    weight: number;
  }[];
  message: string;
}

/**
 * Calculate how much we can trust the recovery score
 * based on data availability and quality.
 */
function calculateDataConfidence(availability: DataAvailability): DataConfidence {
  const weights = {
    hrv: 0.25,
    sleep: 0.25,
    rhr: 0.10,
    temperature: 0.10,
    nutrition: 0.15,
    bioimpedance: 0.05,
    wellnessCheck: 0.10
  };
  
  let confidence = 0;
  const breakdown = [];
  
  if (availability.hasHRV) {
    confidence += weights.hrv;
    breakdown.push({ metric: 'HRV', available: true, weight: weights.hrv });
  } else {
    breakdown.push({ metric: 'HRV', available: false, weight: weights.hrv });
  }
  
  // ... similar for other metrics
  
  // Boost confidence for more days of baseline data
  const baselineBoost = Math.min(0.1, availability.daysOfData * 0.01);
  confidence += baselineBoost;

  // Clamp
  confidence = Math.min(1, confidence);

  // Generate message
  let message: string;
  if (confidence >= 0.9) {
    message = 'High confidence — comprehensive data available.';
  } else if (confidence >= 0.7) {
    message = 'Good confidence — most key metrics available.';
  } else if (confidence >= 0.5) {
    message = 'Moderate confidence — some data missing. Score may be less accurate.';
  } else {
    message = 'Low confidence — limited data available. Wear your watch tonight and log your meals!';
  }

  return { overall: confidence, breakdown, message };
}
```

### Confidence Composition: Incorporating Per-Component Quality

The binary availability model above answers "do we have data?" but not "how good is that data?"
The composed confidence formula below blends availability with per-component quality signals
to produce a more accurate overall confidence score.

```typescript
interface ComponentConfidence {
  hrv: { available: boolean; quality: number };        // quality = HRVBaseline.confidence (0-1)
  sleep: { available: boolean; quality: number };      // quality = source confidence (watch=1.0, phone=0.6, manual=0.4)
  rhr: { available: boolean; quality: number };        // quality = 1.0 if ≥3 overnight samples, else 0.5
  temperature: { available: boolean; quality: number };// quality = 1.0 if baseline ≥ 7 days, else days/7
  nutrition: { available: boolean; quality: number };  // quality = meals_logged / expected_meals (0-1)
  bioimpedance: { available: boolean; quality: number };// quality = 1.0 if < 7 days old, 0.5 if < 30 days, 0 otherwise
  wellnessCheck: { available: boolean; quality: number };// quality = 1.0 (binary — either completed or not)
}

/**
 * Composed Confidence Score
 *
 * Formula:
 *   overallConfidence = Σ (weight_i × available_i × quality_i) + baselineBoost
 *
 * Where:
 *   weight_i    = importance weight for component i (sums to 1.0)
 *   available_i = 1 if data present, 0 if absent
 *   quality_i   = per-component quality factor (0-1)
 *   baselineBoost = min(0.10, daysOfData × 0.01)
 *
 * This ensures that e.g. an HRV reading with a pending baseline (confidence=0.3)
 * contributes less to overall confidence than one with a mature baseline (confidence=0.95).
 *
 * Threshold: overall < 0.65 → low-confidence flag → triggers review-required UX.
 */
function calculateComposedConfidence(
  components: ComponentConfidence,
  daysOfData: number
): DataConfidence {
  const weights = {
    hrv: 0.25,
    sleep: 0.25,
    rhr: 0.10,
    temperature: 0.10,
    nutrition: 0.15,
    bioimpedance: 0.05,
    wellnessCheck: 0.10
  };

  let confidence = 0;
  const breakdown: DataConfidence['breakdown'] = [];

  for (const [key, weight] of Object.entries(weights)) {
    const comp = components[key as keyof ComponentConfidence];
    const contribution = comp.available ? weight * comp.quality : 0;
    confidence += contribution;
    breakdown.push({
      metric: key,
      available: comp.available,
      weight,
      quality: comp.quality,
      contribution
    });
  }

  // Baseline maturity boost
  const baselineBoost = Math.min(0.10, daysOfData * 0.01);
  confidence += baselineBoost;
  confidence = Math.min(1, confidence);

  // Message
  let message: string;
  if (confidence >= 0.9) {
    message = 'High confidence — comprehensive, high-quality data available.';
  } else if (confidence >= 0.65) {
    message = 'Good confidence — most key metrics available with adequate quality.';
  } else if (confidence >= 0.5) {
    message = 'Moderate confidence — some data missing or low quality. Score may be less accurate.';
  } else {
    message = 'Low confidence — limited or low-quality data. Wear your watch tonight and log your meals!';
  }

  return { overall: confidence, breakdown, message };
}
```

---

## 15. ALGORITHM VALIDATION METHODOLOGY

### Internal Validation Framework

> [!IMPORTANT]
> This section defines **methodology + acceptance criteria**.  
> Do not publish or claim numeric “results” without a dated audit artifact in `audits/` (protocol + dataset summary + metrics).

#### 15.1 HRV Algorithm Validation

**Goal:** Ensure HealthKit HRV (SDNN) is reliable enough for **baseline-relative** scoring.

**Validation Method (recommended):**
- Collect paired measurements: Apple Watch HRV (SDNN) vs a reference RR‑interval sensor (e.g., chest strap) in the same time window.
- Evaluate on log scale (`ln(ms)`) and on baseline-relative deltas (direction + magnitude).
- Metrics to report:
  - Pearson/Spearman correlation on log scale
  - MAE/RMSE on log scale
  - Bland–Altman agreement (bias + limits)
  - Test–retest reliability (ICC), if protocol supports repeated measures

**Acceptance Criteria (targets; tune with real data):**
- Daily **direction-of-change** agreement ≥ 70% (vs baseline)
- Correlation on log scale ≥ 0.80
- No systematic bias that would frequently flip recovery zones

#### 15.2 Sleep Stage Validation

**Goal:** Sleep data should be accurate enough to guide recovery behavior **without overclaiming sleep stages**.

**Validation Method (recommended):**
- Validate **total sleep time (TST)** and sleep timing (sleep start/end) against:
  - sleep diary and/or a reference wearable in larger samples
  - PSG only in small, optional subsets (if available)
- Treat sleep stages as estimates; validate stages only at coarse aggregate levels.

**Acceptance Criteria (targets):**
- Nightly TST MAE ≤ 30 minutes (on average)
- Sleep onset/offset MAE ≤ 20 minutes (on average)
- Stage estimates are not used for clinical claims; UI must label stages as “estimates”

> [!WARNING]
> **User-Facing Disclaimer Required:**
> "Sleep stages are estimates based on movement and heart rate patterns. For clinical sleep assessment, consult a sleep specialist for polysomnography (PSG)."

#### 15.3 Recovery Score Validation

**Goal:** The score should be **useful and calibrated**: higher scores should align with better subjective readiness and (when available) better training outcomes.

**Validation Method (recommended):**
- Compare recovery score/zone to:
  - subjective wellness checks (energy/stress/soreness)
  - training RPE and completion rate
  - user-labeled “felt ill” days
- Validate zone behavior (monotonic ordering): Optimal > Ready > Caution > Critical across outcomes.
- Calibrate “illness risk” as **risk levels** (low/moderate/high) unless you have enough data to estimate PPV/NPV responsibly.

**Acceptance Criteria (targets):**
- Monotonicity holds across key outcomes (wellness + training adherence)
- Zone transitions are stable (no excessive day-to-day whiplash without signal changes)
- Safety: false-alarm rate is low; messaging remains non-diagnostic and action-oriented

#### 15.4 AI Food Recognition Validation

**Goal:** AI food estimates should be accurate enough for trends and guidance, and always editable by the user.

**Validation Method (recommended):**
- Build a labeled evaluation set (dietitian‑verified macros and ingredients).
- Report errors by category (single-item vs mixed meals vs restaurant vs packaged).
- Track post-correction error (after user edits) to measure “human-in-the-loop” improvement.

**Acceptance Criteria (targets):**
- Calories MAPE ≤ 25% (average), with clear UI for corrections
- Protein MAPE ≤ 30% (average)
- For low-confidence meals, require user confirmation before logging

> [!NOTE]
> **User-Facing Disclaimer:**
> "AI food estimates are approximate. For precise tracking, verify and adjust values. Accuracy improves with your corrections over time."

#### 15.5 Continuous Improvement Process

```typescript
interface ValidationPipeline {
  // Automated validation on each model update
  stages: [
    'unit_tests',           // Algorithm correctness
    'regression_tests',     // No performance degradation
    'shadow_deployment',    // Run new model alongside production
    'canary_release',       // 5% of users for 7 days
    'full_rollout'          // If metrics pass thresholds
  ];

  // Key metrics monitored
  metrics: {
    recovery_usefulness: 'Monotonic zones + improves decisions (measured via surveys + adherence)',
    false_alert_rate: 'Below defined threshold (set after baseline observation)',
    user_satisfaction_score: '>= 4.2/5 (target)',
    regression_budget: 'No statistically meaningful degradation on key eval sets'
  };

  // Rollback trigger
  rollback_if: {
    metric_degradation: '> 10%',
    user_complaints_spike: '> 2x baseline',
    critical_bug_reports: '> 0'
  };
}
```

#### 15.6 External Benchmarking

Competitor comparisons are **informative**, but not a success metric. Avoid “score chasing”.

**Method (optional):**
- Recruit users who simultaneously wear multiple devices for a limited period.
- Compare:
  - rank correlation of daily readiness
  - zone agreement (e.g., same or adjacent zone)
  - divergence cases (why we disagree)

**Output:** Store all results in `audits/` with dataset/protocol notes.

## 16. HEALTH MARKERS INTEGRATION

### Overview

Health markers from blood tests and medical documents can significantly impact recovery. This section defines how extracted markers influence the recovery score.

### Marker Impact Calculation

```typescript
interface MarkerRecoveryImpact {
  markerId: string;
  displayName: string;
  currentValue: number;
  unit: string;
  optimalRange: [number, number];
  status: 'critical_low' | 'low' | 'optimal' | 'high' | 'critical_high';
  impact: number;        // -0.05 to +0.02 (negative = penalty, positive = bonus)
  lastMeasuredAt: Date;
}

/**
 * Calculate recovery impact from health markers
 * Only considers markers measured within last 6 months that affect recovery
 */
async function calculateMarkerImpact(userId: string): Promise<{
  totalImpact: number;
  markers: MarkerRecoveryImpact[];
  recommendations: string[];
}> {
  // Query most recent measurement for each recovery-affecting marker
  const relevantMarkers = await db.query(`
    SELECT DISTINCT ON (hm.marker_id)
      hm.marker_id,
      hm.value,
      hm.unit,
      hm.status,
      hm.measured_at,
      hmc.display_name,
      hmc.optimal_range_male,
      hmc.optimal_range_female,
      hmc.recovery_weight,
      hmc.critical_low,
      u.sex
    FROM health_measurements hm
    JOIN health_marker_catalog hmc ON hm.marker_id = hmc.id
    JOIN users u ON hm.user_id = u.id
    WHERE hm.user_id = $1 
      AND hmc.affects_recovery = TRUE
      AND hm.measured_at > NOW() - INTERVAL '6 months'
    ORDER BY hm.marker_id, hm.measured_at DESC
  `, [userId]);
  
  const impacts: MarkerRecoveryImpact[] = [];
  const recommendations: string[] = [];
  
  for (const marker of relevantMarkers) {
    const range = marker.sex === 'male' 
      ? marker.optimal_range_male 
      : marker.optimal_range_female;
    
    let impact = 0;
    
    // Calculate impact based on status
    if (marker.value < marker.critical_low) {
      // Critical deficiency: full negative impact
      impact = -marker.recovery_weight;
      recommendations.push(
        `Critical: Your ${marker.display_name} is severely low (${marker.value} ${marker.unit}). ` +
        `This may significantly impact recovery. Consider consulting a healthcare provider.`
      );
    } else if (marker.status === 'low') {
      // Low but not critical: half negative impact
      impact = -marker.recovery_weight * 0.5;
      recommendations.push(
        `Your ${marker.display_name} is below optimal (${marker.value} ${marker.unit}). ` +
        `Improving this may boost your recovery.`
      );
    } else if (marker.status === 'optimal') {
      // Optimal: small bonus
      impact = marker.recovery_weight * 0.2;
    } else if (marker.status === 'high') {
      // High: small penalty (some markers being high can be problematic)
      impact = -marker.recovery_weight * 0.25;
    }
    
    // Check if measurement is getting stale (> 3 months)
    const monthsOld = (Date.now() - new Date(marker.measured_at).getTime()) / (1000 * 60 * 60 * 24 * 30);
    if (monthsOld > 3) {
      recommendations.push(
        `Your ${marker.display_name} was last measured ${Math.round(monthsOld)} months ago. ` +
        `Consider getting updated labs.`
      );
    }
    
    impacts.push({
      markerId: marker.marker_id,
      displayName: marker.display_name,
      currentValue: marker.value,
      unit: marker.unit,
      optimalRange: [range.lower, range.upper],
      status: marker.status,
      impact,
      lastMeasuredAt: marker.measured_at
    });
  }
  
  // Sum impacts and cap at ±15%
  const rawTotal = impacts.reduce((sum, m) => sum + m.impact, 0);
  const totalImpact = Math.max(-0.15, Math.min(0.15, rawTotal));
  
  return { totalImpact, markers: impacts, recommendations };
}
```

### Integration into Main Recovery Score

```typescript
// Canonical pipeline is defined in Section 13 (calculateComprehensiveRecoveryScore).
async function calculateRecoveryScore(data: RecoveryData): Promise<RecoveryResult> {
  const comprehensive = await calculateComprehensiveRecoveryScore(
    data.healthKitData,
    data.nutritionLogs,
    data.nutritionGoals,
    data.bioimpedance,
    data.wellnessCheck,
    data.userProfile,
    data.baselines
  );

  return {
    score: comprehensive.overall,
    components: {
      hrv: comprehensive.components.hrv,
      sleep: comprehensive.components.sleep,
      rhr: comprehensive.components.rhr,
      temperature: comprehensive.components.temperature,
      markers: comprehensive.modifiers.markers?.totalImpact ?? 0,
      nutrition: comprehensive.modifiers.nutrition.modifier
    },
    markerInsights: comprehensive.modifiers.markers?.recommendations?.slice(0, 2) ?? [],
    zone: comprehensive.zone
  };
}
```

### Impact Weights by Marker

| Marker | Max Impact | Rationale |
|--------|------------|-----------|
| Testosterone | ±6% | Direct impact on muscle recovery and adaptation |
| Vitamin D | ±5% | Affects muscle function, immune response, mood |
| Cortisol | ±5% | Indicates chronic stress, overtraining |
| Ferritin | ±4% | Oxygen transport, energy metabolism |
| Hemoglobin | ±4% | Oxygen delivery to muscles |
| TSH | ±4% | Metabolic rate, energy levels |
| CRP | ±4% | Inflammation marker, recovery impairment |
| Vitamin B12 | ±3% | Energy, nervous system function |
| Iron | ±3% | Energy, performance |

### Example Scenario

**User Profile:**
- Vitamin D: 24 ng/mL (low) → -2.5% impact
- Ferritin: 85 ng/mL (optimal) → +0.8% impact
- Testosterone: 350 ng/dL (optimal) → +1.2% impact

**Total Marker Impact:** -0.5% 

**Effect on Recovery:**
- Base score from biometrics: 72%
- After marker adjustment: 72 × (1 - 0.005) = 71.6% ≈ 72%

*Small impact because markers are mostly fine, with only mild Vitamin D deficiency.*

---

## 17. CHRONOTYPE INTEGRATION (MEQ)

### About Chronotype

Chronotype refers to an individual's natural preference for sleep timing. Research shows significant variation in optimal sleep/wake times based on genetics.

> **"Chronotype is a major moderating factor in performance optimization. Training and sleep recommendations should account for individual morningness-eveningness preferences."**  
> — Horne & Östberg (1976)

### Morningness-Eveningness Questionnaire (MEQ) Integration

```typescript
/**
 * Chronotype Assessment
 * Based on Horne-Östberg Morningness-Eveningness Questionnaire
 * Reference: Horne & Östberg (1976) — Int J Chronobiol
 */
interface ChronotypeProfile {
  score: number;                    // 16-86 scale
  type: 'DEFINITE_MORNING' | 'MODERATE_MORNING' | 'INTERMEDIATE' | 
        'MODERATE_EVENING' | 'DEFINITE_EVENING';
  optimalWakeTime: { min: string; max: string };
  optimalBedtime: { min: string; max: string };
  peakPhysicalWindow: { start: string; end: string };
  peakCognitiveWindow: { start: string; end: string };
}

function assessChronotype(meqScore: number): ChronotypeProfile {
  let type: ChronotypeProfile['type'];
  let optimalWakeTime, optimalBedtime, peakPhysical, peakCognitive;
  
  if (meqScore >= 70) {
    type = 'DEFINITE_MORNING';
    optimalWakeTime = { min: '05:00', max: '06:30' };
    optimalBedtime = { min: '21:00', max: '22:30' };
    peakPhysical = { start: '09:00', end: '12:00' };
    peakCognitive = { start: '08:00', end: '11:00' };
  } else if (meqScore >= 59) {
    type = 'MODERATE_MORNING';
    optimalWakeTime = { min: '06:00', max: '07:30' };
    optimalBedtime = { min: '22:00', max: '23:30' };
    peakPhysical = { start: '10:00', end: '13:00' };
    peakCognitive = { start: '09:00', end: '12:00' };
  } else if (meqScore >= 42) {
    type = 'INTERMEDIATE';
    optimalWakeTime = { min: '06:30', max: '08:00' };
    optimalBedtime = { min: '22:30', max: '00:00' };
    peakPhysical = { start: '11:00', end: '14:00' };
    peakCognitive = { start: '10:00', end: '13:00' };
  } else if (meqScore >= 31) {
    type = 'MODERATE_EVENING';
    optimalWakeTime = { min: '07:30', max: '09:00' };
    optimalBedtime = { min: '23:30', max: '01:00' };
    peakPhysical = { start: '16:00', end: '19:00' };
    peakCognitive = { start: '15:00', end: '18:00' };
  } else {
    type = 'DEFINITE_EVENING';
    optimalWakeTime = { min: '08:30', max: '10:00' };
    optimalBedtime = { min: '00:30', max: '02:00' };
    peakPhysical = { start: '17:00', end: '20:00' };
    peakCognitive = { start: '16:00', end: '19:00' };
  }
  
  return {
    score: meqScore,
    type,
    optimalWakeTime,
    optimalBedtime,
    peakPhysicalWindow: peakPhysical,
    peakCognitiveWindow: peakCognitive
  };
}

/**
 * Apply chronotype adjustments to recommendations
 */
function adjustForChronotype(
  baseRecommendation: TimeRecommendation,
  chronotype: ChronotypeProfile
): TimeRecommendation {
  // Example: Shift workout recommendations based on peak windows
  if (baseRecommendation.type === 'WORKOUT') {
    baseRecommendation.suggestedTime = chronotype.peakPhysicalWindow.start;
    baseRecommendation.note = 
      `Your chronotype suggests peak physical performance around ${chronotype.peakPhysicalWindow.start}-${chronotype.peakPhysicalWindow.end}`;
  }
  
  return baseRecommendation;
}
```

### MEQ Onboarding Questions

During onboarding, users answer 5 core questions (abbreviated MEQ):

1. **If free to plan your day, when would you get up?**
2. **When do you feel "at your best" for demanding mental work?**
3. **If you had to do 2 hours of hard physical work, when would you choose?**
4. **At what time do you feel tired and need sleep?**
5. **How alert do you feel in the first 30 minutes after waking?**

---

## 18. EXPANDED STRESS DETECTION

### Comprehensive Stress Assessment

```typescript
interface StressProfile {
  physiologicalScore: number;       // 0-100 from HRV, RHR, temp
  subjectiveScore: number | null;   // 0-100 from wellness check
  chronicity: 'ACUTE' | 'SUSTAINED' | 'CHRONIC';
  duration: number;                 // Days of elevated stress
  sources: StressSource[];
  recommendations: string[];
}

interface StressSource {
  type: 'PHYSICAL' | 'MENTAL' | 'EMOTIONAL' | 'SLEEP' | 'NUTRITIONAL' | 'EXTERNAL';
  detected: boolean;
  confidence: number;
  indicators: string[];
}

/**
 * Comprehensive Stress Detection
 * Combines physiological markers with behavioral patterns
 */
function detectStress(data: UserData, history: HistoricalData): StressProfile {
  // Physiological markers
  const hrvSuppression = data.lnHRV < (data.baseline.lnHRV - data.baseline.sd);
  const rhrElevation = data.rhr > (data.baseline.rhr + 5);
  const sleepDebt = calculateSleepDebt(history.sleep, 14) > 10;
  // Wrist temperature is modeled as deviation-from-baseline (°C). Baseline is ~0 by definition.
  const tempElevation = Math.abs(data.wristTemperatureDeviationC) > 0.3;
  
  const physiologicalScore = calculatePhysiologicalStress({
    hrvSuppression,
    rhrElevation,
    sleepDebt,
    tempElevation
  });
  
  // Detect chronicity (how long has stress been present?)
  const stressDays = countConsecutiveStressDays(history);
  let chronicity: StressProfile['chronicity'];
  if (stressDays <= 2) chronicity = 'ACUTE';
  else if (stressDays <= 7) chronicity = 'SUSTAINED';
  else chronicity = 'CHRONIC';
  
  // Identify probable sources
  const sources = identifyStressSources(data, history);
  
  // Generate recommendations
  const recommendations = generateStressRecommendations(sources, chronicity);
  
  return {
    physiologicalScore,
    subjectiveScore: data.wellnessCheck?.stressLevel ?? null,
    chronicity,
    duration: stressDays,
    sources,
    recommendations
  };
}

/**
 * Identify stress sources from patterns
 */
function identifyStressSources(data: UserData, history: HistoricalData): StressSource[] {
  const sources: StressSource[] = [];
  
  // Physical stress (training load)
  if (data.acwr > 1.3) {
    sources.push({
      type: 'PHYSICAL',
      detected: true,
      confidence: 0.85,
      indicators: ['Elevated training load', 'ACWR > 1.3']
    });
  }
  
  // Sleep stress
  if (calculateSleepDebt(history.sleep, 7) > 7) {
    sources.push({
      type: 'SLEEP',
      detected: true,
      confidence: 0.90,
      indicators: ['Sleep debt > 7 hours', 'Cumulative deficiency']
    });
  }
  
  // Nutritional stress
  if (data.nutrition?.calorieDeficit > 500) {
    sources.push({
      type: 'NUTRITIONAL',
      detected: true,
      confidence: 0.75,
      indicators: ['Caloric deficit > 500 kcal', 'May impair recovery']
    });
  }
  
  // External life stressors (from wellness check)
  if (data.wellnessCheck?.lifeStressors?.length > 0) {
    sources.push({
      type: 'EXTERNAL',
      detected: true,
      confidence: 0.80,
      indicators: data.wellnessCheck.lifeStressors
    });
  }
  
  return sources;
}
```

### Life Stressor Logging

Optional daily check-in captures external stressors:

```typescript
interface LifeStressorCheck {
  workStress: 1 | 2 | 3 | 4 | 5;      // 1 = none, 5 = severe
  relationshipStress: 1 | 2 | 3 | 4 | 5;
  financialStress: 1 | 2 | 3 | 4 | 5;
  travelRecent: boolean;              // Travel in last 48h
  majorLifeEvent: boolean;            // Moving, job change, etc.
  notes: string | null;
}
```

---

## 19. N-OF-1 EXPERIMENT TEMPLATES

### Pre-Built Experiment Library

```typescript
interface NOf1Template {
  id: string;
  name: string;
  hypothesis: string;
  duration: { baseline: number; intervention: number; washout: number };
  design: 'ABA' | 'ABAB' | 'MULTIPLE_BASELINE';
  metrics: string[];
  instructions: string;
}

const EXPERIMENT_TEMPLATES: NOf1Template[] = [
  {
    id: 'caffeine_cutoff',
    name: 'Caffeine Cutoff Time',
    hypothesis: 'Cutting off caffeine earlier improves sleep quality',
    duration: { baseline: 7, intervention: 7, washout: 3 },
    design: 'ABA',
    metrics: ['sleepEfficiency', 'deepSleepPercent', 'sleepLatency'],
    instructions: 'Week 1: Normal caffeine. Week 2: No caffeine after 12pm. Week 3: Return to normal.'
  },
  {
    id: 'morning_sunlight',
    name: 'Morning Sunlight Exposure',
    hypothesis: '15 min morning sunlight improves HRV and sleep',
    duration: { baseline: 7, intervention: 14, washout: 0 },
    design: 'ABAB',
    metrics: ['lnHRV', 'sleepEfficiency', 'energyLevel'],
    instructions: 'Get 15 min outdoor sunlight within 1 hour of waking.'
  },
  {
    id: 'alcohol_free',
    name: 'Alcohol-Free Period',
    hypothesis: 'Eliminating alcohol improves REM sleep and recovery',
    duration: { baseline: 7, intervention: 14, washout: 0 },
    design: 'ABA',
    metrics: ['remPercent', 'rhr', 'recoveryScore'],
    instructions: 'No alcohol during intervention period.'
  },
  {
    id: 'pre_sleep_screen',
    name: 'Screen-Free Before Bed',
    hypothesis: 'No screens 1h before bed improves sleep onset',
    duration: { baseline: 7, intervention: 7, washout: 0 },
    design: 'ABA',
    metrics: ['sleepLatency', 'sleepEfficiency'],
    instructions: 'No phone/tablet/TV screens 60 minutes before sleep.'
  },
  {
    id: 'protein_timing',
    name: 'Evening Protein Intake',
    hypothesis: 'Protein before bed improves overnight recovery',
    duration: { baseline: 7, intervention: 14, washout: 0 },
    design: 'ABAB',
    metrics: ['recoveryScore', 'muscleReadiness'],
    instructions: 'Consume ~0.3–0.5 g/kg protein within 2 hours of sleep.'
  },
  {
    id: 'cold_exposure',
    name: 'Cold Shower Intervention',
    hypothesis: 'Morning cold exposure improves HRV and alertness',
    duration: { baseline: 7, intervention: 14, washout: 0 },
    design: 'ABA',
    metrics: ['lnHRV', 'morningAlertness', 'energyLevel'],
    instructions: 'End shower with 30-60 seconds of cold water.'
  }
];
```

### Experiment Result Analysis

```typescript
/**
 * Analyze N-of-1 experiment results
 */
function analyzeExperiment(
  template: NOf1Template,
  baselineData: MetricData[],
  interventionData: MetricData[]
): ExperimentResult {
  const results: MetricComparison[] = template.metrics.map(metric => {
    const baselineMean = calculateMean(baselineData, metric);
    const baselineSD = calculateSD(baselineData, metric);
    const interventionMean = calculateMean(interventionData, metric);
    
    const effectSize = (interventionMean - baselineMean) / baselineSD;
    const percentChange = ((interventionMean - baselineMean) / baselineMean) * 100;
    
    return {
      metric,
      baselineMean,
      interventionMean,
      effectSize,      // Cohen's d
      percentChange,
      isSignificant: Math.abs(effectSize) > 0.5,  // Medium effect threshold
      direction: interventionMean > baselineMean ? 'IMPROVED' : 'DECLINED'
    };
  });
  
  const overallSuccess = results.filter(r => 
    r.isSignificant && r.direction === 'IMPROVED'
  ).length >= results.length / 2;
  
  return {
    templateId: template.id,
    hypothesis: template.hypothesis,
    results,
    overallSuccess,
    recommendation: overallSuccess 
      ? 'This intervention appears beneficial for you. Consider making it a habit.'
      : 'This intervention did not show significant benefit. Try a different approach.'
  };
}
```

---

## 20. AI EXPLAINABILITY FRAMEWORK

### Transparency Requirements

Every AI-generated insight must include:

```typescript
interface AIInsight {
  id: string;
  type: 'PATTERN' | 'RECOMMENDATION' | 'PREDICTION' | 'ANOMALY';
  message: string;
  
  // Explainability (REQUIRED)
  explainability: {
    dataInputs: string[];           // What data was used
    algorithm: string;              // Name of algorithm/model
    confidence: number;             // 0-1 confidence score
    reasoning: string;              // Human-readable explanation
    limitations: string[];          // Known limitations
    learnMore: string | null;       // Link to detailed explanation
  };
  
  // Verifiability
  validation: {
    populationAccuracy: number | null;      // Optional; requires audit artifact
    personalAccuracy: number | null;        // Optional; requires sufficient history
    lastValidated: Date | null;
  };
}

// Example insight with full explainability (synthetic example; numbers are illustrative only)
const exampleInsight: AIInsight = {
  id: 'insight_001',
  type: 'PATTERN',
  message: 'Your recovery is 15% lower on days after evening workouts.',
  
  explainability: {
    dataInputs: [
      'Recovery scores (last 90 days)',
      'Workout timestamps (last 90 days)'
    ],
    algorithm: 'Time-series correlation analysis',
    confidence: 0.82,
    reasoning: 'We analyzed your workout timing vs next-day recovery across 47 data points. ' +
               'Workouts after 8pm correlate with 15% lower recovery scores the following morning. ' +
               'This may be due to elevated core temperature and cortisol affecting sleep onset.',
    limitations: [
      'Correlation, not causation',
      'Sample size: 47 days',
      'Does not account for workout intensity differences'
    ],
    learnMore: null
  },
  
  validation: {
    populationAccuracy: null,
    personalAccuracy: null,
    lastValidated: null
  }
};
```

### Model Documentation

| Model | Purpose | Inputs | Validation | Limitations |
|-------|---------|--------|------------|-------------|
| Recovery Score | Daily readiness | HRV, Sleep, RHR, Temp | Validated via `audits/` (see Sections 15 & 21) | Confounded by caffeine, hydration |
| Illness Detection | Early warning | Wrist temp deviation, RHR, HRV trend | Risk index requires calibration; validate via `audits/` | False positives during heavy training |
| Training Load | Injury risk | Daily TRIMP | ACWR zones validated | Does not account for modality |
| Sleep Quality | Restorative sleep | Stages, efficiency, debt | Validate TST/timing; stages are estimates | Stage estimation is imperfect; avoid clinical claims |

---

## 21. VALIDATION PROTOCOL

### Internal Validation Metrics

```typescript
interface ValidationMetrics {
  // Correlation with gold standards
  hrvVsHolter: number;              // Target: r > 0.85
  sleepVsPSG: number;               // Target: r > 0.70
  recoveryVsSubjective: number;     // Target: r > 0.60
  
  // Prediction accuracy
  illnessDetection: {
    sensitivity: number;            // Target: > 0.80
    specificity: number;            // Target: > 0.70
    leadTime: number;               // Target: > 48 hours
  };
  
  // User outcome tracking
  fatiguePrevention: number;        // % users avoiding burnout
  injuryReduction: number;          // % reduction vs baseline
  userSatisfaction: number;         // NPS or CSAT
}

// DEPRECATED: Use the detailed VALIDATION_TARGETS below (Section 22 — Post-Audit).
// This flat version is retained for backward-compatibility reference only.
const VALIDATION_TARGETS_LEGACY = {
  hrvCorrelation: 0.85,
  sleepStageAccuracy: 0.70,
  recoverySubjectiveCorrelation: 0.60,
  illnessSensitivity: 0.80,
  illnessLeadTime: 48  // hours
};
```

### User-Based Validation Loop

```typescript
/**
 * Track prediction accuracy over time
 */
interface PredictionValidation {
  predictionId: string;
  predictionType: 'ILLNESS' | 'FATIGUE' | 'PERFORMANCE';
  prediction: string;
  confidence: number;
  timestamp: Date;
  
  // User feedback
  userFeedback: {
    accurate: boolean | null;
    feedbackTimestamp: Date | null;
    notes: string | null;
  };
}

/**
 * Periodic user validation prompts
 */
function createValidationPrompt(predictions: PredictionValidation[]): ValidationPrompt {
  // Only ask about predictions > 3 days old
  const validatable = predictions.filter(p => 
    daysSince(p.timestamp) >= 3 && p.userFeedback.accurate === null
  );
  
  if (validatable.length === 0) return null;
  
  const prediction = validatable[0];
  
  return {
    message: formatValidationQuestion(prediction),
    options: ['Yes, accurate', 'No, not accurate', 'Not sure'],
    predictionId: prediction.predictionId,
    skippable: true
  };
}
```

---

## 22. ORTHOSOMNIA PREVENTION

### Definition

**Orthosomnia** is a condition where users become so obsessed with optimizing their sleep metrics that it paradoxically causes anxiety and worsens sleep. (Baron et al., 2017)

### Prevention Measures

```typescript
interface OrthosomniaPrevention {
  enabledFeatures: {
    hideScoresOption: boolean;       // User can hide numeric scores
    trendOnlyMode: boolean;          // Show trends, not daily numbers
    quietNight: boolean;             // No notifications after bedtime
    weeklyOnlyMode: boolean;         // Only show weekly summaries
  };
  
  messaging: {
    dataDisclaimer: string;
    perfectNotRequired: string;
    focusOnFeeling: string;
  };
}

const orthosomniaSafetyNet: OrthosomniaPrevention = {
  enabledFeatures: {
    hideScoresOption: true,
    trendOnlyMode: true,
    quietNight: true,
    weeklyOnlyMode: true
  },
  
  messaging: {
    dataDisclaimer: 
      'Sleep data from wearables is approximate. Your own sense of restfulness matters most.',
    perfectNotRequired: 
      'You don\'t need a "perfect" night to be well-rested. Consistency beats perfection.',
    focusOnFeeling: 
      'How do you FEEL this morning? That\'s the most important metric.'
  }
};
```

### User Behavior Detection

```typescript
/**
 * Detect potential orthosomnia patterns
 */
function detectOrthosomniaBehavior(userBehavior: AppUsageData): OrthosomniaConcern | null {
  const redFlags = [];
  
  // Excessive nighttime app checks
  if (userBehavior.appOpensAfterBedtime > 3) {
    redFlags.push('Multiple app opens after bedtime');
  }
  
  // Obsessive score checking
  if (userBehavior.sleepScreenViews > 10) {
    redFlags.push('Excessive sleep screen viewing');
  }
  
  // Anxiety feedback
  if (userBehavior.wellnessCheck?.sleepAnxiety === 'HIGH') {
    redFlags.push('Self-reported sleep anxiety');
  }
  
  if (redFlags.length >= 2) {
    return {
      concern: true,
      flags: redFlags,
      recommendedAction: 'Consider enabling Trend-Only Mode to reduce score fixation.',
      showInterventionModal: true
    };
  }
  
  return null;
}
```

---

## 23. AUDIT IMPROVEMENTS (P2 Fixes)

### P2-001: SpO2 Sleep Apnea Screening Disclaimer

> [!WARNING]
> **SpO2 Sleep Apnea Screening — Important Limitations**
> 
> The SpO2-based sleep apnea risk screening is a **preliminary indicator only**, not a diagnosis.
> 
> - Apple Watch SpO2 accuracy: ±2-3% compared to pulse oximetry
> - False positive rate: ~15-20% due to motion artifacts during sleep
> - Clinical diagnosis requires polysomnography (PSG) or home sleep test (HST)
> 
> **User-Facing Disclaimer:**
> "HIGH RISK" labels must always display: *"This is a screening indicator suggesting possible sleep-disordered breathing. Please consult a sleep specialist for proper evaluation."*

```typescript
interface SpO2SleepApneaRisk {
  riskLevel: 'LOW' | 'MODERATE' | 'HIGH';
  averageSpO2: number;
  desaturationEvents: number;  // Drops >3% from baseline
  disclaimer: string;          // REQUIRED - always shown
}

const SPO2_DISCLAIMER = {
  LOW: 'SpO2 levels appear normal. This is not a clinical assessment.',
  MODERATE: 'Some desaturation events detected. Consider discussing with your doctor if you experience daytime fatigue.',
  HIGH: '⚠️ SCREENING INDICATOR ONLY: Potential sleep-disordered breathing detected. ' +
        'This is NOT a diagnosis. Please consult a sleep specialist for proper evaluation with polysomnography.'
};
```

---

### P2-002: Sleep Stage Accuracy Caveat

> [!NOTE]
> **Wearable Sleep Stage Accuracy**
> 
> Consumer wearables (Apple Watch, Oura, WHOOP) achieve approximately **70% agreement** with clinical polysomnography (PSG) for sleep stage detection.
> 
> **Stage-specific accuracy:**
> - Wake detection: ~85% accurate
> - Light sleep (N1/N2): ~75% accurate
> - Deep sleep (N3): ~65% accurate
> - REM sleep: ~70% accurate
> 
> Reference: de Zambotti et al. (2019), "Wearable Sleep Technology in Clinical and Research Settings"

```typescript
const SLEEP_ACCURACY_DISCLAIMER = {
  overall: 'Sleep stages detected by Apple Watch are approximately 70% accurate compared to clinical sleep studies.',
  deepSleep: 'Deep sleep detection is less precise (~65%). Small variations (±10min) may not be meaningful.',
  actionableMessage: 'Focus on trends over 7+ days rather than single-night variations.'
};

// Show in sleep insights once per week
function getSleepAccuracyEducation(lastShown: Date): string | null {
  const daysSinceShown = (Date.now() - lastShown.getTime()) / (1000 * 60 * 60 * 24);
  if (daysSinceShown >= 7) {
    return 'Remember: Sleep stage data from wearables is approximate (~70% accuracy). ' +
           'Your subjective feeling of rest matters most!';
  }
  return null;
}
```

---

### P2-003: Bayesian Methods for N-of-1 Experiments

For small sample sizes (7-14 days), traditional frequentist statistics (Cohen's d, t-tests) may be underpowered. Bayesian estimation provides more appropriate inference.

```typescript
/**
 * Bayesian Estimation for N-of-1 Experiments
 * 
 * Uses Bayesian updating to estimate effect size with appropriate
 * uncertainty quantification for small samples.
 * 
 * Reference: Kruschke, J.K. (2013). "Bayesian estimation supersedes the t test."
 * J Experimental Psychology: General, 142(2):573-603.
 */
interface BayesianExperimentResult {
  posteriorMeanDifference: number;
  credibleInterval95: [number, number];  // 95% HDI
  probabilityOfEffectGtZero: number;     // P(effect > 0)
  probabilityOfMeaningfulEffect: number; // P(effect > ROPE threshold)
  ropeThreshold: number;                 // Region of Practical Equivalence
  interpretation: string;
}

function analyzeBayesian(
  baselineData: number[],
  interventionData: number[],
  ropeThreshold: number = 0.1  // 10% change considered meaningful
): BayesianExperimentResult {
  // Simplified Bayesian estimation (full implementation uses MCMC)
  const baselineMean = mean(baselineData);
  const interventionMean = mean(interventionData);
  const pooledSD = pooledStdDev(baselineData, interventionData);
  
  const effectSize = (interventionMean - baselineMean) / baselineMean;
  const se = pooledSD / Math.sqrt(baselineData.length + interventionData.length);
  
  // Approximate 95% credible interval
  const ci95: [number, number] = [
    effectSize - 1.96 * se,
    effectSize + 1.96 * se
  ];
  
  // Probability calculations (simplified - production uses full posterior)
  const probGtZero = normalCDF(effectSize / se);
  const probMeaningful = effectSize > ropeThreshold ? probGtZero * 0.9 : probGtZero * 0.5;
  
  let interpretation: string;
  if (probMeaningful > 0.95) {
    interpretation = 'Strong evidence: Intervention has a meaningful positive effect.';
  } else if (probMeaningful > 0.80) {
    interpretation = 'Moderate evidence: Intervention likely beneficial. Consider extending study.';
  } else if (probMeaningful > 0.50) {
    interpretation = 'Weak evidence: Possible effect, but more data needed for confidence.';
  } else {
    interpretation = 'Insufficient evidence: No clear effect detected. Try a different approach.';
  }
  
  return {
    posteriorMeanDifference: effectSize,
    credibleInterval95: ci95,
    probabilityOfEffectGtZero: probGtZero,
    probabilityOfMeaningfulEffect: probMeaningful,
    ropeThreshold,
    interpretation
  };
}
```

---

### P2-004: Chronotype-Based Meal Timing

Expand circadian recommendations to include time-restricted eating (TRE) windows based on chronotype.

```typescript
/**
 * Chronotype-Optimized Nutrition Timing
 * 
 * Reference: Sutton et al. (2018). "Early Time-Restricted Feeding Improves 
 * Insulin Sensitivity." Cell Metabolism, 27(6):1212-1221.
 */
interface ChronotypeNutritionSchedule {
  chronotype: ChronotypeType;
  eatingWindow: { start: string; end: string };
  lastMealBuffer: number;  // Hours before bedtime
  optimalProteinTiming: string[];
  caffeinesCutoff: string;
  recommendations: string[];
}

const CHRONOTYPE_NUTRITION: Record<string, ChronotypeNutritionSchedule> = {
  DEFINITE_MORNING: {
    chronotype: 'DEFINITE_MORNING',
    eatingWindow: { start: '06:00', end: '18:00' },
    lastMealBuffer: 3,
    optimalProteinTiming: ['07:00', '12:00', '17:30'],
    caffeinesCutoff: '12:00',
    recommendations: [
      'Your metabolism peaks in the morning — front-load calories',
      'Largest meal at breakfast or lunch',
      'Light dinner before 18:00 for optimal digestion',
      'Caffeine only before noon'
    ]
  },
  
  MODERATE_MORNING: {
    chronotype: 'MODERATE_MORNING',
    eatingWindow: { start: '07:00', end: '19:00' },
    lastMealBuffer: 3,
    optimalProteinTiming: ['08:00', '13:00', '18:30'],
    caffeinesCutoff: '13:00',
    recommendations: [
      'Balanced meal timing works well for you',
      'Avoid heavy meals after 19:00',
      'Caffeine before 1 PM'
    ]
  },
  
  INTERMEDIATE: {
    chronotype: 'INTERMEDIATE',
    eatingWindow: { start: '08:00', end: '20:00' },
    lastMealBuffer: 2.5,
    optimalProteinTiming: ['09:00', '14:00', '19:00'],
    caffeinesCutoff: '14:00',
    recommendations: [
      'Standard 12-hour eating window suits you',
      'Finish dinner by 20:00',
      'Caffeine before 2 PM for optimal sleep'
    ]
  },
  
  MODERATE_EVENING: {
    chronotype: 'MODERATE_EVENING',
    eatingWindow: { start: '10:00', end: '21:00' },
    lastMealBuffer: 2.5,
    optimalProteinTiming: ['11:00', '15:00', '20:00'],
    caffeinesCutoff: '16:00',
    recommendations: [
      'Delayed eating window matches your rhythm',
      'Skip or keep breakfast light',
      'Larger lunch and moderate dinner',
      'Caffeine OK until 4 PM given later bedtime'
    ]
  },
  
  DEFINITE_EVENING: {
    chronotype: 'DEFINITE_EVENING',
    eatingWindow: { start: '11:00', end: '22:00' },
    lastMealBuffer: 2,
    optimalProteinTiming: ['12:00', '17:00', '21:00'],
    caffeinesCutoff: '17:00',
    recommendations: [
      'Your metabolism shifts later — that\'s normal for your type',
      'Skip breakfast if not hungry — it\'s fine for evening types',
      'Larger meals in afternoon/evening',
      'Caffeine until 5 PM is acceptable for your bedtime'
    ]
  }
};
```

---

### P2-005: External Validation Metric Targets

Documented target correlations and accuracy metrics for algorithm validation.

```typescript
/**
 * Validation Targets — Gold Standard Comparisons
 * 
 * These metrics should be achieved in validation studies before
 * making accuracy claims to users.
 */
const VALIDATION_TARGETS = {
  // HRV Validation
  hrv: {
    vs_holter_monitor: { target_r: 0.85, minimum_r: 0.75 },
    vs_polar_chest_strap: { target_r: 0.90, minimum_r: 0.80 },
    note: 'Set targets based on wearable validation literature; do not present study-specific claims without citations and dated audit artifacts.'
  },
  
  // Sleep Validation
  sleep: {
    vs_psg_total_duration: { target_r: 0.90, minimum_r: 0.80 },
    vs_psg_stage_agreement: { target_kappa: 0.60, minimum_kappa: 0.50 },
    vs_psg_deep_sleep: { target_r: 0.65, minimum_r: 0.55 },
    note: 'Treat stage outputs as estimates; validate primarily on total sleep time and timing accuracy.'
  },
  
  // Recovery Score Validation
  recovery: {
    vs_subjective_wellness: { target_r: 0.60, minimum_r: 0.50 },
    vs_next_day_performance: { target_r: 0.55, minimum_r: 0.45 },
    note: 'Recovery scores should correlate with both subjective feeling and performance'
  },
  
  // Illness Detection
  illness: {
    sensitivity: { target: 0.80, minimum: 0.70 },
    specificity: { target: 0.75, minimum: 0.65 },
    lead_time_hours: { target: 48, minimum: 24 },
    note: 'Temperature deviation is a promising early-warning signal; validate lead time empirically and present as risk levels unless calibrated.'
  },
  
  // Training Load
  training: {
    acwr_injury_correlation: { target_auc: 0.65, minimum_auc: 0.55 },
    note: 'ACWR alone is a weak predictor (Gabbett critique) — always combine with other metrics'
  }
};

interface ValidationStudy {
  id: string;
  metric: string;
  goldStandard: string;
  sampleSize: number;
  result: number;
  passesCriteria: boolean;
  studyDate: Date;
}
```

---

### P2-006: Respiratory Rate Weight Enhancement

Increase respiratory rate weight for illness detection, particularly for respiratory infections.

```typescript
/**
 * Enhanced Illness Detection with Respiratory Rate (P2-006)
 * 
 * Respiratory rate is highly predictive of respiratory infections
 * but was previously underweighted. Updated weighting:
 * 
 * Previous: respiratoryRate weight = 20 points
 * Updated:  respiratoryRate weight = 30 points (same as temperature)
 * 
 * Reference: Massaroni et al. (2019). "Respiratory Rate Monitoring in 
 * Healthcare." Sensors, 19(2):386.
 */
const ILLNESS_DETECTION_WEIGHTS = {
  // Previous weights
  HRV_SUPPRESSION: 25,
  RHR_ELEVATION: 25,
  TEMPERATURE_ELEVATION: 30,
  // RESPIRATORY_RATE: 20,  // OLD VALUE
  
  // Updated weight — P2-006 fix
  RESPIRATORY_RATE: 30,  // Increased from 20 to match temperature
  
  // Rationale: 
  // - Respiratory rate elevation often precedes RHR changes
  // - More specific to respiratory infections (COVID, flu, cold)
  // - Normal range 12-16 breaths/min; >18 is concerning
};

function detectIllnessEnhanced(data: BiometricData): IllnessRisk {
  let riskScore = 0;
  
  // ... other metrics ...
  
  // Respiratory rate (ENHANCED - P2-006)
  if (data.respiratoryRate && data.respiratoryRate > 17) {
    const severity = data.respiratoryRate > 20 ? 'high' : 'moderate';
    const weight = ILLNESS_DETECTION_WEIGHTS.RESPIRATORY_RATE;
    
    // Additional weight for sustained elevation (2+ days)
    const sustainedBonus = data.respiratoryRateTrendDays >= 2 ? 1.3 : 1.0;
    
    riskScore += weight * sustainedBonus;
    
    signals.push({
      metric: 'Respiratory Rate',
      severity,
      message: `Breathing rate elevated at ${data.respiratoryRate} breaths/min`,
      weight: weight * sustainedBonus
    });
  }
  
  // ... rest of detection logic ...
}
```

---

*Document Version: 3.5 — Canonical Pipeline + Cross-Domain Fixes + Zone Boundary + HRV Aggregation*
*Last Updated: February 16, 2026*
*Data Sources: Apple Watch, Nutrition Logs, Bioimpedance, Self-Reported Wellness, Medical Labs*
*Audit Status: All P1 and P2 recommendations implemented ✅ | Cross-domain audit fixes applied ✅*

### Audit Implementation Summary

| Issue ID | Priority | Description | Status |
|----------|----------|-------------|--------|
| P1-001 | High | HRV 60s minimum validation | ✅ Implemented |
| P1-002 | High | EWMA λ values documented | ✅ Implemented |
| P2-001 | Medium | SpO2 apnea disclaimer | ✅ Implemented |
| P2-002 | Medium | Sleep stage accuracy caveat | ✅ Implemented |
| P2-003 | Medium | Bayesian N-of-1 methods | ✅ Implemented |
| P2-004 | Medium | Chronotype meal timing | ✅ Implemented |
| P2-005 | Medium | Validation metric targets | ✅ Implemented |
| P2-006 | Medium | Respiratory rate weight | ✅ Implemented |
| Citation | Minor | Tanaka (2001) HR max | ✅ Added |
| Citation | Minor | Drake (2013) caffeine | ✅ Added |
| Citation | Minor | Williams (2017) EWMA | ✅ Added |
| Citation | Minor | Van Dongen (2003) sleep | ✅ Added |

---

## 24. RECOMMENDATION FEEDBACK LOOP

### Overview

Every recommendation the system generates must be tracked for outcome evaluation. This closes the loop between "we suggested X" and "did X actually help?" — enabling personalized weight calibration over time.

> **"Without a feedback loop, even a well-designed algorithm is just an educated guess that never learns."**

### Schema

```sql
-- Tracks whether recommendations were followed and their measurable outcomes
CREATE TABLE recommendation_outcomes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id),
    recommendation_id UUID NOT NULL REFERENCES recommendations(id),

    -- What was recommended
    recommendation_type TEXT NOT NULL, -- 'training_volume', 'nutrition', 'sleep', 'supplement', 'recovery'
    recommendation_action TEXT NOT NULL, -- e.g., 'reduce_volume_30', 'add_protein_post_workout', 'sleep_earlier_30min'

    -- Was it followed?
    action_taken BOOLEAN, -- null = unknown, true = followed, false = ignored
    action_taken_at TIMESTAMPTZ,

    -- Pre-recommendation metrics (snapshot at time of recommendation)
    pre_recovery_score NUMERIC(5,2),
    pre_sleep_score NUMERIC(5,2),
    pre_hrv_score NUMERIC(5,2),
    pre_nutrition_modifier NUMERIC(4,3),

    -- Post-recommendation metrics (24-48h after)
    post_recovery_score NUMERIC(5,2),
    post_sleep_score NUMERIC(5,2),
    post_hrv_score NUMERIC(5,2),
    post_nutrition_modifier NUMERIC(4,3),
    post_measured_at TIMESTAMPTZ,

    -- Derived outcome
    outcome_delta NUMERIC(5,2), -- post_recovery - pre_recovery
    outcome_quality TEXT CHECK (outcome_quality IN ('positive', 'neutral', 'negative')),

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_rec_outcomes_user_type ON recommendation_outcomes(user_id, recommendation_type);
CREATE INDEX idx_rec_outcomes_action ON recommendation_outcomes(recommendation_action);
```

### Outcome Evaluation Algorithm

```typescript
/**
 * Recommendation Feedback Loop
 *
 * After 24-48h, evaluate whether a recommendation improved metrics.
 * Accumulate outcomes over 2-4 weeks to generate personalized effectiveness scores.
 *
 * This data feeds back into:
 * 1. Recommendation priority ranking (effective ones surface first)
 * 2. Confidence scores (recommendations proven effective get higher confidence)
 * 3. Future weight calibration (see adaptiveWeights below)
 */
interface RecommendationOutcome {
  recommendationId: string;
  recommendationType: string;
  actionTaken: boolean;
  preDelta: {
    recovery: number;
    sleep: number;
    hrv: number;
  };
  postDelta: {
    recovery: number;
    sleep: number;
    hrv: number;
  };
  outcomeDelta: number;
  outcomeQuality: 'positive' | 'neutral' | 'negative';
}

async function evaluateRecommendationOutcome(
  userId: string,
  recommendationId: string,
  evaluationWindowHours: number = 48
): Promise<RecommendationOutcome> {
  const rec = await db.getRecommendation(recommendationId);
  const preMetrics = rec.pre_metrics;

  // Get metrics from evaluation window
  const postDate = new Date(rec.created_at);
  postDate.setHours(postDate.getHours() + evaluationWindowHours);
  const postMetrics = await db.getMetricsNearDate(userId, postDate);

  // Determine if action was taken (heuristic + explicit user feedback)
  const actionTaken = await inferActionTaken(userId, rec);

  const outcomeDelta = postMetrics.recovery - preMetrics.recovery;
  const outcomeQuality =
    outcomeDelta > 5 ? 'positive' :
    outcomeDelta < -5 ? 'negative' :
    'neutral';

  return {
    recommendationId,
    recommendationType: rec.type,
    actionTaken,
    preDelta: { recovery: preMetrics.recovery, sleep: preMetrics.sleep, hrv: preMetrics.hrv },
    postDelta: { recovery: postMetrics.recovery, sleep: postMetrics.sleep, hrv: postMetrics.hrv },
    outcomeDelta,
    outcomeQuality
  };
}

/**
 * Personalized Effectiveness Score per Recommendation Type
 *
 * After accumulating >= 10 outcomes for a recommendation type, calculate:
 *   effectiveness = (outcomes where followed AND positive) / (outcomes where followed)
 *
 * This is used to:
 * - Rank recommendations (higher effectiveness → higher priority)
 * - Suppress recommendations with effectiveness < 0.3 after 20+ observations
 * - Surface "this works for you" confirmations when effectiveness > 0.7
 */
async function calculateRecommendationEffectiveness(
  userId: string,
  recommendationType: string
): Promise<{ effectiveness: number; sampleSize: number; mature: boolean }> {
  const outcomes = await db.query(`
    SELECT outcome_quality, action_taken
    FROM recommendation_outcomes
    WHERE user_id = $1 AND recommendation_type = $2 AND action_taken = TRUE
    ORDER BY created_at DESC
    LIMIT 30
  `, [userId, recommendationType]);

  const followed = outcomes.filter(o => o.action_taken);
  if (followed.length < 10) {
    return { effectiveness: 0.5, sampleSize: followed.length, mature: false }; // Prior
  }

  const positive = followed.filter(o => o.outcome_quality === 'positive').length;
  const effectiveness = positive / followed.length;

  return {
    effectiveness,
    sampleSize: followed.length,
    mature: followed.length >= 20
  };
}

/**
 * Adaptive Weight Calibration (V3+)
 *
 * After 60+ days of data with recommendation tracking, the system can
 * begin adjusting the composite recovery score weights per user.
 *
 * Method: For each component (HRV, Sleep, RHR, Temp), measure which
 * component changes best predict user-reported wellness the next day.
 * Shift weights toward components with higher predictive power for this user.
 *
 * Constraints:
 * - Each weight must stay within ±50% of default (e.g., HRV: 0.20-0.60)
 * - Weights must sum to 1.0
 * - Recalculate monthly with rolling 90-day window
 * - User can always reset to defaults
 */
interface AdaptiveWeights {
  hrv: number;    // default 0.40, range [0.20, 0.60]
  sleep: number;  // default 0.30, range [0.15, 0.45]
  rhr: number;    // default 0.15, range [0.08, 0.22]
  temp: number;   // default 0.15, range [0.08, 0.22]
  calibratedAt: Date;
  daysOfData: number;
  predictiveR2: number; // How well the weighted combo predicts next-day wellness
}
```

---

## 25. ENHANCED ILLNESS DETECTION (CROSS-DOMAIN)

### Nutrition-Aware Illness Signals

The base illness detection (Section 7) uses only physiological metrics. This enhanced version
incorporates nutrition behavioral signals as weak but meaningful indicators.

```typescript
/**
 * Enhanced Illness Detection with Nutrition Behavioral Signals
 *
 * Adds nutrition-based weak indicators to the physiological model:
 * - Sudden appetite drop (calories < 50% TDEE without intentional dieting)
 * - Hydration spike (unusual increase in water intake)
 * - Caffeine/alcohol pattern break (sudden cessation of habitual consumption)
 * - Food log absence (user who normally logs stops logging — may indicate feeling unwell)
 *
 * These signals alone are insufficient but strengthen the illness signal
 * when combined with physiological markers (HRV, RHR, temperature).
 */
interface NutritionIllnessSignal {
  metric: 'APPETITE_DROP' | 'HYDRATION_SPIKE' | 'HABIT_BREAK' | 'LOG_ABSENCE';
  severity: 'low' | 'moderate';
  message: string;
}

function detectNutritionIllnessSignals(
  recentNutrition: FoodLog[],  // Last 3 days
  historicalNutrition: FoodLog[], // Last 14 days for baseline
  userGoals: NutritionGoals,
  isOnDiet: boolean
): NutritionIllnessSignal[] {
  const signals: NutritionIllnessSignal[] = [];

  // Calculate recent and baseline averages
  const todayCalories = getDayCalories(recentNutrition, 0);
  const yesterdayCalories = getDayCalories(recentNutrition, -1);
  const baselineCalories = getAverageDayCalories(historicalNutrition, 14);
  const todayWaterMl = getDayWater(recentNutrition, 0);
  const baselineWaterMl = getAverageWater(historicalNutrition, 14);

  // 1. Appetite drop: sudden calorie reduction not explained by dieting
  if (!isOnDiet && todayCalories > 0 && todayCalories < baselineCalories * 0.50) {
    signals.push({
      metric: 'APPETITE_DROP',
      severity: 'moderate',
      message: `Calorie intake today (${Math.round(todayCalories)} kcal) is less than half ` +
        `your recent average (${Math.round(baselineCalories)} kcal). This can be an early illness sign.`
    });
  }

  // 2. Hydration spike: >40% above baseline (common when feeling unwell)
  if (todayWaterMl > 0 && baselineWaterMl > 0 && todayWaterMl > baselineWaterMl * 1.40) {
    signals.push({
      metric: 'HYDRATION_SPIKE',
      severity: 'low',
      message: `Water intake is ${Math.round((todayWaterMl / baselineWaterMl - 1) * 100)}% above ` +
        'your typical amount. Combined with other signals, this may indicate your body is fighting something.'
    });
  }

  // 3. Habit break: regular caffeine/alcohol consumer suddenly stops
  const baselineCaffeine = getAverageCaffeine(historicalNutrition, 14);
  const todayCaffeine = getDayCaffeine(recentNutrition, 0);
  if (baselineCaffeine > 100 && todayCaffeine === 0 && yesterdayCalories > 0) {
    signals.push({
      metric: 'HABIT_BREAK',
      severity: 'low',
      message: 'You typically consume caffeine but had none today. If this is unusual, ' +
        'it may reflect feeling unwell.'
    });
  }

  // 4. Log absence: user who logs consistently stops (>2 meals missed)
  const expectedMeals = 3;
  const todayLogs = recentNutrition.filter(l => isToday(l.loggedAt)).length;
  const avgDailyLogs = historicalNutrition.length / 14;
  if (avgDailyLogs >= 2.5 && todayLogs === 0 && isAfternoon()) {
    signals.push({
      metric: 'LOG_ABSENCE',
      severity: 'low',
      message: 'No food logged today despite your usual habit. If you\'re feeling unwell, rest is priority.'
    });
  }

  return signals;
}

/**
 * Integrate nutrition signals into the main illness risk calculation.
 * Nutrition signals are additive with low weight (max +15 to risk_index).
 */
function calculateEnhancedIllnessRisk(
  // Original physiological inputs
  hrvDeviationPercent: number,
  rhrDeviationBpm: number,
  wristTempDeviationC: number,
  respiratoryRate: number | null,
  trendDays: number,
  // New: nutrition behavioral context
  nutritionSignals: NutritionIllnessSignal[]
): IllnessRisk {
  // Calculate base physiological illness risk (Section 7 algorithm)
  const baseRisk = calculateIllnessRisk(
    hrvDeviationPercent, rhrDeviationBpm,
    wristTempDeviationC, respiratoryRate, trendDays
  );

  // Add nutrition signal contribution (capped at +15)
  let nutritionBoost = 0;
  for (const signal of nutritionSignals) {
    nutritionBoost += signal.severity === 'moderate' ? 8 : 4;
  }
  nutritionBoost = Math.min(15, nutritionBoost);

  // Only apply nutrition boost if at least one physiological signal exists
  if (baseRisk.signals.length > 0 && nutritionBoost > 0) {
    const enhancedIndex = Math.min(100, baseRisk.risk_index + nutritionBoost);
    const enhancedLevel: IllnessRisk['level'] =
      enhancedIndex >= 70 ? 'high' : enhancedIndex >= 40 ? 'moderate' : 'low';

    return {
      ...baseRisk,
      risk_index: enhancedIndex,
      level: enhancedLevel,
      signals: [
        ...baseRisk.signals,
        ...nutritionSignals.map(ns => ({
          metric: ns.metric as any,
          severity: ns.severity,
          message: ns.message
        }))
      ]
    };
  }

  return baseRisk;
}
```

---

## 26. TRAINING-LOAD-ADJUSTED SLEEP SCORING

### Sleep Need Increases with Training Load

Sleep research shows that heavy training increases sleep need by 30-60 minutes.
The base sleep score (Section 2) evaluates duration against a static target.
This enhancement dynamically adjusts the target based on yesterday's training load.

> **Reference:** Halson, S.L. (2014). "Sleep in Elite Athletes and Nutritional Interventions to Enhance Sleep."
> *Sports Medicine*, 44:S13-S23. [DOI: 10.1007/s40279-014-0147-0]

```typescript
/**
 * Adjust optimal sleep duration based on training load.
 *
 * When daily TRIMP exceeds the chronic (28-day) average by >= 30%,
 * sleep need is increased. This ensures the sleep score doesn't penalize
 * athletes who sleep 7.5h after a hard session when they'd normally
 * need only 7h on a rest day.
 *
 * Scale:
 *   TRIMP ratio 1.0 (normal day): +0 min
 *   TRIMP ratio 1.3 (hard day):   +15 min
 *   TRIMP ratio 1.5 (very hard):  +30 min
 *   TRIMP ratio 2.0+ (extreme):   +45 min (capped)
 */
function adjustSleepTargetForTraining(
  baseSleepTargetMinutes: number,
  dailyTrimp: number,
  chronicTrimp: number
): { adjustedTargetMinutes: number; adjustmentMinutes: number; reason: string | null } {
  if (chronicTrimp <= 0 || dailyTrimp <= 0) {
    return { adjustedTargetMinutes: baseSleepTargetMinutes, adjustmentMinutes: 0, reason: null };
  }

  const trimpRatio = dailyTrimp / chronicTrimp;

  if (trimpRatio < 1.3) {
    return { adjustedTargetMinutes: baseSleepTargetMinutes, adjustmentMinutes: 0, reason: null };
  }

  // Linear interpolation: ratio 1.3→2.0 maps to +15min→+45min
  const extraMinutes = Math.min(45, Math.round(lerp(trimpRatio, 1.3, 2.0, 15, 45)));

  return {
    adjustedTargetMinutes: baseSleepTargetMinutes + extraMinutes,
    adjustmentMinutes: extraMinutes,
    reason: `Training load was ${Math.round((trimpRatio - 1) * 100)}% above your average. ` +
      `Your sleep target is increased by ${extraMinutes} min for optimal recovery.`
  };
}

/**
 * Enhanced Sleep Score with training-load context
 *
 * Wraps the base calculateSleepScore() with a training-adjusted duration target.
 */
function calculateTrainingAwareSleepScore(
  sleepData: SleepData,
  baseline: SleepBaseline,
  age: number,
  yesterdayTrimp: number,
  chronicTrimp: number
): SleepScore {
  // Adjust the optimal duration target
  // baseline.optimalDuration is in HOURS; convert to minutes for adjustSleepTargetForTraining
  const baseSleepTargetMinutes = baseline.optimalDuration * 60;
  const { adjustedTargetMinutes, adjustmentMinutes, reason } =
    adjustSleepTargetForTraining(baseSleepTargetMinutes, yesterdayTrimp, chronicTrimp);

  // Create adjusted baseline with higher target (convert back to hours)
  const adjustedBaseline: SleepBaseline = {
    ...baseline,
    optimalDuration: adjustedTargetMinutes / 60
  };

  // Calculate score with adjusted target
  const score = calculateSleepScore(sleepData, adjustedBaseline, age);

  // Add training context insight
  if (reason) {
    score.insights.push(reason);
  }

  return score;
}
```

---

## 27. DYNAMIC WEIGHT FROM BODY COMPOSITION

### Rolling Weight Instead of Static Profile

All weight-dependent calculations (protein targets, caffeine, training adjustments) should use
the most recent reliable weight rather than the static onboarding value.

```typescript
/**
 * Get the effective weight for calculations.
 *
 * Priority:
 * 1. Rolling 7-day average from body_composition (if ≥ 2 measurements in last 14 days)
 * 2. Most recent single measurement from body_composition (if < 30 days old)
 * 3. Static users.weight_kg from profile (fallback)
 *
 * When the effective weight diverges from users.weight_kg by > 2kg,
 * a notification is queued to suggest the user update their profile.
 */
async function getEffectiveWeight(userId: string): Promise<{
  weightKg: number;
  source: 'rolling_7d' | 'latest_measurement' | 'profile';
  divergenceFromProfile: number;
  shouldUpdateProfile: boolean;
}> {
  // Try rolling 7-day average
  const recentMeasurements = await db.query(`
    SELECT weight_kg, measured_at
    FROM body_composition
    WHERE user_id = $1
      AND measured_at > NOW() - INTERVAL '14 days'
      AND weight_kg IS NOT NULL
    ORDER BY measured_at DESC
  `, [userId]);

  const profileWeight = await db.getProfileWeight(userId);

  if (recentMeasurements.length >= 2) {
    // Use 7-day rolling average (more stable than single measurements)
    const sevenDayMeasurements = recentMeasurements.filter(
      m => (Date.now() - new Date(m.measured_at).getTime()) <= 7 * 24 * 60 * 60 * 1000
    );
    const weights = (sevenDayMeasurements.length >= 2 ? sevenDayMeasurements : recentMeasurements)
      .map(m => m.weight_kg);
    const avgWeight = weights.reduce((s, w) => s + w, 0) / weights.length;
    const divergence = Math.abs(avgWeight - profileWeight);

    return {
      weightKg: Math.round(avgWeight * 10) / 10,
      source: 'rolling_7d',
      divergenceFromProfile: divergence,
      shouldUpdateProfile: divergence > 2
    };
  }

  // Try most recent single measurement
  const latest = await db.query(`
    SELECT weight_kg, measured_at
    FROM body_composition
    WHERE user_id = $1
      AND measured_at > NOW() - INTERVAL '30 days'
      AND weight_kg IS NOT NULL
    ORDER BY measured_at DESC
    LIMIT 1
  `, [userId]);

  if (latest.length > 0) {
    const divergence = Math.abs(latest[0].weight_kg - profileWeight);
    return {
      weightKg: latest[0].weight_kg,
      source: 'latest_measurement',
      divergenceFromProfile: divergence,
      shouldUpdateProfile: divergence > 2
    };
  }

  // Fallback to profile
  return {
    weightKg: profileWeight,
    source: 'profile',
    divergenceFromProfile: 0,
    shouldUpdateProfile: false
  };
}
```

### Integration Points

All functions that use `weightKg` must call `getEffectiveWeight()` instead of reading `userProfile.weight_kg` directly:

| Function | File | Change |
|----------|------|--------|
| `calculateProteinTarget()` | recovery_algorithms §10 | Use `getEffectiveWeight()` |
| `applyRecoveryNutritionAdjustment()` | recovery_algorithms §10 | Use `getEffectiveWeight()` |
| `estimateCaffeineRemainingMg()` | recovery_algorithms §10 | Indirect (via targets) |
| `calculateTRIMP()` fallback RPE | recovery_algorithms §9 | Use `getEffectiveWeight()` for weight-adjusted TRIMP |
| `postWorkoutTargets` | recovery_algorithms §10 | `protein = 0.4 * effectiveWeight` |
| Nutrition target calculation | health_ecosystem_expansion §1.3 | `weight_factor = clamp(effectiveWeight / 70, ...)` |

---

## 28. CROSS-DOMAIN COLD START BOOTSTRAPPING

### Population-Based Priors for New Users

For the first 5-14 days, personalized baselines are unavailable. Instead of showing
"insufficient data" or using arbitrary defaults, the system bootstraps from
population-based priors conditioned on age, sex, and self-reported activity level.

```typescript
/**
 * Population-Based Prior for HRV Baseline
 *
 * Reference data from Shaffer & Ginsberg (2017) and Nunan et al. (2010):
 * - Healthy adults (20-29): mean ln(RMSSD) ≈ 3.9, SD ≈ 0.5
 * - Healthy adults (30-39): mean ln(RMSSD) ≈ 3.7, SD ≈ 0.5
 * - Healthy adults (40-49): mean ln(RMSSD) ≈ 3.5, SD ≈ 0.5
 * - Healthy adults (50-59): mean ln(RMSSD) ≈ 3.3, SD ≈ 0.5
 * - Healthy adults (60+):   mean ln(RMSSD) ≈ 3.0, SD ≈ 0.5
 *
 * Note: Apple Watch provides SDNN, not RMSSD. Population priors for SDNN
 * are less well-established, so we use a proportional scaling.
 * These are PRIORS that get replaced quickly — not definitive baselines.
 */
interface PopulationPrior {
  metric: string;
  mean: number;
  sd: number;
  confidence: number; // Lower than personal baseline (typically 0.30-0.50)
  source: string;
}

function getPopulationPrior(
  metric: 'hrv' | 'rhr' | 'sleep_duration' | 'deep_sleep_pct',
  ageRange: string, // '20-29', '30-39', etc.
  sex: 'male' | 'female',
  activityLevel: 'sedentary' | 'light' | 'moderate' | 'active' | 'very_active'
): PopulationPrior {
  const priors = {
    hrv: {
      // ln(SDNN) priors by age range (both sexes combined; sex adjustment below)
      '18-29': { mean: 3.9, sd: 0.50 },
      '30-39': { mean: 3.7, sd: 0.50 },
      '40-49': { mean: 3.5, sd: 0.50 },
      '50-59': { mean: 3.3, sd: 0.50 },
      '60+':   { mean: 3.0, sd: 0.50 },
    },
    rhr: {
      '18-29': { mean: 68, sd: 8 },
      '30-39': { mean: 70, sd: 8 },
      '40-49': { mean: 72, sd: 8 },
      '50-59': { mean: 74, sd: 9 },
      '60+':   { mean: 72, sd: 9 },
    },
    sleep_duration: {
      // Hours — fairly consistent across ages
      '18-29': { mean: 7.2, sd: 0.8 },
      '30-39': { mean: 7.0, sd: 0.8 },
      '40-49': { mean: 6.8, sd: 0.9 },
      '50-59': { mean: 6.7, sd: 0.9 },
      '60+':   { mean: 6.5, sd: 1.0 },
    },
    deep_sleep_pct: {
      // Age-adjusted from Ohayon (2004), already used in Section 2
      '18-29': { mean: 20, sd: 4 },
      '30-39': { mean: 17, sd: 4 },
      '40-49': { mean: 14, sd: 4 },
      '50-59': { mean: 12, sd: 4 },
      '60+':   { mean: 9,  sd: 3 },
    }
  };

  const base = priors[metric]?.[ageRange] ?? priors[metric]?.['30-39'];
  let mean = base.mean;

  // Activity level adjustment for HRV and RHR
  if (metric === 'hrv') {
    const activityBonus = { sedentary: -0.2, light: -0.1, moderate: 0, active: 0.15, very_active: 0.25 };
    mean += activityBonus[activityLevel] ?? 0;
  }
  if (metric === 'rhr') {
    const activityBonus = { sedentary: 3, light: 1, moderate: 0, active: -4, very_active: -8 };
    mean += activityBonus[activityLevel] ?? 0;
  }

  return {
    metric,
    mean,
    sd: base.sd,
    confidence: 0.35, // Population prior is low-confidence
    source: 'population_prior'
  };
}

/**
 * Bayesian Baseline Transition
 *
 * Smoothly transitions from population prior to personal baseline as data accumulates.
 *
 * Formula (simplified Bayesian update):
 *   effective_mean = (prior_weight × prior_mean + data_weight × personal_mean) / (prior_weight + data_weight)
 *   effective_sd   = prior_sd × (prior_weight / (prior_weight + data_weight))
 *
 * Where:
 *   prior_weight = max(0, 7 - daysOfData) / 7    (decays to 0 after 7 days)
 *   data_weight  = min(1, daysOfData / 7)         (grows to 1 after 7 days)
 *
 * After 7 days, the personal baseline fully replaces the prior.
 * After 5 days with at least 3 valid measurements, the confidence crosses 0.65 threshold.
 */
function computeTransitionalBaseline(
  populationPrior: PopulationPrior,
  personalMeasurements: number[],
  daysOfData: number
): { mean: number; sd: number; confidence: number; source: 'prior' | 'transitional' | 'personal' } {
  if (daysOfData === 0 || personalMeasurements.length === 0) {
    return {
      mean: populationPrior.mean,
      sd: populationPrior.sd,
      confidence: populationPrior.confidence,
      source: 'prior'
    };
  }

  const priorWeight = Math.max(0, (7 - daysOfData) / 7);
  const dataWeight = Math.min(1, daysOfData / 7);
  const personalMean = personalMeasurements.reduce((s, v) => s + v, 0) / personalMeasurements.length;
  const personalSd = calculateStdDev(personalMeasurements);

  if (priorWeight <= 0) {
    // Full personal baseline
    return {
      mean: personalMean,
      sd: personalSd > 0 ? personalSd : populationPrior.sd * 0.5,
      confidence: Math.min(0.90, 0.50 + daysOfData * 0.05),
      source: 'personal'
    };
  }

  // Blended transitional baseline
  const effectiveMean = (priorWeight * populationPrior.mean + dataWeight * personalMean) / (priorWeight + dataWeight);
  const effectiveSd = populationPrior.sd * (priorWeight / (priorWeight + dataWeight)) +
                      (personalSd > 0 ? personalSd : populationPrior.sd) * (dataWeight / (priorWeight + dataWeight));

  return {
    mean: effectiveMean,
    sd: effectiveSd,
    confidence: Math.min(0.75, populationPrior.confidence + daysOfData * 0.06),
    source: 'transitional'
  };
}
```

### First-Week Micro-Challenges

To accelerate data collection during cold start, the system issues targeted micro-challenges:

| Day | Challenge | Purpose |
|-----|-----------|---------|
| 1 | "Wear your watch to sleep tonight" | Get first HRV/sleep data point |
| 2 | "Log all 3 meals today" | Establish nutrition baseline |
| 3 | "Complete the morning wellness check" | Calibrate subjective data |
| 4 | "Log your workout (or rest day)" | Start TRIMP baseline |
| 5 | "Take a 5-question chronotype quiz" | Personalize timing recommendations |
| 6 | "Log your water intake today" | Hydration baseline |
| 7 | "Review your first weekly summary" | Engagement + data completeness check |

### Cold-Start Integration with Main Pipeline

The transitional baselines from this section MUST be used by `calculateComprehensiveRecoveryScore()` (Section 13) during the cold-start window (days 0–7). The server-side baseline resolution function ensures this:

```typescript
/**
 * Resolve the effective baseline for a metric.
 *
 * This is the single entry point that Section 13 should use for baselines.
 * It transparently handles cold-start → transitional → personal transitions.
 */
async function resolveBaseline(
  userId: string,
  metric: 'hrv' | 'rhr' | 'sleep_duration' | 'deep_sleep_pct',
  personalMeasurements: number[],
  daysOfData: number,
  userProfile: UserProfile
): Promise<{ mean: number; sd: number; confidence: number; source: string }> {
  // If enough personal data exists, skip population prior entirely
  if (daysOfData >= 7 && personalMeasurements.length >= 5) {
    const mean = calculateMean(personalMeasurements);
    const sd = calculateStdDev(personalMeasurements, mean);
    return {
      mean,
      sd: sd > 0 ? sd : 1.0,
      confidence: Math.min(0.95, 0.50 + daysOfData * 0.05),
      source: 'personal'
    };
  }

  // Cold-start or transitional: blend population prior with personal data
  const ageRange = getAgeRange(userProfile.age); // '18-29', '30-39', etc.
  const prior = getPopulationPrior(
    metric,
    ageRange,
    userProfile.sex ?? 'male',
    userProfile.activityLevel ?? 'moderate'
  );

  return computeTransitionalBaseline(prior, personalMeasurements, daysOfData);
}
```

**Wiring into Section 13:**

When `baselines.daysOfData < 7`, the `calculateComprehensiveRecoveryScore()` function uses `resolveBaseline()` to provide the HRV, RHR, sleep, and deep-sleep baselines that are passed to the component scoring functions. This ensures:

1. **Day 0–1**: Population priors drive scoring (confidence ~0.35)
2. **Day 2–6**: Bayesian blend transitions toward personal data (confidence ~0.50–0.65)
3. **Day 7+**: Full personal baselines (confidence ≥0.65)

The `confidence` field from `resolveBaseline()` feeds into `calculateComposedConfidence()` to ensure the recovery score surfaces appropriate review prompts during the cold-start window.

---

## 29. SUPPLEMENT-BIOMARKER EFFECTIVENESS TRACKING

### Automated Pre/Post Comparison

When a user logs a new lab result, the system automatically checks whether any
active supplements correspond to changed biomarkers.

```typescript
/**
 * Supplement-Biomarker Effectiveness Tracker
 *
 * Maps supplements to their expected biomarker impacts,
 * and automatically evaluates effectiveness when new lab results arrive.
 */
interface SupplementBiomarkerLink {
  supplementId: string;
  supplementName: string;
  markerId: string;
  markerName: string;
  expectedDirection: 'increase' | 'decrease';
  typicalTimeToEffectWeeks: number; // 4-12 weeks for most supplements
}

const SUPPLEMENT_MARKER_MAP: SupplementBiomarkerLink[] = [
  { supplementId: 'vitamin_d3', supplementName: 'Vitamin D3', markerId: 'vitamin_d_25oh',
    markerName: '25(OH) Vitamin D', expectedDirection: 'increase', typicalTimeToEffectWeeks: 8 },
  { supplementId: 'iron_bisglycinate', supplementName: 'Iron', markerId: 'ferritin',
    markerName: 'Ferritin', expectedDirection: 'increase', typicalTimeToEffectWeeks: 8 },
  { supplementId: 'omega3', supplementName: 'Omega-3', markerId: 'crp',
    markerName: 'CRP', expectedDirection: 'decrease', typicalTimeToEffectWeeks: 12 },
  { supplementId: 'magnesium', supplementName: 'Magnesium', markerId: 'magnesium_serum',
    markerName: 'Serum Magnesium', expectedDirection: 'increase', typicalTimeToEffectWeeks: 6 },
  { supplementId: 'b12', supplementName: 'Vitamin B12', markerId: 'vitamin_b12',
    markerName: 'Vitamin B12', expectedDirection: 'increase', typicalTimeToEffectWeeks: 8 },
  { supplementId: 'zinc', supplementName: 'Zinc', markerId: 'zinc_serum',
    markerName: 'Serum Zinc', expectedDirection: 'increase', typicalTimeToEffectWeeks: 8 },
  { supplementId: 'ashwagandha', supplementName: 'Ashwagandha', markerId: 'cortisol_am',
    markerName: 'Morning Cortisol', expectedDirection: 'decrease', typicalTimeToEffectWeeks: 8 },
];

interface SupplementEffectivenessResult {
  supplementName: string;
  markerName: string;
  preValue: number;
  postValue: number;
  unit: string;
  change: number;
  changePercent: number;
  expectedDirection: 'increase' | 'decrease';
  directionMatch: boolean; // Did the marker move in the expected direction?
  daysSinceStart: number;
  withinExpectedTimeframe: boolean;
  assessment: 'effective' | 'too_early' | 'no_change' | 'unexpected';
  insight: string;
}

/**
 * Evaluate supplement effectiveness when a new lab result arrives.
 *
 * Automatically compares the new marker value with the pre-supplement baseline
 * (the most recent measurement before the supplement was started).
 */
async function evaluateSupplementEffectiveness(
  userId: string,
  newLabResult: { markerId: string; value: number; unit: string; measuredAt: Date }
): Promise<SupplementEffectivenessResult[]> {
  const results: SupplementEffectivenessResult[] = [];

  // Find active supplements linked to this marker
  const links = SUPPLEMENT_MARKER_MAP.filter(l => l.markerId === newLabResult.markerId);
  if (links.length === 0) return results;

  for (const link of links) {
    // Check if user is taking this supplement
    const supplement = await db.query(`
      SELECT us.id, us.started_at, us.adherence_percent
      FROM user_supplements us
      WHERE us.user_id = $1 AND us.supplement_id = $2
        AND us.stopped_at IS NULL
        AND us.started_at IS NOT NULL
    `, [userId, link.supplementId]);

    if (supplement.length === 0) continue;

    const startedAt = new Date(supplement[0].started_at);
    const daysSinceStart = Math.round(
      (newLabResult.measuredAt.getTime() - startedAt.getTime()) / (1000 * 60 * 60 * 24)
    );

    // Find pre-supplement baseline measurement
    const preMeasurement = await db.query(`
      SELECT value, unit, measured_at
      FROM health_measurements
      WHERE user_id = $1 AND marker_id = $2
        AND measured_at < $3
      ORDER BY measured_at DESC
      LIMIT 1
    `, [userId, link.markerId, startedAt]);

    if (preMeasurement.length === 0) continue; // No baseline to compare

    const preValue = preMeasurement[0].value;
    const postValue = newLabResult.value;
    const change = postValue - preValue;
    const changePercent = preValue > 0 ? (change / preValue) * 100 : 0;
    const expectedWeeks = link.typicalTimeToEffectWeeks;
    const withinTimeframe = daysSinceStart >= expectedWeeks * 7 * 0.5; // Allow half the typical time

    const directionMatch =
      (link.expectedDirection === 'increase' && change > 0) ||
      (link.expectedDirection === 'decrease' && change < 0);

    let assessment: SupplementEffectivenessResult['assessment'];
    let insight: string;

    if (!withinTimeframe) {
      assessment = 'too_early';
      insight = `You started ${link.supplementName} ${daysSinceStart} days ago. ` +
        `It typically takes ${expectedWeeks} weeks to see changes in ${link.markerName}. ` +
        'Keep taking it consistently and retest later.';
    } else if (Math.abs(changePercent) < 5) {
      assessment = 'no_change';
      insight = `${link.markerName} is essentially unchanged since starting ${link.supplementName} ` +
        `(${preValue} → ${postValue} ${newLabResult.unit}). ` +
        'Consider discussing dosage or formulation with a healthcare provider.';
    } else if (directionMatch) {
      assessment = 'effective';
      insight = `${link.supplementName} appears to be working: ${link.markerName} moved ` +
        `${link.expectedDirection === 'increase' ? 'up' : 'down'} by ` +
        `${Math.abs(changePercent).toFixed(0)}% (${preValue} → ${postValue} ${newLabResult.unit}).`;
    } else {
      assessment = 'unexpected';
      insight = `${link.markerName} moved in the opposite direction than expected with ` +
        `${link.supplementName} (${preValue} → ${postValue} ${newLabResult.unit}). ` +
        'This may be due to other factors. Consider discussing with a healthcare provider.';
    }

    results.push({
      supplementName: link.supplementName,
      markerName: link.markerName,
      preValue,
      postValue,
      unit: newLabResult.unit,
      change,
      changePercent,
      expectedDirection: link.expectedDirection,
      directionMatch,
      daysSinceStart,
      withinExpectedTimeframe: withinTimeframe,
      assessment,
      insight
    });
  }

  return results;
}
```

---

## 30. MODIFIER APPLICATION — TEMPORAL ORDERING GUARANTEE

### Modifier Composition Rule

All multiplicative modifiers in `calculateComprehensiveRecoveryScore()` (Section 13)
MUST be composed as a single product and clamped ONCE, not sequentially.

```typescript
/**
 * Modifier Composition (Canonical Rule)
 *
 * WRONG (sequential clamping — order-dependent, can silently absorb later modifiers):
 *   score *= clamp(nutrition, 0.85, 1.15)
 *   score *= clamp(bodyComp, 0.90, 1.10)
 *   score *= clamp(training, 0.88, 1.00)
 *
 * CORRECT (single product, single clamp):
 *   product = nutrition * bodyComp * training
 *   score *= clamp(product, GLOBAL_FLOOR, GLOBAL_CEILING)
 *
 * Global bounds:
 *   GLOBAL_FLOOR   = 0.60 (modifiers can reduce score by max 40%)
 *   GLOBAL_CEILING  = 1.25 (modifiers can boost score by max 25%)
 *
 * This ensures:
 * 1. No modifier is silently absorbed by an earlier clamp
 * 2. The final effect is independent of application order
 * 3. Edge cases are tested: e.g., nutrition=0.75 × training=0.88 = 0.66 → clamped to 0.60
 */
const MODIFIER_GLOBAL_FLOOR = 0.60;
const MODIFIER_GLOBAL_CEILING = 1.25;

function composeModifiers(modifiers: {
  nutrition: number;
  bodyComp: number;
  training: number;
  markers: number; // 1 + totalImpact from Section 16
}): { product: number; clamped: number; wasClipped: boolean } {
  const rawProduct =
    modifiers.nutrition *
    modifiers.bodyComp *
    modifiers.training *
    modifiers.markers;

  const clamped = Math.max(MODIFIER_GLOBAL_FLOOR, Math.min(MODIFIER_GLOBAL_CEILING, rawProduct));

  return {
    product: rawProduct,
    clamped,
    wasClipped: rawProduct !== clamped
  };
}
```

### Required Unit Tests

```yaml
MODIFIER_COMPOSITION_TESTS:
  - name: "All modifiers at default"
    input: { nutrition: 1.0, bodyComp: 1.0, training: 1.0, markers: 1.0 }
    expected_clamped: 1.0

  - name: "Multiple penalties stack but are floored"
    input: { nutrition: 0.75, bodyComp: 0.90, training: 0.88, markers: 0.90 }
    expected_raw: 0.5346
    expected_clamped: 0.60
    note: "Raw product is below floor; clamped to 0.60"

  - name: "Multiple bonuses stack but are ceilinged"
    input: { nutrition: 1.15, bodyComp: 1.10, training: 1.0, markers: 1.10 }
    expected_raw: 1.3915
    expected_clamped: 1.25

  - name: "Order independence"
    assertion: "composeModifiers({a,b,c,d}) === composeModifiers({d,c,b,a}) for all permutations"

  - name: "Marker penalty doesn't get absorbed"
    input: { nutrition: 0.80, bodyComp: 1.0, training: 0.88, markers: 0.92 }
    expected_raw: 0.64768
    expected_clamped: 0.64768
    note: "Raw product (0.80×1.0×0.88×0.92 = 0.64768) is above floor — all modifiers contribute"
```

---

## 31. REFERENCES & CITATIONS

### Primary Sources

1. **Shaffer, F. & Ginsberg, J.P.** (2017). "An Overview of Heart Rate Variability Metrics and Norms." *Frontiers in Public Health*, 5:258. [DOI: 10.3389/fpubh.2017.00258](https://doi.org/10.3389/fpubh.2017.00258)

2. **Plews, D.J., Laursen, P.B., Stanley, J., Kilding, A.E. & Buchheit, M.** (2013). "Training adaptation and heart rate variability in elite endurance athletes." *Int J Sports Physiol Perform*, 8(6):688-94. [DOI: 10.1123/ijspp.8.6.688](https://doi.org/10.1123/ijspp.8.6.688)

3. **Walker, M.** (2017). *Why We Sleep: Unlocking the Power of Sleep and Dreams*. Scribner. ISBN: 978-1501144318

4. **Buchheit, M.** (2014). "Monitoring training status with HR measures: do all roads lead to Rome?" *Front Physiol*, 5:73. [DOI: 10.3389/fphys.2014.00073](https://doi.org/10.3389/fphys.2014.00073)

5. **Smarr, B.L., Aschbacher, K., Fisher, S.M. et al.** (2020). "Feasibility of continuous fever monitoring using wearable devices." *Scientific Reports*, 10:21640. [DOI: 10.1038/s41598-020-78355-6](https://doi.org/10.1038/s41598-020-78355-6)

6. **Xie, L., Kang, H., Xu, Q. et al.** (2013). "Sleep drives metabolite clearance from the adult brain." *Science*, 342(6156):373-377. [DOI: 10.1126/science.1241224](https://doi.org/10.1126/science.1241224)

7. **Diekelmann, S. & Born, J.** (2010). "The memory function of sleep." *Nature Reviews Neuroscience*, 11:114-126. [DOI: 10.1038/nrn2762](https://doi.org/10.1038/nrn2762)

8. **Task Force of ESC & NASPE** (1996). "Heart rate variability: standards of measurement, physiological interpretation and clinical use." *Circulation*, 93(5):1043-1065. [DOI: 10.1161/01.CIR.93.5.1043](https://doi.org/10.1161/01.CIR.93.5.1043)

9. **Esco, M.R. & Flatt, A.A.** (2014). "Ultra-short-term heart rate variability indexes at rest and post-exercise in athletes." *Eur J Appl Physiol*, 114(11):2281-9. [DOI: 10.1007/s00421-014-2847-8](https://doi.org/10.1007/s00421-014-2847-8)

10. **Ohayon, M.M., Carskadon, M.A., Guilleminault, C. & Vitiello, M.V.** (2004). "Meta-analysis of quantitative sleep parameters from childhood to old age." *Sleep*, 27(7):1255-73. [DOI: 10.1093/sleep/27.7.1255](https://doi.org/10.1093/sleep/27.7.1255)

11. **Banister, E.W.** (1991). "Modeling elite athletic performance." *Physiological Testing of Elite Athletes*, 403-424.

12. **McNulty, K.L., Elliott-Sale, K.J., Dolan, E. et al.** (2020). "The Effects of Menstrual Cycle Phase on Exercise Performance in Eumenorrheic Women." *Sports Medicine*, 50:1813-1827. [DOI: 10.1007/s40279-020-01319-3](https://doi.org/10.1007/s40279-020-01319-3)

13. **Saw, A.E., Main, L.C. & Gastin, P.B.** (2015). "Monitoring the athlete training response: subjective self-reported measures trump commonly used objective measures." *Br J Sports Med*, 50:281-291. [DOI: 10.1136/bjsports-2015-094758](https://doi.org/10.1136/bjsports-2015-094758)

14. **Deci, E.L. & Ryan, R.M.** (2000). "The 'What' and 'Why' of Goal Pursuits: Human Needs and the Self-Determination of Behavior." *Psychological Inquiry*, 11(4):227-268. [DOI: 10.1207/S15327965PLI1104_01](https://doi.org/10.1207/S15327965PLI1104_01)

15. **Gottman, J.M.** (1994). *What Predicts Divorce? The Relationship Between Marital Processes and Marital Outcomes*. Lawrence Erlbaum Associates. ISBN: 978-0805814026

16. **Gabbett, T.J.** (2020). "Debunking the myths about training load, injury and performance." *Br J Sports Med*, 54:58-66. [DOI: 10.1136/bjsports-2019-101402](https://doi.org/10.1136/bjsports-2019-101402)

17. **Horne, J.A. & Östberg, O.** (1976). "A self-assessment questionnaire to determine morningness-eveningness in human circadian rhythms." *Int J Chronobiol*, 4(2):97-110. PMID: 1027738

18. **Baron, K.G. et al.** (2017). "Orthosomnia: Are Some Patients Taking the Quantified Self Too Far?" *J Clin Sleep Med*, 13(2):351-354. [DOI: 10.5664/jcsm.6472](https://doi.org/10.5664/jcsm.6472)

19. **Tanaka, H., Monahan, K.D. & Seals, D.R.** (2001). "Age-predicted maximal heart rate revisited." *J Am Coll Cardiol*, 37(1):153-156. [DOI: 10.1016/S0735-1097(00)01054-8](https://doi.org/10.1016/S0735-1097(00)01054-8)
    > *Used for HR max estimation: HR_max = 208 - (0.7 × age)*

20. **Drake, C., Roehrs, T., Shambroom, J. & Roth, T.** (2013). "Caffeine effects on sleep taken 0, 3, or 6 hours before going to bed." *J Clin Sleep Med*, 9(11):1195-1200. [DOI: 10.5664/jcsm.3170](https://doi.org/10.5664/jcsm.3170)
    > *Evidence for caffeine cutoff recommendations (6h half-life)*

21. **Williams, S., West, S., Cross, M.J. & Stokes, K.A.** (2017). "Better way to determine the acute:chronic workload ratio?" *Br J Sports Med*, 51:209-210. [DOI: 10.1136/bjsports-2016-096589](https://doi.org/10.1136/bjsports-2016-096589)
    > *EWMA methodology for ACWR calculation*

22. **Van Dongen, H.P., Maislin, G., Mullington, J.M. & Dinges, D.F.** (2003). "The cumulative cost of additional wakefulness." *Sleep*, 26(2):117-126. [DOI: 10.1093/sleep/26.2.117](https://doi.org/10.1093/sleep/26.2.117)
    > *Sleep debt accumulation model over 14-day window*

23. **Kitamura, S. et al.** (2016). "Estimating individual optimal sleep duration."

24. **Vandewalle, G. et al.** (2007). "HRV peaks during early morning sleep."

25. **Bonnemeier, H. et al.** (2003). "Circadian modulation of heart rate variability in healthy subjects."

26. **de Zambotti, M. et al.** (2019). "Wearable Sleep Technology in Clinical and Research Settings."

27. **Barron, M.L. & Fehring, R.J.** (2005). "Basal body temperature assessment."

28. **Massaroni, C. et al.** (2019). "Respiratory Rate Monitoring in Healthcare: A Comprehensive Review." *Sensors*, 19(2):386. [DOI: 10.3390/s19020386]

29. **Sutton, E.F. et al.** (2018). "Early Time-Restricted Feeding Improves Insulin Sensitivity, Blood Pressure, and Oxidative Stress Even without Weight Loss in Men with Prediabetes." *Cell Metabolism*, 27(6):1212-1221. [DOI: 10.1016/j.cmet.2018.04.010]

30. **Kruschke, J.K.** (2013). "Bayesian estimation supersedes the t test." *Journal of Experimental Psychology: General*, 142(2):573-603. [DOI: 10.1037/a0029146]

31. **Ebrahim, I.O. et al.** (2013). "Alcohol and Sleep I: Effects on Normal Sleep." *Alcoholism: Clinical and Experimental Research*, 37(4):539-549. [DOI: 10.1111/acer.12006]

32. **Sagawa, Y. et al.** (2011). "Alcohol has a dose-related effect on parasympathetic nerve activity during sleep." *Alcoholism: Clinical and Experimental Research*, 35(11):2093-2100. [DOI: 10.1111/j.1530-0277.2011.01558.x]

33. **Buchheit, M.** (2014). "Monitoring training status with HR measures: do all roads lead to Rome?" *Sports Medicine*, 44(Suppl 2):S195-S212. [DOI: 10.1007/s40279-014-0169-7]
    > *Note: Distinct from reference #4 (same author, same year, published in Frontiers in Physiology). This is the Sports Medicine review.*

34. **Halson, S.L.** (2014). "Sleep in Elite Athletes and Nutritional Interventions to Enhance Sleep." *Sports Medicine*, 44:S13-S23. [DOI: 10.1007/s40279-014-0147-0]
    > *Evidence for increased sleep need after heavy training loads (Section 26)*

35. **Nunan, D., Sandercock, G.R.H. & Brodie, D.A.** (2010). "A quantitative systematic review of normal values for short-term heart rate variability in healthy adults." *Pacing Clin Electrophysiol*, 33(11):1407-17. [DOI: 10.1111/j.1540-8159.2010.02841.x]
    > *Population HRV norms used for cold-start priors (Section 28)*

36. *(Merged with #32 — Sagawa et al. 2011 was listed twice; canonical DOI: 10.1111/j.1530-0277.2011.01558.x)*
    > *Evidence for alcohol as HRV confounder in training state detection (Section 9, context filters) — see reference #32*

---

## Appendix: Helper Function Specifications

> These utility functions are referenced throughout the recovery algorithms. Implementations MUST match these signatures and semantics.

### Statistical Utilities

#### `calculateMean(values: number[]): number`
Returns the arithmetic mean of the input array. Returns `0` if array is empty.

#### `calculateStdDev(values: number[], mean?: number): number`
Returns the population standard deviation. If `mean` is not provided, calculates it internally. Returns `0` if fewer than 2 values.

#### `removeOutliersIQR(values: number[], multiplier: number = 1.5): number[]`
Removes outliers using the Tukey IQR method. Values outside `[Q1 - multiplier*IQR, Q3 + multiplier*IQR]` are excluded. Returns filtered array.

#### `calculateTrend(values: number[]): 'improving' | 'declining' | 'stable'`
Calculates the trend direction over the input values (typically last 7 days). Uses simple linear regression slope. Threshold for "stable": slope magnitude < 0.01 * mean.

#### `calculatePercentile(value: number, distribution: number[]): number`
Returns the percentile rank (0–100) of `value` within the given distribution. Uses linear interpolation between ranks.

### Date & Time Utilities

#### `daysAgo(days: number): Date`
Returns a `Date` object representing `days` days before the current date (midnight local time).

#### `daysSince(timestamp: Date | string): number`
Returns the number of whole days elapsed since the given timestamp relative to the current date.

### HRV Baseline

#### `createPendingBaseline(): HRVBaseline`
Returns an incomplete HRV baseline object with `status: 'pending'`, `confidence: 0`, and empty rolling windows. Used when fewer than 14 days of HRV data are available.

### Sleep Analysis

#### `calculateDurationScore(actual_hours: number, optimal_hours: number): number`
Scores sleep duration 0–100. Score = 100 when `actual == optimal`, linearly decreasing. Scores below 50% or above 150% of optimal clamp to 0.

#### `calculateEfficiencyScore(time_asleep_min: number, time_in_bed_min: number): number`
Scores sleep efficiency 0–100. Efficiency = `time_asleep / time_in_bed * 100`. Score mapping: ≥90% → 100, ≥85% → 80, ≥80% → 60, <80% → linear decline to 0.

#### `calculateContinuityScore(awakenings: number, total_sleep_min: number): number`
Scores sleep continuity 0–100 based on awakening frequency. Fewer awakenings relative to sleep duration = higher score. Benchmark: 0 awakenings → 100, >5 per 8h → 20.

#### `calculateDebtPenalty(recent_logs: SleepLog[], optimal_duration_hours: number): number`
Returns a penalty factor (0–1) based on accumulated sleep debt over the last 7 days. 0 = no debt, 1 = severe debt (>4h cumulative deficit).

#### `generateSleepInsights(analysis: SleepAnalysis): SleepInsight[]`
Generates an array of actionable sleep insights based on the composite analysis. Insights include duration adequacy, efficiency trends, consistency patterns, and chronotype alignment.

### Temperature & Illness Detection

#### `analyzeTemperatureTrend(readings: TemperatureReading[], window_days: number): TemperatureTrend`
Analyzes wrist temperature deviations over the specified window. Returns trend direction, magnitude, and confidence. Deviations >0.5°C above baseline for 2+ days flag potential illness.

#### `generateIllnessRecommendation(signals: IllnessSignals): Recommendation`
Generates a recommendation when illness risk is elevated. Considers temperature trend, HRV suppression, resting HR elevation, and sleep quality decline. Always includes "consult your clinician" caveat.

### Nutrition & Training

#### `getNutritionSummary(nutrition_logs: FoodLog[], day_offset: number): NutritionSummary`
Fetches aggregated nutrition data (calories, protein, carbs, fat, hydration, alcohol units, caffeine mg, last caffeine timestamp) for `day_offset` days ago from the current date. Returns null if no data logged.

#### `findMealAfterWorkout(nutrition_logs: FoodLog[], workout_end_time: Date, window_minutes: number = 120): Meal | null`
Searches for the first meal logged within `window_minutes` after a workout ends. Used for post-workout nutrition analysis.

### Stress & Wellness

#### `countConsecutiveStressDays(wellness_checks: WellnessCheck[]): number`
Counts the number of consecutive days where `stress_level >= 4` (on a 1-5 scale), counting backward from the most recent entry.

#### `generateStressRecommendations(stress_data: StressAnalysis): Recommendation[]`
Generates stress management recommendations based on consecutive stress days, HRV trends, and sleep quality. Recommendations escalate with duration (3+ days: suggest rest; 7+ days: suggest professional support).

#### `generateWellnessAlerts(wellness_data: WellnessData): WellnessAlert[]`
Generates alerts from wellness check patterns. Detects sustained low mood, high stress, poor energy, and declining trends. Each alert includes severity and suggested action.

### Validation & Formatting

#### `formatValidationQuestion(metric: string, value: number, context: string): string`
Formats a user-facing validation question when an AI-generated insight needs human confirmation. Returns a natural-language question suitable for a review dialog.

### REMs Score

#### `calculateREMScore(rem_minutes: number, total_sleep_minutes: number, age: number): number`
Scores REM sleep adequacy 0–100. Target REM% varies by age bracket (younger adults: ~25%, older adults: ~20%). Score = 100 when actual% matches target, declining linearly on either side.

### Recovery Pipeline Orchestration

#### `generatePrioritizedRecommendations(context: RecoveryContext): Recommendation[]`
Generates an ordered list of actionable recommendations based on the complete recovery context (score, component scores, modifiers). Recommendations are sorted by priority: `high` → `medium` → `low`. Max 5 recommendations returned. Each recommendation includes `category`, `priority`, `confidence`, `actionText`, and `rationale`.

#### `collectAlerts(data: { hrvScore: HRVScore; sleepScore: SleepScore; tempScore: TemperatureScore; trainingLoad: TrainingLoad; illnessRisk?: IllnessRisk }): Alert[]`
Aggregates alerts from all component scorers (e.g., HRV suppression, sleep debt, illness risk, overtraining). Returns deduplicated alerts sorted by severity. Alerts with `illnessRisk.level >= 'moderate'` are always included first.

#### `getCachedOrCalculate<T>(cacheKey: string, computeFn: () => Promise<T>, ttlMs: number): Promise<T>`
Generic caching wrapper. Returns cached value if exists and not expired; otherwise calls `computeFn`, caches the result for `ttlMs` milliseconds, and returns it. Used for slow-changing data like biomarker impacts (24h TTL).

### Training Load Utilities

#### `analyzeTrend(values: number[]): 'improving' | 'declining' | 'stable'`
Analyzes the trend of daily training loads over the input window. Uses linear regression slope normalized by the mean. Alias for the generic `calculateTrend()` utility; exists for semantic clarity in the training domain.

### Nutrition Illness Signal Helpers (Section 25)

#### `getDayCalories(logs: FoodLog[], dayOffset: number): number`
Returns total calories for the day at `dayOffset` (0 = today, -1 = yesterday). Returns `0` if no logs.

#### `getAverageDayCalories(logs: FoodLog[], windowDays: number): number`
Returns the mean daily calorie intake over the last `windowDays`. Excludes days with zero logs to avoid skewing.

#### `getDayWater(logs: FoodLog[], dayOffset: number): number`
Returns total water intake in mL for the specified day.

#### `getAverageWater(logs: FoodLog[], windowDays: number): number`
Returns mean daily water intake in mL over the specified window.

#### `getDayCaffeine(logs: FoodLog[], dayOffset: number): number`
Returns total caffeine in mg for the specified day.

#### `getAverageCaffeine(logs: FoodLog[], windowDays: number): number`
Returns mean daily caffeine intake in mg over the specified window.

#### `isToday(date: Date | string): boolean`
Returns `true` if the given date falls within the current calendar day (local timezone).

#### `isAfternoon(): boolean`
Returns `true` if the current local time is 14:00 or later. Used to assess whether missing food logs are meaningful (too early in the day = not meaningful).

### Cold-Start & Baseline Resolution (Section 28)

#### `resolveBaseline(userId: string, metric: string, personalMeasurements: number[], daysOfData: number, userProfile: UserProfile): Promise<BaselineResult>`
Single entry point for baseline resolution. Transparently handles population prior → transitional → personal transitions. See Section 28 for full implementation.

#### `getAgeRange(age: number): string`
Maps a numeric age to a string range: `'18-29'`, `'30-39'`, `'40-49'`, `'50-59'`, or `'60+'`.

### Interpolation

#### `lerp(value: number, inMin: number, inMax: number, outMin: number, outMax: number): number`
Linear interpolation. Maps `value` from range `[inMin, inMax]` to `[outMin, outMax]`. Values outside `inMin..inMax` are clamped to `outMin..outMax`. Used throughout to eliminate discrete step-function boundaries.

---

## 30) Recovery Zone Boundary Assignment (Canonical)

> [!IMPORTANT]
> This is the **single source of truth** for mapping a recovery score to a zone. All other documents reference this function.
> Boundaries: inclusive on the low end, exclusive on the high end, except Optimal which includes 100.
> Matches `life_os_invariants.md` §1.

```typescript
type RecoveryZone = 'critical' | 'caution' | 'ready' | 'optimal';

/**
 * Canonical zone assignment function.
 * Invariant: score ∈ [0, 100] (clamped).
 * 
 * Zone boundaries:
 *   critical:  0 ≤ score < 25
 *   caution:  25 ≤ score < 50
 *   ready:    50 ≤ score < 75
 *   optimal:  75 ≤ score ≤ 100
 */
function assignRecoveryZone(score: number): RecoveryZone {
  const clamped = Math.max(0, Math.min(100, Math.round(score)));
  
  if (clamped < 25) return 'critical';
  if (clamped < 50) return 'caution';
  if (clamped < 75) return 'ready';
  return 'optimal';
}
```

### Unit Test Expectations (Boundary Values)

| Input Score | Expected Zone | Rationale |
|-------------|---------------|----------|
| 0 | `critical` | Minimum valid score |
| 12 | `critical` | Mid-range critical |
| 24 | `critical` | Upper bound of Critical (< 25) |
| 24.6 | `critical` | Rounds to 25 → still `critical`? No: `round(24.6) = 25` → `caution`. See note below. |
| 25 | `caution` | Lower bound of Caution (inclusive) |
| 49 | `caution` | Upper bound of Caution (< 50) |
| 50 | `ready` | Lower bound of Ready (inclusive) |
| 74 | `ready` | Upper bound of Ready (< 75) |
| 75 | `optimal` | Lower bound of Optimal (inclusive) |
| 100 | `optimal` | Maximum valid score (inclusive) |
| -5 | `critical` | Below range → clamped to 0 |
| 105 | `optimal` | Above range → clamped to 100 |

> [!NOTE]
> The score is **rounded** before zone assignment. This means a raw score of 24.6 rounds to 25 and becomes `caution`, not `critical`. All upstream computations should be aware that the final zone boundary operates on the rounded integer.

---

## 31) HRV Aggregation Rules (Cross-Reference)

> **Source of truth for HRV sample aggregation:** `life_os_healthkit_spec.md` § HRV Aggregation.

When this document's algorithms reference "today's HRV value", the following aggregation rules from the HealthKit spec apply:

| Sample Count (per day) | Aggregation Method | Rationale |
|------------------------|-------------------|----------|
| ≥ 3 samples | **Median** | Robust to outliers from motion artifacts |
| 1–2 samples | **Mean** (arithmetic) | Insufficient data for robust median |
| 0 samples | **Missing** (`null`) | Data completeness drops; confidence reduced per §4 |

**Implementation note:** The HRV score computation in §2 (`scoreHRV`) receives a single aggregated value. The aggregation step (median vs mean) is performed **before** the value reaches this pipeline. Implementers must use the aggregation logic from `life_os_healthkit_spec.md`, not a simple average.

**Confidence impact:** When only 1–2 HRV samples are available for a day, the data completeness score (§4) should reflect this via the `hrv_data_points` contributing factor. A day with 1 sample is less reliable than a day with 5+ samples.

