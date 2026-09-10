#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT_ID="$(
  sed -n 's/^[[:space:]]*project_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    supabase/config.toml |
    head -n 1
)"

if [[ -z "$PROJECT_ID" ]]; then
  echo "Unable to resolve project_id from supabase/config.toml" >&2
  exit 1
fi

DB_CONTAINER="${SUPABASE_DB_CONTAINER:-supabase_db_${PROJECT_ID}}"
if ! docker inspect "$DB_CONTAINER" >/dev/null 2>&1; then
  echo "Supabase database container is not running: $DB_CONTAINER" >&2
  exit 1
fi

docker exec -i "$DB_CONTAINER" psql \
  --username postgres \
  --dbname postgres \
  --set ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    missing_tables TEXT;
BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY c.relname)
      INTO missing_tables
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'p')
       AND NOT (
           has_table_privilege('service_role', c.oid, 'SELECT')
           AND has_table_privilege('service_role', c.oid, 'INSERT')
           AND has_table_privilege('service_role', c.oid, 'UPDATE')
           AND has_table_privilege('service_role', c.oid, 'DELETE')
       );

    IF missing_tables IS NOT NULL THEN
        RAISE EXCEPTION
            'service_role is missing CRUD privileges on: %',
            missing_tables;
    END IF;
END;
$$;

DO $$
DECLARE
    unexpected_tables TEXT;
BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY c.relname)
      INTO unexpected_tables
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'p')
       AND (
           has_table_privilege('anon', c.oid, 'SELECT')
           OR has_table_privilege('anon', c.oid, 'INSERT')
           OR has_table_privilege('anon', c.oid, 'UPDATE')
           OR has_table_privilege('anon', c.oid, 'DELETE')
       );

    IF unexpected_tables IS NOT NULL THEN
        RAISE EXCEPTION
            'anon unexpectedly has table DML privileges on: %',
            unexpected_tables;
    END IF;
END;
$$;

DO $$
DECLARE
    missing_views TEXT;
BEGIN
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY c.relname)
      INTO missing_views
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('v', 'm')
       AND NOT has_table_privilege('service_role', c.oid, 'SELECT');

    IF missing_views IS NOT NULL THEN
        RAISE EXCEPTION
            'service_role is missing SELECT privileges on views: %',
            missing_views;
    END IF;
END;
$$;

DO $$
DECLARE
    policy_record RECORD;
    required_privilege TEXT;
BEGIN
    FOR policy_record IN
        SELECT DISTINCT p.tablename, p.cmd
          FROM pg_policies p
          JOIN pg_class c
            ON c.relname = p.tablename
          JOIN pg_namespace n
            ON n.oid = c.relnamespace
           AND n.nspname = p.schemaname
         WHERE p.schemaname = 'public'
           AND c.relkind IN ('r', 'p')
           AND NOT (p.cmd = 'DELETE' AND p.qual = 'false')
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
            IF NOT (
                has_table_privilege(
                    'authenticated',
                    format('public.%I', policy_record.tablename),
                    'SELECT'
                )
                AND has_table_privilege(
                    'authenticated',
                    format('public.%I', policy_record.tablename),
                    'INSERT'
                )
                AND has_table_privilege(
                    'authenticated',
                    format('public.%I', policy_record.tablename),
                    'UPDATE'
                )
                AND has_table_privilege(
                    'authenticated',
                    format('public.%I', policy_record.tablename),
                    'DELETE'
                )
            ) THEN
                RAISE EXCEPTION
                    'authenticated lacks CRUD required by ALL policy on public.%',
                    policy_record.tablename;
            END IF;
        ELSE
            required_privilege := policy_record.cmd;
            IF NOT has_table_privilege(
                'authenticated',
                format('public.%I', policy_record.tablename),
                required_privilege
            ) THEN
                RAISE EXCEPTION
                    'authenticated lacks % required by policy on public.%',
                    required_privilege,
                    policy_record.tablename;
            END IF;
        END IF;
    END LOOP;
END;
$$;

DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'food_catalog_items',
        'supplement_catalog',
        'exercise_catalog',
        'health_marker_catalog'
    ]
    LOOP
        IF NOT has_table_privilege(
            'authenticated',
            format('public.%I', table_name),
            'SELECT'
        ) THEN
            RAISE EXCEPTION
                'authenticated lacks read-only catalog access on public.%',
                table_name;
        END IF;
    END LOOP;
END;
$$;

DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'deletion_audit_log',
        'service_role_audit_log'
    ]
    LOOP
        IF (
            has_table_privilege(
                'authenticated',
                format('public.%I', table_name),
                'SELECT'
            )
            OR has_table_privilege(
                'authenticated',
                format('public.%I', table_name),
                'INSERT'
            )
            OR has_table_privilege(
                'authenticated',
                format('public.%I', table_name),
                'UPDATE'
            )
            OR has_table_privilege(
                'authenticated',
                format('public.%I', table_name),
                'DELETE'
            )
        ) THEN
            RAISE EXCEPTION
                'authenticated unexpectedly has service-only access on public.%',
                table_name;
        END IF;
    END LOOP;
END;
$$;

SELECT
    COUNT(*) AS public_tables_checked,
    COUNT(*) FILTER (
        WHERE has_table_privilege('authenticated', c.oid, 'SELECT')
    ) AS authenticated_readable_tables,
    COUNT(*) FILTER (
        WHERE has_table_privilege('service_role', c.oid, 'SELECT')
          AND has_table_privilege('service_role', c.oid, 'INSERT')
          AND has_table_privilege('service_role', c.oid, 'UPDATE')
          AND has_table_privilege('service_role', c.oid, 'DELETE')
    ) AS service_role_crud_tables
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('r', 'p');

SELECT
    COUNT(*) AS public_views_checked,
    COUNT(*) FILTER (
        WHERE has_table_privilege('service_role', c.oid, 'SELECT')
    ) AS service_role_readable_views
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind IN ('v', 'm');
SQL

echo "Supabase public table grant regression check passed."
