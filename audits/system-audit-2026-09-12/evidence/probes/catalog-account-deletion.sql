\set ON_ERROR_STOP on
-- LOCAL database only; fresh fixtures, SQL deletion contained in subtransactions,
-- outer ROLLBACK. No Auth or storage API is invoked.
BEGIN;
DO $$
DECLARE a UUID := gen_random_uuid(); b UUID := gen_random_uuid();
        ua UUID; ub UUID; failed BOOLEAN; error_text TEXT;
BEGIN
  INSERT INTO auth.users (id,email,aud,role) VALUES
    (a,a::TEXT || '@audit.invalid','authenticated','authenticated'),
    (b,b::TEXT || '@audit.invalid','authenticated','authenticated');
  SELECT id INTO ua FROM public.users WHERE auth_id = a;
  SELECT id INTO ub FROM public.users WHERE auth_id = b;
  INSERT INTO public.food_catalog_items
    (provider,created_by_user_id,name,calories_per_100g,protein_per_100g,fat_per_100g,carbs_per_100g)
  VALUES ('lifeos_label_ocr',ua,'Audit private food',100,1,2,3);
  failed := FALSE;
  BEGIN
    PERFORM public.delete_user_account(ua);
  EXCEPTION WHEN insufficient_privilege THEN
    failed := TRUE; error_text := SQLERRM;
  END;
  IF NOT failed OR error_text <> 'catalog_owner_immutable' THEN
    RAISE EXCEPTION 'food deletion finding not reproduced: failed=%, error=%',failed,error_text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = ua) THEN
    RAISE EXCEPTION 'unexpected fixture removal';
  END IF;
  RAISE NOTICE 'CONFIRMED: custom food blocks account SQL erasure: %',error_text;

  INSERT INTO public.exercise_catalog (name,category,is_custom,created_by)
  VALUES ('Audit private exercise','strength',TRUE,ub);
  failed := FALSE; error_text := NULL;
  BEGIN
    PERFORM public.delete_user_account(ub);
  EXCEPTION WHEN insufficient_privilege THEN
    failed := TRUE; error_text := SQLERRM;
  END;
  IF NOT failed OR error_text <> 'catalog_owner_immutable' THEN
    RAISE EXCEPTION 'exercise deletion finding not reproduced: failed=%, error=%',failed,error_text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = ub) THEN
    RAISE EXCEPTION 'unexpected fixture removal';
  END IF;
  RAISE NOTICE 'CONFIRMED: custom exercise blocks account SQL erasure: %',error_text;
END;
$$;
ROLLBACK;
\echo AUDIT_CATALOG_ACCOUNT_DELETION_PROBE_ROLLED_BACK
