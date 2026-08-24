# Phase 9 - Training Recovery

Date: 2026-06-23

## Verdict

Status: PASS.

Training, sleep, recovery, prediction, weekly strategy, insights, and recommendation flows were reviewed against current iOS and Supabase contracts. The phase found a real contract gap in the workout read API family: weekly training metrics were already carried as a risk from phase 2, and the same spec surface also expected daily and summary read routes. I closed the whole workout aggregate route family instead of leaving adjacent gaps for later.

Production code changed in this phase:

- Added `api-workouts-daily` for authenticated local-date workout sessions.
- Added `api-workouts-summary` for authenticated rolling workout volume/TRIMP/ACWR summary.
- Added `api-workouts-weekly` for authenticated ISO week workout buckets.
- Registered all three functions in Supabase config, added local Edge E2E scenarios, and aligned iOS rate-limit policy/tests.

## Fixed Production Gaps

| Gap | Fix | Evidence |
| --- | --- | --- |
| `GET /api/workouts/daily?date=...` contract had no deployed Edge function | Added `supabase/functions/api/workouts/daily/index.ts`; validates GET/date before auth, resolves user context with standard tier, filters by `user_id`, `session_date`, and `deleted_at IS NULL`, and returns ordered sessions. | `supabase/functions/api/workouts/daily/index.ts:15` through `:51`; `supabase/config.toml:94`; `deno-workouts-aggregate-routes-tests.log`: daily route ok. |
| `GET /api/workouts/summary?days=30` contract had no deployed Edge function | Added `supabase/functions/api/workouts/summary/index.ts`; validates `days` 1...90, computes timezone-local rolling range, aggregates non-negative volume/TRIMP, and returns latest ACWR from `training_loads`. | `supabase/functions/api/workouts/summary/index.ts:21` through `:93`; `supabase/config.toml:98`; `deno-workouts-aggregate-routes-tests.log`: summary route ok. |
| `GET /api/workouts/weekly?from=...&to=...` was missing from phase 2 contract reconciliation | Added `supabase/functions/api/workouts/weekly/index.ts`; validates max 26-week range, groups by ISO Monday week start, rounds TRIMP values, and ignores invalid date rows. | `supabase/functions/api/workouts/weekly/index.ts:27` through `:95`; `supabase/config.toml:102`; `workouts_weekly.test.ts:8` and `:87`. |
| New read functions were not present in local Supabase E2E/rate-limit coverage | Added E2E scenarios and client tier assertions. | `supabase/functions/tests/edge_local_e2e.ts:2582` through `:2631`; `ios/LifeOS/Modules/Shared/Network/RateLimitPolicy.swift:101` through `:103`; `ios/LifeOSTests/LowCoverageUtilitiesTests.swift:2393` through `:2395`. |

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| Targeted training/recovery `xcodebuild test` for `TrainingServiceTests`, `SleepTargetEngineTests`, `RecoveryEngineTests`, `RecoveryZoneTests`, `PredictionServiceTests`, and `WeeklyStrategyServiceTests` | PASS | `phase-9-logs/ios-training-recovery-gate-final-rerun.log`: 54 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| `deno test -A supabase/functions/tests/daily_insights.test.ts supabase/functions/tests/next_best_action.test.ts supabase/functions/tests/predictive_context.test.ts` | PASS | `phase-9-logs/deno-insights-recovery-tests-final.log`: `ok | 31 passed | 0 failed`; `exit=0`. |

Retry context:

- `phase-9-logs/ios-training-recovery-gate.log` exited 75 because the first wrapper used an empty same-shell `DERIVED_DATA_PATH` expansion. The authoritative final rerun is `ios-training-recovery-gate-final-rerun.log`.
- `phase-9-logs/edge-local-e2e-after-weekly-route.log` exited 1 because it bypassed the wrapper and missed Supabase env vars. The authoritative local E2E rerun is `edge-local-e2e-after-workout-aggregate-routes.log`.

## Additional Targeted Proof

| Command | Result | Evidence |
| --- | --- | --- |
| `deno fmt --check` for new/changed workout Edge files and E2E tests | PASS | `phase-9-logs/deno-workout-route-fmt-check-final.log`: `Checked 6 files`; `exit=0`. |
| `deno test -A supabase/functions/tests/workouts_aggregate_routes.test.ts supabase/functions/tests/workouts_weekly.test.ts` | PASS | `phase-9-logs/deno-workouts-aggregate-routes-tests.log`: 5 tests, 0 failures; daily, summary, weekly, method validation, and query validation pass; `exit=0`. |
| iOS rate-limit targeted test | PASS | `phase-9-logs/ios-rate-limit-workout-route-tests-final.log`: 2 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| Sleep detail/calendar targeted iOS test | PASS | `phase-9-logs/ios-sleep-calendar-detail-tests.log`: 2 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| Extra training and HealthKit flow iOS tests | PASS | `phase-9-logs/ios-training-extra-flow-tests.log`: 21 tests, 0 failures; covers HealthKit sync, import conflicts, delete/undo, rest timer, training calendar fallback, and plan/calendar state. |
| Extra recommendation/recovery helper Deno tests | PASS | `phase-9-logs/deno-coverage-true-last-mile-tests.log`: 13 tests, 0 failures; `exit=0`. |
| Full local Supabase Edge E2E wrapper | PASS | `phase-9-logs/edge-local-e2e-after-workout-aggregate-routes.log`: `api-recovery`, `api-wellness`, `api-recommendations`, `api-insights-daily`, `api-weekly-strategy`, `api-workouts-daily`, `api-workouts-summary`, and `api-workouts-weekly` all OK; `exit=0`. |
| Post-E2E Supabase cleanup check | PASS | `supabase status` failed with `No such container: supabase_db_life-os`, confirming the wrapper left no local stack running. |

## Domain Verification Matrix

| Flow | Status | Evidence |
| --- | --- | --- |
| Manual workout logging | PASS | `TrainingServiceTests` prove nested session/exercise/set persistence and outbox queueing to `api-workouts-log`; `TrainingServiceTests.swift:268` through `:294`. |
| Update/delete/undo | PASS | Route events use PATCH, DELETE, and POST undo paths, and undo restores `deletedAt`; `TrainingServiceTests.swift:297` through `:417`; extra failure coverage in `CoverageFinalPushTests.swift:10468` through `:10504`. |
| Rest timer and set draft | PASS | `WorkoutLogViewModel` starts and clears the active rest timer, then persists the set with `restAfterSeconds`; `TrainingServiceTests.swift:572` through `:606`. |
| Imported HealthKit workouts | PASS | Imported workouts load read-only for exercise editing; imported note/effort update path preserves imported session constraints; `TrainingServiceTests.swift:516` through `:570`; `CoverageFinalPushTests.swift:10141` through `:10208`. |
| HealthKit import conflicts | PASS | Conflict merge, keep-manual, keep-imported, no-conflict state, and conflict-failure copy are covered; `CoverageFinalPushTests.swift:10100` through `:10115`, `:10210` through `:10287`, and `:10506` through `:10602`. |
| HealthKit daily sync | PASS | Insert/update/outbox behavior, partial data, environment failure fallback, and local-day handling are covered by `HealthSyncManagerFlowIntegrationTests`; `HealthSyncManagerFlowTests.swift:145` through `:260`; extra test log shows 7 HealthSync tests green. |
| Training calendar | PASS | Calendar labels and empty states include "Recovery day", "No duration yet", and "Load building"; remote and local fallback paths are covered; `TrainingCalendarSupportTests.swift:40` through `:187`. |
| Training plans | PASS | Plan generation normalizes days/duration/injuries, active-plan limit is fail-closed, updates validate payload, and recovery-critical adjustment maps to mobility swap; `TrainingServiceTests.swift:756` through `:980`. |
| Sleep detail/calendar | PASS | Detail loader, stage/trend feedback, low-confidence badge, calendar month status, rendered sections, and route decoding are covered; `CoverageFinalPushTests.swift:2969` through `:3096` and `:3132` through `:3155`; targeted sleep test passes. |
| Sleep targets and medical boundary | PASS | Age bands match spec and supportive copy excludes danger, critical, and diagnosis wording; `SleepTargetEngineTests.swift:13` through `:31`. |
| Recovery zones and recovery engine | PASS | Recovery zone clamp/range/accessibility tests plus recovery engine score branch tests pass in the 54-test mandatory gate. |
| Prediction service | PASS | Predictive simulation route use, payloads, non-runtime short-circuit, API error propagation, and encoding/network wrapping pass in `PredictionServiceTests`. |
| Weekly strategy | PASS | Weekly strategy remote fetch/persist, local fallback, generated report use, and stale-insight preservation pass in `WeeklyStrategyServiceTests`. |
| Insights and recommendations | PASS | Daily insights, next-best-action, predictive context, local Edge E2E `api-insights-daily`, `api-recommendations`, `api-recovery`, `api-wellness`, and `api-weekly-strategy` all pass. |

## Advice Safety and Copy Boundaries

Low-confidence and watch behavior are fail-closed:

- `determineNextBestAction` routes low-confidence actions to diary review instead of direct action; `supabase/functions/_shared/next_best_action.ts:62` through `:68`.
- `adaptNextBestActionForWatch` forces low-confidence actions to `open_on_iphone`; `supabase/functions/_shared/next_best_action.ts:181` through `:188`; test proof in `next_best_action.test.ts:105` through `:123`.
- Watch action labels use copy IDs such as `global.open_on_iphone`; `supabase/functions/_shared/next_best_action.ts:30` through `:34`.

Medical-boundary wording is explicit:

- Sleep score UI says "Quality score, not medical"; `SleepDetailSupport.swift:1245` through `:1251`.
- Sleep missing/permission empty states use visible safe copy IDs and text; `SleepDetailSupport.swift:44` through `:70`.
- Sleep target feedback test blocks alarm/diagnostic language; `SleepTargetEngineTests.swift:21` through `:31`.
- Daily insights can mark a low recovery day as critical priority, but the recommendation title remains behavioral/restorative, not diagnostic: "Make today a restoration day"; test proof in `daily_insights.test.ts:687` through `:784`.

Error/empty/missing-permission states have visible copy:

- Training errors expose localized IDs and safe messages for invalid set, cloud requirement, missing workout, expired undo, and imported-workout edit restriction; `AppErrors.swift:72` through `:100`.
- HealthKit not available, denied, no data, invalid sample, and noisy SDNN have localized descriptions; `AppErrors.swift:194` through `:214`.
- Training calendar empty state copy is verified in tests; `TrainingCalendarSupportTests.swift:103` through `:106`.
- Sleep permission missing/denied/unavailable empty copy is explicit; `SleepDetailSupport.swift:44` through `:70`.

## Edge Contract Review

| Surface | Status | Evidence |
| --- | --- | --- |
| `api-workouts-log` / `api-workouts` | PASS | Full local E2E creates, replays idempotency, reads detail, patches, deletes, and undoes a workout before aggregate reads. |
| `api-workouts-calendar` | PASS | Full local E2E verifies authenticated calendar day response, and iOS route decoding test covers workout calendar payloads. |
| `api-workouts-daily` | PASS | Unit-level Edge test asserts user/date/deleted filters and response shape; full local E2E route passes. |
| `api-workouts-summary` | PASS | Unit-level Edge test asserts 30-day rolling query, latest ACWR query, rounding, and validation; full local E2E route passes. |
| `api-workouts-weekly` | PASS | Unit-level Edge test asserts 26-week cap, ISO week buckets, null/invalid row handling, and response shape; full local E2E route passes. |
| `api-recovery`, `api-wellness`, `api-recommendations`, `api-insights-daily`, `api-weekly-strategy` | PASS | Mandatory Deno tests and full local Edge E2E pass after the workout aggregate routes were added. |

## Acceptance Criteria

| Criterion | Status |
| --- | --- |
| Manual workout logging, HealthKit import, conflicts, undo, calendar, plans, and rest timer paths are verified. | PASS |
| Sleep detail/calendar, recovery zones, prediction service, weekly strategy, insights, and notification recommendations match documented invariants. | PASS |
| Domain unit tests pass for training, sleep, recovery, predictions, and weekly strategy. | PASS |
| Edge recommendation/recovery/wellness tests pass. | PASS |
| User-facing advice obeys low-confidence and medical-boundary rules. | PASS |
| Error/empty/missing-permission states have copy IDs or visible safe copy. | PASS |

## Notes

- Simulator logs about unpaired WatchConnectivity and Family Controls monitor authorization are expected in local test context and did not fail any test.
- Existing Swift concurrency warnings appeared in large test files during targeted builds, but no new warning-gated failure appeared in this phase.
- No production Supabase deployment was attempted in this phase; release operations remain covered by later phases.
