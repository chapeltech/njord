-- sql/njord.sql installs one complete Book into its own dedicated database.
-- Rebuilding that database is intentionally a clean install: retaining an
-- object here would hide a missing declaration or a stale dependency.
DROP SCHEMA IF EXISTS api CASCADE;
DROP SCHEMA IF EXISTS njord CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
