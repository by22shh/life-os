-- Store objective HealthKit/manual sleep without coercing legacy subjective
-- TIME, boolean or environmental labels into incompatible numeric values.
ALTER TABLE public.sleep_logs
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS bed_time timestamptz,
  ADD COLUMN IF NOT EXISTS wake_time timestamptz,
  ADD COLUMN IF NOT EXISTS total_duration_minutes integer,
  ADD COLUMN IF NOT EXISTS time_in_bed_minutes integer,
  ADD COLUMN IF NOT EXISTS deep_sleep_minutes integer,
  ADD COLUMN IF NOT EXISTS rem_sleep_minutes integer,
  ADD COLUMN IF NOT EXISTS light_sleep_minutes integer,
  ADD COLUMN IF NOT EXISTS awake_minutes integer,
  ADD COLUMN IF NOT EXISTS number_of_awakenings integer,
  ADD COLUMN IF NOT EXISTS sleep_efficiency double precision,
  ADD COLUMN IF NOT EXISTS sleep_quality_score double precision,
  ADD COLUMN IF NOT EXISTS device_name text,
  ADD COLUMN IF NOT EXISTS client_updated_at timestamptz;

CREATE OR REPLACE FUNCTION public.upsert_canonical_sleep(p_user_id uuid, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  old_row public.sleep_logs;
  incoming public.sleep_logs;
  result public.sleep_logs;
  requested_id uuid := (p_payload->>'id')::uuid;
  requested_day date := (p_payload->>'sleep_date')::date;
BEGIN
  IF p_user_id IS NULL OR requested_id IS NULL OR requested_day IS NULL
     OR p_payload->>'source' NOT IN ('manual','healthkit','wearable','import')
     OR p_payload->>'client_updated_at' IS NULL THEN
    RAISE EXCEPTION 'Invalid sleep identity' USING ERRCODE = '22023';
  END IF;
  -- Serialize competing devices on the natural day key, including first insert.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_user_id::text || '/' || requested_day::text, 0));
  SELECT * INTO old_row FROM public.sleep_logs WHERE id = requested_id;
  IF FOUND AND old_row.user_id <> p_user_id THEN
    RAISE EXCEPTION 'Forbidden record owner' USING ERRCODE = '42501';
  END IF;
  IF FOUND AND old_row.sleep_date <> requested_day THEN
    RAISE EXCEPTION 'Sleep identity cannot move days' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO old_row FROM public.sleep_logs WHERE user_id = p_user_id AND sleep_date = requested_day FOR UPDATE;
  IF FOUND THEN
    -- Manual edits (including deletions) must survive delayed HealthKit replay.
    IF (old_row.source = 'manual' AND p_payload->>'source' <> 'manual'
        AND (old_row.total_duration_minutes IS NOT NULL OR old_row.deleted_at IS NOT NULL))
       OR (old_row.source = p_payload->>'source' AND old_row.client_updated_at IS NOT NULL
           AND old_row.client_updated_at >= (p_payload->>'client_updated_at')::timestamptz) THEN
      RETURN to_jsonb(old_row);
    END IF;
    incoming := jsonb_populate_record(old_row, p_payload || jsonb_build_object('id', old_row.id, 'user_id', p_user_id));
  ELSE
    incoming := jsonb_populate_record(NULL::public.sleep_logs, p_payload || jsonb_build_object('user_id', p_user_id, 'created_at', now(), 'updated_at', now()));
  END IF;
  INSERT INTO public.sleep_logs (
    id,user_id,sleep_date,source,created_at,updated_at,client_updated_at,
    bed_time,wake_time,total_duration_minutes,time_in_bed_minutes,
    deep_sleep_minutes,rem_sleep_minutes,light_sleep_minutes,awake_minutes,
    number_of_awakenings,sleep_efficiency,sleep_quality_score,device_name,
    sleep_timezone,sleep_utc_offset_minutes,notes,deleted_at
  ) VALUES (
    incoming.id,p_user_id,requested_day,incoming.source,incoming.created_at,now(),incoming.client_updated_at,
    incoming.bed_time,incoming.wake_time,incoming.total_duration_minutes,incoming.time_in_bed_minutes,
    incoming.deep_sleep_minutes,incoming.rem_sleep_minutes,incoming.light_sleep_minutes,incoming.awake_minutes,
    incoming.number_of_awakenings,incoming.sleep_efficiency,incoming.sleep_quality_score,incoming.device_name,
    incoming.sleep_timezone,incoming.sleep_utc_offset_minutes,incoming.notes,incoming.deleted_at
  ) ON CONFLICT (user_id,sleep_date) DO UPDATE SET
    source=excluded.source,client_updated_at=excluded.client_updated_at,
    bed_time=excluded.bed_time,wake_time=excluded.wake_time,
    total_duration_minutes=excluded.total_duration_minutes,time_in_bed_minutes=excluded.time_in_bed_minutes,
    deep_sleep_minutes=excluded.deep_sleep_minutes,rem_sleep_minutes=excluded.rem_sleep_minutes,
    light_sleep_minutes=excluded.light_sleep_minutes,awake_minutes=excluded.awake_minutes,
    number_of_awakenings=excluded.number_of_awakenings,sleep_efficiency=excluded.sleep_efficiency,
    sleep_quality_score=excluded.sleep_quality_score,device_name=excluded.device_name,
    sleep_timezone=excluded.sleep_timezone,sleep_utc_offset_minutes=excluded.sleep_utc_offset_minutes,
    notes=excluded.notes,deleted_at=excluded.deleted_at
  RETURNING * INTO result;
  RETURN to_jsonb(result);
END;
$$;
REVOKE ALL ON FUNCTION public.upsert_canonical_sleep(uuid,jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_canonical_sleep(uuid,jsonb) TO service_role;
