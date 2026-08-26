-- Security hardening follow-up to the 2026-06 audit findings.
--
-- Closes three classes of gaps:
--   1. SECURITY DEFINER functions that inherited PostgreSQL's default
--      PUBLIC EXECUTE grant and were therefore callable by anon/authenticated
--      clients directly through PostgREST RPC.
--   2. resolve_feature_flags_for_user accepted an arbitrary caller-supplied
--      user id, allowing cross-tenant reads of flag overrides and A/B
--      assignments. It now derives the effective user from the JWT whenever
--      one is present.
--   3. workout_exercises and batch_recipe_ingredients had no RLS at all
--      (they carry no user_id column and hang off parent tables). They are
--      now protected through parent-ownership policies, matching the [017]
--      per-operation policy style.
--
-- Additionally closes a GDPR residue: deletion_failures rows survived account
-- deletion because user_id had no foreign key.

-- ============================================================
-- 1. Revoke default PUBLIC execute on SECURITY DEFINER helpers
-- ============================================================
-- pg_cron invokes these as the job owner (postgres), so revoking PUBLIC does
-- not affect scheduled workers. service_role keeps its explicit grants.

REVOKE ALL ON FUNCTION public.bootstrap_user_from_auth() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_service_role_invocation(TEXT, UUID, JSONB, TEXT, DOUBLE PRECISION)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_service_role_audit_log(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_due_account_deletion_jobs(INTEGER, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.purge_soft_deleted_rows(INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cleanup_expired_feature_flags() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.process_due_medical_scan_retention_jobs(INTEGER, TIMESTAMPTZ) FROM PUBLIC;

-- ============================================================
-- 2. resolve_feature_flags_for_user: derive caller identity from JWT
-- ============================================================
-- Behavior matrix:
--   * authenticated client  -> effective user is always the JWT owner;
--     any supplied p_user_id is ignored unless it matches their own row.
--   * service_role / postgres (edge functions, cron) -> trusted callers may
--     pass an explicit p_user_id, preserving the existing edge contract.
--   * anon / unresolvable -> empty result set.

CREATE OR REPLACE FUNCTION public.resolve_feature_flags_for_user(p_user_id UUID)
RETURNS TABLE(flag_key TEXT, enabled BOOLEAN, variant TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_auth_uid UUID;
    v_effective_user_id UUID;
    v_caller_role TEXT := COALESCE(current_setting('role', TRUE), current_user);
    v_is_trusted BOOLEAN := FALSE;
BEGIN
    v_auth_uid := NULLIF(current_setting('request.jwt.claim.sub', TRUE), '')::UUID;

    IF v_auth_uid IS NOT NULL THEN
        SELECT u.id INTO v_effective_user_id
        FROM public.users u
        WHERE u.auth_id = v_auth_uid
        LIMIT 1;
    END IF;

    SELECT COALESCE(
            bool_or(r.rolname IN ('service_role', 'postgres')),
            FALSE
           )
      INTO v_is_trusted
      FROM pg_roles r
     WHERE r.rolname = current_user;

    IF v_effective_user_id IS NULL THEN
        IF v_is_trusted THEN
            v_effective_user_id := p_user_id;
        ELSE
            RETURN;
        END IF;
    ELSIF p_user_id IS NOT NULL AND p_user_id <> v_effective_user_id THEN
        IF NOT v_is_trusted THEN
            -- Authenticated callers may never resolve another user's flags.
            p_user_id := v_effective_user_id;
        END IF;
    END IF;

    RETURN QUERY
    SELECT
        ff.flag_key,
        COALESCE(
            ufo.enabled,
            ff.enabled,
            (ff.rollout_pct IS NOT NULL
             AND abs(hashtext(v_effective_user_id::TEXT || ff.flag_key)) % 100 < ff.rollout_pct)
        ) AS enabled,
        aba.variant
    FROM feature_flags ff
    LEFT JOIN user_feature_overrides ufo
        ON ufo.flag_id = ff.id AND ufo.user_id = v_effective_user_id
    LEFT JOIN ab_tests abt
        ON abt.flag_id = ff.id AND abt.status = 'running'
    LEFT JOIN ab_test_assignments aba
        ON aba.test_id = abt.id AND aba.user_id = v_effective_user_id
    WHERE ff.expires_at IS NULL OR ff.expires_at > NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_feature_flags_for_user(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_feature_flags_for_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_feature_flags_for_user(UUID) TO service_role;

-- ============================================================
-- 3. RLS for child tables without a user_id column
-- ============================================================
-- Access is derived from the owning parent row:
--   workout_exercises.session_id -> workout_sessions.user_id
--   batch_recipe_ingredients.batch_recipe_id -> batch_recipes.user_id
-- Writes performed by Edge Functions use the service-role client and bypass
-- RLS; these policies constrain the iOS app's direct sync pulls/upserts.

ALTER TABLE public.workout_exercises ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.batch_recipe_ingredients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS workout_exercises_select_own ON public.workout_exercises;
CREATE POLICY workout_exercises_select_own
    ON public.workout_exercises
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.workout_sessions ws
            WHERE ws.id = session_id
              AND ws.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    );

DROP POLICY IF EXISTS workout_exercises_insert_own ON public.workout_exercises;
CREATE POLICY workout_exercises_insert_own
    ON public.workout_exercises
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.workout_sessions ws
            WHERE ws.id = session_id
              AND ws.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    );

DROP POLICY IF EXISTS workout_exercises_update_own ON public.workout_exercises;
CREATE POLICY workout_exercises_update_own
    ON public.workout_exercises
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.workout_sessions ws
            WHERE ws.id = session_id
              AND ws.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.workout_sessions ws
            WHERE ws.id = session_id
              AND ws.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    );

DROP POLICY IF EXISTS workout_exercises_no_hard_delete ON public.workout_exercises;
CREATE POLICY workout_exercises_no_hard_delete
    ON public.workout_exercises
    FOR DELETE
    TO authenticated
    USING (false);

DROP POLICY IF EXISTS batch_recipe_ingredients_select_own ON public.batch_recipe_ingredients;
CREATE POLICY batch_recipe_ingredients_select_own
    ON public.batch_recipe_ingredients
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.batch_recipes br
            WHERE br.id = batch_recipe_id
              AND br.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    );

DROP POLICY IF EXISTS batch_recipe_ingredients_insert_own ON public.batch_recipe_ingredients;
CREATE POLICY batch_recipe_ingredients_insert_own
    ON public.batch_recipe_ingredients
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.batch_recipes br
            WHERE br.id = batch_recipe_id
              AND br.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    );

DROP POLICY IF EXISTS batch_recipe_ingredients_update_own ON public.batch_recipe_ingredients;
CREATE POLICY batch_recipe_ingredients_update_own
    ON public.batch_recipe_ingredients
    FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.batch_recipes br
            WHERE br.id = batch_recipe_id
              AND br.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.batch_recipes br
            WHERE br.id = batch_recipe_id
              AND br.user_id IN (
                  SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())
              )
        )
    );

DROP POLICY IF EXISTS batch_recipe_ingredients_no_hard_delete ON public.batch_recipe_ingredients;
CREATE POLICY batch_recipe_ingredients_no_hard_delete
    ON public.batch_recipe_ingredients
    FOR DELETE
    TO authenticated
    USING (false);

-- Align grants with the new policies (same derivation rule as
-- 20260730000001_public_table_grants.sql).
GRANT SELECT, INSERT, UPDATE ON TABLE public.workout_exercises TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.batch_recipe_ingredients TO authenticated;

-- ============================================================
-- 4. deletion_failures: purge residue on account deletion
-- ============================================================
-- Rows referencing users deleted before this migration are removed first so
-- the new cascade constraint validates cleanly.

DELETE FROM public.deletion_failures df
WHERE df.resolved
   OR NOT EXISTS (
       SELECT 1 FROM public.users u WHERE u.id = df.user_id
   );

ALTER TABLE public.deletion_failures
    DROP CONSTRAINT IF EXISTS deletion_failures_user_id_fkey;

ALTER TABLE public.deletion_failures
    ADD CONSTRAINT deletion_failures_user_id_fkey
    FOREIGN KEY (user_id)
    REFERENCES public.users(id)
    ON DELETE CASCADE;

-- ============================================================
-- 5. Invalidate legacy plaintext export download tokens
-- ============================================================
-- Download tokens are now stored as SHA-256 digests. Pre-existing rows hold
-- raw tokens that would never match a digest lookup; overwrite them so any
-- previously leaked database read cannot be replayed into a working URL.
-- Artifacts with invalidated tokens are re-tokenized on the next export
-- status poll (rotate path in _shared/export_builder.ts).

UPDATE public.export_artifacts
SET download_token = 'invalidated-legacy-plaintext-' || md5(random()::TEXT)
WHERE download_token NOT LIKE 'invalidated-legacy-plaintext-%';

-- ============================================================
-- 6. Ops alert dispatcher cron
-- ============================================================
-- Bridges ops_alert_events to the ops-alert-dispatch edge function, which
-- forwards a digest to OPS_ALERT_WEBHOOK_URL. Uses the same vault-secret +
-- pg_net pattern as the medical scan retention worker.

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
         WHERE jobname = 'dispatch_ops_alert_events'
         LIMIT 1;

        IF v_jobid IS NOT NULL THEN
            PERFORM cron.unschedule(v_jobid);
        END IF;

        -- Reuses the existing vault accessors: both workers read the same
        -- "project_url" / "service_role_key" secret names.
        v_project_url := public.account_deletion_worker_project_url();
        v_service_role_key := public.account_deletion_worker_service_role_key();

        IF COALESCE(v_project_url, '') <> '' AND COALESCE(v_service_role_key, '') <> '' THEN
            PERFORM cron.schedule(
                'dispatch_ops_alert_events',
                '45 * * * *',
                $cron$
                SELECT net.http_post(
                    url := public.account_deletion_worker_project_url() || '/functions/v1/ops-alert-dispatch',
                    headers := jsonb_build_object(
                        'Content-Type', 'application/json',
                        'Authorization', 'Bearer ' || public.account_deletion_worker_service_role_key(),
                        'apikey', public.account_deletion_worker_service_role_key(),
                        'X-Ops-Alert-Dispatcher', 'scheduled'
                    ),
                    body := jsonb_build_object('window_minutes', 65)
                );
                $cron$
            );
        ELSE
            RAISE WARNING
                'Skipped scheduling ops alert dispatcher cron: missing vault secret "project_url" or "service_role_key".';
        END IF;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Failed to schedule ops alert dispatcher cron: % (%)', SQLERRM, SQLSTATE;
END;
$$;
