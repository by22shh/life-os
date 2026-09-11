# Life OS — External Production Checks

This checklist covers the release evidence that **cannot** be produced from
unit tests, simulators, or the repository alone. Each item needs hardware,
credentials, or a hosted project. Nothing here is claimed as passing until the
listed command/observation is actually run and its artifact is attached.

Local gates that are already green (re-verified 2026-09-11 after the
2026-09-11 hardening pass; see `audits/system-audit-2026-09-08/`):
Deno fmt/lint/check + 280 tests, clean DB migrations + upgrade + integrity,
edge E2E (66 scenarios), iOS build + 821 unit tests + widgets + watch,
core UI E2E and accessibility audit. Those do **not** substitute for the items below.

Legend: **BLOCKER** = required before App Store submission · **PILOT** = required
before claiming user benefit · **CONFIG** = must be validated against the hosted project.

## 0. Configuration preflight (CONFIG)

```bash
set -a; source .env; set +a
bash scripts/check_production_config.sh --strict
LIFEOS_REQUIRE_RESOLVED_RELEASE_CONFIG=1 bash scripts/check_ios_release_config.sh
```

Evidence: preflight exit 0; no placeholder URLs/keys; service-role key ≠ anon key.

## 1. Hosted Supabase: migrations, Vault, cron (BLOCKER)

- [ ] `supabase link` + `supabase db push` against the hosted project (forward-only).
- [ ] Vault secrets `project_url` and `service_role_key` created **before** `db push`
      (see `supabase/DEPLOYMENT.md` §2).
- [ ] Confirm cron jobs exist and run: `process_due_account_deletion_jobs`,
      medical-scan retention, `sync_vector_memory`.
      Evidence: `select jobname, schedule, active from cron.job;` and a
      `cron.job_run_details` success row.
- [ ] `supabase functions deploy` completes for every entry in `supabase/config.toml`.
- [ ] Anonymous sign-in enabled on the hosted project.
      Evidence: `GET /auth/v1/settings` → `external.anonymous_users == true`.

## 2. Real device: iPhone + Apple Watch (BLOCKER)

```bash
bash scripts/run_ios_preprod_real_device_smoke.sh
```

Then complete `ios/PREPROD_REAL_DEVICE_SMOKE.md` (APNs, HealthKit revoke/recover,
background refresh). Additional companion checks:
- [ ] Watch app is installed **with** the iPhone app (embedded bundle, not a separate build).
- [ ] WatchConnectivity actions and complications deliver with the phone locked/away.
- [ ] HealthKit read authorization is requested correctly for read-only access
      (write status must not be used as a read gate).

## 3. APNs production (BLOCKER)

- [ ] `APS_ENVIRONMENT=production` and hosted APNs secrets (`APNS_TEAM_ID`,
      `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`, `APNS_BUNDLE_ID`) set.
- [ ] Device token registration succeeds; `send-notification` returns
      `delivery_state` indicating real delivery (not `not_configured`).
- [ ] Verify the hard cap (≤ 6/day) and quiet hours on a real device.

## 4. Guardian / Family Controls (BLOCKER if shipping Guardian)

- [ ] Family Controls entitlement approved on the Apple Developer account.
- [ ] `GuardianMonitorExtension` is granted device approval and enforces restrictions.
- [ ] Verify the runtime capability check works on an App Store-style build
      (no embedded provisioning profile; `RuntimeCapabilities.plist` is used).

## 5. Live AI / nutrition providers (PILOT)

```bash
SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_ACCESS_TOKEN=... \
  bash scripts/run_nutrition_provider_live_smoke.sh
```

- [ ] OpenRouter photo/voice/label/insight calls return real results (not fallback).
- [ ] Food barcode/search provider returns CIS-relevant coverage.
- [ ] Measure OCR/recognition accuracy against originals on real documents.

## 6. App Store artifact (BLOCKER)

- [ ] Set `APP_STORE_ID` / `APP_STORE_URL` (Release build settings and hosted edge env).
- [ ] Archive and export the release `.app`; then:
      `LIFEOS_BUILT_APP_PATH=/path/to/LifeOS.app bash scripts/check_ios_release_config.sh`
- [ ] Install the exported build via TestFlight and re-run onboarding + HealthKit.

## 7. Pilot: does it actually help? (PILOT)

Not provable by tests. Define a small pilot and measure:
- [ ] Time to log a typical meal/workout and correct mistakes.
- [ ] Data survives network loss, app kill, and reinstall/sign-in.
- [ ] Recognized lab values match the source document.
- [ ] Users understand recommendations and how often they correct them.
- [ ] Continued use over the pilot window (retention), not just first-run completion.

Until this is run, treat recovery scores, predictions, experiment effects and
"AI memory" as **unvalidated** product claims.

## Out of scope (deferred by PRD)

- StoreKit / subscriptions / monetization (V3+).
