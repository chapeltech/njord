-- Cluster-wide PostgreSQL roles, Book capabilities, and membership invariants.

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
