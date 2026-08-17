-- Variables required from psql:
--   database_role, book_id, book_name, reporting_asset, entity_type,
--   create_standard_accounts
SET ROLE :"database_role";
SELECT *
FROM api.create_book(
    :'book_id',
    :'book_name',
    :'reporting_asset',
    :'create_standard_accounts'::BOOLEAN,
    :'entity_type'
);
RESET ROLE;
