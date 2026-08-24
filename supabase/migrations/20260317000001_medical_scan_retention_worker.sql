DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM pg_available_extensions
         WHERE name = 'vault'
    ) THEN
        CREATE EXTENSION IF NOT EXISTS vault;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.medical_scan_retention_worker_project_url()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_project_url TEXT;
BEGIN
    BEGIN
        IF EXISTS (
            SELECT 1
              FROM information_schema.schemata
             WHERE schema_name = 'vault'
        ) THEN
            SELECT decrypted_secret
              INTO v_project_url
              FROM vault.decrypted_secrets
             WHERE name = 'project_url'
             LIMIT 1;
        END IF;
    EXCEPTION
        WHEN undefined_table THEN
            v_project_url := NULL;
    END;

    RETURN NULLIF(BTRIM(COALESCE(v_project_url, '')), '');
END;
$$;

CREATE OR REPLACE FUNCTION public.medical_scan_retention_worker_service_role_key()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_service_role_key TEXT;
BEGIN
    BEGIN
        IF EXISTS (
            SELECT 1
              FROM information_schema.schemata
             WHERE schema_name = 'vault'
        ) THEN
            SELECT decrypted_secret
              INTO v_service_role_key
              FROM vault.decrypted_secrets
             WHERE name = 'service_role_key'
             LIMIT 1;
        END IF;
    EXCEPTION
        WHEN undefined_table THEN
            v_service_role_key := NULL;
    END;

    RETURN NULLIF(BTRIM(COALESCE(v_service_role_key, '')), '');
END;
$$;

CREATE OR REPLACE FUNCTION public.process_due_medical_scan_retention_jobs(
    p_batch_size INTEGER DEFAULT 100,
    p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_project_url TEXT;
    v_service_role_key TEXT;
    v_request_id BIGINT;
    v_batch_size INTEGER := LEAST(100, GREATEST(1, COALESCE(p_batch_size, 100)));
BEGIN
    v_project_url := public.medical_scan_retention_worker_project_url();
    v_service_role_key := public.medical_scan_retention_worker_service_role_key();

    IF COALESCE(v_project_url, '') = '' THEN
        status := 'error';
        detail := 'medical_scan_retention_worker_project_url_missing';
        RETURN NEXT;
        RETURN;
    END IF;

    IF COALESCE(v_service_role_key, '') = '' THEN
        status := 'error';
        detail := 'medical_scan_retention_worker_service_role_key_missing';
        RETURN NEXT;
        RETURN;
    END IF;

    v_request_id := net.http_post(
        url := v_project_url || '/functions/v1/api-labs-retention-worker',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key,
            'apikey', v_service_role_key,
            'X-Labs-Retention-Worker', 'scheduled'
        ),
        body := jsonb_build_object(
            'batch_size', v_batch_size,
            'requested_at', COALESCE(p_now, NOW())
        )
    );

    status := 'dispatched';
    detail := v_request_id::TEXT;
    RETURN NEXT;
END;
$$;

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
            RAISE NOTICE
                'Skipped scheduling medical scan retention worker cron: missing vault secret "project_url" or "service_role_key".';
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.medical_scan_retention_worker_project_url() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.medical_scan_retention_worker_service_role_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.medical_scan_retention_worker_project_url() TO service_role;
GRANT EXECUTE ON FUNCTION public.medical_scan_retention_worker_service_role_key() TO service_role;
GRANT EXECUTE ON FUNCTION public.process_due_medical_scan_retention_jobs(INTEGER, TIMESTAMPTZ) TO service_role;
