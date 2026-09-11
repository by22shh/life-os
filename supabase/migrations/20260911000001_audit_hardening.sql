-- Audit hardening (2026-09-11):
-- 1. Immutable ownership for shared food_catalog_items rows (cross-tenant
--    catalog poisoning backstop for service-role writes).
-- 2. Revoke client access to internal deletion_failures ops records.
-- 3. Indexes for scheduled retention/vector workers that currently scan.

-- ---------------------------------------------------------------------------
-- 1. Catalog owner/PK immutability
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_catalog_identity_change()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'catalog_identity_immutable' USING ERRCODE = '42501';
    END IF;
    IF NEW.created_by_user_id IS DISTINCT FROM OLD.created_by_user_id THEN
        RAISE EXCEPTION 'catalog_owner_immutable' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_catalog_identity_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS prevent_catalog_identity_change ON public.food_catalog_items;
CREATE TRIGGER prevent_catalog_identity_change
    BEFORE UPDATE ON public.food_catalog_items
    FOR EACH ROW EXECUTE FUNCTION public.prevent_catalog_identity_change();

-- ---------------------------------------------------------------------------
-- 2. deletion_failures is internal ops data, never a client surface
-- ---------------------------------------------------------------------------
DO $$
DECLARE policy_name TEXT;
BEGIN
    FOR policy_name IN
        SELECT policyname FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'deletion_failures'
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON public.deletion_failures', policy_name);
    END LOOP;
END;
$$;
REVOKE ALL ON TABLE public.deletion_failures FROM anon, authenticated, PUBLIC;

-- ---------------------------------------------------------------------------
-- 3. Worker indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_medical_scans_scheduled_deletion
    ON public.medical_scans (scheduled_deletion_at)
    WHERE scheduled_deletion_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_privacy_settings_vector_refresh
    ON public.privacy_settings (vector_last_attempt_at)
    WHERE vector_opt_in = TRUE AND ai_processing_consent = TRUE;

CREATE INDEX IF NOT EXISTS idx_privacy_settings_vector_cleanup
    ON public.privacy_settings (user_id)
    WHERE vector_cleanup_required = TRUE;
