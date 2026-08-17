-- Variables required from psql: database_role. authenticator_role is optional.
\if :{?authenticator_role}
\else
\set authenticator_role njord_authenticator
\endif

SELECT format('REVOKE %I FROM %I', :'database_role', :'authenticator_role')
WHERE EXISTS (
    SELECT 1
    FROM pg_auth_members AS membership
    JOIN pg_roles AS granted_role ON granted_role.oid = membership.roleid
    JOIN pg_roles AS member_role ON member_role.oid = membership.member
    WHERE granted_role.rolname = :'database_role'
      AND member_role.rolname = :'authenticator_role'
)
\gexec
