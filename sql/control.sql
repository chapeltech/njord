-- Cluster-wide catalogue for a database-per-book Njord installation.
--
-- This database contains identities, invitations, browser sessions, and Book
-- discovery only. Accounting rows, report-pack configuration, and ledger
-- mutations belong to the individual Book databases created from
-- sql/njord.sql.

DROP SCHEMA IF EXISTS api CASCADE;
DROP SCHEMA IF EXISTS njord_control CASCADE;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

CREATE SCHEMA njord_control;
CREATE SCHEMA api;

\ir presentation.sql

CREATE TABLE njord_control.assets (
    id VARCHAR PRIMARY KEY
);

-- The control catalogue and every Book share one canonical starting list.
\ir asset-catalog.sql
INSERT INTO njord_control.assets (id)
SELECT id FROM njord_asset_catalog;

CREATE TABLE njord_control.entity_types (
    id VARCHAR PRIMARY KEY
);

INSERT INTO njord_control.entity_types VALUES
    ('household'),
    ('sole_trader'),
    ('partnership'),
    ('company'),
    ('charity'),
    ('trust'),
    ('other_organisation');

CREATE TABLE njord_control.access_levels (
    access_level VARCHAR PRIMARY KEY,
    membership_role VARCHAR NOT NULL UNIQUE,
    row_order SMALLINT NOT NULL UNIQUE,
    semantic_key VARCHAR NOT NULL
);

INSERT INTO njord_control.access_levels VALUES
    ('ro', 'viewer', 1, 'access.ro'),
    ('rw', 'editor', 2, 'access.rw'),
    ('admin', 'owner', 3, 'access.admin');

-- Private appliance-wide capacity guard. Operators may tune this directly;
-- application users receive no table privileges. The 32-Book default fits the
-- appliance's two-connections-per-Book adapter budget under a typical
-- max_connections=100. Raising it requires tuning PostgreSQL and host resources.
CREATE TABLE njord_control.settings (
    singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
    max_books INTEGER NOT NULL DEFAULT 32 CHECK (max_books BETWEEN 1 AND 4096),
    authenticator_role NAME NOT NULL DEFAULT 'njord_authenticator'
);

INSERT INTO njord_control.settings (singleton, max_books)
VALUES (TRUE, 32);

CREATE OR REPLACE FUNCTION njord_control.keep_settings_singleton()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'the Njord control settings row cannot be deleted'
        USING ERRCODE = '23514',
              CONSTRAINT = 'control_settings_singleton';
END;
$$;

CREATE TRIGGER settings_keep_singleton
    BEFORE DELETE ON njord_control.settings
    FOR EACH ROW EXECUTE FUNCTION njord_control.keep_settings_singleton();

CREATE TABLE njord_control.principals (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    database_role NAME NOT NULL UNIQUE,
    display_name VARCHAR,
    disabled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE njord_control.global_administrators (
    principal_id UUID PRIMARY KEY REFERENCES njord_control.principals(id)
        ON DELETE CASCADE,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    granted_by UUID REFERENCES njord_control.principals(id)
);

CREATE TABLE njord_control.books (
    id VARCHAR PRIMARY KEY,
    name VARCHAR NOT NULL,
    reporting_asset VARCHAR NOT NULL REFERENCES njord_control.assets(id),
    entity_type VARCHAR NOT NULL DEFAULT 'household'
        REFERENCES njord_control.entity_types(id),
    provisioning_state VARCHAR NOT NULL DEFAULT 'provisioning'
        CHECK (provisioning_state IN ('provisioning', 'ready', 'deleting')),
    archived_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    -- A handle is also the database name. Keeping it deliberately boring
    -- makes psql -d HANDLE pleasant and lets the router quote it safely.
    CHECK (id ~ '^[a-z][a-z0-9_-]{0,62}$'),
    CHECK (id NOT IN ('postgres', 'template0', 'template1'))
);

CREATE TABLE njord_control.book_memberships (
    book_id VARCHAR NOT NULL REFERENCES njord_control.books(id)
        ON DELETE CASCADE,
    principal_id UUID NOT NULL REFERENCES njord_control.principals(id)
        ON DELETE RESTRICT,
    membership_role VARCHAR NOT NULL
        CHECK (membership_role IN ('owner', 'editor', 'viewer')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    changed_by UUID REFERENCES njord_control.principals(id),

    PRIMARY KEY (book_id, principal_id)
);

CREATE INDEX book_memberships_principal
    ON njord_control.book_memberships (principal_id);

-- SECURITY DEFINER page functions still need to identify their caller. A
-- direct login has role=none and is identified by session_user; PostgREST
-- reaches the same identity after SET LOCAL ROLE.
CREATE OR REPLACE FUNCTION njord_control.invoking_database_role()
RETURNS NAME
LANGUAGE SQL
STABLE
AS $$
    SELECT CASE current_setting('role')
        WHEN 'none' THEN session_user::NAME
        ELSE current_setting('role')::NAME
    END;
$$;

-- A Book's capability roles are cluster objects, so their names must be both
-- deterministic and unique across databases. The readable prefix is useful
-- in \du; the 96-bit suffix makes truncated-handle collisions impractical.
CREATE OR REPLACE FUNCTION njord_control.book_access_role(
    p_book_id VARCHAR,
    p_access_level VARCHAR
)
RETURNS NAME
LANGUAGE SQL
IMMUTABLE
STRICT
AS $$
    SELECT format(
        'njord_%s_%s_%s',
        left(p_book_id, 20), substr(md5(p_book_id), 1, 24), p_access_level
    )::NAME;
$$;

CREATE OR REPLACE FUNCTION njord_control.ensure_book_access_roles(
    p_book_id VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    access_level VARCHAR;
    access_role NAME;
    existing RECORD;
BEGIN
    -- Role DDL is transactional, and this lock serializes concurrent first
    -- use without requiring a second state table.
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-book-access:' || p_book_id, 0)
    );

    FOREACH access_level IN ARRAY ARRAY['ro', 'rw', 'admin'] LOOP
        access_role := njord_control.book_access_role(
            p_book_id, access_level
        );
        SELECT rolcanlogin, rolinherit, rolsuper, rolcreatedb, rolcreaterole,
               rolreplication, rolbypassrls
        INTO existing
        FROM pg_roles
        WHERE rolname = access_role;

        IF NOT FOUND THEN
            EXECUTE format(
                'CREATE ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB '
                'NOCREATEROLE NOREPLICATION NOBYPASSRLS',
                access_role
            );
        ELSIF existing.rolcanlogin OR existing.rolinherit OR existing.rolsuper
           OR existing.rolcreatedb OR existing.rolcreaterole
           OR existing.rolreplication OR existing.rolbypassrls
           OR EXISTS (
               SELECT 1
               FROM pg_auth_members AS membership
               JOIN pg_roles AS member_role
                 ON member_role.oid = membership.member
               WHERE member_role.rolname = access_role
           ) THEN
            RAISE EXCEPTION 'unsafe Book capability role: %', access_role
                USING ERRCODE = '42501', DETAIL = 'UNSAFE_BOOK_ACCESS_ROLE';
        END IF;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.set_book_role_membership(
    p_book_id VARCHAR,
    p_database_role NAME,
    p_membership_role VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    access_level VARCHAR;
    access_role NAME;
    role_state RECORD;
BEGIN
    SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole,
           rolreplication, rolbypassrls
    INTO role_state
    FROM pg_roles
    WHERE rolname = p_database_role;

    IF p_membership_role IS NOT NULL AND NOT FOUND THEN
        EXECUTE format(
            'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE '
            'NOREPLICATION NOBYPASSRLS',
            p_database_role
        );
    ELSIF p_membership_role IS NOT NULL
       AND (
            role_state.rolsuper OR role_state.rolcreatedb
            OR role_state.rolcreaterole OR role_state.rolreplication
            OR role_state.rolbypassrls
            OR EXISTS (
                WITH RECURSIVE ancestors (role_oid) AS (
                    SELECT membership.roleid
                    FROM pg_auth_members AS membership
                    JOIN pg_roles AS member_role
                      ON member_role.oid = membership.member
                    WHERE member_role.rolname = p_database_role
                    UNION
                    SELECT membership.roleid
                    FROM pg_auth_members AS membership
                    JOIN ancestors
                      ON ancestors.role_oid = membership.member
                )
                SELECT 1
                FROM ancestors
                JOIN pg_roles AS ancestor
                  ON ancestor.oid = ancestors.role_oid
                WHERE ancestor.rolsuper OR ancestor.rolcreatedb
                   OR ancestor.rolcreaterole OR ancestor.rolreplication
                   OR ancestor.rolbypassrls
            )
       )
       AND NOT (
            p_database_role = njord_control.invoking_database_role()
            AND p_membership_role = 'owner'
       ) THEN
        RAISE EXCEPTION 'refusing privileged Book member role: %',
            p_database_role
            USING ERRCODE = '42501', DETAIL = 'PRIVILEGED_BOOK_MEMBER_ROLE';
    END IF;

    -- Revoke every profile first. Direct membership checks avoid harmless
    -- warnings and also clean up state left by an older installation.
    FOR access_level IN SELECT unnest(ARRAY['ro', 'rw', 'admin']) LOOP
        access_role := njord_control.book_access_role(
            p_book_id, access_level
        );
        IF EXISTS (
            SELECT 1
            FROM pg_auth_members AS membership
            JOIN pg_roles AS granted_role
              ON granted_role.oid = membership.roleid
            JOIN pg_roles AS member_role
              ON member_role.oid = membership.member
            WHERE granted_role.rolname = access_role
              AND member_role.rolname = p_database_role
        ) THEN
            EXECUTE format(
                'REVOKE %I FROM %I', access_role, p_database_role
            );
        END IF;
    END LOOP;

    IF p_membership_role IS NOT NULL THEN
        PERFORM njord_control.ensure_book_access_roles(p_book_id);
        SELECT levels.access_level INTO access_level
        FROM njord_control.access_levels AS levels
        WHERE levels.membership_role = p_membership_role;
        access_role := njord_control.book_access_role(
            p_book_id, access_level
        );
        EXECUTE format('GRANT %I TO %I', access_role, p_database_role);
    END IF;
END;
$$;

-- This is the authorization boundary for direct SQL as well as PostgREST.
-- Because PostgreSQL roles are cluster-wide, changing a catalogue row and
-- changing its group membership can commit (or roll back) together even
-- though the Book's objects live in another database.
CREATE OR REPLACE FUNCTION njord_control.sync_book_role_membership()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    database_role NAME;
    principal_disabled_at TIMESTAMPTZ;
BEGIN
    -- Every ACL mutation for a Book takes the same parent-row lock.  Besides
    -- ordering transactional role DDL, this closes the two-owner write-skew in
    -- which concurrent sessions could each remove the owner visible to the
    -- other and satisfy the deferred final-owner check independently.
    IF TG_OP = 'INSERT' THEN
        PERFORM 1
        FROM njord_control.books AS book
        WHERE book.id = NEW.book_id
        FOR UPDATE;
    ELSIF TG_OP = 'DELETE' THEN
        PERFORM 1
        FROM njord_control.books AS book
        WHERE book.id = OLD.book_id
        FOR UPDATE;
    ELSE
        PERFORM 1
        FROM njord_control.books AS book
        WHERE book.id IN (OLD.book_id, NEW.book_id)
        ORDER BY book.id
        FOR UPDATE;
    END IF;

    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        SELECT principal.database_role INTO database_role
        FROM njord_control.principals AS principal
        WHERE principal.id = OLD.principal_id;
        IF FOUND THEN
            PERFORM njord_control.set_book_role_membership(
                OLD.book_id, database_role, NULL
            );
        END IF;
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        SELECT principal.database_role, principal.disabled_at
        INTO STRICT database_role, principal_disabled_at
        FROM njord_control.principals AS principal
        WHERE principal.id = NEW.principal_id;
        PERFORM njord_control.set_book_role_membership(
            NEW.book_id,
            database_role,
            CASE WHEN principal_disabled_at IS NULL
                 THEN NEW.membership_role ELSE NULL END
        );
        RETURN NEW;
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER book_memberships_sync_cluster_roles
    BEFORE INSERT OR UPDATE OR DELETE ON njord_control.book_memberships
    FOR EACH ROW EXECUTE FUNCTION njord_control.sync_book_role_membership();

CREATE OR REPLACE FUNCTION njord_control.drop_book_access_roles()
RETURNS trigger
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    access_level VARCHAR;
    access_role NAME;
BEGIN
    FOREACH access_level IN ARRAY ARRAY['ro', 'rw', 'admin'] LOOP
        access_role := njord_control.book_access_role(OLD.id, access_level);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = access_role) THEN
            -- This deliberately fails if the physical Book database still
            -- grants capabilities: drop that database before its catalogue.
            EXECUTE format('DROP ROLE %I', access_role);
        END IF;
    END LOOP;
    RETURN OLD;
END;
$$;

CREATE TRIGGER books_drop_cluster_roles
    AFTER DELETE ON njord_control.books
    FOR EACH ROW EXECUTE FUNCTION njord_control.drop_book_access_roles();

CREATE OR REPLACE FUNCTION njord_control.assert_book_has_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    checked_book_id VARCHAR;
    checked_book_ids VARCHAR[];
BEGIN
    IF TG_TABLE_NAME = 'books' THEN
        checked_book_ids := ARRAY[COALESCE(NEW.id, OLD.id)];
    ELSIF TG_OP = 'INSERT' THEN
        checked_book_ids := ARRAY[NEW.book_id];
    ELSIF TG_OP = 'DELETE' THEN
        checked_book_ids := ARRAY[OLD.book_id];
    ELSE
        -- A direct SQL update may move a membership. Both Books must retain an
        -- owner; checking only NEW.book_id would leave the old Book orphaned.
        checked_book_ids := ARRAY[OLD.book_id, NEW.book_id];
    END IF;

    FOREACH checked_book_id IN ARRAY checked_book_ids LOOP
        IF EXISTS (
            SELECT 1 FROM njord_control.books WHERE id = checked_book_id
        ) AND NOT EXISTS (
            SELECT 1
            FROM njord_control.book_memberships
            WHERE book_id = checked_book_id
              AND membership_role = 'owner'
        ) THEN
            RAISE EXCEPTION 'a book must retain at least one owner'
                USING ERRCODE = '23514', CONSTRAINT = 'book_requires_owner';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER memberships_require_book_owner
    AFTER INSERT OR UPDATE OR DELETE ON njord_control.book_memberships
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord_control.assert_book_has_owner();

CREATE CONSTRAINT TRIGGER books_require_owner
    AFTER INSERT OR UPDATE ON njord_control.books
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord_control.assert_book_has_owner();

-- A principal's PostgreSQL role is its durable direct-SQL identity.  Changing
-- the catalogue spelling without atomically renaming the cluster role would
-- leave the old login authorized and the new one unprovisioned, so it is
-- deliberately immutable.
CREATE OR REPLACE FUNCTION njord_control.keep_principal_database_role()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.database_role IS DISTINCT FROM OLD.database_role THEN
        RAISE EXCEPTION 'a principal database role is immutable'
            USING ERRCODE = '23514',
                  CONSTRAINT = 'principal_database_role_immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER principals_keep_database_role
    BEFORE UPDATE OF database_role ON njord_control.principals
    FOR EACH ROW EXECUTE FUNCTION njord_control.keep_principal_database_role();

CREATE OR REPLACE FUNCTION njord_control.current_principal_id()
RETURNS UUID
LANGUAGE SQL
VOLATILE
AS $$
    INSERT INTO njord_control.principals (database_role, display_name)
    VALUES (
        njord_control.invoking_database_role(),
        njord_control.invoking_database_role()
    )
    ON CONFLICT (database_role) DO UPDATE
       SET database_role = EXCLUDED.database_role
    RETURNING id;
$$;

\ir auth.sql

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

-- One private identity directory supplies the same name, GitHub identity, and
-- lifecycle status to global administration and per-Book access pages.
CREATE OR REPLACE VIEW njord_control.principal_directory AS
SELECT
    principal.id AS principal_id,
    principal.database_role,
    COALESCE(principal.display_name, principal.database_role::TEXT) AS display_name,
    COALESCE(identity.provider_login, invitation.github_login) AS github_login,
    COALESCE(identity.provider_subject,
             invitation.invited_provider_subject) AS provider_subject,
    principal.disabled_at,
    CASE
        WHEN principal.disabled_at IS NOT NULL THEN 'disabled'
        WHEN identity.principal_id IS NOT NULL THEN 'active'
        WHEN invitation.revoked_at IS NOT NULL THEN 'revoked'
        WHEN invitation.accepted_at IS NULL
         AND invitation.expires_at <= CURRENT_TIMESTAMP THEN 'expired'
        WHEN invitation.principal_id IS NOT NULL
         AND invitation.accepted_at IS NULL
         AND invitation.revoked_at IS NULL THEN 'pending'
        ELSE 'direct'
    END AS status,
    administrator.principal_id IS NOT NULL AS global_administrator
FROM njord_control.principals AS principal
LEFT JOIN njord_control.principal_identities AS identity
  ON identity.principal_id = principal.id
LEFT JOIN njord_control.github_invitations AS invitation
  ON invitation.principal_id = principal.id
LEFT JOIN njord_control.global_administrators AS administrator
  ON administrator.principal_id = principal.id;

CREATE OR REPLACE VIEW njord_control.book_access_directory AS
SELECT
    membership.book_id,
    directory.*,
    membership.membership_role,
    levels.access_level
FROM njord_control.book_memberships AS membership
JOIN njord_control.principal_directory AS directory
  ON directory.principal_id = membership.principal_id
JOIN njord_control.access_levels AS levels
  ON levels.membership_role = membership.membership_role;

CREATE OR REPLACE FUNCTION njord_control.book_access_level(p_book_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
STABLE
AS $$
    SELECT access.access_level
    FROM njord_control.book_access_directory AS access
    WHERE access.book_id = p_book_id
      AND access.database_role = njord_control.invoking_database_role()
      AND access.disabled_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION njord_control.can_administer_book(p_book_id VARCHAR)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT COALESCE(njord_control.book_access_level(p_book_id) = 'admin', FALSE);
$$;

CREATE OR REPLACE FUNCTION njord_control.can_administer_global()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM njord_control.principal_directory AS principal
        WHERE principal.database_role = njord_control.invoking_database_role()
          AND principal.global_administrator
          AND principal.disabled_at IS NULL
    );
$$;

CREATE OR REPLACE FUNCTION njord_control.require_global_administrator()
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT njord_control.can_administer_global() THEN
        RAISE EXCEPTION 'Global administrator access is required'
            USING ERRCODE = 'P0001', DETAIL = 'GLOBAL_ADMIN_REQUIRED';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.require_book_administrator(
    p_book_id VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT njord_control.can_administer_book(p_book_id) THEN
        RAISE EXCEPTION 'Book administrator access is required'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_ADMIN_REQUIRED';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.shell_page(p_book_id VARCHAR DEFAULT NULL)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT
	'book_option'::VARCHAR,
        1000 + row_number() OVER (ORDER BY books.name, books.id),
        books.id,
        jsonb_build_object(
            'id', books.id,
            'name', books.name,
            'reporting_asset', books.reporting_asset,
            'entity_type', books.entity_type,
            'access_level', access.access_level,
            'selected', books.id = p_book_id
        )
    FROM njord_control.books AS books
    JOIN njord_control.book_access_directory AS access
      ON access.book_id = books.id
     AND access.database_role = njord_control.invoking_database_role()
     AND access.disabled_at IS NULL
    WHERE books.provisioning_state = 'ready'
UNION ALL
    SELECT
        'admin_context'::VARCHAR,
        900::BIGINT,
        'global'::VARCHAR,
        jsonb_build_object(
            'can_administer_global', njord_control.can_administer_global()
        )
UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
$$;

-- Admin is a cluster-wide destination for facts which live outside every
-- Book database. It deliberately has no active-Book selection.
CREATE OR REPLACE FUNCTION api.admin_page()
RETURNS SETOF api.page_component
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM njord_control.require_global_administrator();

    RETURN QUERY
    SELECT
        'admin_context'::VARCHAR,
        900::BIGINT,
        'global'::VARCHAR,
        jsonb_build_object('can_administer_global', TRUE)
    UNION ALL
    SELECT
        'global_user'::VARCHAR,
        1000 + row_number() OVER (
            ORDER BY lower(principal.display_name),
                     principal.database_role::TEXT
        ),
        principal.principal_id::VARCHAR,
        jsonb_build_object(
            'principal_id', principal.principal_id,
            'database_role', principal.database_role,
            'display_name', principal.display_name,
            'github_login', principal.github_login,
            'provider_subject', principal.provider_subject,
            'status', principal.status,
            'book_count', (
                SELECT count(*)
                FROM njord_control.book_memberships AS membership
                WHERE membership.principal_id = principal.principal_id
            ),
	    'global_admin', principal.global_administrator,
	    'current_user', principal.database_role = njord_control.invoking_database_role(),
	    'enabled', principal.disabled_at IS NULL,
	    'can_change_enabled',
	        principal.database_role <> njord_control.invoking_database_role()
	        AND NOT principal.global_administrator,
	    'action_key', CASE WHEN principal.disabled_at IS NULL
	        THEN 'action.admin.disable-user'
	        ELSE 'action.admin.enable-user'
	    END,
	    'action_label', presentation.text(
	        CASE WHEN principal.disabled_at IS NULL
	            THEN 'action.admin.disable-user'
	            ELSE 'action.admin.enable-user'
	        END
	    )
	)
    FROM njord_control.principal_directory AS principal
    UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
END;
$$;

CREATE OR REPLACE FUNCTION api.invite_global_user(
    p_github_login TEXT,
    p_provider_subject BIGINT,
    p_display_name TEXT DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    prepared RECORD;
BEGIN
    PERFORM njord_control.require_global_administrator();

    SELECT * INTO prepared
    FROM njord_control.prepare_github_user(
        p_github_login,
        p_display_name,
        NULL,
        ARRAY[]::VARCHAR[],
        'viewer',
        p_provider_subject
    );

    RETURN QUERY SELECT
        'global_user_result'::VARCHAR,
        899::BIGINT,
        prepared.principal_id::VARCHAR,
        jsonb_build_object(
            'principal_id', prepared.principal_id,
            'database_role', prepared.database_role
        );
    RETURN QUERY SELECT * FROM api.admin_page();
END;
$$;

CREATE OR REPLACE FUNCTION api.set_global_user_enabled(
    p_principal_id UUID,
    p_enabled BOOLEAN
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    target RECORD;
BEGIN
    PERFORM njord_control.require_global_administrator();
    IF p_enabled IS NULL THEN
        RAISE EXCEPTION 'enabled state is required'
            USING ERRCODE = 'P0001', DETAIL = 'ENABLED_STATE_REQUIRED';
    END IF;

    SELECT principal.id, principal.database_role,
           administrator.principal_id IS NOT NULL AS global_admin
    INTO target
    FROM njord_control.principals AS principal
    LEFT JOIN njord_control.global_administrators AS administrator
      ON administrator.principal_id = principal.id
    WHERE principal.id = p_principal_id
    FOR UPDATE OF principal;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'global user does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'GLOBAL_USER_NOT_FOUND';
    END IF;
    IF target.database_role = njord_control.invoking_database_role() THEN
        RAISE EXCEPTION 'use another global administrator to change your own access'
            USING ERRCODE = 'P0001', DETAIL = 'CANNOT_CHANGE_OWN_ACCESS';
    END IF;
    IF target.global_admin AND NOT p_enabled THEN
        RAISE EXCEPTION 'global administrators must be removed from that role before disabling them'
            USING ERRCODE = 'P0001', DETAIL = 'GLOBAL_ADMINISTRATOR_ACTIVE';
    END IF;

    UPDATE njord_control.principals
    SET disabled_at = CASE WHEN p_enabled THEN NULL ELSE clock_timestamp() END
    WHERE id = p_principal_id
      AND (disabled_at IS NULL) = (NOT p_enabled);

    RETURN QUERY SELECT * FROM api.admin_page();
END;
$$;

-- Access control belongs to the cluster control database, not to an
-- individual ledger database.  The gateway composes these SQL-owned rows
-- with the selected Book's settings rows for a Book-management detail page.
CREATE OR REPLACE FUNCTION api.book_acl_page(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);

    RETURN QUERY
    SELECT
        'book_access_context'::VARCHAR,
        8000::BIGINT,
        p_book_id,
        jsonb_build_object(
            'book_id', p_book_id,
            'can_administer', TRUE,
            'current_access_level', 'admin'
        )
    UNION ALL
    SELECT
        'book_access_level_option'::VARCHAR,
        8010 + levels.row_order,
        levels.access_level,
        jsonb_build_object(
            'id', levels.access_level,
            'label', presentation.text(levels.semantic_key)
        )
    FROM njord_control.access_levels AS levels
    UNION ALL
    SELECT
        'book_access'::VARCHAR,
        8100 + row_number() OVER (
            ORDER BY lower(access.display_name), access.database_role::TEXT
        ),
        access.principal_id::TEXT,
        jsonb_build_object(
            'principal_id', access.principal_id,
            'database_role', access.database_role,
            'display_name', access.display_name,
            'github_login', access.github_login,
            'access_level', access.access_level,
            'status', access.status,
            'current_user', access.database_role = njord_control.invoking_database_role()
        )
    FROM njord_control.book_access_directory AS access
    WHERE access.book_id = p_book_id
    UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
END;
$$;

-- Every ACL mutation returns its changed row first, followed by the refreshed
-- SQL-owned page. Keeping that response envelope here makes the three mutation
-- functions focus on authorization and state changes.
CREATE OR REPLACE FUNCTION njord_control.book_access_change_page(
    p_book_id VARCHAR,
    p_principal_id UUID,
    p_database_role NAME,
    p_access_level VARCHAR
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT
        'book_access_result'::VARCHAR,
        7999::BIGINT,
        p_principal_id::VARCHAR,
        jsonb_build_object(
            'principal_id', p_principal_id,
            'database_role', p_database_role,
            'access_level', p_access_level
        )
UNION ALL
    SELECT * FROM api.book_acl_page(p_book_id);
$$;

CREATE OR REPLACE FUNCTION api.invite_book_user(
    p_book_id VARCHAR,
    p_github_login TEXT,
    p_access_level VARCHAR,
    p_provider_subject BIGINT,
    p_display_name TEXT DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    actor_principal_id UUID := njord_control.current_principal_id();
    prepared RECORD;
    membership_role VARCHAR := (
        SELECT levels.membership_role
        FROM njord_control.access_levels AS levels
        WHERE levels.access_level = lower(btrim(p_access_level))
    );
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);
    IF membership_role IS NULL THEN
        RAISE EXCEPTION 'access level must be RO, RW, or Admin'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_ACCESS_LEVEL';
    END IF;
    IF p_provider_subject IS NULL OR p_provider_subject <= 0 THEN
        RAISE EXCEPTION 'GitHub provider subject must be a positive numeric id'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_PROVIDER_SUBJECT';
    END IF;

    SELECT * INTO prepared
    FROM njord_control.prepare_github_user(
        p_github_login,
        p_display_name,
        NULL,
        ARRAY[]::VARCHAR[],
        membership_role,
        p_provider_subject
    );

    INSERT INTO njord_control.book_memberships AS membership (
        book_id, principal_id, membership_role, changed_by
    ) VALUES (
        p_book_id, prepared.principal_id, membership_role, actor_principal_id
    )
    ON CONFLICT ON CONSTRAINT book_memberships_pkey DO UPDATE SET
        membership_role = EXCLUDED.membership_role,
        changed_at = clock_timestamp(),
        changed_by = EXCLUDED.changed_by;

    RETURN QUERY SELECT *
    FROM njord_control.book_access_change_page(
        p_book_id, prepared.principal_id, prepared.database_role,
        lower(btrim(p_access_level))
    );
END;
$$;

CREATE OR REPLACE FUNCTION api.update_book_access(
    p_book_id VARCHAR,
    p_principal_id UUID,
    p_access_level VARCHAR
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    requested_role VARCHAR := (
        SELECT levels.membership_role
        FROM njord_control.access_levels AS levels
        WHERE levels.access_level = lower(btrim(p_access_level))
    );
    target_database_role NAME;
    actor_principal_id UUID := njord_control.current_principal_id();
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);
    IF requested_role IS NULL THEN
        RAISE EXCEPTION 'access level must be RO, RW, or Admin'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_ACCESS_LEVEL';
    END IF;

    SELECT principal.database_role INTO target_database_role
    FROM njord_control.book_memberships AS membership
    JOIN njord_control.principals AS principal
      ON principal.id = membership.principal_id
    WHERE membership.book_id = p_book_id
      AND membership.principal_id = p_principal_id
      AND principal.disabled_at IS NULL
    FOR UPDATE OF membership;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Book access entry does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'BOOK_ACCESS_NOT_FOUND';
    END IF;

    IF target_database_role = njord_control.invoking_database_role()
       AND requested_role <> 'owner' THEN
        RAISE EXCEPTION 'use another administrator to change your own access'
            USING ERRCODE = 'P0001', DETAIL = 'CANNOT_CHANGE_OWN_ACCESS';
    END IF;

    UPDATE njord_control.book_memberships
    SET membership_role = requested_role,
        changed_at = clock_timestamp(),
        changed_by = actor_principal_id
    WHERE book_id = p_book_id
      AND principal_id = p_principal_id;

    RETURN QUERY SELECT *
    FROM njord_control.book_access_change_page(
        p_book_id, p_principal_id, target_database_role,
        lower(btrim(p_access_level))
    );
END;
$$;

CREATE OR REPLACE FUNCTION api.remove_book_access(
    p_book_id VARCHAR,
    p_principal_id UUID
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    target_database_role NAME;
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);

    SELECT principal.database_role INTO target_database_role
    FROM njord_control.book_memberships AS membership
    JOIN njord_control.principals AS principal
      ON principal.id = membership.principal_id
    WHERE membership.book_id = p_book_id
      AND membership.principal_id = p_principal_id
    FOR UPDATE OF membership;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Book access entry does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'BOOK_ACCESS_NOT_FOUND';
    END IF;

    IF target_database_role = njord_control.invoking_database_role() THEN
        RAISE EXCEPTION 'use another administrator to remove your own access'
            USING ERRCODE = 'P0001', DETAIL = 'CANNOT_REMOVE_OWN_ACCESS';
    END IF;

    DELETE FROM njord_control.book_memberships
    WHERE book_id = p_book_id
      AND principal_id = p_principal_id;

    RETURN QUERY SELECT *
    FROM njord_control.book_access_change_page(
        p_book_id, p_principal_id, target_database_role, NULL
    );
END;
$$;

CREATE OR REPLACE FUNCTION api.add_book_page()
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT * FROM api.shell_page(NULL)
UNION ALL
    SELECT
        'page_context'::VARCHAR,
        9000::BIGINT,
        'add-book'::VARCHAR,
        jsonb_build_object(
            'page', 'add-book',
            'reporting_asset', 'GBP',
            'entity_type', 'household',
            'validation', jsonb_build_object(
                'id_required', TRUE,
                'name_required', TRUE,
                'entity_type_required', TRUE,
                'reporting_asset_required', TRUE
            )
        )
UNION ALL
    SELECT
        'asset_option'::VARCHAR,
        10000 + row_number() OVER (ORDER BY assets.id),
        assets.id,
        jsonb_build_object('id', assets.id)
    FROM njord_control.assets AS assets
UNION ALL
    SELECT
        'book_entity_type_option'::VARCHAR,
        11000 + row_number() OVER (
            ORDER BY presentation.text('entity.' || entity_types.id)
        ),
        entity_types.id,
        jsonb_build_object(
            'id', entity_types.id,
            'label', presentation.text('entity.' || entity_types.id)
        )
    FROM njord_control.entity_types AS entity_types;
$$;

-- This function records the user's intent. Database creation is completed by
-- scripts/create-book-database because PostgreSQL forbids CREATE DATABASE in a
-- transaction, including the transaction around a PostgREST RPC.
CREATE OR REPLACE FUNCTION api.create_book(
    p_id VARCHAR,
    p_name VARCHAR,
    p_reporting_asset VARCHAR,
    p_create_standard_accounts BOOLEAN DEFAULT TRUE,
    p_entity_type VARCHAR DEFAULT 'household'
)
RETURNS TABLE (
    id VARCHAR,
    name VARCHAR,
    reporting_asset VARCHAR,
    entity_type VARCHAR
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    normalized_id VARCHAR := NULLIF(lower(btrim(p_id)), '');
    normalized_name VARCHAR := NULLIF(btrim(p_name), '');
    normalized_asset VARCHAR := NULLIF(upper(btrim(p_reporting_asset)), '');
    normalized_entity_type VARCHAR := COALESCE(
        NULLIF(btrim(p_entity_type), ''), 'household'
    );
    principal_id UUID;
    configured_max_books INTEGER;
BEGIN
    IF normalized_id IS NULL OR normalized_id !~ '^[a-z][a-z0-9_-]{0,62}$' THEN
        RAISE EXCEPTION 'book id must be a lowercase PostgreSQL database handle'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_BOOK_ID';
    END IF;
    IF normalized_id IN ('postgres', 'template0', 'template1')
       OR normalized_id = current_database() THEN
        RAISE EXCEPTION 'book id is reserved'
            USING ERRCODE = 'P0001', DETAIL = 'RESERVED_BOOK_ID';
    END IF;
    IF normalized_name IS NULL THEN
        RAISE EXCEPTION 'book name is required'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_NAME_REQUIRED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM njord_control.assets WHERE assets.id = normalized_asset
    ) THEN
        RAISE EXCEPTION 'reporting asset does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'REPORTING_ASSET_NOT_FOUND';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM njord_control.entity_types
        WHERE entity_types.id = normalized_entity_type
    ) THEN
        RAISE EXCEPTION 'book entity type does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_ENTITY_TYPE_NOT_FOUND';
    END IF;

    BEGIN
        SELECT settings.max_books INTO STRICT configured_max_books
        FROM njord_control.settings AS settings
        WHERE settings.singleton
        FOR UPDATE;
    EXCEPTION WHEN no_data_found THEN
        RAISE EXCEPTION 'Njord control settings are missing'
            USING ERRCODE = 'P0001', DETAIL = 'CONTROL_SETTINGS_MISSING';
    END;

    IF EXISTS (
        SELECT 1
        FROM njord_control.books AS existing_book
        WHERE existing_book.id = normalized_id
    ) THEN
        RAISE EXCEPTION 'book already exists'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_ALREADY_EXISTS';
    END IF;
    IF (SELECT count(*) FROM njord_control.books) >= configured_max_books THEN
        RAISE EXCEPTION 'this Njord appliance has reached its configured Book limit'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_LIMIT_REACHED';
    END IF;

    principal_id := njord_control.current_principal_id();

    LOCK TABLE njord_control.global_administrators IN SHARE ROW EXCLUSIVE MODE;
    INSERT INTO njord_control.global_administrators (principal_id, granted_by)
    SELECT principal_id, principal_id
    WHERE NOT EXISTS (SELECT 1 FROM njord_control.global_administrators);

    INSERT INTO njord_control.books (
        id, name, reporting_asset, entity_type
    ) VALUES (
        normalized_id, normalized_name, normalized_asset,
        normalized_entity_type
    )
    ON CONFLICT ON CONSTRAINT books_pkey DO NOTHING;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'book already exists'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_ALREADY_EXISTS';
    END IF;

    INSERT INTO njord_control.book_memberships (
        book_id, principal_id, membership_role, changed_by
    ) VALUES (
        normalized_id, principal_id, 'owner', principal_id
    );

    RETURN QUERY SELECT
        normalized_id, normalized_name, normalized_asset,
        normalized_entity_type;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.mark_book_ready(p_book_id VARCHAR)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    UPDATE njord_control.books
    SET provisioning_state = 'ready'
    WHERE id = p_book_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'book does not exist';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.register_existing_book(
    p_id VARCHAR,
    p_name VARCHAR,
    p_reporting_asset VARCHAR,
    p_entity_type VARCHAR,
    p_database_role NAME DEFAULT current_user
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    owner_principal_id UUID;
BEGIN
    INSERT INTO njord_control.principals (database_role, display_name)
    VALUES (p_database_role, p_database_role)
    ON CONFLICT (database_role) DO UPDATE
       SET database_role = EXCLUDED.database_role
    RETURNING id INTO owner_principal_id;

    LOCK TABLE njord_control.global_administrators IN SHARE ROW EXCLUSIVE MODE;
    INSERT INTO njord_control.global_administrators (principal_id, granted_by)
    SELECT owner_principal_id, owner_principal_id
    WHERE NOT EXISTS (SELECT 1 FROM njord_control.global_administrators);

    INSERT INTO njord_control.books (
        id, name, reporting_asset, entity_type, provisioning_state
    ) VALUES (
        p_id, p_name, p_reporting_asset, p_entity_type, 'ready'
    )
    ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        reporting_asset = EXCLUDED.reporting_asset,
        entity_type = EXCLUDED.entity_type,
        archived_at = NULL,
        provisioning_state = 'ready';

    INSERT INTO njord_control.book_memberships (
        book_id, principal_id, membership_role, changed_by
    ) VALUES (p_id, owner_principal_id, 'owner', owner_principal_id)
    ON CONFLICT (book_id, principal_id) DO UPDATE SET
        membership_role = 'owner',
        changed_at = clock_timestamp(),
        changed_by = owner_principal_id;
END;
$$;

COMMENT ON SCHEMA njord_control IS
    'Cluster-wide authentication, identity, Book catalogue, and membership control plane; no ledger rows.';

-- Control tables and operational functions stay private. Human roles receive
-- only the public control RPCs through sql/grant-control-user.sql.
REVOKE ALL ON SCHEMA njord_control FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA njord_control FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA njord_control FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA njord_control FROM PUBLIC;
REVOKE CREATE ON SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
