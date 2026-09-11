-- Audit remediation 2026-09-11 (part 2):
-- 1. The users deletion-column guard was ineffective: inside a SECURITY
--    DEFINER trigger, `current_user` is the function owner, never the caller.
--    A SECURITY INVOKER trigger sees the actual role performing the write.
-- 2. Atomic multi-statement mutations for workout creation, batch ingredient
--    replacement, batch portion logging, training plan creation and lab
--    marker persistence. PostgREST cannot wrap several statements in one
--    transaction from Edge, so each sequence lives in a single SQL function.

-- ---------------------------------------------------------------------------
-- 1. Users deletion workflow columns: block authenticated clients, allow
--    service_role and SECURITY DEFINER RPCs (delete_user_account).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_user_deletion_columns()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
    IF NEW.deletion_in_progress IS DISTINCT FROM OLD.deletion_in_progress
       OR NEW.deletion_scheduled_at IS DISTINCT FROM OLD.deletion_scheduled_at
       OR NEW.deletion_reason IS DISTINCT FROM OLD.deletion_reason THEN
        IF current_user NOT IN ('postgres', 'supabase_admin', 'service_role') THEN
            RAISE EXCEPTION 'users deletion columns are server-managed'
                USING ERRCODE = '42501';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Atomic workout creation (session + exercises + sets)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_workout_atomic(
    p_user_id UUID,
    p_session JSONB,
    p_exercises JSONB DEFAULT '[]'::JSONB
) RETURNS public.workout_sessions
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_session public.workout_sessions;
    v_exercise JSONB;
    v_set JSONB;
BEGIN
    IF p_session IS NULL OR (p_session->>'id') IS NULL THEN
        RAISE EXCEPTION 'invalid_session_payload' USING ERRCODE = '23502';
    END IF;
    IF p_exercises IS NULL OR jsonb_typeof(p_exercises) <> 'array' THEN
        RAISE EXCEPTION 'invalid_exercises_payload' USING ERRCODE = '22023';
    END IF;
    IF (p_session->>'training_plan_id') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.training_plans
        WHERE id = (p_session->>'training_plan_id')::UUID AND user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'invalid_training_plan_reference' USING ERRCODE = '23503';
    END IF;

    INSERT INTO public.workout_sessions (
        id, user_id, started_at, session_date, started_timezone,
        started_utc_offset_minutes, ended_at, duration_minutes, source,
        workout_type, location, notes, training_plan_id, total_volume,
        total_sets, total_reps, estimated_calories, trimp_score,
        perceived_exertion_rpe, post_feeling
    )
    SELECT
        x.id, p_user_id, x.started_at, x.session_date, x.started_timezone,
        x.started_utc_offset_minutes, x.ended_at, x.duration_minutes, x.source,
        x.workout_type, x.location, x.notes, x.training_plan_id, x.total_volume,
        x.total_sets, x.total_reps, x.estimated_calories, x.trimp_score,
        x.perceived_exertion_rpe, x.post_feeling
    FROM jsonb_populate_record(NULL::public.workout_sessions, p_session) x;

    FOR v_exercise IN SELECT value FROM jsonb_array_elements(p_exercises) LOOP
        IF (v_exercise->>'exercise_id') IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.exercise_catalog c
            WHERE c.id = (v_exercise->>'exercise_id')::UUID
              AND (c.is_custom IS NOT TRUE OR c.created_by = p_user_id)
        ) THEN
            RAISE EXCEPTION 'invalid_exercise_reference' USING ERRCODE = '23503';
        END IF;
        INSERT INTO public.workout_exercises (
            id, session_id, exercise_id, order_in_session, total_sets,
            total_reps, total_volume, max_weight, duration_seconds, notes
        )
        SELECT
            x.id, (p_session->>'id')::UUID, x.exercise_id, x.order_in_session,
            x.total_sets, x.total_reps, x.total_volume, x.max_weight,
            x.duration_seconds, x.notes
        FROM jsonb_populate_record(NULL::public.workout_exercises, v_exercise) x;

        FOR v_set IN
            SELECT value FROM jsonb_array_elements(
                COALESCE(v_exercise->'sets', '[]'::JSONB)
            )
        LOOP
            INSERT INTO public.workout_sets (
                id, exercise_entry_id, user_id, set_number, weight, reps, rpe,
                rest_after_seconds, is_warmup, is_failure, is_dropset
            )
            SELECT
                x.id, (v_exercise->>'id')::UUID, p_user_id, x.set_number,
                x.weight, x.reps, x.rpe, x.rest_after_seconds, x.is_warmup,
                x.is_failure, x.is_dropset
            FROM jsonb_populate_record(NULL::public.workout_sets, v_set) x;
        END LOOP;
    END LOOP;

    SELECT * INTO v_session FROM public.workout_sessions
    WHERE id = (p_session->>'id')::UUID;
    RETURN v_session;
END;
$$;
REVOKE ALL ON FUNCTION public.create_workout_atomic(UUID, JSONB, JSONB)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_workout_atomic(UUID, JSONB, JSONB)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Atomic batch ingredient replacement
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.replace_batch_recipe_ingredients_atomic(
    p_user_id UUID,
    p_batch_id UUID,
    p_ingredients JSONB
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_item JSONB;
BEGIN
    IF p_ingredients IS NULL OR jsonb_typeof(p_ingredients) <> 'array' THEN
        RAISE EXCEPTION 'invalid_ingredients_payload' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.batch_recipes
        WHERE id = p_batch_id AND user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'invalid_batch_reference' USING ERRCODE = '23503';
    END IF;

    DELETE FROM public.batch_recipe_ingredients WHERE batch_recipe_id = p_batch_id;

    FOR v_item IN SELECT value FROM jsonb_array_elements(p_ingredients) LOOP
        IF (v_item->>'user_food_id') IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.user_foods
            WHERE id = (v_item->>'user_food_id')::UUID AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'invalid_user_food_reference' USING ERRCODE = '23503';
        END IF;
        INSERT INTO public.batch_recipe_ingredients (
            id, batch_recipe_id, name, brand, barcode, catalog_item_id,
            user_food_id, weight_g, calories, protein_g, fat_g, carbs_g,
            fiber_g, sugar_g, sodium_mg, sort_order
        )
        SELECT
            x.id, p_batch_id, x.name, x.brand, x.barcode, x.catalog_item_id,
            x.user_food_id, x.weight_g, x.calories, x.protein_g, x.fat_g,
            x.carbs_g, x.fiber_g, x.sugar_g, x.sodium_mg, x.sort_order
        FROM jsonb_populate_record(NULL::public.batch_recipe_ingredients, v_item) x;
    END LOOP;

    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.replace_batch_recipe_ingredients_atomic(UUID, UUID, JSONB)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.replace_batch_recipe_ingredients_atomic(UUID, UUID, JSONB)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Atomic batch portion logging (food log + item + usage metrics)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_batch_portion_atomic(
    p_user_id UUID,
    p_batch_id UUID,
    p_log JSONB,
    p_item JSONB
) RETURNS VOID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_log_id UUID := (p_log->>'id')::UUID;
    v_item_id UUID := (p_item->>'id')::UUID;
BEGIN
    IF v_log_id IS NULL OR v_item_id IS NULL THEN
        RAISE EXCEPTION 'invalid_batch_log_payload' USING ERRCODE = '23502';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.batch_recipes
        WHERE id = p_batch_id AND user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'invalid_batch_reference' USING ERRCODE = '23503';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.food_logs WHERE id = v_log_id AND user_id <> p_user_id
    ) OR EXISTS (
        SELECT 1 FROM public.food_items WHERE id = v_item_id AND user_id <> p_user_id
    ) THEN
        RAISE EXCEPTION 'record_owner_immutable' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.food_logs (
        id, user_id, logged_at, logged_date, logged_timezone,
        logged_utc_offset_minutes, input_method, meal_type, context,
        calories, protein_g, fat_g, carbs_g, fiber_g, needs_review,
        user_corrected
    )
    SELECT
        x.id, p_user_id, x.logged_at, x.logged_date, x.logged_timezone,
        x.logged_utc_offset_minutes, x.input_method, x.meal_type, x.context,
        x.calories, x.protein_g, x.fat_g, x.carbs_g, x.fiber_g, x.needs_review,
        x.user_corrected
    FROM jsonb_populate_record(NULL::public.food_logs, p_log) x
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.food_items (
        id, food_log_id, user_id, name, batch_recipe_id, weight_g, calories,
        protein_g, fat_g, carbs_g, fiber_g, detected_by_ai, user_adjusted
    )
    SELECT
        x.id, x.food_log_id, p_user_id, x.name, x.batch_recipe_id, x.weight_g,
        x.calories, x.protein_g, x.fat_g, x.carbs_g, x.fiber_g,
        x.detected_by_ai, x.user_adjusted
    FROM jsonb_populate_record(NULL::public.food_items, p_item) x
    ON CONFLICT (id) DO NOTHING;

    UPDATE public.batch_recipes b
    SET times_used = usage.usage_count,
        last_used_at = usage.last_used_at
    FROM (
        SELECT COUNT(*)::INTEGER AS usage_count, MAX(l.logged_at) AS last_used_at
        FROM public.food_items i
        JOIN public.food_logs l ON l.id = i.food_log_id
        WHERE i.user_id = p_user_id
          AND i.batch_recipe_id = p_batch_id
          AND l.user_id = p_user_id
          AND l.deleted_at IS NULL
    ) usage
    WHERE b.id = p_batch_id AND b.user_id = p_user_id;
END;
$$;
REVOKE ALL ON FUNCTION public.log_batch_portion_atomic(UUID, UUID, JSONB, JSONB)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_batch_portion_atomic(UUID, UUID, JSONB, JSONB)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Atomic training plan creation (plan + planned sessions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_training_plan_atomic(
    p_user_id UUID,
    p_plan JSONB,
    p_sessions JSONB DEFAULT '[]'::JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_plan_id UUID := (p_plan->>'id')::UUID;
    v_session JSONB;
BEGIN
    IF v_plan_id IS NULL THEN
        RAISE EXCEPTION 'invalid_plan_payload' USING ERRCODE = '23502';
    END IF;
    IF p_sessions IS NULL OR jsonb_typeof(p_sessions) <> 'array' THEN
        RAISE EXCEPTION 'invalid_plan_sessions_payload' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.training_plans (
        id, user_id, name, goal, status, start_date, end_date, duration_weeks,
        days_per_week, current_week, ai_generated, plan_json, adaptive_rules
    )
    SELECT
        x.id, p_user_id, x.name, x.goal, x.status, x.start_date, x.end_date,
        x.duration_weeks, x.days_per_week, x.current_week, x.ai_generated,
        x.plan_json, x.adaptive_rules
    FROM jsonb_populate_record(NULL::public.training_plans, p_plan) x;

    FOR v_session IN SELECT value FROM jsonb_array_elements(p_sessions) LOOP
        INSERT INTO public.training_plan_sessions (
            id, training_plan_id, user_id, planned_date, session_type,
            planned_duration_minutes, planned_exercises, status
        )
        SELECT
            x.id, v_plan_id, p_user_id, x.planned_date, x.session_type,
            x.planned_duration_minutes, x.planned_exercises, x.status
        FROM jsonb_populate_record(NULL::public.training_plan_sessions, v_session) x;
    END LOOP;

    RETURN v_plan_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_training_plan_atomic(UUID, JSONB, JSONB)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_training_plan_atomic(UUID, JSONB, JSONB)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Atomic lab marker persistence (upserts + stale removal)
-- ---------------------------------------------------------------------------
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
        DELETE FROM public.health_measurements
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
