# watchOS Workspace

This folder contains watchOS-side artifacts used by the Life OS architecture review:

- `watch/LifeOSWatchApp/` — watch snapshot payload contract (host-fed via WatchConnectivity).
- `watch/LifeOSComplications/` — complication module wired to host snapshot data.

Source iOS target implementation remains in:
- `ios/LifeOSWatch/`

Invariant guardrail:
- No direct backend calls from watchOS code.
