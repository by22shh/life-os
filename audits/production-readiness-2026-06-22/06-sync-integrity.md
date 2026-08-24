# Phase 7 - Sync Integrity

Date: 2026-06-23

## Verdict

Status: PASS.

The sync contract gate and targeted sync/identity/load/database suites pass on the warmed iOS build cache. The first fresh DerivedData attempt failed while SwiftPM tried to clone GRDB's `SQLiteLib` submodule from GitHub; that was an infrastructure/network checkout failure, not an app failure. This phase made one documentation fix: `life_os_data_lineage_matrix.md` is now aligned with the current local-day/timezone fields, canonical lab measurement shape, and offline sync queue contract.

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| `DERIVED_DATA_PATH=/tmp/lifeos-ios-gate bash scripts/run_ios_sync_contract_gate.sh` | PASS | `phase-7-logs/ios-sync-contract-gate-final.log`: `SyncTableRegistryTests` 2/2, `SyncModelContractTests` 8/8, `SyncEnginePerfBenchTests` 2/2; 12 tests, 0 failures; `Sync contract gate passed`; `exit=0`. |
| Targeted `xcodebuild test` for `SyncEngineControlFlowTests`, `SyncEngineLoadTests`, `UserIdentityReconcilerTests`, `WeightResolutionDatabaseTests` | PASS | `phase-7-logs/targeted-sync-tests.log`: 55 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |

Retry context:

- `phase-7-logs/ios-sync-contract-gate.log`: fresh `/tmp/lifeos-sync-gate` failed during SwiftPM checkout of GRDB `SQLiteLib` because GitHub egress failed.
- `phase-7-logs/ios-sync-contract-gate-warmed.log`: the test suite itself passed, but the shell wrapper used a read-only zsh variable name while capturing status.
- `phase-7-logs/ios-sync-contract-gate-final.log`: clean rerun with the warmed `/tmp/lifeos-ios-gate` cache exited 0.

## Fixture and Contract Parity

| Check | Status | Evidence |
| --- | --- | --- |
| Fixture JSON health | PASS | `phase-7-logs/fixture-parity-summary.log`: 42 fixtures, `invalid_json=0`. |
| Registry coverage | PASS | `SyncTableRegistryTests.testSyncTableRegistryCoversEverySyncableTable` proves every `SyncableTable` has a date-column mapping. |
| Critical date-window columns | PASS | `SyncTableRegistryTests.testSyncTableRegistryUsesExpectedColumnsForDateWindowedTables` proves `food_logs.logged_date`, `hydration_logs.logged_date`, `sleep_logs.sleep_date`, `workout_sessions.session_date`, `supplement_logs.taken_date`, `physiological_states.date`, `daily_nutrition_targets.date`, `training_loads.date`, and `wellness_checks.date`. |
| Model contract groups | PASS | `SyncModelContractTests` covers Core, Nutrition, Training, Supplements, SleepCycle, Health, AI, OnboardingPrivacy fixture groups. |
| Health measurement canonical shape | PASS | `SyncFixtureContractGateTests` requires `marker_id`, `measured_at`, `source_scan_id`, `source_type`, `confidence`, `manually_verified`, forbids legacy `medical_scan_id`, `biomarker_name`, `measured_date`, `ai_confidence`, `user_corrected`, and enforces date-only `measured_at`. |

The direct parity summary for `health_measurement.json` showed canonical keys only:

`confidence,created_at,id,manually_verified,marker_id,measured_at,notes,original_label,original_unit,original_value,reference_range_high,reference_range_low,source_scan_id,source_type,status,unit,updated_at,user_id,value`

## Timezone and Local-Day Matrix

| Domain | Local-day source | Timezone/offset source | Verification |
| --- | --- | --- | --- |
| Nutrition | `food_logs.logged_date` | `logged_timezone`, `logged_utc_offset_minutes` | Supabase schema and iOS migration define all three; registry uses `logged_date`; Nutrition tests query by `logged_date`. |
| Workouts | `workout_sessions.session_date` | `started_timezone`, `started_utc_offset_minutes` | Supabase schema and iOS migration define all three; registry uses `session_date`; training/HealthKit paths query by `session_date`. |
| Hydration | `hydration_logs.logged_date` | `logged_timezone`, `logged_utc_offset_minutes` | Supabase schema and iOS migration define all three; registry uses `logged_date`; fixture contract includes `hydration_log`. |
| Supplements | `supplement_logs.taken_date` | `taken_timezone`, `taken_utc_offset_minutes` | Supabase schema and iOS migration define all three; registry uses `taken_date`; widget/watch/notification paths query by `taken_date`. |
| Sleep | `sleep_logs.sleep_date` | `sleep_timezone`, `sleep_utc_offset_minutes` | Supabase schema and iOS migration define all three; `DatabaseMigrationTests` prove decode/insert compatibility for `sleep_date`; registry uses `sleep_date`. |
| Labs | `health_measurements.measured_at` date-only for server contract; local DB still backfills `measured_date` for legacy compatibility | Lab scan rows sync by timestamp; measurements normalize legacy `measured_date` into canonical `measured_at`/`source_scan_id` shape | `SyncFixtureContractGateTests`, `HealthMeasurementContractTests`, and `SyncEngineControlFlowTests.testPushPendingEventsUploadsLabScanAssetAndUpgradesLegacyMedicalScanOutbox`. |
| Body composition | `body_composition.measured_date` | `measured_timezone`, `measured_utc_offset_minutes` | Supabase triggers and iOS V28 migration backfill local day/timezone; registry uses `measured_date`; `WeightResolutionDatabaseTests` pass. |

## Offline Queue, Retry, Dead-Letter, and Conflict Coverage

| Area | Status | Evidence |
| --- | --- | --- |
| Queue schema | PASS | Local migrations define `local_meta`, `sync_state`, and `outbox_events` with `status`, `attempt_count`, `next_attempt_at`, error fields, `user_visible_blocker`, and later `idempotency_key`. |
| Large outbox | PASS | `SyncEngineLoadTests.testPushPendingEventsHandlesLargeOutboxVolume` pushes 500 pending events to succeeded with zero pending rows. |
| Retry and idempotency | PASS | `testPushPendingEventsRetriesAndPreservesIdempotencyAcrossRounds` proves retries preserve the same idempotency key; `DesignAndSyncModelCoverageTests.testRetryConfigBoundsAndCap` locks base delay, multiplier, cap, attempts, and jitter. |
| Stale in-flight recovery | PASS | `SyncEngineControlFlowTests.testPushPendingEventsRecoversStaleInFlightRows` recovers stale in-flight events. |
| Rate limiting | PASS | `testPushPendingEventsClassifiesErrorsAndRateLimitBreaksReplay` and `testPushPendingEventsRateLimitWithoutRetryAfterUsesDefaultDelay` verify 429 handling, replay stop, and fallback delay. |
| Dead-letter/SLO | PASS | `SyncEngineLoadTests.testOutboxSLOSnapshotCriticalAlertForDeadLetterRate` and `SyncEngineControlFlowTests.testSyncHealthMetricsNeedsAttentionAndBlockedFallbackBranches` cover permanent failure/dead-letter health. |
| Conflict policy | PASS | Current sync spec states V2 uses server-authoritative entity-level LWW and no manual sync conflict UI. Tests cover the implemented paths: rollback of optimistic local changes, dependency/idempotency backfill, user-visible blockers, stale server pull reconciliation, and domain-specific workout import/manual conflict fields. |

Documentation note: `life_os_api_specification.md` still contains an older generic "Review changes" wording in the sync appendix, while `life_os_sync_engine_spec.md` says V2 has no manual conflict UI. I did not silently reinterpret product behavior. I updated `life_os_data_lineage_matrix.md` to name the current implemented policy: server-authoritative entity-level LWW plus outbox/idempotency state, not generic manual sync conflict UI.

## Identity Reconciliation

| Scenario | Status | Evidence |
| --- | --- | --- |
| Offline anonymous user merges into existing cloud/canonical user | PASS | `testAuthenticatedIdentityMergeReusesCanonicalUserAndRewritesLocalReferences` keeps one user, preserves local profile data, rewrites related rows, and rewrites pending outbox payloads. |
| Offline user canonicalized to cloud auth id | PASS | `testCloudAuthenticatedIdentityCanonicalizesOfflineUserIdToAuthIdAndRewritesUserPayload` rewrites user id, owner references, and pending user payload. |
| Server pull canonicalizes local profile to server user id | PASS | `testPullUsersTableCanonicalizesLocalUserIdToServerUserId` merges local profile fields with pulled server identity and rewrites `sync_row_state` plus outbox payloads. |
| Bootstrap reconnect fallback | PASS | `testBootstrapFallsBackToExistingLocalProfileWithoutCreatingOfflineSplit` avoids creating an offline split when cloud reconnect/bootstrap fails but a local profile exists. |

## Source and Documentation Changes

| File | Change |
| --- | --- |
| `life_os_data_lineage_matrix.md` | Version/date bumped to 0.4 / June 23, 2026; added local-day timezone/offset fields for nutrition, training, wellness, hydration, sleep, supplements, body composition; updated labs to canonical `source_scan_id`/`marker_id`/`measured_at`; added offline sync queue lineage; clarified V2 conflict policy. |

No production Swift, Supabase, or Edge code changes were required in this phase.

## Acceptance Criteria

| Criterion | Status |
| --- | --- |
| iOS sync contract gate passes for registry, fixtures, and sync perf tests. | PASS |
| Sync fixtures match current Supabase contract and do not regress to legacy key shapes. | PASS |
| Timezone/local-day invariants pass for nutrition, workouts, hydration, supplements, sleep, labs, and body composition. | PASS |
| Offline queue, retry, dead-letter, and conflict resolution paths are covered by unit or UI tests. | PASS |
| Anonymous-to-cloud identity reconciliation is verified with local-only and reconnect/bootstrap states. | PASS |
| Data lineage matrix is updated if implementation differs from docs. | PASS |

## Notes

- Simulator logs about unpaired WatchConnectivity, Family Controls monitor permission, and performance probes were non-blocking and did not fail tests.
- The fresh-cache SwiftPM failure remains an environment prewarming risk for CI or clean machines. The app-level evidence is the final `exit=0` mandatory gate plus the targeted sync suite.
