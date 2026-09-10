# Experiments B-06 fixes — 2026-09-09

## Implemented

- Completion now produces and persists baseline/intervention means and sample SDs for the primary metric. Rows from other metrics, washout, inconsistent timeline phases, nonfinite values and protocol violations are excluded. Mixed units prohibit comparison. Historical edits recompute completed results.
- At least three protocol-followed measurements per phase are required before presenting a descriptive effect/direction. Cohen's d uses pooled sample SD and is absent for zero variance. A growing value is only favorable for explicitly recognized ascending scales; stress/fatigue/pain have the opposite direction. Unknown metrics remain direction-neutral.
- The iOS detail view uses the same phase/metric/adherence/unit rules and shows phase means and sample counts rather than the oldest/newest endpoints. Insufficient data is explicitly reported. Invalid numeric daily input cannot silently become zero. Multi-metric server logs use one upsert statement and reject malformed/unplanned metrics before any write.
- Added an idempotent owner-scoped stop endpoint and Stop action: the iOS status update and replay event are atomic, reminders are cancelled immediately, and an abandoned run refuses new server logs.
- Server create/replay responses no longer claim to schedule reminders. The iOS application now actually schedules them through NotificationScheduleCoordinator and NotificationEngine, using local OS requests even for cloud accounts. New experiments default to 18:00; the coordinator handles daily/weekly recurrence, skips already-logged days and stops at the lifecycle end. Up to 30 upcoming days are scheduled (the default 21-day protocol fits completely); longer experiments replenish on existing foreground refresh.
- Reminder delivery retains first-insight, authorization, category, critical-only, quiet-hour, cap and dedup checks. Permission is requested on explicit experiment start without requiring APNs entitlement. Denial or OS add failure rolls back notification intent/log records and is not represented as scheduled. Detail UI shows the next successfully scheduled time, or explains that no reminder is pending. Stopped/completed/deleted experiments and logged days are excluded during reconciliation; cancellation removes both system request and local records.

## Statistical interpretation

These are descriptive within-person comparisons of sequential daily observations. They do not establish causal treatment effects or independent observations. p_value, significant and confidence intervals intentionally remain NULL rather than fabricating inferential certainty from an unrandomized baseline/intervention design. The result text explicitly states this limitation. The existing database ai_interpretation field stores this deterministic explanation, not an unperformed AI analysis.

## Verification

- `deno check supabase/functions/api/experiments/index.ts` passed.
- `deno test --allow-env --allow-read --allow-net supabase/functions/tests/experiment_analysis.test.ts`: 10 passed, including actual handler lifecycle/result persistence, historical recalculation, atomic log validation, malformed payloads, create/replay reminder truthfulness, and scoped/idempotent stopping. These handler tests use the repository HTTP/PostgREST harness; they are not live database evidence.
- Central parent-run second iOS test log records passes for new phase-mean, permission-failure cleanup, cloud/local delivery/cap, reminder schedule and system cancellation regression tests. The parent owns final full-suite/build evidence; two additional PushNotificationManager permission/system-failure tests and the final Stop/UI-status additions may require its subsequent run.
- Syntax parsing of modified Swift source/tests passed. No new Swift files or project registration needed.

## Files

- supabase/functions/api/experiments/index.ts, analysis.ts
- supabase/functions/tests/experiment_analysis.test.ts
- ios/LifeOS/Modules/Insights/InsightDetailView.swift
- ios/LifeOS/Modules/Shared/Notifications/NotificationEngine.swift
- ios/LifeOS/Modules/Shared/Notifications/PushNotificationManager.swift
- ios/LifeOSTests/NotificationEngineTests.swift
- ios/LifeOSTests/PushNotificationManagerTests.swift

Physical OS notification delivery and cancellation while the app remains closed after a change made on another device require device verification. Local pending requests reconcile when the app receives/refetches current state and foreground scheduling refresh runs.
# Offline create replay follow-up

The create request now carries the original `baseline_start_date`; the server validates it and derives every phase from it instead of the upload date. Existing queued creates are enriched from their stored local experiment before dispatch. This prevents measurements recorded before a delayed upload from being rejected or shifted into another phase. Added an end-to-end handler regression (historical create → first baseline log → idempotent replay), invalid/future anchor validation, an iOS outbox transport regression and an assertion against the actual start payload. Experiment handler suite: 12/12 passing; sleep handler suite: 3/3 passing.
