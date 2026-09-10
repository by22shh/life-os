-- A status-only capability must survive auth/user cascade deletion. This
-- table contains no user/profile/health fields and retains only hashed tokens.
ALTER TABLE public.account_deletion_jobs ALTER COLUMN audit_log_id SET DEFAULT gen_random_uuid();
UPDATE public.account_deletion_jobs SET audit_log_id = gen_random_uuid() WHERE audit_log_id IS NULL;
CREATE TABLE public.account_deletion_receipts (
  token_hash TEXT PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  job_id UUID NOT NULL,
  audit_log_id UUID NOT NULL,
  state TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX account_deletion_receipts_job ON public.account_deletion_receipts(job_id);
CREATE INDEX account_deletion_receipts_audit ON public.account_deletion_receipts(audit_log_id);
CREATE INDEX account_deletion_receipts_expiry ON public.account_deletion_receipts(expires_at);
ALTER TABLE public.account_deletion_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.account_deletion_receipts FROM anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON public.account_deletion_receipts TO service_role;

CREATE FUNCTION public.refresh_deletion_receipt_state()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_TABLE_NAME = 'account_deletion_jobs' THEN
    UPDATE public.account_deletion_receipts SET state = NEW.state WHERE job_id = NEW.id;
  ELSE
    UPDATE public.account_deletion_receipts
      SET state = CASE WHEN NEW.compliance_verified THEN 'completed' ELSE 'failed' END
      WHERE audit_log_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.refresh_deletion_receipt_state() FROM PUBLIC;
CREATE TRIGGER refresh_deletion_job_receipts AFTER UPDATE OF state ON public.account_deletion_jobs
  FOR EACH ROW EXECUTE FUNCTION public.refresh_deletion_receipt_state();
CREATE TRIGGER refresh_deletion_audit_receipts AFTER INSERT OR UPDATE ON public.deletion_audit_log
  FOR EACH ROW EXECUTE FUNCTION public.refresh_deletion_receipt_state();
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('expire_deletion_receipts','25 3 * * *',
      'DELETE FROM public.account_deletion_receipts WHERE expires_at < NOW()');
  END IF;
END;
$$;

-- Do not allow an in-flight client to create a new orphan after the deletion
-- worker has captured its manifest, or after cloud backup is revoked.
CREATE POLICY medical_scans_insert_consent ON storage.objects AS RESTRICTIVE
FOR INSERT TO authenticated WITH CHECK (
  bucket_id <> 'medical-scans' OR EXISTS (
    SELECT 1 FROM public.users u JOIN public.privacy_settings p ON p.user_id = u.id
    WHERE u.auth_id = (SELECT auth.uid()) AND NOT u.deletion_in_progress
      AND p.cloud_backup_enabled AND NOT p.medical_scan_local_only
  )
);
CREATE POLICY medical_scans_update_consent ON storage.objects AS RESTRICTIVE
FOR UPDATE TO authenticated WITH CHECK (
  bucket_id <> 'medical-scans' OR EXISTS (
    SELECT 1 FROM public.users u JOIN public.privacy_settings p ON p.user_id = u.id
    WHERE u.auth_id = (SELECT auth.uid()) AND NOT u.deletion_in_progress
      AND p.cloud_backup_enabled AND NOT p.medical_scan_local_only
  )
);
