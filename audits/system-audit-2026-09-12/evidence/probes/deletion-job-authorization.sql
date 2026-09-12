\set ON_ERROR_STOP on
-- LOCAL database only. No worker/RPC/Auth deletion is invoked.
-- All fixture rows and client writes below roll back.
BEGIN;
CREATE TEMP TABLE audit_deletion_fixture AS
SELECT gen_random_uuid() AS auth_a, gen_random_uuid() AS auth_b,
       gen_random_uuid() AS job_id;
INSERT INTO auth.users (id, email, aud, role)
SELECT auth_a, auth_a::TEXT || '@audit.invalid', 'authenticated', 'authenticated'
FROM audit_deletion_fixture
UNION ALL
SELECT auth_b, auth_b::TEXT || '@audit.invalid', 'authenticated', 'authenticated'
FROM audit_deletion_fixture;
ALTER TABLE audit_deletion_fixture ADD COLUMN user_a UUID;
ALTER TABLE audit_deletion_fixture ADD COLUMN user_b UUID;
UPDATE audit_deletion_fixture SET
user_a = (SELECT id FROM public.users WHERE auth_id = auth_a),
user_b = (SELECT id FROM public.users WHERE auth_id = auth_b);
GRANT SELECT ON audit_deletion_fixture TO authenticated;
SELECT policyname, cmd, roles, qual, with_check
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'account_deletion_jobs'
ORDER BY policyname;
SELECT has_table_privilege('authenticated', 'public.account_deletion_jobs', 'INSERT') AS client_insert,
       has_table_privilege('authenticated', 'public.account_deletion_jobs', 'UPDATE') AS client_update;
SELECT set_config('request.jwt.claims', jsonb_build_object('sub', auth_a, 'role', 'authenticated')::TEXT, TRUE)
FROM audit_deletion_fixture;
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SET LOCAL ROLE authenticated;
DO $$
DECLARE f RECORD; n INTEGER;
BEGIN
  SELECT * INTO f FROM audit_deletion_fixture;
  IF f.user_a IS NULL OR f.user_b IS NULL THEN RAISE EXCEPTION 'fixture bootstrap failed'; END IF;
  INSERT INTO public.account_deletion_jobs
    (id,user_id,auth_user_id,idempotency_key,mode,state,scheduled_for,storage_cleanup_completed)
  VALUES
    (f.job_id,f.user_a,f.auth_b,'audit-' || f.job_id,'scheduled','scheduled',NOW(),FALSE);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'unexpected fixture insert count'; END IF;
  RAISE NOTICE 'CONFIRMED: authenticated caller inserted deletion job targeting another Auth identity';
  UPDATE public.account_deletion_jobs
    SET storage_cleanup_completed = TRUE, state = 'retry_scheduled', next_retry_at = NOW()
    WHERE id = f.job_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'client update denied; insert finding remains independently relevant'; END IF;
  RAISE NOTICE 'CONFIRMED: permissive policy also allows client mutation of worker state/cleanup proof';
END;
$$;
RESET ROLE;
SELECT j.user_id = f.user_a AS owned_job,
       j.auth_user_id = f.auth_b AS targets_other_auth,
       j.auth_user_id <> u.auth_id AS worker_identity_mismatch,
       j.storage_cleanup_completed
FROM public.account_deletion_jobs j
JOIN audit_deletion_fixture f ON j.id = f.job_id
JOIN public.users u ON u.id = j.user_id;
ROLLBACK;
\echo AUDIT_DELETION_JOB_AUTHORIZATION_PROBE_ROLLED_BACK
