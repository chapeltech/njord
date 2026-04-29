\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

SET client_min_messages TO warning;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(label text, ok boolean)
RETURNS text AS $$
BEGIN
    IF NOT COALESCE(ok, false) THEN
	RAISE EXCEPTION 'not ok - %', label;
    END IF;

    RETURN 'ok - ' || label;
END;
$$ LANGUAGE plpgsql;

SELECT pg_temp.assert_true(
    'standard account types are loaded',
    (
	SELECT array_agg(id ORDER BY id) = ARRAY['A', 'E', 'I', 'L', 'Q']::varchar[]
	FROM acct_types
    )
);

SELECT pg_temp.assert_true(
    'standard accounts are loaded',
    (
	SELECT count(*) = 3
	FROM accts
	WHERE id IN ('Opening Balance', 'Income', 'Expenses')
    )
);

SELECT pg_temp.assert_true(
    'currency reference data is loaded',
    EXISTS (SELECT 1 FROM asset WHERE id = 'GBP') AND
    EXISTS (SELECT 1 FROM asset WHERE id = 'USD')
);

SELECT pg_temp.assert_true(
    'USD valuation to GBP is loaded',
    EXISTS (
	SELECT 1
	FROM current_valuations
	WHERE src = 'USD' AND round(rate, 5) = 0.81169
    )
);

INSERT INTO accts (id, type, atype)
VALUES ('USD Expenses', 'E', 'USD');

CALL open_account('Broker USD', '2026-01-01', 'A', 'USD', 123.20);

SELECT pg_temp.assert_true(
    'open_account creates the asset account',
    EXISTS (
	SELECT 1
	FROM accts
	WHERE id = 'Broker USD' AND type = 'A' AND atype = 'USD'
    )
);

SELECT pg_temp.assert_true(
    'open_account creates a balanced two-line transaction',
    (
	SELECT count(*) = 2 AND sum(amt) = 0
	FROM xaction_bits
	WHERE xid = (
	    SELECT max(xid)
	    FROM xactions
	)
    )
);

CALL create_simple_xaction('2026-01-15', 'Broker USD', 'USD Expenses', -23.20);

SELECT pg_temp.assert_true(
    'ledger reports account entries',
    (
	SELECT count(*) = 2 AND sum(amt) = 100.00
	FROM ledger('Broker USD')
    )
);

SELECT pg_temp.assert_true(
    'full_ledger reports running balances',
    (
	SELECT runningtotal = 100.00
	FROM full_ledger
	WHERE acct = 'Broker USD'
	ORDER BY date DESC, xid DESC
	LIMIT 1
    )
);

SELECT pg_temp.assert_true(
    'balance_sheet values assets in GBP',
    (
	SELECT posttax = 81.17
	FROM balance_sheet
	WHERE account = 'Broker USD'
    )
);

SELECT pg_temp.assert_true(
    'bsheet reports balances as of a date',
    (
	SELECT posttax = 81.17
	FROM bsheet('2026-01-31')
	WHERE account = 'Broker USD'
    )
);

CALL create_xaction(
    '2026-02-01',
    FALSE,
    ROW('Broker USD', -10.00, 'Unmatched row')::xaction_elem
);

SELECT pg_temp.assert_true(
    'unresolved transactions are tracked',
    (
	SELECT count(*) = 1
	FROM xaction_unresolved
    )
);

CREATE TEMP TABLE import (
    date varchar,
    vendor varchar,
    amt varchar
);

INSERT INTO import (date, vendor, amt)
VALUES
    ('2026-02-05', 'Coffee', '-3.50'),
    ('2026-02-06', 'Refund', '1.25');

CALL import_csv('Broker USD');

SELECT pg_temp.assert_true(
    'import_csv creates ledger lines from staging rows',
    (
	SELECT count(*) = 2
	FROM xaction_bits
	WHERE acct = 'Broker USD'
	  AND comment IN ('Coffee', 'Refund')
    )
);

DROP TABLE import;
