ALTER TABLE public.deletion_audit_log
    ADD COLUMN IF NOT EXISTS storage_deleted BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.deletion_failures
    DROP CONSTRAINT IF EXISTS deletion_failures_failure_type_check,
    ADD CONSTRAINT deletion_failures_failure_type_check
        CHECK (failure_type IN ('pinecone', 'postgres', 'auth', 'storage'));

ALTER TABLE public.account_deletion_jobs
    ADD COLUMN IF NOT EXISTS auth_user_id UUID,
    ADD COLUMN IF NOT EXISTS storage_object_paths JSONB NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS storage_cleanup_completed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS storage_cleanup_completed_at TIMESTAMPTZ;

UPDATE public.account_deletion_jobs AS adj
SET auth_user_id = u.auth_id
FROM public.users AS u
WHERE adj.user_id = u.id
  AND adj.auth_user_id IS NULL;

UPDATE public.account_deletion_jobs
SET storage_object_paths = '[]'::jsonb
WHERE storage_object_paths IS NULL
   OR jsonb_typeof(storage_object_paths) <> 'array';

ALTER TABLE public.account_deletion_jobs
    DROP CONSTRAINT IF EXISTS account_deletion_jobs_last_failure_type_check,
    ADD CONSTRAINT account_deletion_jobs_last_failure_type_check
        CHECK (
            last_failure_type IS NULL OR
            last_failure_type IN ('auth', 'postgres', 'pinecone', 'storage')
        ),
    DROP CONSTRAINT IF EXISTS account_deletion_jobs_storage_object_paths_check,
    ADD CONSTRAINT account_deletion_jobs_storage_object_paths_check
        CHECK (jsonb_typeof(storage_object_paths) = 'array');

CREATE OR REPLACE FUNCTION public.classify_account_deletion_failure_type(
    p_error TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_error TEXT := LOWER(COALESCE(p_error, ''));
BEGIN
    IF v_error LIKE '%storage%' OR v_error LIKE '%bucket%' THEN
        RETURN 'storage';
    END IF;

    IF v_error LIKE '%vector%' OR v_error LIKE '%pinecone%' THEN
        RETURN 'pinecone';
    END IF;

    IF v_error LIKE '%auth%' THEN
        RETURN 'auth';
    END IF;

    RETURN 'postgres';
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
    RAISE EXCEPTION
        'process_due_account_deletion_job_deprecated: use api-account-delete-worker';
END;
$$;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_available_extensions
        WHERE name = 'pg_net'
    ) THEN
        CREATE EXTENSION IF NOT EXISTS pg_net;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_available_extensions
        WHERE name = 'vault'
    ) THEN
        CREATE EXTENSION IF NOT EXISTS vault;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.account_deletion_worker_project_url()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_project_url TEXT;
BEGIN
    BEGIN
        SELECT decrypted_secret
          INTO v_project_url
          FROM vault.decrypted_secrets
         WHERE name = 'project_url'
         ORDER BY created_at DESC
         LIMIT 1;
    EXCEPTION
        WHEN undefined_table THEN
            v_project_url := NULL;
    END;

    RETURN NULLIF(BTRIM(COALESCE(v_project_url, '')), '');
END;
$$;

CREATE OR REPLACE FUNCTION public.account_deletion_worker_service_role_key()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_service_role_key TEXT;
BEGIN
    BEGIN
        SELECT decrypted_secret
          INTO v_service_role_key
          FROM vault.decrypted_secrets
         WHERE name = 'service_role_key'
         ORDER BY created_at DESC
         LIMIT 1;
    EXCEPTION
        WHEN undefined_table THEN
            v_service_role_key := NULL;
    END;

    RETURN NULLIF(BTRIM(COALESCE(v_service_role_key, '')), '');
END;
$$;

CREATE OR REPLACE FUNCTION public.process_due_account_deletion_jobs(
    p_batch_size INTEGER DEFAULT 25,
    p_now TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE(job_id UUID, status TEXT, detail TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_project_url TEXT;
    v_service_role_key TEXT;
    v_request_id BIGINT;
    v_batch_size INTEGER := LEAST(25, GREATEST(1, COALESCE(p_batch_size, 25)));
BEGIN
    v_project_url := public.account_deletion_worker_project_url();
    v_service_role_key := public.account_deletion_worker_service_role_key();
    IF COALESCE(v_project_url, '') = '' THEN
        job_id := NULL;
        status := 'error';
        detail := 'account_deletion_worker_project_url_missing';
        RETURN NEXT;
        RETURN;
    END IF;
    IF COALESCE(v_service_role_key, '') = '' THEN
        job_id := NULL;
        status := 'error';
        detail := 'account_deletion_worker_service_role_key_missing';
        RETURN NEXT;
        RETURN;
    END IF;

    v_request_id := net.http_post(
        url := v_project_url || '/functions/v1/api-account-delete-worker',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || v_service_role_key,
            'apikey', v_service_role_key,
            'X-Account-Deletion-Worker', 'scheduled'
        ),
        body := jsonb_build_object(
            'batch_size', v_batch_size,
            'requested_at', COALESCE(p_now, NOW())
        )
    );

    job_id := NULL;
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
         WHERE jobname = 'process_due_account_deletion_jobs'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        v_project_url := public.account_deletion_worker_project_url();
        v_service_role_key := public.account_deletion_worker_service_role_key();
        IF COALESCE(v_project_url, '') <> '' AND COALESCE(v_service_role_key, '') <> '' THEN
            PERFORM cron.schedule(
                'process_due_account_deletion_jobs',
                '* * * * *',
                $cron$SELECT public.process_due_account_deletion_jobs(25);$cron$
            );
        ELSE
            RAISE NOTICE
                'Skipped scheduling account deletion worker cron: missing vault secret "project_url" or "service_role_key".';
        END IF;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.account_deletion_worker_project_url() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.account_deletion_worker_service_role_key() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.account_deletion_worker_project_url() TO service_role;
GRANT EXECUTE ON FUNCTION public.account_deletion_worker_service_role_key() TO service_role;
GRANT EXECUTE ON FUNCTION public.process_due_account_deletion_job(UUID, TIMESTAMPTZ) TO service_role;
GRANT EXECUTE ON FUNCTION public.process_due_account_deletion_jobs(INTEGER, TIMESTAMPTZ) TO service_role;
