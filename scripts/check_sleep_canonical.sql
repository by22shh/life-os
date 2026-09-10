\set ON_ERROR_STOP on
-- LOCAL regression transaction: day identity, manual precedence, replay and owner isolation.
BEGIN;
CREATE TEMP TABLE sleep_fixture AS SELECT gen_random_uuid() AS auth_a, gen_random_uuid() AS auth_b;
INSERT INTO auth.users (id,email,aud,role)
SELECT auth_a,auth_a::text || '@sleep.invalid','authenticated','authenticated' FROM sleep_fixture
UNION ALL SELECT auth_b,auth_b::text || '@sleep.invalid','authenticated','authenticated' FROM sleep_fixture;
DO $$
DECLARE
  a uuid; b uuid; first_id uuid := gen_random_uuid(); manual_id uuid := gen_random_uuid();
  result jsonb; denied boolean := false;
BEGIN
  SELECT u.id INTO a FROM public.users u JOIN sleep_fixture f ON u.auth_id=f.auth_a;
  SELECT u.id INTO b FROM public.users u JOIN sleep_fixture f ON u.auth_id=f.auth_b;
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',first_id,'sleep_date','2026-03-08','source','healthkit','total_duration_minutes',360,'deep_sleep_minutes',60,'client_updated_at','2026-03-08T08:00:00Z'));
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',manual_id,'sleep_date','2026-03-08','source','manual','total_duration_minutes',480,'deep_sleep_minutes',NULL,'client_updated_at','2026-03-08T09:00:00Z'));
  IF result->>'id' <> first_id::text OR (result->>'total_duration_minutes')::int <> 480 OR result->>'deep_sleep_minutes' IS NOT NULL THEN
    RAISE EXCEPTION 'manual edit failed canonical identity or stage clearing';
  END IF;
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',gen_random_uuid(),'sleep_date','2026-03-08','source','healthkit','total_duration_minutes',300,'client_updated_at','2026-03-08T10:00:00Z'));
  IF result->>'source' <> 'manual' OR (result->>'total_duration_minutes')::int <> 480 OR (SELECT count(*) FROM public.sleep_logs WHERE user_id=a AND sleep_date='2026-03-08') <> 1 THEN
    RAISE EXCEPTION 'delayed import overwrote manual or duplicated day';
  END IF;
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',manual_id,'sleep_date','2026-03-08','source','manual','total_duration_minutes',100,'client_updated_at','2026-03-08T07:00:00Z'));
  IF (result->>'total_duration_minutes')::int <> 480 THEN RAISE EXCEPTION 'stale replay won'; END IF;
  BEGIN
    PERFORM public.upsert_canonical_sleep(b,jsonb_build_object('id',first_id,'sleep_date','2026-03-08','source','manual','client_updated_at','2026-03-08T11:00:00Z'));
  EXCEPTION WHEN insufficient_privilege THEN denied := true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'foreign owner accepted'; END IF;
  denied := false;
  BEGIN
    PERFORM public.upsert_canonical_sleep(a,jsonb_build_object('id',first_id,'sleep_date','2026-03-09','source','manual','client_updated_at','2026-03-09T11:00:00Z'));
  EXCEPTION WHEN invalid_parameter_value THEN denied := true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'existing identity moved days'; END IF;
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',first_id,'sleep_date','2026-03-08','source','manual','deleted_at','2026-03-08T12:00:00Z','client_updated_at','2026-03-08T12:00:00Z'));
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',gen_random_uuid(),'sleep_date','2026-03-08','source','healthkit','total_duration_minutes',600,'client_updated_at','2026-03-09T12:00:00Z'));
  IF result->>'deleted_at' IS NULL THEN RAISE EXCEPTION 'import resurrected manual deletion'; END IF;
  -- Existing subjective-only entries can gain objective data without losing their diary context.
  INSERT INTO public.sleep_logs (user_id,sleep_date,source,notes,perceived_quality,bedtime_actual)
    VALUES (a,'2026-03-10','manual','legacy diary',4,'23:00:00');
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',gen_random_uuid(),'sleep_date','2026-03-10','source','healthkit','total_duration_minutes',480,'client_updated_at','2026-03-10T08:00:00Z'));
  IF (result->>'total_duration_minutes')::int <> 480 OR result->>'notes' <> 'legacy diary' OR (result->>'perceived_quality')::int <> 4 OR result->>'source' <> 'healthkit' THEN RAISE EXCEPTION 'legacy subjective row blocked enrichment or lost context'; END IF;
  INSERT INTO public.sleep_logs (user_id,sleep_date,source,deleted_at)
    VALUES (a,'2026-03-11','manual','2026-03-11T08:00:00Z');
  result := public.upsert_canonical_sleep(a,jsonb_build_object('id',gen_random_uuid(),'sleep_date','2026-03-11','source','healthkit','total_duration_minutes',480,'client_updated_at','2026-03-11T09:00:00Z'));
  IF result->>'deleted_at' IS NULL OR result->>'total_duration_minutes' IS NOT NULL THEN RAISE EXCEPTION 'NULL-duration tombstone was enriched or resurrected'; END IF;
  IF has_function_privilege('authenticated','public.upsert_canonical_sleep(uuid,jsonb)','EXECUTE') OR has_function_privilege('anon','public.upsert_canonical_sleep(uuid,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'unscoped client RPC exposed'; END IF;
END;
$$;
ROLLBACK;
\echo 'check_sleep_canonical: all assertions passed and transaction rolled back'
