\if :{?authenticator_role}
\else
\set authenticator_role njord_authenticator
\endif
\if :{?gateway_role}
\else
\set gateway_role njord_gateway
\endif

-- PostgREST connects as this dedicated, unprivileged LOGIN role.  NOINHERIT
-- prevents it from acquiring browser-role privileges until PostgREST performs
-- SET LOCAL ROLE for a verified JWT (or the configured anonymous role).
\set database_role :authenticator_role
\set role_login LOGIN
\set role_kind authenticator
\ir ensure-unprivileged-role.sql

-- Cluster-wide role used by PostgREST before it validates a Njord JWT.  It
-- deliberately receives no database, schema, table, or function grants.
\set database_role :anonymous_role
\set role_login NOLOGIN
\set role_kind anonymous
\ir ensure-unprivileged-role.sql

-- The loopback gateway signs very short-lived internal JWTs for this distinct
-- capability. It can call only fixed-path SECURITY DEFINER wrappers granted by
-- grant-control-gateway.sql and is never a browser or human identity.
\set database_role :gateway_role
\set role_login NOLOGIN
\set role_kind gateway
\ir ensure-unprivileged-role.sql

SELECT format('GRANT %I TO %I', :'anonymous_role', :'authenticator_role') \gexec
SELECT format('GRANT %I TO %I', :'gateway_role', :'authenticator_role') \gexec
