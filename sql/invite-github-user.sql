-- Variables required from psql:
--   github_login, provider_subject, display_name, expires_at,
--   membership_role, book_ids
-- book_ids is a JSON array such as ["demo","personal"]. Empty optional
-- values mean: login as display name, no expiry, viewer, and no Books. The
-- operational caller must resolve and pass GitHub's positive numeric user id.
\ir machine-output.sql

SELECT to_jsonb(prepared)
FROM njord_control.prepare_github_user(
    :'github_login',
    NULLIF(:'display_name', ''),
    NULLIF(:'expires_at', '')::TIMESTAMPTZ,
    ARRAY(
        SELECT jsonb_array_elements_text(
            COALESCE(NULLIF(:'book_ids', ''), '[]')::JSONB
        )
    )::VARCHAR[],
    COALESCE(NULLIF(:'membership_role', ''), 'viewer'),
    :'provider_subject'::BIGINT
) AS prepared;
