-- Export artifact hygiene (audit remediation 2026-08-26)
--
-- 1. export_jobs.download_url historically stored the RAW download token URL,
--    contradicting the "raw tokens are never persisted" threat model that the
--    SHA-256 digest storage in export_artifacts already implements. The edge
--    layer no longer writes download_url at all (tokens rotate per status
--    poll and live only in responses), so any persisted value is a stale
--    legacy secret and must be scrubbed.
--
-- 2. Expired GDPR export artifacts were never deleted: expireExport only
--    flips job status while payload_json (the full health data dump) stayed
--    in export_artifacts indefinitely. Adds an hourly pg_cron purge that
--    deletes rows whose expires_at has passed, enforcing the documented 24h
--    TTL at the storage layer (GDPR Art. 5(1)(e) storage limitation).

-- ---------------------------------------------------------------
-- 1. Scrub legacy plaintext download URLs.
-- ---------------------------------------------------------------

UPDATE public.export_jobs
SET download_url = NULL
WHERE download_url IS NOT NULL;

-- ---------------------------------------------------------------
-- 2. Retention: delete expired export payloads.
-- ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.purge_expired_export_artifacts()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_deleted INTEGER;
BEGIN
    DELETE FROM public.export_artifacts
    WHERE expires_at < NOW();
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_expired_export_artifacts()
    FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
    v_jobid BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS pg_cron;

        SELECT jobid
          INTO v_jobid
          FROM cron.job
         WHERE jobname = 'purge_expired_export_artifacts'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        PERFORM cron.schedule(
            'purge_expired_export_artifacts',
            '37 * * * *',
            $cron$
            SELECT public.purge_expired_export_artifacts();
            $cron$
        );
    ELSE
        RAISE WARNING
            'Skipped scheduling purge_expired_export_artifacts cron: pg_cron not available.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to schedule export artifact purge cron: % (%)', SQLERRM, SQLSTATE;
END;
$$;
