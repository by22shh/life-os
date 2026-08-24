# Phase 10 - Labs Wellness

Date: 2026-06-23

## Verdict

Status: PASS.

Labs, medical scan privacy, supplements, menstrual tracking, wellness, hydration, body composition, retention, and privacy/account-deletion adjacent flows were reviewed against the current iOS and Supabase contracts. No production code changes were required in this phase. The existing implementation is fail-closed for menstrual and medical scan sensitive data: local-only is the default when privacy settings are missing, scan outbox writes are skipped for local-only scans, cloud original uploads require both medical scan opt-in and cloud backup opt-in, and server-side privacy changes clear stored scan artifacts.

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| Targeted labs/wellness `xcodebuild test` for `LabScanDetailViewModelTests`, `LabsPrivacySettingsTests`, `MenstrualStoreTests`, `SupplementAndMenstrualModelsTests`, `LocalSensitiveFieldEncryptionTests`, and `PrivacyRetentionManagerTests` | PASS | `phase-10-logs/ios-labs-wellness-gate.log`: 25 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| `deno test -A supabase/functions/tests/medical_scan_privacy.test.ts supabase/functions/tests/settings_privacy_edge.test.ts supabase/functions/tests/settings_notifications_edge.test.ts supabase/functions/tests/supplement_log_handler.test.ts` | PASS | `phase-10-logs/deno-medical-settings-supplements-gate.log`: `ok | 22 passed (24 steps) | 0 failed`; `exit=0`. |

## Additional Production Proof

| Check | Result | Evidence |
| --- | --- | --- |
| Full local Supabase Edge E2E wrapper | PASS | `phase-10-logs/edge-local-e2e-labs-wellness.log`: `api-settings-privacy`, `api-labs`, `api-labs-retention-worker`, `api-hydration`, `api-body-composition`, `api-wellness`, `api-hydration-log-alias`, `api-wellness-check-alias`, `api-supplements-log`, `api-supplement-log`, `api-supplements-daily`, `api-supplements-calendar`, and `api-menstrual-sync` all OK; `exit=0`. |
| Post-E2E Supabase cleanup check | PASS | `phase-10-logs/supabase-status-after-edge-e2e.log`: `No such container: supabase_db_life-os`; `exit=1`, which confirms the wrapper left no local stack running. |
| Extra iOS coverage for labs views, health measurement contract, privacy gateway, and local privacy operations | PASS | `phase-10-logs/ios-labs-privacy-extra-tests-rerun.log`: 30 tests, 0 failures; `** TEST SUCCEEDED **`; `exit=0`. |
| Shared settings internals | PASS | `phase-10-logs/deno-settings-shared-internals.log`: `ok | 3 passed | 0 failed`; `exit=0`. |

Note: `phase-10-logs/ios-labs-privacy-extra-tests.log` is a discarded first extra run because it did not write a final test/exit marker. The authoritative extra evidence is `ios-labs-privacy-extra-tests-rerun.log`.

## Sensitive Data Audit

| Surface | Default | Cloud or sync rule | Retention / deletion proof | Evidence |
| --- | --- | --- | --- | --- |
| Medical scan metadata and review state | Local-only unless `medical_scan_local_only` is false | iOS `markReviewed` and pin toggles persist locally, then enqueue `api-labs` only when `storageMode` is not `local_only`; pull of scans/diagnoses is gated by `shouldPullRestrictedMedicalData`. | Local retention removes stale unpinned raw scan refs; Edge privacy side effects clear scan storage fields and force `storage_mode = local_only` when requested. | `LabScanDetailView.swift:570-789`; `SyncEngine.swift:1604-1635` and `2254-2275`; mandatory iOS tests; extra labs view tests. |
| Medical scan original files | Not stored in cloud by default | Upload requires `medical_scan_local_only = false`, `cloud_backup_enabled = true`, and `store_original_in_cloud = true`; otherwise payload strips cloud asset fields and can force local-only mode. | Edge retention deletes expired unpinned owned storage objects and nulls DB refs; privacy settings PATCH removes stored objects and DB refs. | `SyncEngine.swift:869-965`; `api/labs/index.ts:185-213`; `_shared/medical_scan_privacy.ts:64-173`; Deno medical scan privacy tests. |
| Lab OCR / extracted markers | Review required when confidence/status indicate risk | Server normalizes statuses and blocks verified/reviewed flags while review is required; iOS review clears `needsReview`, marks measurements verified, and queues only cloud-allowed scans. | Processed marker history is normalized into health measurements; scan artifacts follow the scan retention rules above. | `api/labs/index.ts:215-235`; `LabScanDetailView.swift:570-789`; `LabScanDetailViewModelTests`; `LabsViewCoverageTests`. |
| Health measurements and diagnoses | Measurements are syncable health records; scan/diagnosis pull is restricted | Health measurements remain part of the normal sync contract, while `medicalScans` and `healthDiagnoses` are pulled only when restricted medical data is allowed. | Contract migration and decoder tests keep canonical marker/source fields stable across legacy payloads. | `LabsSyncHandler.swift:1-16`; `HealthMeasurementContractTests`; extra iOS run. |
| Menstrual logs | Local-only by default | Save/delete enqueues `api-menstrual-sync` only when `menstrual_local_only` is false; missing auth or missing privacy settings fails closed. | Soft-delete tombstones sync only when opt-in allows; local context reports `syncEnabled` from privacy settings. | `MenstrualStore.swift:1-167`; `MenstrualStoreTests`; Edge E2E `api-menstrual-sync`. |
| Supplements | Normal app sync surface | Log handler requires auth/user context, normalizes scheduled time, applies idempotency, and rejects malformed payloads. | No special retention beyond normal account/export/delete lanes; supplement daily/calendar routes pass Edge E2E. | `supplement_log_handler.test.ts`; Edge E2E `api-supplements-log`, `api-supplement-log`, `api-supplements-daily`, `api-supplements-calendar`. |
| Wellness, hydration, body composition | Normal app sync surface with local-day metadata | Edge routes are authenticated, user-scoped, and covered by local-day E2E scenarios including alias routes. | Account deletion and export coverage remains from phase 6; this phase reverified route behavior in the full Edge wrapper. | Edge E2E `api-hydration`, `api-body-composition`, `api-wellness`, `api-hydration-log-alias`, `api-wellness-check-alias`. |
| Privacy settings | Defaults: menstrual local-only, medical scan local-only, vector off, analytics off, backup off | GET creates fail-closed defaults; PATCH validates payload, applies normalized booleans, and runs medical scan cleanup side effects. | Cleanup removes storage objects, nulls scan asset fields, and forces local-only mode when medical scan local-only is enabled. | `api/settings/privacy/index.ts:177-281`; `settings_privacy_edge.test.ts`; Deno gate. |
| Local encrypted sensitive fields | Stored encrypted at rest | Sensitive inserts roll back when encryption/key prep fails; old plaintext rows are migrated and remain readable. | Key deletion/local erasure flow is covered by `LocalPrivacyOperationsTests`. | `LocalSensitiveFieldEncryptionTests`; `LocalPrivacyOperationsTests`; extra iOS run. |

## Flow Verification Matrix

| Flow | Status | Evidence |
| --- | --- | --- |
| Labs import/capture | PASS | `LabsViewCoverageTests` cover cloud storage/outbox and local-only/missing-user branches; extra iOS run shows 6 labs view tests green. |
| Labs detail review | PASS | `LabScanDetailViewModelTests` cover local measurements, processed-data fallback, remote snapshot persistence, review save, local-only pin skip, and signed document URL resolution. |
| Low-confidence and review states | PASS | `api-labs` derives `needsReview` from normalized scan/extraction status and blocks manual/user-reviewed flags until review is cleared; iOS tests verify review clears the flags for cloud scans. |
| Medical scan retention worker | PASS | Full Edge E2E `api-labs-retention-worker` passes; medical scan privacy tests cover retention deadline, expired unpinned cleanup, pinned/future/invalid skip, storage verify fallback, storage survivor detection, and update/delete failure surfaces. |
| Supplements scheduling/logging | PASS | Supplement log handler tests cover normalized insert, idempotent replay, malformed scheduled time, blank/oversized names, request guardrails, insert failures, and UTC fallback. |
| Menstrual privacy | PASS | iOS tests cover opt-in enqueue, local-only skip, missing settings skip, missing auth nil fetch, legacy text ID delete, and context `syncEnabled`; Edge E2E covers `api-menstrual-sync`. |
| Wellness, hydration, body composition | PASS | Full Edge E2E covers canonical and alias routes for hydration/wellness plus body composition with authenticated user context. |
| Account export/delete adjacency | PASS | Extra `PrivacyGatewayTests` cover export queueing/status/download trust checks, erasure/cancel queueing, consent record queueing, and local status updates. |
| Local privacy erasure | PASS | `LocalPrivacyOperationsTests` cover successful local erasure, failed export cleanup, failed key deletion, and latest status selection. |

## Error and Empty State Coverage

| Risk | Coverage |
| --- | --- |
| Missing auth or missing resolved user | `api-settings-privacy`, notifications, supplement log, and local menstrual fetch tests cover unauthorized or missing user rows; `MenstrualStore` returns nil/disabled context without auth. |
| Malformed input | Deno tests cover invalid JSON/payloads, invalid scan storage mode/date branches, malformed supplement scheduled times, invalid notification wall-clock fields, and oversized supplement names. |
| Slow or failed AI / cloud paths | Labs detail falls back to local snapshots on remote refresh failure; scan cloud backup throws stable local errors for missing scan id, missing asset metadata, invalid file URL, or missing file. |
| Storage cleanup failure | Medical scan privacy tests surface lookup, remove, verify, survivor, list, and update failures with stable error categories. |
| Missing permissions | Local simulator Family Controls / Watch pairing warnings appeared during extra iOS run, but tests passed and no production path depended on those permissions for this phase. |
| Empty history or missing local rows | Labs detail handles missing local row with optional remote snapshot; menstrual context returns disabled/empty state when no user/privacy state is available. |

## Retention And Phase 6 Reconciliation

Phase 6 already proved export/delete/account-erasure Edge lanes and release privacy/security gates. Phase 10 rechecked the high-risk health surfaces that feed those lanes:

- Local maintenance removes food photo references after 90 days, raw unpinned medical scan artifacts after 90 days, AI cache after 7 days, non-critical notification logs after 7 days, analytics after 90 days, insights after 1 year, and completed/dead-letter outbox events after 7 days; pinned scans are preserved. Evidence: `PrivacyRetentionManager.swift:23-130` and `PrivacyRetentionManagerTests`.
- Edge medical scan retention removes expired unpinned owned storage objects and verifies removal before nulling DB refs. Evidence: `_shared/medical_scan_privacy.ts:64-117` and `medical_scan_privacy.test.ts`.
- Privacy settings PATCH is a stronger immediate cleanup path than retention: disabling cloud backup or forcing medical scan local-only removes stored scan objects and clears DB asset refs. Evidence: `_shared/medical_scan_privacy.ts:119-173` and `settings_privacy_edge.test.ts`.
- Account deletion/export adjacency remains consistent: `PrivacyGatewayTests` prove export jobs, trusted archive downloads, erasure requests, cancellation, consent writes, and local status updates.

No conflict was found between phase 6 privacy/deletion guarantees and phase 10 labs/wellness behavior.

## Acceptance Criteria

| Criterion | Status |
| --- | --- |
| Labs import/OCR/review, medical scan retention, low-confidence checks, and local asset cleanup are verified. | PASS |
| Supplements scheduling/logging, menstrual privacy, wellness check, hydration, and body composition paths match docs. | PASS |
| Sensitive flows do not sync or expose local-only data unless opt-in rules allow it. | PASS |
| Unit and Edge tests for labs/privacy/settings/supplements pass. | PASS |
| Error/empty states handle missing permissions, missing data, malformed input, and slow/failed AI. | PASS |
| Retention and account deletion coverage is reconciled with phase 6. | PASS |

## Notes

- The source contains an intentional server-side retention cleanup log inside `api-labs`; it is pre-existing behavior and not a phase-10 source change.
- Existing Swift warnings about immutable candidates appeared while Xcode compiled broad test targets, but all selected tests passed.
- No Supabase deployment was attempted in this phase; release operations remain scheduled for phase 14.
