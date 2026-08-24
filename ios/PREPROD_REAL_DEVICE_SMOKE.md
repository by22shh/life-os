# Pre-Prod Real Device Smoke

Use this checklist right before TestFlight/production cut. Run on a physical iPhone/iPad (not simulator).

## Automated smoke

```bash
bash scripts/run_ios_preprod_real_device_smoke.sh
```

This runs `LifeOSTests/RealDeviceSmokeTests` on the connected device:
- Notification settings access (APNs capability precheck)
- HealthKit availability + authorization status snapshot
- Background refresh status availability
- Offline-first replay validation (outbox failures while offline, full replay after recovery)
- Chaos retry validation (mixed retryable failures/429, eventual queue drain without loss)

## Manual APNs + HealthKit + background validation

1. Install and launch the Debug build on the device.
2. Complete onboarding with HealthKit and notification permissions enabled.
3. Trigger one outbound notification intent in-app and verify it appears in Notification Center.
4. Put app in background for at least 10 minutes, then reopen and confirm sync loop runs without blocker banner.
5. In iOS Settings, revoke notification permission, reopen app, verify non-critical notifications are disabled/blocked.
6. Re-enable notification permission, relaunch app, verify notification flows recover.
7. In iOS Settings -> Privacy & Security -> Health, revoke one required HealthKit type.
8. Relaunch app and verify HealthKit degradation is handled gracefully (no crash, surfaced state).
9. Re-enable HealthKit permissions and verify daily sync can recover.
10. Lock device and wait for background window; confirm next foreground launch has updated sync timestamps.

## Exit criteria

- No crash during permission changes.
- No stuck `failed_permanent` blocker after recovery actions.
- Notification and HealthKit behavior matches expected degraded/recovered states.
- Background sync resumes on foreground without manual DB reset.
