# LIFE OS — COPY CATALOG

**Version:** 1.17
**Date:** February 16, 2026  
**Purpose:** Single source of truth for UX copy across the core app flows (Onboarding, Nutrition, Training, Supplements, Labs, OCR) + watchOS companion surfaces (V2).

> [!IMPORTANT]
> All UI strings in core flows must map to a `copy_id` here.  
> If UI needs new text, add it here first.

---

## LOCALIZATION SPEC

**Key format:** `module.scope.intent`  
Examples: `training.start_title`, `labs.ocr_low_helper`

**Variables:** Use `{variable}` placeholders only.  
Examples: `Recovery is low today. Volume reduced by {percent}%.`

**Pluralization:** Use ICU plural rules in implementation layer.  
Catalog stores the base English string; plural forms live in localization files.

**Length budgets (English):**
- CTA: 1-3 words
- Title: <= 28 characters
- Helper: <= 80 characters
- Banner: <= 50 characters

**Tone rules:**
- Supportive, neutral, non-judgmental
- No guilt, no threats, no medical claims
- Avoid exclamation overload

---

## IMPLEMENTATION GUIDANCE

- All UI must reference `copy_id` (no hardcoded strings).
- For new screens, add `copy_id` before design review.
- Errors should reference `copy_id` where applicable.
- If `copy_id` not found, fallback to `global.no_copy_fallback`.

**Fallback copy:**
| copy_id | Context | Copy |
|---------|---------|------|
| global.no_copy_fallback | Error | "Text unavailable. Please update the copy catalog." |

---

## GLOBAL

| copy_id | Context | Copy |
|---------|---------|------|
| global.save | Primary CTA | "Save" |
| global.cancel | Secondary CTA | "Cancel" |
| global.edit | CTA | "Edit" |
| global.review | CTA | "Review" |
| global.continue | CTA | "Continue" |
| global.back | CTA | "Back" |
| global.skip | CTA | "Skip" |
| global.done | CTA | "Done" |
| global.open_on_iphone | CTA | "Open on iPhone" |
| global.estimate_badge | Badge | "Estimate" |
| global.no_copy_fallback | Error | "Text unavailable. Please update the copy catalog." |
| recovery.zone_critical | Label | "Critical" |
| recovery.zone_caution | Label | "Caution" |
| recovery.zone_ready | Label | "Ready" |
| recovery.zone_optimal | Label | "Optimal" |

---

## HOME

| copy_id | Context | Copy |
|---------|---------|------|
| home.title | Screen title | "Home" |
| home.next_best_action | Primary CTA | "Do this now" |
| home.quick_log_food | CTA | "Log food" |
| home.quick_log_training | CTA | "Log training" |
| home.quick_log_supplement | CTA | "Log supplement" |
| home.quick_log_lab | CTA | "Scan lab" |
| home.low_confidence_banner | Banner | "Low confidence — review before saving." |

---

## WATCHOS

| copy_id | Context | Copy |
|---------|---------|------|
| watch.due_soon | Pill | "Due soon" |
| watch.last_updated | Footer | "Last updated {time}" |

---

## INSIGHTS

| copy_id | Context | Copy |
|---------|---------|------|
| insights.list_title | Screen title | "Insights" |
| insights.open_detail | CTA | "View insight" |
| insights.start_experiment | CTA | "Start experiment" |
| insights.acknowledge | CTA | "Got it" |
| insights.dismiss | CTA | "Dismiss" |
| insights.why_this | CTA | "Why this?" |
| insights.confidence_high | Badge | "High confidence" |
| insights.confidence_medium | Badge | "Medium confidence" |
| insights.confidence_low | Badge | "Low confidence" |
| insights.empty_title | Empty state | "No insights yet" |
| insights.empty_helper | Empty state | "Keep logging to unlock patterns and experiments." |
| insights.empty_cta | CTA | "View diary" |

---

## EXPERIMENTS

| copy_id | Context | Copy |
|---------|---------|------|
| experiments.list_title | Screen title | "Experiments" |
| experiments.log_daily | CTA | "Log today" |
| experiments.stop | Secondary CTA | "Stop experiment" |
| experiments.empty_title | Empty state | "No active experiments yet" |
| experiments.empty_helper | Empty state | "Start one from an insight to learn what works for you." |
| experiments.results_title | Screen title | "Experiment results" |
| experiments.results_summary | Helper text | "Here’s what changed during your experiment." |

---

## SETTINGS — NOTIFICATIONS & CONTROL

| copy_id | Context | Copy |
|---------|---------|------|
| settings.notifications_title | Screen title | "Notifications" |
| settings.control_title | Screen title | "Control" |
| settings.control_advisory | Option | "Advisory" |
| settings.control_protective | Option | "Protective" |
| settings.control_guardian | Option | "Guardian" |
| settings.control_permission_needed | Banner | "Enable Focus Control to use Guardian mode." |
| settings.control_pause_today | CTA | "Pause control for today" |
| settings.focus_title | Screen title | "Focus Control" |
| settings.focus_helper | Helper text | "Choose which apps can be restricted when your recovery is low." |
| settings.focus_continue | CTA | "Continue" |
| settings.focus_confirm | CTA | "Confirm" |
| settings.focus_edit_apps | CTA | "Edit apps" |
| settings.focus_learn_more | CTA | "Learn more" |
| settings.focus_learn_more_title | Sheet title | "How Focus Control works" |
| settings.focus_learn_more_body | Body | "Life OS can temporarily restrict selected apps when your recovery is low. You stay in control and can pause or edit restrictions anytime." |
| settings.notifications_positive_label | Label | "Positive reinforcement" |
| settings.notifications_nudges_label | Label | "Gentle nudges" |
| settings.notifications_critical_only_label | Label | "Critical alerts only" |
| settings.notifications_quiet_hours_label | Label | "Quiet hours" |
| settings.notifications_quiet_hours_start | Label | "Start" |
| settings.notifications_quiet_hours_end | Label | "End" |

---

## AUTH

| copy_id | Context | Copy |
|---------|---------|------|
| auth.welcome_title | Screen title | "Welcome to Life OS" |
| auth.welcome_helper | Helper text | "Build better days with gentle insights." |
| auth.continue_apple | CTA | "Continue with Apple" |
| auth.continue_email | CTA | "Continue with Email" |
| auth.sign_in | CTA | "Sign In" |
| auth.create_account | CTA | "Create Account" |
| auth.terms_helper | Helper text | "By continuing, you agree to our Terms and Privacy Policy." |
| auth.error_invalid_email | Inline error | "Please enter a valid email address." |
| auth.error_wrong_code | Inline error | "That code doesn’t match. Try again." |

---

## ONBOARDING

| copy_id | Context | Copy |
|---------|---------|------|
| onboarding.value_title | Screen title | "Your health, clarified" |
| onboarding.value_bullets | Helper text | "Sleep, training, nutrition, supplements — connected." |
| onboarding.value_trust | Helper text | "Private by default. You stay in control." |
| onboarding.demo_title | Screen title | "See it in action" |
| onboarding.demo_helper | Helper text | "Snap a meal photo — we’ll estimate macros and let you edit." |
| onboarding.healthkit_title | Screen title | "Connect Apple Health" |
| onboarding.healthkit_privacy | Helper text | "Your data stays protected. Disconnect anytime." |
| onboarding.healthkit_preview | Helper text | "Get a Recovery Score and personalized daily plan." |
| onboarding.healthkit_primary | CTA | "Connect HealthKit" |
| onboarding.profile_title | Screen title | "Set your baseline" |
| onboarding.profile_helper | Helper text | "A few details help personalize targets and insights." |
| onboarding.health_q_cardiac | Question | "Do you have any heart conditions?" |
| onboarding.health_q_pacemaker | Question | "Do you have a pacemaker or implanted device?" |
| onboarding.health_q_pregnant | Question | "Are you currently pregnant?" |
| onboarding.health_q_eating_disorder | Question | "Have you ever been diagnosed with an eating disorder?" |
| onboarding.add_supplements | CTA | "Add Supplements" |
| onboarding.import_labs | CTA | "Import Labs" |
| onboarding.insight_title | Screen title | "Your first insight" |
| onboarding.insight_helper | Helper text | "Here’s what your body may need today — and why." |
| onboarding.notify_title | Screen title | "Gentle reminders" |
| onboarding.notify_helper | Helper text | "Get a morning brief and optional nudges. You control timing." |
| onboarding.notify_primary | CTA | "Enable Notifications" |

---

## NUTRITION

| copy_id | Context | Copy |
|---------|---------|------|
| nutrition.diary_title | Screen title | "Nutrition" |
| nutrition.diary_log_primary | CTA | "Log Meal" |
| nutrition.empty_title | Empty state | "Log your first meal" |
| nutrition.empty_helper | Empty state | "Add a meal to see daily targets and trends." |
| nutrition.photo_log_title | Screen title | "Log Meal Photo" |
| nutrition.photo_log_helper | Helper text | "Include the full plate in the frame." |
| nutrition.photo_log_primary | CTA | "Capture" |
| nutrition.photo_log_secondary | CTA | "Choose Photo" |
| nutrition.meal_edit_title | Screen title | "Review Meal" |
| nutrition.meal_edit_helper | Helper text | "Adjust items and portions before saving." |
| nutrition.meal_save_primary | CTA | "Save Meal" |
| nutrition.meal_save_secondary | CTA | "Edit Items" |
| nutrition.ai_low_title | Modal title | "Needs a quick check" |
| nutrition.ai_low_helper | Helper text | "We’re not fully confident. Please review before saving." |
| nutrition.ai_low_primary | CTA | "Review" |
| nutrition.ai_low_secondary | CTA | "Retake" |
| nutrition.log_picker_title | Sheet title | "Log Meal" |
| nutrition.log_picker_time | Label | "Time" |
| nutrition.log_picker_now | CTA | "Now" |
| nutrition.method_photo | Tile | "Photo" |
| nutrition.method_barcode | Tile | "Barcode" |
| nutrition.method_voice | Tile | "Voice" |
| nutrition.method_search | Tile | "Search" |
| nutrition.method_quick_add | Tile | "Quick Add" |
| nutrition.method_recipe | Tile | "Recipe" |
| nutrition.barcode_title | Screen title | "Scan Barcode" |
| nutrition.barcode_helper | Helper text | "Align the barcode in the frame." |
| nutrition.barcode_type_code | CTA | "Type code" |
| nutrition.barcode_not_found_title | Empty state | "Barcode not found" |
| nutrition.barcode_not_found_helper | Empty state | "You can still log it in seconds." |
| nutrition.barcode_not_found_search | CTA | "Search" |
| nutrition.barcode_not_found_photo | CTA | "Photo" |
| nutrition.barcode_not_found_manual | CTA | "Manual" |
| nutrition.barcode_not_found_scan_label | CTA | "Scan label" |
| nutrition.barcode_scan_again | CTA | "Scan again" |
| nutrition.label_scan_title | Screen title | "Scan Nutrition Label" |
| nutrition.label_scan_helper | Helper text | "Photograph the nutrition table (kcal, P/F/C)." |
| nutrition.label_scan_primary | CTA | "Capture label" |
| nutrition.label_scan_secondary | CTA | "Choose photo" |
| nutrition.product_review_title | Screen title | "Review Product" |
| nutrition.product_review_helper | Helper text | "Check values once — future scans are instant." |
| nutrition.product_save_primary | CTA | "Save product" |
| nutrition.product_save_secondary | CTA | "Cancel" |
| nutrition.product_fix_macros | CTA | "Fix macros" |
| nutrition.voice_title | Screen title | "Tell us what you ate" |
| nutrition.voice_helper | Helper text | "Short is fine. Example: “Two eggs and cappuccino”." |
| nutrition.voice_primary | CTA | "Continue" |
| nutrition.voice_type_instead | CTA | "Type instead" |
| nutrition.search_title | Screen title | "Add Food" |
| nutrition.search_placeholder | Placeholder | "Search foods" |
| nutrition.search_empty_title | Empty state | "No results" |
| nutrition.search_empty_helper | Empty state | "Try a shorter name or create a custom food." |
| nutrition.search_create_custom | CTA | "Create custom" |
| nutrition.meal_tray_review_save | CTA | "Review & Save" |
| nutrition.portion_title | Sheet title | "Portion" |
| nutrition.portion_unit_serving | Unit | "Serving" |
| nutrition.portion_unit_grams | Unit | "Grams" |
| nutrition.portion_add | CTA | "Add" |
| nutrition.add_to_meal | CTA | "Add to meal" |
| nutrition.quick_add_title | Screen title | "Quick Add" |
| nutrition.quick_add_repeat_last | CTA | "Repeat last" |
| nutrition.save_as_template | CTA | "Save as Template" |
| nutrition.template_name_title | Sheet title | "Name template" |
| nutrition.template_name_placeholder | Placeholder | "Template name" |
| nutrition.templates_title | Screen title | "Templates" |
| nutrition.templates_create_primary | CTA | "New template" |
| nutrition.templates_manage | CTA | "Manage templates" |
| nutrition.templates_edit | Swipe action | "Edit" |
| nutrition.templates_archive | Swipe action | "Archive" |
| nutrition.templates_unarchive | CTA | "Unarchive" |
| nutrition.batch_library_title | Screen title | "Meal Prep" |
| nutrition.batch_library_empty_title | Empty state | "Create your first meal prep" |
| nutrition.batch_library_empty_helper | Empty state | "Save a batch once, then log portions in seconds." |
| nutrition.batch_library_create_primary | CTA | "Create batch" |
| nutrition.batch_create_title | Screen title | "New Meal Prep" |
| nutrition.batch_create_helper | Helper text | "Choose precise ingredients or a quick photo draft." |
| nutrition.batch_mode_precise | Tile | "Precise" |
| nutrition.batch_mode_precise_helper | Helper text | "Best accuracy" |
| nutrition.batch_mode_quick | Tile | "Quick (Photo)" |
| nutrition.batch_mode_quick_helper | Helper text | "Draft • review required" |
| nutrition.batch_total_weight_label | Label | "Total cooked weight" |
| nutrition.batch_total_portions_label | Label | "Portions" |
| nutrition.batch_cooked_at_label | Label | "Cooked on" |
| nutrition.batch_add_ingredient_title | Screen title | "Add Ingredient" |
| nutrition.batch_add_ingredient_placeholder | Placeholder | "Search ingredients" |
| nutrition.batch_review_title | Screen title | "Review Batch" |
| nutrition.batch_review_helper | Helper text | "Confirm totals and portions before saving." |
| nutrition.batch_save_primary | CTA | "Save batch" |
| nutrition.batch_save_secondary | CTA | "Edit ingredients" |
| nutrition.batch_log_title | Sheet title | "Log portion" |
| nutrition.batch_log_action | CTA | "Log portion" |
| nutrition.batch_log_primary | CTA | "Add to meal" |
| nutrition.batch_duplicate | CTA | "Cook again" |
| nutrition.batch_archive | CTA | "Archive" |

---

## DIARY

| copy_id | Context | Copy |
|---------|---------|------|
| diary.title | Screen title | "Diary" |
| diary.helper | Helper text | "Your day, in one place." |
| diary.view_day | CTA | "View Day" |
| diary.review_required | CTA | "Review items" |
| diary.empty_title | Empty state | "Start your day log" |
| diary.empty_helper | Empty state | "Log a meal or workout to see patterns over time." |

---

## SLEEP

| copy_id | Context | Copy |
|---------|---------|------|
| sleep.title | Screen title | "Sleep" |
| sleep.helper | Helper text | "Your sleep, explained." |
| sleep.stages_title | Section title | "Sleep stages" |
| sleep.stages_unavailable | Inline | "Sleep stages unavailable." |
| sleep.missing_title | Empty state | "Connect Apple Health" |
| sleep.missing_helper | Empty state | "Enable Sleep data to see stages, trends, and gentle recommendations." |
| sleep.connect_primary | CTA | "Connect HealthKit" |
| sleep.partial_title | Banner | "Some sleep data is missing" |
| sleep.partial_helper | Banner | "Grant full Sleep access for more accurate insights." |
| sleep.try_tonight | Section title | "Try tonight" |
| sleep.manual_title | Screen title | "Log Sleep" |
| sleep.manual_helper | Helper text | "Manually record your sleep times." |
| sleep.manual_bedtime | Label | "Bedtime" |
| sleep.manual_waketime | Label | "Wake time" |
| sleep.manual_quality | Label | "Sleep quality" |
| sleep.manual_quality_placeholder | Placeholder | "How did you sleep?" |
| sleep.manual_notes | Label | "Notes" |
| sleep.manual_save | CTA | "Save" |
| sleep.manual_success | Toast | "Sleep logged" |

---

## TRAINING

| copy_id | Context | Copy |
|---------|---------|------|
| training.start_title | Screen title | "Start Workout" |
| training.start_helper | Helper text | "Log sets, reps, or import from Apple Health." |
| training.start_primary | CTA | "Start" |
| training.start_secondary | CTA | "Choose Template" |
| training.start_planned_primary | CTA | "Start planned session" |
| training.start_empty_secondary | CTA | "Start empty workout" |
| training.session_title | Screen title | "Workout" |
| training.add_exercise | CTA | "Add exercise" |
| training.add_set | CTA | "Add set" |
| training.exercise_picker_title | Screen title | "Add Exercise" |
| training.exercise_search_placeholder | Placeholder | "Search exercises" |
| training.rest_timer_label | Label | "Rest" |
| training.finish_title | Screen title | "Finish Workout" |
| training.finish_helper | Helper text | "Summary will update your training load." |
| training.finish_primary | CTA | "Finish" |
| training.finish_secondary | CTA | "Review Sets" |
| training.adjust_title | Banner title | "Plan Adjusted" |
| training.adjust_helper | Helper text | "Recovery is low today. Volume reduced by 30%." |
| training.adjust_primary | CTA | "View Session" |
| training.adjust_secondary | CTA | "Keep Original" |
| training.error_missing_sets | Inline error | "Set data is incomplete. Please review." |
| training.error_missing_sets_primary | CTA | "Fix Set" |
| training.error_missing_sets_secondary | CTA | "Save as is" |
| training.plan_fail_title | Modal title | "Could not build plan" |
| training.plan_fail_helper | Helper text | "We need your available days and equipment access." |
| training.plan_fail_primary | CTA | "Add details" |
| training.plan_fail_secondary | CTA | "Choose template" |
| training.diary_title | Screen title | "Training" |
| training.diary_filter_planned | CTA | "Planned" |
| training.diary_filter_logged | CTA | "Logged" |
| training.merge_title | Modal title | "Duplicate workout found" |
| training.merge_helper | Helper text | "Keep imported, keep manual, or merge details." |
| training.merge_primary | CTA | "Merge" |
| training.merge_secondary | CTA | "Keep Manual" |
| training.merge_tertiary | CTA | "Keep Imported" |

---

## SUPPLEMENTS

| copy_id | Context | Copy |
|---------|---------|------|
| supplements.add_title | Screen title | "Add Supplements" |
| supplements.add_helper | Helper text | "Create your schedule for reminders and insights." |
| supplements.add_primary | CTA | "Add" |
| supplements.add_secondary | CTA | "Browse Catalog" |
| supplements.log_title | Screen title | "Log Intake" |
| supplements.log_helper | Helper text | "Mark as taken to improve adherence." |
| supplements.log_primary | CTA | "Taken" |
| supplements.log_secondary | CTA | "Skip" |
| supplements.warn_title | Inline title | "Timing Tip" |
| supplements.warn_helper | Helper text | "Calcium may reduce iron absorption." |
| supplements.warn_primary | CTA | "Adjust Timing" |
| supplements.warn_secondary | CTA | "Keep Schedule" |

---

## LABS + OCR

| copy_id | Context | Copy |
|---------|---------|------|
| labs.scan_title | Screen title | "Scan Lab Report" |
| labs.scan_helper | Helper text | "Include the results table in the frame." |
| labs.scan_primary | CTA | "Capture" |
| labs.scan_secondary | CTA | "Upload PDF" |
| labs.review_title | Screen title | "Review Values" |
| labs.review_helper | Helper text | "Confirm extracted values before saving." |
| labs.review_primary | CTA | "Save Results" |
| labs.review_secondary | CTA | "Edit Values" |
| labs.detail_title | Screen title | "Marker Detail" |
| labs.detail_helper | Helper text | "Trends are based on your historical tests." |
| labs.detail_primary | CTA | "Compare" |
| labs.detail_secondary | CTA | "Add Note" |
| labs.ocr_low_title | Modal title | "Scan Needs Review" |
| labs.ocr_low_helper | Helper text | "We found values but confidence is low. Please review before saving." |
| labs.ocr_low_primary | CTA | "Review Values" |
| labs.ocr_low_secondary | CTA | "Retake Photo" |
| labs.ocr_low_tertiary | CTA | "Upload PDF" |
| labs.processing_helper | Helper text | "This can take up to 30 seconds." |
| labs.duplicate_title | Sheet title | "Possible duplicate test" |
| labs.duplicate_helper | Helper text | "We found a recent test that looks similar. What would you like to do?" |
| labs.duplicate_keep_both | CTA | "Keep both" |
| labs.duplicate_replace | CTA | "Replace previous" |
| labs.duplicate_review | CTA | "Review differences" |
| labs.storage_local_only | Toggle | "Store scans on this device only" |
| labs.storage_cloud_optin | Toggle | "Sync scans to cloud" |
| labs.saved_title | Confirmation | "Saved results" |
| labs.saved_helper | Confirmation | "Saved {markers_count} markers." |
| labs.saved_view_trends | CTA | "View trends" |

---

## SETTINGS (Data Sources)

| copy_id | Context | Copy |
|---------|---------|------|
| settings.data_sources_title | Screen title | "Data Sources" |
| settings.data_sources_off_title | Row title | "Product data" |
| settings.data_sources_off_helper | Row helper | "From Open Food Facts (ODbL)" |
| settings.data_sources_user_submitted_title | Row title | "Community products" |
| settings.data_sources_user_submitted_helper | Row helper | "Added by users via label scan" |
| settings.data_sources_disclaimer | Footer | "Verify nutrition labels if unsure." |

---

## ERROR STATES (CROSS-MODULE)

| copy_id | Context | Copy |
|---------|---------|------|
| error.offline_title | Banner | "Working offline" |
| error.offline_helper | Banner | "Changes will sync when connected." |
| error.timeout_title | Modal | "Taking longer than usual" |
| error.timeout_helper | Modal | "Try again?" |
| error.no_data_title | Empty state | "No data yet" |
| error.no_data_helper | Empty state | "Log your first entry to get insights." |
| error.onboarding_profile_exists_title | Modal | "Profile already exists" |
| error.onboarding_profile_exists_helper | Modal | "It looks like you already have a profile. Try signing in instead." |
| error.onboarding_invalid_profile_title | Modal | "Couldn't save profile" |
| error.onboarding_invalid_profile_helper | Modal | "Please check your details and try again." |
| error.onboarding_backfill_failed_title | Banner | "Health data import failed" |
| error.onboarding_backfill_failed_helper | Banner | "We'll retry automatically. Your data is safe." |
| error.onboarding_healthkit_denied_title | Modal | "Health data access needed" |
| error.onboarding_healthkit_denied_helper | Modal | "Life OS works best with Apple Health data. You can enable access in Settings later." |

---

## EMPTY STATES (MODULES)

| copy_id | Context | Copy |
|---------|---------|------|
| empty.training_title | Empty state | "Log your first workout" |
| empty.training_helper | Empty state | "Track sets, reps, or import from Apple Health to personalize your plan." |
| empty.training_primary | CTA | "Log Workout" |
| empty.supplements_title | Empty state | "Track your supplement stack" |
| empty.supplements_helper | Empty state | "Add your supplements to get timing reminders and adherence insights." |
| empty.supplements_primary | CTA | "Add Supplements" |
| empty.labs_title | Empty state | "Upload your first lab test" |
| empty.labs_helper | Empty state | "Scan a lab report to track trends and compare over time." |
| empty.labs_primary | CTA | "Scan Lab Report" |
| empty.ocr_review_title | Empty state | "Review required" |
| empty.ocr_review_helper | Empty state | "We found values, but need your confirmation before saving." |
| empty.ocr_review_primary | CTA | "Review Values" |

---

## LOADING STATES

| copy_id | Context | Copy |
|---------|---------|------|
| loading.ocr_title | Loading state | "Analyzing report..." |
| loading.food_title | Loading state | "Analyzing meal..." |
| loading.plan_title | Loading state | "Building your plan..." |

---

## NOTIFICATIONS

### Morning Brief

| copy_id | Context | Copy |
|---------|---------|------|
| notification.morning_brief_title | Title | "Good morning, {name} ☀️" |
| notification.morning_brief_body | Body | "Here's your daily brief." |

### Positive Reinforcement

| copy_id | Context | Copy |
|---------|---------|------|
| notification.positive_protein_target | Body | "✨ Protein target hit {streak_days} days in a row — your muscle recovery thanks you" |
| notification.positive_sleep_consistency | Body | "🎯 Sleep consistency this week: {consistency_pct}% — that's elite level" |
| notification.positive_pattern_detected | Body | "📈 Pattern detected: {pattern_description}" |

### Celebration Moments

| copy_id | Context | Copy |
|---------|---------|------|
| notification.celebration_checkin | Body | "Just checking in — you've been consistent this week! 💪" |
| notification.celebration_hrv_trend | Body | "Fun fact: Your average HRV improved {hrv_change_pct}% vs last month" |
| notification.celebration_meal_adherence | Body | "Random appreciation: You logged {meal_adherence_pct}% of meals this month. That's exceptional!" |
| notification.celebration_sleep_pattern | Body | "Did you know? Your {best_sleep_day} sleep is consistently your best. Keep protecting it!" |

### Gentle Nudges

| copy_id | Context | Copy |
|---------|---------|------|
| notification.nudge_protein_deficit | Body | "🥗 Lunch idea: You're {protein_deficit}g short on protein. {food_suggestion} would close the gap." |
| notification.nudge_caffeine_timing | Body | "☕ Heads up: Caffeine after {caffeine_cutoff} reduces your sleep quality by {impact_pct}%" |
| notification.nudge_bedtime | Body | "🌙 Optimal bedtime in {minutes_until} minutes for your target {target_hours}h sleep" |
| notification.nudge_workout_prep | Body | "🏋️ Workout in {time_until}: light carbs + water for better performance" |
| notification.nudge_supplement_reminder | Body | "💊 Supplement reminder: {supplement_name} scheduled at {time} ({instruction})" |

### Critical Alerts

| copy_id | Context | Copy |
|---------|---------|------|
| notification.critical_recovery_low | Body | "⚠️ Recovery at {recovery_score}% (Critical). Rest day strongly recommended." |
| notification.critical_sleep_debt | Body | "⚠️ Sleep debt: {debt_hours}+ hours accumulated. Priority: early bedtime tonight." |
| notification.critical_training_load | Body | "⚠️ Training load spike detected (ACWR {acwr_value}). Reduce intensity today." |

---

## PRIVACY & DATA

| copy_id | Context | Copy |
|---------|---------|------|
| privacy.retention_title | Section title | "Data retention" |
| privacy.retention_photos | Row | "Food photos: 30 days" |
| privacy.retention_scans | Row | "Lab scans: 90 days" |
| privacy.retention_helper | Footer | "Originals are deleted after processing; derived data is kept." |
| privacy.anonymization_title | Section title | "Data anonymization" |
| privacy.anonymization_helper | Body | "Aggregated data is anonymized before any analytics processing." |
| privacy.breach_title | Alert title | "Security notice" |
| privacy.breach_body | Alert body | "We detected unusual activity. Your data is secure. Tap for details." |
| privacy.breach_action | CTA | "View details" |

---

## SYNC

| copy_id | Context | Copy |
|---------|---------|------|
| sync.dead_letter_title | Banner | "Some changes couldn't sync" |
| sync.dead_letter_helper | Banner | "Tap to review and retry." |
| sync.dead_letter_discard | CTA | "Discard" |
| sync.dead_letter_retry | CTA | "Retry" |
| sync.conflict_title | Modal title | "Update conflict" |
| sync.conflict_helper | Modal body | "This item was updated on another device. Choose which version to keep." |
| sync.conflict_keep_local | CTA | "Keep mine" |
| sync.conflict_keep_server | CTA | "Use latest" |

---

## NOTES

- Do not change capitalization or punctuation without updating this catalog.
- Keep CTAs concise (1-3 words) and consistent across modules.

---

## CHANGELOG

### v1.17 (February 16, 2026)
- Added missing Settings destination copy IDs for sync status metrics and actionable controls (`settings_sync_*`, `settings_save`, `settings_saved`)
- Added notification/privacy settings field labels (`settings_morning_brief_enabled`, `settings_critical_only`, `settings_menstrual_local_only`, etc.)
- Added Insights list/detail copy IDs for non-placeholder UI (`insights_empty_*`, `insights_confidence_prefix`, `insights_category_prefix`, `insights_review_required_message`)

### v1.16 (February 16, 2026)
- Added missing `error.*` user-facing copy IDs used by typed module errors (Nutrition, Training, Supplements, Labs, Settings, Sync, HealthKit, Recovery, Privacy)
- Added missing Nutrition input method copy IDs for V2 flows (`nutrition_method_vision`, `nutrition_method_batch`, `nutrition_method_template`)

### v1.15 (February 16, 2026)
- Added app string catalog IDs used by iOS implementation (auth, onboarding, recovery, home, settings, deep link destinations)

### v1.14 (February 9, 2026)
- Added `diary.review_required` CTA for review-required flows

### v1.13 (February 9, 2026)
- Added sleep manual entry copy IDs (`sleep.manual_*`)
- Added privacy & data copy IDs (`privacy.retention_*`, `privacy.anonymization_*`, `privacy.breach_*`)
- Added sync copy IDs (`sync.dead_letter_*`, `sync.conflict_*`)

### v1.12 (February 9, 2026)
- Added notification body copy IDs (Morning Brief, Positive Reinforcement, Celebration Moments, Gentle Nudges, Critical Alerts) and notification settings labels.

### v1.11 (February 4, 2026)
- Added minimal watchOS companion copy IDs (Open on iPhone, Due soon, Last updated, Estimate badge)

### v1.10 (February 4, 2026)
- Added missing Nutrition CTAs for consistency: add-to-meal + log-portion action

### v1.9 (February 4, 2026)
- Added Nutrition label scan + product review copy IDs (CIS-critical barcode fallback)
- Added Meal Prep (batch recipes) copy IDs (library, create modes, review, log portion)
- Added Settings “Data Sources” copy IDs (Open Food Facts attribution + community products)

### v1.8 (February 4, 2026)
- Added Training workout logging copy IDs (exercise picker, add set, start planned/empty)
- Added Nutrition template save/naming copy IDs

### v1.7 (February 4, 2026)
- Added Sleep detail screen copy IDs

### v1.6 (February 4, 2026)
- Added Nutrition logging copy IDs (method picker, barcode, voice, search, portion, quick add)
- Added Labs async/duplicate handling + storage toggle copy IDs

### v1.5 (February 3, 2026)
- Added unified Diary screen copy IDs

### v1.4 (February 3, 2026)
- Added Auth, Onboarding, Nutrition diary copy IDs
- Added training diary filter and conflict copy IDs

### v1.3 (February 3, 2026)
- Added empty/loading state copy

### v1.2 (February 3, 2026)
- Added training plan failure and error CTAs

### v1.1 (February 3, 2026)
- Added localization spec and copy usage rules

## APP STRING CATALOG IDS

| copy_id | Context | Copy |
|---------|---------|------|
| app_name | App UI | "Life OS" |
| auth_email_placeholder | App UI | "email@example.com" |
| auth_email_sign_in_title | App UI | "Email Sign In" |
| auth_email_subtitle | App UI | "We'll send you a verification code." |
| auth_email_title | App UI | "Enter your email" |
| auth_error_invalid_credential | App UI | "Invalid sign-in credential." |
| auth_error_network_unavailable | App UI | "No network connection. Your data is saved locally." |
| auth_error_session_expired | App UI | "Your session has expired. Please sign in again." |
| auth_invalid_apple_credential | App UI | "Invalid Apple credential." |
| auth_otp_placeholder | App UI | "000000" |
| auth_otp_sent_prefix | App UI | "Sent to" |
| auth_otp_title | App UI | "Enter verification code" |
| auth_subtitle | App UI | "Your health optimization companion" |
| calories | App UI | "Calories" |
| cancel | App UI | "Cancel" |
| carbs | App UI | "Carbs" |
| connect_apple_health | App UI | "Connect Apple Health" |
| continue | App UI | "Continue" |
| continue_with_email | App UI | "Continue with Email" |
| date | App UI | "Date" |
| fat | App UI | "Fat" |
| get_started | App UI | "Get Started" |
| getting_started | App UI | "Getting Started" |
| health_screening | App UI | "Health Screening" |
| home_log_prefix | App UI | "Open" |
| home_next_action_subtitle | App UI | "Complete your morning wellness check to get personalized recommendations." |
| home_recovery_card_accessibility | App UI | "Recovery score card. Calibrating. Connect Apple Health to see your recovery score." |
| home_recovery_unavailable | App UI | "Recovery score unavailable" |
| home_start_wellness_check_accessibility | App UI | "Start wellness check" |
| home_start_wellness_check_hint | App UI | "Opens the morning wellness check form" |
| hydration | App UI | "Hydration" |
| hydration_default_progress | App UI | "0 / 2,500 mL" |
| insights_coming_soon_subtitle | App UI | "After a few days of logging, Life OS will start generating personalized insights based on your recovery, nutrition, and training patterns." |
| insights_coming_soon_title | App UI | "Insights Coming Soon" |
| insights_empty_title | App UI | "No insights yet" |
| insights_empty_subtitle | App UI | "Keep logging your day and we'll surface patterns with confidence labels." |
| insights_confidence_low_badge | App UI | "Low confidence" |
| insights_confidence_prefix | App UI | "Confidence:" |
| insights_category_prefix | App UI | "Category:" |
| insights_category_recovery | App UI | "Recovery" |
| insights_category_nutrition | App UI | "Nutrition" |
| insights_category_training | App UI | "Training" |
| insights_category_sleep | App UI | "Sleep" |
| insights_category_supplement | App UI | "Supplements" |
| insights_category_health | App UI | "Health" |
| insights_category_experiment | App UI | "Experiment" |
| insights_category_general | App UI | "General" |
| insights_review_required_message | App UI | "This insight needs review before you act on it." |
| insights_detail_not_found | App UI | "Insight not found." |
| loading | App UI | "Loading..." |
| log_food | App UI | "Log Food" |
| micro_zone_peak | App UI | "Peak" |
| micro_zone_solid | App UI | "Solid" |
| micro_zone_strong | App UI | "Strong" |
| next_best_action | App UI | "Next Best Action" |
| no_meals_logged | App UI | "No meals logged today" |
| no_supplements_taken | App UI | "No supplements taken" |
| no_workouts_today | App UI | "No workouts today" |
| not_completed | App UI | "Not completed" |
| nutrition | App UI | "Nutrition" |
| nutrition_method_barcode | App UI | "Barcode" |
| nutrition_method_manual | App UI | "Manual" |
| nutrition_method_photo | App UI | "Photo" |
| nutrition_method_vision | App UI | "Vision" |
| nutrition_method_batch | App UI | "Batch" |
| nutrition_method_template | App UI | "Template" |
| nutrition_method_voice | App UI | "Voice" |
| onboarding_apple_health_description | App UI | "Connect Apple Health so Life OS can read your HRV, resting heart rate, sleep, and temperature data." |
| onboarding_apple_health_title | App UI | "Apple Health" |
| onboarding_backfill_description | App UI | "We're computing your personal baselines from the last 14 days of health data." |
| onboarding_backfill_title | App UI | "Analyzing Your Data" |
| onboarding_complete_subtitle | App UI | "Start logging your first meal, supplement, or workout." |
| onboarding_health_screening_description | App UI | "Help us customize the experience. Some conditions affect which features we show." |
| onboarding_profile_description | App UI | "We'll personalize Life OS based on your goals and preferences." |
| protein | App UI | "Protein" |
| recovery_announcement_prefix | App UI | "Recovery:" |
| recovery_calibrating | App UI | "Calibrating..." |
| recovery_connect_health | App UI | "Connect Apple Health to see your recovery score" |
| recovery_percent_label | App UI | "percent" |
| recovery_score | App UI | "Recovery Score" |
| recovery_zone_accessibility_prefix | App UI | "Recovery zone:" |
| recovery_zone_caution | App UI | "Caution" |
| recovery_zone_critical | App UI | "Critical" |
| recovery_zone_desc_caution | App UI | "Take it easy" |
| recovery_zone_desc_critical | App UI | "Rest required" |
| recovery_zone_desc_optimal | App UI | "Ready for anything" |
| recovery_zone_desc_ready | App UI | "Good to go" |
| recovery_zone_optimal | App UI | "Optimal" |
| recovery_zone_ready | App UI | "Ready" |
| send_code | App UI | "Send Code" |
| settings_about_section | App UI | "About" |
| settings_account_section | App UI | "Account" |
| settings_apple_health | App UI | "Apple Health" |
| settings_build | App UI | "Build" |
| settings_build_value | App UI | "1" |
| settings_data_section | App UI | "Data" |
| settings_export_data | App UI | "Export Data" |
| settings_save | App UI | "Save" |
| settings_saved | App UI | "Saved" |
| settings_health_flags | App UI | "Health Flags" |
| settings_notifications | App UI | "Notifications" |
| settings_preferences_section | App UI | "Preferences" |
| settings_privacy | App UI | "Privacy" |
| settings_profile | App UI | "Profile" |
| settings_sync_status | App UI | "Sync Status" |
| settings_sync_pending | App UI | "Pending outbox events" |
| settings_sync_failed | App UI | "Permanent failures" |
| settings_sync_oldest_pending | App UI | "Oldest pending age" |
| settings_sync_replay_now | App UI | "Replay Queue" |
| settings_sync_pull_now | App UI | "Pull Now" |
| settings_sync_engine_unavailable | App UI | "Sync engine unavailable" |
| settings_morning_brief_enabled | App UI | "Morning Brief" |
| settings_positive_enabled | App UI | "Positive notifications" |
| settings_nudges_enabled | App UI | "Nudges" |
| settings_celebration_enabled | App UI | "Celebrations" |
| settings_critical_only | App UI | "Critical alerts only" |
| settings_max_total_per_day | App UI | "Max total per day" |
| settings_max_nudges_per_day | App UI | "Max nudges per day" |
| settings_max_positive_per_day | App UI | "Max positive per day" |
| settings_menstrual_local_only | App UI | "Menstrual data local only" |
| settings_medical_scan_local_only | App UI | "Medical scans local only" |
| settings_cloud_backup_enabled | App UI | "Cloud backup for health flags" |
| settings_vector_opt_in | App UI | "Vector memory opt-in" |
| settings_analytics_consent | App UI | "Analytics consent" |
| settings_cloud_ocr_enabled | App UI | "Cloud OCR enabled" |
| settings_units_locale | App UI | "Units & Locale" |
| settings_version | App UI | "Version" |
| settings_version_value | App UI | "1.0.0 (Phase 1)" |
| sign_in | App UI | "Sign In" |
| sleep_supportive_both_outside | App UI | "Your stage pattern is a little off your usual targets today. Focus on consistency rather than a perfect night." |
| sleep_supportive_deep_outside | App UI | "Deep sleep is slightly outside your age-adjusted target. Gentle routine tweaks can help over time." |
| sleep_supportive_in_range | App UI | "Your deep and REM patterns are in a healthy range for your age." |
| sleep_supportive_more_data | App UI | "Sleep trends need a bit more data. Keep a steady routine and review again tomorrow." |
| sleep_supportive_rem_outside | App UI | "REM sleep is slightly outside your age-adjusted target. Keep your routine steady and reassess over several nights." |
| sleep_title | App UI | "Sleep" |
| start_wellness_check | App UI | "Start Wellness Check" |
| supplements | App UI | "Supplements" |
| tab_diary | App UI | "Diary" |
| tab_home | App UI | "Home" |
| tab_insights | App UI | "Insights" |
| tab_settings | App UI | "Settings" |
| training | App UI | "Training" |
| verify | App UI | "Verify" |
| water | App UI | "Water" |
| wellness | App UI | "Wellness" |
| workout | App UI | "Workout" |
| your_profile | App UI | "Your Profile" |
| youre_all_set | App UI | "You're all set!" |
| nutrition_review_gate_message | App UI | "Low confidence detection. Please review and edit before saving." |
| clinician_disclaimer | App UI | "Consult your clinician." |
| error.nutrition.invalid_macros | Error UI | "Invalid macronutrient data: %@" |
| error.nutrition.image_too_large | Error UI | "Photo exceeds %d MB" |
| error.nutrition.barcode_not_found | Error UI | "Product with barcode %@ not found" |
| error.nutrition.catalog_unavailable | Error UI | "Food catalog temporarily unavailable" |
| error.nutrition.template_empty | Error UI | "Template contains no food items" |
| error.nutrition.duplicate_log | Error UI | "This meal has already been logged" |
| error.training.invalid_set | Error UI | "Invalid set data: %@" |
| error.training.workout_active | Error UI | "A workout is already in progress" |
| error.training.plan_limit | Error UI | "Maximum %d plans reached" |
| error.training.exercise_not_found | Error UI | "Exercise not found" |
| error.supplements.schedule_conflict | Error UI | "Schedule conflicts with an existing supplement reminder" |
| error.supplements.invalid_dose | Error UI | "Dose is outside a safe range" |
| error.supplements.reminder_window | Error UI | "Reminder time falls inside quiet hours" |
| error.labs.unsupported_document | Error UI | "This lab document format is not supported yet" |
| error.labs.extraction_failed | Error UI | "Unable to extract markers from this scan" |
| error.labs.low_confidence | Error UI | "Low confidence extraction. Please review values before saving." |
| error.settings.export_failed | Error UI | "Unable to prepare your export right now" |
| error.settings.deletion_failed | Error UI | "Account deletion request failed" |
| error.settings.consent_version | Error UI | "Please re-confirm consent for the latest policy version" |
| error.sync.network_unavailable | Error UI | "No internet connection" |
| error.sync.auth_required | Error UI | "Re-authentication required" |
| error.sync.server_error | Error UI | "Server error %d: %@" |
| error.sync.conflict | Error UI | "Data conflict in %@" |
| error.sync.watermark_corrupted | Error UI | "Sync watermark corrupted for %@" |
| error.sync.max_retries | Error UI | "Maximum send attempts exceeded" |
| error.healthkit.not_available | Error UI | "HealthKit is not available on this device" |
| error.healthkit.auth_denied | Error UI | "Health data access denied" |
| error.healthkit.no_data | Error UI | "No data available for this date" |
| error.healthkit.invalid_sample | Error UI | "Invalid measurement: %@" |
| error.healthkit.sdnn_too_low | Error UI | "SDNN too low (%.1fms) — rejected as noise" |
| error.recovery.insufficient_baseline | Error UI | "Not enough data days (%d/%d) for baseline calculation" |
| error.recovery.no_state | Error UI | "No physiological data for %@" |
| error.recovery.computation_failed | Error UI | "Computation error: %@" |
| error.privacy.export_in_progress | Error UI | "Data export is already in progress" |
| error.privacy.export_not_ready | Error UI | "Data export is not ready yet" |
| error.privacy.deletion_scheduled | Error UI | "Account deletion scheduled for %@" |
