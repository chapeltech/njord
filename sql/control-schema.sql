-- Control-catalogue tables and their compact reference data.

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
