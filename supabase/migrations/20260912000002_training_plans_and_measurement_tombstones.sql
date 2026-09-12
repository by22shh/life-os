-- Executable training-plan adaptations and synchronized lab-measurement tombstones.
--
-- Training adaptations must alter the sessions a person will actually perform,
-- not merely record an advisory flag on the parent plan. Lab measurements use a
-- tombstone so every device can observe a user deletion before eventual purge.

-- ---------------------------------------------------------------------------
-- 1. Apply a validated plan adjustment to pending sessions and the plan in one
--    transaction. Generated session documents have an executable exercises
--    array; this helper also handles previously-created sparse documents.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adapt_training_plan_session_exercises(
    p_document JSONB,
    p_adjustment TEXT,
    p_reason TEXT,
    p_effective_from DATE,
    p_duration_minutes INTEGER
) RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
    v_document JSONB := COALESCE(p_document, '{}'::JSONB);
    v_multiplier NUMERIC := 1;
    v_duration INTEGER := GREATEST(10, COALESCE(p_duration_minutes, 60));
BEGIN
    IF p_adjustment = 'reduce_volume_30' THEN
        v_multiplier := 0.7;
        v_duration := GREATEST(10, CEIL(v_duration * v_multiplier)::INTEGER);
    ELSIF p_adjustment = 'reduce_intensity_20' THEN
        v_multiplier := 0.8;
    ELSIF p_adjustment = 'deload_week' THEN
        v_multiplier := 0.6;
        v_duration := GREATEST(10, CEIL(v_duration * v_multiplier)::INTEGER);
    ELSIF p_adjustment = 'swap_to_mobility' THEN
        v_duration := LEAST(v_duration, 30);
        v_document := jsonb_build_object(
            'schema_version', 1,
            'title', 'Mobility and recovery session',
            'goal', 'recovery',
            'session_type', 'mobility',
            'duration_minutes', v_duration,
            'warmup_minutes', 5,
            'cooldown_minutes', 5,
            'exercises', jsonb_build_array(
                jsonb_build_object(
                    'exercise_key', 'hip_mobility_flow',
                    'name', 'Hip mobility flow',
                    'sets', 2,
                    'reps', '8 each side',
                    'rest_seconds', 30,
                    'target_rpe', 3,
                    'load_multiplier', 1
                ),
                jsonb_build_object(
                    'exercise_key', 'thoracic_rotation',
                    'name', 'Thoracic rotation',
                    'sets', 2,
                    'reps', '8 each side',
                    'rest_seconds', 30,
                    'target_rpe', 3,
                    'load_multiplier', 1
                )
            )
        );
    END IF;

    IF p_adjustment IN ('reduce_volume_30', 'reduce_intensity_20', 'deload_week') THEN
        v_document := jsonb_set(
            v_document,
            '{exercises}',
            COALESCE((
                SELECT jsonb_agg(
                    CASE
                        WHEN jsonb_typeof(exercise) <> 'object' THEN exercise
                        WHEN p_adjustment IN ('reduce_volume_30', 'deload_week') THEN
                            jsonb_set(
                                jsonb_set(
                                    exercise,
                                    '{sets}',
                                    to_jsonb(GREATEST(
                                        1,
                                        CEIL(COALESCE(
                                            CASE
                                                WHEN jsonb_typeof(exercise->'sets') = 'number'
                                                    THEN (exercise->>'sets')::NUMERIC
                                                ELSE 1
                                            END,
                                            1
                                        ) * v_multiplier
                                    )::INTEGER)),
                                    TRUE
                                ),
                                '{load_multiplier}',
                                to_jsonb(v_multiplier),
                                TRUE
                            )
                        ELSE
                            jsonb_set(
                                jsonb_set(
                                    exercise,
                                    '{target_rpe}',
                                    to_jsonb(GREATEST(
                                        1,
                                        COALESCE(
                                            CASE
                                                WHEN jsonb_typeof(exercise->'target_rpe') = 'number'
                                                    THEN (exercise->>'target_rpe')::INTEGER
                                                ELSE 7
                                            END,
                                            7
                                        ) - 2
                                    )),
                                    TRUE
                                ),
                                '{load_multiplier}',
                                to_jsonb(v_multiplier),
                                TRUE
                            )
                    END
                )
                FROM jsonb_array_elements(COALESCE(v_document->'exercises', '[]'::JSONB)) AS elements(exercise)
            ), '[]'::JSONB),
            TRUE
        );
    END IF;

    v_document := jsonb_set(
        v_document,
        '{duration_minutes}',
        to_jsonb(v_duration),
        TRUE
    );
    v_document := jsonb_set(
        v_document,
        '{adaptations}',
        COALESCE(v_document->'adaptations', '[]'::JSONB) || jsonb_build_array(
            jsonb_build_object(
                'reason', p_reason,
                'adjustment', p_adjustment,
                'effective_from', p_effective_from
            )
        ),
        TRUE
    );
    RETURN v_document;
END;
$$;
REVOKE ALL ON FUNCTION public.adapt_training_plan_session_exercises(JSONB, TEXT, TEXT, DATE, INTEGER)
    FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.apply_training_plan_adjustment(
    p_user_id UUID,
    p_plan_id UUID,
    p_reason TEXT,
    p_adjustment TEXT,
    p_effective_from DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_adaptive_rules JSONB;
    v_target_session_id UUID;
    v_sessions_adjusted INTEGER := 0;
    v_skipped_sessions INTEGER := 0;
BEGIN
    IF p_reason NOT IN (
        'recovery_low', 'recovery_critical', 'fatigue_accumulation',
        'injury_flag', 'user_request', 'schedule_conflict', 'load_spike_acwr'
    ) OR p_adjustment NOT IN (
        'reduce_volume_30', 'reduce_intensity_20', 'skip_session',
        'swap_to_mobility', 'extend_rest_day', 'deload_week'
    ) THEN
        RAISE EXCEPTION 'invalid_training_plan_adjustment' USING ERRCODE = '22023';
    END IF;

    SELECT adaptive_rules INTO v_adaptive_rules
    FROM public.training_plans
    WHERE id = p_plan_id
      AND user_id = p_user_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('plan_found', FALSE, 'sessions_adjusted', 0, 'skipped_sessions', 0);
    END IF;

    IF p_adjustment IN ('skip_session', 'swap_to_mobility', 'extend_rest_day') THEN
        SELECT id INTO v_target_session_id
        FROM public.training_plan_sessions
        WHERE training_plan_id = p_plan_id
          AND user_id = p_user_id
          AND status = 'planned'
          AND planned_date >= p_effective_from
        ORDER BY planned_date ASC, id ASC
        LIMIT 1
        FOR UPDATE;
    END IF;

    UPDATE public.training_plan_sessions AS session
    SET
        planned_exercises = public.adapt_training_plan_session_exercises(
            session.planned_exercises,
            p_adjustment,
            p_reason,
            p_effective_from,
            session.planned_duration_minutes
        ),
        planned_duration_minutes = (
            public.adapt_training_plan_session_exercises(
                session.planned_exercises,
                p_adjustment,
                p_reason,
                p_effective_from,
                session.planned_duration_minutes
            )->>'duration_minutes'
        )::INTEGER,
        session_type = CASE
            WHEN p_adjustment = 'swap_to_mobility'
             AND NOT EXISTS (
                 SELECT 1
                 FROM public.training_plan_sessions AS other_session
                 WHERE other_session.training_plan_id = session.training_plan_id
                   AND other_session.planned_date = session.planned_date
                   AND other_session.session_type = 'mobility'
                   AND other_session.id <> session.id
             ) THEN 'mobility'
            ELSE session.session_type
        END,
        status = CASE
            WHEN p_adjustment IN ('skip_session', 'extend_rest_day') THEN 'skipped'
            ELSE session.status
        END
    WHERE session.training_plan_id = p_plan_id
      AND session.user_id = p_user_id
      AND session.status = 'planned'
      AND session.planned_date >= p_effective_from
      AND (
          p_adjustment NOT IN ('skip_session', 'swap_to_mobility', 'extend_rest_day')
          OR session.id = v_target_session_id
      )
      AND (
          p_adjustment <> 'deload_week'
          OR session.planned_date < p_effective_from + 7
      );
    GET DIAGNOSTICS v_sessions_adjusted = ROW_COUNT;

    IF p_adjustment IN ('skip_session', 'extend_rest_day') THEN
        v_skipped_sessions := v_sessions_adjusted;
    END IF;

    UPDATE public.training_plans
    SET adaptive_rules = COALESCE(v_adaptive_rules, '{}'::JSONB) ||
            jsonb_build_object(p_reason, p_adjustment),
        last_adjusted_at = NOW()
    WHERE id = p_plan_id
      AND user_id = p_user_id;

    RETURN jsonb_build_object(
        'plan_found', TRUE,
        'sessions_adjusted', v_sessions_adjusted,
        'skipped_sessions', v_skipped_sessions
    );
END;
$$;
REVOKE ALL ON FUNCTION public.apply_training_plan_adjustment(UUID, UUID, TEXT, TEXT, DATE)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_training_plan_adjustment(UUID, UUID, TEXT, TEXT, DATE)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Preserve per-measurement deletion as a syncable tombstone. Existing lab
--    clients already send removed scan markers through p_delete_ids, so retain
--    that one replacement contract instead of introducing a competing route.
-- ---------------------------------------------------------------------------
ALTER TABLE public.health_measurements
    ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS deletion_reason TEXT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.health_measurements'::regclass
          AND conname = 'health_measurements_deletion_reason_check'
    ) THEN
        ALTER TABLE public.health_measurements
            ADD CONSTRAINT health_measurements_deletion_reason_check
            CHECK (deletion_reason IS NULL OR deletion_reason IN ('user_deleted', 'source_scan_replaced'));
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_health_measurements_user_tombstones
    ON public.health_measurements (user_id, updated_at DESC)
    WHERE deleted_at IS NOT NULL;

-- Scan reprocessing must not physically erase a marker: an old client then
-- receives the tombstone through normal watermark sync instead of resurrecting
-- a deleted value or retaining it indefinitely.
CREATE OR REPLACE FUNCTION public.save_scan_measurements_atomic(
    p_user_id UUID,
    p_scan_id UUID,
    p_measurements JSONB,
    p_delete_ids UUID[] DEFAULT NULL
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_measurement JSONB;
BEGIN
    IF p_measurements IS NULL OR jsonb_typeof(p_measurements) <> 'array' THEN
        RAISE EXCEPTION 'invalid_measurements_payload' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.medical_scans
        WHERE id = p_scan_id AND user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'invalid_scan_reference' USING ERRCODE = '23503';
    END IF;

    FOR v_measurement IN SELECT value FROM jsonb_array_elements(p_measurements) LOOP
        INSERT INTO public.health_measurements (
            id, user_id, marker_id, value, unit, original_value, original_unit,
            status, reference_range_low, reference_range_high, measured_at,
            source_scan_id, source_type, original_label, confidence,
            manually_verified
        )
        SELECT
            x.id, p_user_id, x.marker_id, x.value, x.unit, x.original_value,
            x.original_unit, x.status, x.reference_range_low,
            x.reference_range_high, x.measured_at, p_scan_id, x.source_type,
            x.original_label, x.confidence, x.manually_verified
        FROM jsonb_populate_record(NULL::public.health_measurements, v_measurement) x
        ON CONFLICT (id) DO UPDATE SET
            marker_id = EXCLUDED.marker_id,
            value = EXCLUDED.value,
            unit = EXCLUDED.unit,
            original_value = EXCLUDED.original_value,
            original_unit = EXCLUDED.original_unit,
            status = EXCLUDED.status,
            reference_range_low = EXCLUDED.reference_range_low,
            reference_range_high = EXCLUDED.reference_range_high,
            measured_at = EXCLUDED.measured_at,
            source_scan_id = EXCLUDED.source_scan_id,
            source_type = EXCLUDED.source_type,
            original_label = EXCLUDED.original_label,
            confidence = EXCLUDED.confidence,
            manually_verified = EXCLUDED.manually_verified
        WHERE public.health_measurements.user_id = p_user_id;
    END LOOP;

    IF p_delete_ids IS NOT NULL AND array_length(p_delete_ids, 1) > 0 THEN
        UPDATE public.health_measurements
        SET deleted_at = COALESCE(deleted_at, NOW()),
            deletion_reason = COALESCE(deletion_reason, 'source_scan_replaced')
        WHERE user_id = p_user_id
          AND source_scan_id = p_scan_id
          AND id = ANY(p_delete_ids);
    END IF;

    RETURN jsonb_array_length(p_measurements);
END;
$$;
REVOKE ALL ON FUNCTION public.save_scan_measurements_atomic(UUID, UUID, JSONB, UUID[])
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.save_scan_measurements_atomic(UUID, UUID, JSONB, UUID[])
    TO service_role;
