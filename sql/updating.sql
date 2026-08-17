--
-- create_xaction will create a "complicated" transaction.  This one
-- allows split transactions and the like.  Essentially, this is a variadic
-- function which consumes a timestamp and a list of rows which comprise a
-- single split transaction.
--
-- Final transaction validity is checked by the deferred constraint
-- triggers in schema.sql after this procedure has written every line.

CREATE TYPE xaction_elem AS (
	acct VARCHAR,
	amt NUMERIC(100,5),
	memo VARCHAR
);

CREATE OR REPLACE PROCEDURE create_xaction_v(
	book	 VARCHAR,
	t	 TIMESTAMP,
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
	SELECT NULLIF(btrim(memo), '')
	INTO tx_comment
	FROM unnest(xs)
	WHERE memo IS NOT NULL
	  AND btrim(memo) <> ''
	LIMIT 1;
    ELSE
	SELECT CASE WHEN count(DISTINCT memo) = 1 THEN min(memo) END
	INTO tx_comment
	FROM (
	    SELECT NULLIF(btrim(memo), '') AS memo
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
		       WHEN NULLIF(btrim(x.memo), '') = tx_comment THEN NULL
		       ELSE NULLIF(btrim(x.memo), '')
		   END
	       );
    END LOOP;
END;
$$;

CREATE OR REPLACE PROCEDURE create_xaction(
	book VARCHAR,
	t TIMESTAMP,
	VARIADIC xaction_bits XACTION_ELEM[])
LANGUAGE SQL
AS $$
    CALL create_xaction_v(book, t, xaction_bits);
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

    CALL create_xaction(book, t,
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
    equity_root VARCHAR;
BEGIN
    SELECT books.reporting_asset
    INTO STRICT reporting_asset
    FROM books
    WHERE books.id = book;

    account_id := CASE
	WHEN atype = reporting_asset THEN 'Opening Balance'
	ELSE 'Opening Balance (' || atype || ')'
    END;

    SELECT accts.id
    INTO equity_root
    FROM accts
    WHERE accts.book_id = book
      AND accts.type = 'Q'
      AND accts.parent_id IS NULL;

    SELECT type, accts.atype
    INTO existing_type, existing_asset
    FROM accts
    WHERE book_id = book
      AND id = account_id;

    IF NOT FOUND THEN
	IF equity_root IS NULL THEN
	    RAISE EXCEPTION 'book % does not have an Equity root account', book
		USING ERRCODE = '23514',
		      CONSTRAINT = 'opening_balance_equity_root';
	END IF;

	INSERT INTO accts (
	    book_id, id, name, type, atype, parent_id, account_kind, placeholder
	)
	VALUES (
	    book, account_id, account_id, 'Q', atype, equity_root, 'posting', FALSE
	);
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
	acct_type VARCHAR,
	atype	VARCHAR,
	amt	NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
    opening_account VARCHAR;
BEGIN
    INSERT INTO accts (
	book_id, id, name, type, atype, parent_id, account_kind, placeholder
    )
    SELECT
	$1, $2, $2, $4, $5, root.id,
	CASE WHEN $4 = 'A' THEN 'bank' ELSE 'posting' END,
	FALSE
    FROM accts AS root
    WHERE root.book_id = $1
	AND root.type = $4
      AND root.parent_id IS NULL;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book % does not have a root account for class %', book, acct_type
	    USING ERRCODE = '23514', CONSTRAINT = 'account_requires_root';
    END IF;

	IF amt IS NULL THEN
	    RAISE EXCEPTION 'opening balance must be a finite number or zero'
		USING ERRCODE = '23514',
		      CONSTRAINT = 'opening_balance_required';
	END IF;
	IF NOT njord.is_finite(amt) THEN
	    RAISE EXCEPTION 'opening balance must be finite'
		USING ERRCODE = '23514',
		      CONSTRAINT = 'opening_balance_finite';
	END IF;

	-- A zero opening balance needs no ledger event. The account itself remains
	-- useful and can receive its first posting later.
	IF amt <> 0 THEN
	    opening_account := opening_balance_account(book, atype);
	    CALL create_simple_xaction(book, date, acct, opening_account, amt);
	END IF;
END;
$$;

--
-- Import rows are deliberately left in the caller's staging table.  A
-- one-sided bank row is not an accounting transaction: it must be classified
-- with a balancing account before a normal create_xaction call may record it.

CREATE OR REPLACE PROCEDURE import_csv(book VARCHAR, acct1 VARCHAR)
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE 'import rows for %.% remain staged; classify and balance them before recording transactions',
	book,
	acct1;
END;
$$;
