# Phase 5 - Supabase Edge Functions Audit

Date: 2026-06-23

## Verdict

Status: PASS after E2E harness hardening and alias coverage additions.

All Deno gates, the full Edge unit/integration test suite, local Edge E2E, and local Edge load checks pass from a fresh local Supabase stack.

## Changes Made

- Updated `scripts/run_supabase_edge_e2e.sh` and `scripts/run_supabase_edge_load.sh` to start Supabase with `--exclude edge-runtime`.
  - The E2E/load harness serves each function directly with `deno run` on `localhost:8000`.
  - The built-in Supabase `edge-runtime` container is not used by those tests and was causing a flaky boot failure when its internal main worker attempted a remote `deno.land` import without Docker egress.
- Added explicit E2E alias coverage in `supabase/functions/tests/edge_local_e2e.ts`:
  - `api-sleep-log`
  - `api-workout-log`

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| `deno fmt --check supabase/functions` | PASS, 112 files | `phase-5-logs/deno-fmt-check-after-aliases.log` |
| `deno lint supabase/functions` | PASS, 112 files | `phase-5-logs/deno-lint-after-aliases.log` |
| `find supabase/functions -type f -name "*.ts" -print0 \| xargs -0 deno check` | PASS | `phase-5-logs/deno-check-all-ts-after-aliases.log` |
| `deno test -A supabase/functions/tests` | PASS, 225 tests, 46 steps, 0 failed | `phase-5-logs/deno-test-all-functions-tests-after-aliases.log` |
| `bash scripts/run_supabase_edge_e2e.sh` | PASS | `phase-5-logs/edge-local-e2e-after-aliases.log` |
| `bash scripts/run_supabase_edge_load.sh` | PASS | `phase-5-logs/edge-local-load-final.log` |

## E2E and Load Summary

Initial E2E failure:

- `phase-5-logs/edge-local-e2e.log`
- Failure: Supabase `edge-runtime` container booted an internal main worker that imported `https://deno.land/std/http/status.ts`; Docker egress was unavailable, so `supabase start` failed before app scenarios ran.
- Fix: exclude the unused built-in `edge-runtime` service in the repo E2E/load scripts. Function scenarios still run against fresh local Auth/REST/DB/Storage and are served by `deno run` per function.

Final E2E:

- 58 configured functions normalized to 58 E2E OK scenarios.
- No configured functions missing from E2E coverage.
- No extra unconfigured E2E scenarios after normalization.

Final load:

| Endpoint | Requests | Concurrency | p50 | p95 | p99 | Error Rate | Statuses |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `api-food-log` | 120 | 16 | 88.3ms | 144.1ms | 149.7ms | 0.00% | `{"202":120}` |
| `api-settings-notifications` | 90 | 16 | 94.6ms | 108.0ms | 112.7ms | 0.00% | `{"200":90}` |

## Endpoint Risk Matrix

Evidence: `phase-5-logs/endpoint-coverage-matrix-final.txt`.

| Risk Area | Coverage Status | Evidence |
| --- | --- | --- |
| Configured function inventory | PASS | 58 configured functions from `supabase/config.toml` |
| E2E scenario parity | PASS | 58 normalized E2E OK scenarios |
| Alias functions | PASS | `api-sleep-log`, `api-workout-log`, `api-hydration-log`, `api-wellness-check`, `api-supplement-log` covered |
| Auth guardrails | PASS | `user_context.test.ts`, `settings_*_edge.test.ts`, AI entrypoint tests, E2E unauthorized checks |
| CORS/preflight | PASS | `shared_coverage.test.ts`, `settings_notifications_edge.test.ts`, `settings_privacy_edge.test.ts`, E2E readiness preflights |
| Malformed payloads | PASS | `payload_malformed.test.ts`, endpoint-specific invalid payload tests |
| Rate limits | PASS | `rate_limit_security.test.ts`, `correlation_property.test.ts`, settings/AI/supplement guard tests, E2E 429 checks |
| Destructive/export/delete flows | PASS | account deletion/export E2E plus helper tests carried from Phase 4 |
| AI gateway/image endpoints | PASS | AI entrypoint tests and E2E smoke for OpenRouter gateway, food image, label, and batch-recipe endpoints |
| Food/nutrition/training/labs/watch endpoints | PASS | E2E scenarios plus full Deno tests |

## Acceptance Criteria

| Criterion | Status |
| --- | --- |
| `deno fmt --check supabase/functions` passes | PASS |
| `deno lint supabase/functions` passes | PASS |
| `deno check` passes for every TypeScript function/test file | PASS |
| `deno test -A supabase/functions/tests` passes | PASS |
| Local Edge e2e and load scripts pass against a fresh local Supabase stack | PASS |
| Rate limiting, CORS, malformed payload, and auth guard tests cover public endpoints | PASS |

## Notes

- The scripts intentionally keep `gotrue`, REST, DB, storage, and gateway services in the local stack; only the unused built-in `edge-runtime` health dependency is excluded.
- The Supabase local stack is stopped by the E2E/load script cleanup traps at the end of each run.
