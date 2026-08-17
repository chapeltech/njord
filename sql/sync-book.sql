-- Variables required from psql:
--   book_id, book_name, reporting_asset, entity_type, archived_at
UPDATE njord_control.books
SET name = :'book_name',
    reporting_asset = :'reporting_asset',
    entity_type = :'entity_type',
    archived_at = NULLIF(:'archived_at', '')::TIMESTAMPTZ
WHERE id = :'book_id';

\if :{?require_synced_book}
\else
\set require_synced_book true
\endif

SELECT count(*) = 1 AS synced
FROM njord_control.books
WHERE id = :'book_id'
\gset

\if :require_synced_book
\if :synced
\else
DO $njord$
BEGIN
    RAISE EXCEPTION 'Book is missing from the control catalogue';
END
$njord$;
\endif
\endif
