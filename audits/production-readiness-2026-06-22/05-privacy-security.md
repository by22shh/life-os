# Phase 6 - Privacy and Security Lock

Date: 2026-06-23

## Verdict

Status: PASS.

No new production code changes were required in this phase. The previously-added database hardening remains part of the privacy/security posture, and this phase verified the app against secret exposure, release transport, Apple privacy manifest, export/delete/account-erasure, sensitive-data default, public Edge abuse, and internal service-role boundaries.

## Sources Checked

- Apple Developer Documentation: [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- Apple Developer Documentation: [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- Apple Technote: [TN3183 - Adding required reason API entries to your privacy manifest](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| `bash scripts/run_preprod_security_pass.sh` | PASS | `phase-6-logs/preprod-security-pass.log`: 40 abuse/security unit tests passed, Edge abuse E2E completed, script ended successfully. |
| `bash scripts/check_ios_release_config.sh` | PASS | `phase-6-logs/ios-release-config-guard.log`: release source config guard and privacy manifest source guard passed. |
| `plutil -lint ... PrivacyInfo.xcprivacy` | PASS | `phase-6-logs/privacy-manifest-plutil.log`: all five manifests OK. |
| Required secret scan | PASS | `phase-6-logs/secret-scan.log` and repeat scan exit 0; no hardcoded service-role keys, OpenRouter keys, `sk-...` keys, or private-key headers matched. |

The local Supabase stack was clean after the security pass: `docker ps --format ... | rg 'supabase|life-os'` returned no running containers.

## Secret and Transport Review

| Area | Status | Evidence |
| --- | --- | --- |
| Production secrets | PASS | Mandatory secret scan returned no matches outside safe env-name examples. |
| Service-role key handling | PASS | `supabase/functions/_shared/supabase.ts` reads `SUPABASE_SERVICE_ROLE_KEY` only from runtime env and throws when missing. No literal key values were found. |
| Internal worker auth | PASS | `api/account/delete_worker` and `api/labs/retention_worker` require bearer service-role auth, matching `apikey`, and a worker-specific invocation header before creating a service client. |
| App transport | PASS | `scripts/run_preprod_security_pass.sh` checks `NSAllowsArbitraryLoads` is not true and that `SupabaseConfig.swift` rejects non-HTTPS URLs outside test mode. |
| Release Supabase URL | PASS | `scripts/check_ios_release_config.sh` proves Release config is env-resolved and can enforce a resolved HTTPS URL with `LIFEOS_REQUIRE_RESOLVED_RELEASE_CONFIG=1`. |

Transport scan notes: direct `http://` hits were plist DTDs, tests/local harnesses, documentation schema URLs, localhost placeholders, or storage URL sanitizers that parse existing Supabase object URLs into bucket paths. No production network client path was found accepting insecure project URLs.

## Privacy Manifests and Required-Reason APIs

Apple's current privacy manifest flow requires declaring privacy manifests and required-reason API categories used by app or SDK code. This audit matched production source usage to each target manifest.

| Target | Manifest Status | Required-Reason Categories |
| --- | --- | --- |
| iOS app | PASS | `FileTimestamp` reason `C617.1`; `UserDefaults` reasons `CA92.1`, `1C8F.1`; no collected data; no tracking. |
| iOS widgets | PASS | `UserDefaults` reason `1C8F.1`; no collected data; no tracking. |
| Guardian monitor extension | PASS | `UserDefaults` reason `1C8F.1`; no collected data; no tracking. |
| Watch app | PASS | `UserDefaults` reason `CA92.1`; no collected data; no tracking. |
| Watch complications | PASS | `UserDefaults` reason `1C8F.1`; no collected data; no tracking. |

Wiring proof:

- `ios/project.yml` lists all five manifest files in their target source sections.
- `ios/LifeOS.xcodeproj/project.pbxproj` has five `PrivacyInfo.xcprivacy in Resources` build entries.
- Evidence: `phase-6-logs/privacy-manifest-xcode-wiring-clean.log`.

Required-reason source scan classification:

- `UserDefaults` is used in the app, widgets, Guardian extension, Watch app, and Watch complications; every corresponding target declares `UserDefaults`.
- File timestamp APIs are used in the iOS app by nutrition export cleanup and privacy export archive handling; the app manifest declares `FileTimestamp`.
- `LabScanDetailView.swift` only requested `.isDirectoryKey`; the broad scan captured it, but this is not a timestamp category by itself.
- No production hits were found for disk-space, system-boot-time, or active-keyboard required-reason categories.
- Evidence: `phase-6-logs/required-reason-api-production-scan.log` and `phase-6-logs/privacy-manifest-dump.log`.

## Export, Delete, and Account-Erasure Proof

| Layer | Status | Evidence |
| --- | --- | --- |
| Database | PASS | `delete_user_account(UUID)` is service-role-only; `deletion_audit_log` is now RLS-forced with client denial and no anon/auth grants; account deletion jobs and audit/failure tables exist in migrations. Phase 4 reset/lint/destructive tests passed. |
| Edge | PASS | Local Edge E2E covers `api-user-export`, `api-user-export-status`, `api-user-export-download`, `api-account-delete`, `api-account-delete-status`, `api-account-delete-cancel`, and `api-account-delete-worker`. Unit tests cover export builder redaction/failure handling and account deletion helper/state/storage paths. |
| iOS privacy gateway | PASS | `PrivacyGatewayTests` cover export request, local export job persistence, erasure request/cancel queueing, status polling, trusted export download, and untrusted remote download rejection. |
| Local erasure | PASS | `LocalPrivacyOperationsTests` cover export cleanup, device-key deletion hook, audit compliance, failed cleanup, failed key deletion, and latest local erasure status. |
| UI | PASS | `LifeOSUITests/EndToEndScenariosUITests.testDeleteAndExportScenario` opens Settings export, verifies `settings.export.status`, deep-links to privacy, opens delete-account, and exercises confirmation. Phase 3 full UI gate passed with 10 UI tests, including this scenario. |

No live-proof blocker remains for this acceptance criterion.

## Sensitive-Data Defaults

| Default | Status | Evidence |
| --- | --- | --- |
| Local-first medical scans | PASS | `medical_scans.storage_mode` defaults to `local_only`; `store_original_in_cloud` defaults false; server and iOS sync paths preserve local-only defaults. |
| Medical scan cloud behavior opt-in | PASS | `privacy_settings.medical_scan_local_only` defaults true; `SyncEngine` checks privacy settings and scrubs `store_original_in_cloud=false` plus `storage_mode=local_only`. |
| Vectors opt-in | PASS | `privacy_settings.vector_opt_in` defaults false; `SyncEngine` checks it before vector/cloud-sensitive sync paths. |
| Cloud backup opt-in | PASS | `privacy_settings.cloud_backup_enabled` defaults false in the spec/migrations and is queried before backup-sensitive flows. |
| Menstrual data on-device by default | PASS | `privacy_settings.menstrual_local_only` defaults true; `MenstrualStore` treats missing settings as local-only. |

Evidence: `phase-6-logs/privacy-sensitive-defaults-proof.log`, `life_os_privacy_architecture.md`, `life_os_api_specification.md`, Supabase migrations, iOS local migrations, `SyncEngine.swift`, and `MenstrualStore.swift`.

## Public Edge Abuse Gates

| Gate | Status | Evidence |
| --- | --- | --- |
| Malformed payload rejection | PASS | `payload_malformed.test.ts`: 21 tests passed, including export, export status, delete-account, privacy, consent, notification, AI, food, menstrual, supplement, and watch snapshot payloads. |
| Authorization parsing | PASS | `rate_limit_security.test.ts`: malformed bearer forms rejected; internal service-role validation requires service-role bearer, matching `apikey`, and worker header. |
| Rate limiting | PASS | `rate_limit_security.test.ts`: local fallback, distributed limiter errors, malformed replay headers, high-cardinality eviction, and 429 retry headers tested. |
| Correlation IDs | PASS | `correlation_property.test.ts`: malformed IDs regenerate; JSON and 429 responses preserve correlation headers. |
| Integration abuse path | PASS | `run_preprod_security_pass.sh` ran the Edge abuse-case integration suite and completed successfully. |

## Acceptance Criteria

| Criterion | Status |
| --- | --- |
| No hardcoded service-role keys, OpenRouter keys, private keys, or production secrets are present outside safe examples. | PASS |
| Release Supabase config guard and HTTPS enforcement pass. | PASS |
| Privacy manifests exist, lint, are wired for app/widgets/watch/extensions, and required-reason API usage is audited. | PASS |
| Export/delete/account-erasure flows have DB, Edge, and UI tests or documented live-proof blockers. | PASS |
| Sensitive-data defaults match the docs: local-first, opt-in vectors/cloud sensitive data, menstrual on-device by default. | PASS |
| Public Edge endpoints reject malformed/unauthorized abuse cases. | PASS |

## Notes

- Phase 6 made no production source changes; it added this audit artifact only.
- The secret/transport scans intentionally classify localhost, plist DTDs, and test harness URLs as non-production evidence rather than deleting useful local-development fixtures.
