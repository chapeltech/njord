SET DATESTYLE = 'European';

-- Keep imported bank rows in a session-local staging table. import_csv emits
-- guidance only: callers must classify each row with a balancing account before
-- recording it as a ledger transaction.
CREATE TEMP TABLE import (
    date	VARCHAR,
    vendor	VARCHAR,
    amt		VARCHAR
);
COPY import(date, vendor, amt) FROM STDIN DELIMITER ',' CSV;

CALL import_csv(:'INPUT_BOOK', :'INPUT_ACCOUNT');
