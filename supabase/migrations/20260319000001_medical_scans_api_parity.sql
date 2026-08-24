-- Keep cloud medical_scans schema aligned with the iOS model and Edge API payloads.

ALTER TABLE public.medical_scans
    ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'pending',
    ADD COLUMN IF NOT EXISTS image_url TEXT,
    ADD COLUMN IF NOT EXISTS image_uploaded_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS needs_review BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS user_reviewed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS user_reviewed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

UPDATE public.medical_scans
   SET status = COALESCE(NULLIF(BTRIM(status), ''), NULLIF(BTRIM(extraction_status), ''), 'pending')
 WHERE status IS NULL OR BTRIM(status) = '';

UPDATE public.medical_scans
   SET image_url = COALESCE(image_url, original_image_url)
 WHERE image_url IS NULL;

UPDATE public.medical_scans
   SET needs_review = TRUE
 WHERE status = 'review_required'
    OR extraction_status IN ('needs_review', 'review_required')
    OR (ai_confidence IS NOT NULL AND ai_confidence < 0.65);

ALTER TABLE public.medical_scans
    ALTER COLUMN status SET DEFAULT 'pending',
    ALTER COLUMN status SET NOT NULL;

ALTER TABLE public.medical_scans
    DROP CONSTRAINT IF EXISTS medical_scans_status_check,
    DROP CONSTRAINT IF EXISTS medical_scans_extraction_status_check,
    ADD CONSTRAINT medical_scans_status_check
        CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'review_required')),
    ADD CONSTRAINT medical_scans_extraction_status_check
        CHECK (extraction_status IN ('pending', 'processing', 'completed', 'failed', 'needs_review', 'review_required'));

CREATE INDEX IF NOT EXISTS idx_medical_scans_active_user
    ON public.medical_scans(user_id, scan_date DESC)
    WHERE deleted_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_medical_scans_deleted
    ON public.medical_scans(user_id, deleted_at DESC)
    WHERE deleted_at IS NOT NULL;
