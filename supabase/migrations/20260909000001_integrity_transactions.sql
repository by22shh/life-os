-- Both clean installations and previously provisioned databases need the
-- digest-compatible export column. Preserve valid digests on upgrade.
ALTER TABLE public.export_artifacts ALTER COLUMN download_token DROP DEFAULT;
ALTER TABLE public.export_artifacts ALTER COLUMN download_token TYPE TEXT USING download_token::TEXT;
UPDATE public.export_artifacts
SET download_token = 'invalidated-legacy-plaintext-' || md5(random()::TEXT)
WHERE download_token NOT LIKE 'invalidated-legacy-plaintext-%'
  AND download_token !~ '^[0-9a-f]{64}$';

-- This invariant also applies to service-role upserts. Checking an owner in
-- Edge before an upsert alone leaves a race between the read and the write.
CREATE OR REPLACE FUNCTION public.prevent_record_owner_change()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
        RAISE EXCEPTION 'record_owner_immutable' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.prevent_record_owner_change() FROM PUBLIC;

DO $$
DECLARE v_table TEXT;
BEGIN
    -- Ownership never migrates through a regular domain mutation.
    FOR v_table IN SELECT c.table_name FROM information_schema.columns c
      WHERE c.table_schema = 'public' AND c.column_name = 'user_id' AND c.is_nullable = 'NO'
        AND c.table_name NOT IN ('account_deletion_jobs', 'deletion_failures')
        AND EXISTS (SELECT 1 FROM information_schema.tables t
                    WHERE t.table_schema = c.table_schema AND t.table_name = c.table_name
                      AND t.table_type = 'BASE TABLE')
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS prevent_record_owner_change ON public.%I', v_table);
        EXECUTE format('CREATE TRIGGER prevent_record_owner_change BEFORE UPDATE OF user_id ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_record_owner_change()', v_table);
    END LOOP;
END;
$$;

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

-- Lock the privacy row for every write: revocation and an in-flight sync
-- serialize, so a request accepted before revocation cannot recreate data.
CREATE OR REPLACE FUNCTION public.enforce_menstrual_sync_consent()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_local_only BOOLEAN;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.deleted_at IS NOT NULL THEN RETURN NEW; END IF;
    SELECT menstrual_local_only INTO v_local_only FROM public.privacy_settings
      WHERE user_id = NEW.user_id FOR UPDATE;
    IF v_local_only IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'menstrual_cloud_consent_required' USING ERRCODE = '42501';
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.enforce_menstrual_sync_consent() FROM PUBLIC;
DROP TRIGGER IF EXISTS enforce_menstrual_sync_consent ON public.menstrual_logs;
CREATE TRIGGER enforce_menstrual_sync_consent BEFORE INSERT OR UPDATE ON public.menstrual_logs
  FOR EACH ROW EXECUTE FUNCTION public.enforce_menstrual_sync_consent();

CREATE OR REPLACE FUNCTION public.purge_revoked_menstrual_data()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
    IF NEW.menstrual_local_only THEN
        DELETE FROM public.menstrual_logs WHERE user_id = NEW.user_id;
    END IF;
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_revoked_menstrual_data() FROM PUBLIC;
DROP TRIGGER IF EXISTS purge_revoked_menstrual_data ON public.privacy_settings;
CREATE TRIGGER purge_revoked_menstrual_data AFTER INSERT OR UPDATE OF menstrual_local_only
  ON public.privacy_settings FOR EACH ROW EXECUTE FUNCTION public.purge_revoked_menstrual_data();
DELETE FROM public.menstrual_logs m WHERE NOT EXISTS (
    SELECT 1 FROM public.privacy_settings p WHERE p.user_id = m.user_id AND NOT p.menstrual_local_only
);

-- Apply caller-identity fix to databases which already ran the old migration.
CREATE OR REPLACE FUNCTION public.resolve_feature_flags_for_user(p_user_id UUID)
RETURNS TABLE(flag_key TEXT, enabled BOOLEAN, variant TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_auth_uid UUID;
    v_effective_user_id UUID;
    v_caller_role TEXT := COALESCE(current_setting('role', TRUE), current_user);
    v_is_trusted BOOLEAN := FALSE;
BEGIN
    v_auth_uid := auth.uid();

    IF v_auth_uid IS NOT NULL THEN
        SELECT u.id INTO v_effective_user_id
        FROM public.users u
        WHERE u.auth_id = v_auth_uid
        LIMIT 1;
    END IF;

    -- current_user is the function owner in SECURITY DEFINER. The active
    -- role and auth.uid() describe the actual PostgREST caller.
    v_is_trusted := v_caller_role = 'service_role'
        OR (v_caller_role IN ('none', 'postgres') AND session_user = 'postgres');

    IF v_effective_user_id IS NULL THEN
        IF v_is_trusted THEN
            v_effective_user_id := p_user_id;
        ELSE
            RETURN;
        END IF;
    ELSIF p_user_id IS NOT NULL AND p_user_id <> v_effective_user_id THEN
        IF NOT v_is_trusted THEN
            -- Authenticated callers may never resolve another user's flags.
            p_user_id := v_effective_user_id;
        END IF;
    END IF;

    RETURN QUERY
    SELECT
        ff.flag_key,
        COALESCE(
            ufo.enabled,
            ff.enabled,
            (ff.rollout_pct IS NOT NULL
             AND abs(hashtext(v_effective_user_id::TEXT || ff.flag_key)) % 100 < ff.rollout_pct)
        ) AS enabled,
        aba.variant
    FROM feature_flags ff
    LEFT JOIN user_feature_overrides ufo
        ON ufo.flag_id = ff.id AND ufo.user_id = v_effective_user_id
    LEFT JOIN ab_tests abt
        ON abt.flag_id = ff.id AND abt.status = 'running'
    LEFT JOIN ab_test_assignments aba
        ON aba.test_id = abt.id AND aba.user_id = v_effective_user_id
    WHERE ff.expires_at IS NULL OR ff.expires_at > NOW();
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_feature_flags_for_user(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_feature_flags_for_user(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_feature_flags_for_user(UUID) TO service_role;
