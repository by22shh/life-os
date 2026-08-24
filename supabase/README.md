# Supabase Workspace

Local Supabase artifacts for Life OS spec parity.

## Migration Layout

This repo no longer uses the older split migration chain that appeared during the early audit phase.
The current source of truth is:

- `supabase/migrations/20260216000001_api_schema.sql` — canonical consolidated baseline schema. This file contains the initial schema plus the previously separate incremental migrations merged into one SQL file. See the in-file marker `CONSOLIDATED MIGRATIONS (002–019)`.
- `supabase/migrations/20260315000001_medical_scans_storage.sql` — follow-up storage bucket and RLS policies for private medical scan uploads.

Practical rule for contributors:

- Treat `20260216000001_api_schema.sql` as the baseline snapshot.
- Add new schema changes as new forward-only migration files.
- Do not recreate the older split migration filenames such as `20260216000002_ops_tables.sql`; those changes already live inside the consolidated baseline.

## Historical Audit Logs

Some archived audit logs in this folder were captured before the migration chain was consolidated. Because of that, files like:

- `supabase/tests_audit_db_gate_v2.log`
- `supabase/tests_audit_edge_e2e_v2.log`
- `supabase/tests_audit_edge_e2e_v3.log`

may still mention legacy migration names that are no longer present in `supabase/migrations/`. Those logs are historical artifacts, not the current migration inventory.

## Edge Functions

- `supabase/functions/send-notification/` — notification scheduler enforcing caps, quiet hours, and dedup.
- `supabase/functions/api/user/export/` — GDPR export job creation endpoint.
- `supabase/functions/api/user/export_status/` — export status polling endpoint.
- `supabase/functions/api/account/delete/` — erasure scheduling endpoint.
- `supabase/functions/api/account/delete_worker/` — scheduled erasure worker that performs storage cleanup, DB deletion, vector verification, and auth removal.
- `supabase/functions/api/config/feature-flags/` — authenticated runtime kill switches and rollout flags.
- `supabase/functions/api/watch/snapshot/` — iPhone watch snapshot endpoint.
- `supabase/functions/ai/openrouter-gateway/` — server-side OpenRouter proxy so API keys stay on the server.
- `supabase/functions/tests/edge_local_e2e.ts` — local edge end-to-end smoke scenarios.
- `supabase/functions/tests/edge_local_load.ts` — local load and soak profile for write-heavy endpoints.

## Useful Local Commands

- `bash scripts/run_supabase_edge_e2e.sh`
- `bash scripts/run_supabase_edge_load.sh`
- `bash scripts/run_supabase_edge_soak.sh`
- `bash scripts/run_preprod_security_pass.sh`

## Scheduled Deletion Worker

- The scheduled account-deletion cron now dispatches to `api-account-delete-worker` so Storage API cleanup runs before `public.users` is deleted.
- For hosted environments, store the Supabase project URL and service-role key in Vault as `project_url` and `service_role_key` before relying on the cron path:
  - `select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');`
  - `select vault.create_secret('<your-service-role-key>', 'service_role_key');`
- Local Supabase can use the same secret name pointing at the internal gateway URL if desired:
  - `select vault.create_secret('http://api.supabase.internal:8000', 'project_url');`
  - `select vault.create_secret('<your-local-service-role-key>', 'service_role_key');`

## Useful Load-Test Env Switches

- `EDGE_LOAD_SOAK_DURATION_SECONDS` — when `> 0`, runs duration-based soak instead of fixed request count.
- `EDGE_LOAD_SOAK_REQUEST_INTERVAL_MS` — inter-request delay per soak worker. Default `1500`.
- `EDGE_LOAD_CONCURRENCY`
- `EDGE_LOAD_FOOD_REQUESTS`
- `EDGE_LOAD_SETTINGS_REQUESTS`
- `EDGE_LOAD_MAX_ERROR_RATE`

## Server-Managed Force-Update Headers

- `MIN_SUPPORTED_APP_VERSION` — emitted as `X-Min-App-Version` on Edge Function responses.
- `SOFT_UPDATE_VERSION` — emitted as `X-Soft-Update-Version` on Edge Function responses.
- `APP_STORE_URL` — emitted as `X-App-Store-URL` when it is a valid absolute `http(s)` URL and not an App Store search page.
- `APP_STORE_ID` — numeric App Store identifier used to build `X-App-Store-URL` when no direct product URL is configured or the configured URL degrades to App Store search.
- Optional aliases: `X_MIN_APP_VERSION`, `X_SOFT_UPDATE_VERSION`, `FORCE_UPDATE_APP_STORE_URL`, `FORCE_UPDATE_APP_STORE_ID`.
