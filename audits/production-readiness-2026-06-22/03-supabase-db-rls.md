# Phase 4 - Supabase DB, RLS, Index, and Destructive Path Audit

Date: 2026-06-23

## Verdict

Status: PASS after hardening migration.

The mandatory Supabase database gate passes from a clean local reset, and the live schema no longer exposes user-scoped tables without RLS, unindexed FK predicates, or unwrapped `auth.uid()` / `auth.role()` policy helpers.

## Changes Made

- Added `supabase/migrations/20260320000001_db_rls_policy_hardening.sql`.
- Closed `public.deletion_audit_log` to client roles:
  - enabled RLS;
  - forced RLS;
  - added explicit deny policy for `anon` and `authenticated`;
  - revoked all table privileges from `anon` and `authenticated`;
  - retained `service_role` access for Edge cleanup/audit flows.
- Added 13 missing FK/RLS-supporting indexes:
  - `idx_food_catalog_items_created_by_user`
  - `idx_user_supplements_catalog`
  - `idx_supplement_logs_user_supplement`
  - `idx_body_composition_previous_measurement`
  - `idx_exercise_catalog_created_by`
  - `idx_training_plan_sessions_actual_session`
  - `idx_experiment_measurements_user_date`
  - `idx_insights_suggested_experiment`
  - `idx_recommendations_insight`
  - `idx_health_diagnoses_source_scan`
  - `idx_ab_tests_flag`
  - `idx_user_feature_overrides_flag`
  - `idx_account_deletion_jobs_auth_user`
- Rewrote existing public/storage policy expressions from direct `auth.uid()` / `auth.role()` calls to `(SELECT auth.uid())` / `(SELECT auth.role())`.
- Replaced the deprecated `process_due_account_deletion_job(UUID, TIMESTAMPTZ)` body so schema lint remains clean without changing its signature or deprecation behavior.

## Mandatory Commands

| Command | Result | Evidence |
| --- | --- | --- |
| `supabase stop --workdir . --no-backup --yes || true; supabase start --workdir .` | PASS | `phase-4-logs/supabase-start.log` |
| `supabase db lint --workdir .` before hardening | PASS with warnings | `phase-4-logs/supabase-db-lint.log` |
| `supabase db reset --workdir . --no-seed --yes` before hardening | PASS | `phase-4-logs/supabase-db-reset.log` |
| required RLS/index/destructive `rg` scan before hardening | PASS | `phase-4-logs/rls-index-pattern-scan.txt` |
| `supabase db reset --workdir . --no-seed --yes` after hardening | PASS | `phase-4-logs/supabase-db-reset-after-hardening.log` |
| `supabase db lint --workdir .` after hardening | PASS, no schema errors | `phase-4-logs/supabase-db-lint-after-hardening.log` |
| required RLS/index/destructive `rg` scan after hardening | PASS | `phase-4-logs/rls-index-pattern-scan-after-hardening.txt` |

The pre-hardening lint warning was:

- `public.process_due_account_deletion_job`: unused `p_job_id`, unused `p_now`.

The post-hardening lint output is clean:

- `No schema errors found`

## Live Schema Audit

Evidence:

- `phase-4-logs/db-schema-tables-policies-indexes.log`
- `phase-4-logs/db-schema-risk-queries-clean.log`
- `phase-4-logs/db-schema-risk-queries-after-hardening.log`
- `phase-4-logs/db-schema-summary-after-hardening.log`
- `phase-4-logs/deletion-audit-client-access-check.log`

Post-hardening summary:

| Check | Result |
| --- | --- |
| public tables | 58 |
| public tables with RLS | 50 |
| public tables with forced RLS | 4 |
| user-scoped tables | 46 |
| user-scoped tables with RLS | 46 |
| user-scoped tables without RLS | 0 |
| unindexed foreign keys | 0 |
| user/auth id columns without leading index | 0 |
| public policies | 207 |
| storage policies | 4 |
| policies using auth helper without SELECT wrapper | 0 |

Critical before/after:

- Before hardening, `deletion_audit_log` was the only user-id-like table without RLS and still had `anon` / `authenticated` privileges.
- After hardening, `deletion_audit_log` has RLS, forced RLS, an explicit deny policy for client roles, and no `anon` / `authenticated` grants.
- Direct check as `anon` returns expected `permission denied for table deletion_audit_log`.

## Destructive, Retention, and Account Deletion Coverage

Targeted Deno proof:

```text
deno test --allow-env --allow-net --allow-read --allow-write \
  supabase/functions/tests/account_deletion_helpers.test.ts \
  supabase/functions/tests/settings_privacy_edge.test.ts \
  supabase/functions/tests/medical_scan_privacy.test.ts
```

Result: PASS, 32 tests plus 13 substeps, 0 failed.

Evidence:

- `phase-4-logs/deno-destructive-retention-tests.log`

Covered paths:

- account auth deletion retry/missing-principal behavior;
- Postgres account deletion RPC success/failure verification;
- deletion audit upsert compliance metadata;
- account deletion job manifest normalization and storage cleanup;
- privacy PATCH cloud-data cleanup and local-only enforcement;
- medical scan 90-day retention deadline calculation;
- expired medical scan artifact pruning;
- storage delete/list/update failure propagation;
- medical scan privacy enforcement cleanup paths.

## Acceptance Criteria

| Criterion | Status | Evidence |
| --- | --- | --- |
| DB lint passes | PASS | post-hardening lint exit 0, no schema errors |
| DB reset applies migrations cleanly | PASS | post-hardening reset exit 0 through `20260320000001_db_rls_policy_hardening.sql` |
| Every user-scoped table has RLS or safe reason | PASS | 46/46 user-scoped tables with RLS |
| RLS uses indexed columns / avoids auth hot spots where practical | PASS | no user/auth id columns without leading index; 0 policies without SELECT wrapper |
| FKs/high-cardinality/join columns indexed or documented | PASS | unindexed FK query returns 0 rows after 13 added indexes |
| Destructive/retention/account-deletion paths covered by DB or Edge tests | PASS | targeted Deno destructive/retention suite passes |

## Notes

- Local Supabase remains running intentionally because Phase 5 requires Edge/local E2E and load checks against the local stack.
- Local cron scheduling notices for account deletion and medical scan retention workers are expected in reset logs when vault secrets are absent in the local stack.
