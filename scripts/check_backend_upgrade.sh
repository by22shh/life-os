#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
PROJECT_ID="$(sed -n 's/^project_id = "\([^"]*\)"/\1/p' supabase/config.toml | head -n 1)"
DB_CONTAINER="${SUPABASE_DB_CONTAINER:-supabase_db_${PROJECT_ID}}"
SQL_FILE="$(mktemp "${TMPDIR:-/tmp}/lifeos_upgrade.XXXXXX")"
trap 'rm -f "$SQL_FILE"' EXIT
cat > "$SQL_FILE" <<'SQL'
\set ON_ERROR_STOP on
BEGIN;
-- Recreate the legacy token column inside a rollback-only local transaction.
ALTER TABLE public.export_artifacts ALTER COLUMN download_token TYPE UUID USING gen_random_uuid();
CREATE TEMP TABLE upgrade_fixture AS SELECT gen_random_uuid() AS auth_id, gen_random_uuid() AS job_id;
INSERT INTO auth.users(id,email,aud,role)
SELECT auth_id,auth_id::TEXT || '@upgrade.invalid','authenticated','authenticated' FROM upgrade_fixture;
INSERT INTO public.export_jobs(id,user_id,status,requested_at)
SELECT f.job_id,u.id,'pending',NOW() FROM upgrade_fixture f JOIN public.users u ON u.auth_id=f.auth_id;
INSERT INTO public.export_artifacts(job_id,user_id,download_token,payload_json,file_name,expires_at)
SELECT f.job_id,u.id,gen_random_uuid(),'{}'::JSONB,'upgrade.json',NOW()+INTERVAL '1 day'
FROM upgrade_fixture f JOIN public.users u ON u.auth_id=f.auth_id;
SQL
cat supabase/migrations/20260909000001_integrity_transactions.sql >> "$SQL_FILE"
cat >> "$SQL_FILE" <<'SQL'
DO $$ BEGIN
  IF (SELECT data_type FROM information_schema.columns WHERE table_schema='public'
      AND table_name='export_artifacts' AND column_name='download_token') <> 'text'
    OR NOT EXISTS(SELECT 1 FROM public.export_artifacts e JOIN upgrade_fixture f ON f.job_id=e.job_id
      WHERE e.download_token LIKE 'invalidated-legacy-plaintext-%') THEN
    RAISE EXCEPTION 'legacy UUID token upgrade failed';
  END IF;
END $$;
UPDATE public.export_artifacts SET download_token=repeat('a',64)
WHERE job_id IN(SELECT job_id FROM upgrade_fixture);
SQL
cat supabase/migrations/20260909000001_integrity_transactions.sql >> "$SQL_FILE"
cat >> "$SQL_FILE" <<'SQL'
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.export_artifacts e JOIN upgrade_fixture f ON f.job_id=e.job_id
      WHERE e.download_token=repeat('a',64) AND e.file_name='upgrade.json') THEN
    RAISE EXCEPTION 'upgrade replay changed a valid digest or existing data';
  END IF;
END $$;
ROLLBACK;
SQL
docker exec -i "$DB_CONTAINER" psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 < "$SQL_FILE"
echo 'Legacy UUID upgrade and digest-preserving replay passed.'
