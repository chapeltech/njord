
-- TYPE | Account name | Actual Amount | GBP Amount

CREATE OR REPLACE VIEW balance_sheet_old AS
    SELECT accts.book_id, accts.type, accts.id, sum(amt * valuations.rate)
	FROM accts
	LEFT JOIN xaction_bits
	    ON accts.book_id = xaction_bits.book_id
	   AND accts.id = acct
	LEFT JOIN xactions
	    ON xactions.book_id = xaction_bits.book_id
	   AND xactions.xid = xaction_bits.xid
	LEFT JOIN valuations ON valuations.src = accts.atype
    WHERE accts.type = 'A'
    GROUP BY accts.book_id, accts.type, accts.id
UNION
    SELECT accts.book_id, 'Libility', accts.id, sum(amt * valuations.rate)
	FROM accts
	LEFT JOIN xaction_bits
	    ON accts.book_id = xaction_bits.book_id
	   AND accts.id = acct
	LEFT JOIN xactions
	    ON xactions.book_id = xaction_bits.book_id
	   AND xactions.xid = xaction_bits.xid
	LEFT JOIN valuations ON valuations.src = accts.atype
    WHERE accts.type = 'L'
    GROUP BY accts.book_id, accts.type, accts.id
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
		accts.book_id,
		accts.type,
		accts.atype,
		accts.pretax AS istaxed,
		accts.id as Account,
		sum(amt) AS Value,
		sum(amt * current_valuations.rate) AS pretax,
		sum(amt * current_valuations.rate * accts.pretax) AS posttax
	FROM accts
	LEFT JOIN xaction_bits
	    ON accts.book_id = xaction_bits.book_id
	   AND accts.id = acct
	LEFT JOIN xactions
	    ON xactions.book_id = xaction_bits.book_id
	   AND xactions.xid = xaction_bits.xid
	LEFT JOIN current_valuations ON current_valuations.src = accts.atype
	WHERE accts.type = 'A' OR accts.type = 'L'
    GROUP BY accts.book_id, accts.id, accts.type, accts.atype, accts.pretax
    )
    SELECT  book_id,
	    Account,
	    fmt_asset(value, atype) AS origcurrency,
	    CASE WHEN istaxed != 1
		THEN round(pretax, 2)
		ELSE NULL
	    END AS pretax,
	    round(posttax, 2) AS posttax
    FROM t
    ORDER BY book_id, type, Account;

--
-- XXXrcd: we should really give this one a proper name...
-- XXXrcd: which comment should I really be choosing?

CREATE OR REPLACE VIEW join_them AS
    SELECT accts.book_id, accts.id, type, atype, pretax, xactions.xid,
	   amt, xactions.date, xaction_bits.comment
	FROM accts
	JOIN xaction_bits
	  ON accts.book_id = xaction_bits.book_id
	 AND accts.id = acct
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
;

--
-- XXXrcd: hmmm, is there really any difference between using a
--         CREATE VIEW and CREATE FUNCTION which returns a table?
--         In any case, the approach below allows me to create what
--         essentially acts like a VIEW but with a parameter of the
--         date...

CREATE OR REPLACE FUNCTION bsheet(b VARCHAR, d TIMESTAMP)
RETURNS TABLE (
	book_id		VARCHAR,
	account		VARCHAR,
	origcurrency	VARCHAR,
	pretax		NUMERIC,
	posttax		NUMERIC
) AS $$
    WITH t AS (
	SELECT
		accts.book_id,
		accts.type,
		accts.atype,
		accts.pretax AS istaxed,
		accts.id as Account,
		sum(amt) AS Value,
		sum(amt * current_valuations.rate) AS pretax,
		sum(amt * current_valuations.rate * accts.pretax) AS posttax
	FROM join_them AS accts
	LEFT JOIN current_valuations ON current_valuations.src = accts.atype
	WHERE accts.book_id = b
	  AND (accts.type = 'A' OR accts.type = 'L')
	  AND accts.date <= d
    GROUP BY accts.book_id, accts.id, accts.type, accts.atype, accts.pretax
    )
    SELECT  book_id,
	    Account,
	    fmt_asset(value, atype) AS origcurrency,
	    CASE WHEN istaxed != 1
		THEN round(pretax, 2)
		ELSE NULL
	    END AS pretax,
	    round(posttax, 2) AS posttax
    FROM t
    ORDER BY type, Account;
$$ LANGUAGE SQL;

--
-- A report-shaped balance sheet.  The older balance_sheet view and bsheet()
-- function above remain the raw account-balance interface; these objects add
-- section labels, conventional liability/equity signs, current earnings, and
-- total rows for presentation.

CREATE OR REPLACE VIEW balance_sheet_report AS
    WITH account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		accts.pretax AS tax_factor,
		COALESCE(sum(xaction_bits.amt), 0)::NUMERIC(100,5) AS native_value,
		CASE
		    WHEN accts.atype = books.reporting_asset THEN 1::NUMERIC(100,5)
		    ELSE latest_rate.rate
		END AS rate
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	LEFT JOIN xaction_bits
	  ON xaction_bits.book_id = accts.book_id
	 AND xaction_bits.acct = accts.id
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE accts.type IN ('A', 'L', 'Q', 'I', 'E')
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype, accts.pretax, latest_rate.rate
    ),
    normalised AS (
	SELECT
		report_book_id,
		account_type,
		account,
		atype,
		tax_factor,
		native_value,
		native_value * rate AS pretax_value,
		native_value * rate * tax_factor AS posttax_value
	FROM account_values
    ),
    account_rows AS (
	SELECT
		report_book_id,
		CASE account_type
		    WHEN 'A' THEN 'Assets'
		    WHEN 'L' THEN 'Liabilities'
		    ELSE 'Equity'
		END::VARCHAR AS section,
		CASE account_type
		    WHEN 'A' THEN 1
		    WHEN 'L' THEN 2
		    ELSE 3
		END AS section_order,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		fmt_asset(
		    CASE WHEN account_type = 'A'
			THEN native_value
			ELSE -native_value
		    END,
		    atype
		) AS origcurrency,
		CASE WHEN tax_factor != 1
		    THEN round(
			CASE WHEN account_type = 'A'
			    THEN pretax_value
			    ELSE -pretax_value
			END,
			2
		    )
		    ELSE NULL
		END AS pretax,
		round(
		    CASE WHEN account_type = 'A'
			THEN posttax_value
			ELSE -posttax_value
		    END,
		    2
		) AS posttax
	FROM normalised
	WHERE account_type IN ('A', 'L', 'Q')
    ),
    earnings_rows AS (
	SELECT
		report_book_id,
		'Equity'::VARCHAR AS section,
		3 AS section_order,
		20 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Current Earnings'::VARCHAR AS account,
		'Q'::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(-sum(posttax_value), 2) AS posttax
	FROM normalised
	WHERE account_type IN ('I', 'E')
	GROUP BY report_book_id
	HAVING round(-sum(posttax_value), 2) <> 0
    ),
    report_rows AS (
	SELECT * FROM account_rows
	UNION ALL
	SELECT * FROM earnings_rows
    ),
    section_totals AS (
	SELECT
		report_book_id,
		section,
		section_order,
		90 AS row_order,
		'section_total'::VARCHAR AS row_kind,
		('Total ' || section)::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM report_rows
	GROUP BY report_book_id, section, section_order
    ),
    grand_total AS (
	SELECT
		report_book_id,
		'Liabilities and Equity'::VARCHAR AS section,
		4 AS section_order,
		100 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		'Total Liabilities and Equity'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM report_rows
	WHERE section IN ('Liabilities', 'Equity')
	GROUP BY report_book_id
    )
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM report_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM section_totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM grand_total;

CREATE OR REPLACE FUNCTION bsheet_report(b VARCHAR, d TIMESTAMP)
RETURNS TABLE (
	book_id		VARCHAR,
	section		VARCHAR,
	section_order	INTEGER,
	row_order	INTEGER,
	row_kind	VARCHAR,
	account		VARCHAR,
	account_type	VARCHAR,
	origcurrency	VARCHAR,
	pretax		NUMERIC,
	posttax		NUMERIC
) AS $$
    WITH dated_bits AS (
	SELECT xaction_bits.book_id, xaction_bits.acct, xaction_bits.amt
	FROM xaction_bits
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	WHERE xactions.date <= d
    ),
    account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		accts.pretax AS tax_factor,
		COALESCE(sum(dated_bits.amt), 0)::NUMERIC(100,5) AS native_value,
		CASE
		    WHEN accts.atype = books.reporting_asset THEN 1::NUMERIC(100,5)
		    ELSE latest_rate.rate
		END AS rate
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	LEFT JOIN dated_bits
	  ON dated_bits.book_id = accts.book_id
	 AND dated_bits.acct = accts.id
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= d
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE books.id = b
	  AND accts.type IN ('A', 'L', 'Q', 'I', 'E')
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype, accts.pretax, latest_rate.rate
    ),
    normalised AS (
	SELECT
		report_book_id,
		account_type,
		account,
		atype,
		tax_factor,
		native_value,
		native_value * rate AS pretax_value,
		native_value * rate * tax_factor AS posttax_value
	FROM account_values
    ),
    account_rows AS (
	SELECT
		report_book_id,
		CASE account_type
		    WHEN 'A' THEN 'Assets'
		    WHEN 'L' THEN 'Liabilities'
		    ELSE 'Equity'
		END::VARCHAR AS section,
		CASE account_type
		    WHEN 'A' THEN 1
		    WHEN 'L' THEN 2
		    ELSE 3
		END AS section_order,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		fmt_asset(
		    CASE WHEN account_type = 'A'
			THEN native_value
			ELSE -native_value
		    END,
		    atype
		) AS origcurrency,
		CASE WHEN tax_factor != 1
		    THEN round(
			CASE WHEN account_type = 'A'
			    THEN pretax_value
			    ELSE -pretax_value
			END,
			2
		    )
		    ELSE NULL
		END AS pretax,
		round(
		    CASE WHEN account_type = 'A'
			THEN posttax_value
			ELSE -posttax_value
		    END,
		    2
		) AS posttax
	FROM normalised
	WHERE account_type IN ('A', 'L', 'Q')
    ),
    earnings_rows AS (
	SELECT
		report_book_id,
		'Equity'::VARCHAR AS section,
		3 AS section_order,
		20 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Current Earnings'::VARCHAR AS account,
		'Q'::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(-sum(posttax_value), 2) AS posttax
	FROM normalised
	WHERE account_type IN ('I', 'E')
	GROUP BY report_book_id
	HAVING round(-sum(posttax_value), 2) <> 0
    ),
    report_rows AS (
	SELECT * FROM account_rows
	UNION ALL
	SELECT * FROM earnings_rows
    ),
    section_totals AS (
	SELECT
		report_book_id,
		section,
		section_order,
		90 AS row_order,
		'section_total'::VARCHAR AS row_kind,
		('Total ' || section)::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM report_rows
	GROUP BY report_book_id, section, section_order
    ),
    grand_total AS (
	SELECT
		report_book_id,
		'Liabilities and Equity'::VARCHAR AS section,
		4 AS section_order,
		100 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		'Total Liabilities and Equity'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM report_rows
	WHERE section IN ('Liabilities', 'Equity')
	GROUP BY report_book_id
    )
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM report_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM section_totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM grand_total;
$$ LANGUAGE SQL;

--
-- Trial Balance.  This is an internal accounting check over all accounts:
-- positive account balances are debits, negative account balances are
-- credits, and the total row should balance when posted data is balanced.

CREATE OR REPLACE VIEW trial_balance_report AS
    WITH account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		COALESCE(sum(xaction_bits.amt), 0)::NUMERIC(100,5) AS native_value,
		CASE
		    WHEN accts.atype = books.reporting_asset THEN 1::NUMERIC(100,5)
		    ELSE latest_rate.rate
		END AS rate
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	LEFT JOIN xaction_bits
	  ON xaction_bits.book_id = accts.book_id
	 AND xaction_bits.acct = accts.id
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype, latest_rate.rate
    ),
    normalised AS (
	SELECT
		report_book_id,
		account_type,
		account,
		atype,
		native_value,
		CASE WHEN native_value = 0 THEN
		    0::NUMERIC(100,5)
		ELSE
		    native_value * rate
		END AS report_value
	FROM account_values
    ),
    account_rows AS (
	SELECT
		report_book_id,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		CASE WHEN native_value <> 0 THEN
		    fmt_asset(abs(native_value), atype)
		ELSE
		    NULL::VARCHAR
		END AS origcurrency,
		CASE WHEN report_value > 0 THEN round(report_value, 2) ELSE NULL END AS debit,
		CASE WHEN report_value < 0 THEN round(-report_value, 2) ELSE NULL END AS credit
	FROM normalised
    ),
    totals AS (
	SELECT
		report_book_id,
		90 AS row_order,
		'total'::VARCHAR AS row_kind,
		'Total'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		round(sum(COALESCE(debit, 0)), 2) AS debit,
		round(sum(COALESCE(credit, 0)), 2) AS credit
	FROM account_rows
	GROUP BY report_book_id
    ),
    differences AS (
	SELECT
		report_book_id,
		100 AS row_order,
		'difference'::VARCHAR AS row_kind,
		'Difference'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		CASE WHEN debit < credit THEN round(credit - debit, 2) ELSE NULL END AS debit,
		CASE WHEN debit > credit THEN round(debit - credit, 2) ELSE NULL END AS credit
	FROM totals
	WHERE debit <> credit
    )
    SELECT
	report_book_id AS book_id,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	debit,
	credit
    FROM account_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	debit,
	credit
    FROM totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	debit,
	credit
    FROM differences;

CREATE OR REPLACE FUNCTION tb_report(b VARCHAR, d TIMESTAMP)
RETURNS TABLE (
	book_id		VARCHAR,
	row_order	INTEGER,
	row_kind	VARCHAR,
	account		VARCHAR,
	account_type	VARCHAR,
	origcurrency	VARCHAR,
	debit		NUMERIC,
	credit		NUMERIC
) AS $$
    WITH dated_bits AS (
	SELECT xaction_bits.book_id, xaction_bits.acct, xaction_bits.amt
	FROM xaction_bits
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	WHERE xactions.date <= d
    ),
    account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		COALESCE(sum(dated_bits.amt), 0)::NUMERIC(100,5) AS native_value,
		CASE
		    WHEN accts.atype = books.reporting_asset THEN 1::NUMERIC(100,5)
		    ELSE latest_rate.rate
		END AS rate
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	LEFT JOIN dated_bits
	  ON dated_bits.book_id = accts.book_id
	 AND dated_bits.acct = accts.id
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= d
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE books.id = b
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype, latest_rate.rate
    ),
    normalised AS (
	SELECT
		report_book_id,
		account_type,
		account,
		atype,
		native_value,
		CASE WHEN native_value = 0 THEN
		    0::NUMERIC(100,5)
		ELSE
		    native_value * rate
		END AS report_value
	FROM account_values
    ),
    account_rows AS (
	SELECT
		report_book_id,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		CASE WHEN native_value <> 0 THEN
		    fmt_asset(abs(native_value), atype)
		ELSE
		    NULL::VARCHAR
		END AS origcurrency,
		CASE WHEN report_value > 0 THEN round(report_value, 2) ELSE NULL END AS debit,
		CASE WHEN report_value < 0 THEN round(-report_value, 2) ELSE NULL END AS credit
	FROM normalised
    ),
    totals AS (
	SELECT
		report_book_id,
		90 AS row_order,
		'total'::VARCHAR AS row_kind,
		'Total'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		round(sum(COALESCE(debit, 0)), 2) AS debit,
		round(sum(COALESCE(credit, 0)), 2) AS credit
	FROM account_rows
	GROUP BY report_book_id
    ),
    differences AS (
	SELECT
		report_book_id,
		100 AS row_order,
		'difference'::VARCHAR AS row_kind,
		'Difference'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		CASE WHEN debit < credit THEN round(credit - debit, 2) ELSE NULL END AS debit,
		CASE WHEN debit > credit THEN round(debit - credit, 2) ELSE NULL END AS credit
	FROM totals
	WHERE debit <> credit
    )
    SELECT
	report_book_id AS book_id,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	debit,
	credit
    FROM account_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	debit,
	credit
    FROM totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	debit,
	credit
    FROM differences;
$$ LANGUAGE SQL;

--
-- Standard Profit & Loss report.  This uses the same report row shape as the
-- balance sheet report, but it is a period report over income and expense
-- accounts.  Income account balances are conventionally presented as positive
-- revenue, expenses as positive costs, and the final row is net profit/loss.

CREATE OR REPLACE VIEW profit_loss_report AS
    WITH account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		accts.pretax AS tax_factor,
		sum(xaction_bits.amt)::NUMERIC(100,5) AS native_value,
		sum(
		    xaction_bits.amt *
		    CASE
			WHEN accts.atype = books.reporting_asset
			    THEN 1::NUMERIC(100,5)
			ELSE latest_rate.rate
		    END
		) AS pretax_value,
		sum(
		    xaction_bits.amt *
		    CASE
			WHEN accts.atype = books.reporting_asset
			    THEN 1::NUMERIC(100,5)
			ELSE latest_rate.rate
		    END *
		    accts.pretax
		) AS posttax_value
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	JOIN xaction_bits
	  ON xaction_bits.book_id = accts.book_id
	 AND xaction_bits.acct = accts.id
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE accts.type IN ('I', 'E')
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype, accts.pretax
    ),
    normalised AS (
	SELECT
		report_book_id,
		account_type,
		account,
		atype,
		tax_factor,
		native_value,
		pretax_value,
		posttax_value
	FROM account_values
    ),
    account_rows AS (
	SELECT
		report_book_id,
		CASE account_type
		    WHEN 'I' THEN 'Income'
		    ELSE 'Expenses'
		END::VARCHAR AS section,
		CASE account_type
		    WHEN 'I' THEN 1
		    ELSE 2
		END AS section_order,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		fmt_asset(
		    CASE WHEN account_type = 'I'
			THEN -native_value
			ELSE native_value
		    END,
		    atype
		) AS origcurrency,
		CASE WHEN tax_factor != 1
		    THEN round(
			CASE WHEN account_type = 'I'
			    THEN -pretax_value
			    ELSE pretax_value
			END,
			2
		    )
		    ELSE NULL
		END AS pretax,
		round(
		    CASE WHEN account_type = 'I'
			THEN -posttax_value
			ELSE posttax_value
		    END,
		    2
		) AS posttax
	FROM normalised
    ),
    section_totals AS (
	SELECT
		report_book_id,
		section,
		section_order,
		90 AS row_order,
		'section_total'::VARCHAR AS row_kind,
		('Total ' || section)::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM account_rows
	GROUP BY report_book_id, section, section_order
    ),
    net_income AS (
	SELECT
		report_book_id,
		round(
		    sum(
			CASE WHEN account_type = 'I'
			    THEN -posttax_value
			    ELSE -posttax_value
			END
		    ),
		    2
		) AS posttax
	FROM normalised
	GROUP BY report_book_id
    ),
    grand_total AS (
	SELECT
		report_book_id,
		'Net Income'::VARCHAR AS section,
		3 AS section_order,
		100 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		CASE WHEN posttax < 0
		    THEN 'Net Loss'
		    ELSE 'Net Profit'
		END::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		posttax
	FROM net_income
    )
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM account_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM section_totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM grand_total;

CREATE OR REPLACE FUNCTION pl_report(
	b VARCHAR,
	start_date TIMESTAMP,
	end_date TIMESTAMP
)
RETURNS TABLE (
	book_id		VARCHAR,
	section		VARCHAR,
	section_order	INTEGER,
	row_order	INTEGER,
	row_kind	VARCHAR,
	account		VARCHAR,
	account_type	VARCHAR,
	origcurrency	VARCHAR,
	pretax		NUMERIC,
	posttax		NUMERIC
) AS $$
    WITH account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		accts.pretax AS tax_factor,
		sum(xaction_bits.amt)::NUMERIC(100,5) AS native_value,
		sum(
		    xaction_bits.amt *
		    CASE
			WHEN accts.atype = books.reporting_asset
			    THEN 1::NUMERIC(100,5)
			ELSE latest_rate.rate
		    END
		) AS pretax_value,
		sum(
		    xaction_bits.amt *
		    CASE
			WHEN accts.atype = books.reporting_asset
			    THEN 1::NUMERIC(100,5)
			ELSE latest_rate.rate
		    END *
		    accts.pretax
		) AS posttax_value
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	JOIN xaction_bits
	  ON xaction_bits.book_id = accts.book_id
	 AND xaction_bits.acct = accts.id
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE books.id = b
	  AND accts.type IN ('I', 'E')
	  AND (start_date IS NULL OR xactions.date >= start_date)
	  AND (end_date IS NULL OR xactions.date <= end_date)
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype, accts.pretax
    ),
    normalised AS (
	SELECT
		report_book_id,
		account_type,
		account,
		atype,
		tax_factor,
		native_value,
		pretax_value,
		posttax_value
	FROM account_values
    ),
    account_rows AS (
	SELECT
		report_book_id,
		CASE account_type
		    WHEN 'I' THEN 'Income'
		    ELSE 'Expenses'
		END::VARCHAR AS section,
		CASE account_type
		    WHEN 'I' THEN 1
		    ELSE 2
		END AS section_order,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		fmt_asset(
		    CASE WHEN account_type = 'I'
			THEN -native_value
			ELSE native_value
		    END,
		    atype
		) AS origcurrency,
		CASE WHEN tax_factor != 1
		    THEN round(
			CASE WHEN account_type = 'I'
			    THEN -pretax_value
			    ELSE pretax_value
			END,
			2
		    )
		    ELSE NULL
		END AS pretax,
		round(
		    CASE WHEN account_type = 'I'
			THEN -posttax_value
			ELSE posttax_value
		    END,
		    2
		) AS posttax
	FROM normalised
    ),
    section_totals AS (
	SELECT
		report_book_id,
		section,
		section_order,
		90 AS row_order,
		'section_total'::VARCHAR AS row_kind,
		('Total ' || section)::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM account_rows
	GROUP BY report_book_id, section, section_order
    ),
    net_income AS (
	SELECT
		books.id AS report_book_id,
		round(
		    COALESCE(sum(
			CASE WHEN account_type = 'I'
			    THEN -posttax_value
			    ELSE -posttax_value
			END
		    ), 0),
		    2
		) AS posttax
	FROM books
	LEFT JOIN normalised
	  ON normalised.report_book_id = books.id
	WHERE books.id = b
	GROUP BY books.id
    ),
    grand_total AS (
	SELECT
		report_book_id,
		'Net Income'::VARCHAR AS section,
		3 AS section_order,
		100 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		CASE WHEN posttax < 0
		    THEN 'Net Loss'
		    ELSE 'Net Profit'
		END::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		posttax
	FROM net_income
    )
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM account_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM section_totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM grand_total;
$$ LANGUAGE SQL;

--
-- Standard Cash Flow report.  Cash and cash-equivalent accounts are explicit
-- SQL data in cash_accounts.  Cash-to-cash transfers are ignored; movements
-- involving a marked cash account are classified by the non-cash side:
-- income/expense accounts are operating, asset accounts are investing, and
-- liability/equity accounts are financing.

CREATE OR REPLACE VIEW cash_flow_report AS
    WITH book_scope AS (
	SELECT DISTINCT books.id AS report_book_id
	FROM books
	JOIN cash_accounts ON cash_accounts.book_id = books.id
    ),
    cash_transactions AS (
	SELECT DISTINCT xaction_bits.book_id, xaction_bits.xid
	FROM xaction_bits
	JOIN cash_accounts
	  ON cash_accounts.book_id = xaction_bits.book_id
	 AND cash_accounts.acct = xaction_bits.acct
    ),
    account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		sum(-xaction_bits.amt)::NUMERIC(100,5) AS native_value,
		sum(
		    -xaction_bits.amt *
		    CASE
			WHEN accts.atype = books.reporting_asset
			    THEN 1::NUMERIC(100,5)
			ELSE latest_rate.rate
		    END
		) AS report_value
	FROM cash_transactions
	JOIN books
	  ON books.id = cash_transactions.book_id
	JOIN xactions
	  ON xactions.book_id = cash_transactions.book_id
	 AND xactions.xid = cash_transactions.xid
	JOIN xaction_bits
	  ON xaction_bits.book_id = cash_transactions.book_id
	 AND xaction_bits.xid = cash_transactions.xid
	JOIN accts
	  ON accts.book_id = xaction_bits.book_id
	 AND accts.id = xaction_bits.acct
	LEFT JOIN cash_accounts
	  ON cash_accounts.book_id = xaction_bits.book_id
	 AND cash_accounts.acct = xaction_bits.acct
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE cash_accounts.acct IS NULL
	  AND accts.type IN ('I', 'E', 'A', 'L', 'Q')
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype
    ),
    account_rows AS (
	SELECT
		report_book_id,
		CASE
		    WHEN account_type IN ('I', 'E') THEN 'Operating Activities'
		    WHEN account_type = 'A' THEN 'Investing Activities'
		    ELSE 'Financing Activities'
		END::VARCHAR AS section,
		CASE
		    WHEN account_type IN ('I', 'E') THEN 1
		    WHEN account_type = 'A' THEN 2
		    ELSE 3
		END AS section_order,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		fmt_asset(native_value, atype) AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(report_value, 2) AS posttax
	FROM account_values
    ),
    section_totals AS (
	SELECT
		report_book_id,
		section,
		section_order,
		90 AS row_order,
		'section_total'::VARCHAR AS row_kind,
		('Net Cash from ' || section)::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM account_rows
	GROUP BY report_book_id, section, section_order
    ),
    net_cash AS (
	SELECT
		book_scope.report_book_id,
		round(COALESCE(sum(account_rows.posttax), 0), 2) AS posttax
	FROM book_scope
	LEFT JOIN account_rows
	  ON account_rows.report_book_id = book_scope.report_book_id
	GROUP BY book_scope.report_book_id
    ),
    cash_balance AS (
	SELECT
		books.id AS report_book_id,
		round(
		    COALESCE(
			sum(
			    CASE WHEN xactions.xid IS NULL THEN
				0
			    ELSE
				xaction_bits.amt *
				CASE
				    WHEN accts.atype = books.reporting_asset
					THEN 1::NUMERIC(100,5)
				    ELSE latest_rate.rate
				END
			    END
			),
			0
		    ),
		    2
		) AS ending_cash
	FROM books
	JOIN cash_accounts
	  ON cash_accounts.book_id = books.id
	JOIN accts
	  ON accts.book_id = cash_accounts.book_id
	 AND accts.id = cash_accounts.acct
	LEFT JOIN xaction_bits
	  ON xaction_bits.book_id = cash_accounts.book_id
	 AND xaction_bits.acct = cash_accounts.acct
	LEFT JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	GROUP BY books.id
    ),
    reconciliation_rows AS (
	SELECT
		net_cash.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		10 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Cash at Beginning of Period'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		0::NUMERIC AS posttax
	FROM net_cash
UNION ALL
	SELECT
		net_cash.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		20 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		CASE WHEN net_cash.posttax < 0
		    THEN 'Net Decrease in Cash'
		    ELSE 'Net Increase in Cash'
		END::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		net_cash.posttax
	FROM net_cash
UNION ALL
	SELECT
		cash_balance.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		30 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Cash at End of Period'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		cash_balance.ending_cash
	FROM cash_balance
    )
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM account_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM section_totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM reconciliation_rows;

CREATE OR REPLACE FUNCTION cf_report(
	b VARCHAR,
	start_date TIMESTAMP,
	end_date TIMESTAMP
)
RETURNS TABLE (
	book_id		VARCHAR,
	section		VARCHAR,
	section_order	INTEGER,
	row_order	INTEGER,
	row_kind	VARCHAR,
	account		VARCHAR,
	account_type	VARCHAR,
	origcurrency	VARCHAR,
	pretax		NUMERIC,
	posttax		NUMERIC
) AS $$
    WITH book_scope AS (
	SELECT books.id AS report_book_id
	FROM books
	WHERE books.id = b
	  AND EXISTS (
	    SELECT 1
	    FROM cash_accounts
	    WHERE cash_accounts.book_id = books.id
	  )
    ),
    cash_transactions AS (
	SELECT DISTINCT xaction_bits.book_id, xaction_bits.xid
	FROM xaction_bits
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	JOIN cash_accounts
	  ON cash_accounts.book_id = xaction_bits.book_id
	 AND cash_accounts.acct = xaction_bits.acct
	WHERE xaction_bits.book_id = b
	  AND (start_date IS NULL OR xactions.date >= start_date)
	  AND (end_date IS NULL OR xactions.date <= end_date)
    ),
    account_values AS (
	SELECT
		books.id AS report_book_id,
		accts.type AS account_type,
		accts.id AS account,
		accts.atype,
		sum(-xaction_bits.amt)::NUMERIC(100,5) AS native_value,
		sum(
		    -xaction_bits.amt *
		    CASE
			WHEN accts.atype = books.reporting_asset
			    THEN 1::NUMERIC(100,5)
			ELSE latest_rate.rate
		    END
		) AS report_value
	FROM cash_transactions
	JOIN books
	  ON books.id = cash_transactions.book_id
	JOIN xactions
	  ON xactions.book_id = cash_transactions.book_id
	 AND xactions.xid = cash_transactions.xid
	JOIN xaction_bits
	  ON xaction_bits.book_id = cash_transactions.book_id
	 AND xaction_bits.xid = cash_transactions.xid
	JOIN accts
	  ON accts.book_id = xaction_bits.book_id
	 AND accts.id = xaction_bits.acct
	LEFT JOIN cash_accounts
	  ON cash_accounts.book_id = xaction_bits.book_id
	 AND cash_accounts.acct = xaction_bits.acct
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	WHERE cash_accounts.acct IS NULL
	  AND accts.type IN ('I', 'E', 'A', 'L', 'Q')
	GROUP BY books.id, books.reporting_asset, accts.type, accts.id,
	    accts.atype
    ),
    account_rows AS (
	SELECT
		report_book_id,
		CASE
		    WHEN account_type IN ('I', 'E') THEN 'Operating Activities'
		    WHEN account_type = 'A' THEN 'Investing Activities'
		    ELSE 'Financing Activities'
		END::VARCHAR AS section,
		CASE
		    WHEN account_type IN ('I', 'E') THEN 1
		    WHEN account_type = 'A' THEN 2
		    ELSE 3
		END AS section_order,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		fmt_asset(native_value, atype) AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(report_value, 2) AS posttax
	FROM account_values
    ),
    section_totals AS (
	SELECT
		report_book_id,
		section,
		section_order,
		90 AS row_order,
		'section_total'::VARCHAR AS row_kind,
		('Net Cash from ' || section)::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		round(sum(posttax), 2) AS posttax
	FROM account_rows
	GROUP BY report_book_id, section, section_order
    ),
    net_cash AS (
	SELECT
		book_scope.report_book_id,
		round(COALESCE(sum(account_rows.posttax), 0), 2) AS posttax
	FROM book_scope
	LEFT JOIN account_rows
	  ON account_rows.report_book_id = book_scope.report_book_id
	GROUP BY book_scope.report_book_id
    ),
    beginning_cash AS (
	SELECT
		book_scope.report_book_id,
		round(
		    COALESCE(
			sum(
			    CASE WHEN xactions.xid IS NULL THEN
				0
			    ELSE
				xaction_bits.amt *
				CASE
				    WHEN accts.atype = books.reporting_asset
					THEN 1::NUMERIC(100,5)
				    ELSE latest_rate.rate
				END
			    END
			),
			0
		    ),
		    2
		) AS cash_value
	FROM book_scope
	JOIN books
	  ON books.id = book_scope.report_book_id
	JOIN cash_accounts
	  ON cash_accounts.book_id = books.id
	JOIN accts
	  ON accts.book_id = cash_accounts.book_id
	 AND accts.id = cash_accounts.acct
	LEFT JOIN xaction_bits
	  ON xaction_bits.book_id = cash_accounts.book_id
	 AND xaction_bits.acct = cash_accounts.acct
	LEFT JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	 AND start_date IS NOT NULL
	 AND xactions.date < start_date
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	GROUP BY book_scope.report_book_id
    ),
    ending_cash AS (
	SELECT
		book_scope.report_book_id,
		round(
		    COALESCE(
			sum(
			    CASE WHEN xactions.xid IS NULL THEN
				0
			    ELSE
				xaction_bits.amt *
				CASE
				    WHEN accts.atype = books.reporting_asset
					THEN 1::NUMERIC(100,5)
				    ELSE latest_rate.rate
				END
			    END
			),
			0
		    ),
		    2
		) AS cash_value
	FROM book_scope
	JOIN books
	  ON books.id = book_scope.report_book_id
	JOIN cash_accounts
	  ON cash_accounts.book_id = books.id
	JOIN accts
	  ON accts.book_id = cash_accounts.book_id
	 AND accts.id = cash_accounts.acct
	LEFT JOIN xaction_bits
	  ON xaction_bits.book_id = cash_accounts.book_id
	 AND xaction_bits.acct = cash_accounts.acct
	LEFT JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	 AND (end_date IS NULL OR xactions.date <= end_date)
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = accts.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= xactions.date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS latest_rate ON TRUE
	GROUP BY book_scope.report_book_id
    ),
    reconciliation_rows AS (
	SELECT
		beginning_cash.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		10 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Cash at Beginning of Period'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		beginning_cash.cash_value AS posttax
	FROM beginning_cash
UNION ALL
	SELECT
		net_cash.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		20 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		CASE WHEN net_cash.posttax < 0
		    THEN 'Net Decrease in Cash'
		    ELSE 'Net Increase in Cash'
		END::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		net_cash.posttax
	FROM net_cash
UNION ALL
	SELECT
		ending_cash.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		30 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Cash at End of Period'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		ending_cash.cash_value AS posttax
	FROM ending_cash
    )
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM account_rows
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM section_totals
UNION ALL
    SELECT
	report_book_id AS book_id,
	section,
	section_order,
	row_order,
	row_kind,
	account,
	account_type,
	origcurrency,
	pretax,
	posttax
    FROM reconciliation_rows;
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
		accts.book_id,
		accts.id AS acct,
                CAST (xactions.date AS date),
                xaction_bits.xid,
                amt,
                sum(amt) OVER (PARTITION BY accts.book_id, accts.id
			       ORDER BY xactions.date, xaction_bits.xid)
			RunningTotal,
                xaction_bits.comment
        FROM accts
        LEFT JOIN xaction_bits
	  ON accts.book_id = xaction_bits.book_id
	 AND accts.id = acct
        LEFT JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid;

CREATE OR REPLACE VIEW general_journal AS
    SELECT
	xactions.book_id,
	CAST (xactions.date AS date) AS date,
	xactions.xid,
	xactions.comment AS description,
	NOT EXISTS (
	    SELECT 1
	    FROM xaction_unresolved
	    WHERE xaction_unresolved.book_id = xactions.book_id
	      AND xaction_unresolved.xid = xactions.xid
	) AS reconciled,
	(row_number() OVER (
	    PARTITION BY xaction_bits.book_id, xaction_bits.xid
	    ORDER BY
		CASE
		    WHEN xaction_bits.amt > 0 THEN 0
		    WHEN xaction_bits.amt < 0 THEN 1
		    ELSE 2
		END,
		xaction_bits.id
	))::INTEGER AS line_order,
	xaction_bits.id AS line_id,
	xaction_bits.acct AS account,
	accts.type AS account_type,
	xaction_bits.comment AS memo,
	CASE WHEN xaction_bits.amt > 0
	    THEN round(xaction_bits.amt, 2)
	    ELSE NULL
	END AS debit,
	CASE WHEN xaction_bits.amt < 0
	    THEN round(-xaction_bits.amt, 2)
	    ELSE NULL
	END AS credit
    FROM xactions
    JOIN xaction_bits
      ON xaction_bits.book_id = xactions.book_id
     AND xaction_bits.xid = xactions.xid
    JOIN accts
      ON accts.book_id = xaction_bits.book_id
     AND accts.id = xaction_bits.acct;

--
-- XXXrcd: okay, now we should make a parameterised view that
--         reprents the ledger from the point of view of a
--         single account.

CREATE OR REPLACE FUNCTION ledger(b VARCHAR, a VARCHAR) RETURNS TABLE (
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
	LEFT JOIN xaction_bits
	  ON accts.book_id = xaction_bits.book_id
	 AND accts.id = acct
	LEFT JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	WHERE accts.book_id = b
	  AND accts.id = a;
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
