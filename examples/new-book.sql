-- Variables required from psql:
--   book_id, book_name, reporting_asset, entity_type
\ir ../sql/njord.sql

SELECT *
FROM api.create_book(
    :'book_id',
    :'book_name',
    :'reporting_asset',
    :'create_standard_accounts'::BOOLEAN,
    :'entity_type'
);

\ir ../sql/book-database.sql
