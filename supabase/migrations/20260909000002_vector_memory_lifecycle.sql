-- Operational state is server-owned. A short lease serializes external writes
-- with deletion, without holding a database transaction during HTTP calls.
ALTER TABLE public.privacy_settings
  ADD COLUMN IF NOT EXISTS vector_cleanup_required BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS vector_last_sync_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS vector_last_attempt_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS vector_source_cursors JSONB NOT NULL DEFAULT '{}'::JSONB,
  ADD COLUMN IF NOT EXISTS vector_operation_id UUID,
  ADD COLUMN IF NOT EXISTS vector_lease_expires_at TIMESTAMPTZ;
UPDATE public.privacy_settings p SET vector_cleanup_required = TRUE
  WHERE EXISTS (SELECT 1 FROM public.vector_memory v WHERE v.user_id = p.user_id);

CREATE OR REPLACE FUNCTION public.guard_vector_operational_state()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF current_user NOT IN ('postgres','service_role') AND (
    (TG_OP = 'INSERT' AND (NEW.vector_cleanup_required OR NEW.vector_last_sync_at IS NOT NULL
       OR NEW.vector_last_attempt_at IS NOT NULL OR NEW.vector_operation_id IS NOT NULL OR NEW.vector_lease_expires_at IS NOT NULL OR NEW.vector_source_cursors <> '{}'::JSONB))
    OR (TG_OP = 'UPDATE' AND (NEW.vector_cleanup_required,NEW.vector_last_sync_at,NEW.vector_last_attempt_at,NEW.vector_operation_id,NEW.vector_lease_expires_at,NEW.vector_source_cursors)
       IS DISTINCT FROM (OLD.vector_cleanup_required,OLD.vector_last_sync_at,OLD.vector_last_attempt_at,OLD.vector_operation_id,OLD.vector_lease_expires_at,OLD.vector_source_cursors))
  ) THEN RAISE EXCEPTION 'vector_operational_state_server_only' USING ERRCODE = '42501'; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_vector_operational_state() FROM PUBLIC;
CREATE TRIGGER guard_vector_operational_state BEFORE INSERT OR UPDATE ON public.privacy_settings
  FOR EACH ROW EXECUTE FUNCTION public.guard_vector_operational_state();
REVOKE INSERT, UPDATE, DELETE ON public.vector_memory FROM authenticated;
REVOKE DELETE ON public.privacy_settings FROM authenticated;
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname = 'public'
      AND tablename = 'vector_memory' AND cmd <> 'SELECT' LOOP
    EXECUTE format('DROP POLICY %I ON public.vector_memory', p.policyname);
  END LOOP;
  FOR p IN SELECT policyname FROM pg_policies WHERE schemaname = 'public'
      AND tablename = 'privacy_settings' AND cmd = 'DELETE' LOOP
    EXECUTE format('DROP POLICY %I ON public.privacy_settings', p.policyname);
  END LOOP;
END;
$$;

DROP POLICY IF EXISTS vector_memory_read_derived ON public.vector_memory;
CREATE POLICY vector_memory_read_derived ON public.vector_memory FOR SELECT TO authenticated
USING (user_id IN (SELECT id FROM public.users WHERE auth_id = (SELECT auth.uid())));

CREATE OR REPLACE FUNCTION public.claim_vector_operation(p_user_id UUID, p_operation_id UUID, p_write BOOLEAN)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE p public.privacy_settings;
BEGIN
  SELECT * INTO p FROM public.privacy_settings WHERE user_id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RETURN FALSE; END IF;
  IF p.vector_lease_expires_at > NOW() THEN RAISE EXCEPTION 'vector_operation_busy' USING ERRCODE = '55P03'; END IF;
  IF p_write AND (NOT p.vector_opt_in OR NOT p.ai_processing_consent OR NOT EXISTS (
      SELECT 1 FROM public.users WHERE id = p_user_id AND NOT deletion_in_progress
  )) THEN RETURN FALSE; END IF;
  UPDATE public.privacy_settings SET vector_operation_id = p_operation_id,
    vector_lease_expires_at = NOW() + INTERVAL '10 minutes', vector_last_attempt_at = NOW(),
    vector_cleanup_required = vector_cleanup_required OR p_write
    WHERE user_id = p_user_id;
  RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_vector_operation(UUID,UUID,BOOLEAN) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_vector_operation(UUID,UUID,BOOLEAN) TO service_role;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
    AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
    AND COALESCE(public.account_deletion_worker_project_url(),'') <> ''
    AND COALESCE(public.account_deletion_worker_service_role_key(),'') <> '' THEN
    PERFORM cron.schedule('sync_vector_memory','*/10 * * * *', $cron$
      SELECT net.http_post(
        url := public.account_deletion_worker_project_url() || '/functions/v1/api-vector-memory-worker',
        headers := jsonb_build_object('Content-Type','application/json',
          'Authorization','Bearer ' || public.account_deletion_worker_service_role_key(),
          'apikey',public.account_deletion_worker_service_role_key(),'X-Vector-Memory-Worker','scheduled'),
        body := '{}'::JSONB);
    $cron$);
  END IF;
END;
$$;
