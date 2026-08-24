# Phase 14 - Release operations proof

Date: 2026-06-23
Phase: 14 of 15
Verdict: local release candidate is proven green; true deploy/App Store readiness is externally blocked until the items in `external-blockers.md` are run with production access.

## Scope

This phase proved the final local release gate, recorded optional/live/physical-device boundaries, and audited the operational checklist for iOS release config, APNs, App Store update metadata, Supabase release secrets, privacy manifests, and runbooks.

## Code change made in this phase

`ios/LifeOSUITests/AccessibilityAuditUITests.swift` was hardened after the full release gate exposed a simulator harness failure:

- The accessibility audit now retries only the transient XCTest `com.apple.accessibilityAudit` code `-902` / `Invalid target app` failure.
- Retries are bounded to four attempts.
- The app is re-foregrounded, system alerts are handled through SpringBoard, and later retries relaunch the authenticated app.
- Real accessibility issues still make `performAccessibilityAudit` return `false` and remain release-blocking.

Focused proof:

- `audits/production-readiness-2026-06-22/phase-14-logs/ui-accessibility-after-bounded-invalid-target-retry.log`
- Result: `TEST SUCCEEDED`, `inner_exit=0`, `exit=0`.

## Full local release gate

Command:

```bash
DERIVED_DATA_PATH=/tmp/lifeos-a11y-gate bash scripts/run_release_gate_local.sh
```

Final log:

- `audits/production-readiness-2026-06-22/phase-14-logs/release-gate-local-final-after-a11y-harden.log`
- `Release gate local run passed.`
- `finished_at_utc=2026-06-23T14:38:35Z`
- `inner_exit=0`
- `exit=0`

Major evidence from the final gate:

- Deno fmt/lint/check/test/coverage passed for Supabase functions.
- Deno tests: `230 passed`, `0 failed`.
- Deno coverage: all files branch `99.0`, line `99.4`.
- Supabase Edge E2E passed for local endpoints, including `api-settings-notifications` and `api-food-log`.
- Supabase Edge load passed:
  - `api-food-log`: 120 requests, concurrency 16, p95 `166.5ms`, errors `0.00%`.
  - `api-settings-notifications`: 90 requests, concurrency 16, p95 `154.9ms`, errors `0.00%`.
- Pre-prod security pass completed: `40 passed`, `0 failed`.
- iOS release config guard passed.
- iOS unit test pass: `776 tests`, `5 skipped`, `0 failures`.
- iOS UI test pass: `10 tests`, `0 failures`.
- iOS performance hard gates passed.
- iOS static analyze passed: `ANALYZE SUCCEEDED`.

Important boundary: the first fresh-cache attempt hit SwiftPM/GRDB `SQLiteLib.git` network/submodule fetch instability. The successful proof used warmed DerivedData at `/tmp/lifeos-a11y-gate`; this is a CI/network reliability consideration, not an app runtime failure.

## Optional and external probes

| Probe | Log | Result | Production meaning |
| --- | --- | --- | --- |
| Supabase edge soak | `phase-14-logs/edge-soak-status.log` | `RUN_EDGE_SOAK not set`, `inner_exit=0`, `exit=0` | Soak was not requested in this preflight. Local load passed, but 30-minute soak coverage remains unrun. |
| Physical iOS device smoke | `phase-14-logs/real-device-smoke-status.log` | `NO_PHYSICAL_DEVICE_FOR_REAL_DEVICE_SMOKE`, `inner_exit=0`, `exit=0` | Simulator gates passed, but APNs/HealthKit/background behavior on real hardware is not proven in this environment. |
| Live nutrition provider smoke | `phase-14-logs/live-nutrition-smoke-status.log` | `NO_LIVE_NUTRITION_SMOKE_ENV`, `inner_exit=0`, `exit=0` | Local mocked/e2e nutrition gates passed, but hosted provider search/barcode smoke is not proven without live Supabase auth env. |

## CI release gate coverage

`.github/workflows/release-gate.yml` enforces these required jobs before the aggregate `release-gate` job can pass:

- `ios-unit-tests`
- `ios-ui-tests`
- `ios-accessibility-audit`
- `ios-performance-hard-gates`
- `ios-analyze`
- `watchos-build`
- `watchos-tests`
- `deno-gates`
- `supabase-db`
- `supabase-edge-e2e`
- `supabase-edge-load`
- `security-preprod-pass`

The local all-in-one script `scripts/run_release_gate_local.sh` mirrors the app-critical subset and passed after the accessibility harness hardening.

## Production checklist

### iOS release config

Confirmed:

- `scripts/check_ios_release_config.sh` validates that Release `SUPABASE_URL` and `SUPABASE_ANON_KEY` resolve from `LIFEOS_SUPABASE_URL` and `LIFEOS_SUPABASE_ANON_KEY`.
- It validates all five privacy manifests and their Xcode resource wiring.
- It can additionally validate fully resolved release values when `LIFEOS_REQUIRE_RESOLVED_RELEASE_CONFIG=1`.
- It can validate a built app bundle when `LIFEOS_BUILT_APP_PATH` is provided.

Required before production:

- Run the release config guard with real production build settings:

```bash
LIFEOS_REQUIRE_RESOLVED_RELEASE_CONFIG=1 bash scripts/check_ios_release_config.sh
```

- Run the built app bundle guard after archiving/exporting the release artifact:

```bash
LIFEOS_BUILT_APP_PATH=/path/to/LifeOS.app bash scripts/check_ios_release_config.sh
```

### Privacy manifests

Confirmed present and plist-valid:

- `ios/LifeOS/App/PrivacyInfo.xcprivacy`
- `ios/LifeOSWidgets/PrivacyInfo.xcprivacy`
- `ios/GuardianMonitorExtension/PrivacyInfo.xcprivacy`
- `watch/LifeOSWatchApp/PrivacyInfo.xcprivacy`
- `watch/LifeOSComplications/PrivacyInfo.xcprivacy`

Confirmed release guard checks at least five `PrivacyInfo.xcprivacy in Resources` entries in the Xcode project.

### APNs and iOS capabilities

Confirmed in source:

- Main app entitlements bind `aps-environment` to `$(APS_ENVIRONMENT)`.
- Main app entitlements include Apple Sign In, Family Controls, HealthKit, time-sensitive notifications, and app groups.
- `UIBackgroundModes` includes `fetch`, `processing`, and `remote-notification`.
- Server APNs dispatcher requires `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`, and `APNS_BUNDLE_ID`.
- APNs dispatch unit tests cover unconfigured state, successful dispatch, invalid token classification, and empty configured requests.

Required before production:

- Verify production provisioning resolves `APS_ENVIRONMENT=production`.
- Store APNs production credentials in the hosted Edge environment.
- Run physical-device smoke and manual APNs checklist from `ios/PREPROD_REAL_DEVICE_SMOKE.md`.

### App Store ID and URL

Confirmed in source:

- `ios/LifeOS/App/Info.plist` expands `APP_STORE_ID` and `APP_STORE_URL`.
- Current project build settings contain empty `APP_STORE_ID` and `APP_STORE_URL` defaults.
- Supabase Edge force-update headers can emit `APP_STORE_URL` or derive it from `APP_STORE_ID`.

Required before production:

- Set real App Store product ID or product URL in iOS release build settings and hosted Supabase Edge environment.
- Verify the force-update header path returns a product URL, not an App Store search fallback.

### Supabase release environment

Confirmed in source:

- `supabase/config.toml` sets `verify_jwt = true` for the configured Edge functions.
- Local E2E and load gates passed with local Supabase.
- Account-deletion cron dispatch requires Vault secrets named `project_url` and `service_role_key`.
- If those Vault secrets are missing, the migration intentionally skips scheduling the account deletion worker cron and emits a notice.

Required before production:

- Confirm hosted Supabase secrets:
  - `SUPABASE_URL`
  - `SUPABASE_ANON_KEY`
  - `SUPABASE_SERVICE_ROLE_KEY`
  - `OPENROUTER_API_KEY` for AI routes
  - `APNS_TEAM_ID`
  - `APNS_KEY_ID`
  - `APNS_PRIVATE_KEY_P8`
  - `APNS_BUNDLE_ID`
  - `APP_STORE_ID` or `APP_STORE_URL`
- Confirm Vault secrets:
  - `project_url`
  - `service_role_key`
- Confirm hosted cron job `process_due_account_deletion_jobs` exists after secrets are present.

### Nutrition live provider

Confirmed locally:

- Food provider Deno tests passed in the full release gate.
- Local Edge E2E and load passed.

Required before production:

- Run `scripts/run_nutrition_provider_live_smoke.sh` with hosted Supabase auth:

```bash
SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_ACCESS_TOKEN=... bash scripts/run_nutrition_provider_live_smoke.sh
```

## Release boundary

Local release candidate: ready.

The following are proven on this machine:

- Local all-in-one release gate.
- Local Supabase Edge E2E/load/security.
- Simulator iOS unit/UI/accessibility/performance/analyze.
- Release config source guard.
- Privacy manifest presence and wiring.

Deploy/App Store ready: not yet claimable from this machine.

The following require external production access or hardware:

- Physical iPhone/iPad APNs, HealthKit, background smoke.
- Hosted nutrition provider smoke.
- Soak run with `RUN_EDGE_SOAK=1`.
- Hosted Supabase secrets and Vault cron verification.
- Production APNs credentials.
- Real App Store ID/URL and built artifact release config verification.

