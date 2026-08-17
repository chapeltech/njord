-- A native amount adds information only when its asset differs from the
-- report's effective currency. One unit is still meaningful and is retained.
CREATE OR REPLACE FUNCTION njord.native_amount_label(
    value NUMERIC(100,5), asset_id VARCHAR, reporting_asset VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
	WHEN asset_id <> reporting_asset THEN round(value, 2) || ' ' || asset_id
    END;
$$;

-- One effective-dated conversion rule serves stock and flow reports. Missing
-- market data remains NULL; callers decide whether a zero native balance can
-- be reported without a rate.
CREATE OR REPLACE FUNCTION njord.asset_rate(
    source_asset VARCHAR, destination_asset VARCHAR, at_date TIMESTAMP
)
RETURNS NUMERIC
LANGUAGE SQL
STABLE
AS $$
    SELECT CASE
	WHEN source_asset = destination_asset THEN 1::NUMERIC
	ELSE (
	    SELECT valuations.rate
	    FROM valuations
	    WHERE valuations.src = source_asset
	      AND valuations.dst = destination_asset
	      AND valuations.date <= at_date
	    ORDER BY valuations.date DESC
	    LIMIT 1
	)
    END;
$$;

-- The reporting currency is itself effective-dated; this wrapper keeps that
-- Book-level choice out of report queries.
CREATE OR REPLACE FUNCTION njord.reporting_rate(
    book_id VARCHAR, source_asset VARCHAR, at_date TIMESTAMP
)
RETURNS NUMERIC
LANGUAGE SQL
STABLE
AS $$
    SELECT njord.asset_rate(
	source_asset,
	njord.book_reporting_asset_at(book_id, at_date::DATE),
	at_date
    );
$$;

-- Ordinary sum() silently drops NULL values, which can turn a report with a
-- missing exchange rate into a plausible but incomplete total. This aggregate
-- instead propagates NULL; its zero initial state preserves empty-report sums.
CREATE OR REPLACE FUNCTION njord.add_if_complete(
    total NUMERIC, value NUMERIC
)
RETURNS NUMERIC
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
	WHEN total IS NULL OR value IS NULL THEN NULL
	ELSE total + value
    END;
$$;

CREATE AGGREGATE njord.sum_if_complete(NUMERIC) (
    SFUNC = njord.add_if_complete,
    STYPE = NUMERIC,
    INITCOND = '0',
    PARALLEL = SAFE
);

-- The common report fact: one ledger posting with its transaction, account,
-- and effective-dated value in the Book's reporting currency.
CREATE OR REPLACE VIEW report_postings AS
    SELECT
	transactions.book_id,
	transactions.xid,
	transactions.date AS transaction_date,
	transactions.comment AS transaction_comment,
	postings.id AS posting_id,
	postings.acct AS account_id,
	postings.amt AS amount,
	postings.comment AS posting_comment,
	accounts.name AS account_name,
	accounts.type AS account_type,
	accounts.atype AS account_asset,
	accounts.account_kind,
	accounts.placeholder,
	accounts.pretax,
	accounts.default_business_use_percent,
	valued.reporting_rate,
	postings.amt * valued.reporting_rate AS reporting_amount
    FROM xactions AS transactions
    JOIN xaction_bits AS postings
      ON postings.book_id = transactions.book_id
     AND postings.xid = transactions.xid
    JOIN accts AS accounts
      ON accounts.book_id = postings.book_id
     AND accounts.id = postings.acct
    CROSS JOIN LATERAL (
	SELECT njord.reporting_rate(
	    transactions.book_id, accounts.atype, transactions.date
	) AS reporting_rate
    ) AS valued;

-- A canonical preorder hierarchy for statement-shaped reports. Report
-- functions use the stable sort path for presentation order and the ancestor
-- list to roll posting values into their visible parent groups.
CREATE OR REPLACE VIEW report_account_tree AS
    WITH RECURSIVE tree AS (
	SELECT
	    accts.book_id,
	    accts.id,
	    accts.name,
	    accts.parent_id,
	    accts.type,
	    accts.atype,
	    accts.account_kind,
	    accts.placeholder,
	    accts.pretax,
	    accts.comment,
	    0 AS depth,
	    ARRAY[]::VARCHAR[] AS ancestor_ids,
	    ARRAY[accts.name]::VARCHAR[] AS name_path,
	    ARRAY[
		CASE accts.type
		    WHEN 'A' THEN '01' WHEN 'L' THEN '02' WHEN 'Q' THEN '03'
		    WHEN 'I' THEN '04' WHEN 'E' THEN '05' ELSE '99'
		END,
		lower(accts.name) || E'\x1f' || accts.id
	    ]::VARCHAR[] AS sort_path,
	    accts.name::TEXT AS display_path
	FROM accts
	WHERE accts.parent_id IS NULL
	UNION ALL
	SELECT
	    child.book_id,
	    child.id,
	    child.name,
	    child.parent_id,
	    child.type,
	    child.atype,
	    child.account_kind,
	    child.placeholder,
	    child.pretax,
	    child.comment,
	    parent.depth + 1,
	    parent.ancestor_ids || parent.id,
	    parent.name_path || child.name,
	    parent.sort_path || (lower(child.name) || E'\x1f' || child.id),
	    (parent.display_path || ' › ' || child.name)::TEXT
	FROM accts AS child
	JOIN tree AS parent
	  ON parent.book_id = child.book_id
	 AND parent.id = child.parent_id
    )
    SELECT * FROM tree;

-- Native balances are accumulated first and valued once at the report date.
-- This is stock-report semantics: it intentionally differs from converting
-- each historical posting at its transaction-date rate.
CREATE OR REPLACE FUNCTION njord.account_balances_at(
    p_book_id VARCHAR, p_as_of TIMESTAMP
)
RETURNS TABLE (
    book_id VARCHAR,
    account VARCHAR,
    account_type VARCHAR,
    asset_id VARCHAR,
    pretax_factor NUMERIC,
    reporting_asset VARCHAR,
    native_value NUMERIC,
    report_value NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    WITH balances AS (
	SELECT
	    accounts.book_id,
	    accounts.id AS account,
	    accounts.type AS account_type,
	    accounts.atype AS asset_id,
	    accounts.pretax AS pretax_factor,
	    njord.book_reporting_asset_at(
		accounts.book_id, p_as_of::DATE
	    ) AS reporting_asset,
	    COALESCE(sum(
		CASE WHEN transactions.xid IS NULL THEN 0 ELSE postings.amt END
	    ), 0)::NUMERIC(100,5) AS native_value
	FROM accts AS accounts
	LEFT JOIN xaction_bits AS postings
	  ON postings.book_id = accounts.book_id
	 AND postings.acct = accounts.id
	LEFT JOIN xactions AS transactions
	  ON transactions.book_id = postings.book_id
	 AND transactions.xid = postings.xid
	 AND transactions.date <= p_as_of
	WHERE accounts.book_id = p_book_id
	GROUP BY accounts.book_id, accounts.id, accounts.type, accounts.atype,
	    accounts.pretax
    ),
    rated AS (
	SELECT balances.*,
	    njord.asset_rate(asset_id, reporting_asset, p_as_of) AS rate
	FROM balances
    )
    SELECT book_id, account, account_type, asset_id, pretax_factor,
	reporting_asset, native_value,
	CASE WHEN native_value = 0 THEN 0::NUMERIC
	     ELSE native_value * rate
	END AS report_value
    FROM rated;
$$;

-- Pack reports all emit the same small JSON vocabulary.  Keep its spelling in
-- one place so a report query reads as accounting logic rather than JSON
-- plumbing.
CREATE OR REPLACE FUNCTION njord.report_text_cell(
    p_column_id VARCHAR,
    p_value TEXT
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object('column_id', p_column_id, 'text', p_value);
$$;

CREATE OR REPLACE FUNCTION njord.report_number_cell(
    p_column_id VARCHAR,
    p_value NUMERIC,
    p_suffix VARCHAR DEFAULT NULL
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
	'column_id', p_column_id,
	'number', p_value,
	'exact', p_value::TEXT
    )
	|| CASE WHEN p_suffix IS NULL THEN '{}'::JSONB
		ELSE jsonb_build_object('suffix', p_suffix)
	   END;
$$;

CREATE OR REPLACE FUNCTION njord.report_payload(
    p_row_kind VARCHAR,
    p_account_id VARCHAR,
    p_cells JSONB,
    p_depth INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
	'row_kind', p_row_kind,
	'depth', p_depth,
	'account_id', p_account_id,
	'cells', p_cells
    );
$$;

CREATE OR REPLACE FUNCTION njord.statement_report_payload(
    p_row_kind VARCHAR,
    p_account_id VARCHAR,
    p_account VARCHAR,
    p_asset VARCHAR,
    p_pretax NUMERIC,
    p_posttax NUMERIC,
    p_depth INTEGER
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT njord.report_payload(
	p_row_kind, p_account_id,
	jsonb_build_array(
	    njord.report_text_cell('account', p_account),
	    njord.report_text_cell('asset', p_asset),
	    njord.report_number_cell('pretax', p_pretax),
	    njord.report_number_cell('posttax', p_posttax)
	),
	p_depth
    );
$$;

-- Report presentation is database-owned. Elm consumes these catalogue,
-- column, and chart rows through one generic report page; a new tabular report
-- or single-series bar chart therefore needs SQL definitions, not a new view.
CREATE OR REPLACE VIEW core_report_catalog AS
    SELECT reports.*, 'ordinary'::VARCHAR AS profile_kind
    FROM (VALUES
	(1, 'balance-sheet'::VARCHAR, 'Balance Sheet'::VARCHAR,
	    'Assets, liabilities, and equity at a chosen date.'::VARCHAR,
	    'as_of'::VARCHAR, 'Financial statements'::VARCHAR),
	(2, 'net-worth'::VARCHAR, 'Net Worth'::VARCHAR,
	    'Current asset estimates less outstanding liabilities at a chosen date.'::VARCHAR,
	    'as_of'::VARCHAR, 'Financial statements'::VARCHAR),
	(3, 'trial-balance'::VARCHAR, 'Trial Balance'::VARCHAR,
	    'Debit and credit balances across the chart of accounts.'::VARCHAR,
	    'as_of'::VARCHAR, 'Financial statements'::VARCHAR),
	(4, 'profit-loss'::VARCHAR, 'Profit & Loss'::VARCHAR,
	    'Income, expenses, and net profit or loss for a period.'::VARCHAR,
	    'period'::VARCHAR, 'Financial statements'::VARCHAR),
	(5, 'cash-flow'::VARCHAR, 'Cash Flow'::VARCHAR,
	    'Cash movement by activity for a period.'::VARCHAR,
	    'period'::VARCHAR, 'Financial statements'::VARCHAR)
    ) AS reports(
	report_order, report_id, title, description, parameter_kind,
	report_group
    );

CREATE OR REPLACE VIEW core_report_columns AS
    SELECT *
    FROM (VALUES
	('balance-sheet'::VARCHAR, 1, 'account'::VARCHAR, 'Account'::VARCHAR, 'left'::VARCHAR, 'text'::VARCHAR, TRUE),
	('balance-sheet', 2, 'asset', 'Asset', 'left', 'text', FALSE),
	('balance-sheet', 3, 'pretax', 'Pre-tax', 'right', 'number', FALSE),
	('balance-sheet', 4, 'posttax', 'Post-tax', 'right', 'number', FALSE),
	('net-worth', 1, 'account', 'Account', 'left', 'text', TRUE),
	('net-worth', 2, 'commodity', 'Commodity', 'left', 'text', FALSE),
	('net-worth', 3, 'native_balance', 'Native balance', 'right', 'quantity', FALSE),
	('net-worth', 4, 'market_value', 'Market value', 'right', 'number', FALSE),
	('net-worth', 5, 'valuation', 'Valuation', 'left', 'text', FALSE),
	('trial-balance', 1, 'account', 'Account', 'left', 'text', FALSE),
	('trial-balance', 2, 'asset', 'Asset', 'left', 'text', FALSE),
	('trial-balance', 3, 'debit', 'Debit', 'right', 'number', FALSE),
	('trial-balance', 4, 'credit', 'Credit', 'right', 'number', FALSE),
	('profit-loss', 1, 'account', 'Account', 'left', 'text', TRUE),
	('profit-loss', 2, 'asset', 'Asset', 'left', 'text', FALSE),
	('profit-loss', 3, 'pretax', 'Pre-tax', 'right', 'number', FALSE),
	('profit-loss', 4, 'posttax', 'Post-tax', 'right', 'number', FALSE),
	('cash-flow', 1, 'section', 'Activity', 'left', 'text', FALSE),
	('cash-flow', 2, 'account', 'Account', 'left', 'text', FALSE),
	('cash-flow', 3, 'asset', 'Asset', 'left', 'text', FALSE),
	('cash-flow', 4, 'pretax', 'Pre-tax', 'right', 'number', FALSE),
	('cash-flow', 5, 'posttax', 'Post-tax', 'right', 'number', FALSE)
    ) AS columns(
	report_id, column_order, column_id, label, alignment, value_format,
	tree_column
    );

CREATE OR REPLACE VIEW core_report_bar_charts AS
    SELECT *
    FROM (VALUES
	('net-worth'::VARCHAR, 1, 'net-worth-history'::VARCHAR,
	    'Net Worth over time'::VARCHAR, 'Net Worth'::VARCHAR,
	    'money'::VARCHAR)
    ) AS charts(
	report_id, chart_order, chart_id, title, value_label, value_format
    );

-- The canonical Balance Sheet is dated, book-scoped, currency-aware, and
-- report-shaped. There is deliberately no undated or GBP-only twin.
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
    WITH normalised AS (
	SELECT
	    book_id AS report_book_id,
	    account_type,
	    account,
	    asset_id AS atype,
	    pretax_factor AS tax_factor,
	    reporting_asset,
	    native_value,
	    report_value AS pretax_value,
	    report_value * pretax_factor AS posttax_value
	FROM njord.account_balances_at(b, d)
	WHERE account_type IN ('A', 'L', 'Q', 'I', 'E')
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
		njord.native_amount_label(
		    CASE WHEN account_type = 'A'
			THEN native_value
			ELSE -native_value
		    END,
		    atype,
		    reporting_asset
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
		round(-njord.sum_if_complete(posttax_value), 2) AS posttax
	FROM normalised
	WHERE account_type IN ('I', 'E')
	GROUP BY report_book_id
	HAVING round(-njord.sum_if_complete(posttax_value), 2)
	    IS DISTINCT FROM 0
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
		round(njord.sum_if_complete(posttax), 2) AS posttax
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
		round(njord.sum_if_complete(posttax), 2) AS posttax
	FROM report_rows
	WHERE section IN ('Liabilities', 'Equity')
	GROUP BY report_book_id
    )
    SELECT * FROM report_rows
    UNION ALL SELECT * FROM section_totals
    UNION ALL SELECT * FROM grand_total;
$$ LANGUAGE SQL STABLE;

--
-- Net Worth deliberately differs from the accounting Balance Sheet. It uses
-- the latest dated total estimate for a unique fixed asset, the latest dated
-- unit rate for a commodity holding, and the posted balance for reporting-
-- currency cash and liabilities. No market observation changes the ledger.

-- Stable account identity and valuation provenance are carried together here.
-- Rendered paths are mutable presentation text and must never become
-- relational join keys.
CREATE OR REPLACE FUNCTION njord.net_worth_account_values(
    b VARCHAR,
    d TIMESTAMP
)
RETURNS TABLE (
    book_id VARCHAR,
    account_id VARCHAR,
    account_path VARCHAR,
    account_name VARCHAR,
    account_type VARCHAR,
    commodity VARCHAR,
    native_balance NUMERIC,
    market_value NUMERIC,
    valuation_date TIMESTAMP,
    valuation_source VARCHAR,
    depth INTEGER,
    parent_id VARCHAR,
    sort_path VARCHAR[],
    ancestor_ids VARCHAR[]
)
LANGUAGE SQL
STABLE
AS $$
    WITH accounts AS (
	SELECT
	    balances.book_id,
	    balances.reporting_asset,
	    account_tree.id,
	    account_tree.display_path,
	    account_tree.name,
	    balances.account_type,
	    balances.asset_id,
	    account_tree.account_kind,
	    balances.native_value,
	    account_tree.depth,
	    account_tree.parent_id,
	    account_tree.sort_path,
	    account_tree.ancestor_ids
	FROM njord.account_balances_at(b, d) AS balances
	JOIN report_account_tree AS account_tree
	  ON account_tree.book_id = balances.book_id
	 AND account_tree.id = balances.account
	WHERE balances.account_type IN ('A', 'L')
	  AND NOT account_tree.placeholder
	  AND balances.native_value <> 0
    ),
    valued AS (
	SELECT
	    accounts.*,
	    account_estimate.value AS account_estimate,
	    account_estimate.date AS account_estimate_date,
	    unit_rate.rate AS unit_rate,
	    unit_rate.date AS unit_rate_date
	FROM accounts
	LEFT JOIN LATERAL (
	    SELECT account_valuations.value, account_valuations.date
	    FROM account_valuations
	    WHERE account_valuations.book_id = accounts.book_id
	      AND account_valuations.acct = accounts.id
	      AND account_valuations.dst = accounts.reporting_asset
	      AND account_valuations.date <= d
	    ORDER BY account_valuations.date DESC
	    LIMIT 1
	) AS account_estimate ON TRUE
	LEFT JOIN LATERAL (
	    SELECT valuations.rate, valuations.date
	    FROM valuations
	    WHERE valuations.src = accounts.asset_id
	      AND valuations.dst = accounts.reporting_asset
	      AND valuations.date <= d
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS unit_rate ON TRUE
    )
    SELECT
	book_id,
	id,
	display_path::VARCHAR,
	name::VARCHAR,
	account_type,
	asset_id,
	CASE account_type WHEN 'A' THEN native_value ELSE -native_value END,
	round(CASE
	    WHEN account_type = 'A' AND account_estimate IS NOT NULL THEN
		sign(native_value) * account_estimate
	    WHEN asset_id = reporting_asset THEN
		CASE account_type WHEN 'A' THEN native_value ELSE -native_value END
	    WHEN unit_rate IS NOT NULL THEN
		CASE account_type WHEN 'A' THEN native_value ELSE -native_value END
		    * unit_rate
	    ELSE NULL
	END, 2),
	CASE
	    WHEN account_type = 'A' AND account_estimate IS NOT NULL
		THEN account_estimate_date
	    WHEN asset_id <> reporting_asset THEN unit_rate_date
	END,
	CASE
	    WHEN account_type = 'A' AND account_estimate IS NOT NULL
		THEN 'Account estimate'
	    WHEN asset_id = reporting_asset AND account_kind = 'fixed_asset'
		THEN 'Book value fallback'
	    WHEN asset_id = reporting_asset THEN 'Book balance'
	    WHEN unit_rate IS NOT NULL THEN 'Unit rate'
	    ELSE 'Missing valuation'
	END::VARCHAR,
	depth,
	parent_id,
	sort_path,
	ancestor_ids
    FROM valued;
$$;

CREATE OR REPLACE FUNCTION net_worth_report(b VARCHAR, d TIMESTAMP)
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
	posttax		NUMERIC,
	commodity	VARCHAR,
	native_balance	NUMERIC,
	valuation_date	TIMESTAMP,
	valuation_source VARCHAR
) AS $$
    WITH account_rows AS (
	SELECT
	    values.book_id AS report_book_id,
	    CASE account_type WHEN 'A' THEN 'Assets' ELSE 'Liabilities' END::VARCHAR AS section,
	    CASE account_type WHEN 'A' THEN 1 ELSE 2 END AS section_order,
	    10 AS row_order,
	    'account'::VARCHAR AS row_kind,
	    values.account_path AS account,
	    account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    values.market_value AS posttax,
	    values.commodity,
	    values.native_balance,
	    values.valuation_date,
	    values.valuation_source
	FROM njord.net_worth_account_values(b, d) AS values
    ),
    section_totals AS (
	SELECT
	    b::VARCHAR AS report_book_id,
	    sections.section,
	    sections.section_order,
	    90 AS row_order,
	    'section_total'::VARCHAR AS row_kind,
	    ('Total ' || sections.section)::VARCHAR AS account,
	    NULL::VARCHAR AS account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    round(njord.sum_if_complete(account_rows.posttax)
		FILTER (WHERE account_rows.row_kind IS NOT NULL), 2) AS posttax,
	    NULL::VARCHAR AS commodity,
	    NULL::NUMERIC AS native_balance,
	    NULL::TIMESTAMP AS valuation_date,
	    NULL::VARCHAR AS valuation_source
	FROM (VALUES
	    ('Assets'::VARCHAR, 1),
	    ('Liabilities'::VARCHAR, 2)
	) AS sections(section, section_order)
	LEFT JOIN account_rows
	  ON account_rows.section = sections.section
	GROUP BY sections.section, sections.section_order
    ),
    net_worth AS (
	SELECT
	    b::VARCHAR AS report_book_id,
	    'Net Worth'::VARCHAR AS section,
	    3 AS section_order,
	    100 AS row_order,
	    'grand_total'::VARCHAR AS row_kind,
	    'Net Worth'::VARCHAR AS account,
	    NULL::VARCHAR AS account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    CASE
		WHEN count(*) = 2 AND count(posttax) = 2 THEN
		    round(
			max(posttax) FILTER (WHERE section = 'Assets')
			- max(posttax) FILTER (WHERE section = 'Liabilities'),
			2
		    )
		ELSE NULL
	    END AS posttax,
	    NULL::VARCHAR AS commodity,
	    NULL::NUMERIC AS native_balance,
	    NULL::TIMESTAMP AS valuation_date,
	    NULL::VARCHAR AS valuation_source
	FROM section_totals
    )
    SELECT * FROM account_rows
UNION ALL
    SELECT * FROM section_totals
UNION ALL
    SELECT * FROM net_worth;
$$ LANGUAGE SQL STABLE;

-- Balance Sheet rows arranged like the chart of accounts. Placeholder roots
-- and groups carry descendant totals; posting accounts retain their own values.
CREATE OR REPLACE FUNCTION hierarchical_balance_sheet_report(b VARCHAR, d TIMESTAMP)
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
	posttax		NUMERIC,
	depth		INTEGER,
	parent_id	VARCHAR,
	account_id	VARCHAR,
	has_children	BOOLEAN,
	sort_path	VARCHAR[]
) AS $$
    WITH base_rows AS (
	SELECT * FROM bsheet_report(b, d)
    ),
    leaf_rows AS (
	SELECT
	    base_rows.book_id,
	    base_rows.section,
	    base_rows.section_order,
	    20 AS row_order,
	    'account'::VARCHAR AS row_kind,
	    account_tree.name::VARCHAR AS account,
	    base_rows.account_type,
	    base_rows.origcurrency,
	    base_rows.pretax,
	    base_rows.posttax,
	    account_tree.depth,
	    account_tree.parent_id,
	    account_tree.id AS account_id,
	    EXISTS (
		SELECT 1
		FROM report_account_tree AS child
		WHERE child.book_id = account_tree.book_id
		  AND child.parent_id = account_tree.id
	    ) AS has_children,
	    account_tree.sort_path,
	    account_tree.ancestor_ids
	FROM base_rows
	JOIN report_account_tree AS account_tree
	  ON account_tree.book_id = base_rows.book_id
	 AND account_tree.id = base_rows.account
	WHERE base_rows.row_kind = 'account'
	  AND NOT account_tree.placeholder
	  AND (
	    base_rows.posttax IS DISTINCT FROM 0
	    OR base_rows.pretax IS NOT NULL
	    OR base_rows.origcurrency IS NOT NULL
	  )
    ),
    computed_rows AS (
	SELECT
	    base_rows.book_id,
	    base_rows.section,
	    base_rows.section_order,
	    20 AS row_order,
	    'computed'::VARCHAR AS row_kind,
	    base_rows.account,
	    base_rows.account_type,
	    base_rows.origcurrency,
	    base_rows.pretax,
	    base_rows.posttax,
	    equity.depth + 1 AS depth,
	    equity.id AS parent_id,
	    'Current Earnings'::VARCHAR AS account_id,
	    FALSE AS has_children,
	    equity.sort_path || 'zzzz current earnings'::VARCHAR AS sort_path
	FROM base_rows
	JOIN report_account_tree AS equity
	  ON equity.book_id = base_rows.book_id
	 AND equity.id = 'Equity'
	WHERE base_rows.row_kind = 'computed'
    ),
    group_rows AS (
	SELECT
	    account_tree.book_id,
	    CASE account_tree.type
		WHEN 'A' THEN 'Assets'
		WHEN 'L' THEN 'Liabilities'
		ELSE 'Equity'
	    END::VARCHAR AS section,
	    CASE account_tree.type WHEN 'A' THEN 1 WHEN 'L' THEN 2 ELSE 3 END AS section_order,
	    10 AS row_order,
	    'group'::VARCHAR AS row_kind,
	    account_tree.name::VARCHAR AS account,
	    account_tree.type AS account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    round(
		njord.sum_if_complete(leaf_rows.posttax)
		    FILTER (WHERE leaf_rows.account_id IS NOT NULL)
		+ CASE WHEN account_tree.id = 'Equity' THEN
		    (SELECT njord.sum_if_complete(posttax) FROM computed_rows)
		  ELSE 0
		  END,
		2
	    ) AS posttax,
	    account_tree.depth,
	    account_tree.parent_id,
	    account_tree.id AS account_id,
	    TRUE AS has_children,
	    account_tree.sort_path
	FROM report_account_tree AS account_tree
	LEFT JOIN leaf_rows
	  ON leaf_rows.book_id = account_tree.book_id
	 AND account_tree.id = ANY(leaf_rows.ancestor_ids)
	WHERE account_tree.book_id = b
	  AND account_tree.placeholder
	  AND account_tree.type IN ('A', 'L', 'Q')
	  AND (
	    leaf_rows.account_id IS NOT NULL
	    OR account_tree.id = 'Equity'
	       AND EXISTS (SELECT 1 FROM computed_rows)
	  )
	GROUP BY account_tree.book_id, account_tree.type, account_tree.id,
	    account_tree.name, account_tree.depth, account_tree.parent_id,
	    account_tree.sort_path
    ),
    grand_rows AS (
	SELECT
	    base_rows.book_id,
	    base_rows.section,
	    base_rows.section_order,
	    base_rows.row_order,
	    base_rows.row_kind,
	    base_rows.account,
	    base_rows.account_type,
	    base_rows.origcurrency,
	    base_rows.pretax,
	    base_rows.posttax,
	    0 AS depth,
	    NULL::VARCHAR AS parent_id,
	    base_rows.account AS account_id,
	    FALSE AS has_children,
	    ARRAY['zzzz', lower(base_rows.account)]::VARCHAR[] AS sort_path
	FROM base_rows
	WHERE base_rows.row_kind = 'grand_total'
    )
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, depth, parent_id,
	account_id, has_children, sort_path
    FROM group_rows
UNION ALL
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, depth, parent_id,
	account_id, has_children, sort_path
    FROM leaf_rows
UNION ALL
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, depth, parent_id,
	account_id, has_children, sort_path
    FROM computed_rows
UNION ALL
    SELECT * FROM grand_rows;
$$ LANGUAGE SQL STABLE;

-- Net Worth uses the same account tree while retaining leaf-level valuation
-- provenance. Root and group values are complete descendant market totals.
CREATE OR REPLACE FUNCTION hierarchical_net_worth_report(b VARCHAR, d TIMESTAMP)
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
	posttax		NUMERIC,
	commodity	VARCHAR,
	native_balance	NUMERIC,
	valuation_date	TIMESTAMP,
	valuation_source VARCHAR,
	depth		INTEGER,
	parent_id	VARCHAR,
	account_id	VARCHAR,
	has_children	BOOLEAN,
	sort_path	VARCHAR[]
) AS $$
    WITH leaf_rows AS (
	SELECT
	    account_values.book_id,
	    CASE account_values.account_type
		WHEN 'A' THEN 'Assets' ELSE 'Liabilities'
	    END::VARCHAR AS section,
	    CASE account_values.account_type WHEN 'A' THEN 1 ELSE 2 END
		AS section_order,
	    20 AS row_order,
	    'account'::VARCHAR AS row_kind,
	    account_values.account_name AS account,
	    account_values.account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    account_values.market_value AS posttax,
	    account_values.commodity,
	    account_values.native_balance,
	    account_values.valuation_date,
	    account_values.valuation_source,
	    account_values.depth,
	    account_values.parent_id,
	    account_values.account_id,
	    FALSE AS has_children,
	    account_values.sort_path,
	    account_values.ancestor_ids
	FROM njord.net_worth_account_values(b, d) AS account_values
    ),
    group_rows AS (
	SELECT
	    account_tree.book_id,
	    CASE account_tree.type WHEN 'A' THEN 'Assets' ELSE 'Liabilities' END::VARCHAR AS section,
	    CASE account_tree.type WHEN 'A' THEN 1 ELSE 2 END AS section_order,
	    10 AS row_order,
	    'group'::VARCHAR AS row_kind,
	    account_tree.name::VARCHAR AS account,
	    account_tree.type AS account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    round(njord.sum_if_complete(leaf_rows.posttax), 2) AS posttax,
	    NULL::VARCHAR AS commodity,
	    NULL::NUMERIC AS native_balance,
	    NULL::TIMESTAMP AS valuation_date,
	    NULL::VARCHAR AS valuation_source,
	    account_tree.depth,
	    account_tree.parent_id,
	    account_tree.id AS account_id,
	    TRUE AS has_children,
	    account_tree.sort_path
	FROM report_account_tree AS account_tree
	JOIN leaf_rows
	  ON leaf_rows.book_id = account_tree.book_id
	 AND account_tree.id = ANY(leaf_rows.ancestor_ids)
	WHERE account_tree.book_id = b
	  AND account_tree.placeholder
	  AND account_tree.type IN ('A', 'L')
	GROUP BY account_tree.book_id, account_tree.type, account_tree.id,
	    account_tree.name, account_tree.depth, account_tree.parent_id,
	    account_tree.sort_path
    ),
    section_totals AS (
	SELECT
	    sections.section,
	    round(njord.sum_if_complete(leaf_rows.posttax)
		FILTER (WHERE leaf_rows.account_id IS NOT NULL), 2) AS posttax
	FROM (VALUES ('Assets'::VARCHAR), ('Liabilities'::VARCHAR))
	    AS sections(section)
	LEFT JOIN leaf_rows USING (section)
	GROUP BY sections.section
    ),
    grand_rows AS (
	SELECT
	    b::VARCHAR AS book_id,
	    'Net Worth'::VARCHAR AS section,
	    3 AS section_order,
	    100 AS row_order,
	    'grand_total'::VARCHAR AS row_kind,
	    'Net Worth'::VARCHAR AS account,
	    NULL::VARCHAR AS account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    CASE WHEN count(posttax) = 2 THEN round(
		max(posttax) FILTER (WHERE section = 'Assets')
		- max(posttax) FILTER (WHERE section = 'Liabilities'),
		2
	    ) END AS posttax,
	    NULL::VARCHAR AS commodity,
	    NULL::NUMERIC AS native_balance,
	    NULL::TIMESTAMP AS valuation_date,
	    NULL::VARCHAR AS valuation_source,
	    0 AS depth,
	    NULL::VARCHAR AS parent_id,
	    'Net Worth'::VARCHAR AS account_id,
	    FALSE AS has_children,
	    ARRAY['zzzz', 'net worth']::VARCHAR[] AS sort_path
	FROM section_totals
    )
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, commodity, native_balance,
	valuation_date, valuation_source, depth, parent_id, account_id,
	has_children, sort_path
    FROM group_rows
UNION ALL
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, commodity, native_balance,
	valuation_date, valuation_source, depth, parent_id, account_id,
	has_children, sort_path
    FROM leaf_rows
UNION ALL
    SELECT * FROM grand_rows;
$$ LANGUAGE SQL STABLE;

-- Twelve month-end snapshots by default. The final point is the chosen as-of
-- day, so refreshing the detailed report and chart is one atomic page request.
CREATE OR REPLACE FUNCTION net_worth_history(
    b VARCHAR,
    d TIMESTAMP,
    periods INTEGER DEFAULT 12
)
RETURNS TABLE (
	period_end	DATE,
	assets		NUMERIC,
	liabilities	NUMERIC,
	net_worth	NUMERIC
) AS $$
    WITH points AS (
	SELECT least(
	    d::DATE,
	    (
		date_trunc('month', d)
		- make_interval(months => offset_number)
		+ INTERVAL '1 month' - INTERVAL '1 day'
	    )::DATE
	) AS period_end
	FROM generate_series(
	    greatest(1, least(COALESCE(periods, 12), 60)) - 1,
	    0,
	    -1
	) AS offsets(offset_number)
    )
    SELECT
	points.period_end,
	max(report.posttax) FILTER (WHERE report.account = 'Total Assets') AS assets,
	max(report.posttax) FILTER (WHERE report.account = 'Total Liabilities') AS liabilities,
	max(report.posttax) FILTER (WHERE report.row_kind = 'grand_total') AS net_worth
    FROM points
    CROSS JOIN LATERAL net_worth_report(
	b,
	points.period_end::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
    ) AS report
    GROUP BY points.period_end
    ORDER BY points.period_end;
$$ LANGUAGE SQL STABLE;

-- Trial Balance.  This is an internal accounting check over all accounts:
-- positive account balances are debits, negative account balances are
-- credits, and the total row should balance when posted data is balanced.

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
    WITH normalised AS (
	SELECT
	    book_id AS report_book_id,
	    account_type,
	    account,
	    asset_id AS atype,
	    reporting_asset,
	    native_value,
	    report_value
	FROM njord.account_balances_at(b, d)
    ),
    account_rows AS (
	SELECT
		report_book_id,
		10 AS row_order,
		'account'::VARCHAR AS row_kind,
		account,
		account_type,
		CASE WHEN native_value <> 0 THEN
		    njord.native_amount_label(
			abs(native_value), atype, reporting_asset
		    )
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
		round(njord.sum_if_complete(
		    CASE WHEN report_value > 0 THEN report_value
			 WHEN report_value IS NOT NULL THEN 0 END
		), 2) AS debit,
		round(njord.sum_if_complete(
		    CASE WHEN report_value < 0 THEN -report_value
			 WHEN report_value IS NOT NULL THEN 0 END
		), 2) AS credit
	FROM normalised
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
    SELECT * FROM account_rows
    UNION ALL SELECT * FROM totals
    UNION ALL SELECT * FROM differences;
$$ LANGUAGE SQL STABLE;

--
-- Standard Profit & Loss report.  This uses the same report row shape as the
-- balance sheet report, but it is a period report over income and expense
-- accounts.  Income account balances are conventionally presented as positive
-- revenue, expenses as positive costs, and the final row is net profit/loss.

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
		njord.sum_if_complete(valued.report_value) AS pretax_value,
		njord.sum_if_complete(valued.report_value)
		    * accts.pretax AS posttax_value
	FROM books
	JOIN accts
	  ON accts.book_id = books.id
	JOIN xaction_bits
	  ON xaction_bits.book_id = accts.book_id
	 AND xaction_bits.acct = accts.id
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	CROSS JOIN LATERAL (
	    SELECT xaction_bits.amt * njord.asset_rate(
		accts.atype,
		njord.book_reporting_asset_at(books.id, end_date::DATE),
		xactions.date
	    ) AS report_value
	) AS valued
	WHERE books.id = b
	  AND accts.type IN ('I', 'E')
	  AND (start_date IS NULL OR xactions.date >= start_date)
	  AND (end_date IS NULL OR xactions.date <= end_date)
	GROUP BY books.id, accts.type, accts.id,
	    accts.atype, accts.pretax
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
		njord.native_amount_label(
		    CASE WHEN account_type = 'I'
			THEN -native_value
			ELSE native_value
		    END,
		    atype,
		    njord.book_reporting_asset_at(report_book_id, end_date::DATE)
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
	FROM account_values
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
		round(njord.sum_if_complete(posttax), 2) AS posttax
	FROM account_rows
	GROUP BY report_book_id, section, section_order
    ),
    net_income AS (
	SELECT
		books.id AS report_book_id,
		round(njord.sum_if_complete(-posttax_value)
		    FILTER (WHERE account_values.account IS NOT NULL), 2) AS posttax
	FROM books
	LEFT JOIN account_values
	  ON account_values.report_book_id = books.id
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
		CASE WHEN posttax < 0 THEN 'Net Loss'
		    WHEN posttax IS NOT NULL THEN 'Net Profit'
		    ELSE 'Net Profit / Loss'
		END::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		posttax
	FROM net_income
    )
    SELECT * FROM account_rows
    UNION ALL SELECT * FROM section_totals
    UNION ALL SELECT * FROM grand_total;
$$ LANGUAGE SQL STABLE;

-- Profit & Loss arranged as Income/Expense roots, intermediate groups, and
-- posting accounts. Group values are period subtotals of their descendants.
CREATE OR REPLACE FUNCTION hierarchical_profit_loss_report(
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
	posttax		NUMERIC,
	depth		INTEGER,
	parent_id	VARCHAR,
	account_id	VARCHAR,
	has_children	BOOLEAN,
	sort_path	VARCHAR[]
) AS $$
    WITH base_rows AS (
	SELECT * FROM pl_report(b, start_date, end_date)
    ),
    leaf_rows AS (
	SELECT
	    base_rows.book_id,
	    base_rows.section,
	    base_rows.section_order,
	    20 AS row_order,
	    'account'::VARCHAR AS row_kind,
	    account_tree.name::VARCHAR AS account,
	    base_rows.account_type,
	    base_rows.origcurrency,
	    base_rows.pretax,
	    base_rows.posttax,
	    account_tree.depth,
	    account_tree.parent_id,
	    account_tree.id AS account_id,
	    FALSE AS has_children,
	    account_tree.sort_path,
	    account_tree.ancestor_ids
	FROM base_rows
	JOIN report_account_tree AS account_tree
	  ON account_tree.book_id = base_rows.book_id
	 AND account_tree.id = base_rows.account
	WHERE base_rows.row_kind = 'account'
    ),
    group_rows AS (
	SELECT
	    account_tree.book_id,
	    CASE account_tree.type WHEN 'I' THEN 'Income' ELSE 'Expenses' END::VARCHAR AS section,
	    CASE account_tree.type WHEN 'I' THEN 1 ELSE 2 END AS section_order,
	    10 AS row_order,
	    'group'::VARCHAR AS row_kind,
	    account_tree.name::VARCHAR AS account,
	    account_tree.type AS account_type,
	    NULL::VARCHAR AS origcurrency,
	    NULL::NUMERIC AS pretax,
	    round(njord.sum_if_complete(leaf_rows.posttax), 2) AS posttax,
	    account_tree.depth,
	    account_tree.parent_id,
	    account_tree.id AS account_id,
	    TRUE AS has_children,
	    account_tree.sort_path
	FROM report_account_tree AS account_tree
	JOIN leaf_rows
	  ON leaf_rows.book_id = account_tree.book_id
	 AND account_tree.id = ANY(leaf_rows.ancestor_ids)
	WHERE account_tree.book_id = b
	  AND account_tree.placeholder
	  AND account_tree.type IN ('I', 'E')
	GROUP BY account_tree.book_id, account_tree.type, account_tree.id,
	    account_tree.name, account_tree.depth, account_tree.parent_id,
	    account_tree.sort_path
    ),
    grand_rows AS (
	SELECT
	    base_rows.book_id,
	    base_rows.section,
	    base_rows.section_order,
	    base_rows.row_order,
	    base_rows.row_kind,
	    base_rows.account,
	    base_rows.account_type,
	    base_rows.origcurrency,
	    base_rows.pretax,
	    base_rows.posttax,
	    0 AS depth,
	    NULL::VARCHAR AS parent_id,
	    base_rows.account AS account_id,
	    FALSE AS has_children,
	    ARRAY['zzzz', lower(base_rows.account)]::VARCHAR[] AS sort_path
	FROM base_rows
	WHERE base_rows.row_kind = 'grand_total'
    )
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, depth, parent_id,
	account_id, has_children, sort_path
    FROM group_rows
UNION ALL
    SELECT book_id, section, section_order, row_order, row_kind, account,
	account_type, origcurrency, pretax, posttax, depth, parent_id,
	account_id, has_children, sort_path
    FROM leaf_rows
UNION ALL
    SELECT * FROM grand_rows;
$$ LANGUAGE SQL STABLE;

-- Net cash by transaction and commodity. Grouping before conversion removes
-- transfers between cash accounts denominated in the same commodity.
CREATE OR REPLACE FUNCTION njord.cash_movements(
    p_book_id VARCHAR, p_valuation_date DATE
)
RETURNS TABLE (
    book_id VARCHAR,
    xid INTEGER,
    transaction_date TIMESTAMP,
    asset_id VARCHAR,
    reporting_asset VARCHAR,
    account_ids TEXT,
    native_amount NUMERIC,
    reporting_amount NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    SELECT
	movements.*,
	movements.native_amount * njord.asset_rate(
	    movements.asset_id,
	    movements.reporting_asset,
	    movements.transaction_date
	) AS reporting_amount
    FROM (
	SELECT
	    cash_accounts.book_id,
	    postings.xid,
	    transactions.date AS transaction_date,
	    accounts.atype AS asset_id,
	    njord.book_reporting_asset_at(
		cash_accounts.book_id, p_valuation_date
	    ) AS reporting_asset,
	    string_agg(DISTINCT accounts.id, ', ' ORDER BY accounts.id) AS account_ids,
	    sum(postings.amt)::NUMERIC AS native_amount
	FROM cash_accounts
	JOIN accts AS accounts
	  ON accounts.book_id = cash_accounts.book_id
	 AND accounts.id = cash_accounts.acct
	JOIN xaction_bits AS postings
	  ON postings.book_id = cash_accounts.book_id
	 AND postings.acct = cash_accounts.acct
	JOIN xactions AS transactions
	  ON transactions.book_id = postings.book_id
	 AND transactions.xid = postings.xid
	WHERE cash_accounts.book_id = p_book_id
	GROUP BY cash_accounts.book_id, postings.xid, transactions.date,
	    accounts.atype
	HAVING sum(postings.amt) <> 0
    ) AS movements;
$$;

-- Cash reconciliation values these movements in the period-end reporting
-- currency, using the rate available on each transaction date. A NULL start
-- means no opening period boundary; a NULL end includes all postings.
CREATE OR REPLACE FUNCTION njord.cash_balances_for_period(
    p_book_id VARCHAR, p_start TIMESTAMP, p_end TIMESTAMP
)
RETURNS TABLE (
    book_id VARCHAR,
    beginning_cash NUMERIC,
    ending_cash NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    WITH scope AS (
	SELECT
	    books.id AS book_id,
	    njord.book_reporting_asset_at(
		books.id, p_end::DATE
	    ) AS reporting_asset
	FROM books
	WHERE books.id = p_book_id
	  AND EXISTS (
	    SELECT 1 FROM cash_accounts WHERE cash_accounts.book_id = books.id
	  )
    ),
    cash_postings AS (
	SELECT book_id, transaction_date, reporting_amount
	FROM njord.cash_movements(p_book_id, p_end::DATE)
    )
    SELECT
	scope.book_id,
	round(njord.sum_if_complete(reporting_amount) FILTER (
	    WHERE cash_postings.book_id IS NOT NULL
	      AND p_start IS NOT NULL AND transaction_date < p_start
	), 2) AS beginning_cash,
	round(njord.sum_if_complete(reporting_amount) FILTER (
	    WHERE cash_postings.book_id IS NOT NULL
	      AND (p_end IS NULL OR transaction_date <= p_end)
	), 2) AS ending_cash
    FROM scope
    LEFT JOIN cash_postings USING (book_id)
    GROUP BY scope.book_id;
$$;

-- Standard Cash Flow report. Cash and cash-equivalent accounts are explicit
-- SQL data in cash_accounts.  Cash-to-cash transfers are ignored; movements
-- involving a marked cash account are classified by the non-cash side:
-- income/expense accounts are operating, asset accounts are investing, and
-- liability/equity accounts are financing.

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
		njord.sum_if_complete(
		    -xaction_bits.amt * njord.asset_rate(
			accts.atype,
			njord.book_reporting_asset_at(books.id, end_date::DATE),
			xactions.date
		    )
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
	WHERE cash_accounts.acct IS NULL
	  AND accts.type IN ('I', 'E', 'A', 'L', 'Q')
	GROUP BY books.id, accts.type, accts.id,
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
		njord.native_amount_label(
		    native_value, atype,
		    njord.book_reporting_asset_at(report_book_id, end_date::DATE)
		) AS origcurrency,
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
		round(njord.sum_if_complete(posttax), 2) AS posttax
	FROM account_rows
	GROUP BY report_book_id, section, section_order
    ),
    net_cash AS (
	SELECT
		book_scope.report_book_id,
		round(njord.sum_if_complete(account_rows.posttax)
		    FILTER (WHERE account_rows.account IS NOT NULL), 2) AS posttax
	FROM book_scope
	LEFT JOIN account_rows
	  ON account_rows.report_book_id = book_scope.report_book_id
	GROUP BY book_scope.report_book_id
    ),
    cash_balances AS (
	SELECT *
	FROM njord.cash_balances_for_period(b, start_date, end_date)
    ),
    reconciliation_rows AS (
	SELECT
		cash_balances.book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		10 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Cash at Beginning of Period'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		cash_balances.beginning_cash AS posttax
	FROM cash_balances
UNION ALL
	SELECT
		net_cash.report_book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		20 AS row_order,
		'grand_total'::VARCHAR AS row_kind,
		CASE WHEN net_cash.posttax < 0 THEN 'Net Decrease in Cash'
		    WHEN net_cash.posttax IS NOT NULL THEN 'Net Increase in Cash'
		    ELSE 'Net Change in Cash'
		END::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		net_cash.posttax
	FROM net_cash
UNION ALL
	SELECT
		cash_balances.book_id,
		'Cash Reconciliation'::VARCHAR AS section,
		4 AS section_order,
		30 AS row_order,
		'computed'::VARCHAR AS row_kind,
		'Cash at End of Period'::VARCHAR AS account,
		NULL::VARCHAR AS account_type,
		NULL::VARCHAR AS origcurrency,
		NULL::NUMERIC AS pretax,
		cash_balances.ending_cash AS posttax
	FROM cash_balances
    )
    SELECT * FROM account_rows
    UNION ALL SELECT * FROM section_totals
    UNION ALL SELECT * FROM reconciliation_rows;
$$ LANGUAGE SQL STABLE;

-- Core and jurisdiction reports expose the same database-owned row contract.
-- This keeps presentation JSON out of api.report_page and gives every report
-- family one normalisation boundary.
CREATE OR REPLACE FUNCTION core_report_rows(
    b VARCHAR,
    requested_report VARCHAR,
    as_of_date TIMESTAMP,
    start_date TIMESTAMP,
    end_date TIMESTAMP
)
RETURNS TABLE (
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF requested_report = 'balance-sheet' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (
		ORDER BY report.section_order, report.sort_path, report.row_order
	    ),
	    (report.row_kind || ':' || report.account_id)::VARCHAR,
	    njord.statement_report_payload(
		report.row_kind, report.account_id, report.account,
		report.origcurrency, report.pretax, report.posttax, report.depth
	    )
	FROM hierarchical_balance_sheet_report(b, as_of_date) AS report;
    ELSIF requested_report = 'net-worth' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (
		ORDER BY report.section_order, report.sort_path, report.row_order
	    ),
	    (report.row_kind || ':' || report.account_id)::VARCHAR,
	    njord.report_payload(
		report.row_kind, report.account_id,
		jsonb_build_array(
		    njord.report_text_cell('account', report.account),
		    njord.report_text_cell('commodity', report.commodity),
		    njord.report_number_cell(
			'native_balance', report.native_balance, report.commodity
		    ),
		    njord.report_number_cell('market_value', report.posttax),
		    njord.report_text_cell(
			'valuation',
			CASE
			    WHEN report.valuation_source IS NULL THEN NULL
			    WHEN report.valuation_date IS NULL THEN report.valuation_source
			    ELSE report.valuation_source || ' · '
				|| report.valuation_date::DATE
			END
		    )
		),
		report.depth
	    )
	FROM hierarchical_net_worth_report(b, as_of_date) AS report;
    ELSIF requested_report = 'trial-balance' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (ORDER BY report.row_order, report.account),
	    (report.row_kind || ':' || report.account)::VARCHAR,
	    njord.report_payload(
		report.row_kind, report.account,
		jsonb_build_array(
		    njord.report_text_cell('account', report.account),
		    njord.report_text_cell('asset', report.origcurrency),
		    njord.report_number_cell('debit', report.debit),
		    njord.report_number_cell('credit', report.credit)
		)
	    )
	FROM tb_report(b, as_of_date) AS report;
    ELSIF requested_report = 'profit-loss' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (
		ORDER BY report.section_order, report.sort_path, report.row_order
	    ),
	    (report.row_kind || ':' || report.account_id)::VARCHAR,
	    njord.statement_report_payload(
		report.row_kind, report.account_id, report.account,
		report.origcurrency, report.pretax, report.posttax, report.depth
	    )
	FROM hierarchical_profit_loss_report(
	    b, start_date, end_date
	) AS report;
    ELSIF requested_report = 'cash-flow' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (
		ORDER BY report.section_order, report.row_order, report.account
	    ),
	    (report.row_kind || ':' || report.section || ':' || report.account)::VARCHAR,
	    njord.report_payload(
		report.row_kind, report.account,
		jsonb_build_array(
		    njord.report_text_cell('section', report.section),
		    njord.report_text_cell('account', report.account),
		    njord.report_text_cell('asset', report.origcurrency),
		    njord.report_number_cell('pretax', report.pretax),
		    njord.report_number_cell('posttax', report.posttax)
		)
	    )
	FROM cf_report(b, start_date, end_date) AS report;
    END IF;
END;
$$;

CREATE OR REPLACE VIEW general_journal AS
    SELECT
	xactions.book_id,
	CAST (xactions.date AS date) AS date,
	xactions.xid,
	xactions.comment AS description,
	NOT EXISTS (
	    SELECT 1
	    FROM unreconciled_postings
	    WHERE unreconciled_postings.book_id = xaction_bits.book_id
	      AND unreconciled_postings.xid = xaction_bits.xid
	      AND unreconciled_postings.acct = xaction_bits.acct
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
	    THEN xaction_bits.amt
	    ELSE NULL
	END AS debit,
	CASE WHEN xaction_bits.amt < 0
	    THEN -xaction_bits.amt
	    ELSE NULL
	END AS credit
    FROM xactions
    JOIN xaction_bits
      ON xaction_bits.book_id = xactions.book_id
     AND xaction_bits.xid = xactions.xid
    JOIN accts
      ON accts.book_id = xaction_bits.book_id
     AND accts.id = xaction_bits.acct;

-- Book-scoped direct-SQL register. The LEFT joins intentionally retain an
-- empty account as one null posting row for the long-standing SQL contract.
CREATE OR REPLACE FUNCTION ledger(b VARCHAR, a VARCHAR)
RETURNS TABLE (date DATE, xid INTEGER, amt NUMERIC, description VARCHAR)
LANGUAGE SQL
STABLE
AS $$
    SELECT xactions.date::DATE, bits.xid, bits.amt, bits.comment
    FROM accts
    LEFT JOIN xaction_bits AS bits
      ON bits.book_id = accts.book_id AND bits.acct = accts.id
    LEFT JOIN xactions
      ON xactions.book_id = bits.book_id AND xactions.xid = bits.xid
    WHERE accts.book_id = b AND accts.id = a;
$$;
