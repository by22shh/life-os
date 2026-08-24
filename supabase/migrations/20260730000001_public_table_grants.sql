-- Restore the PostgREST table privileges that are required by the authenticated
-- sync client and by Edge Functions using the service-role client.
--
-- RLS remains the authorization boundary for authenticated users. Anonymous
-- clients intentionally receive no table DML privileges.

GRANT USAGE ON SCHEMA public TO authenticated, service_role;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon;

DO $$
DECLARE
    table_record RECORD;
BEGIN
    FOR table_record IN
        SELECT c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('r', 'p')
    LOOP
        EXECUTE format(
            'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO service_role',
            table_record.table_name
        );
    END LOOP;
END;
$$;

-- Edge Functions also query derived public views through PostgREST.
DO $$
DECLARE
    view_record RECORD;
BEGIN
    FOR view_record IN
        SELECT c.relname AS view_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relkind IN ('v', 'm')
    LOOP
        EXECUTE format(
            'GRANT SELECT ON TABLE public.%I TO service_role',
            view_record.view_name
        );
    END LOOP;
END;
$$;

-- Authenticated users may exercise only operations that are already protected
-- by an explicit RLS policy. Deny-only policies are harmless here: RLS still
-- rejects the operation, while PostgREST can return the intended policy result
-- instead of failing early with "permission denied for table".
DO $$
DECLARE
    policy_record RECORD;
    privilege_name TEXT;
BEGIN
    FOR policy_record IN
        SELECT DISTINCT
            p.tablename,
            p.cmd
        FROM pg_policies p
        JOIN pg_class c
          ON c.relname = p.tablename
        JOIN pg_namespace n
          ON n.oid = c.relnamespace
         AND n.nspname = p.schemaname
        WHERE p.schemaname = 'public'
          AND c.relkind IN ('r', 'p')
          AND (
              p.roles = '{public}'::name[]
              OR 'authenticated'::name = ANY(p.roles)
          )
          AND p.tablename NOT IN (
              'deletion_audit_log',
              'service_role_audit_log'
          )
    LOOP
        IF policy_record.cmd = 'ALL' THEN
            EXECUTE format(
                'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.%I TO authenticated',
                policy_record.tablename
            );
        ELSE
            privilege_name := policy_record.cmd;
            EXECUTE format(
                'GRANT %s ON TABLE public.%I TO authenticated',
                privilege_name,
                policy_record.tablename
            );
        END IF;
    END LOOP;
END;
$$;

-- Shared reference data is pulled directly by the iOS sync engine. These
-- tables are read-only for authenticated clients.
GRANT SELECT ON TABLE
    public.food_catalog_items,
    public.supplement_catalog,
    public.exercise_catalog,
    public.health_marker_catalog
TO authenticated;

-- These tables contain service-only audit data even though RLS is enabled.
REVOKE ALL ON TABLE public.deletion_audit_log FROM anon, authenticated;
REVOKE ALL ON TABLE public.service_role_audit_log FROM anon, authenticated;

-- service_role owns the only identity-backed public table today. Grant sequence
-- access explicitly and protect future tables created by the postgres migration
-- role from repeating the same service-role outage.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO service_role;
