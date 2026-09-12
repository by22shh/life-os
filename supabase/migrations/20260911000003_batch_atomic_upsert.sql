-- Audit hardening (2026-09-11, part 3):
-- 1. Atomic batch recipe create/update (parent + ingredients in one
--    transaction) so a failed ingredient write can no longer leave an empty
--    batch row or divergent totals.
-- 2. Catalog-item references are validated against shared rows or the
--    caller's own rows in every RPC that can persist food_items or batch
--    ingredients.
-- 3. patch_workout_atomic validates exercise catalog visibility like
--    create_workout_atomic already does.
-- 4. exercise_catalog identity/owner immutability backstop.

-- ---------------------------------------------------------------------------
-- 1. Atomic batch recipe upsert (parent + ingredients)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_batch_recipe_atomic(
    p_user_id UUID,
    p_batch JSONB,
    p_ingredients JSONB DEFAULT NULL
) RETURNS public.batch_recipes
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
    v_batch_id UUID := (p_batch->>'id')::UUID;
    v_owner UUID;
    v_batch public.batch_recipes;
    v_item JSONB;
BEGIN
    IF v_batch_id IS NULL THEN
        RAISE EXCEPTION 'invalid_batch_payload' USING ERRCODE = '23502';
    END IF;
    IF p_ingredients IS NOT NULL AND jsonb_typeof(p_ingredients) <> 'array' THEN
        RAISE EXCEPTION 'invalid_ingredients_payload' USING ERRCODE = '22023';
    END IF;

    SELECT user_id INTO v_owner
    FROM public.batch_recipes
    WHERE id = v_batch_id
    FOR UPDATE;

    IF v_owner IS NOT NULL AND v_owner <> p_user_id THEN
        RAISE EXCEPTION 'forbidden_id_ownership' USING ERRCODE = '42501';
    END IF;

    IF v_owner IS NULL THEN
        INSERT INTO public.batch_recipes (
            id, user_id, name, description, image_url, cooked_at,
            total_weight_g, total_portions, total_calories, total_protein_g,
            total_fat_g, total_carbs_g, total_fiber_g, archived
        )
        SELECT
            v_batch_id, p_user_id, x.name, x.description, x.image_url, x.cooked_at,
            x.total_weight_g, x.total_portions, x.total_calories, x.total_protein_g,
            x.total_fat_g, x.total_carbs_g, x.total_fiber_g, COALESCE(x.archived, FALSE)
        FROM jsonb_populate_record(NULL::public.batch_recipes, p_batch) x;
    ELSE
        UPDATE public.batch_recipes AS b
        SET name = x.name,
            description = x.description,
            image_url = x.image_url,
            cooked_at = x.cooked_at,
            total_weight_g = x.total_weight_g,
            total_portions = x.total_portions,
            total_calories = x.total_calories,
            total_protein_g = x.total_protein_g,
            total_fat_g = x.total_fat_g,
            total_carbs_g = x.total_carbs_g,
            total_fiber_g = x.total_fiber_g,
            archived = COALESCE(x.archived, b.archived)
        FROM jsonb_populate_record(NULL::public.batch_recipes, p_batch) x
        WHERE b.id = v_batch_id
          AND b.user_id = p_user_id
          AND b.deleted_at IS NULL;
    END IF;

    IF p_ingredients IS NOT NULL THEN
        DELETE FROM public.batch_recipe_ingredients WHERE batch_recipe_id = v_batch_id;
        FOR v_item IN SELECT value FROM jsonb_array_elements(p_ingredients) LOOP
            IF (v_item->>'user_food_id') IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.user_foods
                WHERE id = (v_item->>'user_food_id')::UUID AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'invalid_user_food_reference' USING ERRCODE = '23503';
            END IF;
            IF (v_item->>'catalog_item_id') IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.food_catalog_items
                WHERE id = (v_item->>'catalog_item_id')::UUID
                  AND (created_by_user_id IS NULL OR created_by_user_id = p_user_id)
            ) THEN
                RAISE EXCEPTION 'invalid_catalog_item_reference' USING ERRCODE = '23503';
            END IF;
            INSERT INTO public.batch_recipe_ingredients (
                id, batch_recipe_id, name, brand, barcode, catalog_item_id,
                user_food_id, weight_g, calories, protein_g, fat_g, carbs_g,
                fiber_g, sugar_g, sodium_mg, sort_order
            )
            SELECT
                x.id, v_batch_id, x.name, x.brand, x.barcode, x.catalog_item_id,
                x.user_food_id, x.weight_g, x.calories, x.protein_g, x.fat_g,
                x.carbs_g, x.fiber_g, x.sugar_g, x.sodium_mg, x.sort_order
            FROM jsonb_populate_record(NULL::public.batch_recipe_ingredients, v_item) x;
        END LOOP;
    END IF;

    SELECT * INTO v_batch FROM public.batch_recipes WHERE id = v_batch_id;
    RETURN v_batch;
END;
$$;
REVOKE ALL ON FUNCTION public.upsert_batch_recipe_atomic(UUID, JSONB, JSONB)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_batch_recipe_atomic(UUID, JSONB, JSONB)
    TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Replace ingredients with catalog ownership validation
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
        IF (v_item->>'catalog_item_id') IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.food_catalog_items
            WHERE id = (v_item->>'catalog_item_id')::UUID
              AND (created_by_user_id IS NULL OR created_by_user_id = p_user_id)
        ) THEN
            RAISE EXCEPTION 'invalid_catalog_item_reference' USING ERRCODE = '23503';
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
-- 3. patch_food_log_atomic with catalog ownership validation
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.patch_food_log_atomic(
    p_user_id UUID, p_log_id UUID, p_updates JSONB, p_items JSONB DEFAULT NULL
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_log public.food_logs; v_item JSONB;
BEGIN
    SELECT * INTO v_log FROM public.food_logs
      WHERE id = p_log_id AND user_id = p_user_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    v_log := jsonb_populate_record(v_log, p_updates);
    UPDATE public.food_logs SET
      logged_at = v_log.logged_at, logged_date = v_log.logged_date,
      meal_type = v_log.meal_type, context = v_log.context, user_notes = v_log.user_notes,
      calories = v_log.calories, protein_g = v_log.protein_g, fat_g = v_log.fat_g,
      carbs_g = v_log.carbs_g, fiber_g = v_log.fiber_g,
      user_corrected = v_log.user_corrected, needs_review = v_log.needs_review,
      ai_confidence = v_log.ai_confidence
      WHERE id = p_log_id AND user_id = p_user_id;
    IF p_items IS NOT NULL THEN
        IF jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'invalid_items'; END IF;
        DELETE FROM public.food_items WHERE food_log_id = p_log_id AND user_id = p_user_id;
        FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
            IF (v_item->>'user_food_id') IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.user_foods WHERE id = (v_item->>'user_food_id')::UUID AND user_id = p_user_id
            ) THEN RAISE EXCEPTION 'invalid_user_food_reference' USING ERRCODE = '23503'; END IF;
            IF (v_item->>'batch_recipe_id') IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.batch_recipes WHERE id = (v_item->>'batch_recipe_id')::UUID AND user_id = p_user_id
            ) THEN RAISE EXCEPTION 'invalid_batch_recipe_reference' USING ERRCODE = '23503'; END IF;
            IF (v_item->>'catalog_item_id') IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.food_catalog_items
                WHERE id = (v_item->>'catalog_item_id')::UUID
                  AND (created_by_user_id IS NULL OR created_by_user_id = p_user_id)
            ) THEN RAISE EXCEPTION 'invalid_catalog_item_reference' USING ERRCODE = '23503'; END IF;
            INSERT INTO public.food_items (
              id, food_log_id, user_id, name, brand, barcode, catalog_item_id, user_food_id,
              batch_recipe_id, weight_g, calories, protein_g, fat_g, carbs_g, fiber_g,
              confidence, detected_by_ai, user_adjusted
            ) SELECT x.id, p_log_id, p_user_id, x.name, x.brand, x.barcode,
              x.catalog_item_id, x.user_food_id, x.batch_recipe_id, x.weight_g,
              x.calories, x.protein_g, x.fat_g, x.carbs_g, x.fiber_g,
              x.confidence, x.detected_by_ai, x.user_adjusted
            FROM jsonb_populate_record(NULL::public.food_items, v_item) x;
        END LOOP;
    END IF;
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.patch_food_log_atomic(UUID, UUID, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.patch_food_log_atomic(UUID, UUID, JSONB, JSONB) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. patch_workout_atomic with exercise catalog visibility
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.patch_workout_atomic(
    p_user_id UUID, p_session_id UUID, p_updates JSONB, p_exercises JSONB DEFAULT NULL
) RETURNS BOOLEAN LANGUAGE plpgsql SECURITY INVOKER SET search_path = public AS $$
DECLARE v_session public.workout_sessions; v_exercise JSONB; v_set JSONB;
BEGIN
    SELECT * INTO v_session FROM public.workout_sessions
      WHERE id = p_session_id AND user_id = p_user_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    v_session := jsonb_populate_record(v_session, p_updates);
    IF v_session.training_plan_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.training_plans WHERE id = v_session.training_plan_id AND user_id = p_user_id
    ) THEN RAISE EXCEPTION 'invalid_training_plan_reference' USING ERRCODE = '23503'; END IF;
    UPDATE public.workout_sessions SET
      started_at = v_session.started_at, ended_at = v_session.ended_at,
      session_date = v_session.session_date, workout_type = v_session.workout_type,
      location = v_session.location, started_timezone = v_session.started_timezone,
      notes = v_session.notes, training_plan_id = v_session.training_plan_id,
      started_utc_offset_minutes = v_session.started_utc_offset_minutes,
      duration_minutes = v_session.duration_minutes, estimated_calories = v_session.estimated_calories,
      perceived_exertion_rpe = v_session.perceived_exertion_rpe, post_feeling = v_session.post_feeling,
      trimp_score = v_session.trimp_score, total_sets = v_session.total_sets,
      total_reps = v_session.total_reps, total_volume = v_session.total_volume, source = v_session.source
      WHERE id = p_session_id AND user_id = p_user_id;
    IF p_exercises IS NOT NULL THEN
        IF jsonb_typeof(p_exercises) <> 'array' THEN RAISE EXCEPTION 'invalid_exercises'; END IF;
        DELETE FROM public.workout_exercises WHERE session_id = p_session_id;
        FOR v_exercise IN SELECT value FROM jsonb_array_elements(p_exercises) LOOP
            IF (v_exercise->>'exercise_id') IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM public.exercise_catalog c
                WHERE c.id = (v_exercise->>'exercise_id')::UUID
                  AND (c.is_custom IS NOT TRUE OR c.created_by = p_user_id)
            ) THEN RAISE EXCEPTION 'invalid_exercise_reference' USING ERRCODE = '23503'; END IF;
            INSERT INTO public.workout_exercises (
              id, session_id, exercise_id, order_in_session, total_sets, total_reps,
              total_volume, max_weight, duration_seconds, notes
            ) SELECT x.id, p_session_id, x.exercise_id, x.order_in_session, x.total_sets,
              x.total_reps, x.total_volume, x.max_weight, x.duration_seconds, x.notes
            FROM jsonb_populate_record(NULL::public.workout_exercises, v_exercise) x;
            FOR v_set IN SELECT value FROM jsonb_array_elements(v_exercise->'sets') LOOP
                INSERT INTO public.workout_sets (
                  id, exercise_entry_id, user_id, set_number, weight, reps, rpe,
                  rest_after_seconds, is_warmup, is_failure, is_dropset
                ) SELECT x.id, (v_exercise->>'id')::UUID, p_user_id, x.set_number,
                  x.weight, x.reps, x.rpe, x.rest_after_seconds, x.is_warmup, x.is_failure, x.is_dropset
                FROM jsonb_populate_record(NULL::public.workout_sets, v_set) x;
            END LOOP;
        END LOOP;
    END IF;
    RETURN TRUE;
END;
$$;
REVOKE ALL ON FUNCTION public.patch_workout_atomic(UUID, UUID, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.patch_workout_atomic(UUID, UUID, JSONB, JSONB) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. exercise_catalog identity/owner immutability
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prevent_exercise_catalog_identity_change()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM OLD.id THEN
        RAISE EXCEPTION 'catalog_identity_immutable' USING ERRCODE = '42501';
    END IF;
    IF NEW.created_by IS DISTINCT FROM OLD.created_by THEN
        RAISE EXCEPTION 'catalog_owner_immutable' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_exercise_catalog_identity_change() FROM PUBLIC;

DROP TRIGGER IF EXISTS prevent_exercise_catalog_identity_change ON public.exercise_catalog;
CREATE TRIGGER prevent_exercise_catalog_identity_change
    BEFORE UPDATE ON public.exercise_catalog
    FOR EACH ROW EXECUTE FUNCTION public.prevent_exercise_catalog_identity_change();
