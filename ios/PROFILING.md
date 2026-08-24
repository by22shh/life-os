# iOS Settings/Sync Profiling (Release Gate)

Use Instruments CLI to capture CPU and memory traces while running the Settings Sync UI flow.

## Command

```bash
bash scripts/profile_ios_settings_sync.sh
```

Optional environment overrides:

```bash
SIM_NAME="iPhone 17" PROFILE_DURATION_SECONDS=30 bash scripts/profile_ios_settings_sync.sh
```

To keep artifacts in a specific location, override `LIFEOS_ARTIFACTS_DIR`:

```bash
LIFEOS_ARTIFACTS_DIR="/absolute/path" bash scripts/profile_ios_settings_sync.sh
```

## Outputs

The script writes artifacts to:

- `${TMPDIR}/life-os/profiles/<timestamp>/settings_sync_ui.xcresult`
- `${TMPDIR}/life-os/profiles/<timestamp>/time_profiler_settings_sync.trace`
- `${TMPDIR}/life-os/profiles/<timestamp>/allocations_settings_sync.trace`

If `LIFEOS_ARTIFACTS_DIR` is set, the script writes under that directory instead.

## Release checks

- `Time Profiler`: no sustained main-thread hotspots in Settings/Sync flow.
- `Allocations`: no monotonic growth while opening Settings -> Sync and dismissing blocker.
- `UI test`: `testSyncConflictScenario` passes in the same run.
