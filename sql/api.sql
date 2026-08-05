CREATE SCHEMA api;

CREATE OR REPLACE FUNCTION plutus.report_validation_messages(
    p_report VARCHAR,
    p_book_id VARCHAR,
    p_from DATE DEFAULT NULL,
    p_to DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    messages TEXT[] := ARRAY[]::TEXT[];
    missing_accounts TEXT;
    report_end TIMESTAMP;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.books WHERE id = p_book_id) THEN
	RETURN jsonb_build_array('Book does not exist.');
    END IF;

    IF p_from IS NOT NULL AND p_to IS NOT NULL AND p_from > p_to THEN
	messages := array_append(
	    messages,
	    'The start date must not be after the end date.'
	);
    END IF;

    IF p_report = 'cash-flow' AND NOT EXISTS (
	SELECT 1 FROM public.cash_accounts WHERE book_id = p_book_id
    ) THEN
	messages := array_append(
	    messages,
	    'Mark at least one asset account as a cash account for Cash Flow reporting.'
	);
    END IF;

    report_end := CASE
	WHEN p_to IS NULL THEN NULL
	ELSE p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
    END;

    CASE p_report
	WHEN 'balance-sheet' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		SELECT accts.id || ' [' || accts.atype || ']' AS label
		FROM public.books
		JOIN public.accts ON accts.book_id = books.id
		LEFT JOIN public.xaction_bits
		  ON xaction_bits.book_id = accts.book_id
		 AND xaction_bits.acct = accts.id
		LEFT JOIN public.xactions
		  ON xactions.book_id = xaction_bits.book_id
		 AND xactions.xid = xaction_bits.xid
		 AND xactions.date <= report_end
		WHERE books.id = p_book_id
		  AND accts.atype <> books.reporting_asset
		GROUP BY accts.id, accts.atype, books.reporting_asset
		HAVING COALESCE(sum(
		    CASE WHEN xactions.xid IS NULL THEN 0 ELSE xaction_bits.amt END
		  ), 0) <> 0
		  AND NOT EXISTS (
		    SELECT 1
		    FROM public.valuations
		    WHERE valuations.src = accts.atype
		      AND valuations.dst = books.reporting_asset
		      AND valuations.date <= report_end
		      AND valuations.rate IS NOT NULL
		  )
	    ) AS missing;
	WHEN 'trial-balance' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		SELECT accts.id || ' [' || accts.atype || ']' AS label
		FROM public.books
		JOIN public.accts ON accts.book_id = books.id
		LEFT JOIN public.xaction_bits
		  ON xaction_bits.book_id = accts.book_id
		 AND xaction_bits.acct = accts.id
		LEFT JOIN public.xactions
		  ON xactions.book_id = xaction_bits.book_id
		 AND xactions.xid = xaction_bits.xid
		 AND xactions.date <= report_end
		WHERE books.id = p_book_id
		  AND accts.atype <> books.reporting_asset
		GROUP BY accts.id, accts.atype, books.reporting_asset
		HAVING COALESCE(sum(
		    CASE WHEN xactions.xid IS NULL THEN 0 ELSE xaction_bits.amt END
		  ), 0) <> 0
		  AND NOT EXISTS (
		    SELECT 1
		    FROM public.valuations
		    WHERE valuations.src = accts.atype
		      AND valuations.dst = books.reporting_asset
		      AND valuations.date <= report_end
		      AND valuations.rate IS NOT NULL
		  )
	    ) AS missing;
	WHEN 'profit-loss' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		SELECT DISTINCT accts.id || ' [' || accts.atype || ']' AS label
		FROM public.books
		JOIN public.accts ON accts.book_id = books.id
		JOIN public.xaction_bits
		  ON xaction_bits.book_id = accts.book_id
		 AND xaction_bits.acct = accts.id
		JOIN public.xactions
		  ON xactions.book_id = xaction_bits.book_id
		 AND xactions.xid = xaction_bits.xid
		WHERE books.id = p_book_id
		  AND accts.type IN ('I', 'E')
		  AND accts.atype <> books.reporting_asset
		  AND (p_from IS NULL OR xactions.date >= p_from::TIMESTAMP)
		  AND (report_end IS NULL OR xactions.date <= report_end)
		  AND NOT EXISTS (
		    SELECT 1
		    FROM public.valuations
		    WHERE valuations.src = accts.atype
		      AND valuations.dst = books.reporting_asset
		      AND valuations.date <= xactions.date
		      AND valuations.rate IS NOT NULL
		  )
	    ) AS missing;
	WHEN 'cash-flow' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		WITH period_cash_transactions AS (
		    SELECT DISTINCT xactions.book_id, xactions.xid, xactions.date
		    FROM public.xactions
		    JOIN public.xaction_bits
		      ON xaction_bits.book_id = xactions.book_id
		     AND xaction_bits.xid = xactions.xid
		    JOIN public.cash_accounts
		      ON cash_accounts.book_id = xaction_bits.book_id
		     AND cash_accounts.acct = xaction_bits.acct
		    WHERE xactions.book_id = p_book_id
		      AND (p_from IS NULL OR xactions.date >= p_from::TIMESTAMP)
		      AND (report_end IS NULL OR xactions.date <= report_end)
		),
		missing_period_accounts AS (
		    SELECT DISTINCT accts.id, accts.atype
		    FROM period_cash_transactions
		    JOIN public.xaction_bits
		      ON xaction_bits.book_id = period_cash_transactions.book_id
		     AND xaction_bits.xid = period_cash_transactions.xid
		    JOIN public.accts
		      ON accts.book_id = xaction_bits.book_id
		     AND accts.id = xaction_bits.acct
		    JOIN public.books ON books.id = accts.book_id
		    WHERE accts.atype <> books.reporting_asset
		      AND NOT EXISTS (
			SELECT 1
			FROM public.valuations
			WHERE valuations.src = accts.atype
			  AND valuations.dst = books.reporting_asset
			  AND valuations.date <= period_cash_transactions.date
			  AND valuations.rate IS NOT NULL
		      )
		),
		missing_cash_balances AS (
		    SELECT DISTINCT accts.id, accts.atype
		    FROM public.cash_accounts
		    JOIN public.accts
		      ON accts.book_id = cash_accounts.book_id
		     AND accts.id = cash_accounts.acct
		    JOIN public.books ON books.id = accts.book_id
		    JOIN public.xaction_bits
		      ON xaction_bits.book_id = cash_accounts.book_id
		     AND xaction_bits.acct = cash_accounts.acct
		    JOIN public.xactions
		      ON xactions.book_id = xaction_bits.book_id
		     AND xactions.xid = xaction_bits.xid
		    WHERE cash_accounts.book_id = p_book_id
		      AND accts.atype <> books.reporting_asset
		      AND (report_end IS NULL OR xactions.date <= report_end)
		      AND NOT EXISTS (
			SELECT 1
			FROM public.valuations
			WHERE valuations.src = accts.atype
			  AND valuations.dst = books.reporting_asset
			  AND valuations.date <= xactions.date
			  AND valuations.rate IS NOT NULL
		      )
		)
		SELECT id || ' [' || atype || ']' AS label
		FROM missing_period_accounts
		UNION
		SELECT id || ' [' || atype || ']' AS label
		FROM missing_cash_balances
	    ) AS missing;
	ELSE
	    NULL;
    END CASE;

    IF missing_accounts IS NOT NULL THEN
	messages := array_append(
	    messages,
	    'Missing valuations for: ' || missing_accounts || '.'
	);
    END IF;

    RETURN to_jsonb(messages);
END;
$$;

-- A page is a relational stream of typed components.  The payload varies by
-- component, while the other columns provide stable identity and ordering.

CREATE OR REPLACE FUNCTION api.shell_page(p_book_id VARCHAR DEFAULT NULL)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT
	'book_option'::VARCHAR,
	1000 + row_number() OVER (ORDER BY books.name, books.id),
	books.id,
	jsonb_build_object(
	    'id', books.id,
	    'name', books.name,
	    'reporting_asset', books.reporting_asset,
	    'selected', books.id = COALESCE(
		p_book_id,
		(SELECT id FROM public.books ORDER BY name, id LIMIT 1)
	    )
	)
    FROM public.books
UNION ALL
    SELECT
	'report_option'::VARCHAR,
	2000 + report_order,
	report_id,
	jsonb_build_object(
	    'id', report_id,
	    'name', report_name,
	    'uses_account', uses_account
	)
    FROM (VALUES
	(1, 'ledger'::VARCHAR, 'Ledger'::VARCHAR, TRUE),
	(2, 'general-journal'::VARCHAR, 'General Journal'::VARCHAR, FALSE),
	(3, 'balance-sheet'::VARCHAR, 'Balance Sheet'::VARCHAR, FALSE),
	(4, 'trial-balance'::VARCHAR, 'Trial Balance'::VARCHAR, FALSE),
	(5, 'profit-loss'::VARCHAR, 'Income and Expenses'::VARCHAR, FALSE),
	(6, 'cash-flow'::VARCHAR, 'Cash Flow'::VARCHAR, FALSE)
    ) AS reports(report_order, report_id, report_name, uses_account)
UNION ALL
    SELECT
	'account_option'::VARCHAR,
	3000 + row_number() OVER (ORDER BY accts.type, accts.id),
	accts.id,
	jsonb_build_object(
	    'book_id', accts.book_id,
	    'id', accts.id,
	    'type', accts.type,
	    'asset', accts.atype,
	    'pretax', accts.pretax,
	    'comment', accts.comment
	)
    FROM public.accts
    WHERE accts.book_id = COALESCE(
	p_book_id,
	(SELECT id FROM public.books ORDER BY name, id LIMIT 1)
    );
$$;

CREATE OR REPLACE FUNCTION api.ledger_page(
    p_book_id VARCHAR,
    p_account_id VARCHAR
)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'ledger'::VARCHAR,
	jsonb_build_object(
	    'page', 'ledger',
	    'book_id', p_book_id,
	    'account_id', p_account_id,
	    'book_exists', EXISTS (
		SELECT 1 FROM public.books WHERE id = p_book_id
	    ),
	    'transaction_rules', jsonb_build_object(
		'minimum_resolved_lines', 2,
		'nonzero_amounts', TRUE,
		'unique_accounts', TRUE,
		'balance_per_asset', TRUE
	    ),
	    'account_exists', EXISTS (
		SELECT 1
		FROM public.accts
		WHERE book_id = p_book_id AND id = p_account_id
	    ),
	    'validation_messages', CASE
		WHEN NOT EXISTS (
		    SELECT 1 FROM public.books WHERE id = p_book_id
		) THEN jsonb_build_array('Book does not exist.')
		WHEN NOT EXISTS (
		    SELECT 1 FROM public.accts
		    WHERE book_id = p_book_id AND id = p_account_id
		) THEN jsonb_build_array('Account does not exist in this book.')
		ELSE '[]'::JSONB
	    END
	)
UNION ALL
    SELECT
	'transfer_account_option'::VARCHAR,
	9500 + row_number() OVER (ORDER BY accts.type, accts.id),
	accts.id,
	jsonb_build_object(
	    'id', accts.id,
	    'type', accts.type,
	    'asset', accts.atype
	)
    FROM public.accts
    WHERE accts.book_id = p_book_id
      AND accts.id <> p_account_id
      AND accts.atype = (
	SELECT selected.atype
	FROM public.accts AS selected
	WHERE selected.book_id = p_book_id
	  AND selected.id = p_account_id
      )
UNION ALL
    SELECT
	'ledger_row'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY xactions.date, selected_bits.xid, selected_bits.id
	),
	selected_bits.xid::VARCHAR,
	jsonb_build_object(
	    'date', CAST(xactions.date AS date),
	    'xid', selected_bits.xid,
	    'account', selected_bits.acct,
	    'description', COALESCE(selected_bits.comment, xactions.comment),
	    'transaction_comment', xactions.comment,
	    'transfer', CASE
		WHEN line_counts.line_count = 2 THEN other_bits.acct
		ELSE NULL
	    END,
	    'reconciled', NOT EXISTS (
		SELECT 1
		FROM public.xaction_unresolved
		WHERE book_id = selected_bits.book_id
		  AND xid = selected_bits.xid
	    ),
	    'amount', selected_bits.amt,
	    'balance', sum(selected_bits.amt) OVER (
		ORDER BY xactions.date, selected_bits.xid, selected_bits.id
	    ),
	    'split', line_counts.line_count > 2,
	    'split_lines', (
		SELECT jsonb_agg(
		    jsonb_build_object(
			'account', transaction_bits.acct,
			'comment', transaction_bits.comment,
			'amount', transaction_bits.amt
		    )
		    ORDER BY transaction_bits.id
		)
		FROM public.xaction_bits AS transaction_bits
		WHERE transaction_bits.book_id = selected_bits.book_id
		  AND transaction_bits.xid = selected_bits.xid
	    )
	)
    FROM public.xaction_bits AS selected_bits
    JOIN public.xactions
	ON xactions.book_id = selected_bits.book_id
       AND xactions.xid = selected_bits.xid
    JOIN (
	SELECT book_id, xid, count(*) AS line_count
	FROM public.xaction_bits
	GROUP BY book_id, xid
    ) AS line_counts
	ON line_counts.book_id = selected_bits.book_id
       AND line_counts.xid = selected_bits.xid
    LEFT JOIN public.xaction_bits AS other_bits
	ON other_bits.book_id = selected_bits.book_id
       AND other_bits.xid = selected_bits.xid
       AND line_counts.line_count = 2
       AND other_bits.acct <> selected_bits.acct
    WHERE selected_bits.book_id = p_book_id
      AND selected_bits.acct = p_account_id;
$$;

CREATE OR REPLACE FUNCTION api.general_journal_page(p_book_id VARCHAR)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'general-journal'::VARCHAR,
	jsonb_build_object(
	    'page', 'general-journal',
	    'book_id', p_book_id,
	    'book_exists', EXISTS (
		SELECT 1 FROM public.books WHERE id = p_book_id
	    ),
	    'validation_messages', CASE
		WHEN EXISTS (
		    SELECT 1 FROM public.books WHERE id = p_book_id
		) THEN '[]'::JSONB
		ELSE jsonb_build_array('Book does not exist.')
	    END
	)
UNION ALL
    SELECT
	'journal_row'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY journal.date, journal.xid, journal.line_order, journal.line_id
	),
	journal.xid || ':' || journal.line_id,
	to_jsonb(journal)
    FROM public.general_journal AS journal
    WHERE journal.book_id = p_book_id;
$$;

CREATE OR REPLACE FUNCTION api.balance_sheet_page(
    p_book_id VARCHAR,
    p_as_of DATE DEFAULT NULL
)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'balance-sheet'::VARCHAR,
	jsonb_build_object(
	    'page', 'balance-sheet',
	    'book_id', p_book_id,
	    'as_of', COALESCE(p_as_of, CURRENT_DATE),
	    'validation_messages', plutus.report_validation_messages(
		'balance-sheet', p_book_id, NULL, COALESCE(p_as_of, CURRENT_DATE)
	    )
	)
UNION ALL
    SELECT
	'report_row'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY report.section_order, report.row_order, report.account
	),
	report.section || ':' || report.row_kind || ':' || report.account,
	to_jsonb(report)
    FROM public.bsheet_report(
	p_book_id,
	COALESCE(p_as_of, CURRENT_DATE)::TIMESTAMP
	    + INTERVAL '1 day' - INTERVAL '1 microsecond'
    ) AS report;
$$;

CREATE OR REPLACE FUNCTION api.trial_balance_page(
    p_book_id VARCHAR,
    p_as_of DATE DEFAULT NULL
)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'trial-balance'::VARCHAR,
	jsonb_build_object(
	    'page', 'trial-balance',
	    'book_id', p_book_id,
	    'as_of', COALESCE(p_as_of, CURRENT_DATE),
	    'validation_messages', plutus.report_validation_messages(
		'trial-balance', p_book_id, NULL, COALESCE(p_as_of, CURRENT_DATE)
	    )
	)
UNION ALL
    SELECT
	'trial_balance_row'::VARCHAR,
	10000 + row_number() OVER (ORDER BY report.row_order, report.account),
	report.row_kind || ':' || report.account,
	to_jsonb(report)
    FROM public.tb_report(
	p_book_id,
	COALESCE(p_as_of, CURRENT_DATE)::TIMESTAMP
	    + INTERVAL '1 day' - INTERVAL '1 microsecond'
    ) AS report;
$$;

CREATE OR REPLACE FUNCTION api.profit_loss_page(
    p_book_id VARCHAR,
    p_from DATE DEFAULT NULL,
    p_to DATE DEFAULT NULL
)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'profit-loss'::VARCHAR,
	jsonb_build_object(
	    'page', 'profit-loss',
	    'book_id', p_book_id,
	    'from', p_from,
	    'to', p_to,
	    'validation_messages', plutus.report_validation_messages(
		'profit-loss', p_book_id, p_from, p_to
	    )
	)
UNION ALL
    SELECT
	'report_row'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY report.section_order, report.row_order, report.account
	),
	report.section || ':' || report.row_kind || ':' || report.account,
	to_jsonb(report)
    FROM public.pl_report(
	p_book_id,
	p_from::TIMESTAMP,
	p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
    ) AS report;
$$;

CREATE OR REPLACE FUNCTION api.cash_flow_page(
    p_book_id VARCHAR,
    p_from DATE DEFAULT NULL,
    p_to DATE DEFAULT NULL
)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'cash-flow'::VARCHAR,
	jsonb_build_object(
	    'page', 'cash-flow',
	    'book_id', p_book_id,
	    'from', p_from,
	    'to', p_to,
	    'validation_messages', plutus.report_validation_messages(
		'cash-flow', p_book_id, p_from, p_to
	    )
	)
UNION ALL
    SELECT
	'report_row'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY report.section_order, report.row_order, report.account
	),
	report.section || ':' || report.row_kind || ':' || report.account,
	to_jsonb(report)
    FROM public.cf_report(
	p_book_id,
	p_from::TIMESTAMP,
	p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
    ) AS report;
$$;

CREATE OR REPLACE FUNCTION api.add_book_page()
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(NULL)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'add-book'::VARCHAR,
	jsonb_build_object(
	    'page', 'add-book',
	    'reporting_asset', 'GBP',
	    'validation', jsonb_build_object(
		'id_required', TRUE,
		'name_required', TRUE,
		'reporting_asset_required', TRUE
	    )
	)
UNION ALL
    SELECT
	'asset_option'::VARCHAR,
	10000 + row_number() OVER (ORDER BY asset.id),
	asset.id,
	jsonb_build_object('id', asset.id)
    FROM public.asset;
$$;

CREATE OR REPLACE FUNCTION api.add_account_page(p_book_id VARCHAR)
RETURNS TABLE (
    component VARCHAR,
    row_order BIGINT,
    row_key VARCHAR,
    payload JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'add-account'::VARCHAR,
	jsonb_build_object(
	    'page', 'add-account',
	    'book_id', p_book_id,
	    'account_type', 'A',
	    'asset', (
		SELECT books.reporting_asset
		FROM public.books
		WHERE books.id = p_book_id
	    ),
	    'pretax', 1,
	    'opening_date', CURRENT_DATE,
	    'validation_messages', CASE
		WHEN EXISTS (
		    SELECT 1 FROM public.books WHERE id = p_book_id
		) THEN '[]'::JSONB
		ELSE jsonb_build_array('Book does not exist.')
	    END,
	    'validation', jsonb_build_object(
		'id_required', TRUE,
		'type_required', TRUE,
		'asset_required', TRUE,
		'opening_date_required_with_balance', TRUE
	    )
	)
UNION ALL
    SELECT
	'account_type_option'::VARCHAR,
	9500 + row_number() OVER (ORDER BY acct_types.id),
	acct_types.id,
	jsonb_build_object('id', acct_types.id)
    FROM public.acct_types
UNION ALL
    SELECT
	'asset_option'::VARCHAR,
	10000 + row_number() OVER (ORDER BY asset.id),
	asset.id,
	jsonb_build_object('id', asset.id)
    FROM public.asset;
$$;

CREATE OR REPLACE FUNCTION plutus.transaction_preview(
    p_book_id VARCHAR,
    p_transaction JSONB
)
RETURNS TABLE (
    valid BOOLEAN,
    error_code VARCHAR,
    error_message VARCHAR,
    imbalance JSONB,
    normalized_transaction JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    line_count INTEGER;
    duplicate_account VARCHAR;
    missing_account VARCHAR;
    bad_line INTEGER;
    normalized_comment VARCHAR;
    normalized_lines JSONB;
    requested_date DATE;
    requested_resolved BOOLEAN;
BEGIN
    valid := FALSE;
    error_code := NULL;
    error_message := NULL;
    imbalance := '{}'::JSONB;
    normalized_transaction := NULL;

    IF NOT EXISTS (SELECT 1 FROM public.books WHERE id = p_book_id) THEN
	error_code := 'BOOK_NOT_FOUND';
	error_message := 'book does not exist';
	RETURN NEXT;
	RETURN;
    END IF;

    BEGIN
	requested_date := (p_transaction ->> 'date')::DATE;
    EXCEPTION WHEN OTHERS THEN
	error_code := 'INVALID_DATE';
	error_message := 'date must be a valid date';
	RETURN NEXT;
	RETURN;
    END;

    IF requested_date IS NULL THEN
	error_code := 'INVALID_DATE';
	error_message := 'date is required';
	RETURN NEXT;
	RETURN;
    END IF;

    BEGIN
	requested_resolved := COALESCE(
	    (p_transaction ->> 'resolved')::BOOLEAN,
	    TRUE
	);
    EXCEPTION WHEN OTHERS THEN
	error_code := 'INVALID_RESOLVED';
	error_message := 'resolved must be a boolean';
	RETURN NEXT;
	RETURN;
    END;

    IF jsonb_typeof(p_transaction -> 'lines') IS DISTINCT FROM 'array' THEN
	error_code := 'INVALID_LINES';
	error_message := 'lines must be an array';
	RETURN NEXT;
	RETURN;
    END IF;

    line_count := jsonb_array_length(p_transaction -> 'lines');

    IF line_count = 0 THEN
	error_code := 'TRANSACTION_REQUIRES_LINES';
	error_message := 'transactions require at least one line';
	RETURN NEXT;
	RETURN;
    END IF;

    BEGIN
	SELECT ordinality::INTEGER
	INTO bad_line
	FROM jsonb_array_elements(p_transaction -> 'lines')
	    WITH ORDINALITY AS lines(line, ordinality)
	WHERE jsonb_typeof(line) IS DISTINCT FROM 'object'
	   OR NULLIF(btrim(line ->> 'account'), '') IS NULL
	   OR NULLIF(btrim(line ->> 'amount'), '') IS NULL
	   OR (line ->> 'amount')::NUMERIC(100,5) = 0
	   OR ((line ->> 'amount')::NUMERIC(100,5))::TEXT IN (
		'NaN', 'Infinity', '-Infinity'
	   )
	LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
	error_code := 'INVALID_LINE';
	error_message := 'every line requires an account and numeric non-zero amount';
	RETURN NEXT;
	RETURN;
    END;

    IF bad_line IS NOT NULL THEN
	error_code := 'INVALID_LINE';
	error_message := 'every line requires an account and non-zero amount';
	RETURN NEXT;
	RETURN;
    END IF;

    SELECT account
    INTO duplicate_account
    FROM (
	SELECT btrim(line ->> 'account') AS account, count(*)
	FROM jsonb_array_elements(p_transaction -> 'lines') AS lines(line)
	GROUP BY btrim(line ->> 'account')
	HAVING count(*) > 1
    ) AS duplicates
    LIMIT 1;

    IF duplicate_account IS NOT NULL THEN
	error_code := 'DUPLICATE_ACCOUNT';
	error_message := 'each transaction line must use a different account';
	RETURN NEXT;
	RETURN;
    END IF;

    SELECT btrim(line ->> 'account')
    INTO missing_account
    FROM jsonb_array_elements(p_transaction -> 'lines') AS lines(line)
    WHERE NOT EXISTS (
	SELECT 1
	FROM public.accts
	WHERE book_id = p_book_id
	  AND id = btrim(line ->> 'account')
    )
    LIMIT 1;

    IF missing_account IS NOT NULL THEN
	error_code := 'ACCOUNT_NOT_FOUND';
	error_message := 'account does not exist in this book: ' || missing_account;
	RETURN NEXT;
	RETURN;
    END IF;

    IF requested_resolved AND line_count < 2 THEN
	error_code := 'RESOLVED_TRANSACTION_REQUIRES_LINES';
	error_message := 'resolved transactions require at least two lines';
	RETURN NEXT;
	RETURN;
    END IF;

    SELECT COALESCE(
	jsonb_object_agg(asset, amount ORDER BY asset),
	'{}'::JSONB
    )
    INTO imbalance
    FROM (
	SELECT
	    accts.atype AS asset,
	    sum((line ->> 'amount')::NUMERIC(100,5)) AS amount
	FROM jsonb_array_elements(p_transaction -> 'lines') AS lines(line)
	JOIN public.accts
	  ON accts.book_id = p_book_id
	 AND accts.id = btrim(line ->> 'account')
	GROUP BY accts.atype
	HAVING sum((line ->> 'amount')::NUMERIC(100,5)) <> 0
    ) AS imbalances;

    normalized_comment := NULLIF(btrim(p_transaction ->> 'comment'), '');

    IF normalized_comment IS NULL THEN
	IF line_count <= 2 THEN
	    SELECT NULLIF(btrim(line ->> 'comment'), '')
	    INTO normalized_comment
	    FROM jsonb_array_elements(p_transaction -> 'lines')
		WITH ORDINALITY AS lines(line, ordinality)
	    WHERE NULLIF(btrim(line ->> 'comment'), '') IS NOT NULL
	    ORDER BY ordinality
	    LIMIT 1;
	ELSE
	    SELECT CASE
		WHEN count(DISTINCT memo) = 1 THEN min(memo)
		ELSE NULL
	    END
	    INTO normalized_comment
	    FROM (
		SELECT NULLIF(btrim(line ->> 'comment'), '') AS memo
		FROM jsonb_array_elements(p_transaction -> 'lines') AS lines(line)
	    ) AS memos
	    WHERE memo IS NOT NULL;
	END IF;
    END IF;

    SELECT jsonb_agg(
	jsonb_build_object(
	    'account', btrim(line ->> 'account'),
	    'amount', (line ->> 'amount')::NUMERIC(100,5),
	    'comment', CASE
		WHEN line_count <= 2 THEN NULL
		WHEN NULLIF(btrim(line ->> 'comment'), '') = normalized_comment
		    THEN NULL
		ELSE NULLIF(btrim(line ->> 'comment'), '')
	    END
	)
	ORDER BY ordinality
    )
    INTO normalized_lines
    FROM jsonb_array_elements(p_transaction -> 'lines')
	WITH ORDINALITY AS lines(line, ordinality);

    normalized_transaction := jsonb_build_object(
	'date', requested_date,
	'resolved', requested_resolved,
	'comment', normalized_comment,
	'lines', normalized_lines
    );

    IF requested_resolved AND imbalance <> '{}'::JSONB THEN
	error_code := 'TRANSACTION_NOT_BALANCED';
	error_message := 'resolved transaction is not balanced per asset';
	RETURN NEXT;
	RETURN;
    END IF;

    valid := TRUE;
    RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION api.preview_transaction(
    p_book_id VARCHAR,
    p_transaction JSONB
)
RETURNS TABLE (
    valid BOOLEAN,
    error_code VARCHAR,
    error_message VARCHAR,
    imbalance JSONB,
    normalized_transaction JSONB
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM plutus.transaction_preview(p_book_id, p_transaction);
$$;

CREATE OR REPLACE FUNCTION plutus.require_valid_transaction(
    p_book_id VARCHAR,
    p_transaction JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    preview RECORD;
BEGIN
    SELECT *
    INTO preview
    FROM plutus.transaction_preview(p_book_id, p_transaction);

    IF NOT preview.valid THEN
	RAISE EXCEPTION '%', preview.error_message
	    USING ERRCODE = 'P0001',
		  DETAIL = preview.error_code;
    END IF;

    RETURN preview.normalized_transaction;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_transaction(
    p_book_id VARCHAR,
    p_transaction JSONB
)
RETURNS TABLE (
    book_id VARCHAR,
    xid INTEGER,
    resolved BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized JSONB;
    new_xid INTEGER;
BEGIN
    normalized := plutus.require_valid_transaction(p_book_id, p_transaction);

    INSERT INTO public.xactions (book_id, date, comment)
    VALUES (
	p_book_id,
	(normalized ->> 'date')::DATE,
	normalized ->> 'comment'
    )
    RETURNING xactions.xid INTO new_xid;

    INSERT INTO public.xaction_bits (book_id, xid, acct, amt, comment)
    SELECT
	p_book_id,
	new_xid,
	line ->> 'account',
	(line ->> 'amount')::NUMERIC,
	line ->> 'comment'
    FROM jsonb_array_elements(normalized -> 'lines') AS lines(line);

    IF NOT (normalized ->> 'resolved')::BOOLEAN THEN
	INSERT INTO public.xaction_unresolved (book_id, xid)
	VALUES (p_book_id, new_xid);
    END IF;

    RETURN QUERY SELECT
	p_book_id,
	new_xid,
	(normalized ->> 'resolved')::BOOLEAN;
END;
$$;

CREATE OR REPLACE FUNCTION api.replace_transaction(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_transaction JSONB
)
RETURNS TABLE (
    book_id VARCHAR,
    xid INTEGER,
    resolved BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized JSONB;
BEGIN
    normalized := plutus.require_valid_transaction(p_book_id, p_transaction);

    UPDATE public.xactions
    SET date = (normalized ->> 'date')::DATE,
	comment = normalized ->> 'comment'
    WHERE xactions.book_id = p_book_id
      AND xactions.xid = p_xid;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'transaction does not exist'
	    USING ERRCODE = 'P0002',
		  DETAIL = 'TRANSACTION_NOT_FOUND';
    END IF;

    DELETE FROM public.xaction_unresolved
    WHERE xaction_unresolved.book_id = p_book_id
      AND xaction_unresolved.xid = p_xid;

    DELETE FROM public.xaction_bits
    WHERE xaction_bits.book_id = p_book_id
      AND xaction_bits.xid = p_xid;

    INSERT INTO public.xaction_bits (book_id, xid, acct, amt, comment)
    SELECT
	p_book_id,
	p_xid,
	line ->> 'account',
	(line ->> 'amount')::NUMERIC,
	line ->> 'comment'
    FROM jsonb_array_elements(normalized -> 'lines') AS lines(line);

    IF NOT (normalized ->> 'resolved')::BOOLEAN THEN
	INSERT INTO public.xaction_unresolved (book_id, xid)
	VALUES (p_book_id, p_xid);
    END IF;

    RETURN QUERY SELECT
	p_book_id,
	p_xid,
	(normalized ->> 'resolved')::BOOLEAN;
END;
$$;

CREATE OR REPLACE FUNCTION api.update_ledger_line(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_account_id VARCHAR,
    p_date DATE,
    p_description VARCHAR
)
RETURNS TABLE (
    book_id VARCHAR,
    xid INTEGER,
    account_id VARCHAR
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    line_count INTEGER;
    transaction_comment VARCHAR;
BEGIN
    IF p_date IS NULL THEN
	RAISE EXCEPTION 'date is required'
	    USING ERRCODE = 'P0001', DETAIL = 'INVALID_DATE';
    END IF;

    SELECT count(*)
    INTO line_count
    FROM public.xaction_bits
    WHERE xaction_bits.book_id = p_book_id
      AND xaction_bits.xid = p_xid;

    SELECT xactions.comment
    INTO transaction_comment
    FROM public.xactions
    WHERE xactions.book_id = p_book_id
      AND xactions.xid = p_xid;

    IF NOT EXISTS (
	SELECT 1
	FROM public.xaction_bits
	WHERE xaction_bits.book_id = p_book_id
	  AND xaction_bits.xid = p_xid
	  AND xaction_bits.acct = p_account_id
    ) THEN
	RAISE EXCEPTION 'ledger line does not exist'
	    USING ERRCODE = 'P0002',
		  DETAIL = 'LEDGER_LINE_NOT_FOUND';
    END IF;

    IF line_count = 2 THEN
	UPDATE public.xaction_bits
	SET comment = NULL
	WHERE xaction_bits.book_id = p_book_id
	  AND xaction_bits.xid = p_xid;

	UPDATE public.xactions
	SET date = p_date,
	    comment = NULLIF(btrim(p_description), '')
	WHERE xactions.book_id = p_book_id
	  AND xactions.xid = p_xid;
    ELSE
	UPDATE public.xaction_bits
	SET comment = CASE
	    WHEN NULLIF(btrim(p_description), '') IS NOT DISTINCT FROM
		 NULLIF(btrim(transaction_comment), '') THEN NULL
	    ELSE NULLIF(btrim(p_description), '')
	END
	WHERE xaction_bits.book_id = p_book_id
	  AND xaction_bits.xid = p_xid
	  AND xaction_bits.acct = p_account_id;

	UPDATE public.xactions
	SET date = p_date
	WHERE xactions.book_id = p_book_id
	  AND xactions.xid = p_xid;
    END IF;

    RETURN QUERY SELECT p_book_id, p_xid, p_account_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_book(
    p_id VARCHAR,
    p_name VARCHAR,
    p_reporting_asset VARCHAR,
    p_create_standard_accounts BOOLEAN DEFAULT TRUE
)
RETURNS TABLE (
    id VARCHAR,
    name VARCHAR,
    reporting_asset VARCHAR
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_id VARCHAR;
    normalized_name VARCHAR;
    normalized_asset VARCHAR;
BEGIN
    normalized_id := NULLIF(btrim(p_id), '');
    normalized_name := NULLIF(btrim(p_name), '');
    normalized_asset := NULLIF(btrim(p_reporting_asset), '');

    IF normalized_id IS NULL THEN
	RAISE EXCEPTION 'book id is required'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_ID_REQUIRED';
    END IF;

    IF normalized_name IS NULL THEN
	RAISE EXCEPTION 'book name is required'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_NAME_REQUIRED';
    END IF;

    IF normalized_asset IS NULL OR NOT EXISTS (
	SELECT 1 FROM public.asset WHERE asset.id = normalized_asset
    ) THEN
	RAISE EXCEPTION 'reporting asset does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'REPORTING_ASSET_NOT_FOUND';
    END IF;

    INSERT INTO public.books (id, name, reporting_asset)
    VALUES (normalized_id, normalized_name, normalized_asset);

    IF COALESCE(p_create_standard_accounts, TRUE) THEN
	INSERT INTO public.accts (book_id, id, type, atype)
	VALUES
	    (normalized_id, 'Opening Balance', 'Q', normalized_asset),
	    (normalized_id, 'Income', 'I', normalized_asset),
	    (normalized_id, 'Expenses', 'E', normalized_asset);
    END IF;

    RETURN QUERY SELECT normalized_id, normalized_name, normalized_asset;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'book already exists'
	USING ERRCODE = 'P0001', DETAIL = 'BOOK_ALREADY_EXISTS';
END;
$$;

CREATE OR REPLACE FUNCTION api.create_account(
    p_book_id VARCHAR,
    p_id VARCHAR,
    p_type VARCHAR,
    p_asset VARCHAR,
    p_pretax NUMERIC DEFAULT 1,
    p_comment VARCHAR DEFAULT NULL,
    p_opening_balance NUMERIC DEFAULT NULL,
    p_opening_date DATE DEFAULT NULL
)
RETURNS TABLE (
    book_id VARCHAR,
    id VARCHAR,
    type VARCHAR,
    asset VARCHAR,
    pretax NUMERIC,
    comment VARCHAR
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    opening_account VARCHAR;
    created_xid INTEGER;
    normalized_id VARCHAR;
    normalized_type VARCHAR;
    normalized_asset VARCHAR;
    normalized_comment VARCHAR;
BEGIN
    normalized_id := NULLIF(btrim(p_id), '');
    normalized_type := NULLIF(btrim(p_type), '');
    normalized_asset := NULLIF(btrim(p_asset), '');
    normalized_comment := NULLIF(btrim(p_comment), '');

    IF NOT EXISTS (
	SELECT 1 FROM public.books WHERE books.id = p_book_id
    ) THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    IF normalized_id IS NULL THEN
	RAISE EXCEPTION 'account id is required'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_ID_REQUIRED';
    END IF;

    IF normalized_type IS NULL OR NOT EXISTS (
	SELECT 1 FROM public.acct_types WHERE acct_types.id = normalized_type
    ) THEN
	RAISE EXCEPTION 'account type does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_TYPE_NOT_FOUND';
    END IF;

    IF normalized_asset IS NULL OR NOT EXISTS (
	SELECT 1 FROM public.asset WHERE asset.id = normalized_asset
    ) THEN
	RAISE EXCEPTION 'account asset does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_ASSET_NOT_FOUND';
    END IF;

    IF p_pretax IS NULL THEN
	RAISE EXCEPTION 'pretax fraction is required'
	    USING ERRCODE = 'P0001', DETAIL = 'PRETAX_REQUIRED';
    END IF;

    IF p_opening_balance IS NOT NULL AND p_opening_balance <> 0
       AND p_opening_date IS NULL THEN
	RAISE EXCEPTION 'opening_date is required when opening_balance is set'
	    USING ERRCODE = 'P0001',
		  DETAIL = 'OPENING_DATE_REQUIRED';
    END IF;

    INSERT INTO public.accts (book_id, id, type, atype, pretax, comment)
    VALUES (
	p_book_id,
	normalized_id,
	normalized_type,
	normalized_asset,
	p_pretax,
	normalized_comment
    );

    IF p_opening_balance IS NOT NULL AND p_opening_balance <> 0 THEN
	opening_account := public.opening_balance_account(
	    p_book_id,
	    normalized_asset
	);

	SELECT result.xid
	INTO created_xid
	FROM api.create_transaction(
	    p_book_id,
	    jsonb_build_object(
		'date', p_opening_date,
		'resolved', TRUE,
		'comment', 'Opening balance',
		'lines', jsonb_build_array(
		    jsonb_build_object(
			'account', normalized_id,
			'amount', p_opening_balance
		    ),
		    jsonb_build_object(
			'account', opening_account,
			'amount', -p_opening_balance
		    )
		)
	    )
	) AS result;
    END IF;

    RETURN QUERY
    SELECT
	accts.book_id,
	accts.id,
	accts.type,
	accts.atype,
	accts.pretax,
	accts.comment
    FROM public.accts
    WHERE accts.book_id = p_book_id
      AND accts.id = normalized_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'account already exists in this book'
	USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_ALREADY_EXISTS';
END;
$$;

COMMENT ON SCHEMA api IS
    'PostgREST API for the Plutus personal-accounting user interface';

COMMENT ON FUNCTION api.ledger_page(VARCHAR, VARCHAR) IS
    'Complete account-ledger page model, including shell and transfer choices';

COMMENT ON FUNCTION api.preview_transaction(VARCHAR, JSONB) IS
    'Validate and normalize a candidate transaction without writing it';
