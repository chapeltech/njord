-- Variables required from psql: book_id. authenticator_role is optional.
\set ON_ERROR_STOP on
\if :{?authenticator_role}
\else
\set authenticator_role njord_authenticator
\endif

SELECT format(
    'DO $block$ BEGIN IF current_database() IS DISTINCT FROM %L THEN '
    'RAISE EXCEPTION ''wrong Book database: %%'', current_database(); '
    'END IF; END $block$',
    :'book_id'
) \gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I',
              :'book_id', :'authenticator_role') \gexec
