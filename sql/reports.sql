
-- TYPE | Account name | Actual Amount | GBP Amount

CREATE OR REPLACE VIEW balance_sheet_old AS
    SELECT accts.type, accts.id, sum(amt * valuations.rate)
	FROM accts
	LEFT JOIN xaction_bits ON accts.id = acct
	LEFT JOIN xactions ON xactions.xid = xaction_bits.xid
	LEFT JOIN valuations ON valuations.src = accts.atype
    WHERE accts.type = 'A'
    GROUP BY accts.type, accts.id
UNION
    SELECT 'Libility', accts.id, sum(amt * valuations.rate)
	FROM accts
	LEFT JOIN xaction_bits ON accts.id = acct
	LEFT JOIN xactions ON xactions.xid = xaction_bits.xid
	LEFT JOIN valuations ON valuations.src = accts.atype
    WHERE accts.type = 'L'
    GROUP BY accts.type, accts.id
;

CREATE OR REPLACE VIEW current_valuations AS
    SELECT  src,
	    (array_agg(rate ORDER BY date DESC))[1] AS rate
	FROM valuations
	WHERE dst = 'GBP'
	GROUP BY src;

CREATE OR REPLACE FUNCTION
fmt_asset (value NUMERIC(100,5), atype VARCHAR)
RETURNS VARCHAR AS $$
BEGIN
    IF value != 1 AND atype != 'GBP' THEN
	RETURN round(value, 2) || ' ' || atype;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE VIEW balance_sheet AS
    WITH t AS (
	SELECT
		accts.type,
		accts.atype,
		accts.pretax AS istaxed,
		accts.id as Account,
		sum(amt) AS Value,
		sum(amt * current_valuations.rate) AS pretax,
		sum(amt * current_valuations.rate * accts.pretax) AS posttax
	FROM accts
	LEFT JOIN xaction_bits ON accts.id = acct
	LEFT JOIN xactions ON xactions.xid = xaction_bits.xid
	LEFT JOIN current_valuations ON current_valuations.src = accts.atype
	WHERE accts.type = 'A' OR accts.type = 'L'
    GROUP BY accts.id
    )
    SELECT  Account,
	    fmt_asset(value, atype) AS origcurrency,
	    CASE WHEN istaxed != 1
		THEN round(pretax, 2)
		ELSE NULL
	    END AS pretax,
	    round(posttax, 2) AS posttax
    FROM t
    ORDER BY type, Account;

--
-- XXXrcd: we should really give this one a proper name...
-- XXXrcd: which comment should I really be choosing?

CREATE OR REPLACE VIEW join_them AS
    SELECT accts.id, type, atype, pretax, xactions.xid,
	   amt, xactions.date, xaction_bits.comment
	FROM accts
	JOIN xaction_bits ON accts.id = acct
	JOIN xactions	  ON xactions.xid = xaction_bits.xid
;

--
-- XXXrcd: hmmm, is there really any difference between using a
--         CREATE VIEW and CREATE FUNCTION which returns a table?
--         In any case, the approach below allows me to create what
--         essentially acts like a VIEW but with a parameter of the
--         date...

CREATE OR REPLACE FUNCTION bsheet(d TIMESTAMP)
RETURNS TABLE (
	account		VARCHAR,
	origcurrency	VARCHAR,
	pretax		NUMERIC,
	posttax		NUMERIC
) AS $$
    WITH t AS (
	SELECT
		accts.type,
		accts.atype,
		accts.pretax AS istaxed,
		accts.id as Account,
		sum(amt) AS Value,
		sum(amt * current_valuations.rate) AS pretax,
		sum(amt * current_valuations.rate * accts.pretax) AS posttax
	FROM join_them AS accts
	LEFT JOIN current_valuations ON current_valuations.src = accts.atype
	WHERE (accts.type = 'A' OR accts.type = 'L')
	  AND accts.date <= d
    GROUP BY accts.id, accts.type, accts.atype, accts.pretax
    )
    SELECT  Account,
	    fmt_asset(value, atype) AS origcurrency,
	    CASE WHEN istaxed != 1
		THEN round(pretax, 2)
		ELSE NULL
	    END AS pretax,
	    round(posttax, 2) AS posttax
    FROM t
    ORDER BY type, Account;
$$ LANGUAGE SQL;

CREATE OR REPLACE VIEW valuations_with_reciprocals AS
    SELECT date, src, dst, rate FROM valuations
    UNION
    SELECT date, dst AS src, src AS dst, 1/rate FROM valuations
	WHERE src != dst;
;

CREATE OR REPLACE VIEW full_valuations AS
    WITH RECURSIVE vals AS (
	    SELECT src, dst, rate
	    FROM valuations_with_reciprocals
	UNION
	    SELECT v.src, vs.dst, CAST ((v.rate * vs.rate) AS NUMERIC(100,5))
	    FROM valuations_with_reciprocals v
	    INNER JOIN vals vs ON vs.src = v.dst WHERE v.src != vs.dst
    ) SELECT * FROM vals;

CREATE OR REPLACE VIEW full_ledger AS
        SELECT
		accts.id AS acct,
                CAST (xactions.date AS date),
                xaction_bits.xid,
                amt,
                sum(amt) OVER (PARTITION BY accts.id
			       ORDER BY xactions.date, xaction_bits.xid)
			RunningTotal,
                xaction_bits.comment
        FROM accts
        LEFT JOIN xaction_bits ON accts.id = acct
        LEFT JOIN xactions ON xactions.xid = xaction_bits.xid;

--
-- XXXrcd: okay, now we should make a parameterised view that
--         reprents the ledger from the point of view of a
--         single account.

CREATE OR REPLACE FUNCTION ledger(a VARCHAR) RETURNS TABLE (
	date		DATE,
	xid		INTEGER,
--	transfer	VARCHAR,
	amt		NUMERIC,
--	balance		NUMERIC,
	description	VARCHAR
) AS $$
	SELECT
		CAST (xactions.date AS date),
		xaction_bits.xid,
		amt,
		xaction_bits.comment
	FROM accts
	LEFT JOIN xaction_bits ON accts.id = acct
	LEFT JOIN xactions ON xactions.xid = xaction_bits.xid
	WHERE accts.id = a;
$$ LANGUAGE SQL;


--CREATE OR REPLACE VIEW vtest AS
--   WITH RECURSIVE vals AS (
--	SELECT src, dst, rate
--	FROM valuations WHERE dst = 'GBP'
--	UNION
--	SELECT v.src, vs.dst, CAST ((v.rate * vs.rate) AS NUMERIC(100,5))
--	FROM valuations v
--	INNER JOIN vals vs ON vs.src = v.dst
--   ) SELECT * FROM vals;
--
--CREATE OR REPLACE VIEW vtest AS
--   WITH RECURSIVE vals AS (
--	SELECT src, dst, rate
--	FROM valuations WHERE dst = 'GBP'
--	UNION
--	SELECT vs.src, vs.dst, CAST ((v.rate * vs.rate) AS NUMERIC(100,5))
--	FROM valuations v
--	INNER JOIN vals vs ON vs.src = v.dst
--   ) SELECT * FROM vals;


--
--
-- XXXrcd: I want to have an expected income report.  To do this,
--         we'll need to annotate assets and/or accounts with yields.
--         For non-cash assets, this may attach to the asset class
--         itself, e.g. NYSE:DHS.  But for cash, it obviously needs
--         to attach to the account.  We should also estimate in the
--         tax implications, perhaps?
