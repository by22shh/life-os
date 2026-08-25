-- Catalog table isolation and operations-table hardening.
--
-- food_catalog_items and exercise_catalog mix global reference rows with
-- user-created rows (created_by_user_id / created_by). They were missed by the
-- blanket "user_id" RLS loop because their ownership columns use different
-- names, which let any authenticated client read other users' custom entries.
-- supplement_catalog and health_marker_catalog are pure shared reference data.
--
-- Edge Functions access every catalog through the service-role client, so RLS
-- here only constrains the direct PostgREST sync pulls performed by the iOS
-- app with a user JWT.

-- ============================================================
-- 1. Shared reference catalogs: read-only for authenticated
-- ============================================================

ALTER TABLE public.supplement_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.health_marker_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalog_reference_select ON public.supplement_catalog;
CREATE POLICY catalog_reference_select
    ON public.supplement_catalog
    FOR SELECT
    TO authenticated
    USING (true);

DROP POLICY IF EXISTS catalog_reference_select ON public.health_marker_catalog;
CREATE POLICY catalog_reference_select
    ON public.health_marker_catalog
    FOR SELECT
    TO authenticated
    USING (true);

-- ============================================================
-- 2. Mixed catalogs: global rows plus own custom rows only
-- ============================================================

ALTER TABLE public.food_catalog_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalog_select_global_or_own ON public.food_catalog_items;
CREATE POLICY catalog_select_global_or_own
    ON public.food_catalog_items
    FOR SELECT
    TO authenticated
    USING (
        created_by_user_id IS NULL
        OR created_by_user_id IN (
            SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
        )
    );

ALTER TABLE public.exercise_catalog ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS catalog_select_global_or_own ON public.exercise_catalog;
CREATE POLICY catalog_select_global_or_own
    ON public.exercise_catalog
    FOR SELECT
    TO authenticated
    USING (
        is_custom IS NOT TRUE
        OR created_by IN (
            SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
        )
    );

-- Read-only for clients: writes go exclusively through Edge Functions using
-- the service-role client.
REVOKE INSERT, UPDATE, DELETE ON TABLE
    public.food_catalog_items,
    public.supplement_catalog,
    public.exercise_catalog,
    public.health_marker_catalog
FROM anon, authenticated;

GRANT SELECT ON TABLE
    public.food_catalog_items,
    public.supplement_catalog,
    public.exercise_catalog,
    public.health_marker_catalog
TO authenticated;

-- ============================================================
-- 3. Service-only operational tables: deny client access entirely
-- ============================================================
-- No permissive policies are created on purpose. service_role bypasses RLS;
-- SECURITY DEFINER RPCs owned by postgres keep working because FORCE RLS is
-- intentionally NOT enabled here.

ALTER TABLE public.rate_limit_windows ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ops_alert_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.rate_limit_windows FROM anon, authenticated;
REVOKE ALL ON TABLE public.ops_alert_events FROM anon, authenticated;

-- ============================================================
-- 4. Medical scan retention cron: reschedule with visible failures
-- ============================================================
-- Replaces the silent EXCEPTION WHEN OTHERS THEN NULL scheduler block so that
-- scheduling problems reach the Postgres log instead of disappearing.

DO $$
DECLARE
    v_jobid BIGINT;
    v_project_url TEXT;
    v_service_role_key TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron')
       AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid
          INTO v_jobid
          FROM cron.job
         WHERE jobname = 'process_due_medical_scan_retention_jobs'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        v_project_url := public.medical_scan_retention_worker_project_url();
        v_service_role_key := public.medical_scan_retention_worker_service_role_key();
        IF COALESCE(v_project_url, '') <> '' AND COALESCE(v_service_role_key, '') <> '' THEN
            PERFORM cron.schedule(
                'process_due_medical_scan_retention_jobs',
                '15 * * * *',
                $cron$SELECT * FROM public.process_due_medical_scan_retention_jobs(100);$cron$
            );
        ELSE
            RAISE WARNING
                'Skipped scheduling medical scan retention worker cron: missing vault secret "project_url" or "service_role_key".';
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to schedule medical scan retention worker cron: % (%)', SQLERRM, SQLSTATE;
END;
$$;
