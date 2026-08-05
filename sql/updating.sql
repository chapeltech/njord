--
-- create_xaction will create a "complicated" transaction.  This one
-- allows split transactions and the like.  Essentially, this is a variadic
-- function which consumes a timestamp and a list of rows which comprise a
-- single split transaction.
--
-- Final resolved-transaction validity is checked by the deferred constraint
-- triggers in schema.sql after this procedure has written every line.

CREATE TYPE xaction_elem AS (
	acct VARCHAR,
	amt NUMERIC(100,5),
	vendor VARCHAR
);

CREATE OR REPLACE PROCEDURE create_xaction_v(
	book	 VARCHAR,
	t	 TIMESTAMP,
	resolved BOOLEAN,
	xs	 XACTION_ELEM[])
LANGUAGE plpgsql
AS $$
DECLARE
	ourxid	INTEGER;
	x	xaction_elem;
	tx_comment VARCHAR;
	line_count INTEGER;
BEGIN
    line_count := COALESCE(array_length(xs, 1), 0);

    IF line_count = 0 THEN
	RAISE EXCEPTION 'transactions require at least one line'
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'xaction_requires_lines';
    END IF;

    IF line_count = 2 THEN
	SELECT NULLIF(btrim(vendor), '')
	INTO tx_comment
	FROM unnest(xs)
	WHERE vendor IS NOT NULL
	  AND btrim(vendor) <> ''
	LIMIT 1;
    ELSE
	SELECT CASE WHEN count(DISTINCT memo) = 1 THEN min(memo) END
	INTO tx_comment
	FROM (
	    SELECT NULLIF(btrim(vendor), '') AS memo
	    FROM unnest(xs)
	) AS memos
	WHERE memo IS NOT NULL;
    END IF;

    INSERT INTO xactions (book_id, xid, date, comment)
	VALUES (book, DEFAULT, t, tx_comment)
	RETURNING xid INTO ourxid;
    FOREACH x IN ARRAY xs LOOP
	INSERT INTO xaction_bits (book_id, xid, acct, amt, comment)
	       VALUES (
		   book,
		   ourxid,
		   x.acct,
		   x.amt,
		   CASE
		       WHEN line_count = 2 THEN NULL
		       WHEN NULLIF(btrim(x.vendor), '') = tx_comment THEN NULL
		       ELSE NULLIF(btrim(x.vendor), '')
		   END
	       );
    END LOOP;
    IF NOT resolved THEN
	RAISE NOTICE 'inserting unresolved xaction (%:%)', book, ourxid;
	INSERT INTO xaction_unresolved VALUES (book, ourxid);
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE create_xaction_nc(
	book VARCHAR,
	t TIMESTAMP,
	resolved BOOLEAN,
	VARIADIC xaction_bits XACTION_ELEM[])
LANGUAGE plpgsql
AS $$
BEGIN
    CALL create_xaction_v(book, t, resolved, xaction_bits);
END;
$$;

CREATE OR REPLACE PROCEDURE create_xaction(
	book VARCHAR,
	t TIMESTAMP,
	resolved BOOLEAN,
	VARIADIC xaction_bits XACTION_ELEM[])
LANGUAGE plpgsql
AS $$
BEGIN
    CALL create_xaction_v(book, t, resolved, xaction_bits);
END;
$$;

--
-- create_simple_xaction will create a "simple" transaction.  That is,
-- a transaction which is a simple move from one account to another in
-- the same currency with no splits.
--
-- A simple transaction must move value between accounts in the same asset.

CREATE OR REPLACE PROCEDURE create_simple_xaction(
	book VARCHAR,
	t TIMESTAMP,
	acct1 VARCHAR,
	acct2 VARCHAR,
	amt NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
	asset1 VARCHAR;
	asset2 VARCHAR;
BEGIN
    SELECT atype INTO STRICT asset1
    FROM accts
    WHERE book_id = book AND id = acct1;

    SELECT atype INTO STRICT asset2
    FROM accts
    WHERE book_id = book AND id = acct2;

    IF asset1 <> asset2 THEN
	RAISE EXCEPTION 'accounts % and % use different assets (% and %)',
	    acct1, acct2, asset1, asset2
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'simple_xaction_same_asset';
    END IF;

    CALL create_xaction(book, t, TRUE,
			ROW(acct1, amt, NULL),
			ROW(acct2, -amt, NULL));
END;
$$;

CREATE OR REPLACE FUNCTION opening_balance_account(
    book VARCHAR,
    atype VARCHAR
)
RETURNS VARCHAR
LANGUAGE plpgsql
AS $$
DECLARE
    reporting_asset VARCHAR;
    account_id VARCHAR;
    existing_type VARCHAR;
    existing_asset VARCHAR;
BEGIN
    SELECT books.reporting_asset
    INTO STRICT reporting_asset
    FROM books
    WHERE books.id = book;

    account_id := CASE
	WHEN atype = reporting_asset THEN 'Opening Balance'
	ELSE 'Opening Balance (' || atype || ')'
    END;

    SELECT type, accts.atype
    INTO existing_type, existing_asset
    FROM accts
    WHERE book_id = book
      AND id = account_id;

    IF NOT FOUND THEN
	INSERT INTO accts (book_id, id, type, atype)
	VALUES (book, account_id, 'Q', atype);
    ELSIF existing_type <> 'Q' OR existing_asset <> atype THEN
	RAISE EXCEPTION 'opening balance account % has type % and asset %, expected Q and %',
	    account_id, existing_type, existing_asset, atype
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'opening_balance_account_shape';
    END IF;

    RETURN account_id;
END;
$$;

CREATE OR REPLACE PROCEDURE open_account (
	book	VARCHAR,
	acct	VARCHAR,
	date	TIMESTAMP,
	type	VARCHAR,
	atype	VARCHAR,
	amt	NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    opening_account VARCHAR;
BEGIN
    INSERT INTO accts (book_id, id, type, atype) VALUES (book, acct, type, atype);
    opening_account := opening_balance_account(book, atype);
    CALL create_simple_xaction(book, date, acct, opening_account, amt);
END;
$$;

CREATE OR REPLACE PROCEDURE open_account_pretax (
	book	VARCHAR,
	acct	VARCHAR,
	date	TIMESTAMP,
	atype	VARCHAR,
	amt	NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    opening_account VARCHAR;
BEGIN
    INSERT INTO accts (book_id, id, type, atype, pretax)
	VALUES (book, acct, 'A', atype, 0.6);
    opening_account := opening_balance_account(book, atype);
    CALL create_simple_xaction(book, date, acct, opening_account, amt);
END;
$$;

--
-- XXXrcd: for now import_csv() assumes that the the first three
--         columns are date, description, amount.  The rest are
--         ignored...
-- XXXrcd: we import imbalanced transactions as we intend to fix
--         them later, perhaps heuristically, perhaps with human
--         interaction...

CREATE OR REPLACE PROCEDURE import_csv(book VARCHAR, acct1 VARCHAR)
LANGUAGE plpgsql
AS $$
DECLARE
	t TIMESTAMP;
	v VARCHAR;
	value NUMERIC(100,5);
BEGIN

    FOR t, v, value IN
	    SELECT
		CAST(date AS TIMESTAMP) AS t,
		vendor AS v,
		CAST(regexp_replace(amt, ',', '', 'g') AS NUMERIC) AS value
	    FROM import
	LOOP
	    CALL create_xaction_nc(book, t, FALSE, ROW(acct1, value, v));
	END LOOP;
END;
$$;
