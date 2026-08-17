-- Variables required from psql: token_hash
-- Produces no row when the session is unknown, expired, revoked, or disabled.
\ir machine-output.sql

SELECT to_jsonb(resolved)
FROM njord_control.resolve_web_session(:'token_hash') AS resolved;
