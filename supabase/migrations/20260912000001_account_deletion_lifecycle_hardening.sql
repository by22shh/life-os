-- Account deletion lifecycle hardening (2026-09-12)
--
-- The deletion queue is an internal command queue. Its identity and state are
-- derived from public.users by trusted server code, never accepted from a
-- browser client. The functions below also make cancellation a single locked
-- transition, recover abandoned worker claims, and enforce ownership of
-- training-plan child rows.

-- ---------------------------------------------------------------------------
-- 1. Make account_deletion_jobs service-only and bind its auth identity to the
--    canonical public.users.auth_id value.
-- ---------------------------------------------------------------------------
ALTER TABLE public.account_deletion_jobs
    ADD COLUMN IF NOT EXISTS processing_started_at TIMESTAMPTZ;

UPDATE public.account_deletion_jobs AS job
SET auth_user_id = users.auth_id
FROM public.users AS users
WHERE users.id = job.user_id
  AND job.auth_user_id IS DISTINCT FROM users.auth_id;

UPDATE public.account_deletion_jobs
SET processing_started_at = updated_at
WHERE mode = 'scheduled'
  AND state IN ('auth_deleting', 'data_deleting', 'vector_verifying')
  AND processing_started_at IS NULL;

ALTER TABLE public.account_deletion_jobs
    ALTER COLUMN auth_user_id SET NOT NULL;

CREATE OR REPLACE FUNCTION public.bind_account_deletion_job_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
    v_auth_id UUID;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'account_deletion_job_user_immutable' USING ERRCODE = '42501';
    END IF;

    SELECT auth_id INTO v_auth_id
    FROM public.users
    WHERE id = NEW.user_id;

    IF v_auth_id IS NULL THEN
        RAISE EXCEPTION 'account_deletion_job_user_not_found' USING ERRCODE = '23503';
    END IF;

    NEW.auth_user_id := v_auth_id;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.bind_account_deletion_job_identity() FROM PUBLIC;

DROP TRIGGER IF EXISTS bind_account_deletion_job_identity ON public.account_deletion_jobs;
CREATE TRIGGER bind_account_deletion_job_identity
    BEFORE INSERT OR UPDATE ON public.account_deletion_jobs
    FOR EACH ROW
    EXECUTE FUNCTION public.bind_account_deletion_job_identity();

DO $$
DECLARE
    policy_record RECORD;
BEGIN
    FOR policy_record IN
        SELECT policyname
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'account_deletion_jobs'
    LOOP
        EXECUTE format(
            'DROP POLICY IF EXISTS %I ON public.account_deletion_jobs',
            policy_record.policyname
        );
    END LOOP;
END;
$$;

REVOKE ALL ON TABLE public.account_deletion_jobs FROM PUBLIC, anon, authenticated;

CREATE INDEX IF NOT EXISTS idx_account_deletion_jobs_processing_lease
    ON public.account_deletion_jobs (processing_started_at)
    WHERE mode = 'scheduled'
      AND state IN ('auth_deleting', 'data_deleting', 'vector_verifying');

-- ---------------------------------------------------------------------------
-- 2. Atomically cancel only a deletion job that has not begun destructive
--    processing. The FOR UPDATE locks serialize cancellation with the worker.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_scheduled_account_deletion(
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_user public.users%ROWTYPE;
    v_job public.account_deletion_jobs%ROWTYPE;
    v_has_cancellable BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_user
    FROM public.users
    WHERE id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN 'not_found';
    END IF;

    FOR v_job IN
        SELECT *
        FROM public.account_deletion_jobs
        WHERE user_id = p_user_id
          AND mode = 'scheduled'
          AND state NOT IN ('completed', 'failed', 'cancelled')
        FOR UPDATE
    LOOP
        IF v_job.state IN ('auth_deleting', 'data_deleting', 'vector_verifying') THEN
            RETURN 'in_progress';
        END IF;
        IF v_job.state IN ('requested', 'scheduled', 'retry_scheduled') THEN
            v_has_cancellable := TRUE;
        END IF;
    END LOOP;

    IF v_user.deletion_in_progress THEN
        RETURN 'in_progress';
    END IF;

    IF NOT v_has_cancellable AND v_user.deletion_scheduled_at IS NULL THEN
        RETURN 'not_scheduled';
    END IF;

    UPDATE public.account_deletion_jobs
    SET state = 'cancelled',
        next_retry_at = NULL,
        last_error = NULL,
        last_failure_type = NULL,
        processing_started_at = NULL
    WHERE user_id = p_user_id
      AND mode = 'scheduled'
      AND state IN ('requested', 'scheduled', 'retry_scheduled');

    UPDATE public.users
    SET deletion_scheduled_at = NULL,
        deletion_reason = NULL,
        deletion_in_progress = FALSE
    WHERE id = p_user_id;

    RETURN 'cancelled';
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_scheduled_account_deletion(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_scheduled_account_deletion(UUID) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Catalog ownership is immutable during normal writes, but ON DELETE SET
--    NULL must be allowed when its owner account is actually being removed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_catalog_identity_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'catalog_identity_immutable' USING ERRCODE = '42501';
    END IF;
    IF NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id THEN
        IF NEW.created_by_user_id IS NULL
           AND OLD.created_by_user_id IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM public.users WHERE id = OLD.created_by_user_id
           ) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'catalog_owner_immutable' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_exercise_catalog_identity_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'catalog_identity_immutable' USING ERRCODE = '42501';
    END IF;
    IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        IF NEW.created_by IS NULL
           AND OLD.created_by IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM public.users WHERE id = OLD.created_by
           ) THEN
            RETURN NEW;
        END IF;
        RAISE EXCEPTION 'catalog_owner_immutable' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4. A planned session is owned by the same user as its parent plan. Repair
--    malformed legacy rows before replacing the single-column foreign key.
-- ---------------------------------------------------------------------------
DELETE FROM public.training_plan_sessions AS session
USING public.training_plans AS plan
WHERE session.training_plan_id = plan.id
  AND session.user_id IS DISTINCT FROM plan.user_id;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.training_plans'::regclass
          AND conname = 'training_plans_id_user_id_key'
    ) THEN
        ALTER TABLE public.training_plans
            ADD CONSTRAINT training_plans_id_user_id_key UNIQUE (id, user_id);
    END IF;
END;
$$;

ALTER TABLE public.training_plan_sessions
    DROP CONSTRAINT IF EXISTS training_plan_sessions_training_plan_id_fkey;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.training_plan_sessions'::regclass
          AND conname = 'training_plan_sessions_plan_owner_fkey'
    ) THEN
        ALTER TABLE public.training_plan_sessions
            ADD CONSTRAINT training_plan_sessions_plan_owner_fkey
            FOREIGN KEY (training_plan_id, user_id)
            REFERENCES public.training_plans(id, user_id)
            ON DELETE CASCADE;
    END IF;
END;
$$;
