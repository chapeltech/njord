-- Book creation intent and catalogue provisioning transitions.

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
