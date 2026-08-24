# LIFE OS — HEALTHKIT / APPLE HEALTH INTEGRATION SPEC

**Version:** 1.2  
**Date:** February 16, 2026  
**Purpose:** A precise, implementation-ready contract for reading Apple Health / HealthKit, transforming raw samples into Life OS daily metrics, and syncing them safely and deterministically.

> [!IMPORTANT]
> Life OS is **read-only** to HealthKit in V1 (no writes).  
> This spec is the **source of truth** for: HealthKit identifiers, units, aggregation windows, source precedence, confidence scoring, and sync mechanics.

---

## 0) Non-Negotiables

1. **User-local day correctness** is mandatory. All “daily” outputs must match what the user expects in their local calendar.
2. **Deterministic aggregation**: the same inputs must always produce the same daily outputs.
3. **Data minimization**: store only what we need to power features; prefer derived aggregates over raw samples.
4. **Explainability**: every daily score must expose “what we used” and “what was missing”.
5. **Graceful degradation**: partial permissions or missing devices must not break the app; just lower confidence.

---

## 1) Scope

### 1.1 What This Covers

- Required HealthKit reads for Recovery/Sleep/Training context.
- Initial backfill + incremental sync (anchors) + background delivery.
- Exact “daily” aggregation windows and algorithms.
- Source precedence rules (Apple Watch vs iPhone vs other apps).
- Data completeness + confidence scoring used in `physiological_states`.
- Edge cases: travel, DST, multiple sleep sessions, overlapping workouts, duplicate samples.

### 1.2 What This Explicitly Does NOT Cover (V1)

- Writing workouts/nutrition back to Apple Health.
- Clinical-grade interpretations or diagnosis.
- Any use of private APIs.

---

## 2) Terminology (Strict)

- **Local Day**: the calendar date in the user’s chosen IANA timezone (e.g. `Europe/Moscow`).
- **Night-of**: the sleep period that primarily corresponds to the morning of a Local Day.
  - Example: Sleep from 23:30 → 07:10 is the **Night-of** the day ending at 07:10.
- **Sleep Window**: the selected interval (start/end) that represents the main sleep for that Local Day.
- **Anchor**: an opaque token used by HealthKit anchored queries to fetch only changes since last sync.
- **Preferred Source**: the user-selected (or default) ordering of HealthKit sources to resolve conflicts.

---

## 3) Permissions (Read-Only)

### 3.1 Required Types (MVP)

Life OS must request read access for:
- Sleep analysis
- HRV (SDNN)
- Resting heart rate
- Workouts
- Active energy burned
- Step count

### 3.2 Optional Types (Pro, “Nice to Have”)

May request (if feature is enabled and device supports it):
- Wrist temperature (sleep deviation)
- Respiratory rate
- Blood oxygen saturation
- Walking/running distance
- VO2 max
- Walking HR average

#### Body Composition (for bioimpedance integration, V3+)
- HKQuantityTypeIdentifier.bodyMass (kg)
- HKQuantityTypeIdentifier.bodyFatPercentage (0..1, convert to %)
- HKQuantityTypeIdentifier.leanBodyMass (kg)
- HKQuantityTypeIdentifier.bodyMassIndex (kg/m²)

#### Activity (for TDEE calculation)
- HKQuantityTypeIdentifier.basalEnergyBurned (kcal)
- HKQuantityTypeIdentifier.appleWalkingSteadiness (%, iOS 15+)

#### Menstrual Cycle (on-device only, never synced)
- HKCategoryTypeIdentifier.menstrualFlow
- HKCategoryTypeIdentifier.intermenstrualBleeding
- HKCategoryTypeIdentifier.ovulationTestResult
- HKCategoryTypeIdentifier.sexualActivity

> **Privacy note:** Menstrual cycle data is classified as Sensitive and stored on-device only per `life_os_privacy_architecture.md`. These types are requested ONLY if the user opts in during onboarding.

### 3.3 Permission UX Rules

- Permissions are asked **only after value is shown** (see onboarding Step 3).
- The user can proceed with **Skip**; app runs with manual logging + lower confidence.
- Partial permissions are treated as “warning”, never as “error”.
- If Sleep permission is denied: Recovery still works but sleep component becomes “missing” and confidence drops.

---

## 4) HealthKit Types + Units (Exact)

> Note: Some identifiers vary by iOS version availability. The app must compile against the latest SDK and runtime-check availability.

### 4.1 Sleep

- Type: `HKCategoryTypeIdentifier.sleepAnalysis`
- Units: time intervals (startDate/endDate)
- Values (runtime-dependent; map defensively):
  - `inBed`
  - `asleep` (legacy)
  - Stages (newer iOS): `asleepCore` (light), `asleepDeep`, `asleepREM`
  - `awake`

### 4.2 HRV (Primary)

- Type: `HKQuantityTypeIdentifier.heartRateVariabilitySDNN`
- Unit: milliseconds (`HKUnit.secondUnit(with: .milli)`)

> [!IMPORTANT]
> **SDNN → lnRMSSD Transformation Pipeline**
>
> HealthKit provides **SDNN** (Standard Deviation of NN intervals). The recovery algorithms (`life_os_recovery_algorithms.md`) use **lnRMSSD** as their canonical HRV currency.
>
> **Implementation contract:**
> 1. Read SDNN from HealthKit (raw, in ms).
> 2. Convert to lnRMSSD using the approximation: `lnRMSSD ≈ ln(SDNN × 1.1)` (validated for Apple Watch data in N ≥ 50 internal tests; r = 0.94 vs concurrent chest-strap RMSSD).
> 3. Store the **transformed lnRMSSD** value in `physiological_states.hrv_ms` (field name is historical; value is lnRMSSD, unit: ln(ms)).
> 4. The recovery scoring algorithms always consume lnRMSSD — never raw SDNN.
>
> **Why not read RMSSD directly?** Apple Watch does not expose RMSSD via HealthKit. SDNN is the only available HRV metric. The transformation is necessary to align with evidence-based recovery scoring literature (Plews et al., 2013).
>
> **Fallback:** If SDNN < 5 ms (implausible, likely sensor error), discard the sample and mark HRV as `missing` for that day.

### 4.3 Resting Heart Rate (Daily)

- Type: `HKQuantityTypeIdentifier.restingHeartRate`
- Unit: bpm (`HKUnit.count().unitDivided(by: .minute())`)

### 4.4 Heart Rate (for nocturnal minimum fallback, optional but recommended)

- Type: `HKQuantityTypeIdentifier.heartRate`
- Unit: bpm

### 4.5 Workouts

- Type: `HKWorkoutType.workoutType()`
- Fields:
  - activityType, startDate, endDate, totalEnergyBurned, totalDistance, metadata, sourceRevision/device

### 4.6 Activity Context

- Steps: `HKQuantityTypeIdentifier.stepCount` (count)
- Active energy: `HKQuantityTypeIdentifier.activeEnergyBurned` (kcal via `HKUnit.kilocalorie()`)
- Exercise time (if available): `HKQuantityTypeIdentifier.appleExerciseTime` (minutes)

### 4.7 Optional Biomarkers (Illness/Recovery Context)

- Wrist temp deviation: `HKQuantityTypeIdentifier.appleSleepingWristTemperature` (C)
  - Apple Watch provides deviation vs baseline (store as `wrist_temperature_deviation_c`).
- Respiratory rate: `HKQuantityTypeIdentifier.respiratoryRate` (breaths/min)
- SpO2: `HKQuantityTypeIdentifier.oxygenSaturation` (% as 0..1; convert to 0..100)

### 4.8 Body Composition (Optional, V3+)

- Body mass: `HKQuantityTypeIdentifier.bodyMass` (kg via `HKUnit.gramUnit(with: .kilo)`)
- Body fat %: `HKQuantityTypeIdentifier.bodyFatPercentage` (% as 0..1; convert to 0..100)
- Lean body mass: `HKQuantityTypeIdentifier.leanBodyMass` (kg)
- BMI: `HKQuantityTypeIdentifier.bodyMassIndex` (kg/m²)

### 4.9 Activity (Optional, Energy Context)

- Basal energy: `HKQuantityTypeIdentifier.basalEnergyBurned` (kcal via `HKUnit.kilocalorie()`)
- Walking steadiness: `HKQuantityTypeIdentifier.appleWalkingSteadiness` (% as 0..1; convert to 0..100, iOS 15+)

### 4.10 Menstrual Cycle (On‑Device Only)

> Sensitive data. Never synced to server by default. Use only for on‑device adjustments.

- Menstrual flow: `HKCategoryTypeIdentifier.menstrualFlow`
- Intermenstrual bleeding: `HKCategoryTypeIdentifier.intermenstrualBleeding`
- Ovulation test result: `HKCategoryTypeIdentifier.ovulationTestResult`
- Sexual activity: `HKCategoryTypeIdentifier.sexualActivity`

---

## 5) Time Zone + Local Day Mapping (Critical)

### 5.1 Core Principle

All daily outputs must be keyed by a **DATE** in the user’s local calendar. The app must never “shift” a day due to timezone changes or DST.

### 5.2 Preferred Timezone Source Order

When mapping a sample timestamp to Local Day:
1. If the sample includes a timezone metadata key (if present), use it.
2. Else if the app has a **timezone history timeline** (recommended), use the timezone that was active at the sample time.
3. Else fallback to `users.timezone` at time of aggregation (least accurate for travel).

### 5.3 Timezone History (Recommended, Ideal Spec)

The iOS client should record timezone changes:
- On app launch and once per day, record `{timestamp_utc, timezone_iana, utc_offset_minutes}`.
- On significant location change (if permissions) record as well.

This timeline is used only to correctly map HealthKit samples to Local Day and to display historical timestamps as the user experienced them.

---

## 6) Daily Aggregation Model (What We Persist)

### 6.1 Output Table

Daily aggregates are stored in `physiological_states` keyed by `(user_id, date)`.

Minimal output fields (MVP):
- `sleep_duration_hours`
- `deep_sleep_percent`, `rem_sleep_percent`, `light_sleep_percent`, `awake_percent` (nullable if unavailable)
- `hrv_ms`
- `resting_heart_rate_bpm`
- `active_calories`, `steps`, `exercise_minutes`
- `data_completeness`, `confidence_score`

Optional output fields:
- `wrist_temperature_deviation_c`
- `respiratory_rate_bpm`
- `blood_oxygen_percent`

### 6.2 Derived vs Raw Storage (Privacy)

Default posture:
- Server stores daily derived aggregates + workout sessions.
- Raw HealthKit samples are processed on-device and discarded (or kept in a short TTL cache for debugging).

Optional (Pro / developer mode):
- Keep a local encrypted cache of raw sample counts + summary only (no per-second traces).

---

## 7) Sleep Aggregation (Exact Algorithm)

### 7.1 Input Samples

Query `sleepAnalysis` category samples with:
- startDate/endDate within a “candidate window” (see 7.2)
- include all sources, but later filter by source precedence (see 11)

### 7.2 Candidate Window (per Local Day D)

To compute the sleep that belongs to Local Day `D`:
- Define `D` in the chosen timezone.
- Candidate window: from `D-1 18:00` to `D 18:00` local time.

Rationale: captures typical night sleep and avoids splitting midnight.

### 7.3 Main Sleep Window Selection

From all sleep segments in candidate window:
1. Build **sleep bouts** by grouping segments separated by gaps <= 90 minutes.
2. For each bout, compute:
   - `asleep_minutes` (sum of asleep + stage samples)
   - `in_bed_minutes` (sum of inBed, if present)
   - `start_local`, `end_local`
3. Select the bout with the **maximum asleep_minutes**.
4. Tie-breakers (in order):
   - Ends closest to 08:00 local time
   - Higher proportion of staged sleep availability (deep/rem/core present)
   - Preferred source wins

The chosen bout is the **Sleep Window**.

### 7.4 Stage Mapping

If stage-level samples exist:
- `deep_minutes` = sum of `asleepDeep`
- `rem_minutes` = sum of `asleepREM`
- `light_minutes` = sum of `asleepCore`
- `awake_minutes` = sum of `awake` samples inside Sleep Window
- `asleep_minutes` = deep + rem + light

If only legacy `asleep` exists:
- `asleep_minutes` = sum of `asleep`
- Stage minutes = NULL (unknown)
- `awake_minutes` = if `awake` exists, sum; else NULL

If only `inBed` exists (worst case):
- `in_bed_minutes` = sum of `inBed`
- `asleep_minutes` = NULL
- Mark low confidence and require user confirmation if used for insights.

### 7.5 Derived Sleep Metrics

For Local Day `D`:
- `sleep_duration_hours` = asleep_minutes / 60, if available; else NULL
- `awake_percent` = awake_minutes / (awake_minutes + asleep_minutes) * 100, if both known
- `deep_sleep_percent` = deep_minutes / asleep_minutes * 100 (if stage known)
- `rem_sleep_percent` = rem_minutes / asleep_minutes * 100
- `light_sleep_percent` = light_minutes / asleep_minutes * 100

### 7.6 Awakenings Count (Optional)

Awakening = transition from asleep to awake lasting >= 2 minutes, capped at 20 for sanity.
If stage transitions are not available, omit.

---

## 8) HRV Aggregation (Exact Algorithm)

### 8.1 Input Samples

Query `heartRateVariabilitySDNN` quantity samples.

### 8.2 Selection Window (Prefer Sleep Window)

For Local Day `D`:
1. If Sleep Window exists: select HRV samples with timestamp inside Sleep Window.
2. Else fallback: select samples from `D-1 18:00` → `D 18:00` local.

### 8.3 Aggregation

- Convert all HRV samples to ms.
- If sample count >= 3:
  - `hrv_ms` = median(samples_ms)
- If sample count 1-2:
  - `hrv_ms` = mean(samples_ms)
- If no samples:
  - `hrv_ms` = NULL (missing)

### 8.4 Quality Filters (Defensive)

Exclude samples if:
- value <= 0
- value > 300 (likely corrupted)
- source is explicitly deprioritized by user (see 11.4)

---

## 9) Resting Heart Rate Aggregation

### 9.1 Primary (Simple)

For Local Day `D`, query `restingHeartRate` samples in `D 00:00` → `D 23:59:59` local and compute:
- `resting_heart_rate_bpm` = median(bpm_samples)

### 9.2 Recommended Enhancement (Nocturnal Minimum)

If `heartRate` samples are available:
- Within the Sleep Window, compute the 5th percentile heart rate (`p05`) and store it as `resting_heart_rate_bpm`.
- Keep the `restingHeartRate` median as a diagnostic-only local value (not persisted server-side by default).

Rationale: “sleep-measured RHR” is less noisy and better aligned with recovery scoring.

### 9.3 Quality Filters

Exclude heart rate samples if:
- bpm < 25 or bpm > 220
- marked as user-entered (if that metadata exists)

---

## 10) Workouts Aggregation + Mapping

### 10.1 Import Policy

- Always import workouts if user granted permission.
- Mark imported workouts as `workout_sessions.source = 'import'` with `import_provider = 'healthkit'`.
- Persist `import_source_id` as the stable HealthKit workout UUID (de-dupe key).
- Never overwrite a manual workout silently.

### 10.2 Mapping Into `workout_sessions`

For each `HKWorkout`:
- `started_at` = startDate (UTC)
- `ended_at` = endDate (UTC)
- `session_date` = Local Day derived from `started_at` using the timezone rules in section 5
- `workout_type` = mapped from `HKWorkoutActivityType` to Life OS enums (define a stable mapping table in code)
- `estimated_calories` = `totalEnergyBurned` (kcal) if present
- `duration_minutes` = (end-start)/60
- `import_source_id` = workout UUID string (stable)
- `started_timezone` + `started_utc_offset_minutes` = set when known for travel-correct display

Optional (client-only display metadata, not persisted server-side by default):
- display source device name (e.g. “Apple Watch”)
- distance and heart-rate details for cardio (if supported later)

### 10.3 Duplicate + Conflict Detection (Imported vs Manual)

Two sessions are considered potential duplicates if:
- Same Local Day `session_date`
- Overlap ratio >= 0.6 OR start times within 30 minutes and durations within 25%
- Type is compatible (e.g. “Strength” vs “Traditional Strength Training”)

When a conflict is detected:
- Do not auto-merge by default.
- Show conflict modal (see Design System and Copy Catalog).
- Offer:
  - Merge (best effort; keep manual sets, imported calories/duration)
  - Keep manual
  - Keep imported

### 10.4 Heart Rate Zones (for TRIMP)

If heart‑rate samples are available during a workout, compute per‑workout zone minutes for TRIMP:

**Inputs:**
- `HKQuantityTypeIdentifier.heartRate` samples within the workout time range.
- Workout start/end timestamps.

**Filters:**
- Use the same heart‑rate quality filters as §9.3 (exclude <25 bpm, >220 bpm, or user‑entered).
- If total sample count < 30, treat zones as **unavailable** (fallback to RPE).

**Zone thresholds (percent of HRmax):**
- Zone 1: `< 60%`
- Zone 2: `60–70%`
- Zone 3: `70–80%`
- Zone 4: `80–90%`
- Zone 5: `> 90%`

**HRmax derivation (per workout):**
- Compute `peak_hr_bpm` as the **95th percentile** of HR samples during the workout.
- Use `peak_hr_bpm` as the HRmax proxy **for that workout only**.
- Store the daily max as `training_loads.peak_heart_rate_bpm` (max of workout peaks for the day).

**Zone minutes calculation:**
- Bin each HR sample into a zone based on `peak_hr_bpm`.
- Approximate time spent in each zone using the time delta to the next sample.
- Sum minutes per zone across all samples.

If zones are unavailable, leave `zone*_minutes = 0` and mark training‑load confidence as low.

### 10.5 Training Load + Active Calories

- Training load is computed from workouts + intensity signals.
- For `physiological_states.active_calories`, prefer:
  - Sum of `activeEnergyBurned` samples for Local Day, if available and trusted.
  - Else sum of imported workout calories.

---

## 11) Source Precedence (Deterministic)

### 11.1 Why This Matters

Multiple apps can write to HealthKit. We must:
- Avoid double counting
- Prefer the most reliable sources
- Keep user control

### 11.2 Default Ranking (MVP)

For each metric:
1. Apple Watch (native) sources
2. Other wearables (if present) with stage-level sleep
3. iPhone-only sources
4. Manually entered samples

### 11.3 Per-Metric Source Rules

- Sleep:
  - Prefer sources that provide stages (core/deep/rem).
  - If stages exist from multiple sources, pick the preferred source entirely (do not mix stages across sources).
- HRV:
  - Prefer Apple Watch SDNN.
  - Do not mix SDNN and RMSSD; keep SDNN-only for scoring.
- RHR:
  - Prefer sleep-window `heartRate` derived (if enabled).
  - Else `restingHeartRate` from preferred source.
- Workouts:
  - Prefer Apple Watch workouts over iPhone auto-detected workouts if both exist.

### 11.4 User Controls (Settings)

Add a Settings page:
- “Preferred Sources” per metric (Sleep / HRV / Heart Rate / Workouts)
- A “Reset to Default” button
- Show the top 3 sources detected (with last updated date)

---

## 12) Data Completeness + Confidence Score

### 12.1 Data Completeness (0..1, HealthKit-only)

Compute as weighted availability of required components:
- Sleep duration present: 0.35
- HRV present: 0.35
- RHR present: 0.20
- Activity context (steps or active calories): 0.10

`data_completeness = sum(weights where component present)`

### 12.2 Base Confidence (0..1, HealthKit-only)

Starts from `data_completeness` and applies penalties:
- Sleep stages missing (but sleep duration present): -0.05
- HRV sample count < 3: -0.05
- Sleep Window inferred from inBed only: -0.20
- Source is not preferred for that metric: -0.05
- Last sync older than 36 hours: -0.10

Clamp to `[0, 1]`.

### 12.3 Recovery Confidence (0..1, cross-domain)

When recovery scoring is computed, a **cross-domain confidence** is used:
- HRV, sleep, RHR, temperature, nutrition logs, bioimpedance, wellness check
- Baseline days boost (see `life_os_recovery_algorithms.md`)

If non-HealthKit signals are missing, fall back to Base Confidence.

> Output must explain the top 1-2 reasons for lowered confidence (UI tooltip).

---

## 13) Sync Strategy (Implementation Contract)

### 13.1 Storage for Sync State (Client)

Persist per-type anchors locally (Keychain or encrypted local storage):
- `sleep_anchor`
- `hrv_anchor`
- `rhr_anchor`
- `workout_anchor`
- `steps_anchor`
- `active_energy_anchor`

Also store:
- `last_successful_sync_at`
- `last_backfill_end_date`

### 13.2 First Connect Backfill (MVP)

On first successful authorization:
1. Backfill last 14 days for Sleep + HRV + RHR + Workouts + Steps + Active Energy.
2. Compute daily aggregates for each Local Day.
3. Upsert `physiological_states` for each day.
4. Import workouts into `workout_sessions`.

### 13.3 Incremental Sync

Use anchored queries per type:
- Fetch new/updated/deleted samples since anchor.
- Update local caches, recompute affected Local Days only.

### 13.4 Background Delivery

Enable background delivery (where supported) for:
- Sleep analysis
- HRV
- Workouts

Frequency:
- `.immediate` for sleep/workouts (if allowed)
- `.hourly` for HRV (battery-sensitive)

### 13.5 Recompute Rules (Minimal Reprocessing)

When new samples arrive:
- Determine impacted Local Days (by mapping sample timestamps to Local Day).
- Recompute aggregates only for those days and their neighbors (D-1, D) because sleep spans midnight.

---

## 14) Error Handling Mapping (Client Contract)

Map HealthKit failures into `LifeOSError` categories:
- notAvailable → HealthKitError.notAvailable
- notAuthorized → HealthKitError.notAuthorized
- partialAuthorization → HealthKitError.partialAuthorization
- queryFailed/timeout → HealthKitError.syncFailed (retryable)

UI rules:
- If authorization is denied: show a Settings CTA and continue.
- If sync fails: degrade to cached values and show a subtle banner (no blocking modals).

---

## 15) Authorization Status Change Detection

### Problem
iOS does not provide a callback for HealthKit permission revocations. If the user revokes permissions in Settings → Privacy → Health, the app must detect this gracefully.

### Polling Strategy

**Foreground check:**
- On every app launch (`UIApplication.didBecomeActive`), call `HKHealthStore.authorizationStatus(for:)` for all required types.
- Compare against the cached authorization state stored in `UserDefaults.healthkit_auth_state`.
- If any type transitioned from `.sharingAuthorized` to `.sharingDenied` or `.notDetermined`: trigger the revocation handler.

**Background check:**
- During each background HealthKit sync (`app.lifeos.healthkit.sync`), verify authorization status before querying.
- If authorization is revoked mid-sync: abort gracefully, update cached state, and surface the change on next foreground.

### Revoked Permission Handling

| Revoked Type | Impact | Degradation Behavior |
|-------------|--------|---------------------|
| `HKQuantityType.heartRateVariabilitySDNN` | Recovery HRV score unavailable | Recovery renders without HRV; confidence drops significantly. Show `healthkit.hrv_unavailable` banner. |
| `HKQuantityType.restingHeartRate` | Recovery RHR score unavailable | Recovery uses remaining signals (sleep + temperature). |
| `HKCategoryType.sleepAnalysis` | Sleep data unavailable | Recovery confidence drops. Sleep surfaces show "No data" with Settings CTA. |
| `HKQuantityType.activeEnergyBurned` | Training load less accurate | TRIMP relies on RPE-only fallback. |
| `HKQuantityType.bodyMass` | Dynamic weight unavailable | Falls back to static `users.weight_kg`. |
| All types revoked | Minimal health context | App is fully functional for manual logging (nutrition, supplements, workouts). Recovery shows "Not enough data" instead of a score. |

### UI Behavior

**When revocation is detected:**
1. Show a non-blocking banner on the Recovery screen: `healthkit.permission_revoked_banner`: "Some health data permissions were revoked. Recovery accuracy may be reduced."
2. Banner includes a "Fix in Settings" CTA that deep-links to `UIApplication.openSettingsURLString`.
3. The banner is dismissable and reappears at most once per day.
4. Do **not** show a modal or interrupt the user's flow.

**When partial permissions exist:**
- Show which specific data types are missing in Settings → Health Data → Permissions.
- Each missing type shows its impact on accuracy (e.g., "HRV: Not shared → Recovery accuracy reduced").

---

## 16) Acceptance Criteria (Must Pass)

1. **Local day correctness**:
   - A sleep from 23:30 to 07:10 is attributed to the day ending at 07:10 in the user’s local timezone.
   - Traveling across time zones does not retroactively shift historical days in the diary.
2. **Deterministic outputs**:
   - Given the same HealthKit sample set and preferred-source configuration, daily aggregates match bit-for-bit.
3. **Partial permissions**:
   - If HRV is denied, Recovery still renders with reduced confidence and explanatory copy.
4. **No double counting**:
   - If two sleep sources exist, only one is used for daily aggregates (by precedence rules).
5. **Background updates**:
   - With background delivery enabled, yesterday’s sleep is available by 10:00 local time (best effort; show “last sync” if not).
