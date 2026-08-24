# LIFE OS — ANALYTICS EVENT CATALOG

**Version:** 0.1  
**Date:** February 16, 2026  
**Purpose:** Canonical list of all analytics events, their properties, and privacy classification. This is the single source of truth for product analytics instrumentation.

> [!IMPORTANT]
> Life OS uses **privacy-preserving analytics** — no IDFA, no cross-app tracking, no user fingerprinting.  
> All analytics are opt-in and anonymized. Events never contain PII (names, emails, health values).

---

## 0) Non-Negotiables

1. **No PII in events.** Never log actual health metric values, food names, supplement names, or user profile data in analytics events.
2. **Opt-in only.** Analytics collection requires explicit user consent during onboarding or in Settings.
3. **No third-party analytics SDKs in V1.** All events are sent to Supabase (self-hosted) or a self-managed PostHog instance. No Mixpanel, Amplitude, Firebase Analytics, or similar.
4. **Event names use `snake_case`.** Property names use `snake_case`.
5. **Every event has**: `event_name`, `timestamp`, `session_id`, `app_version`, `os_version`, `device_model`.

---

## 1) Event Taxonomy

### 1.1 Naming Convention

```
<domain>_<action>_<object>
```

Examples:
- `food_log_created`
- `recovery_score_viewed`
- `onboarding_step_completed`
- `widget_tapped`

### 1.2 Domains

| Domain | Description |
|--------|-------------|
| `app` | App lifecycle events (launch, background, foreground) |
| `onboarding` | Onboarding flow events |
| `food` | Food logging events |
| `recovery` | Recovery score and analysis events |
| `training` | Workout and training plan events |
| `supplement` | Supplement tracking events |
| `lab` | Lab scan and health marker events |
| `experiment` | N-of-1 experiment events |
| `insight` | AI-generated insight events |
| `sync` | Sync engine events |
| `widget` | Widget interaction events |
| `settings` | Settings and preference changes |
| `error` | Error and failure events |
| `ai` | AI feature usage events |

---

## 2) Core Events

### 2.1 App Lifecycle

| Event | Properties | Notes |
|-------|------------|-------|
| `app_launched` | `launch_type` (cold/warm), `time_to_home_ms` | Performance tracking |
| `app_backgrounded` | `foreground_duration_s` | Session length |
| `app_foregrounded` | `background_duration_s` | Re-engagement |

### 2.2 Onboarding

| Event | Properties | Notes |
|-------|------------|-------|
| `onboarding_started` | — | Funnel start |
| `onboarding_step_completed` | `step_name`, `step_index`, `duration_s` | Step-level funnel |
| `onboarding_healthkit_permission` | `granted` (bool), `partial` (bool) | Permission funnel |
| `onboarding_completed` | `total_duration_s`, `steps_skipped` | Funnel end |
| `onboarding_abandoned` | `last_step_name`, `last_step_index` | Drop-off analysis |

### 2.3 Food Logging

| Event | Properties | Notes |
|-------|------------|-------|
| `food_log_started` | `method` (photo/barcode/voice/manual/label_scan) | Method distribution |
| `food_log_created` | `method`, `item_count`, `confidence`, `was_edited`, `duration_s` | Core logging metric |
| `food_log_edited` | `fields_changed` (array of field names) | Edit pattern analysis |
| `food_log_deleted` | `age_hours` | Deletion patterns |
| `food_photo_retaken` | `reason` (blurry/no_food/low_confidence) | Photo quality issues |
| `food_barcode_not_found` | `barcode_format` | CIS coverage gap tracking |
| `food_label_scan_completed` | `confidence`, `needs_review`, `language_detected` | OCR quality |
| `food_voice_parsed` | `confidence`, `item_count`, `clarification_needed` | Voice parsing quality |
| `food_barcode_not_found_locale` | `barcode_format`, `user_locale`, `user_country` | CIS coverage gap tracking per locale — SLO: < 15% miss rate per locale |
| `food_label_ocr_success_rate` | `language_detected`, `markers_extracted`, `was_accepted` | OCR accuracy per language — SLO: ≥ 80% acceptance without edits |
| `food_template_used` | `template_id`, `template_type` (meal/batch), `is_custom` | Template adoption and usage frequency |

### 2.4 Recovery

| Event | Properties | Notes |
|-------|------------|-------|
| `recovery_score_viewed` | `zone` (optimal/ready/caution/critical), `confidence` | Core engagement metric |
| `recovery_detail_viewed` | `breakdown_expanded` (bool) | Detail depth |
| `recovery_recommendation_tapped` | `recommendation_type` | Recommendation engagement |
| `recovery_trend_viewed` | `period` (7d/30d/90d) | Trend usage |

### 2.5 Training

| Event | Properties | Notes |
|-------|------------|-------|
| `workout_started` | `source` (plan/manual/import) | Session source |
| `workout_completed` | `duration_min`, `exercise_count`, `set_count`, `source` | Core training metric |
| `workout_abandoned` | `duration_min`, `exercise_count` | Abandonment patterns |
| `training_plan_generated` | `goal`, `days_per_week`, `duration_weeks`, `confidence` | Plan generation |
| `training_plan_started` | `plan_type` | Plan adoption |

### 2.6 Supplements

| Event | Properties | Notes |
|-------|------------|-------|
| `supplement_logged` | `method` (one_tap/manual), `time_of_day` | Logging patterns |
| `supplement_reminder_received` | — | Reminder delivery |
| `supplement_reminder_acted_on` | `action` (logged/snoozed/dismissed), `delay_s` | Reminder efficacy |

### 2.7 Labs

| Event | Properties | Notes |
|-------|------------|-------|
| `lab_scan_started` | — | Scan funnel start |
| `lab_scan_completed` | `markers_extracted`, `confidence`, `duration_s` | Scan quality |
| `lab_scan_review_edited` | `markers_corrected` | OCR accuracy proxy |

### 2.8 AI Features

| Event | Properties | Notes |
|-------|------------|-------|
| `ai_request_sent` | `feature`, `model_used` | AI usage tracking |
| `ai_request_succeeded` | `feature`, `model_used`, `latency_ms`, `was_fallback` | Success tracking |
| `ai_request_failed` | `feature`, `model_used`, `error_code` | Failure tracking |
| `ai_output_accepted` | `feature`, `was_edited` | Output quality proxy |
| `ai_output_rejected` | `feature`, `reason` | Quality issues |

### 2.9 Sync

| Event | Properties | Notes |
|-------|------------|-------|
| `sync_push_completed` | `events_count`, `duration_ms` | Sync performance |
| `sync_push_failed` | `events_count`, `error_category` | Sync failures |
| `sync_pull_completed` | `records_updated`, `duration_ms` | Pull performance |
| `sync_dead_letter` | `event_type`, `failure_reason` | Data loss risk |

### 2.10 Errors

| Event | Properties | Notes |
|-------|------------|-------|
| `error_occurred` | `category`, `code`, `severity`, `screen` | Error tracking |
| `error_retry_succeeded` | `category`, `code`, `attempt_number` | Retry success rate |
| `error_user_action` | `category`, `action` (retry/dismiss/settings) | User error response |

### 2.11 Sleep (V2)

| Event | Properties | Notes |
|-------|------------|-------|
| `sleep_manual_logged` | `sleep_duration_h`, `had_nap` | Manual sleep diary entry |
| `sleep_detail_viewed` | `date`, `has_healthkit_data` | Sleep detail screen |
| `sleep_trend_viewed` | `range_days` (7/30/90) | Trends engagement |
| `sleep_quality_rated` | `rating` (1-5) | Subjective quality |

### 2.12 Unified Diary (V2)

| Event | Properties | Notes |
|-------|------------|-------|
| `diary_day_viewed` | `date`, `sections_visible` | Daily diary screen |
| `diary_month_viewed` | `month`, `days_with_data` | Calendar overview |
| `diary_action_tapped` | `action` (add_food/add_workout/add_supplement/log_sleep) | Quick action buttons |
| `diary_section_expanded` | `section` (recovery/nutrition/training/supplements) | Section engagement |

### 2.13 Widgets

| Event | Properties | Notes |
|-------|------------|-------|
| `widget_configured` | `widget_type`, `family` (small/medium/circular) | Widget adoption |
| `widget_tapped` | `widget_type`, `deep_link_target` | Widget engagement |

---

## 3) Funnel Definitions

### 3.1 Onboarding Funnel

```
onboarding_started
  → onboarding_step_completed (step: "demo")
  → onboarding_healthkit_permission
  → onboarding_step_completed (step: "profile")
  → onboarding_completed
```

**Target conversion rate:** ≥ 70% from started to completed.

### 3.2 Food Logging Funnel

```
food_log_started
  → (AI analysis or manual entry)
  → food_log_created
```

**Target conversion rate:** ≥ 85% from started to created.

### 3.3 First-Day Activation

User is "activated" if within first 24 hours they complete:
1. Onboarding
2. At least 1 food log
3. View recovery score

**Target activation rate:** ≥ 50%.

---

## 4) Privacy Classification

| Event Category | Contains PII | Requires Consent | Retention |
|---------------|-------------|------------------|-----------|
| App lifecycle | No | Basic consent | 90 days |
| Onboarding | No | Basic consent | 90 days |
| Feature usage (food, recovery, etc.) | No | Basic consent | 90 days |
| AI metrics | No | Basic consent | 90 days |
| Error tracking | No | Basic consent | 30 days |
| Sync metrics | No | Basic consent | 30 days |

---

## 5) Implementation Notes

### 5.1 Client-Side Event Buffer

```swift
actor AnalyticsBuffer {
    private var events: [AnalyticsEvent] = []
    private let maxBufferSize = 50
    private let flushInterval: TimeInterval = 60  // 1 minute
    
    func track(_ event: AnalyticsEvent) {
        events.append(event)
        if events.count >= maxBufferSize {
            await flush()
        }
    }
    
    func flush() async {
        guard !events.isEmpty else { return }
        let batch = events
        events = []
        // Send to Supabase via Edge Function
        await AnalyticsAPI.sendBatch(batch)
    }
}
```

### 5.2 Opt-Out Behavior

When user opts out of analytics:
- Stop collecting all events immediately.
- Delete local event buffer.
- Do NOT delete already-sent events (they are anonymized and cannot be linked back).
- Show "Analytics disabled" in Settings with option to re-enable.

---

## 6) Implementation Checklist

- [ ] Set up analytics Edge Function endpoint (`/api/analytics/batch`).
- [ ] Implement `AnalyticsBuffer` with batching and flush logic.
- [ ] Add consent toggle in onboarding and Settings.
- [ ] Instrument all core events listed above.
- [ ] Create Supabase table `analytics_events` with proper indexing.
- [ ] Set up retention policy (auto-delete events older than 90 days).
- [ ] Create dashboard with key funnels and metrics.
- [ ] Verify no PII leakage in analytics payload (add unit test).
