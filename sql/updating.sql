--
-- create_xaction will create a "complicated" transaction.  This one
-- allows split transactions and the like.  Essentially, this is a variadic
-- function which consumes a timestamp and a list of rows which comprise a
-- single split transaction.
--
-- XXXrcd: this is where we will likely put the CONSTRAINT logic as all
--         of the rows of the transaction must add up to zero.

CREATE TYPE xaction_elem AS (
	acct VARCHAR,
	amt NUMERIC(100,5),
	vendor VARCHAR
);

CREATE OR REPLACE PROCEDURE create_xaction_v(
	t	 TIMESTAMP,
	resolved BOOLEAN,
	xs	 XACTION_ELEM[])
LANGUAGE plpgsql
AS $$
DECLARE
	ourxid	INTEGER;
	x	xaction_elem;
BEGIN
    INSERT INTO xactions (xid, date)
	VALUES (DEFAULT, t)
	RETURNING xid INTO ourxid;
    FOREACH x IN ARRAY xs LOOP
	INSERT INTO xaction_bits (xid, acct, amt, comment)
	       VALUES (ourxid, x.acct, x.amt, x.vendor);
    END LOOP;
    IF NOT resolved THEN
	RAISE NOTICE 'inserting unresolved xaction (%)', ourxid;
	INSERT INTO xaction_unresolved VALUES (ourxid);
    END IF;
END;
$$;

CREATE OR REPLACE PROCEDURE create_xaction_nc(
	t TIMESTAMP,
	resolved BOOLEAN,
	VARIADIC xaction_bits XACTION_ELEM[])
LANGUAGE plpgsql
AS $$
BEGIN
    CALL create_xaction_v(t, resolved, xaction_bits);
END;
$$;

CREATE OR REPLACE PROCEDURE create_xaction(
	t TIMESTAMP,
	resolved BOOLEAN,
	VARIADIC xaction_bits XACTION_ELEM[])
LANGUAGE plpgsql
AS $$
BEGIN
    CALL create_xaction_v(t, resolved, xaction_bits);
    COMMIT;
END;
$$;

--
-- create_simple_xaction will create a "simple" transaction.  That is,
-- a transaction which is a simple move from one account to another in
-- the same currency with no splits.
--
-- XXXrcd: should check that accounts have the same underlying
--         asset type or raise an exception.
--
-- XXXrcd: this doesn't need CONSTRAINT logic because it can't violate
--         the constaints.

CREATE OR REPLACE PROCEDURE create_simple_xaction(
	t TIMESTAMP,
	acct1 VARCHAR,
	acct2 VARCHAR,
	amt NUMERIC)
LANGUAGE plpgsql
AS $$
DECLARE
	ourxid INTEGER;
BEGIN
    CALL create_xaction(t, TRUE,
			ROW(acct1, amt, NULL),
			ROW(acct2, -amt, NULL));
END;
$$;

CREATE OR REPLACE PROCEDURE open_account (
	acct	VARCHAR,
	date	TIMESTAMP,
	type	VARCHAR,
	atype	VARCHAR,
	amt	NUMERIC)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO accts VALUES (acct, type, atype);
    CALL create_simple_xaction(date, acct, 'Opening Balance', amt);
END;
$$;

CREATE OR REPLACE PROCEDURE open_account_pretax (
	acct	VARCHAR,
	date	TIMESTAMP,
	atype	VARCHAR,
	amt	NUMERIC)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO accts VALUES (acct, 'A', atype, 0.6);
    CALL create_simple_xaction(date, acct, 'Opening Balance', amt);
END;
$$;

--
-- XXXrcd: for now import_csv() assumes that the the first three
--         columns are date, description, amount.  The rest are
--         ignored...
-- XXXrcd: we import imbalanced transactions as we intend to fix
--         them later, perhaps heuristically, perhaps with human
--         interaction...

CREATE OR REPLACE PROCEDURE import_csv(acct1 VARCHAR)
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
	    CALL create_xaction_nc(t, TRUE, ROW(acct1, value, v));
	END LOOP;
END;
$$;
