-- Variables required from psql: database_role
-- Cluster role provisioning is administrative; accounting permissions are
-- granted separately for the control database and each Book database.
\set role_login LOGIN
\set role_kind human
\ir ensure-unprivileged-role.sql
