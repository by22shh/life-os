ALTER TABLE physiological_states
    ADD COLUMN IF NOT EXISTS local_timezone TEXT;

ALTER TABLE physiological_states
    ADD COLUMN IF NOT EXISTS local_utc_offset_minutes INTEGER;
