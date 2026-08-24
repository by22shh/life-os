# Phase 13 - Performance And Memory Audit

## Result

PASS after fixing the performance gate harness and rerunning the exact mandatory command.

Production code was not changed in this phase. The only code change is in `scripts/run_ios_performance_hard_gates.sh`, where an empty optional argument array could crash the gate before any app budget was measured.

## Fix Applied

### Performance hard-gate script

File: `scripts/run_ios_performance_hard_gates.sh`

Before:

- `phase-13-logs/ios-performance-hard-gates.log`: failed before tests with `EXTRA_ARGS[@]: unbound variable`, `exit=1`.

After:

- `phase-13-logs/ios-performance-hard-gates-after-extra-args-fix.log`: passed with a shared DerivedData path, `exit=0`.
- `phase-13-logs/ios-performance-hard-gates-exact-after-fix.log`: the exact mandatory command `bash scripts/run_ios_performance_hard_gates.sh` passed, `exit=0`.

The fix builds a single `XCODEBUILD_ARGS` array, conditionally appends `-derivedDataPath`, and invokes `xcodebuild test` once with a non-empty argument list.

## Hard Gates

Final exact run:

- `PerformanceBudgetTests`: 4 tests, 0 failures.
- `PerformanceHardGateTests`: 2 tests, 0 failures.
- `PerformanceHardGateUITests`: 1 test, 0 failures.
- Overall: `TEST SUCCEEDED`, `iOS performance hard-gates passed.`, `exit=0`.

Budget scope verified by source review:

- Startup UI gate: warm-up launch excluded, 3 measured launches, average <= 4000 ms, max <= 5000 ms.
- Sync latency gate: 600 queued events must push within 2500 ms.
- Sync memory gate: 1200 queued events must stay within 64 MB resident growth and 450 MB isolated peak when `LIFEOS_PERFORMANCE_HARD_GATES=1`.
- Budget constants gate: cold launch 2000 ms, warm launch 500 ms, diary refresh 200 ms, local query 50 ms.

Note: the `perf.budget_exceeded.*` lines in the hard-gate logs come from `PerformanceBudgetTests/testPerformanceMonitorTrackingPathsDoNotCrash`, which intentionally exercises exceeded-branch logging. The XCTest result is the source of truth here, and it passed.

## SwiftUI Hot Path Review

Mandatory line-count scan:

- `phase-13-logs/swiftui-hotspot-line-counts.log`: `exit=0`.
- Largest files reviewed: `NutritionDayView.swift` (15539 lines), `SettingsDestinationViews.swift` (4112), `TrainingDayView.swift` (3778), `NutritionService.swift` (3195), `SyncEngine.swift` (2593), `DiaryView.swift` (2244), `SleepDetailSupport.swift` (1969), `LabsView.swift` (1339), `LifeOSApp.swift` (1459).

Mandatory smell scan:

- `phase-13-logs/swiftui-smell-scan.log`: `rg_exit=0`, `exit=0`.

Triage:

- `UIImage(data:)` appears in Nutrition and Labs selected-photo action paths. These are user-triggered picker flows, not repeated SwiftUI `body` work or large-list decoding.
- `GeometryReader` appears in bounded chart/bar components: Sleep sparkline and ACWR load bar. Both use fixed, small render surfaces and do not drive unbounded layout feedback.
- `NumberFormatter()` appears in `BodyCompositionViewModel.formattedDecimal`. It is limited to body-composition summary/edit values, not the launch path and not a high-cardinality scrolling list.
- `.filter(`, `.sorted(` scan hits are mostly GRDB query builders, model/service transformations, or small UI collections. No unstable `ForEach(... id: \.self)` hot-loop issue was found in the scanned output.

No production SwiftUI performance change was made because the concrete evidence did not show a release-blocking body recomputation, image decode loop, unstable identity loop, or layout-thrash defect.

## Runtime Trace

Trace artifacts:

- `phase-13-traces/lifeos-launch-time-profiler.trace`: Time Profiler launch trace, 5.3 MB.
- `phase-13-logs/time-profiler-toc.xml`: exported trace table of contents, `exit=0`.
- `phase-13-logs/time-profiler-profile.xml`: exported time-profile table, `exit=0`.
- `phase-13-logs/time-profiler-window-summary.log`: parsed summary for the startup hang window, `exit=0`.

Trace facts:

- Device: simulated iPhone 17 Pro, iOS 26.2.
- Template: Time Profiler.
- Duration: 13.131184 seconds, time limit reached normally.
- Process: `LifeOS`, launched process, return status 0.
- Environment: UI test bootstrap authenticated with background-isolation flags and localhost-invalid Supabase config.

Trace findings:

- `time-profiler-hang-risks.xml` exported cleanly and contains no hang-risk rows.
- `time-profiler-potential-hangs.xml` contains one startup `Hang` row: Main Thread, start `00:02.624.424`, duration `575.70 ms`.
- The parsed window summary covers 360 samples. The first stacks are dominated by UIKit scene updates, Swift protocol conformance and AttributeGraph layout descriptor work, dyld loading, and scene session persistence. There is no concrete LifeOS view-body loop or large data transform in that window.
- Later samples show post-bootstrap notification and widget refresh work. This is a valid future optimization target, but it did not violate the hard gates and was not changed without a clearer product contract.

## Memory Graph

Memgraph artifacts:

- `phase-13-logs/leaks-help.log`: confirmed simulator `leaks --outputGraph` support, `exit=0`.
- `phase-13-logs/memgraph-capture-by-launch-pid.log`: navigation-heavy flow plus memgraph capture, `exit=0`.
- `phase-13-traces/lifeos-navigation.memgraph`: captured memory graph, 2.3 MB.

Flow covered:

- launch authenticated app
- `lifeos://home`
- `lifeos://diary?mode=review`
- `lifeos://nutrition?date=2026-06-23`
- `lifeos://workout?date=2026-06-23`
- `lifeos://labs`
- `lifeos://sleep?date=2026-06-23`
- `lifeos://insights`
- `lifeos://settings/privacy`
- `lifeos://home`

Result:

- `leaks_exit=0`
- `Output graph successfully written`
- `memgraph_status=captured`

Two earlier attempts are retained for audit trail:

- `memgraph-capture.log`: invalid shell glob issue on an unquoted `?mode=review` URL.
- `memgraph-capture-rerun.log`: valid navigation but invalid pid discovery through simulator `ps`; final run used the pid returned by `simctl launch`.

## Mandatory Commands

- `bash scripts/run_ios_performance_hard_gates.sh`: initial harness failure fixed, final exact rerun passed, `exit=0`.
- `bash -lc 'find ios/LifeOS watch -type f -name "*.swift" -print0 | xargs -0 wc -l | sort -rn | head -40'`: passed, `exit=0`.
- `bash -lc 'rg -n "GeometryReader|ForEach\\(.*id: \\\\.self|UIImage\\(data:|NumberFormatter\\(|MeasurementFormatter\\(|sorted\\(|filter\\(" ios/LifeOS watch --glob "*.swift" || true'`: completed and reviewed, `exit=0`.

## Remaining Risk

No release-blocking performance or memory defect remains in this phase.

The only non-blocking risk is startup/post-active polish: Time Profiler saw a 575.70 ms simulator startup hang window and later notification/widget refresh work. The hard gates still passed, `hang-risks` exported empty, and memgraph capture completed with `leaks_exit=0`, so this is a follow-up optimization candidate rather than a production blocker.
