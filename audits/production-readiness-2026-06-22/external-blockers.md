# External production proof blockers

Date: 2026-06-23
Status: local release candidate proven; production/App Store proof blocked by external access and hardware.

## Blockers

### 1. No physical iOS device attached

Evidence:

- `audits/production-readiness-2026-06-22/phase-14-logs/real-device-smoke-status.log`
- Output: `NO_PHYSICAL_DEVICE_FOR_REAL_DEVICE_SMOKE`
- Exit: `inner_exit=0`, `exit=0`

Impact:

- APNs capability precheck, HealthKit authorization behavior, background refresh availability, offline replay, and chaos retry behavior on real hardware are not proven in this environment.

Required closure:

```bash
bash scripts/run_ios_preprod_real_device_smoke.sh
```

Then execute the manual checklist in `ios/PREPROD_REAL_DEVICE_SMOKE.md`.

### 2. Live nutrition provider smoke environment missing

Evidence:

- `audits/production-readiness-2026-06-22/phase-14-logs/live-nutrition-smoke-status.log`
- Output: `NO_LIVE_NUTRITION_SMOKE_ENV`
- Exit: `inner_exit=0`, `exit=0`

Impact:

- Local food provider tests, Edge E2E, and load gates are green, but hosted search and barcode provider behavior is not proven against a live authenticated Supabase session.

Required closure:

```bash
SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_ACCESS_TOKEN=... bash scripts/run_nutrition_provider_live_smoke.sh
```

### 3. Soak run was not requested

Evidence:

- `audits/production-readiness-2026-06-22/phase-14-logs/edge-soak-status.log`
- Output: `RUN_EDGE_SOAK not set; soak coverage not requested in this preflight`
- Exit: `inner_exit=0`, `exit=0`

Impact:

- Edge E2E and fixed-size load are green, but duration-based soak coverage is not part of the current proof.

Required closure:

```bash
RUN_EDGE_SOAK=1 bash scripts/run_release_gate_local.sh
```

or:

```bash
bash scripts/run_supabase_edge_soak.sh
```

### 4. Production App Store metadata is not resolved

Evidence:

- `ios/LifeOS/App/Info.plist` expands `APP_STORE_ID` and `APP_STORE_URL`.
- Current Xcode project build settings contain empty defaults for `APP_STORE_ID` and `APP_STORE_URL`.
- Supabase force-update headers require `APP_STORE_URL` or `APP_STORE_ID` in the hosted Edge environment.

Impact:

- Force-update and App Store deep-link behavior cannot be fully proven for production users.

Required closure:

- Set real App Store product ID or product URL in iOS Release build settings.
- Set matching `APP_STORE_ID` or `APP_STORE_URL` in hosted Supabase Edge environment.
- Verify the returned force-update header points at the product page.

### 5. Production APNs credentials and provisioning are not locally verifiable

Evidence:

- Main app entitlement uses `aps-environment` as `$(APS_ENVIRONMENT)`.
- Server APNs dispatcher requires `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`, and `APNS_BUNDLE_ID`.
- No live APNs secret environment was available in this run.

Impact:

- The code path is tested, but production APNs dispatch and production provisioning are not proven.

Required closure:

- Confirm Release provisioning resolves `APS_ENVIRONMENT=production`.
- Store production APNs credentials in the hosted Supabase Edge environment.
- Run real-device smoke plus manual APNs checklist.

### 6. Hosted Supabase Vault and cron state need live verification

Evidence:

- Account-deletion scheduled worker reads Vault secrets `project_url` and `service_role_key`.
- Migration skips cron scheduling when those secrets are absent.
- This local run did not have hosted Supabase project access.

Impact:

- Local DB/Edge gates are green, but hosted deletion-worker cron dispatch is not proven.

Required closure:

- Store Vault secrets `project_url` and `service_role_key`.
- Re-run or verify the migration path after secrets exist.
- Confirm cron job `process_due_account_deletion_jobs` exists and dispatches to `api-account-delete-worker`.

### 7. Built release artifact config guard was not run

Evidence:

- `scripts/check_ios_release_config.sh` supports `LIFEOS_BUILT_APP_PATH`.
- This phase validated source/build-setting behavior, not an archived App Store/TestFlight artifact.

Impact:

- The source config is green, but the exported app bundle has not been checked for resolved Supabase values and embedded privacy manifest.

Required closure:

```bash
LIFEOS_BUILT_APP_PATH=/path/to/LifeOS.app bash scripts/check_ios_release_config.sh
```

## Current production claim

Allowed claim:

- The local release candidate is green on the full local release gate.

Not allowed yet:

- The app is fully production/App Store ready.

That stronger claim becomes valid only after the blockers above are closed with live production credentials, hosted Supabase access, a built release artifact, and a physical iOS device.

