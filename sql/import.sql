SET DATESTYLE = 'European';
--
-- We use a temp table to give us a chance to manipulate the
-- data on the way in.
-- XXXrcd: rename table?  scoping?
CREATE TEMP TABLE import (
    date	VARCHAR,
    vendor	VARCHAR,
    amt		VARCHAR
);
COPY import(date, vendor, amt) FROM STDIN DELIMITER ',' CSV;

CALL import_csv(:'INPUT_BOOK', :'INPUT_ACCOUNT');
DROP TABLE import;
