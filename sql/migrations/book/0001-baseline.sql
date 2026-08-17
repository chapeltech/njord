CREATE TABLE njord.schema_migrations (
    version INTEGER PRIMARY KEY CHECK (version > 0),
    name VARCHAR NOT NULL UNIQUE,
    checksum VARCHAR(64) NOT NULL CHECK (checksum ~ '^[0-9a-f]{64}$'),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON TABLE njord.schema_migrations IS
    'Immutable ordered history of this Book database product schema.';

REVOKE ALL ON TABLE njord.schema_migrations FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.adapter_status()
RETURNS TABLE (database NAME, schema_version INTEGER)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT current_database(), max(migration.version)
    FROM njord.schema_migrations AS migration;
$$;

COMMENT ON FUNCTION api.adapter_status() IS
    'Authenticated Book database identity and durable API schema version.';
