ALTER TABLE wellness_checks
    ADD COLUMN IF NOT EXISTS checked_timezone TEXT,
    ADD COLUMN IF NOT EXISTS checked_utc_offset_minutes INTEGER;

ALTER TABLE body_composition
    ADD COLUMN IF NOT EXISTS measured_date DATE,
    ADD COLUMN IF NOT EXISTS measured_timezone TEXT,
    ADD COLUMN IF NOT EXISTS measured_utc_offset_minutes INTEGER;

CREATE OR REPLACE FUNCTION public.sync_wellness_checks_local_day_metadata()
RETURNS TRIGGER AS $$
DECLARE
    resolved_timezone TEXT;
BEGIN
    resolved_timezone := NULLIF(BTRIM(NEW.checked_timezone), '');
    IF resolved_timezone IS NULL THEN
        SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
        INTO resolved_timezone
        FROM users u
        WHERE u.id = NEW.user_id;
    END IF;
    resolved_timezone := COALESCE(resolved_timezone, 'UTC');

    IF NEW.date IS NULL AND NEW.checked_at IS NOT NULL THEN
        NEW.date := (NEW.checked_at AT TIME ZONE resolved_timezone)::date;
    END IF;

    IF NEW.checked_at IS NULL THEN
        NEW.checked_at := ((COALESCE(NEW.date, CURRENT_DATE)::text || ' 12:00:00')::timestamp AT TIME ZONE resolved_timezone);
    END IF;

    NEW.checked_timezone := resolved_timezone;
    NEW.checked_utc_offset_minutes := (
        EXTRACT(EPOCH FROM (
            (NEW.checked_at AT TIME ZONE resolved_timezone) -
            (NEW.checked_at AT TIME ZONE 'UTC')
        )) / 60
    )::INTEGER;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.sync_body_composition_local_day_metadata()
RETURNS TRIGGER AS $$
DECLARE
    resolved_timezone TEXT;
BEGIN
    resolved_timezone := NULLIF(BTRIM(NEW.measured_timezone), '');
    IF resolved_timezone IS NULL THEN
        SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
        INTO resolved_timezone
        FROM users u
        WHERE u.id = NEW.user_id;
    END IF;
    resolved_timezone := COALESCE(resolved_timezone, 'UTC');

    NEW.measured_timezone := resolved_timezone;
    NEW.measured_date := (NEW.measured_at AT TIME ZONE resolved_timezone)::date;
    NEW.measured_utc_offset_minutes := (
        EXTRACT(EPOCH FROM (
            (NEW.measured_at AT TIME ZONE resolved_timezone) -
            (NEW.measured_at AT TIME ZONE 'UTC')
        )) / 60
    )::INTEGER;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

ALTER TABLE wellness_checks DISABLE TRIGGER set_wellness_checks_updated_at;
ALTER TABLE body_composition DISABLE TRIGGER set_body_composition_updated_at;

UPDATE wellness_checks wc
SET checked_timezone = COALESCE(
        NULLIF(BTRIM(wc.checked_timezone), ''),
        (
            SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
            FROM users u
            WHERE u.id = wc.user_id
        ),
        'UTC'
    ),
    checked_utc_offset_minutes = COALESCE(
        wc.checked_utc_offset_minutes,
        (
            EXTRACT(EPOCH FROM (
                (wc.checked_at AT TIME ZONE COALESCE(
                    NULLIF(BTRIM(wc.checked_timezone), ''),
                    (
                        SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
                        FROM users u
                        WHERE u.id = wc.user_id
                    ),
                    'UTC'
                )) -
                (wc.checked_at AT TIME ZONE 'UTC')
            )) / 60
        )::INTEGER
    );

UPDATE body_composition bc
SET measured_timezone = COALESCE(
        NULLIF(BTRIM(bc.measured_timezone), ''),
        (
            SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
            FROM users u
            WHERE u.id = bc.user_id
        ),
        'UTC'
    ),
    measured_date = COALESCE(
        bc.measured_date,
        (
            bc.measured_at AT TIME ZONE COALESCE(
                NULLIF(BTRIM(bc.measured_timezone), ''),
                (
                    SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
                    FROM users u
                    WHERE u.id = bc.user_id
                ),
                'UTC'
            )
        )::date
    ),
    measured_utc_offset_minutes = COALESCE(
        bc.measured_utc_offset_minutes,
        (
            EXTRACT(EPOCH FROM (
                (bc.measured_at AT TIME ZONE COALESCE(
                    NULLIF(BTRIM(bc.measured_timezone), ''),
                    (
                        SELECT COALESCE(NULLIF(BTRIM(u.timezone), ''), 'UTC')
                        FROM users u
                        WHERE u.id = bc.user_id
                    ),
                    'UTC'
                )) -
                (bc.measured_at AT TIME ZONE 'UTC')
            )) / 60
        )::INTEGER
    );

ALTER TABLE wellness_checks ENABLE TRIGGER set_wellness_checks_updated_at;
ALTER TABLE body_composition ENABLE TRIGGER set_body_composition_updated_at;

DROP TRIGGER IF EXISTS sync_wellness_checks_local_day_metadata ON wellness_checks;
CREATE TRIGGER sync_wellness_checks_local_day_metadata
    BEFORE INSERT OR UPDATE OF checked_at, date, checked_timezone ON wellness_checks
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_wellness_checks_local_day_metadata();

DROP TRIGGER IF EXISTS sync_body_composition_local_day_metadata ON body_composition;
CREATE TRIGGER sync_body_composition_local_day_metadata
    BEFORE INSERT OR UPDATE OF measured_at, measured_timezone ON body_composition
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_body_composition_local_day_metadata();

CREATE INDEX IF NOT EXISTS idx_body_comp_user_measured_date
    ON body_composition(user_id, measured_date DESC)
    WHERE deleted_at IS NULL;
