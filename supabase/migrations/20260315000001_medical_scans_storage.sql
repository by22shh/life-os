INSERT INTO storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
VALUES (
    'medical-scans',
    'medical-scans',
    FALSE,
    52428800,
    ARRAY[
        'application/pdf',
        'image/jpeg',
        'image/png',
        'image/heic',
        'image/heif',
        'application/octet-stream'
    ]
)
ON CONFLICT (id) DO UPDATE
SET
    public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'medical_scans_select_own'
    ) THEN
        CREATE POLICY medical_scans_select_own
        ON storage.objects
        FOR SELECT
        TO authenticated
        USING (
            bucket_id = 'medical-scans'
            AND LOWER(auth.uid()::text) = LOWER((storage.foldername(name))[1])
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'medical_scans_insert_own'
    ) THEN
        CREATE POLICY medical_scans_insert_own
        ON storage.objects
        FOR INSERT
        TO authenticated
        WITH CHECK (
            bucket_id = 'medical-scans'
            AND LOWER(auth.uid()::text) = LOWER((storage.foldername(name))[1])
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'medical_scans_update_own'
    ) THEN
        CREATE POLICY medical_scans_update_own
        ON storage.objects
        FOR UPDATE
        TO authenticated
        USING (
            bucket_id = 'medical-scans'
            AND LOWER(auth.uid()::text) = LOWER((storage.foldername(name))[1])
        )
        WITH CHECK (
            bucket_id = 'medical-scans'
            AND LOWER(auth.uid()::text) = LOWER((storage.foldername(name))[1])
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_policies
        WHERE schemaname = 'storage'
          AND tablename = 'objects'
          AND policyname = 'medical_scans_delete_own'
    ) THEN
        CREATE POLICY medical_scans_delete_own
        ON storage.objects
        FOR DELETE
        TO authenticated
        USING (
            bucket_id = 'medical-scans'
            AND LOWER(auth.uid()::text) = LOWER((storage.foldername(name))[1])
        );
    END IF;
END $$;
