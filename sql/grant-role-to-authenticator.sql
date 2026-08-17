-- Variable required from psql: database_role. authenticator_role defaults to
-- the product runtime role so callers cannot accidentally grant browser roles
-- to the PostgreSQL owner through current_user.
\if :{?authenticator_role}
\else
\set authenticator_role njord_authenticator
\endif
SELECT format('GRANT %I TO %I', :'database_role', :'authenticator_role') \gexec
