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
  OPENROUTER_API_KEY="sk-or-..." \
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
