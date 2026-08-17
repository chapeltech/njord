-- Variables required from psql: principal_id, token_hash, expires_at
-- token_hash is lowercase hexadecimal SHA-256 of the opaque cookie value.
\ir machine-output.sql

SELECT to_jsonb(created)
FROM njord_control.create_web_session(
    :'principal_id'::UUID,
    :'token_hash',
    :'expires_at'::TIMESTAMPTZ
) AS created;
