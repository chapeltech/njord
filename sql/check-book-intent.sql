-- Variables required from psql:
--   book_id, book_name, reporting_asset, entity_type
SELECT count(*) = 1 AS intent_matches
FROM njord_control.books
WHERE id = :'book_id'
  AND name = :'book_name'
  AND reporting_asset = :'reporting_asset'
  AND entity_type = :'entity_type'
  AND provisioning_state = 'provisioning'
\gset

\if :intent_matches
\else
DO $njord$
BEGIN
    RAISE EXCEPTION 'Book provisioning intent does not match the requested database';
END
$njord$;
\endif
