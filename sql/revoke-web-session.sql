-- Variables required from psql: token_hash
\ir machine-output.sql

SELECT jsonb_build_object(
    'revoked', njord_control.revoke_web_session(:'token_hash')
);
