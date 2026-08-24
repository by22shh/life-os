# Life OS Production Readiness Baseline Inventory

Generated: 2026-06-23 10:28 +07
Run root: `.supergoal/production-audit-life-os-RFyokC`
Workspace: `/Users/Bayramov_N/Desktop/Other/life-os`
Git baseline: unavailable (`git rev-parse` reports no git repository)

## Summary

This phase establishes the no-git baseline before source edits. The workspace is a Swift 6 iOS/watchOS application with SwiftUI, widgets, a Guardian extension, SwiftPM packages, Supabase Edge Functions (Deno/TypeScript), Postgres migrations/RLS, and shell/Python release gates.

Because the workspace is not a git repository, the final audit must rely on:

- `file-manifest.txt` for the source/config/doc inventory.
- `toolchain.txt` and `phase-1-logs/*` for command evidence.
- `phase-1-logs/critical-checksums.sha256` for release-script and Xcode scheme checksum anchors.
- Per-phase audit reports and command logs instead of commit diffs.

## Mandatory Command Results

| Command | Exit | Evidence |
|---|---:|---|
| `xcodebuild -list -project ios/LifeOS.xcodeproj` | 0 | `phase-1-logs/xcodebuild-list.txt` |
| `xcrun simctl list devices available` | 0 | `phase-1-logs/simctl-devices.txt` |
| `deno --version` | 0 | `phase-1-logs/deno-version.txt` |
| `supabase --version` | 0 | `phase-1-logs/supabase-version.txt` |
| `docker ps` | 0 | `phase-1-logs/docker-ps.txt` |

## Stack And Targets

Xcode project: `ios/LifeOS.xcodeproj`

Schemes:

- `LifeOS`
- `LifeOSWatch`

Targets:

- `LifeOS`
- `LifeOSTests`
- `LifeOSUITests`
- `LifeOSWidgets`
- `LifeOSWidgetsTests`
- `LifeOSWatch`
- `LifeOSWatchTests`
- `LifeOSComplications`
- `GuardianMonitorExtension`

SwiftPM packages resolved by `xcodebuild -list` include `GRDB.swift 7.10.0`, `supabase-swift 2.41.1`, `swift-composable-architecture 1.23.2`, `swift-syntax 602.0.0`, `swift-navigation 2.6.0`, and related Point-Free/Apple packages.

Available simulator lanes:

- iOS 26.2: `iPhone 17 Pro`, `iPhone 17 Pro Max`, `iPhone Air`, `iPhone 17`, `iPhone 16e`, several iPads.
- watchOS 26.2: `Apple Watch Series 11 (46mm)`, `Apple Watch Series 11 (42mm)`, `Apple Watch Ultra 3 (49mm)`, `Apple Watch SE 3`.

## Toolchain

- Deno: `2.6.10`, TypeScript `5.9.2`.
- Supabase CLI: `2.75.0`.
- Docker daemon: reachable; `docker ps` returned existing unrelated containers (`www`, `net`, `ctl`, `redis`).
- Xcode: available through `/Applications/Xcode.app/.../xcodebuild`; package graph resolves.

Supabase CLI drift is documented as a production-readiness risk, not upgraded in this inventory phase: local CLI is `2.75.0`, while the pre-flight retry and current CLI notice report `2.107.0` is available. CI uses `supabase/setup-cli@v1` with `version: latest`, so phase 4/14 must either pin/upgrade deliberately or keep the drift documented.

## File Manifest

Manifest: `audits/production-readiness-2026-06-22/file-manifest.txt`

The manifest contains 476 tracked source/config/doc-like files and excludes generated audit output, Supergoal artifacts, coverage/cache directories, `.xcresult` bundles, `__pycache__`, `.pyc`, `.DS_Store`, and generated `.log` files.

Extension coverage:

- `.swift`: 192
- `.ts`: 112
- `.json`: 56
- `.md`: 42
- `.png`: 31
- `.sh`: 11
- `.sql`: 9
- `.xcprivacy`: 5
- `.plist`: 4
- `.xcscheme`: 2
- plus entitlements, Python, TOML, xcstrings, project, and workflow files.

## Release Scripts And CI

Release/operations scripts inventoried:

- `scripts/run_release_gate_local.sh` - aggregate local release gate: Deno fmt/lint/check/test/coverage, Edge e2e/load, security pass, release config guard, optional soak, iOS unit/UI/performance/analyze.
- `scripts/run_preprod_security_pass.sh` - secret scan, ATS/HTTPS transport guard, abuse/rate-limit/correlation tests, optional Edge abuse e2e.
- `scripts/check_ios_release_config.sh` - release Supabase config and privacy manifest guard.
- `scripts/run_ios_performance_hard_gates.sh` - startup, sync latency, memory, and memory-growth budget tests.
- `scripts/run_ios_sync_contract_gate.sh` - sync contract fixture/model/perf gate, optional fixture refresh.
- `scripts/run_ios_preprod_real_device_smoke.sh` - physical-device preprod smoke when a device is attached.
- `scripts/run_nutrition_provider_live_smoke.sh` - live nutrition provider smoke requiring Supabase/live access tokens.
- `scripts/run_supabase_edge_e2e.sh` - local Supabase Edge e2e suite.
- `scripts/run_supabase_edge_load.sh` - Edge load suite.
- `scripts/run_supabase_edge_soak.sh` - optional long soak wrapper over Edge load.
- `scripts/profile_ios_settings_sync.sh` - focused settings/sync profiling helper.
- `scripts/refresh_sync_contract_fixtures.py` - refreshes sync contract fixtures from Supabase REST snapshots.

CI workflow: `.github/workflows/release-gate.yml`

Jobs inventoried:

- `ios-unit-tests`
- `ios-ui-tests`
- `ios-accessibility-audit`
- `ios-performance-hard-gates`
- `ios-analyze`
- `ios-release-config-guard`
- `watchos-build`
- `watchos-tests`
- `deno-gates`
- `supabase-db`
- `supabase-edge-e2e`
- `supabase-edge-load`
- `security-preprod-pass`
- `release-gate`

Baseline note: local pre-flight discovered that watch simulator names must preserve the size suffix, for example `Apple Watch Series 11 (46mm)`. The workflow currently extracts watch names with `awk -F '[()]'`, which can collapse that name to `Apple Watch Series 11`; phase 11 or 14 should harden this if CI reproduces the destination mismatch.

## Current Hotspots

Top 20 files by line count are recorded in `phase-1-logs/top-hotspots.txt`.

| Lines | File | Production criticality |
|---:|---|---|
| 15539 | `ios/LifeOS/Modules/Nutrition/NutritionDayView.swift` | High: largest SwiftUI nutrition surface, likely UX/perf risk |
| 13004 | `ios/LifeOSTests/LowCoverageUtilitiesTests.swift` | Medium: large safety-net test file, maintainability risk |
| 11010 | `ios/LifeOSTests/CoverageFinalPushTests.swift` | Medium: large safety-net test file |
| 4398 | `supabase/migrations/20260216000001_api_schema.sql` | High: schema/RLS/migration foundation |
| 4112 | `ios/LifeOS/Modules/Settings/SettingsDestinationViews.swift` | High: privacy/account/settings surface |
| 3778 | `ios/LifeOS/Modules/Training/TrainingDayView.swift` | High: training UX and calculations |
| 3558 | `supabase/functions/tests/edge_local_e2e.ts` | High: Edge integration proof surface |
| 3195 | `ios/LifeOS/Modules/Nutrition/NutritionService.swift` | High: nutrition domain service |
| 2706 | `supabase/functions/tests/ai_entrypoints_success.test.ts` | High: AI endpoint coverage |
| 2653 | `ios/LifeOS/Modules/Shared/Database/Migrations.swift` | High: local database migrations |
| 2593 | `ios/LifeOS/Modules/Shared/Database/SyncEngine.swift` | High: offline sync integrity |
| 2544 | `ios/LifeOSTests/NutritionServiceTests.swift` | Medium-high: nutrition regression net |
| 2269 | `ios/LifeOS/Modules/Settings/SettingsAccountDestinationViews.swift` | High: account/export/delete/auth UX |
| 2244 | `ios/LifeOS/Modules/Diary/DiaryView.swift` | Medium-high: core daily UX |
| 2200 | `ios/LifeOSTests/SyncEngineControlFlowTests.swift` | High: sync behavior proof |
| 1969 | `ios/LifeOS/Modules/Sleep/SleepDetailSupport.swift` | Medium-high: sleep/recovery domain |
| 1959 | `ios/LifeOS/Modules/Supplements/SupplementsDayView.swift` | Medium-high: wellness/sensitive routine |
| 1868 | `ios/LifeOS/Modules/Shared/HealthKit/HealthKitManager.swift` | High: HealthKit privacy/data import |
| 1826 | `ios/LifeOS/Modules/Auth/OnboardingFeature.swift` | High: onboarding/account bootstrap |
| 1717 | `ios/LifeOS/Modules/Auth/OnboardingView.swift` | High: first-run UX |

## Source Modification Check

No source/config/doc file under `ios`, `watch`, `supabase`, `scripts`, or `.github` was modified in the last 45 minutes at the time of this inventory check. Evidence: `phase-1-logs/source-files-modified-last-45m.txt` has 0 lines.

Files created/updated by this phase are audit artifacts under `audits/production-readiness-2026-06-22/` plus Supergoal progress files under `.supergoal/production-audit-life-os-RFyokC/`.

## Phase 1 Notes For Later Phases

- Use warmed/shared `DERIVED_DATA_PATH` when diagnosing Xcode lanes; pre-flight showed clean source gates can look red when each command re-clones SwiftPM packages and GRDB submodules under separate temp DerivedData.
- Supabase first local start required large image pulls, but targeted retry eventually made `supabase start`, `db lint`, `db reset`, Edge e2e/load, and preprod security pass green.
- `supabase db lint` exited 0 but reported a warning: `unused parameter "p_now"`. Phase 4 should decide whether to fix or document it.
- `scripts/run_ios_sync_contract_gate.sh` is safe when `DERIVED_DATA_PATH` is set; without it, macOS bash can fail on empty `EXTRA_ARGS[@]`. Phase 7 should harden that script if the bug remains in source.
