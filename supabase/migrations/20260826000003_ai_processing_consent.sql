-- AI processing consent (audit remediation 2026-08-26)
--
-- Life OS forwards derived health context (HRV/sleep/stress aggregates for
-- insights; food photos and OCR text for nutrition analysis) to OpenRouter,
-- an external subprocessor. Under GDPR Art. 9 this processing of
-- special-category data needs its own explicit consent basis — sharing
-- analytics_consent conflated product analytics with third-party AI
-- processing.
--
-- Default FALSE: AI endpoints fail closed until the user opts in from
-- Settings > Privacy ("AI processing"). The edge layer enforces this
-- server-side via _shared/ai_consent.ts, mirroring analytics enforcement.

ALTER TABLE public.privacy_settings
    ADD COLUMN IF NOT EXISTS ai_processing_consent BOOLEAN NOT NULL DEFAULT FALSE;
