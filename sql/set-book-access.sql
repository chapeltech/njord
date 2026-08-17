-- Variable required from psql: book_id
--
-- Each Book has three fixed NOLOGIN capability roles. Human roles are only
-- members, so changing a user's control-catalogue membership can atomically
-- change the effective direct-SQL and PostgREST authorization as well.
\set ON_ERROR_STOP on

BEGIN;

-- Never let a correctly quoted but incorrectly selected Book id install one
-- database's cluster capability roles on another database.  Keep this guard
-- ahead of every role or ACL mutation so failure is side-effect free.
SELECT format(
    'DO $block$ BEGIN '
    'IF current_database() IS DISTINCT FROM %L THEN '
    'RAISE EXCEPTION ''Book %s does not belong in database %%'', current_database() '
    'USING ERRCODE = ''P0001'', DETAIL = ''WRONG_BOOK_DATABASE''; '
    'END IF; '
    'IF to_regclass(''public.books'') IS NULL THEN '
    'RAISE EXCEPTION ''database %% is not a Book database'', current_database() '
    'USING ERRCODE = ''P0001'', DETAIL = ''WRONG_BOOK_DATABASE''; '
    'END IF; '
    'IF (SELECT count(*) FROM public.books WHERE id = %L) <> 1 '
    'OR (SELECT count(*) FROM public.books) <> 1 THEN '
    'RAISE EXCEPTION ''database %% does not contain exactly Book %s'', current_database() '
    'USING ERRCODE = ''P0001'', DETAIL = ''WRONG_BOOK_DATABASE''; '
    'END IF; END $block$',
    :'book_id', :'book_id', :'book_id', :'book_id'
) \gexec

CREATE TEMP TABLE book_access_roles (
    access_level VARCHAR PRIMARY KEY,
    database_role NAME NOT NULL UNIQUE
) ON COMMIT DROP;

INSERT INTO book_access_roles
SELECT access_level, format(
    'njord_%s_%s_%s',
    left(:'book_id', 20), substr(md5(:'book_id'), 1, 24), access_level
)::NAME
FROM unnest(ARRAY['ro', 'rw', 'admin']) AS access_level;

-- A Book creation and its first ACL mutation can race. PostgreSQL role DDL is
-- transactional; the advisory lock makes first-time creation deterministic.
SELECT pg_advisory_xact_lock(
    hashtextextended('njord-book-access:' || :'book_id', 0)
);

SELECT format(
    'CREATE ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE '
    'NOREPLICATION NOBYPASSRLS',
    access.database_role
)
FROM book_access_roles AS access
LEFT JOIN pg_roles AS existing ON existing.rolname = access.database_role
WHERE existing.oid IS NULL
\gexec

SELECT format(
    'DO $block$ BEGIN RAISE EXCEPTION %L; END $block$',
    'unsafe Book capability role: ' || existing.rolname
)
FROM book_access_roles AS access
JOIN pg_roles AS existing ON existing.rolname = access.database_role
WHERE existing.rolcanlogin OR existing.rolinherit OR existing.rolsuper
   OR existing.rolcreatedb
   OR existing.rolcreaterole OR existing.rolreplication
   OR existing.rolbypassrls
   OR EXISTS (
       SELECT 1
       FROM pg_auth_members AS membership
       WHERE membership.member = existing.oid
   )
\gexec

-- Reinstall capability profiles from a known-empty state so rerunning the
-- product loader after an API change cannot accumulate stale grants.
SELECT format(privilege.statement, access.database_role)
FROM book_access_roles AS access
CROSS JOIN (VALUES
    ('REVOKE ALL PRIVILEGES ON DATABASE ' || quote_ident(:'book_id') || ' FROM %I'),
    ('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public, njord, presentation FROM %I'),
    ('REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM %I'),
    ('REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public, njord, api, presentation FROM %I'),
    ('REVOKE ALL PRIVILEGES ON ALL PROCEDURES IN SCHEMA public, njord FROM %I'),
    ('REVOKE ALL PRIVILEGES ON SCHEMA public, njord, api, presentation FROM %I')
) AS privilege(statement)
\gexec

SELECT format(
    'REVOKE ALL PRIVILEGES (%s) ON TABLE %I.%I FROM %I',
    string_agg(format('%I', attribute.attname), ', ' ORDER BY attribute.attnum),
    namespace.nspname, relation.relname, access.database_role
)
FROM book_access_roles AS access
CROSS JOIN pg_class AS relation
JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
JOIN pg_attribute AS attribute ON attribute.attrelid = relation.oid
WHERE namespace.nspname IN ('public', 'njord', 'presentation')
  AND relation.relkind IN ('r', 'p', 'v', 'm', 'f')
  AND attribute.attnum > 0
  AND NOT attribute.attisdropped
GROUP BY access.database_role, namespace.nspname, relation.relname
\gexec

-- PostgreSQL grants CONNECT and routine EXECUTE to PUBLIC by default. Named
-- profiles must not be broadened by those ambient privileges.
REVOKE CONNECT ON DATABASE :"book_id" FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public, njord, api, presentation
    FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public, njord FROM PUBLIC;

SELECT format(privilege.statement, access.database_role)
FROM book_access_roles AS access
CROSS JOIN (VALUES
    ('GRANT CONNECT ON DATABASE ' || quote_ident(:'book_id') || ' TO %I'),
    ('GRANT USAGE ON SCHEMA public, njord, api, presentation TO %I'),
    ('GRANT SELECT ON ALL TABLES IN SCHEMA public, presentation TO %I')
) AS privilege(statement)
\gexec

-- Stable API functions execute as the caller and compose these internal views.
-- Grant the views explicitly rather than all future tables in njord.
SELECT format(
    'GRANT SELECT ON TABLE %I.%I TO %I',
    namespace.nspname, relation.relname, access.database_role
)
FROM book_access_roles AS access
CROSS JOIN pg_class AS relation
JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
WHERE namespace.nspname = 'njord'
  AND relation.relkind IN ('v', 'm')
\gexec

-- RO includes every stable or immutable reader, including api.adapter_status,
-- report aggregates, and SQL-owned presentation functions.
SELECT format(
    'GRANT EXECUTE ON FUNCTION %I.%I(%s) TO %I',
    namespace.nspname,
    procedure.proname,
    pg_get_function_identity_arguments(procedure.oid),
    access.database_role
)
FROM book_access_roles AS access
CROSS JOIN pg_proc AS procedure
JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
WHERE namespace.nspname IN ('public', 'njord', 'api', 'presentation')
  AND procedure.prokind IN ('f', 'a')
  AND procedure.provolatile IN ('i', 's')
\gexec

SELECT format(privilege.statement, access.database_role)
FROM book_access_roles AS access
CROSS JOIN (VALUES
    ('GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO %I'),
    ('GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public, njord, api, presentation TO %I'),
    ('GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public, njord TO %I')
) AS privilege(statement)
WHERE access.access_level IN ('rw', 'admin')
\gexec

SELECT format(
    'GRANT INSERT, UPDATE, DELETE ON TABLE public.%I TO %I',
    capability.table_name, access.database_role
)
FROM book_access_roles AS access
CROSS JOIN njord.rw_table_catalog AS capability
WHERE access.access_level = 'rw'
\gexec

-- RW may add accounts and organize or annotate existing ones, but cannot
-- change account identity, class, commodity, kind, or placeholder status.
SELECT format(privilege.statement, access.database_role)
FROM book_access_roles AS access
CROSS JOIN (VALUES
    ('GRANT INSERT ON TABLE public.accts TO %I'),
    ('GRANT UPDATE (name, parent_id, pretax, default_business_use_percent, comment) ON TABLE public.accts TO %I'),
    ('GRANT UPDATE (id) ON TABLE public.books TO %I')
) AS privilege(statement)
WHERE access.access_level = 'rw'
\gexec

SELECT format(privilege.statement, access.database_role)
FROM book_access_roles AS access
CROSS JOIN (VALUES
    ('GRANT UPDATE ON ALL SEQUENCES IN SCHEMA public TO %I'),
    ('GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %I')
) AS privilege(statement)
WHERE access.access_level = 'admin'
\gexec

-- Book identity, jurisdiction configuration, lifecycle, reporting currency,
-- and physical deletion remain Admin-only. The stable deletion preflight is
-- explicitly removed from RO as well as RW.
SELECT format(
    'REVOKE EXECUTE ON FUNCTION %I.%I(%s) FROM %I',
    namespace.nspname,
    procedure.proname,
    pg_get_function_identity_arguments(procedure.oid),
    access.database_role
)
FROM book_access_roles AS access
CROSS JOIN pg_proc AS procedure
JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
WHERE access.access_level <> 'admin'
  AND namespace.nspname = 'api'
  AND (
      procedure.proname = 'authorize_book_database_deletion'
      OR (
          access.access_level = 'rw'
          AND (
              procedure.proname IN (
                  'update_book_settings', 'set_book_reporting_currency',
                  'archive_book', 'restore_book', 'delete_book'
              )
              OR procedure.proname LIKE 'configure\_%' ESCAPE '\'
          )
      )
  )
\gexec

COMMIT;
