-- Ordered control-database loader for a database-per-Book Njord installation.
--
-- This database contains identities, invitations, browser sessions, and Book
-- discovery only. Accounting rows, report-pack configuration, and ledger
-- mutations belong to the individual Book databases loaded by sql/njord.sql.

DROP SCHEMA IF EXISTS api CASCADE;
DROP SCHEMA IF EXISTS njord_control CASCADE;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

CREATE SCHEMA njord_control;
CREATE SCHEMA api;

\ir presentation.sql
\ir control-schema.sql
\ir control-roles.sql
\ir auth.sql
\ir control-gateway.sql
\ir control-pages.sql
\ir control-lifecycle.sql

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
