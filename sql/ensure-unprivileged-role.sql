-- Variables required from psql: database_role, role_login, role_kind
-- Shared cluster-role hardening for human and anonymous runtime roles.
SELECT format(
    'CREATE ROLE %I %s %s NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS',
    :'database_role', :'role_login',
    CASE :'role_kind' WHEN 'human' THEN 'INHERIT' ELSE 'NOINHERIT' END
)
WHERE NOT EXISTS (
    SELECT 1 FROM pg_roles WHERE rolname = :'database_role'
) \gexec

SELECT format(
    'DO $block$ BEGIN RAISE EXCEPTION %L; END $block$',
    'refusing privileged ' || :'role_kind' || ' role: ' || :'database_role'
)
FROM pg_roles
WHERE rolname = :'database_role'
  AND (rolsuper OR rolreplication OR rolbypassrls) \gexec

-- SET ROLE follows membership transitively. A safe authenticator, gateway, or
-- human role must therefore have no privileged ancestor even when its own
-- flags are clean. Expected unprivileged capability/human parents remain valid.
WITH RECURSIVE target AS (
    SELECT oid, rolname FROM pg_roles WHERE rolname = :'database_role'
), inherited_role(oid) AS (
    SELECT membership.roleid
    FROM pg_auth_members AS membership
    JOIN target ON target.oid = membership.member
  UNION
    SELECT membership.roleid
    FROM pg_auth_members AS membership
    JOIN inherited_role ON inherited_role.oid = membership.member
), unsafe_parent AS (
    SELECT parent.rolname
    FROM inherited_role
    JOIN pg_roles AS parent ON parent.oid = inherited_role.oid
    WHERE parent.rolsuper OR parent.rolcreatedb OR parent.rolcreaterole
       OR parent.rolreplication OR parent.rolbypassrls
    ORDER BY parent.rolname
    LIMIT 1
)
SELECT format(
    'DO $block$ BEGIN RAISE EXCEPTION %L '
    'USING ERRCODE = ''42501'', DETAIL = ''PRIVILEGED_ROLE_ANCESTOR''; '
    'END $block$',
    'refusing ' || :'role_kind' || ' role ' || :'database_role'
        || ' with privileged parent ' || unsafe_parent.rolname
)
FROM unsafe_parent
\gexec

SELECT format(
    'ALTER ROLE %I %s %s NOCREATEDB NOCREATEROLE',
    :'database_role', :'role_login',
    CASE :'role_kind' WHEN 'human' THEN 'INHERIT' ELSE 'NOINHERIT' END
) \gexec
