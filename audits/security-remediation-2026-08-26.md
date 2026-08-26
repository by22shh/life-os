# Security & Quality Remediation — 2026-08-26

Follow-up to `audits/production-readiness-2026-06-22` and the deep platform
audit of 2026-08-26. Every item below was implemented **and verified** in this
repository; verification evidence is listed per section.

## Backend security (migration `20260825000001_security_hardening.sql`)

1. **PUBLIC execute revoked** on 7 SECURITY DEFINER functions that were
   callable by anon/authenticated via PostgREST RPC:
   `purge_soft_deleted_rows`, `process_due_account_deletion_jobs`,
   `cleanup_service_role_audit_log`, `log_service_role_invocation`,
   `cleanup_expired_feature_flags`, `bootstrap_user_from_auth`,
   `process_due_medical_scan_retention_jobs`.
2. **`resolve_feature_flags_for_user` cross-tenant read closed**: effective
   user is now derived from the JWT claim; explicit `p_user_id` is honored
   only for trusted roles (`service_role`, `postgres`). Edge contract is
   unchanged.
3. **RLS enabled** on `workout_exercises` and `batch_recipe_ingredients`
   (parent-scoped SELECT/INSERT/UPDATE policies, hard-delete denied,
   matching grants for authenticated).
4. **`deletion_failures.user_id` FK CASCADE** added (orphan/resolved rows
   purged first) — GDPR residue after account deletion eliminated.
5. **Legacy plaintext export download tokens invalidated**; tokens are now
   stored as SHA-256 digests (`_shared/export_builder.ts`) with a rotation
   path when no reusable URL exists.
6. **Ops alert dispatcher cron scheduled** (`dispatch_ops_alert_events`,
   hourly) using the existing vault accessors + pg_net pattern.

Verification: applied against a clean postgres 16 harness with baseline-shaped
stubs; behavior checks confirmed (a) B requesting A's flag id sees only its
own view, (b) service_role explicit-id path works, (c) anon/authenticated have
no EXECUTE on all revoked functions while service_role retains them, (d)
parent-scoped RLS blocks foreign workout rows and grants are
SELECT/INSERT/UPDATE only, (e) FK delete rule = CASCADE.

## Edge functions

7. **Outbox replay exemption hardened** (`_shared/rate_limit.ts`): the
   `X-Outbox-Replay` header now swaps tier budgets only for
   standard/write_heavy/analytics. AI, search, auth, deletion and export
   tiers can never be relaxed by a client header (previously ai_vision
   10/min+30/hr could become ~60/min sustained).
8. **CORS origin allowlist** (`_shared/cors.ts`): optional
   `CORS_ALLOWED_ORIGINS` env restricts browser preflight to exact origins;
   unset keeps historical wildcard for native clients.
9. **New `ops-alert-dispatch` function**: bridges recent `ops_alert_events`
   rows to an OPS_ALERT_WEBHOOK_URL (Slack-compatible digest). Service-role +
   invocation-header protected, registered in config.toml, covered by local
   e2e entrypoint coverage test.

Verification: `deno fmt --check` (119 files), `deno lint` (0 problems),
`deno test -A functions/tests`: **234 passed, 0 failed** (3 new tests:
AI-tier replay denial, CORS allowlist reflect/deny, legacy token rotation).

## iOS client

10. **No more data destruction on sync failure**: permanent experiment-create
    failure now *quarantines* the row (`sync_quarantine_reason`, migration
    v30) instead of deleting experiments/measurements. Quarantined rows are
    hidden from lists (`InsightsView`) and remain recoverable via outbox
    bootstrap replay.
11. **Menstrual logs encrypted at rest** (migration v31): `flow` and
    `pain_level` migrated to the AES-256-GCM envelope scheme; custom
    GRDB record mapping added (`GRDBRecords.swift`); `DiaryViewModel` raw-SQL
    reader decrypts transparently.
12. **Sync loop reentrancy guard**: overlapping cycles coalesce instead of
    double-processing outbox events.
13. **Atomic `markFailed`**: attempt-count read, backoff computation and
    status write happen in one write transaction.
14. **LWW pull guard protects unpushed edits**: pull skips overwriting rows
    whose local `updated_at` is newer than the incoming server timestamp.
15. **Throwing decode for required encrypted numerics**
    (`requiredEncryptedDoubleThrowing`): failed decryption of a health
    measurement surfaces as an error instead of silently displaying 0.0.
16. **Client-side rate limits mirror server policy**
    (`RateLimitPolicy.replayExemptibleTiers`): replay bypasses only
    exemptible tiers; the previously dead `outboxReplayPerFiveMinutes`
    window is enforced for replay traffic.
17. **Feature flags fail closed on stale cache for cost-bearing AI flags**
    (`failsClosedOnStaleCache`), so kill switches cannot decay after TTL.
18. **Local SQLite backups implemented** (`DatabaseBackupManager`): daily
    backup with WAL checkpoint, 3-copy retention, restore lookup; wired
    after successful startup migrations. Closes the spec-vs-code gap.
19. Hygiene: HealthKit force unwraps removed (safe fallbacks), AuthManager
    session-monitor observers tracked and de-duplicated, schema version
    constant raised to 31.

Verification: full `LifeOSTests` suite: **776 passed, 0 failed, 5 skipped**
(hardware-dependent), parallel run, ad-hoc signed (`CODE_SIGN_IDENTITY=-`;
note: `CODE_SIGNING_ALLOWED=NO` breaks Keychain-dependent tests locally).
New `DatabaseBackupManagerTests` pass.

## CI / ops

20. Workflow: SwiftPM caching, failure artifact upload (xcresults/logs),
    deterministic simulator selection, new secret-gated
    `supabase-staging-deploy` job wired into the aggregate gate (skipped =
    pass, failed = fail). YAML validated (15 jobs).
21. `supabase/DEPLOYMENT.md` written: link/db push/functions deploy, Vault
    secrets, required edge env vars, expected cron jobs, post-deploy
    checklist, rollback policy.
22. `.env.example` documents every environment variable (grep-verified).

## Still open (requires external resources or larger refactors)

- Crash reporting SDK (Sentry/Crashlytics) — needs vendor account + DSN;
  CI upload step should follow.
- Real-device smoke, live provider smoke, hosted soak — same external
  blockers as the June audit (APNs prod, App Store IDs, hosted Vault/cron).
- TLS pinning decision for the three raw URLSession paths.
- `MixedUUIDStorage` dual-format canonicalization (~92 call sites).
- v25/v31-style migrations still brick the app if Keychain is unavailable
  before first unlock (safe-by-design; availability trade-off documented).
- Monolith view splitting (>1000-line files) and broad `try?` reduction.
