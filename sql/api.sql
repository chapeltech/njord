-- Pack-owned report definitions are composed only after every production pack
-- has loaded. Elm consumes these views generically and knows no report IDs,
-- jurisdictions, rates, thresholds, or accounting formulae.
CREATE OR REPLACE VIEW report_catalog AS
    SELECT * FROM core_report_catalog
UNION ALL
    SELECT * FROM uk_report_catalog
UNION ALL
    SELECT * FROM panama_report_catalog
UNION ALL
    SELECT * FROM taiwan_report_catalog;

CREATE OR REPLACE VIEW report_columns AS
    SELECT * FROM core_report_columns
UNION ALL
    SELECT * FROM uk_report_columns
UNION ALL
    SELECT * FROM panama_report_columns
UNION ALL
    SELECT * FROM taiwan_report_columns;

CREATE OR REPLACE VIEW report_bar_charts AS
    SELECT * FROM core_report_bar_charts;

-- Every jurisdiction pack records the same reporting-period fact under its
-- own domain table. Compose those facts once so report-page defaults do not
-- need pack-specific dispatch functions.
CREATE OR REPLACE VIEW report_periods AS
    SELECT
	period.book_id,
	'uk_company'::VARCHAR AS profile_kind,
	period.id AS period_id,
	period.period_start,
	period.period_end,
	period.status AS period_status
    FROM uk_accounting_periods AS period
UNION ALL
    SELECT
	period.book_id,
	profile.profile_kind,
	period.id,
	period.period_start,
	period.period_end,
	period.status
    FROM panama_fiscal_periods AS period
    CROSS JOIN (VALUES
	('panama_business'::VARCHAR),
	('panama_residential_property'::VARCHAR)
    ) AS profile(profile_kind)
UNION ALL
    SELECT
	period.book_id,
	profile.profile_kind,
	period.id,
	period.period_start,
	period.period_end,
	period.status
    FROM taiwan_fiscal_periods AS period
    CROSS JOIN (VALUES
	('taiwan_business'::VARCHAR),
	('taiwan_manufacturing'::VARCHAR)
    ) AS profile(profile_kind);

CREATE OR REPLACE FUNCTION njord.report_default_period(
    p_book_id VARCHAR,
    p_profile_kind VARCHAR,
    p_reference DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    book_id VARCHAR,
    profile_kind VARCHAR,
    period_id VARCHAR,
    period_start DATE,
    period_end DATE,
    period_status VARCHAR
)
LANGUAGE SQL
STABLE
AS $$
    SELECT period.*
    FROM report_periods AS period
    WHERE period.book_id = p_book_id
      AND period.profile_kind = p_profile_kind
    ORDER BY
	CASE
	    WHEN COALESCE(p_reference, CURRENT_DATE)
		 BETWEEN period.period_start AND period.period_end THEN 0
	    WHEN period.period_end < COALESCE(p_reference, CURRENT_DATE) THEN 1
	    ELSE 2
	END,
	CASE WHEN period.period_end < COALESCE(p_reference, CURRENT_DATE)
	    THEN period.period_end END DESC NULLS LAST,
	CASE WHEN period.period_start > COALESCE(p_reference, CURRENT_DATE)
	    THEN period.period_start END NULLS LAST,
	period.period_start,
	period.period_end,
	period.period_id
    LIMIT 1;
$$;

-- The API consumes one row contract. This is the single, explicit boundary
-- that chooses the core or jurisdiction implementation for a report family.
CREATE OR REPLACE FUNCTION njord.report_rows(
    p_book_id VARCHAR,
    p_report_id VARCHAR,
    p_profile_kind VARCHAR,
    p_as_of TIMESTAMP,
    p_from TIMESTAMP,
    p_to TIMESTAMP
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
    IF p_profile_kind = 'ordinary' THEN
	RETURN QUERY SELECT * FROM core_report_rows(
	    p_book_id, p_report_id, p_as_of, p_from, p_to
	);
    ELSIF p_profile_kind = 'uk_company' THEN
	RETURN QUERY SELECT * FROM uk_company_report_rows(
	    p_book_id, p_report_id, p_as_of, p_from, p_to
	);
    ELSIF p_profile_kind IN (
	'panama_business', 'panama_residential_property'
    ) THEN
	RETURN QUERY SELECT * FROM panama_report_rows(
	    p_book_id, p_report_id, p_as_of, p_from, p_to
	);
    ELSIF p_profile_kind IN (
	'taiwan_business', 'taiwan_manufacturing'
    ) THEN
	RETURN QUERY SELECT * FROM taiwan_report_rows(
	    p_book_id, p_report_id, p_as_of, p_from, p_to
	);
    END IF;
END;
$$;

CREATE SCHEMA api;

\ir presentation.sql

CREATE OR REPLACE FUNCTION njord.book_exists(p_book_id VARCHAR)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM public.books WHERE id = p_book_id);
$$;

CREATE OR REPLACE FUNCTION njord.posting_account_exists(
    p_book_id VARCHAR, p_account_id VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
	SELECT 1 FROM public.accts
	WHERE book_id = p_book_id AND id = p_account_id AND NOT placeholder
    );
$$;

CREATE OR REPLACE FUNCTION njord.report_validation_messages(
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
    report_asset VARCHAR;
BEGIN
    IF NOT njord.book_exists(p_book_id) THEN
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

    report_end := p_to::TIMESTAMP
	+ INTERVAL '1 day' - INTERVAL '1 microsecond';
    report_asset := njord.book_reporting_asset_at(
	p_book_id, COALESCE(p_to, CURRENT_DATE)
    );

    CASE
	WHEN p_report = 'net-worth' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		SELECT accounts.name || CASE
		    WHEN accounts.account_kind = 'fixed_asset' THEN ' [market estimate]'
		    ELSE ' [' || balances.asset_id || '/' || report_asset || ']'
		END AS label
		FROM njord.account_balances_at(p_book_id, report_end) AS balances
		JOIN public.accts AS accounts
		  ON accounts.book_id = balances.book_id
		 AND accounts.id = balances.account
		WHERE balances.account_type IN ('A', 'L')
		  AND NOT accounts.placeholder
		  AND balances.native_value <> 0
		  AND (
		    (
			balances.account_type = 'A'
			AND accounts.account_kind = 'fixed_asset'
			AND NOT EXISTS (
			    SELECT 1
			    FROM public.account_valuations
			    WHERE account_valuations.book_id = balances.book_id
			      AND account_valuations.acct = balances.account
			      AND account_valuations.dst = report_asset
			      AND account_valuations.date <= report_end
			)
		    )
		    OR (
			balances.asset_id <> report_asset
			AND balances.report_value IS NULL
		    )
		  )
	    ) AS missing;
	WHEN p_report IN ('balance-sheet', 'trial-balance') THEN
	    SELECT string_agg(
		account || ' [' || asset_id || ']', ', ' ORDER BY account
	    )
	    INTO missing_accounts
	    FROM njord.account_balances_at(p_book_id, report_end)
	    WHERE asset_id <> reporting_asset
	      AND native_value <> 0
	      AND report_value IS NULL;
	WHEN p_report = 'profit-loss' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		SELECT DISTINCT
		    account_id || ' [' || account_asset || ']' AS label
		FROM public.report_postings
		WHERE book_id = p_book_id
		  AND account_type IN ('I', 'E')
		  AND account_asset <> report_asset
		  AND (p_from IS NULL OR transaction_date >= p_from::TIMESTAMP)
		  AND (report_end IS NULL OR transaction_date <= report_end)
		  AND njord.asset_rate(
		      account_asset, report_asset, transaction_date
		  ) IS NULL
	    ) AS missing;
	WHEN p_report = 'cash-flow' THEN
	    SELECT string_agg(label, ', ' ORDER BY label)
	    INTO missing_accounts
	    FROM (
		SELECT DISTINCT
		    report.account || ' [' || accounts.atype || ']' AS label
		FROM cf_report(
		    p_book_id, p_from::TIMESTAMP, report_end
		) AS report
		JOIN public.accts AS accounts
		  ON accounts.book_id = report.book_id
		 AND accounts.id = report.account
		WHERE report.row_kind = 'account'
		  AND report.posttax IS NULL
	    UNION
		SELECT
		    movement.account_ids || ' [' || movement.asset_id || ']' AS label
		FROM njord.cash_movements(p_book_id, p_to) AS movement
		WHERE (report_end IS NULL OR movement.transaction_date <= report_end)
		  AND movement.reporting_amount IS NULL
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

-- One ordered definition drives every standard chart bootstrap.  The five
-- roots are the hierarchy contract; the three posting accounts are optional
-- onboarding conveniences for a new Book.
CREATE OR REPLACE VIEW njord.standard_account_catalog (
    account_order, id, name, account_type, parent_id,
    account_kind, placeholder, onboarding
) AS VALUES
    (1, 'Assets'::VARCHAR, 'Assets'::VARCHAR, 'A'::VARCHAR,
	NULL::VARCHAR, 'root'::VARCHAR, TRUE, FALSE),
    (2, 'Liabilities', 'Liabilities', 'L', NULL, 'root', TRUE, FALSE),
    (3, 'Equity', 'Equity', 'Q', NULL, 'root', TRUE, FALSE),
    (4, 'Income', 'Income', 'I', NULL, 'root', TRUE, FALSE),
    (5, 'Expenses', 'Expenses', 'E', NULL, 'root', TRUE, FALSE),
    (6, 'Opening Balance', 'Opening Balance', 'Q', 'Equity',
	'posting', FALSE, TRUE),
    (7, 'Uncategorised Income', 'Uncategorised Income', 'I', 'Income',
	'posting', FALSE, TRUE),
    (8, 'Uncategorised Expenses', 'Uncategorised Expenses', 'E', 'Expenses',
	'posting', FALSE, TRUE);

-- Reuse compatible rows, but never silently reinterpret an occupied account
-- identity or hierarchy slot.  Insertion order keeps parents ahead of leaves.
CREATE OR REPLACE FUNCTION njord.ensure_standard_accounts(
    p_book_id VARCHAR,
    p_include_onboarding BOOLEAN DEFAULT TRUE
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    reporting_asset VARCHAR;
    required_account RECORD;
    colliding_account VARCHAR;
BEGIN
    SELECT books.reporting_asset
    INTO reporting_asset
    FROM public.books
    WHERE books.id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    FOR required_account IN
	SELECT *
	FROM njord.standard_account_catalog
	WHERE p_include_onboarding OR NOT onboarding
	ORDER BY account_order
    LOOP
	CONTINUE WHEN EXISTS (
	    SELECT 1
	    FROM public.accts
	    WHERE accts.book_id = p_book_id
	      AND accts.id = required_account.id
	      AND accts.type = required_account.account_type
	      AND accts.atype = reporting_asset
	      AND accts.parent_id IS NOT DISTINCT FROM required_account.parent_id
	      AND accts.account_kind = required_account.account_kind
	      AND accts.placeholder = required_account.placeholder
	);

	SELECT accts.id
	INTO colliding_account
	FROM public.accts
	WHERE accts.book_id = p_book_id
	  AND (
	    accts.id = required_account.id
	    OR (
		required_account.parent_id IS NULL
		AND accts.parent_id IS NULL
		AND accts.type = required_account.account_type
	    ) OR (
		required_account.parent_id IS NOT NULL
		AND accts.parent_id = required_account.parent_id
		AND accts.name = required_account.name
	    )
	  )
	ORDER BY (accts.id = required_account.id) DESC
	LIMIT 1;

	IF FOUND THEN
	    RAISE EXCEPTION 'standard account % conflicts with existing account %',
		required_account.id, colliding_account
		USING ERRCODE = 'P0001',
		      DETAIL = 'STANDARD_ACCOUNT_COLLISION',
		      HINT = 'required_account=' || required_account.id
			  || '; conflicting_account=' || colliding_account;
	END IF;

	INSERT INTO public.accts (
	    book_id, id, name, type, atype, parent_id,
	    account_kind, placeholder
	) VALUES (
	    p_book_id, required_account.id, required_account.name,
	    required_account.account_type, reporting_asset,
	    required_account.parent_id, required_account.account_kind,
	    required_account.placeholder
	);
    END LOOP;
END;
$$;

-- UK preparation requires the five compatible standard class roots.  Generic
-- onboarding accounts are not readiness requirements for a mature custom
-- chart.  Keep this check separate so the Book page can name what is absent.
CREATE OR REPLACE FUNCTION njord.standard_account_hierarchy_complete(
    p_book_id VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
	SELECT 1
	FROM public.books
	WHERE books.id = p_book_id
	  AND NOT EXISTS (
	    SELECT 1
	    FROM njord.standard_account_catalog AS required
	    WHERE NOT required.onboarding
	      AND NOT EXISTS (
		SELECT 1
		FROM public.accts
		WHERE accts.book_id = books.id
		  AND accts.id = required.id
		  AND accts.type = required.account_type
		  AND accts.atype = books.reporting_asset
		  AND accts.parent_id IS NOT DISTINCT FROM required.parent_id
		  AND accts.account_kind = required.account_kind
		  AND accts.placeholder = required.placeholder
	    )
	  )
    );
$$;

-- One authoritative readiness predicate is shared by the Book page, catalogue
-- discovery, and direct report routes.  A profile row alone is not enough:
-- direct SQL may create partial development data, which must not expose a
-- half-configured UK report surface.
CREATE OR REPLACE FUNCTION njord.uk_company_configuration_complete(
    p_book_id VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
	SELECT 1
	FROM public.uk_company_profiles AS profile
	WHERE profile.book_id = p_book_id
	  AND njord.standard_account_hierarchy_complete(profile.book_id)
	  AND EXISTS (
	    SELECT 1
	    FROM public.uk_accounting_periods AS period
	    WHERE period.book_id = profile.book_id
	  )
	  AND (
	    profile.vat_scheme = 'not_registered'
	    OR EXISTS (
		SELECT 1
		FROM public.uk_company_control_accounts AS control
		WHERE control.book_id = profile.book_id
	    )
	  )
    );
$$;

-- Catalogue eligibility is database-owned. Profile kinds are supplied by the
-- pack SQL; the browser receives only the reports available to the active
-- book and contains no jurisdiction rules.
CREATE OR REPLACE FUNCTION njord.report_profile_available(
    p_book_id VARCHAR,
    p_profile_kind VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT CASE p_profile_kind
	WHEN 'ordinary' THEN njord.book_exists(p_book_id)
        WHEN 'uk_company' THEN
            njord.uk_company_configuration_complete(p_book_id)
        WHEN 'panama_business' THEN EXISTS (
            SELECT 1
            FROM public.panama_business_profiles AS profile
            WHERE profile.book_id = p_book_id
              AND EXISTS (
                  SELECT 1
                  FROM public.panama_fiscal_periods AS period
                  WHERE period.book_id = profile.book_id
              )
        )
        WHEN 'panama_residential_property' THEN EXISTS (
            SELECT 1
            FROM public.panama_residential_property_profiles AS profile
            WHERE profile.book_id = p_book_id
              AND EXISTS (
                  SELECT 1
                  FROM public.panama_fiscal_periods AS period
                  WHERE period.book_id = profile.book_id
              )
              AND EXISTS (
                  SELECT 1
                  FROM public.panama_properties AS property
                  WHERE property.book_id = profile.book_id
              )
        )
        WHEN 'taiwan_business' THEN
            njord.taiwan_business_configuration_complete(p_book_id)
        WHEN 'taiwan_manufacturing' THEN
            njord.taiwan_manufacturing_configuration_complete(p_book_id)
        ELSE FALSE
    END;
$$;

CREATE OR REPLACE FUNCTION njord.report_pack_validation_messages(
    p_report_id VARCHAR,
    p_book_id VARCHAR,
    p_from DATE,
    p_to DATE
)
RETURNS JSONB
LANGUAGE SQL
STABLE
AS $$
    SELECT CASE
	WHEN report_catalog.profile_kind = 'uk_company' THEN
	    njord.uk_report_validation_messages(
		p_report_id, p_book_id, p_from, p_to
	    )
	WHEN report_catalog.profile_kind IN (
	    'panama_business', 'panama_residential_property'
	) THEN to_jsonb(
	    njord.panama_report_validation_messages(
		p_report_id, p_book_id, p_from, p_to
	    )
	)
	WHEN report_catalog.profile_kind IN (
	    'taiwan_business', 'taiwan_manufacturing'
	) THEN to_jsonb(
	    njord.taiwan_report_validation_messages(
		p_report_id, p_book_id, p_from, p_to
	    )
	)
	ELSE '[]'::JSONB
    END
    FROM public.report_catalog
    WHERE report_catalog.report_id = p_report_id;
$$;

-- A page is a relational stream of typed components.  The payload varies by
-- component, while the other columns provide stable identity and ordering.

CREATE OR REPLACE FUNCTION api.report_option_components(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT
	'report_option'::VARCHAR,
	2000 + report_order,
	report_id,
	jsonb_build_object(
	    'id', report_catalog.report_id,
	    'name', report_catalog.title,
	    'description', report_catalog.description,
	    'report_group', report_catalog.report_group
	)
    FROM public.report_catalog
    WHERE njord.report_profile_available(
	p_book_id, report_catalog.profile_kind
    );
$$;

CREATE OR REPLACE FUNCTION api.account_option_components(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT
	'account_option'::VARCHAR,
	3000 + row_number() OVER (ORDER BY accts.type, accts.id),
	accts.id,
	jsonb_build_object(
	    'book_id', accts.book_id,
	    'id', accts.id,
	    'asset', accts.atype
	)
    FROM public.accts
    WHERE accts.book_id = p_book_id
      AND NOT accts.placeholder;
$$;

CREATE OR REPLACE FUNCTION api.shell_page(p_book_id VARCHAR DEFAULT NULL)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    -- Access and global-admin state belong to the control database. Omitting
    -- them here preserves that authoritative state when a Book page loads.
    SELECT
	'book_option'::VARCHAR,
	1000 + row_number() OVER (ORDER BY books.name, books.id),
	books.id,
	jsonb_build_object(
	    'id', books.id,
	    'name', books.name,
	    'reporting_asset', books.reporting_asset,
	    'selected', books.id = p_book_id
	)
    FROM public.books
    WHERE books.archived_at IS NULL OR books.id = p_book_id
UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
$$;

CREATE OR REPLACE FUNCTION api.reports_page(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT * FROM api.report_option_components(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'reports'::VARCHAR,
	jsonb_build_object(
	    'page', 'reports',
	    'book_id', p_book_id,
	    'book_exists', njord.book_exists(p_book_id),
	    'validation_messages', CASE
		WHEN njord.book_exists(p_book_id) THEN '[]'::JSONB
		ELSE jsonb_build_array('Book does not exist.')
	    END
	);
$$;

-- Generic SQL-defined financial report page. Catalogue metadata controls the
-- title, parameters, columns, tree column, alignment, number formatting, and
-- optional bar chart. Every data branch normalises cells to the same payload.
CREATE OR REPLACE FUNCTION api.report_page(
    p_book_id VARCHAR,
    p_report_id VARCHAR,
    p_as_of DATE DEFAULT NULL,
    p_from DATE DEFAULT NULL,
    p_to DATE DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH resolved AS (
	SELECT
	    p_book_id AS book_id,
	    p_report_id AS report_id,
	    catalogue AS report_definition,
	    catalogue.report_id IS NOT NULL AS report_exists,
	    books.id IS NOT NULL AS book_exists,
	    catalogue.profile_kind,
	    catalogue.parameter_kind,
	    COALESCE(
		njord.report_profile_available(
		    p_book_id, catalogue.profile_kind
		),
		FALSE
	    ) AS profile_available,
	    default_period.period_start AS default_from,
	    default_period.period_end AS default_to
	FROM (VALUES (TRUE)) AS singleton(_)
	LEFT JOIN public.report_catalog AS catalogue
	  ON catalogue.report_id = p_report_id
	LEFT JOIN public.books AS books
	  ON books.id = p_book_id
	LEFT JOIN LATERAL njord.report_default_period(
	    p_book_id, catalogue.profile_kind
	) AS default_period ON TRUE
    ),
    resolved_dates AS (
	SELECT
	    resolved.*,
	    COALESCE(p_as_of, default_to, CURRENT_DATE) AS effective_as_of,
	    COALESCE(
		p_from,
		default_from,
		date_trunc('year', CURRENT_DATE)::DATE
	    ) AS effective_from,
	    COALESCE(p_to, default_to, CURRENT_DATE) AS effective_to,
	    COALESCE(p_as_of, p_to, default_to, CURRENT_DATE) AS reporting_on
	FROM resolved
    ),
    request AS (
	SELECT
	    resolved_dates.*,
	    CASE WHEN parameter_kind = 'period'
		THEN effective_from ELSE p_from
	    END AS page_from,
	    CASE WHEN parameter_kind = 'period'
		THEN effective_to ELSE p_to
	    END AS page_to,
	    CASE WHEN parameter_kind = 'period'
		THEN effective_from ELSE NULL
	    END AS pack_validation_from,
	    CASE WHEN parameter_kind = 'as_of'
		THEN effective_as_of ELSE effective_to
	    END AS validation_to,
	    effective_as_of::TIMESTAMP
		+ INTERVAL '1 day' - INTERVAL '1 microsecond' AS as_of_end,
	    effective_from::TIMESTAMP AS from_start,
	    effective_to::TIMESTAMP
		+ INTERVAL '1 day' - INTERVAL '1 microsecond' AS to_end,
	    njord.book_reporting_asset_at(
		book_id, reporting_on
	    ) AS reporting_asset
	FROM resolved_dates
    )
    SELECT shell.*
    FROM request
    CROSS JOIN LATERAL api.shell_page(request.book_id) AS shell
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'report'::VARCHAR,
	jsonb_build_object(
	    'page', 'report',
	    'book_id', request.book_id,
	    'report_id', request.report_id,
	    'reporting_asset', request.reporting_asset,
	    'as_of', request.effective_as_of,
	    'from', request.page_from,
	    'to', request.page_to,
	    'validation_messages', CASE
		WHEN NOT request.report_exists
		    THEN jsonb_build_array('Report does not exist.')
		WHEN NOT request.book_exists
		    THEN jsonb_build_array('Book does not exist.')
		WHEN NOT request.profile_available THEN jsonb_build_array(
		    'Complete this report pack''s setup on the Book page before opening the report.'
		)
		ELSE njord.report_validation_messages(
		    request.report_id,
		    request.book_id,
		    request.page_from,
		    request.validation_to
		) || njord.report_pack_validation_messages(
		    request.report_id,
		    request.book_id,
		    request.pack_validation_from,
		    request.validation_to
		)
	    END
	)
	FROM request
UNION ALL
    SELECT
	'report_definition'::VARCHAR,
	9100::BIGINT,
	request.report_id,
	to_jsonb(request.report_definition)
	    || jsonb_build_object('reporting_asset', request.reporting_asset)
	FROM request
	WHERE request.book_exists
	  AND request.profile_available
UNION ALL
    SELECT
	'report_column'::VARCHAR,
	9200 + report_columns.column_order,
	report_columns.report_id || ':' || report_columns.column_id,
	to_jsonb(report_columns)
	FROM request
	JOIN public.report_columns
	  ON report_columns.report_id = request.report_id
	WHERE request.profile_available
UNION ALL
    SELECT
	'bar_chart_definition'::VARCHAR,
	9300 + report_bar_charts.chart_order,
	report_bar_charts.chart_id,
	to_jsonb(report_bar_charts)
	FROM request
	JOIN public.report_bar_charts
	  ON report_bar_charts.report_id = request.report_id
UNION ALL
    SELECT
	'bar_chart_point'::VARCHAR,
	9400 + row_number() OVER (ORDER BY history.period_end),
	'net-worth-history:' || history.period_end::VARCHAR,
	jsonb_build_object(
		    'chart_id', 'net-worth-history',
		    'label', history.period_end,
		    'value', history.net_worth,
		    'exact', history.net_worth::TEXT,
		    'suffix', request.reporting_asset
	)
	FROM request
	CROSS JOIN LATERAL public.net_worth_history(
	    request.book_id,
	    request.as_of_end
	) AS history
	WHERE request.book_exists
	  AND request.report_id = 'net-worth'
UNION ALL
    SELECT
	'generic_report_row'::VARCHAR,
	10000 + report_rows.row_order,
	(request.report_id || ':' || report_rows.row_key)::VARCHAR,
	report_rows.payload
	FROM request
	CROSS JOIN LATERAL njord.report_rows(
	    request.book_id,
	    request.report_id,
	    request.profile_kind,
	    request.as_of_end,
	    request.from_start,
	    request.to_end
	) AS report_rows
	WHERE request.profile_available;
$$;

CREATE OR REPLACE FUNCTION api.accounts_page(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'accounts'::VARCHAR,
	jsonb_build_object(
	    'page', 'accounts',
	    'book_id', p_book_id,
	    'book_exists', njord.book_exists(p_book_id),
	    'reporting_asset', (
		SELECT books.reporting_asset
		FROM public.books
		WHERE books.id = p_book_id
	    ),
	    'account_count', (
		SELECT count(*)
		FROM public.accts
		WHERE accts.book_id = p_book_id
	    ),
	    'validation_messages', CASE
		WHEN njord.book_exists(p_book_id) THEN '[]'::JSONB
		ELSE jsonb_build_array('Book does not exist.')
	    END
	)
UNION ALL
    (WITH account_tree AS (
	SELECT *
	FROM public.report_account_tree
	WHERE book_id = p_book_id
    ),
    own AS (
	SELECT
	    accts.book_id,
	    accts.id,
	    COALESCE(sum(xaction_bits.amt), 0)::NUMERIC(100,5) AS balance,
	    count(xaction_bits.id)::BIGINT AS posting_count,
	    count(unreconciled_postings.acct)::BIGINT AS unreconciled_count
	FROM public.accts
	LEFT JOIN public.xaction_bits
	  ON xaction_bits.book_id = accts.book_id
	 AND xaction_bits.acct = accts.id
	LEFT JOIN public.unreconciled_postings
	  ON unreconciled_postings.book_id = xaction_bits.book_id
	 AND unreconciled_postings.xid = xaction_bits.xid
	 AND unreconciled_postings.acct = xaction_bits.acct
	WHERE accts.book_id = p_book_id
	GROUP BY accts.book_id, accts.id
    ),
    valued AS (
	SELECT
	    tree.*,
	    own.balance,
	    own.posting_count,
	    own.unreconciled_count,
	    books.reporting_asset,
	    CASE
		WHEN account_value.value IS NOT NULL THEN account_value.value
		WHEN own.balance = 0 THEN 0
		WHEN tree.atype = books.reporting_asset THEN own.balance
		WHEN commodity_value.rate IS NOT NULL
		    THEN own.balance * commodity_value.rate
		ELSE NULL
	    END::NUMERIC(100,5) AS own_reporting_value
	FROM account_tree AS tree
	JOIN own
	  ON own.book_id = tree.book_id
	 AND own.id = tree.id
	JOIN public.books ON books.id = tree.book_id
	LEFT JOIN LATERAL (
	    SELECT account_valuations.value
	    FROM public.account_valuations
	    WHERE account_valuations.book_id = tree.book_id
	      AND account_valuations.acct = tree.id
	      AND account_valuations.dst = books.reporting_asset
	      AND account_valuations.date <= CURRENT_TIMESTAMP
	    ORDER BY account_valuations.date DESC
	    LIMIT 1
	) AS account_value ON TRUE
	LEFT JOIN LATERAL (
	    SELECT valuations.rate
	    FROM public.valuations
	    WHERE valuations.src = tree.atype
	      AND valuations.dst = books.reporting_asset
	      AND valuations.date <= CURRENT_TIMESTAMP
	    ORDER BY valuations.date DESC
	    LIMIT 1
	) AS commodity_value ON tree.atype <> books.reporting_asset
    ),
    totals AS (
	SELECT
	    node.book_id,
	    node.id,
	    sum(descendant.balance) FILTER (
		WHERE descendant.atype = node.atype
	    )::NUMERIC(100,5) AS subtree_balance,
	    bool_and(descendant.atype = node.atype) AS subtree_balance_complete,
	    sum(descendant.posting_count)::BIGINT AS posting_count,
	    sum(descendant.unreconciled_count)::BIGINT AS unreconciled_count,
	    CASE
		WHEN bool_and(descendant.own_reporting_value IS NOT NULL)
		    THEN sum(descendant.own_reporting_value)::NUMERIC(100,5)
		ELSE NULL
	    END AS reporting_value
	FROM valued AS node
	JOIN valued AS descendant
	  ON descendant.book_id = node.book_id
	 AND (
		descendant.id = node.id
		OR node.id = ANY(descendant.ancestor_ids)
	 )
	GROUP BY node.book_id, node.id
    )
    SELECT
	'account_row'::VARCHAR,
	10000 + row_number() OVER (ORDER BY valued.sort_path),
	valued.id,
	jsonb_build_object(
	    'book_id', valued.book_id,
	    'id', valued.id,
	    'name', valued.name,
	    'type', valued.type,
	    'asset', valued.atype,
	    'parent_id', valued.parent_id,
	    'account_kind', valued.account_kind,
	    'placeholder', valued.placeholder,
	    'depth', valued.depth,
	    'ancestor_ids', to_jsonb(valued.ancestor_ids),
	    'path', array_to_string(valued.name_path, ':'),
	    'has_children', EXISTS (
		SELECT 1
		FROM public.accts AS child
		WHERE child.book_id = valued.book_id
		  AND child.parent_id = valued.id
	    ),
	    'balance', valued.balance::TEXT,
	    'subtree_balance', totals.subtree_balance::TEXT,
	    'subtree_balance_complete', totals.subtree_balance_complete,
	    'reporting_asset', valued.reporting_asset,
	    'reporting_value', totals.reporting_value::TEXT,
	    'posting_count', totals.posting_count,
	    'unreconciled_count', totals.unreconciled_count,
	    'is_cash_account', EXISTS (
		SELECT 1
		FROM public.cash_accounts
		WHERE cash_accounts.book_id = valued.book_id
		  AND cash_accounts.acct = valued.id
	    )
	)
    FROM valued
    JOIN totals
	ON totals.book_id = valued.book_id
       AND totals.id = valued.id);
$$;

CREATE OR REPLACE FUNCTION api.ledger_page(
    p_book_id VARCHAR,
    p_account_id VARCHAR
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT * FROM api.account_option_components(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'ledger'::VARCHAR,
	jsonb_build_object(
	    'page', 'ledger',
	    'book_id', p_book_id,
	    'account_id', p_account_id,
	    'book_exists', njord.book_exists(p_book_id),
	    'transaction_rules', jsonb_build_object(
		'minimum_lines', 2,
		'nonzero_amounts', TRUE,
		'unique_accounts', TRUE,
		'balance_per_asset', TRUE
	    ),
	    'account_exists', njord.posting_account_exists(
		p_book_id, p_account_id
	    ),
	    'validation_messages', CASE
		WHEN NOT njord.book_exists(p_book_id)
		    THEN jsonb_build_array('Book does not exist.')
		WHEN NOT njord.posting_account_exists(p_book_id, p_account_id)
		    THEN jsonb_build_array('Account does not exist in this book.')
		ELSE '[]'::JSONB
	    END
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
	    'amount', selected_bits.amt::TEXT,
	    'balance', (sum(selected_bits.amt) OVER (
		ORDER BY xactions.date, selected_bits.xid, selected_bits.id
	    ))::TEXT,
	    'split', line_counts.line_count > 2,
	    'split_lines', (
		SELECT jsonb_agg(
		    jsonb_build_object(
			'account', transaction_bits.acct,
			'comment', transaction_bits.comment,
			'amount', transaction_bits.amt::TEXT
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

CREATE OR REPLACE FUNCTION api.reconciliation_page(
    p_book_id VARCHAR,
    p_account_id VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT * FROM api.account_option_components(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'reconciliation'::VARCHAR,
	jsonb_build_object(
	    'page', 'reconciliation',
	    'book_id', p_book_id,
	    'account_id', p_account_id,
	    'book_exists', njord.book_exists(p_book_id),
	    'account_exists', p_account_id IS NULL
		OR njord.posting_account_exists(p_book_id, p_account_id),
	    'validation_messages', CASE
		WHEN NOT njord.book_exists(p_book_id)
		    THEN jsonb_build_array('Book does not exist.')
		WHEN p_account_id IS NOT NULL
		     AND NOT njord.posting_account_exists(p_book_id, p_account_id)
		    THEN jsonb_build_array('Account does not exist in this book.')
		ELSE '[]'::JSONB
	    END
	)
UNION ALL
    SELECT
	'reconciliation_row'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY xactions.date, selected_bits.xid, selected_bits.acct
	),
	selected_bits.xid::VARCHAR || ':' || selected_bits.acct,
	jsonb_build_object(
	    'date', CAST(xactions.date AS date),
	    'xid', selected_bits.xid,
	    'account', selected_bits.acct,
	    'asset', accts.atype,
	    'description', COALESCE(selected_bits.comment, xactions.comment),
	    'transaction_comment', xactions.comment,
	    'transfer', CASE
		WHEN line_counts.line_count = 2 THEN other_bits.acct
		ELSE NULL
	    END,
		    'amount', selected_bits.amt::TEXT,
		    'account_balance', (sum(selected_bits.amt) OVER (
			PARTITION BY selected_bits.acct
			ORDER BY xactions.date, selected_bits.xid, selected_bits.id
		    ))::TEXT,
	    'reconciled', unreconciled_postings.book_id IS NULL
	)
    FROM public.xaction_bits AS selected_bits
    JOIN public.xactions
	ON xactions.book_id = selected_bits.book_id
       AND xactions.xid = selected_bits.xid
    JOIN public.accts
	ON accts.book_id = selected_bits.book_id
       AND accts.id = selected_bits.acct
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
    LEFT JOIN public.unreconciled_postings
	ON unreconciled_postings.book_id = selected_bits.book_id
       AND unreconciled_postings.xid = selected_bits.xid
       AND unreconciled_postings.acct = selected_bits.acct
    WHERE selected_bits.book_id = p_book_id
      AND (p_account_id IS NULL OR selected_bits.acct = p_account_id);
$$;

CREATE OR REPLACE FUNCTION api.general_journal_page(p_book_id VARCHAR)
RETURNS SETOF api.page_component
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
	    'book_exists', njord.book_exists(p_book_id),
	    'validation_messages', CASE
		WHEN njord.book_exists(p_book_id) THEN '[]'::JSONB
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
		to_jsonb(journal) || jsonb_build_object(
		    'debit', journal.debit::TEXT,
		    'credit', journal.credit::TEXT
		)
    FROM public.general_journal AS journal
    WHERE journal.book_id = p_book_id;
$$;

CREATE OR REPLACE FUNCTION njord.configuration_check_payload(
    p_id TEXT,
    p_label TEXT,
    p_complete BOOLEAN,
    p_message TEXT
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
	'id', p_id,
	'label', p_label,
	'complete', p_complete,
	'message', p_message
    );
$$;

CREATE OR REPLACE FUNCTION njord.labelled_option_payload(
    p_id TEXT,
    p_label TEXT
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object('id', p_id, 'label', p_label);
$$;

CREATE OR REPLACE FUNCTION njord.report_period_configured(
    p_book_id VARCHAR,
    p_profile_kind VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
	SELECT 1
	FROM public.report_periods AS period
	WHERE period.book_id = p_book_id
	  AND period.profile_kind = p_profile_kind
    );
$$;

CREATE OR REPLACE FUNCTION njord.lock_book_reporting_asset(p_book_id VARCHAR)
RETURNS VARCHAR
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    reporting_asset VARCHAR;
BEGIN
    SELECT books.reporting_asset
    INTO reporting_asset
    FROM public.books
    WHERE books.id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    RETURN reporting_asset;
END;
$$;

-- Optional Panama settings are emitted only for ledgers whose reporting asset
-- can support the pack. The browser renders these database-owned components;
-- it does not decide jurisdiction eligibility or configuration completeness.
CREATE OR REPLACE FUNCTION api.panama_book_components(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH configuration AS (
	SELECT
	    books.id AS book_id,
	    books.name AS book_name,
	    profile.book_id IS NOT NULL AS profile_enabled,
	    profile.legal_name,
	    profile.ruc,
	    profile.verification_digit,
	    profile.legal_form,
	    profile.municipality,
	    profile.incorporated_on,
	    profile.resident_agent,
	    profile.registered_address,
	    profile.operations_notice_number,
	    profile.itbms_registered,
	    profile.conducts_lodging_activity,
	    profile.notes,
	    property_profile.book_id IS NOT NULL AS property_enabled,
	    (
		SELECT count(*)::INTEGER
		FROM public.panama_properties
		WHERE panama_properties.book_id = books.id
	    ) AS property_count,
	    njord.report_period_configured(
		books.id, 'panama_business'
	    ) AS has_period
	FROM public.books
	JOIN public.book_entity_types AS entity_types
	  ON entity_types.id = books.entity_type
	LEFT JOIN public.panama_business_profiles AS profile
	  ON profile.book_id = books.id
	LEFT JOIN public.panama_residential_property_profiles AS property_profile
	  ON property_profile.book_id = books.id
	WHERE books.id = p_book_id
	  AND entity_types.allows_business_packs
	  AND books.reporting_asset IN ('PAB', 'USD')
    )
    SELECT
	'panama_business_profile'::VARCHAR,
	12500::BIGINT,
	configuration.book_id,
	jsonb_build_object(
	    'enabled', configuration.profile_enabled,
	    'legal_name', COALESCE(
		configuration.legal_name, configuration.book_name
	    ),
	    'ruc', COALESCE(configuration.ruc, ''),
	    'verification_digit', configuration.verification_digit,
	    'legal_form', COALESCE(configuration.legal_form, 'corporation'),
	    'municipality', COALESCE(
		configuration.municipality, 'panama_district'
	    ),
	    'incorporated_on', configuration.incorporated_on,
	    'resident_agent', configuration.resident_agent,
	    'registered_address', configuration.registered_address,
	    'operations_notice_number',
		configuration.operations_notice_number,
	    'itbms_registered', COALESCE(
		configuration.itbms_registered, FALSE
	    ),
	    'conducts_lodging_activity', COALESCE(
		configuration.conducts_lodging_activity, FALSE
	    ),
	    'residential_property_enabled',
		configuration.property_enabled,
	    'property_count', configuration.property_count,
	    'notes', configuration.notes
	)
    FROM configuration
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	12600::BIGINT,
	'panama_profile'::VARCHAR,
	njord.configuration_check_payload(
	    'panama_profile',
	    'Panama business profile',
	    configuration.profile_enabled,
	    CASE WHEN configuration.profile_enabled THEN NULL
		ELSE 'Save the Panama business settings to enable its working papers.' END
	)
    FROM configuration
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	12601::BIGINT,
	'panama_period'::VARCHAR,
	njord.configuration_check_payload(
	    'panama_period',
	    'Fiscal period',
	    configuration.profile_enabled AND configuration.has_period,
	    CASE
		WHEN NOT configuration.profile_enabled THEN
		    'Save the business profile first.'
		WHEN NOT configuration.has_period THEN
		    'Add one fiscal period.'
		ELSE NULL
	    END
	)
    FROM configuration
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	12602::BIGINT,
	'panama_property'::VARCHAR,
	njord.configuration_check_payload(
	    'panama_property',
	    'Residential property extension',
	    configuration.property_enabled
		AND configuration.property_count > 0,
	    CASE
		WHEN NOT configuration.property_enabled THEN
		    'Optional; enable it only for a residential-property business.'
		WHEN configuration.property_count = 0 THEN
		    'Add a property before opening property-specific reports.'
		ELSE NULL
	    END
	)
    FROM configuration
UNION ALL
    SELECT
	'panama_legal_form_option'::VARCHAR,
	12700 + row_number() OVER (ORDER BY legal_forms.label, legal_forms.id),
	legal_forms.id,
	njord.labelled_option_payload(legal_forms.id, legal_forms.label)
    FROM public.panama_legal_forms AS legal_forms
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
	'panama_municipality_option'::VARCHAR,
	12800 + row_number() OVER (
	    ORDER BY municipalities.label, municipalities.id
	),
	municipalities.id,
	njord.labelled_option_payload(municipalities.id, municipalities.label)
    FROM public.panama_municipalities AS municipalities
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
	'panama_period_status_option'::VARCHAR,
	12900 + row_number() OVER (
	    ORDER BY period_statuses.label, period_statuses.id
	),
	period_statuses.id,
	njord.labelled_option_payload(period_statuses.id, period_statuses.label)
    FROM public.panama_period_statuses AS period_statuses
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
	'panama_fiscal_period'::VARCHAR,
	13000 + row_number() OVER (
	    ORDER BY periods.period_start DESC, periods.id
	),
	periods.id,
	jsonb_build_object(
	    'id', periods.id,
	    'period_start', periods.period_start,
	    'period_end', periods.period_end,
	    'status', periods.status,
	    'income_tax_return_due_on', periods.income_tax_return_due_on,
	    'municipal_return_due_on', periods.municipal_return_due_on,
	    'notes', periods.notes
	)
    FROM public.panama_fiscal_periods AS periods
    WHERE periods.book_id = p_book_id;
$$;

-- Taiwan settings are offered only to TWD books. SQL owns that eligibility,
-- profile readiness, and the optional manufacturing seam.
CREATE OR REPLACE FUNCTION api.taiwan_book_components(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH configuration AS (
        SELECT
            books.id AS book_id,
            books.name AS book_name,
            profile.book_id IS NOT NULL AS profile_enabled,
            profile.legal_name,
            profile.unified_business_number,
            profile.legal_form,
            profile.business_tax_frequency,
            profile.uses_uniform_invoices,
            profile.established_on,
            profile.responsible_person,
            profile.registered_address,
            profile.tax_registration_notes,
            profile.notes,
            manufacturing.book_id IS NOT NULL AS manufacturing_enabled,
            (SELECT count(*)::INTEGER FROM taiwan_inventory_items AS item
             WHERE item.book_id = books.id) AS inventory_item_count,
            njord.report_period_configured(
                books.id, 'taiwan_business'
            ) AS has_period
        FROM books
        JOIN book_entity_types AS entity_types
          ON entity_types.id = books.entity_type
        LEFT JOIN taiwan_business_profiles AS profile ON profile.book_id = books.id
        LEFT JOIN taiwan_manufacturing_profiles AS manufacturing
          ON manufacturing.book_id = books.id
        WHERE books.id = p_book_id
          AND entity_types.allows_business_packs
          AND books.reporting_asset = 'TWD'
    )
    SELECT
        'taiwan_business_profile'::VARCHAR,
        13500::BIGINT,
        configuration.book_id,
        jsonb_build_object(
            'enabled', configuration.profile_enabled,
            'legal_name', COALESCE(configuration.legal_name, configuration.book_name),
            'unified_business_number', COALESCE(configuration.unified_business_number, ''),
            'legal_form', COALESCE(configuration.legal_form, 'limited_company'),
            'business_tax_frequency', COALESCE(
                configuration.business_tax_frequency, 'bimonthly'
            ),
            'uses_uniform_invoices', COALESCE(configuration.uses_uniform_invoices, TRUE),
            'established_on', configuration.established_on,
            'responsible_person', configuration.responsible_person,
            'registered_address', configuration.registered_address,
            'tax_registration_notes', configuration.tax_registration_notes,
            'manufacturing_enabled', configuration.manufacturing_enabled,
            'inventory_item_count', configuration.inventory_item_count,
            'notes', configuration.notes
        )
    FROM configuration
UNION ALL
    SELECT
        'configuration_check'::VARCHAR,
        13600::BIGINT,
        'taiwan_profile'::VARCHAR,
        njord.configuration_check_payload(
            'taiwan_profile',
            'Taiwan business profile',
            configuration.profile_enabled,
            CASE WHEN configuration.profile_enabled THEN NULL
                ELSE 'Save the Taiwan business settings to enable its working papers.' END
        )
    FROM configuration
UNION ALL
    SELECT
        'configuration_check'::VARCHAR,
        13601::BIGINT,
        'taiwan_period'::VARCHAR,
        njord.configuration_check_payload(
            'taiwan_period',
            'Fiscal period',
            configuration.profile_enabled AND configuration.has_period,
            CASE
                WHEN NOT configuration.profile_enabled THEN 'Save the business profile first.'
                WHEN NOT configuration.has_period THEN 'Add one fiscal period.'
                ELSE NULL
            END
        )
    FROM configuration
UNION ALL
    SELECT
        'configuration_check'::VARCHAR,
        13602::BIGINT,
        'taiwan_manufacturing'::VARCHAR,
        njord.configuration_check_payload(
            'taiwan_manufacturing',
            'Injection-moulding manufacturing extension',
            configuration.manufacturing_enabled
                AND configuration.inventory_item_count > 0,
            CASE
                WHEN NOT configuration.manufacturing_enabled THEN
                    'Optional; enable it for production, stock, BOM, machine, and mould schedules.'
                WHEN configuration.inventory_item_count = 0 THEN
                    'Record inventory items before relying on manufacturing schedules.'
                ELSE NULL
            END
        )
    FROM configuration
UNION ALL
    SELECT
        'taiwan_legal_form_option'::VARCHAR,
        13700 + row_number() OVER (ORDER BY form.label, form.id),
        form.id,
        njord.labelled_option_payload(form.id, form.label)
    FROM taiwan_legal_forms AS form
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
        'taiwan_tax_frequency_option'::VARCHAR,
        13800 + row_number() OVER (ORDER BY frequency.label, frequency.id),
        frequency.id,
        njord.labelled_option_payload(frequency.id, frequency.label)
    FROM taiwan_business_tax_frequencies AS frequency
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
        'taiwan_period_status_option'::VARCHAR,
        13900 + row_number() OVER (ORDER BY status.label, status.id),
        status.id,
        njord.labelled_option_payload(status.id, status.label)
    FROM taiwan_period_statuses AS status
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
        'taiwan_fiscal_period'::VARCHAR,
        14000 + row_number() OVER (ORDER BY period.period_start DESC, period.id),
        period.id,
        jsonb_build_object(
            'id', period.id,
            'period_start', period.period_start,
            'period_end', period.period_end,
            'status', period.status,
            'annual_income_tax_due_on', period.annual_income_tax_due_on,
            'provisional_income_tax_due_on', period.provisional_income_tax_due_on,
            'undistributed_earnings_due_on', period.undistributed_earnings_due_on,
            'notes', period.notes
        )
    FROM taiwan_fiscal_periods AS period
    WHERE period.book_id = p_book_id;
$$;

-- The Book workspace is the only UI surface which owns book identity and
-- jurisdiction-pack configuration.  It deliberately exposes the reporting asset as
-- read-only: changing the denomination of an established ledger is a
-- different operation from changing its display settings.
CREATE OR REPLACE FUNCTION api.book_page(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH configuration AS (
	SELECT
	    books.id AS book_id,
	    books.name AS book_name,
	    books.reporting_asset,
	    books.entity_type,
	    presentation.text('entity.' || entity_types.id) AS entity_type_label,
	    books.archived_at,
	    books.reporting_asset = 'GBP'
		AND books.entity_type = 'company' AS uk_available,
	    profiles.book_id IS NOT NULL AS profile_enabled,
	    profiles.legal_name,
	    profiles.company_number,
	    profiles.legal_form,
	    profiles.accounting_framework,
	    profiles.utr,
	    profiles.vat_registration_number,
	    profiles.vat_scheme,
	    profiles.registered_office,
	    profiles.incorporated_on,
	    profiles.notes,
	    njord.report_period_configured(
		books.id, 'uk_company'
	    ) AS has_period,
	    EXISTS (
		SELECT 1
		FROM public.uk_company_control_accounts
		WHERE uk_company_control_accounts.book_id = books.id
	    ) AS has_vat_control,
	    njord.standard_account_hierarchy_complete(books.id)
		AS has_standard_account_hierarchy,
	    njord.uk_company_configuration_complete(books.id)
		AS configuration_complete
	FROM public.books
	JOIN public.book_entity_types AS entity_types
	  ON entity_types.id = books.entity_type
	LEFT JOIN public.uk_company_profiles AS profiles
	  ON profiles.book_id = books.id
	WHERE books.id = p_book_id
    )
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'book'::VARCHAR,
	jsonb_build_object(
	    'page', 'book',
	    'book_id', p_book_id,
	    'book_exists', configuration.book_id IS NOT NULL,
	    'archived', configuration.archived_at IS NOT NULL,
	    'configuration_status', CASE
		WHEN NOT COALESCE(configuration.profile_enabled, FALSE)
		    THEN 'ordinary'
		WHEN configuration.configuration_complete THEN 'complete'
		ELSE 'incomplete'
	    END,
	    'validation_messages', CASE
		WHEN configuration.book_id IS NULL THEN
		    jsonb_build_array('Book does not exist.')
		ELSE to_jsonb(array_remove(ARRAY[
		    CASE WHEN configuration.profile_enabled
			      AND NOT configuration.has_standard_account_hierarchy THEN
			'Save company settings to create the standard account hierarchy.'
		    END,
		    CASE WHEN configuration.profile_enabled
			      AND NOT configuration.has_period THEN
			'Add at least one accounting period.'
		    END,
		    CASE WHEN configuration.profile_enabled
			      AND configuration.vat_scheme <> 'not_registered'
			      AND NOT configuration.has_vat_control THEN
			'Select a posting liability account for VAT control.'
		    END
		]::TEXT[], NULL))
	    END
	)
    FROM (VALUES (TRUE)) AS singleton(only_row)
    LEFT JOIN configuration ON singleton.only_row
UNION ALL
    SELECT
	'book_identity'::VARCHAR,
	9100::BIGINT,
	configuration.book_id,
	jsonb_build_object(
	    'id', configuration.book_id,
	    'name', configuration.book_name,
	    'reporting_asset', configuration.reporting_asset,
	    'entity_type', configuration.entity_type,
	    'entity_type_label', configuration.entity_type_label,
	    'archived_at', configuration.archived_at
	)
    FROM configuration
UNION ALL
    SELECT
	'book_entity_type_option'::VARCHAR,
	9110 + row_number() OVER (
	    ORDER BY presentation.text('entity.' || book_entity_types.id)
	),
	book_entity_types.id,
	njord.labelled_option_payload(
	    book_entity_types.id,
	    presentation.text('entity.' || book_entity_types.id)
	)
    FROM public.book_entity_types
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
	'reporting_currency'::VARCHAR,
	20000 + row_number() OVER (
	    ORDER BY history.effective_from DESC
	),
	history.effective_from::TEXT,
	jsonb_build_object(
	    'effective_from', history.effective_from,
	    'asset', history.asset,
	    'current', history.asset = configuration.reporting_asset
		AND history.effective_from = (
		    SELECT max(current_history.effective_from)
		    FROM public.book_reporting_currencies AS current_history
		    WHERE current_history.book_id = history.book_id
		      AND current_history.effective_from <= CURRENT_DATE
		)
	)
    FROM public.book_reporting_currencies AS history
    JOIN configuration ON configuration.book_id = history.book_id
UNION ALL
    SELECT
	'book_asset_option'::VARCHAR,
	30000 + row_number() OVER (ORDER BY asset.id),
	asset.id,
	jsonb_build_object('id', asset.id)
    FROM public.asset
    WHERE EXISTS (SELECT 1 FROM configuration)
UNION ALL
    SELECT
	'company_profile'::VARCHAR,
	9200::BIGINT,
	configuration.book_id,
	jsonb_build_object(
	    'enabled', configuration.profile_enabled,
	    'legal_name', COALESCE(
		configuration.legal_name, configuration.book_name
	    ),
	    'company_number', configuration.company_number,
	    'legal_form', COALESCE(
		configuration.legal_form, 'private_limited_shares'
	    ),
	    'accounting_framework', COALESCE(
		configuration.accounting_framework, 'frs105'
	    ),
	    'utr', configuration.utr,
	    'vat_registration_number',
		configuration.vat_registration_number,
	    'vat_scheme', COALESCE(
		configuration.vat_scheme, 'not_registered'
	    ),
	    'registered_office', configuration.registered_office,
	    'incorporated_on', configuration.incorporated_on,
	    'notes', configuration.notes
	)
    FROM configuration
    WHERE configuration.uk_available
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	9300::BIGINT,
	'account_hierarchy'::VARCHAR,
	njord.configuration_check_payload(
	    'account_hierarchy',
	    'Account hierarchy',
	    configuration.has_standard_account_hierarchy,
	    CASE
		WHEN configuration.has_standard_account_hierarchy THEN NULL
		WHEN configuration.profile_enabled THEN
		    'Save company settings to create the standard account hierarchy.'
		ELSE
		    'The standard account hierarchy will be created when company settings are saved.'
	    END
	)
    FROM configuration
    WHERE configuration.uk_available
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	9301::BIGINT,
	'profile'::VARCHAR,
	njord.configuration_check_payload(
	    'profile',
	    'Company profile',
	    configuration.profile_enabled,
	    CASE WHEN configuration.profile_enabled THEN NULL
		ELSE 'Enable UK company reporting to add a company profile.' END
	)
    FROM configuration
    WHERE configuration.uk_available
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	9302::BIGINT,
	'period'::VARCHAR,
	njord.configuration_check_payload(
	    'period',
	    'Accounting period',
	    configuration.profile_enabled AND configuration.has_period,
	    CASE
		WHEN NOT configuration.profile_enabled THEN
		    'Enable UK company reporting first.'
		WHEN NOT configuration.has_period THEN
		    'Add at least one accounting period.'
		ELSE NULL
	    END
	)
    FROM configuration
    WHERE configuration.uk_available
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	9303::BIGINT,
	'vat_control'::VARCHAR,
	njord.configuration_check_payload(
	    'vat_control',
	    'VAT control account',
	    configuration.profile_enabled AND (
		configuration.vat_scheme = 'not_registered'
		OR configuration.has_vat_control
	    ),
	    CASE
		WHEN NOT configuration.profile_enabled THEN
		    'Enable UK company reporting first.'
		WHEN configuration.vat_scheme = 'not_registered' THEN
		    'Not required while the company is not VAT registered.'
		WHEN NOT configuration.has_vat_control THEN
		    'Select a posting liability account for VAT control.'
		ELSE NULL
	    END
	)
    FROM configuration
    WHERE configuration.uk_available
UNION ALL
    SELECT
	'legal_form_option'::VARCHAR,
	9400 + row_number() OVER (
	    ORDER BY uk_company_legal_forms.label, uk_company_legal_forms.id
	),
	uk_company_legal_forms.id,
	njord.labelled_option_payload(
	    uk_company_legal_forms.id, uk_company_legal_forms.label
	)
    FROM public.uk_company_legal_forms
    WHERE EXISTS (
	SELECT 1 FROM configuration WHERE uk_available
    )
UNION ALL
    SELECT
	'accounting_framework_option'::VARCHAR,
	9500 + row_number() OVER (
	    ORDER BY uk_accounting_frameworks.label,
		uk_accounting_frameworks.id
	),
	uk_accounting_frameworks.id,
	njord.labelled_option_payload(
	    uk_accounting_frameworks.id, uk_accounting_frameworks.label
	)
    FROM public.uk_accounting_frameworks
    WHERE EXISTS (
	SELECT 1 FROM configuration WHERE uk_available
    )
UNION ALL
    SELECT
	'vat_scheme_option'::VARCHAR,
	9600 + row_number() OVER (
	    ORDER BY uk_vat_schemes.label, uk_vat_schemes.id
	),
	uk_vat_schemes.id,
	njord.labelled_option_payload(
	    uk_vat_schemes.id, uk_vat_schemes.label
	)
    FROM public.uk_vat_schemes
    WHERE EXISTS (
	SELECT 1 FROM configuration WHERE uk_available
    )
UNION ALL
    SELECT
	'period_status_option'::VARCHAR,
	9700 + row_number() OVER (
	    ORDER BY uk_period_statuses.label, uk_period_statuses.id
	),
	uk_period_statuses.id,
	njord.labelled_option_payload(
	    uk_period_statuses.id, uk_period_statuses.label
	)
    FROM public.uk_period_statuses
    WHERE EXISTS (
	SELECT 1 FROM configuration WHERE uk_available
    )
UNION ALL
    SELECT
	'accounting_period'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY uk_accounting_periods.period_start DESC,
		uk_accounting_periods.id
	),
	uk_accounting_periods.id,
	jsonb_build_object(
	    'id', uk_accounting_periods.id,
	    'period_start', uk_accounting_periods.period_start,
	    'period_end', uk_accounting_periods.period_end,
	    'status', uk_accounting_periods.status,
	    'accounts_due_on', uk_accounting_periods.accounts_due_on,
	    'corporation_tax_due_on',
		uk_accounting_periods.corporation_tax_due_on,
	    'accounts_filed_on', uk_accounting_periods.accounts_filed_on,
	    'ct600_filed_on', uk_accounting_periods.ct600_filed_on,
	    'notes', uk_accounting_periods.notes
	)
    FROM public.uk_accounting_periods
    WHERE uk_accounting_periods.book_id = p_book_id
UNION ALL
    SELECT
	'vat_control_account_option'::VARCHAR,
	11000 + row_number() OVER (
	    ORDER BY report_account_tree.sort_path
	),
	report_account_tree.id,
	jsonb_build_object(
	    'id', report_account_tree.id,
	    'name', report_account_tree.name,
	    'path', report_account_tree.display_path,
	    'selected', EXISTS (
		SELECT 1
		FROM public.uk_company_control_accounts
		WHERE uk_company_control_accounts.book_id = p_book_id
		  AND uk_company_control_accounts.vat_control_acct =
			report_account_tree.id
	    )
	)
    FROM public.report_account_tree
    JOIN public.books ON books.id = report_account_tree.book_id
    WHERE report_account_tree.book_id = p_book_id
      AND report_account_tree.type = 'L'
      AND NOT report_account_tree.placeholder
      AND report_account_tree.atype = books.reporting_asset
UNION ALL
    SELECT * FROM api.panama_book_components(p_book_id)
UNION ALL
    SELECT * FROM api.taiwan_book_components(p_book_id);
$$;

-- Book identity is explicit.  Entity classification may change, but an active
-- jurisdiction profile prevents changing the book back to a household.
CREATE OR REPLACE FUNCTION api.update_book_settings(
    p_book_id VARCHAR,
    p_name VARCHAR,
    p_entity_type VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_name VARCHAR;
    normalized_entity_type VARCHAR;
BEGIN
    normalized_name := NULLIF(btrim(p_name), '');
    normalized_entity_type := NULLIF(btrim(p_entity_type), '');

    IF normalized_name IS NULL THEN
	RAISE EXCEPTION 'book name is required'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_NAME_REQUIRED';
    END IF;

    IF normalized_entity_type IS NOT NULL AND NOT EXISTS (
	SELECT 1
	FROM public.book_entity_types
	WHERE book_entity_types.id = normalized_entity_type
    ) THEN
	RAISE EXCEPTION 'book entity type does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_ENTITY_TYPE_NOT_FOUND';
    END IF;

    IF normalized_entity_type = 'household' AND EXISTS (
	SELECT 1 FROM njord.book_jurisdiction_profiles WHERE book_id = p_book_id
    ) THEN
	RAISE EXCEPTION 'remove the active business pack before choosing household'
	    USING ERRCODE = 'P0001', DETAIL = 'ACTIVE_BUSINESS_PACK';
    END IF;

    UPDATE public.books
    SET name = normalized_name,
	entity_type = COALESCE(normalized_entity_type, books.entity_type)
    WHERE books.id = p_book_id;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

-- Empty books can replace their initial denomination.  Once a posting exists,
-- currency changes are effective-dated and never redenominate accounts or
-- postings.  Dated report functions resolve the applicable row.
CREATE OR REPLACE FUNCTION api.set_book_reporting_currency(
    p_book_id VARCHAR,
    p_asset VARCHAR,
    p_effective_from DATE DEFAULT CURRENT_DATE
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_asset VARCHAR;
    old_asset VARCHAR;
    current_asset VARCHAR;
    has_postings BOOLEAN;
BEGIN
    normalized_asset := NULLIF(btrim(p_asset), '');

    IF normalized_asset IS NULL OR NOT EXISTS (
	SELECT 1 FROM public.asset WHERE asset.id = normalized_asset
    ) THEN
	RAISE EXCEPTION 'reporting asset does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'REPORTING_ASSET_NOT_FOUND';
    END IF;

    SELECT books.reporting_asset,
	EXISTS (SELECT 1 FROM public.xactions WHERE xactions.book_id = books.id)
    INTO old_asset, has_postings
    FROM public.books
    WHERE books.id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    IF NOT has_postings THEN
	DELETE FROM public.book_reporting_currencies
	WHERE book_id = p_book_id;

	UPDATE public.accts
	SET atype = normalized_asset
	WHERE book_id = p_book_id
	  AND atype = old_asset;

	UPDATE public.books
	SET reporting_asset = normalized_asset
	WHERE id = p_book_id;

	INSERT INTO public.book_reporting_currencies (
	    book_id, effective_from, asset
	) VALUES (
	    p_book_id, '-infinity'::DATE, normalized_asset
	);
    ELSE
	IF p_effective_from IS NULL THEN
	    RAISE EXCEPTION 'effective date is required for an active book'
			USING ERRCODE = 'P0001', DETAIL = 'EFFECTIVE_DATE_REQUIRED';
	END IF;
	IF NOT isfinite(p_effective_from) THEN
	    RAISE EXCEPTION 'effective date must be finite'
		USING ERRCODE = 'P0001', DETAIL = 'INVALID_EFFECTIVE_DATE';
	END IF;
	IF p_effective_from > CURRENT_DATE THEN
	    RAISE EXCEPTION 'reporting currency cannot start in the future'
		USING ERRCODE = 'P0001', DETAIL = 'FUTURE_REPORTING_CURRENCY';
	END IF;

	INSERT INTO public.book_reporting_currencies (
	    book_id, effective_from, asset
	) VALUES (
	    p_book_id, p_effective_from, normalized_asset
	)
	ON CONFLICT (book_id, effective_from)
	DO UPDATE SET asset = EXCLUDED.asset;

	current_asset := njord.book_reporting_asset_at(p_book_id, CURRENT_DATE);
	UPDATE public.books
	SET reporting_asset = current_asset
	WHERE id = p_book_id;
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

CREATE OR REPLACE FUNCTION api.archive_book(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    UPDATE public.books
    SET archived_at = COALESCE(archived_at, clock_timestamp())
    WHERE id = p_book_id;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

CREATE OR REPLACE FUNCTION api.restore_book(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    UPDATE public.books
    SET archived_at = NULL
    WHERE id = p_book_id;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

-- Enable or update a UK company in one statement-level transaction.  The UK
-- report catalogue requires a profile, accounting period and any applicable
-- VAT control mapping, so those parts must never be committed independently.
CREATE OR REPLACE FUNCTION api.configure_uk_company(
    p_book_id VARCHAR,
    p_legal_name VARCHAR,
    p_legal_form VARCHAR,
    p_accounting_framework VARCHAR,
    p_vat_scheme VARCHAR,
    p_period_id VARCHAR,
    p_period_start DATE,
    p_period_end DATE,
    p_vat_control_acct VARCHAR DEFAULT NULL,
    p_company_number VARCHAR DEFAULT NULL,
    p_utr VARCHAR DEFAULT NULL,
    p_vat_registration_number VARCHAR DEFAULT NULL,
    p_registered_office VARCHAR DEFAULT NULL,
    p_incorporated_on DATE DEFAULT NULL,
    p_notes VARCHAR DEFAULT NULL,
    p_period_status VARCHAR DEFAULT 'open',
    p_accounts_due_on DATE DEFAULT NULL,
    p_corporation_tax_due_on DATE DEFAULT NULL,
    p_accounts_filed_on DATE DEFAULT NULL,
    p_ct600_filed_on DATE DEFAULT NULL,
    p_period_notes VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_legal_name VARCHAR := NULLIF(btrim(p_legal_name), '');
    normalized_legal_form VARCHAR := NULLIF(btrim(p_legal_form), '');
    normalized_framework VARCHAR := NULLIF(
	btrim(p_accounting_framework), ''
    );
    normalized_vat_scheme VARCHAR := NULLIF(btrim(p_vat_scheme), '');
    normalized_period_id VARCHAR := NULLIF(btrim(p_period_id), '');
    normalized_period_status VARCHAR := COALESCE(
	NULLIF(btrim(p_period_status), ''), 'open'
    );
    normalized_control VARCHAR := NULLIF(btrim(p_vat_control_acct), '');
    reporting_asset VARCHAR;
    selected_control VARCHAR;
    candidate_id VARCHAR;
    candidate_suffix INTEGER;
BEGIN
    reporting_asset := njord.lock_book_reporting_asset(p_book_id);

    IF reporting_asset <> 'GBP' THEN
	RAISE EXCEPTION 'UK company configuration requires a GBP book'
	    USING ERRCODE = 'P0001', DETAIL = 'UK_COMPANY_REQUIRES_GBP';
    END IF;

    -- Calling this company-specific mutation is an explicit entity choice;
    -- it is not an inference from the book name or reporting currency.
    UPDATE public.books SET entity_type = 'company'
    WHERE id = p_book_id AND entity_type = 'household';

    IF normalized_legal_name IS NULL THEN
	RAISE EXCEPTION 'company legal name is required'
	    USING ERRCODE = 'P0001', DETAIL = 'COMPANY_LEGAL_NAME_REQUIRED';
    END IF;

    IF normalized_legal_form IS NULL OR NOT EXISTS (
	SELECT 1
	FROM public.uk_company_legal_forms
	WHERE uk_company_legal_forms.id = normalized_legal_form
    ) THEN
	RAISE EXCEPTION 'company legal form does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'LEGAL_FORM_NOT_FOUND';
    END IF;

    IF normalized_framework IS NULL OR NOT EXISTS (
	SELECT 1
	FROM public.uk_accounting_frameworks
	WHERE uk_accounting_frameworks.id = normalized_framework
    ) THEN
	RAISE EXCEPTION 'accounting framework does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNTING_FRAMEWORK_NOT_FOUND';
    END IF;

    IF normalized_vat_scheme IS NULL OR NOT EXISTS (
	SELECT 1
	FROM public.uk_vat_schemes
	WHERE uk_vat_schemes.id = normalized_vat_scheme
    ) THEN
	RAISE EXCEPTION 'VAT scheme does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'VAT_SCHEME_NOT_FOUND';
    END IF;

    IF normalized_period_id IS NULL THEN
	RAISE EXCEPTION 'accounting period id is required'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNTING_PERIOD_ID_REQUIRED';
    END IF;

    IF p_period_start IS NULL OR p_period_end IS NULL THEN
	RAISE EXCEPTION 'accounting period dates are required'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNTING_PERIOD_DATES_REQUIRED';
    END IF;

    IF p_period_start > p_period_end THEN
	RAISE EXCEPTION 'accounting period starts after it ends'
	    USING ERRCODE = 'P0001', DETAIL = 'INVALID_ACCOUNTING_PERIOD';
    END IF;

    IF NOT EXISTS (
	SELECT 1
	FROM public.uk_period_statuses
	WHERE uk_period_statuses.id = normalized_period_status
    ) THEN
	RAISE EXCEPTION 'accounting period status does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'PERIOD_STATUS_NOT_FOUND';
    END IF;

    -- Existing books may have been created without a chart.  The shared
    -- bootstrap reuses compatible rows and rejects occupied hierarchy slots.
    PERFORM njord.ensure_standard_accounts(p_book_id);

    IF normalized_vat_scheme <> 'not_registered' THEN
	IF normalized_control IS NOT NULL THEN
	    SELECT accts.id
	    INTO selected_control
	    FROM public.accts
	    WHERE accts.book_id = p_book_id
	      AND accts.id = normalized_control
	      AND accts.type = 'L'
	      AND NOT accts.placeholder
	      AND accts.atype = reporting_asset;

	    IF NOT FOUND THEN
		RAISE EXCEPTION 'VAT control account is not a posting GBP liability'
		    USING ERRCODE = 'P0001',
			  DETAIL = 'VAT_CONTROL_ACCOUNT_INVALID';
	    END IF;
	ELSE
	    -- Reuse the current mapping first, then a conventional existing VAT
	    -- Control account.  A fresh standard book has no posting liability,
	    -- so create one beneath its Liabilities root when necessary.
	    SELECT control.vat_control_acct
	    INTO selected_control
	    FROM public.uk_company_control_accounts AS control
	    JOIN public.accts
	      ON accts.book_id = control.book_id
	     AND accts.id = control.vat_control_acct
	    WHERE control.book_id = p_book_id
	      AND accts.type = 'L'
	      AND NOT accts.placeholder
	      AND accts.atype = reporting_asset;

	    IF NOT FOUND THEN
		SELECT accts.id
		INTO selected_control
		FROM public.accts
		WHERE accts.book_id = p_book_id
		  AND accts.type = 'L'
		  AND NOT accts.placeholder
		  AND accts.atype = reporting_asset
		  AND (
		    lower(accts.id) = 'vat control'
		    OR lower(accts.name) = 'vat control'
		  )
		ORDER BY (accts.id = 'VAT Control') DESC, accts.id
		LIMIT 1;
	    END IF;

	    IF selected_control IS NULL THEN
		candidate_id := 'VAT Control';
		candidate_suffix := 2;
		WHILE EXISTS (
		    SELECT 1 FROM public.accts
		    WHERE accts.book_id = p_book_id
		      AND accts.id = candidate_id
		) LOOP
		    candidate_id := 'VAT Control ' || candidate_suffix;
		    candidate_suffix := candidate_suffix + 1;
		END LOOP;

		INSERT INTO public.accts (
		    book_id, id, name, type, atype, parent_id,
		    account_kind, placeholder
		) VALUES (
		    p_book_id, candidate_id, 'VAT Control', 'L',
		    reporting_asset, 'Liabilities', 'posting', FALSE
		);
		selected_control := candidate_id;
	    END IF;
	END IF;
    END IF;

    INSERT INTO public.uk_company_profiles (
	book_id, legal_name, company_number, legal_form,
	accounting_framework, utr, vat_registration_number, vat_scheme,
	registered_office, incorporated_on, notes
    ) VALUES (
	p_book_id,
	normalized_legal_name,
	NULLIF(btrim(p_company_number), ''),
	normalized_legal_form,
	normalized_framework,
	NULLIF(btrim(p_utr), ''),
	NULLIF(btrim(p_vat_registration_number), ''),
	normalized_vat_scheme,
	NULLIF(btrim(p_registered_office), ''),
	p_incorporated_on,
	NULLIF(btrim(p_notes), '')
    )
    ON CONFLICT (book_id) DO UPDATE SET
	legal_name = EXCLUDED.legal_name,
	company_number = EXCLUDED.company_number,
	legal_form = EXCLUDED.legal_form,
	accounting_framework = EXCLUDED.accounting_framework,
	utr = EXCLUDED.utr,
	vat_registration_number = EXCLUDED.vat_registration_number,
	vat_scheme = EXCLUDED.vat_scheme,
	registered_office = EXCLUDED.registered_office,
	incorporated_on = EXCLUDED.incorporated_on,
	notes = EXCLUDED.notes;

    INSERT INTO public.uk_accounting_periods (
	book_id, id, period_start, period_end, status, accounts_due_on,
	corporation_tax_due_on, accounts_filed_on, ct600_filed_on, notes
    ) VALUES (
	p_book_id,
	normalized_period_id,
	p_period_start,
	p_period_end,
	normalized_period_status,
	p_accounts_due_on,
	p_corporation_tax_due_on,
	p_accounts_filed_on,
	p_ct600_filed_on,
	NULLIF(btrim(p_period_notes), '')
    )
    ON CONFLICT (book_id, id) DO UPDATE SET
	period_start = EXCLUDED.period_start,
	period_end = EXCLUDED.period_end,
	status = EXCLUDED.status,
	accounts_due_on = EXCLUDED.accounts_due_on,
	corporation_tax_due_on = EXCLUDED.corporation_tax_due_on,
	accounts_filed_on = EXCLUDED.accounts_filed_on,
	ct600_filed_on = EXCLUDED.ct600_filed_on,
	notes = EXCLUDED.notes;

    IF normalized_vat_scheme = 'not_registered' THEN
	DELETE FROM public.uk_company_control_accounts
	WHERE uk_company_control_accounts.book_id = p_book_id;
    ELSE
	INSERT INTO public.uk_company_control_accounts (
	    book_id, vat_control_acct
	) VALUES (
	    p_book_id, selected_control
	)
	ON CONFLICT (book_id) DO UPDATE SET
	    vat_control_acct = EXCLUDED.vat_control_acct;
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

-- Configure the small bookkeeping seam for a Panamanian business. The RPC
-- stores identity and one explicit fiscal period, creates only the ordinary
-- account roots, and optionally enables the residential-property data model.
-- It does not infer filing obligations or calculate a return.
CREATE OR REPLACE FUNCTION api.configure_panama_business(
    p_book_id VARCHAR,
    p_legal_name VARCHAR,
    p_ruc VARCHAR,
    p_legal_form VARCHAR,
    p_municipality VARCHAR,
    p_period_id VARCHAR,
    p_period_start DATE,
    p_period_end DATE,
    p_verification_digit VARCHAR DEFAULT NULL,
    p_incorporated_on DATE DEFAULT NULL,
    p_resident_agent VARCHAR DEFAULT NULL,
    p_registered_address VARCHAR DEFAULT NULL,
    p_operations_notice_number VARCHAR DEFAULT NULL,
    p_itbms_registered BOOLEAN DEFAULT FALSE,
    p_conducts_lodging_activity BOOLEAN DEFAULT FALSE,
    p_enable_residential_property BOOLEAN DEFAULT FALSE,
    p_notes VARCHAR DEFAULT NULL,
    p_period_status VARCHAR DEFAULT 'open',
    p_income_tax_return_due_on DATE DEFAULT NULL,
    p_municipal_return_due_on DATE DEFAULT NULL,
    p_period_notes VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_legal_name VARCHAR := NULLIF(btrim(p_legal_name), '');
    normalized_ruc VARCHAR := NULLIF(btrim(p_ruc), '');
    normalized_legal_form VARCHAR := NULLIF(btrim(p_legal_form), '');
    normalized_municipality VARCHAR := NULLIF(btrim(p_municipality), '');
    normalized_period_id VARCHAR := NULLIF(btrim(p_period_id), '');
    normalized_period_status VARCHAR := COALESCE(
	NULLIF(btrim(p_period_status), ''), 'open'
    );
    reporting_asset VARCHAR;
BEGIN
    reporting_asset := njord.lock_book_reporting_asset(p_book_id);

    IF reporting_asset NOT IN ('PAB', 'USD') THEN
	RAISE EXCEPTION 'Panama business configuration requires a PAB or USD book'
	    USING ERRCODE = 'P0001',
		  DETAIL = 'PANAMA_BUSINESS_REQUIRES_PAB_OR_USD';
    END IF;

    UPDATE public.books
    SET entity_type = CASE
	WHEN normalized_legal_form = 'sole_proprietor' THEN 'sole_trader'
	ELSE 'company'
    END
    WHERE id = p_book_id AND entity_type = 'household';

    IF normalized_legal_name IS NULL THEN
	RAISE EXCEPTION 'business legal name is required'
	    USING ERRCODE = 'P0001', DETAIL = 'BUSINESS_LEGAL_NAME_REQUIRED';
    END IF;

    IF normalized_ruc IS NULL THEN
	RAISE EXCEPTION 'RUC is required'
	    USING ERRCODE = 'P0001', DETAIL = 'PANAMA_RUC_REQUIRED';
    END IF;

    IF normalized_legal_form IS NULL OR NOT EXISTS (
	SELECT 1 FROM public.panama_legal_forms
	WHERE panama_legal_forms.id = normalized_legal_form
    ) THEN
	RAISE EXCEPTION 'Panama legal form does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'PANAMA_LEGAL_FORM_NOT_FOUND';
    END IF;

    IF normalized_municipality IS NULL OR NOT EXISTS (
	SELECT 1 FROM public.panama_municipalities
	WHERE panama_municipalities.id = normalized_municipality
    ) THEN
	RAISE EXCEPTION 'Panama municipality does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'PANAMA_MUNICIPALITY_NOT_FOUND';
    END IF;

    IF normalized_period_id IS NULL THEN
	RAISE EXCEPTION 'fiscal period id is required'
	    USING ERRCODE = 'P0001', DETAIL = 'FISCAL_PERIOD_ID_REQUIRED';
    END IF;

    IF p_period_start IS NULL OR p_period_end IS NULL THEN
	RAISE EXCEPTION 'fiscal period dates are required'
	    USING ERRCODE = 'P0001', DETAIL = 'FISCAL_PERIOD_DATES_REQUIRED';
    END IF;

    IF p_period_start > p_period_end THEN
	RAISE EXCEPTION 'fiscal period starts after it ends'
	    USING ERRCODE = 'P0001', DETAIL = 'INVALID_FISCAL_PERIOD';
    END IF;

    IF NOT EXISTS (
	SELECT 1 FROM public.panama_period_statuses
	WHERE panama_period_statuses.id = normalized_period_status
    ) THEN
	RAISE EXCEPTION 'fiscal period status does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'PERIOD_STATUS_NOT_FOUND';
    END IF;

    PERFORM njord.ensure_standard_accounts(p_book_id, FALSE);

    INSERT INTO public.panama_business_profiles (
	book_id, legal_name, ruc, verification_digit, legal_form,
	municipality, default_tax_policy_id, incorporated_on,
	resident_agent, registered_address, operations_notice_number,
	itbms_registered, conducts_lodging_activity, notes
    ) VALUES (
	p_book_id, normalized_legal_name, normalized_ruc,
	NULLIF(btrim(p_verification_digit), ''), normalized_legal_form,
	normalized_municipality, 'current_2026', p_incorporated_on,
	NULLIF(btrim(p_resident_agent), ''),
	NULLIF(btrim(p_registered_address), ''),
	NULLIF(btrim(p_operations_notice_number), ''),
	COALESCE(p_itbms_registered, FALSE),
	COALESCE(p_conducts_lodging_activity, FALSE),
	NULLIF(btrim(p_notes), '')
    )
    ON CONFLICT (book_id) DO UPDATE SET
	legal_name = EXCLUDED.legal_name,
	ruc = EXCLUDED.ruc,
	verification_digit = EXCLUDED.verification_digit,
	legal_form = EXCLUDED.legal_form,
	municipality = EXCLUDED.municipality,
	incorporated_on = EXCLUDED.incorporated_on,
	resident_agent = EXCLUDED.resident_agent,
	registered_address = EXCLUDED.registered_address,
	operations_notice_number = EXCLUDED.operations_notice_number,
	itbms_registered = EXCLUDED.itbms_registered,
	conducts_lodging_activity = EXCLUDED.conducts_lodging_activity,
	notes = EXCLUDED.notes;

    INSERT INTO public.panama_fiscal_periods (
	book_id, id, period_start, period_end, status, tax_policy_id,
	income_tax_return_due_on, municipal_return_due_on, notes
    ) VALUES (
	p_book_id, normalized_period_id, p_period_start, p_period_end,
	normalized_period_status, 'current_2026',
	p_income_tax_return_due_on, p_municipal_return_due_on,
	NULLIF(btrim(p_period_notes), '')
    )
    ON CONFLICT (book_id, id) DO UPDATE SET
	period_start = EXCLUDED.period_start,
	period_end = EXCLUDED.period_end,
	status = EXCLUDED.status,
	tax_policy_id = EXCLUDED.tax_policy_id,
	income_tax_return_due_on = EXCLUDED.income_tax_return_due_on,
	municipal_return_due_on = EXCLUDED.municipal_return_due_on,
	notes = EXCLUDED.notes;

    IF COALESCE(p_enable_residential_property, FALSE) THEN
	INSERT INTO public.panama_residential_property_profiles (book_id)
	VALUES (p_book_id)
	ON CONFLICT (book_id) DO NOTHING;
    ELSE
	BEGIN
	    DELETE FROM public.panama_residential_property_profiles
	    WHERE book_id = p_book_id;
	EXCEPTION WHEN foreign_key_violation THEN
	    RAISE EXCEPTION 'residential-property records must be removed before disabling the extension'
		USING ERRCODE = 'P0001',
		      DETAIL = 'PANAMA_PROPERTY_EXTENSION_HAS_DATA';
	END;
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

-- Configure a compact Taiwan bookkeeping profile and an explicit fiscal
-- period. The optional manufacturing marker unlocks production schedules; it
-- does not invent inventory items, BOMs, tax obligations, or return figures.
CREATE OR REPLACE FUNCTION api.configure_taiwan_business(
    p_book_id VARCHAR,
    p_legal_name VARCHAR,
    p_unified_business_number VARCHAR,
    p_legal_form VARCHAR,
    p_business_tax_frequency VARCHAR,
    p_period_id VARCHAR,
    p_period_start DATE,
    p_period_end DATE,
    p_uses_uniform_invoices BOOLEAN DEFAULT TRUE,
    p_enable_manufacturing BOOLEAN DEFAULT FALSE,
    p_established_on DATE DEFAULT NULL,
    p_responsible_person VARCHAR DEFAULT NULL,
    p_registered_address VARCHAR DEFAULT NULL,
    p_tax_registration_notes VARCHAR DEFAULT NULL,
    p_notes VARCHAR DEFAULT NULL,
    p_period_status VARCHAR DEFAULT 'open',
    p_annual_income_tax_due_on DATE DEFAULT NULL,
    p_provisional_income_tax_due_on DATE DEFAULT NULL,
    p_undistributed_earnings_due_on DATE DEFAULT NULL,
    p_period_notes VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_legal_name VARCHAR := NULLIF(btrim(p_legal_name), '');
    normalized_ubn VARCHAR := NULLIF(btrim(p_unified_business_number), '');
    normalized_legal_form VARCHAR := NULLIF(btrim(p_legal_form), '');
    normalized_frequency VARCHAR := NULLIF(btrim(p_business_tax_frequency), '');
    normalized_period_id VARCHAR := NULLIF(btrim(p_period_id), '');
    normalized_period_status VARCHAR := COALESCE(
        NULLIF(btrim(p_period_status), ''), 'open'
    );
    reporting_asset VARCHAR;
BEGIN
    reporting_asset := njord.lock_book_reporting_asset(p_book_id);
    IF reporting_asset <> 'TWD' THEN
        RAISE EXCEPTION 'Taiwan business configuration requires a TWD book'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_BUSINESS_REQUIRES_TWD';
    END IF;
    UPDATE public.books
    SET entity_type = CASE
	WHEN normalized_legal_form = 'sole_proprietorship' THEN 'sole_trader'
	WHEN normalized_legal_form = 'partnership' THEN 'partnership'
	ELSE 'company'
    END
    WHERE id = p_book_id AND entity_type = 'household';
    IF normalized_legal_name IS NULL THEN
        RAISE EXCEPTION 'business legal name is required'
            USING ERRCODE = 'P0001', DETAIL = 'BUSINESS_LEGAL_NAME_REQUIRED';
    END IF;
    IF normalized_ubn IS NULL OR normalized_ubn !~ '^[0-9]{8}$' THEN
        RAISE EXCEPTION 'Unified Business Number must contain eight digits'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_UBN_INVALID';
    END IF;
    IF normalized_legal_form IS NULL OR NOT EXISTS (
        SELECT 1 FROM taiwan_legal_forms WHERE id = normalized_legal_form
    ) THEN
        RAISE EXCEPTION 'Taiwan legal form does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_LEGAL_FORM_NOT_FOUND';
    END IF;
    IF normalized_frequency IS NULL OR NOT EXISTS (
        SELECT 1 FROM taiwan_business_tax_frequencies
        WHERE id = normalized_frequency
    ) THEN
        RAISE EXCEPTION 'business-tax frequency does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'TAIWAN_TAX_FREQUENCY_NOT_FOUND';
    END IF;
    IF normalized_period_id IS NULL THEN
        RAISE EXCEPTION 'fiscal period id is required'
            USING ERRCODE = 'P0001', DETAIL = 'FISCAL_PERIOD_ID_REQUIRED';
    END IF;
    IF p_period_start IS NULL OR p_period_end IS NULL THEN
        RAISE EXCEPTION 'fiscal period dates are required'
            USING ERRCODE = 'P0001', DETAIL = 'FISCAL_PERIOD_DATES_REQUIRED';
    END IF;
    IF p_period_start > p_period_end THEN
        RAISE EXCEPTION 'fiscal period starts after it ends'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_FISCAL_PERIOD';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM taiwan_period_statuses WHERE id = normalized_period_status
    ) THEN
        RAISE EXCEPTION 'fiscal period status does not exist'
            USING ERRCODE = 'P0001', DETAIL = 'PERIOD_STATUS_NOT_FOUND';
    END IF;

    PERFORM njord.ensure_standard_accounts(p_book_id, FALSE);

    INSERT INTO taiwan_business_profiles (
        book_id, legal_name, unified_business_number, legal_form,
        business_tax_frequency, uses_uniform_invoices,
        established_on, responsible_person, registered_address,
        tax_registration_notes, notes
    ) VALUES (
        p_book_id, normalized_legal_name, normalized_ubn,
        normalized_legal_form, normalized_frequency,
        COALESCE(p_uses_uniform_invoices, TRUE), p_established_on,
        NULLIF(btrim(p_responsible_person), ''),
        NULLIF(btrim(p_registered_address), ''),
        NULLIF(btrim(p_tax_registration_notes), ''),
        NULLIF(btrim(p_notes), '')
    )
    ON CONFLICT (book_id) DO UPDATE SET
        legal_name = EXCLUDED.legal_name,
        unified_business_number = EXCLUDED.unified_business_number,
        legal_form = EXCLUDED.legal_form,
        business_tax_frequency = EXCLUDED.business_tax_frequency,
        uses_uniform_invoices = EXCLUDED.uses_uniform_invoices,
        established_on = EXCLUDED.established_on,
        responsible_person = EXCLUDED.responsible_person,
        registered_address = EXCLUDED.registered_address,
        tax_registration_notes = EXCLUDED.tax_registration_notes,
        notes = EXCLUDED.notes;

    INSERT INTO taiwan_fiscal_periods (
        book_id, id, period_start, period_end, status,
        annual_income_tax_due_on, provisional_income_tax_due_on,
        undistributed_earnings_due_on, notes
    ) VALUES (
        p_book_id, normalized_period_id, p_period_start, p_period_end,
        normalized_period_status,
        p_annual_income_tax_due_on, p_provisional_income_tax_due_on,
        p_undistributed_earnings_due_on, NULLIF(btrim(p_period_notes), '')
    )
    ON CONFLICT (book_id, id) DO UPDATE SET
        period_start = EXCLUDED.period_start,
        period_end = EXCLUDED.period_end,
        status = EXCLUDED.status,
        annual_income_tax_due_on = EXCLUDED.annual_income_tax_due_on,
        provisional_income_tax_due_on = EXCLUDED.provisional_income_tax_due_on,
        undistributed_earnings_due_on = EXCLUDED.undistributed_earnings_due_on,
        notes = EXCLUDED.notes;

    IF COALESCE(p_enable_manufacturing, FALSE) THEN
        INSERT INTO taiwan_manufacturing_profiles (book_id)
        VALUES (p_book_id)
        ON CONFLICT (book_id) DO NOTHING;
    ELSE
        BEGIN
            DELETE FROM taiwan_manufacturing_profiles
            WHERE book_id = p_book_id;
        EXCEPTION WHEN foreign_key_violation THEN
            RAISE EXCEPTION 'manufacturing records must be removed before disabling the extension'
                USING ERRCODE = 'P0001',
                      DETAIL = 'TAIWAN_MANUFACTURING_EXTENSION_HAS_DATA';
        END;
    END IF;

    RETURN QUERY SELECT * FROM api.book_page(p_book_id);
END;
$$;

CREATE OR REPLACE FUNCTION api.add_account_page(
    p_book_id VARCHAR,
    p_parent_id VARCHAR DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH account_tree AS (
	SELECT *
	FROM public.report_account_tree
	WHERE book_id = p_book_id
    ),
    requested_parent AS (
	SELECT *
	FROM account_tree
	WHERE id = COALESCE(
	    NULLIF(btrim(p_parent_id), ''),
	    (SELECT id
	     FROM account_tree AS default_parent
	     WHERE default_parent.parent_id IS NULL
	       AND default_parent.type = 'A')
	)
    )
    SELECT * FROM api.shell_page(p_book_id)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'add-account'::VARCHAR,
	jsonb_build_object(
	    'page', 'add-account',
	    'book_id', p_book_id,
	    'parent_id', (SELECT id FROM requested_parent),
	    'account_type', COALESCE(
		(SELECT type FROM requested_parent),
		'A'
	    ),
	    'asset', COALESCE(
		(SELECT atype FROM requested_parent),
		(SELECT books.reporting_asset
		 FROM public.books
		 WHERE books.id = p_book_id)
	    ),
	    'account_kind', 'posting',
	    'placeholder', FALSE,
		    'pretax', '1',
	    'opening_date', CURRENT_DATE,
	    'validation_messages', CASE
		WHEN NOT njord.book_exists(p_book_id)
		    THEN jsonb_build_array('Book does not exist.')
		WHEN NULLIF(btrim(p_parent_id), '') IS NOT NULL
		 AND NOT EXISTS (SELECT 1 FROM requested_parent)
		    THEN jsonb_build_array(
			'Parent account does not exist in this book.'
		    )
		ELSE '[]'::JSONB
	    END,
	    'validation', jsonb_build_object(
		'id_required', TRUE,
		'name_required', TRUE,
		'type_required', TRUE,
		'asset_required', TRUE,
		'parent_required', TRUE,
		'kind_required', TRUE,
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
	'account_kind_option'::VARCHAR,
	9700 + row_number() OVER (ORDER BY account_kinds.label, account_kinds.id),
	account_kinds.id,
	jsonb_build_object(
	    'id', account_kinds.id,
	    'label', account_kinds.label,
	    'required_type', account_kinds.required_type
	)
    FROM public.account_kinds
    WHERE account_kinds.id <> 'root'
UNION ALL
    SELECT
	'parent_account_option'::VARCHAR,
	9800 + row_number() OVER (ORDER BY account_tree.sort_path),
	account_tree.id,
	jsonb_build_object(
	    'id', account_tree.id,
	    'name', account_tree.name,
	    'path', array_to_string(account_tree.name_path, ':'),
	    'type', account_tree.type,
	    'asset', account_tree.atype,
	    'placeholder', account_tree.placeholder
	)
    FROM account_tree
UNION ALL
    SELECT
	'asset_option'::VARCHAR,
	10000 + row_number() OVER (ORDER BY asset.id),
	asset.id,
	jsonb_build_object('id', asset.id)
    FROM public.asset;
$$;

CREATE OR REPLACE FUNCTION njord.transaction_preview(
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
    simple JSONB;
    simple_amount NUMERIC(100,5);
    unsupported_field VARCHAR;
BEGIN
    valid := FALSE;
    error_code := NULL;
    error_message := NULL;
    imbalance := '{}'::JSONB;
    normalized_transaction := NULL;

    IF NOT njord.book_exists(p_book_id) THEN
	error_code := 'BOOK_NOT_FOUND';
	error_message := 'book does not exist';
	RETURN NEXT;
	RETURN;
    END IF;

    IF jsonb_typeof(p_transaction) IS DISTINCT FROM 'object' THEN
	error_code := 'INVALID_TRANSACTION_SHAPE';
	error_message := 'transaction must be an object';
	RETURN NEXT;
	RETURN;
    END IF;

    SELECT key
    INTO unsupported_field
    FROM jsonb_object_keys(p_transaction) AS fields(key)
    WHERE key NOT IN ('date', 'comment', 'lines', 'simple')
    ORDER BY key
    LIMIT 1;

    IF unsupported_field IS NOT NULL THEN
	error_code := 'UNSUPPORTED_TRANSACTION_FIELD';
	error_message := 'unsupported transaction field: ' || unsupported_field;
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

    IF requested_date IS NULL OR NOT isfinite(requested_date) THEN
	error_code := 'INVALID_DATE';
	error_message := CASE WHEN requested_date IS NULL
	    THEN 'date is required' ELSE 'date must be finite' END;
	RETURN NEXT;
	RETURN;
    END IF;

    IF p_transaction ? 'simple' THEN
	IF p_transaction ? 'lines' THEN
	    error_code := 'INVALID_TRANSACTION_SHAPE';
	    error_message := 'use either simple or lines, not both';
	    RETURN NEXT;
	    RETURN;
	END IF;

	simple := p_transaction -> 'simple';
	IF jsonb_typeof(simple) IS DISTINCT FROM 'object'
	   OR NULLIF(btrim(simple ->> 'account'), '') IS NULL
	   OR NULLIF(btrim(simple ->> 'transfer_account'), '') IS NULL
	   OR NULLIF(btrim(simple ->> 'amount'), '') IS NULL THEN
	    error_code := 'INVALID_SIMPLE_TRANSACTION';
	    error_message := 'simple transactions require an account, transfer account, and non-zero amount';
	    RETURN NEXT;
	    RETURN;
	END IF;

	BEGIN
	    simple_amount := (simple ->> 'amount')::NUMERIC(100,5);
	EXCEPTION WHEN OTHERS THEN
	    error_code := 'INVALID_SIMPLE_TRANSACTION';
	    error_message := 'simple transactions require an account, transfer account, and non-zero amount';
	    RETURN NEXT;
	    RETURN;
	END;

	IF simple_amount = 0 OR NOT njord.is_finite(simple_amount) THEN
	    error_code := 'INVALID_SIMPLE_TRANSACTION';
	    error_message := 'simple transactions require an account, transfer account, and non-zero amount';
	    RETURN NEXT;
	    RETURN;
	END IF;

	p_transaction := (p_transaction - 'simple') || jsonb_build_object(
	    'lines', jsonb_build_array(
		jsonb_build_object(
		    'account', btrim(simple ->> 'account'),
		    'amount', simple_amount,
		    'comment', NULL
		),
		jsonb_build_object(
		    'account', btrim(simple ->> 'transfer_account'),
		    'amount', -simple_amount,
		    'comment', NULL
		)
	    )
	);
    END IF;

    IF jsonb_typeof(p_transaction -> 'lines') IS DISTINCT FROM 'array' THEN
	error_code := 'INVALID_LINES';
	error_message := 'lines must be an array';
	RETURN NEXT;
	RETURN;
    END IF;

    -- The expanded register always submits one transient blank row.  It is not
    -- a posting.  Ignore only objects of the expected shape whose account,
    -- amount, and memo are all blank; a partly entered or malformed row must
    -- continue through normal INVALID_LINE validation.
    SELECT COALESCE(jsonb_agg(line ORDER BY ordinality), '[]'::JSONB)
    INTO normalized_lines
    FROM jsonb_array_elements(p_transaction -> 'lines')
	WITH ORDINALITY AS lines(line, ordinality)
    WHERE jsonb_typeof(line) IS DISTINCT FROM 'object'
       OR (line - 'account' - 'amount' - 'comment') <> '{}'::JSONB
       OR NULLIF(btrim(line ->> 'account'), '') IS NOT NULL
       OR NULLIF(btrim(line ->> 'amount'), '') IS NOT NULL
       OR NULLIF(btrim(line ->> 'comment'), '') IS NOT NULL;

    p_transaction := jsonb_set(p_transaction, '{lines}', normalized_lines);
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
	  AND NOT placeholder
    )
    LIMIT 1;

    IF missing_account IS NOT NULL THEN
	error_code := 'ACCOUNT_NOT_FOUND';
	error_message := 'account does not exist in this book: ' || missing_account;
	RETURN NEXT;
	RETURN;
    END IF;

    IF line_count < 2 THEN
	error_code := 'TRANSACTION_REQUIRES_TWO_LINES';
	error_message := 'transactions require at least two lines';
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
	'comment', normalized_comment,
	'lines', normalized_lines
    );

    IF imbalance <> '{}'::JSONB THEN
	error_code := 'TRANSACTION_NOT_BALANCED';
	error_message := 'transaction is not balanced per asset';
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
    SELECT * FROM njord.transaction_preview(p_book_id, p_transaction);
$$;

CREATE OR REPLACE FUNCTION api.transaction_draft_balance(
    p_book_id VARCHAR,
    p_lines JSONB
)
RETURNS TABLE (
    asset VARCHAR,
    amount NUMERIC(100,5)
)
LANGUAGE SQL
STABLE
AS $$
    SELECT
	accts.atype::VARCHAR AS asset,
	(-sum(parsed.amount))::NUMERIC(100,5) AS amount
    FROM jsonb_array_elements(p_lines) AS lines(line)
    JOIN public.accts
	ON accts.book_id = p_book_id
       AND accts.id = btrim(lines.line ->> 'account')
    CROSS JOIN LATERAL (VALUES (
	njord.parse_ledger_amount_or_null(lines.line ->> 'amount')
    )) AS parsed(amount)
    WHERE jsonb_typeof(lines.line) = 'object'
      AND parsed.amount IS NOT NULL
    GROUP BY accts.atype
    HAVING sum(parsed.amount) <> 0
    ORDER BY accts.atype;
$$;

-- Editable decimal values cross the JSON boundary as text. The numeric RPC
-- remains available to SQL clients; the Web UI uses this lossless projection.
CREATE OR REPLACE FUNCTION api.transaction_draft_balance_text(
    p_book_id VARCHAR,
    p_lines JSONB
)
RETURNS TABLE (
    asset VARCHAR,
    amount VARCHAR
)
LANGUAGE SQL
STABLE
AS $$
    SELECT balance.asset, balance.amount::VARCHAR
    FROM api.transaction_draft_balance(p_book_id, p_lines) AS balance;
$$;

CREATE OR REPLACE FUNCTION njord.require_valid_transaction(
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
    FROM njord.transaction_preview(p_book_id, p_transaction);

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
    xid INTEGER
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized JSONB;
    new_xid INTEGER;
BEGIN
    normalized := njord.require_valid_transaction(p_book_id, p_transaction);

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

    RETURN QUERY SELECT p_book_id, new_xid;
END;
$$;

CREATE OR REPLACE FUNCTION api.replace_transaction(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_transaction JSONB
)
RETURNS TABLE (
    book_id VARCHAR,
    xid INTEGER
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized JSONB;
BEGIN
    normalized := njord.require_valid_transaction(p_book_id, p_transaction);

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

    -- Account is a posting's stable identity within a transaction. Update
    -- matching lines in place so their serial IDs, reconciliation state, and
    -- linked evidence survive ordinary edits.
    UPDATE public.xaction_bits AS posting
    SET amt = (requested.line ->> 'amount')::NUMERIC,
	comment = requested.line ->> 'comment'
    FROM jsonb_array_elements(normalized -> 'lines') AS requested(line)
    WHERE posting.book_id = p_book_id
      AND posting.xid = p_xid
      AND posting.acct = requested.line ->> 'account';

    DELETE FROM public.xaction_bits
    WHERE xaction_bits.book_id = p_book_id
      AND xaction_bits.xid = p_xid
      AND NOT EXISTS (
	SELECT 1
	FROM jsonb_array_elements(normalized -> 'lines') AS requested(line)
	WHERE requested.line ->> 'account' = xaction_bits.acct
      );

    INSERT INTO public.xaction_bits (book_id, xid, acct, amt, comment)
    SELECT
	p_book_id,
	p_xid,
	line ->> 'account',
	(line ->> 'amount')::NUMERIC,
	line ->> 'comment'
    FROM jsonb_array_elements(normalized -> 'lines') AS lines(line)
    WHERE NOT EXISTS (
	SELECT 1
	FROM public.xaction_bits AS existing
	WHERE existing.book_id = p_book_id
	  AND existing.xid = p_xid
	  AND existing.acct = line ->> 'account'
    );

    RETURN QUERY SELECT p_book_id, p_xid;
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
    IF p_date IS NULL OR NOT isfinite(p_date) THEN
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

CREATE OR REPLACE FUNCTION api.set_posting_reconciled(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_account_id VARCHAR,
    p_reconciled BOOLEAN
)
RETURNS TABLE (
    book_id VARCHAR,
    xid INTEGER,
    account VARCHAR,
    reconciled BOOLEAN
)
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    IF p_reconciled IS NULL THEN
	RAISE EXCEPTION 'reconciled state is required'
	    USING ERRCODE = 'P0001', DETAIL = 'RECONCILED_STATE_REQUIRED';
    END IF;

    IF NOT EXISTS (
	SELECT 1
	FROM public.xaction_bits
	WHERE xaction_bits.book_id = p_book_id
	  AND xaction_bits.xid = p_xid
	  AND xaction_bits.acct = p_account_id
    ) THEN
	RAISE EXCEPTION 'posting does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'POSTING_NOT_FOUND';
    END IF;

    IF p_reconciled THEN
	DELETE FROM public.unreconciled_postings
	WHERE unreconciled_postings.book_id = p_book_id
	  AND unreconciled_postings.xid = p_xid
	  AND unreconciled_postings.acct = p_account_id;
    ELSE
	INSERT INTO public.unreconciled_postings (book_id, xid, acct)
	VALUES (p_book_id, p_xid, p_account_id)
	ON CONFLICT ON CONSTRAINT unreconciled_postings_pkey DO NOTHING;
    END IF;

    RETURN QUERY SELECT p_book_id, p_xid, p_account_id, p_reconciled;
END;
$$;

CREATE OR REPLACE FUNCTION api.create_book(
    p_id VARCHAR,
    p_name VARCHAR,
    p_reporting_asset VARCHAR,
    p_create_standard_accounts BOOLEAN DEFAULT TRUE,
    p_entity_type VARCHAR DEFAULT 'household'
)
RETURNS TABLE (
    id VARCHAR,
    name VARCHAR,
    reporting_asset VARCHAR,
    entity_type VARCHAR
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    normalized_id VARCHAR;
    normalized_name VARCHAR;
    normalized_asset VARCHAR;
    normalized_entity_type VARCHAR;
BEGIN
    normalized_id := NULLIF(btrim(p_id), '');
    normalized_name := NULLIF(btrim(p_name), '');
    normalized_asset := NULLIF(btrim(p_reporting_asset), '');
    normalized_entity_type := COALESCE(
	NULLIF(btrim(p_entity_type), ''), 'household'
    );

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

    IF NOT EXISTS (
	SELECT 1 FROM public.book_entity_types
	WHERE book_entity_types.id = normalized_entity_type
    ) THEN
	RAISE EXCEPTION 'book entity type does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_ENTITY_TYPE_NOT_FOUND';
    END IF;

    INSERT INTO public.books (id, name, reporting_asset, entity_type)
    VALUES (
	normalized_id, normalized_name, normalized_asset, normalized_entity_type
    );

    IF COALESCE(p_create_standard_accounts, TRUE) THEN
	PERFORM njord.ensure_standard_accounts(normalized_id);
    END IF;

    RETURN QUERY SELECT
	normalized_id, normalized_name, normalized_asset, normalized_entity_type;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'book already exists'
	USING ERRCODE = 'P0001', DETAIL = 'BOOK_ALREADY_EXISTS';
END;
$$;

CREATE OR REPLACE FUNCTION api.create_account(
    p_book_id VARCHAR,
    p_id VARCHAR,
    p_type VARCHAR DEFAULT NULL,
    p_asset VARCHAR DEFAULT NULL,
    p_pretax NUMERIC DEFAULT 1,
    p_comment VARCHAR DEFAULT NULL,
    p_opening_balance NUMERIC DEFAULT NULL,
    p_opening_date DATE DEFAULT NULL,
    p_parent_id VARCHAR DEFAULT NULL,
    p_name VARCHAR DEFAULT NULL,
    p_account_kind VARCHAR DEFAULT NULL,
    p_placeholder BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    book_id VARCHAR,
    id VARCHAR,
    name VARCHAR,
    type VARCHAR,
    asset VARCHAR,
    parent_id VARCHAR,
    account_kind VARCHAR,
    placeholder BOOLEAN,
    pretax NUMERIC,
    comment VARCHAR
)
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    opening_account VARCHAR;
    normalized_id VARCHAR;
    normalized_type VARCHAR;
    normalized_asset VARCHAR;
    normalized_comment VARCHAR;
    normalized_name VARCHAR;
    normalized_parent_id VARCHAR;
    normalized_account_kind VARCHAR;
    parent_type VARCHAR;
    parent_asset VARCHAR;
BEGIN
    normalized_id := NULLIF(btrim(p_id), '');
    normalized_type := NULLIF(btrim(p_type), '');
    normalized_asset := NULLIF(btrim(p_asset), '');
    normalized_comment := NULLIF(btrim(p_comment), '');
    normalized_name := COALESCE(NULLIF(btrim(p_name), ''), normalized_id);
    normalized_parent_id := NULLIF(btrim(p_parent_id), '');
    normalized_account_kind := COALESCE(
	NULLIF(btrim(p_account_kind), ''),
	CASE WHEN COALESCE(p_placeholder, FALSE) THEN 'group' ELSE 'posting' END
    );

    IF NOT njord.book_exists(p_book_id) THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    IF normalized_id IS NULL THEN
	RAISE EXCEPTION 'account id is required'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_ID_REQUIRED';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM public.accts
	WHERE accts.book_id = p_book_id
	  AND accts.id = normalized_id
    ) THEN
	RAISE EXCEPTION 'account already exists in this book'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_ALREADY_EXISTS';
    END IF;

    IF normalized_type IS NOT NULL AND NOT EXISTS (
	SELECT 1 FROM public.acct_types WHERE acct_types.id = normalized_type
    ) THEN
	RAISE EXCEPTION 'account type does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_TYPE_NOT_FOUND';
    END IF;

    IF normalized_asset IS NOT NULL AND NOT EXISTS (
	SELECT 1 FROM public.asset WHERE asset.id = normalized_asset
    ) THEN
	RAISE EXCEPTION 'account asset does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_ASSET_NOT_FOUND';
    END IF;

    IF normalized_parent_id IS NULL THEN
	normalized_type := COALESCE(normalized_type, 'A');

	SELECT accts.id, accts.type, accts.atype
	INTO normalized_parent_id, parent_type, parent_asset
	FROM public.accts
	WHERE accts.book_id = p_book_id
	  AND accts.parent_id IS NULL
	  AND accts.type = normalized_type;

	IF normalized_parent_id IS NULL THEN
	    RAISE EXCEPTION 'select a parent account'
		USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_PARENT_REQUIRED';
	END IF;
    ELSE
	SELECT accts.type, accts.atype
	INTO parent_type, parent_asset
	FROM public.accts
	WHERE accts.book_id = p_book_id
	  AND accts.id = normalized_parent_id;

	IF NOT FOUND THEN
	    RAISE EXCEPTION 'parent account does not exist in this book'
		USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_PARENT_NOT_FOUND';
	END IF;
    END IF;

    IF normalized_type IS NOT NULL AND normalized_type <> parent_type THEN
	RAISE EXCEPTION 'account class must match its parent account class'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_PARENT_TYPE_MISMATCH';
    END IF;

    normalized_type := parent_type;
    normalized_asset := COALESCE(normalized_asset, parent_asset);

    IF EXISTS (
	SELECT 1
	FROM public.accts
	WHERE accts.book_id = p_book_id
	  AND accts.parent_id = normalized_parent_id
	  AND accts.name = normalized_name
    ) THEN
	RAISE EXCEPTION 'an account with this name already exists under the selected parent'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_NAME_ALREADY_EXISTS';
    END IF;

    IF NOT EXISTS (
	SELECT 1
	FROM public.account_kinds
	WHERE account_kinds.id = normalized_account_kind
    ) THEN
	RAISE EXCEPTION 'account kind does not exist'
	    USING ERRCODE = 'P0001', DETAIL = 'ACCOUNT_KIND_NOT_FOUND';
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

    IF p_opening_date IS NOT NULL AND NOT isfinite(p_opening_date) THEN
	RAISE EXCEPTION 'opening_date must be finite'
	    USING ERRCODE = 'P0001', DETAIL = 'INVALID_OPENING_DATE';
    END IF;

    IF COALESCE(p_placeholder, FALSE)
       AND p_opening_balance IS NOT NULL
       AND p_opening_balance <> 0 THEN
	RAISE EXCEPTION 'placeholder accounts cannot have an opening balance'
	    USING ERRCODE = 'P0001', DETAIL = 'PLACEHOLDER_OPENING_BALANCE';
    END IF;

    INSERT INTO public.accts (
	book_id, id, name, type, atype, parent_id, account_kind, placeholder,
	pretax, comment
    )
    VALUES (
	p_book_id,
	normalized_id,
	normalized_name,
	normalized_type,
	normalized_asset,
	normalized_parent_id,
	normalized_account_kind,
	COALESCE(p_placeholder, FALSE),
	p_pretax,
	normalized_comment
    );

    IF normalized_account_kind IN ('bank', 'cash')
       AND NOT COALESCE(p_placeholder, FALSE) THEN
	INSERT INTO public.cash_accounts (book_id, acct)
	VALUES (p_book_id, normalized_id);
    END IF;

    IF p_opening_balance IS NOT NULL AND p_opening_balance <> 0 THEN
	opening_account := public.opening_balance_account(
	    p_book_id,
	    normalized_asset
	);

	PERFORM 1
	FROM api.create_transaction(
	    p_book_id,
	    jsonb_build_object(
		'date', p_opening_date,
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
	);
    END IF;

    RETURN QUERY
    SELECT
	accts.book_id,
	accts.id,
	accts.name,
	accts.type,
	accts.atype,
	accts.parent_id,
	accts.account_kind,
	accts.placeholder,
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
    'PostgREST API for the Njord accounting user interface';

COMMENT ON FUNCTION api.book_page(VARCHAR) IS
    'Complete Book identity, currency history, lifecycle, and optional jurisdiction-pack page model';

COMMENT ON FUNCTION api.update_book_settings(VARCHAR, VARCHAR, VARCHAR) IS
    'Update a book display name and explicit entity classification';

COMMENT ON FUNCTION api.set_book_reporting_currency(VARCHAR, VARCHAR, DATE) IS
    'Replace an empty book denomination or add an effective-dated reporting-currency transition';

COMMENT ON FUNCTION api.archive_book(VARCHAR) IS
    'Hide a book from ordinary navigation without deleting it';

COMMENT ON FUNCTION api.restore_book(VARCHAR) IS
    'Restore an archived book to ordinary navigation';

COMMENT ON FUNCTION api.configure_uk_company(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, DATE,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR,
    DATE, DATE, DATE, DATE, VARCHAR
) IS
    'Atomically ensure the standard hierarchy and configure a UK company profile, period, and required VAT control account';

COMMENT ON FUNCTION api.ledger_page(VARCHAR, VARCHAR) IS
    'Complete account-ledger page model, including shell and transfer choices';

COMMENT ON FUNCTION api.accounts_page(VARCHAR) IS
    'Complete active-book account workspace with native-asset balances';

COMMENT ON FUNCTION api.reconciliation_page(VARCHAR, VARCHAR) IS
    'Posting reconciliation workspace, optionally filtered to one account';

COMMENT ON FUNCTION api.set_posting_reconciled(VARCHAR, INTEGER, VARCHAR, BOOLEAN) IS
    'Idempotently mark one naturally keyed posting reconciled or unreconciled';

COMMENT ON FUNCTION api.reports_page(VARCHAR) IS
    'Complete reports-library page model, including shell and report choices';

COMMENT ON FUNCTION api.preview_transaction(VARCHAR, JSONB) IS
    'Validate and normalize a candidate transaction without writing it';

COMMENT ON FUNCTION api.transaction_draft_balance(VARCHAR, JSONB) IS
    'Return SQL-derived reciprocal amounts for complete split draft lines';
