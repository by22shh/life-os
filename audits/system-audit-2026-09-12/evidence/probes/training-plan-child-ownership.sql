\set ON_ERROR_STOP on
-- LOCAL database only; fixture creation/poisoning is fully rolled back.
BEGIN;
CREATE TEMP TABLE audit_plan_fixture AS SELECT gen_random_uuid() AS auth_a,
  gen_random_uuid() AS auth_b, gen_random_uuid() AS plan_b;
INSERT INTO auth.users (id,email,aud,role)
SELECT auth_a, auth_a::TEXT || '@audit.invalid','authenticated','authenticated' FROM audit_plan_fixture
UNION ALL SELECT auth_b, auth_b::TEXT || '@audit.invalid','authenticated','authenticated' FROM audit_plan_fixture;
ALTER TABLE audit_plan_fixture ADD COLUMN user_a UUID;
ALTER TABLE audit_plan_fixture ADD COLUMN user_b UUID;
UPDATE audit_plan_fixture SET
user_a = (SELECT id FROM public.users WHERE auth_id = auth_a),
user_b = (SELECT id FROM public.users WHERE auth_id = auth_b);
INSERT INTO public.training_plans (id,user_id,name,goal,status,plan_json)
SELECT plan_b,user_b,'Victim private plan','strength','active','{}'::JSONB FROM audit_plan_fixture;
GRANT SELECT ON audit_plan_fixture TO authenticated,service_role;
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',auth_a,'role','authenticated')::TEXT,TRUE)
FROM audit_plan_fixture;
SELECT set_config('request.jwt.claim.sub','',TRUE);
SET LOCAL ROLE authenticated;
INSERT INTO public.training_plan_sessions
  (training_plan_id,user_id,planned_date,session_type,planned_exercises,status)
SELECT plan_b,user_a,CURRENT_DATE,'strength','{"title":"Injected workout instruction"}'::JSONB,'planned'
FROM audit_plan_fixture;
RESET ROLE;
SET LOCAL ROLE service_role;
-- Same filtering used by api-training-plan/{active,sessions}: plan id only.
SELECT s.planned_exercises, s.user_id <> p.user_id AS foreign_user_row_returned
FROM public.training_plan_sessions s JOIN public.training_plans p ON p.id = s.training_plan_id
WHERE s.training_plan_id = (SELECT plan_b FROM audit_plan_fixture);
RESET ROLE;
ROLLBACK;
\echo AUDIT_PLAN_CHILD_OWNERSHIP_PROBE_ROLLED_BACK
