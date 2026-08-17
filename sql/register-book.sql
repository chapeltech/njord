-- Variables required from psql:
--   book_id, book_name, reporting_asset, entity_type, database_role
SELECT njord_control.register_existing_book(
    :'book_id',
    :'book_name',
    :'reporting_asset',
    :'entity_type',
    :'database_role'
);
