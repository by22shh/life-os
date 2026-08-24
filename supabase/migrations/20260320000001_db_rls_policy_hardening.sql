-- Production DB hardening:
-- - keep deletion audit rows service-only;
-- - add indexes for FK/RLS predicates that were missing a leading index;
-- - wrap auth helpers in policy expressions so Postgres can initPlan them;
-- - keep the deprecated account-deletion RPC lint-clean without changing its contract.

ALTER TABLE public.deletion_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deletion_audit_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS deletion_audit_log_no_client_access
    ON public.deletion_audit_log;

CREATE POLICY deletion_audit_log_no_client_access
    ON public.deletion_audit_log
    FOR ALL
    TO anon, authenticated
    USING (false)
    WITH CHECK (false);

REVOKE ALL ON TABLE public.deletion_audit_log FROM anon, authenticated;
GRANT ALL ON TABLE public.deletion_audit_log TO service_role;

CREATE INDEX IF NOT EXISTS idx_food_catalog_items_created_by_user
    ON public.food_catalog_items(created_by_user_id)
    WHERE created_by_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_supplements_catalog
    ON public.user_supplements(catalog_id)
    WHERE catalog_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_supplement_logs_user_supplement
    ON public.supplement_logs(user_supplement_id)
    WHERE user_supplement_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_body_composition_previous_measurement
    ON public.body_composition(previous_measurement_id)
    WHERE previous_measurement_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_exercise_catalog_created_by
    ON public.exercise_catalog(created_by)
    WHERE created_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_training_plan_sessions_actual_session
    ON public.training_plan_sessions(actual_session_id)
    WHERE actual_session_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_experiment_measurements_user_date
    ON public.experiment_measurements(user_id, measurement_date DESC);

CREATE INDEX IF NOT EXISTS idx_insights_suggested_experiment
    ON public.insights(suggested_experiment_id)
    WHERE suggested_experiment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_recommendations_insight
    ON public.recommendations(insight_id)
    WHERE insight_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_health_diagnoses_source_scan
    ON public.health_diagnoses(source_scan_id)
    WHERE source_scan_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ab_tests_flag
    ON public.ab_tests(flag_id)
    WHERE flag_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_user_feature_overrides_flag
    ON public.user_feature_overrides(flag_id);

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_auth_user
    ON public.account_deletion_jobs(auth_user_id)
    WHERE auth_user_id IS NOT NULL;

DO $$
DECLARE
    pol RECORD;
    next_qual TEXT;
    next_with_check TEXT;
    stmt TEXT;
BEGIN
    FOR pol IN
        SELECT schemaname, tablename, policyname, qual, with_check
        FROM pg_policies
        WHERE schemaname IN ('public', 'storage')
          AND (
              COALESCE(qual, '') LIKE '%auth.uid()%'
              OR COALESCE(with_check, '') LIKE '%auth.uid()%'
              OR COALESCE(qual, '') LIKE '%auth.role()%'
              OR COALESCE(with_check, '') LIKE '%auth.role()%'
          )
    LOOP
        next_qual := replace(replace(pol.qual, 'auth.uid()', '(SELECT auth.uid())'), 'auth.role()', '(SELECT auth.role())');
        next_with_check := replace(replace(pol.with_check, 'auth.uid()', '(SELECT auth.uid())'), 'auth.role()', '(SELECT auth.role())');

        stmt := format('ALTER POLICY %I ON %I.%I', pol.policyname, pol.schemaname, pol.tablename);

        IF next_qual IS NOT NULL THEN
            stmt := stmt || format(' USING (%s)', next_qual);
        END IF;

        IF next_with_check IS NOT NULL THEN
            stmt := stmt || format(' WITH CHECK (%s)', next_with_check);
        END IF;

        EXECUTE stmt;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.process_due_account_deletion_job(
    p_job_id UUID,
    p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    PERFORM p_job_id, p_now;

    RAISE EXCEPTION
        'process_due_account_deletion_job_deprecated: use api-account-delete-worker';
END;
$$;

REVOKE ALL ON FUNCTION public.process_due_account_deletion_job(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.process_due_account_deletion_job(UUID, TIMESTAMPTZ) TO service_role;
