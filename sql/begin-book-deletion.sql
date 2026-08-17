-- Variable required from psql: book_id
UPDATE njord_control.books
SET provisioning_state = 'deleting'
WHERE id = :'book_id'
  AND provisioning_state = 'ready';

SELECT count(*) = 1 AS deletion_started
FROM njord_control.books
WHERE id = :'book_id'
  AND provisioning_state = 'deleting'
\gset

\if :deletion_started
\else
DO $njord$
BEGIN
    RAISE EXCEPTION 'Book is not ready for deletion';
END
$njord$;
\endif
