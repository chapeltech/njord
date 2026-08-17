\if :{?authenticator_role}
\else
\set authenticator_role njord_authenticator
\endif
\if :{?gateway_role}
\else
\set gateway_role njord_gateway
\endif

-- The gateway reaches this PostgREST only over loopback.  Its authenticator can
-- connect and SET ROLE, but owns no product object and inherits no privileges.
SELECT format('GRANT CONNECT ON DATABASE %I TO %I',
              current_database(), :'authenticator_role') \gexec
SELECT format('GRANT %I TO %I', :'anonymous_role', :'authenticator_role') \gexec
SELECT format('GRANT %I TO %I', :'gateway_role', :'authenticator_role') \gexec

-- The enable/disable trigger uses this configured role to revoke SET ROLE as
-- well as LOGIN. The settings row is private operator state.
UPDATE njord_control.settings
SET authenticator_role = :'authenticator_role'::NAME
WHERE singleton;

-- Existing human identities must also be SET ROLE targets.  New identities use
-- grant-role-to-authenticator.sql as part of invitation provisioning.
SELECT format('GRANT %I TO %I', principal.database_role, :'authenticator_role')
FROM njord_control.principals AS principal
JOIN pg_roles AS role ON role.rolname = principal.database_role
WHERE principal.disabled_at IS NULL
\gexec

-- Anonymous PostgREST receives no control API. Only the loopback gateway's
-- short-lived internal JWT can enter these fixed-path wrappers.
REVOKE ALL ON FUNCTION
    api.authenticate_gateway_identity(BIGINT, TEXT, TEXT),
    api.create_gateway_session(UUID, TEXT, TIMESTAMPTZ),
    api.resolve_gateway_session(TEXT),
    api.revoke_gateway_session(TEXT),
    api.sync_gateway_book(VARCHAR, VARCHAR, VARCHAR, VARCHAR, TIMESTAMPTZ)
FROM PUBLIC;
REVOKE ALL ON FUNCTION
    api.authenticate_gateway_identity(BIGINT, TEXT, TEXT),
    api.create_gateway_session(UUID, TEXT, TIMESTAMPTZ),
    api.resolve_gateway_session(TEXT),
    api.revoke_gateway_session(TEXT),
    api.sync_gateway_book(VARCHAR, VARCHAR, VARCHAR, VARCHAR, TIMESTAMPTZ)
FROM :"anonymous_role";

GRANT USAGE ON SCHEMA api TO :"gateway_role";
GRANT EXECUTE ON FUNCTION
    api.authenticate_gateway_identity(BIGINT, TEXT, TEXT),
    api.create_gateway_session(UUID, TEXT, TIMESTAMPTZ),
    api.resolve_gateway_session(TEXT),
    api.revoke_gateway_session(TEXT),
    api.sync_gateway_book(VARCHAR, VARCHAR, VARCHAR, VARCHAR, TIMESTAMPTZ)
TO :"gateway_role";
