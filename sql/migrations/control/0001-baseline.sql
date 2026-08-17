CREATE TABLE njord_control.schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name VARCHAR NOT NULL UNIQUE,
    checksum VARCHAR(64) NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE njord_control.schema_migrations IS
    'Immutable ordered history of control-database product migrations.';

REVOKE ALL ON TABLE njord_control.schema_migrations FROM PUBLIC;

CREATE OR REPLACE FUNCTION njord_control.schema_version()
RETURNS INTEGER
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT max(migration.version)
    FROM njord_control.schema_migrations AS migration;
$$;

COMMENT ON FUNCTION njord_control.schema_version() IS
    'Current durable control-database schema version.';

REVOKE ALL ON FUNCTION njord_control.schema_version() FROM PUBLIC;
