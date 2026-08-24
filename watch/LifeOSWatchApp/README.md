# LifeOSWatchApp

Watch-side implementation mirror for the snapshot flow used by the iOS host app.

## Included
- `LifeOSWatchApp.swift`: watch entry point.
- `WatchSnapshotStore.swift`: WatchConnectivity receiver (application context + user info).
- `WatchHomeView.swift`: recovery score/zone UI with VoiceOver-friendly announcement text.
- `WatchSnapshotModel.swift`: shared payload contract.

## Invariants
- No direct backend calls from watch.
- Snapshot payload is received from iPhone host via WatchConnectivity.
- Recovery zone mapping follows `life_os_invariants.md`.
