# Sleep identity, source precedence and offline transactions

Implemented September 9, 2026. Changes remain in the shared working tree; no commits or independent Xcode build were made.

- Manual sleep edits reuse the existing morning record UUID, restore a deliberately edited deleted record, clear imported stage estimates, and set the authoritative source to manual. Subsequent HealthKit imports preserve this record and derive physiological sleep fields and recovery scores from it.
- `SleepRecordSelection` handles legacy GRDB UUID blobs and string user identifiers. Daily selection and history prefer manual records; recent history counts distinct days. Obsolete local source records become tombstones. Sync reconciliation applies the same policy across distinct device UUIDs and recalculates local physiological fields from the selected sleep record.
- Manual sleep, physiological state and their outbox events are atomic with or without an active SyncEngine. Imported workouts are also queued atomically without an engine and are not queued again when unchanged.
- The old `api-sleep-log` configuration pointed to a GET-only endpoint. It now points to an authenticated write handler with field validation and actor binding. Migration `20260909000004_sleep_canonical.sql` adds objective sleep columns without changing existing subjective column types, and a service-role-only RPC serializes writes by user and morning date. It preserves one server UUID, rejects foreign IDs and moving an existing ID between dates, honors manual precedence and ignores stale same-source replay. Imports cannot revive a manually deleted record.
- Sleep decoding accepts the legacy server's clock-only diary fields and alcohol boolean alongside objective fields. Qualitative environment labels do not become fabricated numeric measurements or abort a complete sync pull.

## Verification

- PASS: Swift parser for changed health/sleep/model/test files.
- PASS: `deno check supabase/functions/api/sleep/log/index.ts`.
- PASS: `deno test --allow-all supabase/functions/tests/sleep_log.test.ts supabase/functions/tests/edge_entrypoint_coverage.test.ts` — 4 tests.
- Added XCTest regressions in `HealthSyncManagerFlowTests.swift`: HealthKit → manual → HealthKit preserves UUID, values, score parity and outbox; outbox insertion failure rolls back sleep and state; distinct-day manual history with blob/string IDs; unchanged workout import queues once without SyncEngine; legacy server diary JSON decodes with objective data.
- Added real edge E2E scenario: HealthKit write → manual write with another UUID → later HealthKit write keeps canonical manual duration and cleared stages.
- Added rollback-only `scripts/check_sleep_canonical.sql`: natural-key identity, stale replay, ownership, immovable date, deletion protection and RPC privilege checks.
- Full XCTest and real PostgreSQL/E2E runs are coordinated by the parent agent. This subagent did not start the local stack; connection port 54322 was unavailable when first checked.

## Integration

No new Swift source files require project registration. SyncEngine now remaps legacy sleep REST outbox events to the canonical endpoint, recognizes blob UUID local edits, and protects manual records from incoming HealthKit rows before save. Two added SyncEngineControlFlowTests exercise the actual pull/dispatch paths. Deploy migration 00004 before deploying the new sleep write endpoint.

## Final legacy regression pass

Subjective-only legacy rows with NULL duration can now receive HealthKit metrics without losing notes or perceived quality. A manual tombstone still blocks enrichment. A subjective-only pull retains existing physiological measurements; it is not a command to erase them. Canonical `bed_time` takes precedence over the old subjective `bedtime_actual` TIME field after a cloud pull. Added XCTest and SQL regressions cover these cases. The test decoder was corrected to use explicit snake-case/ISO8601 handling after the parent compiler caught an inaccessible SDK-only decoder method.
