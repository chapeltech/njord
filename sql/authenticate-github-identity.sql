-- Variables required from psql: provider_subject, github_login, display_name
-- The gateway must call this only with identity facts verified by GitHub.
\ir machine-output.sql

SELECT to_jsonb(authenticated)
FROM njord_control.authenticate_github_identity(
    :'provider_subject'::BIGINT,
    :'github_login',
    NULLIF(:'display_name', '')
) AS authenticated;
