\set ON_ERROR_STOP on
-- Run against a migrated LOCAL database: psql -f scripts/check_backend_integrity.sql.
-- Every fixture and tested change is rolled back.
BEGIN;
CREATE TEMP TABLE integrity_fixture AS SELECT gen_random_uuid() AS auth_a, gen_random_uuid() AS auth_b;
INSERT INTO auth.users (id, email, aud, role)
SELECT auth_a, auth_a::TEXT || '@integrity.invalid', 'authenticated', 'authenticated' FROM integrity_fixture
UNION ALL SELECT auth_b, auth_b::TEXT || '@integrity.invalid', 'authenticated', 'authenticated' FROM integrity_fixture;
ALTER TABLE integrity_fixture ADD COLUMN user_a UUID;
ALTER TABLE integrity_fixture ADD COLUMN user_b UUID;
UPDATE integrity_fixture SET
  user_a = (SELECT id FROM public.users WHERE auth_id = auth_a),
  user_b = (SELECT id FROM public.users WHERE auth_id = auth_b);
GRANT SELECT ON integrity_fixture TO service_role, authenticated;

SET LOCAL ROLE service_role;
DO $$
DECLARE
  a UUID; b UUID; meal UUID := gen_random_uuid(); item UUID := gen_random_uuid();
  session UUID := gen_random_uuid(); exercise UUID := gen_random_uuid();
  supplement UUID := gen_random_uuid(); menstrual UUID := gen_random_uuid();
  export_job UUID := gen_random_uuid(); v_failed BOOLEAN; v_saved BOOLEAN;
BEGIN
  SELECT user_a, user_b INTO a,b FROM integrity_fixture;
  IF a IS NULL OR b IS NULL THEN RAISE EXCEPTION 'auth bootstrap failed'; END IF;
  INSERT INTO public.user_supplements (id,user_id,custom_name,frequency)
    VALUES (supplement,b,'private supplement','daily');
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.user_supplements (id,user_id,custom_name,frequency)
      VALUES (supplement,a,'replacement','daily')
      ON CONFLICT (id) DO UPDATE SET user_id = EXCLUDED.user_id, custom_name = EXCLUDED.custom_name;
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  IF NOT v_failed OR NOT EXISTS (SELECT 1 FROM public.user_supplements WHERE id = supplement AND user_id = b AND custom_name = 'private supplement') THEN
    RAISE EXCEPTION 'owner reassignment was not rejected atomically';
  END IF;

  INSERT INTO public.food_logs (id,user_id,logged_at,logged_date,input_method,calories,protein_g,fat_g,carbs_g)
    VALUES (meal,a,NOW(),CURRENT_DATE,'manual',300,10,10,30);
  INSERT INTO public.food_items (id,food_log_id,user_id,name,weight_g,calories,protein_g,fat_g,carbs_g)
    VALUES (item,meal,a,'original',100,300,10,10,30);
  v_failed := FALSE;
  BEGIN
    PERFORM public.patch_food_log_atomic(a,meal,'{"calories":500}'::JSONB,
      jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name','invalid','weight_g',100,'calories',500,
        'protein_g',10,'fat_g',10,'carbs_g',30,'user_food_id',gen_random_uuid())));
  EXCEPTION WHEN foreign_key_violation THEN v_failed := TRUE;
  END;
  IF NOT v_failed OR NOT EXISTS (SELECT 1 FROM public.food_logs WHERE id = meal AND calories = 300)
      OR NOT EXISTS (SELECT 1 FROM public.food_items WHERE id = item AND name = 'original') THEN
    RAISE EXCEPTION 'food failure did not roll back parent and children';
  END IF;
  IF public.patch_food_log_atomic(b,meal,'{"calories":999}'::JSONB,NULL) THEN
    RAISE EXCEPTION 'food RPC allowed wrong owner';
  END IF;
  -- Keep mutation and observation in separate statements: SQL expressions do
  -- not evaluate OR operands left-to-right, and scalar subqueries can become
  -- InitPlans evaluated before the volatile RPC in the same IF expression.
  v_saved := public.patch_food_log_atomic(a,meal,'{"calories":450}'::JSONB,
      jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'name','valid','weight_g',150,'calories',450,
        'protein_g',10,'fat_g',10,'carbs_g',30)));
  IF v_saved IS DISTINCT FROM TRUE
      OR (SELECT calories FROM public.food_logs WHERE id = meal) IS DISTINCT FROM 450::NUMERIC
      OR EXISTS (SELECT 1 FROM public.food_items WHERE id = item)
      OR (SELECT COUNT(*) FROM public.food_items WHERE food_log_id = meal AND user_id = a AND name = 'valid' AND calories = 450) <> 1 THEN
    RAISE EXCEPTION 'food atomic replacement did not persist';
  END IF;

  INSERT INTO public.workout_sessions (id,user_id,started_at,session_date,source,total_sets)
    VALUES (session,a,NOW(),CURRENT_DATE,'manual',1);
  INSERT INTO public.workout_exercises (id,session_id,notes) VALUES (exercise,session,'original');
  INSERT INTO public.workout_sets (exercise_entry_id,user_id,set_number,reps) VALUES (exercise,a,1,10);
  v_failed := FALSE;
  BEGIN
    PERFORM public.patch_workout_atomic(a,session,'{"total_sets":2}'::JSONB,
      jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'sets',jsonb_build_array(
        jsonb_build_object('id',gen_random_uuid(),'set_number',1,'rpe',5),
        jsonb_build_object('id',gen_random_uuid(),'set_number',2,'rpe',99)))));
  EXCEPTION WHEN check_violation THEN v_failed := TRUE;
  END;
  IF NOT v_failed OR NOT EXISTS (SELECT 1 FROM public.workout_sessions WHERE id = session AND total_sets = 1)
    OR NOT EXISTS (SELECT 1 FROM public.workout_exercises WHERE id = exercise AND notes = 'original')
    OR (SELECT COUNT(*) FROM public.workout_sets WHERE exercise_entry_id = exercise) <> 1 THEN
    RAISE EXCEPTION 'workout failure did not roll back parent, exercises and sets';
  END IF;
  IF public.patch_workout_atomic(b,session,'{"notes":"foreign"}'::JSONB,NULL) THEN
    RAISE EXCEPTION 'workout RPC allowed wrong owner';
  END IF;
  PERFORM public.patch_workout_atomic(a,session,'{"notes":"saved"}'::JSONB,'[]'::JSONB);
  IF EXISTS (SELECT 1 FROM public.workout_exercises WHERE session_id = session)
    OR (SELECT notes FROM public.workout_sessions WHERE id = session) <> 'saved' THEN
    RAISE EXCEPTION 'workout valid replacement failed';
  END IF;

  INSERT INTO public.privacy_settings (user_id,menstrual_local_only) VALUES (a,TRUE)
    ON CONFLICT (user_id) DO UPDATE SET menstrual_local_only = TRUE;
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.menstrual_logs (id,user_id,date,flow) VALUES (menstrual,a,CURRENT_DATE,'light');
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'menstrual write without consent succeeded'; END IF;
  UPDATE public.privacy_settings SET menstrual_local_only = FALSE WHERE user_id = a;
  INSERT INTO public.menstrual_logs (id,user_id,date,flow) VALUES (menstrual,a,CURRENT_DATE,'light');
  UPDATE public.privacy_settings SET menstrual_local_only = TRUE WHERE user_id = a;
  IF EXISTS (SELECT 1 FROM public.menstrual_logs WHERE user_id = a) THEN RAISE EXCEPTION 'consent revocation retained cloud rows'; END IF;
  v_failed := FALSE;
  BEGIN
    INSERT INTO public.menstrual_logs (id,user_id,date,flow) VALUES (menstrual,a,CURRENT_DATE,'light')
      ON CONFLICT (id) DO UPDATE SET flow = EXCLUDED.flow;
  EXCEPTION WHEN insufficient_privilege THEN v_failed := TRUE;
  END;
  IF NOT v_failed THEN RAISE EXCEPTION 'outbox replay after consent revocation succeeded'; END IF;

  INSERT INTO public.export_jobs (id,user_id,status,requested_at) VALUES (export_job,a,'pending',NOW());
  INSERT INTO public.export_artifacts (job_id,user_id,download_token,payload_json,file_name,expires_at)
    VALUES (export_job,a,repeat('a',64),'{}','export.json',NOW()+INTERVAL '1 hour');
  IF (SELECT download_token FROM public.export_artifacts WHERE job_id = export_job) <> repeat('a',64) THEN
    RAISE EXCEPTION 'SHA-256 export token storage failed';
  END IF;
END;
$$;
RESET ROLE;

INSERT INTO public.feature_flags (flag_key,enabled) VALUES ('integrity_caller_probe',FALSE);
INSERT INTO public.user_feature_overrides (user_id,flag_id,enabled)
SELECT user_b, (SELECT id FROM public.feature_flags WHERE flag_key = 'integrity_caller_probe'), TRUE FROM integrity_fixture;
SELECT set_config('request.jwt.claims', jsonb_build_object('sub',auth_a,'role','authenticated')::TEXT, TRUE) FROM integrity_fixture;
SELECT set_config('request.jwt.claim.sub', '', TRUE);
SET LOCAL ROLE authenticated;
DO $$
BEGIN
  IF (SELECT enabled FROM public.resolve_feature_flags_for_user((SELECT user_b FROM integrity_fixture))
      WHERE flag_key = 'integrity_caller_probe') IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'JSON JWT caller read foreign override';
  END IF;
  IF has_function_privilege('authenticated','public.patch_food_log_atomic(uuid,uuid,jsonb,jsonb)','EXECUTE')
    OR has_function_privilege('authenticated','public.patch_workout_atomic(uuid,uuid,jsonb,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'transaction RPC exposed outside service_role';
  END IF;
END;
$$;
RESET ROLE;
SET LOCAL ROLE service_role;
DO $$
DECLARE a UUID; b UUID; operation UUID := gen_random_uuid();
  job UUID := gen_random_uuid(); audit UUID; rejected BOOLEAN := FALSE;
BEGIN
  SELECT user_a,user_b INTO a,b FROM integrity_fixture;
  UPDATE public.privacy_settings SET vector_opt_in = TRUE, ai_processing_consent = TRUE WHERE user_id = a;
  IF NOT public.claim_vector_operation(a,operation,TRUE) THEN RAISE EXCEPTION 'vector lease was not acquired'; END IF;
  BEGIN
    PERFORM public.claim_vector_operation(a,gen_random_uuid(),FALSE);
  EXCEPTION WHEN lock_not_available THEN rejected := TRUE;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'concurrent vector operation was accepted'; END IF;
  IF NOT (SELECT vector_cleanup_required FROM public.privacy_settings WHERE user_id = a) THEN
    RAISE EXCEPTION 'vector write did not persist cleanup obligation';
  END IF;
  UPDATE public.privacy_settings SET vector_operation_id = NULL, vector_lease_expires_at = NULL, vector_opt_in = FALSE WHERE user_id = a;
  IF public.claim_vector_operation(a,gen_random_uuid(),TRUE) THEN RAISE EXCEPTION 'vector upload allowed after opt-out'; END IF;

  INSERT INTO public.account_deletion_jobs(id,user_id,idempotency_key,mode,state)
    VALUES(job,b,job::TEXT,'immediate','requested') RETURNING audit_log_id INTO audit;
  IF audit IS NULL THEN RAISE EXCEPTION 'receipt audit binding missing'; END IF;
  INSERT INTO public.account_deletion_receipts(token_hash,job_id,audit_log_id,state,expires_at)
    VALUES(repeat('c',64),job,audit,'requested',NOW()+INTERVAL '1 day');
  UPDATE public.account_deletion_jobs SET state = 'data_deleting' WHERE id = job;
  IF (SELECT state FROM public.account_deletion_receipts WHERE token_hash=repeat('c',64)) <> 'data_deleting' THEN
    RAISE EXCEPTION 'receipt did not track pending state';
  END IF;
  PERFORM public.delete_user_account(b);
  INSERT INTO public.deletion_audit_log(id,user_id_deleted,deleted_at,vectors_deleted,postgres_deleted,storage_deleted,compliance_verified)
    VALUES(audit,b,NOW(),TRUE,TRUE,TRUE,TRUE);
  IF (SELECT state FROM public.account_deletion_receipts WHERE token_hash=repeat('c',64)) <> 'completed' THEN
    RAISE EXCEPTION 'receipt did not survive account cascade/track completion';
  END IF;
END;
$$;
RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$
DECLARE rejected BOOLEAN := FALSE;
BEGIN
  IF has_table_privilege('authenticated','public.account_deletion_receipts','SELECT')
    OR has_table_privilege('authenticated','public.vector_memory','INSERT')
    OR has_table_privilege('authenticated','public.vector_memory','UPDATE')
    OR has_table_privilege('authenticated','public.privacy_settings','DELETE') THEN
    RAISE EXCEPTION 'private lifecycle metadata is client writable/readable';
  END IF;
  BEGIN
    UPDATE public.privacy_settings SET vector_cleanup_required = FALSE WHERE user_id = (SELECT user_a FROM integrity_fixture);
  EXCEPTION WHEN insufficient_privilege THEN rejected := TRUE;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'client cleared server vector cleanup obligation'; END IF;
END;
$$;
RESET ROLE;
ROLLBACK;
\echo 'Backend integrity SQL regression check passed (fixtures rolled back).'
\echo 'check_backend_integrity: all assertions passed and transaction rolled back'
