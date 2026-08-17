-- GitHub authentication and browser sessions for the control database.
--
-- The HTTP gateway owns the OAuth redirect/code exchange and verifies the
-- response with GitHub.  It passes the verified immutable numeric GitHub id
-- and current login to these private functions.  PostgreSQL owns invitations,
-- the permanent identity-to-role mapping, and the session lifecycle.

CREATE OR REPLACE FUNCTION njord_control.normalize_github_login(
    p_github_login TEXT
)
RETURNS VARCHAR
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    normalized_login VARCHAR := lower(btrim(p_github_login));
BEGIN
    -- GitHub logins are at most 39 characters, contain ASCII alphanumerics and
    -- single hyphens, and cannot begin or end with a hyphen. PostgreSQL roles
    -- can represent that spelling exactly when identifiers are quoted.
    IF normalized_login IS NULL
       OR length(normalized_login) NOT BETWEEN 1 AND 39
       OR normalized_login !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
       OR normalized_login IN (
           'current-role', 'current-user', 'none', 'postgres', 'public',
           'session-user'
       )
    THEN
        RAISE EXCEPTION 'GitHub login cannot be used as a PostgreSQL role'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_GITHUB_LOGIN';
    END IF;

    RETURN normalized_login;
END;
$$;

CREATE TABLE njord_control.github_invitations (
    github_login VARCHAR(39) PRIMARY KEY,
    invited_provider_subject BIGINT UNIQUE,
    principal_id UUID UNIQUE REFERENCES njord_control.principals(id),
    invited_by_role NAME NOT NULL,
    invited_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ,
    accepted_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,

    CHECK (github_login = njord_control.normalize_github_login(github_login)),
    CHECK (expires_at IS NULL OR expires_at > invited_at),
    CHECK (invited_provider_subject IS NULL OR invited_provider_subject > 0),
    CHECK (accepted_at IS NULL OR revoked_at IS NULL)
);

CREATE TABLE njord_control.principal_identities (
    provider_subject BIGINT PRIMARY KEY CHECK (provider_subject > 0),
    principal_id UUID NOT NULL REFERENCES njord_control.principals(id)
        ON DELETE CASCADE UNIQUE,
    provider_login VARCHAR(39) NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    last_authenticated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CHECK (provider_login = njord_control.normalize_github_login(provider_login))
);

CREATE TABLE njord_control.web_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash VARCHAR(64) NOT NULL UNIQUE
        CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    principal_id UUID NOT NULL REFERENCES njord_control.principals(id)
        ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,

    CHECK (expires_at > created_at)
);

CREATE INDEX web_sessions_active_principal_idx
    ON njord_control.web_sessions (principal_id, expires_at)
    WHERE revoked_at IS NULL;

CREATE OR REPLACE FUNCTION njord_control.prevent_identity_reassignment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.provider_subject IS DISTINCT FROM OLD.provider_subject
       OR NEW.principal_id IS DISTINCT FROM OLD.principal_id
    THEN
        RAISE EXCEPTION 'an external identity mapping is immutable'
            USING ERRCODE = 'P0001', DETAIL = 'IDENTITY_MAPPING_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER principal_identities_are_immutable
    BEFORE UPDATE ON njord_control.principal_identities
    FOR EACH ROW EXECUTE FUNCTION njord_control.prevent_identity_reassignment();

-- Administrative invitation entry point. Supplying a principal explicitly is
-- useful when binding GitHub to an existing direct-SQL user. Its database role
-- must already be the normalized GitHub login, so OAuth and psql cannot name
-- the same person differently.
CREATE OR REPLACE FUNCTION njord_control.invite_github_identity(
    p_github_login TEXT,
    p_expires_at TIMESTAMPTZ DEFAULT NULL,
    p_principal_id UUID DEFAULT NULL,
    p_provider_subject BIGINT DEFAULT NULL
)
RETURNS TABLE (
    github_login VARCHAR,
    invited_provider_subject BIGINT,
    principal_id UUID,
    expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    normalized_login VARCHAR :=
        njord_control.normalize_github_login(p_github_login);
    existing_role NAME;
BEGIN
    IF p_provider_subject IS NOT NULL AND p_provider_subject <= 0 THEN
        RAISE EXCEPTION 'invited GitHub provider subject must be positive'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_PROVIDER_SUBJECT';
    END IF;
    IF p_expires_at IS NOT NULL AND p_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'GitHub invitation expiry must be in the future'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_INVITATION_EXPIRY';
    END IF;

    IF p_principal_id IS NOT NULL THEN
        SELECT candidate.database_role INTO existing_role
        FROM njord_control.principals AS candidate
        WHERE candidate.id = p_principal_id
          AND candidate.disabled_at IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'invited principal does not exist or is disabled'
                USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_NOT_AVAILABLE';
        END IF;
        IF existing_role::TEXT <> normalized_login THEN
            RAISE EXCEPTION 'GitHub login must match the principal database role'
                USING ERRCODE = 'P0001', DETAIL = 'GITHUB_ROLE_MISMATCH';
        END IF;
    END IF;

    INSERT INTO njord_control.github_invitations AS invitation (
        github_login, invited_provider_subject, principal_id,
        invited_by_role, expires_at
    ) VALUES (
        normalized_login,
        p_provider_subject,
        p_principal_id,
        njord_control.invoking_database_role(),
        p_expires_at
    )
    ON CONFLICT ON CONSTRAINT github_invitations_pkey DO UPDATE SET
        invited_provider_subject = EXCLUDED.invited_provider_subject,
        principal_id = EXCLUDED.principal_id,
        invited_by_role = EXCLUDED.invited_by_role,
        invited_at = clock_timestamp(),
        expires_at = EXCLUDED.expires_at,
        revoked_at = NULL
    WHERE invitation.accepted_at IS NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'GitHub invitation has already been accepted'
            USING ERRCODE = 'P0001', DETAIL = 'INVITATION_ALREADY_ACCEPTED';
    END IF;

    RETURN QUERY
    SELECT invitation.github_login, invitation.invited_provider_subject,
           invitation.principal_id,
           invitation.expires_at
    FROM njord_control.github_invitations AS invitation
    WHERE invitation.github_login = normalized_login;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.revoke_github_invitation(
    p_github_login TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    revoked_principal_id UUID;
BEGIN
    UPDATE njord_control.github_invitations AS invitation
    SET revoked_at = clock_timestamp()
    WHERE invitation.github_login =
          njord_control.normalize_github_login(p_github_login)
      AND invitation.accepted_at IS NULL
      AND invitation.revoked_at IS NULL
    RETURNING invitation.principal_id INTO revoked_principal_id;

    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- A prepared invitation can already have provisional Book memberships and
    -- a LOGIN role. Revocation is therefore complete offboarding, not merely a
    -- status-label change. Re-enabling later is an explicit admin action.
    IF revoked_principal_id IS NOT NULL THEN
        DELETE FROM njord_control.book_memberships
        WHERE principal_id = revoked_principal_id;

        UPDATE njord_control.principals
        SET disabled_at = clock_timestamp()
        WHERE id = revoked_principal_id AND disabled_at IS NULL;
    END IF;

    RETURN TRUE;
END;
$$;

-- Narrow administrative preparation for an invited GitHub user. It creates
-- the principal before OAuth so the cluster role and database grants can be
-- provisioned before PostgREST ever receives a claim for it. Optional Book
-- memberships are catalogue state only; the operational caller must apply the
-- corresponding physical database grants after this transaction succeeds.
CREATE OR REPLACE FUNCTION njord_control.prepare_github_user(
    p_github_login TEXT,
    p_display_name TEXT DEFAULT NULL,
    p_expires_at TIMESTAMPTZ DEFAULT NULL,
    p_book_ids VARCHAR[] DEFAULT ARRAY[]::VARCHAR[],
    p_membership_role VARCHAR DEFAULT 'viewer',
    p_provider_subject BIGINT DEFAULT NULL
)
RETURNS TABLE (
    principal_id UUID,
    database_role NAME,
    github_login VARCHAR,
    invited_provider_subject BIGINT,
    membership_role VARCHAR,
    book_ids VARCHAR[]
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    normalized_login VARCHAR :=
        njord_control.normalize_github_login(p_github_login);
    normalized_display_name VARCHAR := COALESCE(
        NULLIF(btrim(p_display_name), ''), normalized_login
    );
    normalized_book_ids VARCHAR[];
    prepared_principal_id UUID;
    prepared_database_role NAME;
    prepared_disabled_at TIMESTAMPTZ;
    identity_already_bound BOOLEAN := FALSE;
BEGIN
    IF p_membership_role NOT IN ('owner', 'editor', 'viewer') THEN
        RAISE EXCEPTION 'Book membership role must be owner, editor, or viewer'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_MEMBERSHIP_ROLE';
    END IF;
    IF p_provider_subject IS NOT NULL AND p_provider_subject <= 0 THEN
        RAISE EXCEPTION 'invited GitHub provider subject must be positive'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_PROVIDER_SUBJECT';
    END IF;

    SELECT COALESCE(array_agg(DISTINCT book_id ORDER BY book_id), ARRAY[]::VARCHAR[])
    INTO normalized_book_ids
    FROM unnest(COALESCE(p_book_ids, ARRAY[]::VARCHAR[])) AS requested(book_id)
    WHERE NULLIF(btrim(book_id), '') IS NOT NULL;

    IF EXISTS (
        SELECT 1
        FROM unnest(normalized_book_ids) AS requested(book_id)
        LEFT JOIN njord_control.books AS book ON book.id = requested.book_id
        WHERE book.id IS NULL
    ) THEN
        RAISE EXCEPTION 'one or more invited Book ids do not exist'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    IF p_provider_subject IS NOT NULL THEN
        SELECT principal.id, principal.database_role, principal.disabled_at
        INTO prepared_principal_id, prepared_database_role, prepared_disabled_at
        FROM njord_control.principal_identities AS identity
        JOIN njord_control.principals AS principal
          ON principal.id = identity.principal_id
        WHERE identity.provider_subject = p_provider_subject
        FOR UPDATE OF identity, principal;
        identity_already_bound := FOUND;
    END IF;

    IF NOT identity_already_bound THEN
        SELECT principal.id, principal.database_role, principal.disabled_at
        INTO prepared_principal_id, prepared_database_role, prepared_disabled_at
        FROM njord_control.principals AS principal
        WHERE principal.database_role::TEXT = normalized_login
        FOR UPDATE;

        IF FOUND THEN
            IF EXISTS (
                SELECT 1
                FROM njord_control.principal_identities AS identity
                WHERE identity.principal_id = prepared_principal_id
            ) THEN
                RAISE EXCEPTION 'principal already has a GitHub identity'
                    USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_IDENTITY_ALREADY_BOUND';
            END IF;
        ELSE
            INSERT INTO njord_control.principals (database_role)
            VALUES (normalized_login::NAME)
            RETURNING id, njord_control.principals.database_role
            INTO prepared_principal_id, prepared_database_role;
        END IF;
    END IF;

    IF prepared_disabled_at IS NOT NULL THEN
        RAISE EXCEPTION 'principal is disabled'
            USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_DISABLED';
    END IF;

    UPDATE njord_control.principals AS principal
    SET display_name = normalized_display_name
    WHERE principal.id = prepared_principal_id;

    IF NOT identity_already_bound THEN
        PERFORM * FROM njord_control.invite_github_identity(
            normalized_login, p_expires_at, prepared_principal_id,
            p_provider_subject
        );
    END IF;

    INSERT INTO njord_control.book_memberships AS membership (
        book_id, principal_id, membership_role, changed_by
    )
    SELECT requested.book_id, prepared_principal_id,
           p_membership_role, (
               SELECT principal.id
               FROM njord_control.principals AS principal
               WHERE principal.database_role = njord_control.invoking_database_role()
           )
    FROM unnest(normalized_book_ids) AS requested(book_id)
    ON CONFLICT ON CONSTRAINT book_memberships_pkey DO UPDATE SET
        membership_role = CASE
            WHEN membership.membership_role = 'owner'
              OR EXCLUDED.membership_role = 'owner' THEN 'owner'
            WHEN membership.membership_role = 'editor'
              OR EXCLUDED.membership_role = 'editor' THEN 'editor'
            ELSE 'viewer'
        END,
        changed_at = clock_timestamp(),
        changed_by = EXCLUDED.changed_by;

    RETURN QUERY SELECT
        prepared_principal_id,
        prepared_database_role,
        normalized_login,
        p_provider_subject,
        p_membership_role,
        normalized_book_ids;
END;
$$;

-- Called only after the gateway has verified GitHub's OAuth response. A first
-- login consumes an invitation and freezes the PostgreSQL role spelling. On
-- later logins the immutable numeric subject is authoritative: a renamed
-- GitHub login updates provider_login but does not rename the database role.
CREATE OR REPLACE FUNCTION njord_control.authenticate_github_identity(
    p_provider_subject BIGINT,
    p_github_login TEXT,
    p_display_name TEXT DEFAULT NULL
)
RETURNS TABLE (
    principal_id UUID,
    database_role NAME,
    identity_created BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    normalized_login VARCHAR :=
        njord_control.normalize_github_login(p_github_login);
    normalized_display_name VARCHAR := NULLIF(btrim(p_display_name), '');
    matched_principal_id UUID;
    matched_database_role NAME;
    matched_disabled_at TIMESTAMPTZ;
    invited_principal_id UUID;
BEGIN
    IF p_provider_subject IS NULL OR p_provider_subject <= 0 THEN
        RAISE EXCEPTION 'GitHub provider subject must be a positive numeric id'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_PROVIDER_SUBJECT';
    END IF;

    SELECT identity.principal_id, principal.database_role, principal.disabled_at
    INTO matched_principal_id, matched_database_role, matched_disabled_at
    FROM njord_control.principal_identities AS identity
    JOIN njord_control.principals AS principal
      ON principal.id = identity.principal_id
    WHERE identity.provider_subject = p_provider_subject
    FOR UPDATE OF identity, principal;

    IF FOUND THEN
        IF matched_disabled_at IS NOT NULL THEN
            RAISE EXCEPTION 'principal is disabled'
                USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_DISABLED';
        END IF;

        BEGIN
            UPDATE njord_control.principal_identities AS identity
            SET provider_login = normalized_login,
                last_authenticated_at = clock_timestamp()
            WHERE identity.provider_subject = p_provider_subject;
        EXCEPTION WHEN unique_violation THEN
            RAISE EXCEPTION 'GitHub login is already bound to another identity'
                USING ERRCODE = 'P0001', DETAIL = 'GITHUB_LOGIN_ALREADY_BOUND';
        END;

        UPDATE njord_control.principals AS principal
        SET display_name = COALESCE(
            normalized_display_name, principal.display_name, normalized_login
        )
        WHERE principal.id = matched_principal_id;

        RETURN QUERY SELECT
            matched_principal_id, matched_database_role, FALSE;
        RETURN;
    END IF;

    SELECT invitation.principal_id INTO invited_principal_id
    FROM njord_control.github_invitations AS invitation
    WHERE invitation.github_login = normalized_login
      AND (
          invitation.invited_provider_subject IS NULL
          OR invitation.invited_provider_subject = p_provider_subject
      )
      AND invitation.accepted_at IS NULL
      AND invitation.revoked_at IS NULL
      AND (
          invitation.expires_at IS NULL
          OR invitation.expires_at > clock_timestamp()
      )
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'GitHub identity is not invited'
            USING ERRCODE = 'P0001', DETAIL = 'GITHUB_IDENTITY_NOT_INVITED';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM njord_control.principal_identities AS identity
        WHERE identity.provider_login = normalized_login
    ) THEN
        RAISE EXCEPTION 'GitHub login is already bound to another identity'
            USING ERRCODE = 'P0001', DETAIL = 'GITHUB_LOGIN_ALREADY_BOUND';
    END IF;

    SELECT principal.id, principal.database_role, principal.disabled_at
    INTO matched_principal_id, matched_database_role, matched_disabled_at
    FROM njord_control.principals AS principal
    WHERE principal.database_role::TEXT = normalized_login
      AND (invited_principal_id IS NULL OR principal.id = invited_principal_id)
    FOR UPDATE;

    IF NOT FOUND THEN
        IF invited_principal_id IS NOT NULL THEN
            RAISE EXCEPTION 'invited principal is unavailable or has a different role'
                USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_NOT_AVAILABLE';
        END IF;

        INSERT INTO njord_control.principals (database_role, display_name)
        VALUES (
            normalized_login::NAME,
            COALESCE(normalized_display_name, normalized_login)
        )
        RETURNING id, njord_control.principals.database_role
        INTO matched_principal_id, matched_database_role;
    END IF;

    IF matched_disabled_at IS NOT NULL THEN
        RAISE EXCEPTION 'principal is disabled'
            USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_DISABLED';
    END IF;
    IF EXISTS (
        SELECT 1 FROM njord_control.principal_identities AS identity
        WHERE identity.principal_id = matched_principal_id
    ) THEN
        RAISE EXCEPTION 'principal already has a GitHub identity'
            USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_IDENTITY_ALREADY_BOUND';
    END IF;

    INSERT INTO njord_control.principal_identities (
        provider_subject, principal_id, provider_login
    ) VALUES (
        p_provider_subject, matched_principal_id, normalized_login
    );

    UPDATE njord_control.principals AS principal
    SET display_name = COALESCE(
        normalized_display_name, principal.display_name, normalized_login
    )
    WHERE principal.id = matched_principal_id;

    UPDATE njord_control.github_invitations AS invitation
    SET principal_id = matched_principal_id,
        accepted_at = clock_timestamp()
    WHERE invitation.github_login = normalized_login;

    RETURN QUERY SELECT matched_principal_id, matched_database_role, TRUE;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.create_web_session(
    p_principal_id UUID,
    p_token_hash TEXT,
    p_expires_at TIMESTAMPTZ
)
RETURNS TABLE (
    session_id UUID,
    database_role NAME,
    expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    normalized_token_hash VARCHAR := lower(btrim(p_token_hash));
    matched_database_role NAME;
    created_session_id UUID;
BEGIN
    IF normalized_token_hash !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'session token hash must be lowercase SHA-256 hex'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_SESSION_TOKEN_HASH';
    END IF;
    IF p_expires_at IS NULL
       OR p_expires_at <= clock_timestamp()
       OR p_expires_at > clock_timestamp() + INTERVAL '30 days'
    THEN
        RAISE EXCEPTION 'session expiry must be within the next 30 days'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_SESSION_EXPIRY';
    END IF;

    SELECT principal.database_role INTO matched_database_role
    FROM njord_control.principals AS principal
    WHERE principal.id = p_principal_id
      AND principal.disabled_at IS NULL
      AND EXISTS (
          SELECT 1
          FROM njord_control.principal_identities AS identity
          WHERE identity.principal_id = principal.id
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION 'principal has no active GitHub identity'
            USING ERRCODE = 'P0001', DETAIL = 'PRINCIPAL_NOT_AUTHENTICATABLE';
    END IF;

    -- Keep revoked/expired audit rows for 30 days, then prune them only while a
    -- new session is being created. This bounds growth without adding cleanup
    -- work to the hot path that resolves every request.
    PERFORM njord_control.prune_web_sessions(
        clock_timestamp() - INTERVAL '30 days'
    );

    INSERT INTO njord_control.web_sessions (
        token_hash, principal_id, expires_at
    ) VALUES (
        normalized_token_hash, p_principal_id, p_expires_at
    )
    RETURNING id INTO created_session_id;

    RETURN QUERY SELECT
        created_session_id, matched_database_role, p_expires_at;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'session token hash already exists'
        USING ERRCODE = 'P0001', DETAIL = 'SESSION_TOKEN_REUSED';
END;
$$;

-- The gateway hashes the opaque cookie before every lookup. Resolution also
-- touches last_seen_at, making active-session inspection useful without
-- storing the bearer token itself.
CREATE OR REPLACE FUNCTION njord_control.resolve_web_session(
    p_token_hash TEXT
)
RETURNS TABLE (
    session_id UUID,
    principal_id UUID,
    database_role NAME,
    provider_subject BIGINT,
    provider_login VARCHAR,
    expires_at TIMESTAMPTZ
)
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    WITH token AS (
        SELECT lower(btrim(p_token_hash)) AS hash
    ), active_session AS MATERIALIZED (
        SELECT session.id, session.principal_id,
               principal.database_role, session.expires_at
        FROM njord_control.web_sessions AS session
        JOIN njord_control.principals AS principal
          ON principal.id = session.principal_id
        CROSS JOIN token
        WHERE token.hash ~ '^[0-9a-f]{64}$'
          AND session.token_hash = token.hash
          AND session.revoked_at IS NULL
          AND session.expires_at > clock_timestamp()
          AND principal.disabled_at IS NULL
    ), touched AS (
        UPDATE njord_control.web_sessions AS session
        SET last_seen_at = clock_timestamp()
        FROM active_session
        WHERE session.id = active_session.id
          AND session.last_seen_at < clock_timestamp() - INTERVAL '5 minutes'
        RETURNING session.id
    )
    SELECT active_session.id,
           active_session.principal_id,
           active_session.database_role,
           identity.provider_subject,
           identity.provider_login,
           active_session.expires_at
    FROM active_session
    JOIN njord_control.principal_identities AS identity
      ON identity.principal_id = active_session.principal_id;
$$;

CREATE OR REPLACE FUNCTION njord_control.revoke_web_session(
    p_token_hash TEXT
)
RETURNS BOOLEAN
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    WITH revoked AS (
        UPDATE njord_control.web_sessions AS session
        SET revoked_at = clock_timestamp()
        WHERE session.token_hash = lower(btrim(p_token_hash))
          AND lower(btrim(p_token_hash)) ~ '^[0-9a-f]{64}$'
          AND session.revoked_at IS NULL
        RETURNING 1
    )
    SELECT EXISTS (SELECT 1 FROM revoked);
$$;

CREATE OR REPLACE FUNCTION njord_control.revoke_principal_web_sessions(
    p_principal_id UUID
)
RETURNS BIGINT
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    WITH revoked AS (
        UPDATE njord_control.web_sessions AS session
        SET revoked_at = clock_timestamp()
        WHERE session.principal_id = p_principal_id
          AND session.revoked_at IS NULL
        RETURNING 1
    )
    SELECT count(*) FROM revoked;
$$;

CREATE OR REPLACE FUNCTION njord_control.prune_web_sessions(
    p_before TIMESTAMPTZ DEFAULT clock_timestamp()
)
RETURNS BIGINT
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    WITH pruned AS (
        DELETE FROM njord_control.web_sessions AS session
        WHERE session.expires_at <= p_before
           OR session.revoked_at <= p_before
        RETURNING 1
    )
    SELECT count(*) FROM pruned;
$$;

COMMENT ON TABLE njord_control.github_invitations IS
    'Invitation-only admission keyed by normalized GitHub login and normally anchored in advance to GitHub''s resolved numeric user id.';
COMMENT ON TABLE njord_control.principal_identities IS
    'Immutable verified GitHub numeric identity mapped to one stable Njord principal and PostgreSQL role.';
COMMENT ON TABLE njord_control.web_sessions IS
    'Revocable browser sessions storing only SHA-256 hashes of opaque cookie tokens; revoked or expired rows are retained for 30 days and opportunistically pruned when a session is created.';
