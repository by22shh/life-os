-- Users deletion workflow column guard (audit remediation 2026-08-26)
--
-- The blanket `users_update_own` RLS policy lets an authenticated owner UPDATE
-- every column of their users row through PostgREST, including server-managed
-- deletion workflow state. A user could, for example, push deletion_scheduled_at
-- into the future during the grace period and break delete_status expectations.
--
-- Legitimate writers of these columns are:
--   * SECURITY DEFINER RPCs (delete_user_account) — run as the function owner
--     (postgres), detected via current_user.
--   * service_role clients (deletion worker edge functions).
-- Everyone else gets a permission-denied error when any guarded column changes.

CREATE OR REPLACE FUNCTION public.protect_user_deletion_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.deletion_in_progress IS DISTINCT FROM OLD.deletion_in_progress
       OR NEW.deletion_scheduled_at IS DISTINCT FROM OLD.deletion_scheduled_at
       OR NEW.deletion_reason IS DISTINCT FROM OLD.deletion_reason THEN
        IF current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
            RAISE EXCEPTION 'users deletion columns are server-managed'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_users_protect_deletion_columns ON public.users;

CREATE TRIGGER trg_users_protect_deletion_columns
    BEFORE UPDATE ON public.users
    FOR EACH ROW
    EXECUTE FUNCTION public.protect_user_deletion_columns();

REVOKE ALL ON FUNCTION public.protect_user_deletion_columns()
    FROM PUBLIC, anon, authenticated;
