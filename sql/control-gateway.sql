-- Principal enablement and the gateway's private session/identity RPCs.

-- Disabling a principal is one cluster-wide authorization operation. Browser
-- sessions, direct LOGIN, and every Book capability membership change together;
-- re-enabling restores only the memberships still recorded in the catalogue.
CREATE OR REPLACE FUNCTION njord_control.sync_principal_enabled_state()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    book_membership RECORD;
    role_state RECORD;
    authenticator_role NAME;
BEGIN
    IF NEW.disabled_at IS NOT DISTINCT FROM OLD.disabled_at THEN
        RETURN NEW;
    END IF;

    SELECT rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls
    INTO role_state
    FROM pg_roles
    WHERE rolname = NEW.database_role;
    IF NOT FOUND OR role_state.rolsuper OR role_state.rolcreatedb
       OR role_state.rolcreaterole OR role_state.rolreplication
       OR role_state.rolbypassrls THEN
        RAISE EXCEPTION 'refusing to change login state for privileged role %',
            NEW.database_role
            USING ERRCODE = '42501', DETAIL = 'PRIVILEGED_PRINCIPAL';
    END IF;

    SELECT settings.authenticator_role INTO STRICT authenticator_role
    FROM njord_control.settings AS settings
    WHERE settings.singleton;

    IF NEW.disabled_at IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM njord_control.global_administrators
           WHERE principal_id = NEW.id
       )
       AND NOT EXISTS (
           SELECT 1
           FROM njord_control.global_administrators AS administrator
           JOIN njord_control.principals AS principal
             ON principal.id = administrator.principal_id
           WHERE principal.id <> NEW.id
             AND principal.disabled_at IS NULL
       ) THEN
        RAISE EXCEPTION 'the final enabled global administrator cannot be disabled'
            USING ERRCODE = '23514', DETAIL = 'FINAL_GLOBAL_ADMINISTRATOR';
    END IF;

    FOR book_membership IN
        SELECT book_id, membership_role
        FROM njord_control.book_memberships
        WHERE principal_id = NEW.id
    LOOP
        PERFORM njord_control.set_book_role_membership(
            book_membership.book_id,
            NEW.database_role,
            CASE WHEN NEW.disabled_at IS NULL
                 THEN book_membership.membership_role ELSE NULL END
        );
    END LOOP;

    IF NEW.disabled_at IS NULL THEN
        EXECUTE format('ALTER ROLE %I LOGIN', NEW.database_role);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = authenticator_role)
           AND NOT EXISTS (
               SELECT 1
               FROM pg_auth_members AS membership
               JOIN pg_roles AS granted ON granted.oid = membership.roleid
               JOIN pg_roles AS member ON member.oid = membership.member
               WHERE granted.rolname = NEW.database_role
                 AND member.rolname = authenticator_role
           ) THEN
            EXECUTE format(
                'GRANT %I TO %I', NEW.database_role, authenticator_role
            );
        END IF;
    ELSE
        IF EXISTS (
            SELECT 1
            FROM pg_auth_members AS membership
            JOIN pg_roles AS granted ON granted.oid = membership.roleid
            JOIN pg_roles AS member ON member.oid = membership.member
            WHERE granted.rolname = NEW.database_role
              AND member.rolname = authenticator_role
        ) THEN
            EXECUTE format(
                'REVOKE %I FROM %I', NEW.database_role, authenticator_role
            );
        END IF;
        EXECUTE format('ALTER ROLE %I NOLOGIN', NEW.database_role);
        PERFORM njord_control.revoke_principal_web_sessions(NEW.id);
        PERFORM pg_terminate_backend(activity.pid)
        FROM pg_stat_activity AS activity
        WHERE activity.usename = NEW.database_role
          AND activity.pid <> pg_backend_pid();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER principals_sync_enabled_state
    BEFORE UPDATE OF disabled_at ON njord_control.principals
    FOR EACH ROW EXECUTE FUNCTION njord_control.sync_principal_enabled_state();

-- Private loopback transport used by the gateway instead of spawning psql for
-- every cookie lookup. Only the dedicated njord_gateway role receives
-- EXECUTE; anonymous and browser roles do not.
CREATE OR REPLACE FUNCTION api.resolve_gateway_session(p_token_hash TEXT)
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
    SELECT * FROM njord_control.resolve_web_session(p_token_hash);
$$;

CREATE OR REPLACE FUNCTION api.revoke_gateway_session(p_token_hash TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT njord_control.revoke_web_session(p_token_hash);
$$;

CREATE OR REPLACE FUNCTION api.authenticate_gateway_identity(
    p_provider_subject BIGINT,
    p_github_login TEXT,
    p_display_name TEXT
)
RETURNS TABLE (
    principal_id UUID,
    database_role NAME,
    identity_created BOOLEAN
)
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT *
    FROM njord_control.authenticate_github_identity(
        p_provider_subject, p_github_login, p_display_name
    );
$$;

CREATE OR REPLACE FUNCTION api.create_gateway_session(
    p_principal_id UUID,
    p_token_hash TEXT,
    p_expires_at TIMESTAMPTZ
)
RETURNS TABLE (
    session_id UUID,
    database_role NAME,
    expires_at TIMESTAMPTZ
)
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT * FROM njord_control.create_web_session(
        p_principal_id, p_token_hash, p_expires_at
    );
$$;

-- The lifecycle broker has already authenticated the selected Book and read
-- its canonical settings from that Book database. It may refresh only an
-- existing, fully provisioned catalogue row; creation/deletion remain the
-- explicit lifecycle scripts' responsibility.
CREATE OR REPLACE FUNCTION api.sync_gateway_book(
    p_book_id VARCHAR,
    p_name VARCHAR,
    p_reporting_asset VARCHAR,
    p_entity_type VARCHAR,
    p_archived_at TIMESTAMPTZ
)
RETURNS BOOLEAN
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF p_book_id IS NULL OR NULLIF(btrim(p_name), '') IS NULL
       OR p_reporting_asset IS NULL OR p_entity_type IS NULL
       OR (p_archived_at IS NOT NULL AND NOT isfinite(p_archived_at))
    THEN
        RAISE EXCEPTION 'gateway Book settings are incomplete or invalid'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_BOOK_SETTINGS';
    END IF;

    UPDATE njord_control.books AS book
    SET name = btrim(p_name),
        reporting_asset = p_reporting_asset,
        entity_type = p_entity_type,
        archived_at = p_archived_at
    WHERE book.id = p_book_id
      AND book.provisioning_state = 'ready';
    RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION api.resolve_gateway_session(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.revoke_gateway_session(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.authenticate_gateway_identity(BIGINT, TEXT, TEXT)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION api.create_gateway_session(UUID, TEXT, TIMESTAMPTZ)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION api.sync_gateway_book(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, TIMESTAMPTZ
) FROM PUBLIC;
