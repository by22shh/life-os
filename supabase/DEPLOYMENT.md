# Production Deployment Procedure

Operational runbook for deploying the Life OS Supabase backend (database +
edge functions) to a hosted Supabase project. Migration policy is
**forward-only** — see `supabase/README.md` before touching migrations.

## Prerequisites

- Supabase CLI installed: `brew install supabase/tap/supabase`
- A personal access token with deploy rights (Dashboard → Account → Access Tokens)
- Hosted project ref and database password (Dashboard → Project Settings → Database)
- Credentials ready for the secrets step below: OpenRouter API key, APNs signing
  key (`AuthKey_<KEY_ID>.p8` contents), APNs team/key IDs, bundle ID
- Run all CLI commands from the repo root so `--workdir .` resolves
  `supabase/config.toml`

## Step-by-step

### 1. Authenticate and link

```bash
export SUPABASE_ACCESS_TOKEN="sbp_..."   # or run: supabase login
supabase link --project-ref "<project-ref>" --workdir .
```

### 2. Create Vault secrets (before db push)

The account-deletion worker, medical scan retention worker, and ops alert
dispatcher read `project_url` / `service_role_key` from Vault. Their cron
schedules are only created when **both** secrets resolve at migration time,
so create them first:

```bash
psql "postgresql://postgres:<db-password>@db.<project-ref>.supabase.co:5432/postgres"
```

```sql
select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
select vault.create_secret('<service-role-key>', 'service_role_key');
```

### 3. Push migrations (forward-only)

```bash
supabase db push --workdir .
```

Never edit or delete an applied migration; add a new forward-only file instead.

### 4. Deploy edge functions

```bash
supabase functions deploy --project-ref "<project-ref>" --workdir .
```

Omitting the function name deploys every function declared in
`supabase/config.toml`.

### 5. Configure edge runtime secrets

```bash
supabase secrets set \
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:?Set OPENROUTER_API_KEY in your shell}" \
  OPENROUTER_REFERER="https://lifeos.app" \
  OPENROUTER_APP_NAME="Life OS" \
  APNS_TEAM_ID="..." APNS_KEY_ID="..." \
  APNS_PRIVATE_KEY_P8="$(cat AuthKey_XXXXXXXXXX.p8)" \
  APNS_BUNDLE_ID="com.lifeos.app" \
  MIN_SUPPORTED_APP_VERSION="1.0.0" \
  SOFT_UPDATE_VERSION="1.1.0" \
  APP_STORE_URL="https://apps.apple.com/app/id<app-store-id>" \
  APP_STORE_ID="<numeric-app-store-id>"
```

Required:

| Variable | Purpose |
| --- | --- |
| `OPENROUTER_API_KEY` | AI endpoints (`ai-openrouter-gateway`, food analysis, insights) |
| `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_P8`, `APNS_BUNDLE_ID` | Push notification token signing |
| `MIN_SUPPORTED_APP_VERSION`, `SOFT_UPDATE_VERSION` | Force-update headers on every edge response |
| `APP_STORE_URL` or `APP_STORE_ID` | Upgrade target URL in force-update headers |

Optional:

| Variable | Purpose |
| --- | --- |
| `CORS_ALLOWED_ORIGINS` | Comma-separated allowlist; unset = permissive CORS |
| `OPS_ALERT_WEBHOOK_URL` | Webhook sink used by `ops-alert-dispatch` |

### 6. Verify pg_cron jobs

```sql
select jobname, schedule, active from cron.job order by jobname;
```

Expected scheduled jobs:

| jobname | schedule | purpose |
| --- | --- | --- |
| `process_due_account_deletion_jobs` | every minute (`* * * * *`) | dispatches erasure worker to `api-account-delete-worker` |
| `process_due_medical_scan_retention_jobs` | hourly at :15 | expires private medical scan uploads |
| `dispatch_ops_alert_events` | hourly at :45 | POSTs pending ops alerts to `ops-alert-dispatch` (needs pg_net + Vault secrets) |
| `purge-soft-deleted-rows` | daily 03:00 UTC | hard-purges soft-deleted rows past retention |

The consolidated baseline also schedules auxiliary jobs:
`evaluate_ops_queue_alerts` (`*/5 * * * *`) and `cleanup_rate_limit_windows`
(`*/15 * * * *`).

If a vault-dependent job is missing, its schedule block was skipped — fix the
Vault secrets and re-run the matching `cron.schedule(...)` block from
`20260316000001_account_deletion_storage_cleanup.sql`,
`20260317000001_medical_scan_retention_worker.sql`, or
`20260825000001_security_hardening.sql`.

## Post-deploy verification checklist

- [ ] Smoke call with anon key + authenticated JWT returns 200, e.g.
      `curl -s "$SUPABASE_URL/functions/v1/api-config-feature-flags" -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer <jwt>"`
- [ ] Provider smoke passes: `bash scripts/run_nutrition_provider_live_smoke.sh`
      (requires `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_ACCESS_TOKEN`)
- [ ] Live backend smoke against production:
      `LIFEOS_UI_TEST_LIVE_SUPABASE_URL=... LIFEOS_UI_TEST_LIVE_SUPABASE_ANON_KEY=... bash scripts/run_ios_live_backend_smoke.sh`
- [ ] Cron health: `select * from cron.job_run_details order by start_time desc limit 20;`
      shows fresh runs without repeated status failures
- [ ] Edge responses carry `X-Min-App-Version` / `X-Soft-Update-Version`
- [ ] Medical scans storage bucket exists and RLS policies are active

## Rollback notes

- Migrations are **forward-only** (see `supabase/README.md`): there are no down
  migrations and applied files must never be rewritten. Fix forward by adding a
  new migration that undoes or supersedes the bad change.
- Take a PITR/backup snapshot before any destructive migration.
- Function rollback = redeploy the previous good revision:
  `git checkout <last-good-tag> && supabase functions deploy --project-ref "<project-ref>" --workdir .`
- To shield users from a bad backend instead of rolling back schema, raise
  `MIN_SUPPORTED_APP_VERSION` via `supabase secrets set` so stale clients are
  force-updated while you fix forward.

### Vector memory and deletion receipts

Vector memory is optional and requires both AI-processing consent and the user's
vector opt-in. Configure `OPENROUTER_API_KEY`, `PINECONE_API_KEY`, and
`PINECONE_INDEX_HOST` (the HTTPS data-plane host for your index). The default
`VECTOR_EMBEDDING_MODEL` is `openai/text-embedding-3-small`; the Pinecone index
must match the model's embedding dimensions. Changing model/index requires
clearing old vectors before rebuilding the derived memory. Only allowlisted
numeric/boolean summaries are embedded; raw scans and notes are excluded.

Migration `20260909000002_vector_memory_lifecycle.sql` installs the server-only
lease/cleanup state. Its `sync_vector_memory` cron runs every ten minutes when
pg_cron, pg_net and the existing worker Vault credentials are available. If
those credentials are provisioned later, install the same cron statement from
the migration after provisioning and check `cron.job`/`cron.job_run_details`.
Do not assume a successful schema migration implies that cron is enabled.
`api-vector-memory-worker` requires the internal worker authorization headers.
Missing provider configuration causes opt-in to fail explicitly; it does not
produce a fake successful memory state. Provider calls are covered with mocked
transports locally and still need a deployment smoke test with an empty test user.

Account deletion accepts a client-generated 64-hex-character random receipt in
`X-Deletion-Receipt`. The client must store it in device-only Keychain before
submitting deletion. Only a SHA-256 hash is retained server-side. The same header
allows status polling after the auth identity is removed; it grants access only
to that deletion's minimal status and expires. `api-account-delete-status` has
JWT gateway verification disabled for this receipt path; requests without a
receipt still require a valid authenticated user. An HTTP 401 is never evidence
that erasure completed. Apply `20260909000003_deletion_receipts.sql` together
with the matching client and account endpoints.

### Sleep writes and offline experiments (September 2026 repair)

Apply `20260909000004_sleep_canonical.sql` and deploy the updated function map
before distributing the matching iOS client. `api-sleep-log` now points to the
POST/PATCH/DELETE writer under `api/sleep/log`; `api-sleep-daily` remains the GET
reader. Sleep writes retain one server UUID per user/day, preserve explicit
manual duration edits and deletion tombstones against delayed imports, and use
client timestamps to reject stale replay. Legacy subjective-only rows can be
enriched with HealthKit measurements without losing their diary context.

Experiment creation accepts the client's validated `baseline_start_date`, so an
offline start does not shift its phases when the outbox reaches the server later.
The updated client also fills this date into older pending create events.

All authenticated handlers use the shared JWT verifier. Only concurrently pending
verification for the same token is coalesced; completed responses are not cached.
Each request still applies its own endpoint rate limit. Auth transport/429/5xx
failures return retryable 503, while invalid or revoked credentials return 401.

First-launch Auth also requires **Allow anonymous sign-ins** on the hosted
project. The local config pins `auth.enable_anonymous_sign_ins = true`; Supabase
otherwise defaults it to false ([CLI config reference](https://supabase.com/docs/guides/local-development/cli/config#auth.enable_anonymous_sign_ins)).
This matches the app's anonymous-JWT bootstrap; an offline fallback screen alone
is not evidence that cloud authentication succeeded. The local live-UI smoke uses
explicit `TEST_RUNNER_` variables so XCTest runs it instead of silently skipping.

## Preflight verification

Before pushing migrations or archiving the app, validate the operator environment
so a misconfiguration fails loudly instead of silently degrading to offline-local
mode:

```bash
set -a; source .env; set +a            # or export the variables directly
bash scripts/check_production_config.sh            # required checks
bash scripts/check_production_config.sh --strict   # also require APNs/Pinecone/App Store
```

The script checks that hosted Supabase URL/keys are present and well-formed
(`https`, JWT or `sb_publishable_`/`sb_secret_` prefixes), that the service-role
key differs from the anon key, that OpenRouter/APNs metadata is shaped correctly,
and that the iOS `LIFEOS_SUPABASE_*` Release settings resolve. It never prints
secret values. A Release archive must additionally pass
`LIFEOS_REQUIRE_RESOLVED_RELEASE_CONFIG=1 bash scripts/check_ios_release_config.sh`
and, once built, `LIFEOS_BUILT_APP_PATH=/path/to/LifeOS.app bash scripts/check_ios_release_config.sh`.
