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
    'default book is loaded',
    EXISTS (
	SELECT 1
	FROM books
	WHERE id = 'personal'
	  AND reporting_asset = 'GBP'
    )
);

SELECT pg_temp.assert_true(
    'standard accounts are loaded',
    (
	SELECT count(*) = 8
	FROM accts
	WHERE book_id = 'personal'
	  AND id IN (
	      'Assets', 'Liabilities', 'Equity', 'Income', 'Expenses', 'Opening Balance',
	      'Uncategorised Income', 'Uncategorised Expenses'
	  )
    )
);

SELECT pg_temp.assert_true(
    'one ordered catalog defines standard roots and onboarding accounts',
    (
	SELECT count(*) = 8
	   AND count(*) FILTER (WHERE NOT onboarding) = 5
	   AND array_agg(id ORDER BY account_order) FILTER (WHERE onboarding)
	       = ARRAY[
		'Opening Balance',
		'Uncategorised Income',
		'Uncategorised Expenses'
	       ]::VARCHAR[]
	FROM njord.standard_account_catalog
    )
);

SELECT pg_temp.assert_true(
    'one report-period relation maps every jurisdiction profile kind',
    (
	SELECT array_agg(DISTINCT profile_kind ORDER BY profile_kind)
	FROM report_periods
	WHERE book_id IN ('uk-business', 'panama-property', 'taiwan-injection')
    ) = ARRAY[
	'panama_business',
	'panama_residential_property',
	'taiwan_business',
	'taiwan_manufacturing',
	'uk_company'
    ]::VARCHAR[]
);

SELECT pg_temp.assert_true(
    'one shared invariant owns every profile and the Book side',
    (
	SELECT count(*) = 7
	FROM pg_trigger
	WHERE tgname IN (
	    'uk_company_profile_serialize', 'uk_company_profile_validate',
	    'panama_business_profile_serialize', 'panama_business_profile_validate',
	    'taiwan_business_profile_serialize', 'taiwan_business_profile_validate',
	    'books_validate_jurisdiction_profile'
	)
    )
);

SELECT pg_temp.assert_true(
    'jurisdiction reporting-asset eligibility is explicit relational data',
    (
	SELECT array_agg(
	    jurisdiction || ':' || reporting_asset
	    ORDER BY jurisdiction, reporting_asset
	)
	FROM njord.jurisdiction_reporting_assets
    ) = ARRAY['panama:PAB', 'panama:USD', 'taiwan:TWD', 'uk:GBP']::TEXT[]
);

BEGIN;

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('jurisdiction-invariant', 'Jurisdiction invariant', 'GBP', 'company');

DO $$
DECLARE
    failed_constraint TEXT;
BEGIN
    BEGIN
	INSERT INTO uk_company_profiles (
	    book_id, legal_name, legal_form, accounting_framework, vat_scheme
	) VALUES (
	    'jurisdiction-invariant', 'Invariant Ltd',
	    'private_limited_shares', 'frs105', 'not_registered'
	);
	INSERT INTO panama_business_profiles (
	    book_id, legal_name, ruc, legal_form, municipality,
	    default_tax_policy_id
	) VALUES (
	    'jurisdiction-invariant', 'Invariant, S.A.', 'invariant',
	    'corporation', 'panama_district', 'current_2026'
	);

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'two jurisdiction profiles were accepted';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'one_jurisdiction_profile_per_book' THEN
	    RAISE;
	END IF;
    END;
END;
$$;

ROLLBACK;

DO $$
DECLARE
    failed_constraint TEXT;
BEGIN
    BEGIN
	UPDATE uk_vat_behaviours
	SET vat_rate = 'NaN'
	WHERE id = 'sale_standard';
	RAISE EXCEPTION 'non-finite UK VAT rate was accepted';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'uk_vat_behaviours_vat_rate_range' THEN
	    RAISE;
	END IF;
    END;

    BEGIN
	UPDATE panama_tax_policies
	SET form_43_revenue_threshold = 'NaN'
	WHERE id = 'current_2026';
	RAISE EXCEPTION 'non-finite Panama Form 43 revenue threshold was accepted';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'panama_form_43_revenue_threshold' THEN
	    RAISE;
	END IF;
    END;

    BEGIN
	UPDATE panama_tax_policies
	SET form_43_asset_threshold = -1
	WHERE id = 'current_2026';
	RAISE EXCEPTION 'negative Panama Form 43 asset threshold was accepted';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'panama_form_43_asset_threshold' THEN
	    RAISE;
	END IF;
    END;

    BEGIN
	UPDATE panama_property_units
	SET floor_area_square_metres = 'NaN'
	WHERE book_id = 'panama-property' AND id = '8A';
	RAISE EXCEPTION 'non-finite Panama property floor area was accepted';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'panama_property_unit_floor_area' THEN
	    RAISE;
	END IF;
    END;
END;
$$;

BEGIN;

INSERT INTO books (id, name, reporting_asset, entity_type) VALUES
    ('jurisdiction-household', 'Jurisdiction household', 'GBP', 'household'),
    ('jurisdiction-uk', 'Jurisdiction UK', 'GBP', 'company'),
    ('jurisdiction-panama', 'Jurisdiction Panama', 'PAB', 'company'),
    ('jurisdiction-taiwan', 'Jurisdiction Taiwan', 'TWD', 'company');

DO $$
DECLARE
    failed_constraint TEXT;
BEGIN
    BEGIN
	INSERT INTO uk_company_profiles (
	    book_id, legal_name, legal_form, accounting_framework, vat_scheme
	) VALUES (
	    'jurisdiction-household', 'Household Ltd',
	    'private_limited_shares', 'frs105', 'not_registered'
	);
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'household accepted a business jurisdiction profile';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'jurisdiction_profile_business_entity' THEN
	    RAISE;
	END IF;
    END;
END;
$$;

INSERT INTO uk_company_profiles (
    book_id, legal_name, legal_form, accounting_framework, vat_scheme
) VALUES (
    'jurisdiction-uk', 'Jurisdiction UK Ltd',
    'private_limited_shares', 'frs105', 'not_registered'
);
INSERT INTO panama_business_profiles (
    book_id, legal_name, ruc, legal_form, municipality, default_tax_policy_id
) VALUES (
    'jurisdiction-panama', 'Jurisdiction Panama, S.A.', 'jurisdiction-panama',
    'corporation', 'panama_district', 'current_2026'
);
INSERT INTO taiwan_business_profiles (
    book_id, legal_name, unified_business_number, legal_form,
    business_tax_frequency
) VALUES (
    'jurisdiction-taiwan', '台灣管轄測試有限公司', '11223344',
    'limited_company', 'bimonthly'
);

SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

DO $$
DECLARE
    failed_constraint TEXT;
BEGIN
    BEGIN
	UPDATE books SET entity_type = 'household' WHERE id = 'jurisdiction-uk';
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'configured business Book became a household';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'jurisdiction_profile_business_entity' THEN
	    RAISE;
	END IF;
    END;

    BEGIN
	UPDATE books SET reporting_asset = 'USD' WHERE id = 'jurisdiction-uk';
	UPDATE book_reporting_currencies SET asset = 'USD'
	WHERE book_id = 'jurisdiction-uk' AND effective_from = '-infinity'::DATE;
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'configured UK Book changed to USD';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'uk_company_profile_gbp_reporting' THEN
	    RAISE;
	END IF;
    END;

    BEGIN
	UPDATE books SET reporting_asset = 'GBP' WHERE id = 'jurisdiction-panama';
	UPDATE book_reporting_currencies SET asset = 'GBP'
	WHERE book_id = 'jurisdiction-panama' AND effective_from = '-infinity'::DATE;
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'configured Panama Book changed to GBP';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'panama_business_profile_reporting_asset' THEN
	    RAISE;
	END IF;
    END;

    BEGIN
	UPDATE books SET reporting_asset = 'GBP' WHERE id = 'jurisdiction-taiwan';
	UPDATE book_reporting_currencies SET asset = 'GBP'
	WHERE book_id = 'jurisdiction-taiwan' AND effective_from = '-infinity'::DATE;
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'configured Taiwan Book changed to GBP';
    EXCEPTION WHEN check_violation THEN
	GET STACKED DIAGNOSTICS failed_constraint = CONSTRAINT_NAME;
	IF failed_constraint IS DISTINCT FROM 'taiwan_business_profile_reporting_asset' THEN
	    RAISE;
	END IF;
    END;
END;
$$;

ROLLBACK;

BEGIN;

DO $$
DECLARE
    error_detail TEXT;
BEGIN
    PERFORM * FROM api.create_book(
	'extension-panama', 'Extension Panama', 'PAB', FALSE, 'company'
    );
    PERFORM * FROM api.configure_panama_business(
	p_book_id => 'extension-panama',
	p_legal_name => 'Extension Panama, S.A.',
	p_ruc => 'extension-panama',
	p_legal_form => 'corporation',
	p_municipality => 'panama_district',
	p_period_id => '2026',
	p_period_start => DATE '2026-01-01',
	p_period_end => DATE '2026-12-31',
	p_enable_residential_property => TRUE
    );
    PERFORM * FROM api.configure_panama_business(
	p_book_id => 'extension-panama',
	p_legal_name => 'Extension Panama, S.A.',
	p_ruc => 'extension-panama',
	p_legal_form => 'corporation',
	p_municipality => 'panama_district',
	p_period_id => '2026',
	p_period_start => DATE '2026-01-01',
	p_period_end => DATE '2026-12-31',
	p_enable_residential_property => FALSE
    );
    IF EXISTS (
	SELECT 1 FROM panama_residential_property_profiles
	WHERE book_id = 'extension-panama'
    ) THEN
	RAISE EXCEPTION 'empty Panama property extension was not disabled';
    END IF;

    PERFORM * FROM api.configure_panama_business(
	p_book_id => 'extension-panama',
	p_legal_name => 'Extension Panama, S.A.',
	p_ruc => 'extension-panama',
	p_legal_form => 'corporation',
	p_municipality => 'panama_district',
	p_period_id => '2026',
	p_period_start => DATE '2026-01-01',
	p_period_end => DATE '2026-12-31',
	p_enable_residential_property => TRUE
    );
    INSERT INTO panama_tenants (book_id, id, name)
    VALUES ('extension-panama', 'tenant', 'Tenant');

    BEGIN
	PERFORM * FROM api.configure_panama_business(
	    p_book_id => 'extension-panama',
	    p_legal_name => 'Extension Panama, S.A.',
	    p_ruc => 'extension-panama',
	    p_legal_form => 'corporation',
	    p_municipality => 'panama_district',
	    p_period_id => '2026',
	    p_period_start => DATE '2026-01-01',
	    p_period_end => DATE '2026-12-31',
	    p_enable_residential_property => FALSE
	);
	RAISE EXCEPTION 'Panama property evidence was silently deleted'
	    USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
	IF error_detail IS DISTINCT FROM 'PANAMA_PROPERTY_EXTENSION_HAS_DATA' THEN
	    RAISE;
	END IF;
    END;

    PERFORM * FROM api.create_book(
	'extension-taiwan', 'Extension Taiwan', 'TWD', FALSE, 'company'
    );
    PERFORM * FROM api.configure_taiwan_business(
	p_book_id => 'extension-taiwan',
	p_legal_name => 'Extension Taiwan Ltd',
	p_unified_business_number => '87654321',
	p_legal_form => 'limited_company',
	p_business_tax_frequency => 'bimonthly',
	p_period_id => '2026',
	p_period_start => DATE '2026-01-01',
	p_period_end => DATE '2026-12-31',
	p_enable_manufacturing => TRUE
    );
    PERFORM * FROM api.configure_taiwan_business(
	p_book_id => 'extension-taiwan',
	p_legal_name => 'Extension Taiwan Ltd',
	p_unified_business_number => '87654321',
	p_legal_form => 'limited_company',
	p_business_tax_frequency => 'bimonthly',
	p_period_id => '2026',
	p_period_start => DATE '2026-01-01',
	p_period_end => DATE '2026-12-31',
	p_enable_manufacturing => FALSE
    );
    IF EXISTS (
	SELECT 1 FROM taiwan_manufacturing_profiles
	WHERE book_id = 'extension-taiwan'
    ) THEN
	RAISE EXCEPTION 'empty Taiwan manufacturing extension was not disabled';
    END IF;

    PERFORM * FROM api.configure_taiwan_business(
	p_book_id => 'extension-taiwan',
	p_legal_name => 'Extension Taiwan Ltd',
	p_unified_business_number => '87654321',
	p_legal_form => 'limited_company',
	p_business_tax_frequency => 'bimonthly',
	p_period_id => '2026',
	p_period_start => DATE '2026-01-01',
	p_period_end => DATE '2026-12-31',
	p_enable_manufacturing => TRUE
    );
    INSERT INTO accts (
	book_id, id, name, type, atype, parent_id, account_kind, placeholder
    ) VALUES (
	'extension-taiwan', 'Test Work in Progress', '測試在製品',
	'A', 'TWD', 'Assets', 'posting', FALSE
    );
    INSERT INTO taiwan_manufacturing_account_mappings (
	book_id, acct, cost_category
    ) VALUES (
	'extension-taiwan', 'Test Work in Progress', 'work_in_progress'
    );

    BEGIN
	PERFORM * FROM api.configure_taiwan_business(
	    p_book_id => 'extension-taiwan',
	    p_legal_name => 'Extension Taiwan Ltd',
	    p_unified_business_number => '87654321',
	    p_legal_form => 'limited_company',
	    p_business_tax_frequency => 'bimonthly',
	    p_period_id => '2026',
	    p_period_start => DATE '2026-01-01',
	    p_period_end => DATE '2026-12-31',
	    p_enable_manufacturing => FALSE
	);
	RAISE EXCEPTION 'Taiwan manufacturing evidence was silently deleted'
	    USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
	IF error_detail IS DISTINCT FROM 'TAIWAN_MANUFACTURING_EXTENSION_HAS_DATA' THEN
	    RAISE;
	END IF;
    END;
END;
$$;

ROLLBACK;

BEGIN;

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('period-selection-test', 'Period Selection Test', 'GBP', 'company');

INSERT INTO uk_company_profiles (
    book_id, legal_name, legal_form, accounting_framework, vat_scheme
) VALUES (
    'period-selection-test', 'Period Selection Test Ltd',
    'private_limited_shares', 'frs105', 'not_registered'
);

INSERT INTO uk_accounting_periods (
    book_id, id, period_start, period_end, status
) VALUES
    (
	'period-selection-test', 'past',
	DATE '2024-01-01', DATE '2024-12-31', 'closed'
    ),
    (
	'period-selection-test', 'future',
	DATE '2026-01-01', DATE '2026-12-31', 'open'
    );

SELECT pg_temp.assert_true(
    'default period chooses latest past, then nearest future, across a gap',
    (
	SELECT period_id = 'past'
	FROM njord.report_default_period(
	    'period-selection-test', 'uk_company', DATE '2025-06-30'
	)
    ) AND (
	SELECT period_id = 'past'
	FROM njord.report_default_period(
	    'period-selection-test', 'uk_company', DATE '2023-06-30'
	)
    ) AND (
	SELECT period_id = 'future'
	FROM njord.report_default_period(
	    'period-selection-test', 'uk_company', DATE '2026-06-30'
	)
    )
);

ROLLBACK;

SELECT pg_temp.assert_true(
    'ordinary period reports retain calendar-year and current-date defaults',
    EXISTS (
	SELECT 1
	FROM api.report_page('personal', 'profit-loss', NULL, NULL, NULL)
	WHERE component = 'page_context'
	  AND payload ->> 'from'
	      = date_trunc('year', CURRENT_DATE)::DATE::TEXT
	  AND payload ->> 'to' = CURRENT_DATE::TEXT
    )
);

SELECT pg_temp.assert_true(
    'currency reference data is loaded',
    EXISTS (SELECT 1 FROM asset WHERE id = 'GBP') AND
    EXISTS (SELECT 1 FROM asset WHERE id = 'USD')
);

-- A market observation is test data, never part of the production catalogue.
INSERT INTO valuations (date, src, dst, rate)
VALUES ('2020-03-31', 'USD', 'GBP', 1.232 ^ -1);

SELECT pg_temp.assert_true(
    'native amount labels follow the report currency and retain one unit',
    njord.native_amount_label(1, 'XAU', 'GBP') = '1.00 XAU'
    AND njord.native_amount_label(1, 'TWD', 'TWD') IS NULL
);

SELECT pg_temp.assert_true(
    'complete sums distinguish values, missing values, and no rows',
    (
	SELECT njord.sum_if_complete(value) = 3
	FROM (VALUES (1::NUMERIC), (2::NUMERIC)) AS values(value)
    ) AND (
	SELECT njord.sum_if_complete(value) IS NULL
	FROM (VALUES (1::NUMERIC), (NULL::NUMERIC)) AS values(value)
    ) AND (
	SELECT njord.sum_if_complete(value) = 0
	FROM (VALUES (1::NUMERIC)) AS values(value)
	WHERE FALSE
    )
);

SELECT pg_temp.assert_true(
    'USD valuation to GBP is loaded',
    EXISTS (
	SELECT 1
	FROM valuations
	WHERE src = 'USD' AND dst = 'GBP' AND round(rate, 5) = 0.81169
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO valuations (date, src, dst, rate)
	SELECT date, src, dst, rate
	FROM valuations
	LIMIT 1;

	RAISE EXCEPTION 'duplicate valuation was allowed';
    EXCEPTION WHEN unique_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'transaction preview rejects every non-object JSON root',
    NOT EXISTS (
        SELECT 1
        FROM (VALUES
            ('null'::JSONB), ('[]'::JSONB), ('"text"'::JSONB), ('42'::JSONB)
        ) AS malformed(payload)
        CROSS JOIN LATERAL api.preview_transaction(
            'personal', malformed.payload
        ) AS preview
        WHERE preview.valid
           OR preview.error_code IS DISTINCT FROM 'INVALID_TRANSACTION_SHAPE'
    )
);

DO $$
DECLARE
    rejected_constraint TEXT;
BEGIN
    BEGIN
        CALL open_account(
            'personal', 'Missing Opening Amount', '2026-08-16',
            'A', 'GBP', NULL
        );
        RAISE EXCEPTION 'a NULL opening amount was accepted';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS rejected_constraint = CONSTRAINT_NAME;
        IF rejected_constraint <> 'opening_balance_required' THEN
            RAISE;
        END IF;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'a rejected NULL opening amount leaves no account behind',
    NOT EXISTS (
        SELECT 1 FROM accts
        WHERE book_id = 'personal' AND id = 'Missing Opening Amount'
    )
);

DO $$
BEGIN
    BEGIN
        UPDATE xactions SET date = 'infinity'::TIMESTAMP
        WHERE book_id = 'taiwan-injection'
          AND xid = (
              SELECT min(xid) FROM xactions WHERE book_id = 'taiwan-injection'
          );
        RAISE EXCEPTION 'an infinite ledger date was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE valuations SET date = '-infinity'::TIMESTAMP
        WHERE (src, dst) = ('USD', 'GBP');
        RAISE EXCEPTION 'an infinite valuation date was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_business_profiles SET established_on = 'infinity'::DATE
        WHERE book_id = 'taiwan-injection';
        RAISE EXCEPTION 'an infinite Taiwan profile date was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE uk_company_profiles SET incorporated_on = '-infinity'::DATE
        WHERE book_id = 'uk-business';
        RAISE EXCEPTION 'an infinite UK profile date was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE panama_business_profiles SET incorporated_on = 'infinity'::DATE
        WHERE book_id = 'panama-property';
        RAISE EXCEPTION 'an infinite Panama profile date was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
        INSERT INTO taiwan_business_tax_periods (
            book_id, id, period_start, period_end, due_on, status
        ) VALUES (
            'taiwan-injection', 'overlap-business-tax',
            '2026-02-01', '2026-03-31', '2026-05-15', 'open'
        );
        RAISE EXCEPTION 'an overlapping Taiwan business-tax period was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_manufacturing_account_mappings
        SET cost_category = 'direct_labour'
        WHERE book_id = 'taiwan-injection' AND acct = 'ABS Resin Inventory';
        RAISE EXCEPTION 'an asset account was mapped as direct labour';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_manufacturing_cost_categories
        SET required_type = 'E'
        WHERE id = 'direct_material';
        RAISE EXCEPTION 'a manufacturing category invalidated existing mappings';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_inventory_items SET item_kind = 'raw_material'
        WHERE book_id = 'taiwan-injection' AND id = 'sensor-enclosure';
        RAISE EXCEPTION 'a finished product was changed beneath its BOM and run';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_equipment_assets SET equipment_kind = 'other'
        WHERE book_id = 'taiwan-injection' AND id = 'mould-enclosure';
        RAISE EXCEPTION 'a mould in use was changed to ordinary equipment';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_boms SET product_item_id = 'precision-gear'
        WHERE book_id = 'taiwan-injection' AND id = 'BOM-ENC-2026';
        RAISE EXCEPTION 'a BOM was moved away from an existing production run';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_inventory_movement_kinds SET quantity_direction = -1
        WHERE id = 'purchase';
        RAISE EXCEPTION 'a movement kind invalidated existing stock evidence';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE taiwan_business_tax_treatments SET direction = 'purchase'
        WHERE id = 'sale_standard';
        RAISE EXCEPTION 'a tax treatment invalidated existing invoices';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
        UPDATE accts SET account_kind = 'posting'
        WHERE book_id = 'taiwan-injection' AND id = 'IMM-180 Asset';
        SET CONSTRAINTS accts_preserve_taiwan_relations IMMEDIATE;
        RAISE EXCEPTION 'an equipment asset lost its fixed-asset account kind';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'Taiwan semantic reference and manufacturing contracts remain intact',
    NOT EXISTS (
        SELECT 1 FROM taiwan_business_tax_periods
        WHERE book_id = 'taiwan-injection' AND id = 'overlap-business-tax'
    )
    AND (SELECT required_type = 'A'
         FROM taiwan_manufacturing_cost_categories WHERE id = 'direct_material')
    AND (SELECT item_kind = 'finished_good'
         FROM taiwan_inventory_items
         WHERE book_id = 'taiwan-injection' AND id = 'sensor-enclosure')
    AND (SELECT equipment_kind = 'mould'
         FROM taiwan_equipment_assets
         WHERE book_id = 'taiwan-injection' AND id = 'mould-enclosure')
    AND (SELECT account_kind = 'fixed_asset'
         FROM accts
         WHERE book_id = 'taiwan-injection' AND id = 'IMM-180 Asset')
);

SELECT pg_temp.assert_true(
    'valuation dates and asset pairs are unique',
    NOT EXISTS (
	SELECT date, src, dst
	FROM valuations
	GROUP BY date, src, dst
	HAVING count(*) > 1
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO valuations (date, src, dst, rate)
	VALUES ('2026-01-01', 'EUR', 'GBP', NULL);

	RAISE EXCEPTION 'valuation without a rate was allowed';
    EXCEPTION WHEN not_null_violation THEN
	NULL;
    END;
END;
$$;

CREATE TEMP TABLE zero_opening_snapshot AS
SELECT count(*) AS transaction_count
FROM xactions
WHERE book_id = 'personal';

CALL open_account(
    'personal', 'Zero Opening Balance', '2026-08-16', 'A', 'GBP', 0
);

SELECT pg_temp.assert_true(
    'zero-balance account opening creates the account without a transaction',
    EXISTS (
	SELECT 1 FROM accts
	WHERE book_id = 'personal' AND id = 'Zero Opening Balance'
    )
    AND (SELECT count(*) FROM xactions WHERE book_id = 'personal')
	= (SELECT transaction_count FROM zero_opening_snapshot)
);

SELECT pg_temp.assert_true(
    'draft balance ignores incomplete, malformed, overflowing, and non-finite amounts',
    (
	SELECT jsonb_object_agg(asset, amount ORDER BY asset)
	    = '{"GBP": 2.00000}'::JSONB
	FROM api.transaction_draft_balance(
	    'personal',
	    '[
	      {"account":"Uncategorised Expenses","amount":"-2"},
	      {"account":"Uncategorised Expenses","amount":"-"},
	      {"account":"Uncategorised Expenses","amount":"NaN"},
	      {"account":"Uncategorised Expenses","amount":"Infinity"},
	      {"account":"Uncategorised Expenses","amount":"1e500"},
	      {"account":"Uncategorised Expenses","amount":""},
	      {"account":"Uncategorised Expenses"},
	      {"account":"","amount":"3"},
	      null
	    ]'::JSONB
	)
    )
);

UPDATE accts
SET pretax = 0
WHERE book_id = 'personal' AND id = 'Zero Opening Balance';

DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET pretax = -0.01
	WHERE book_id = 'personal' AND id = 'Zero Opening Balance';
	RAISE EXCEPTION 'negative pretax factor was accepted';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts
	SET pretax = 'NaN'::NUMERIC
	WHERE book_id = 'personal' AND id = 'Zero Opening Balance';
	RAISE EXCEPTION 'non-finite pretax factor was accepted';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'pretax permits zero but rejects negative and non-finite factors',
    (
	SELECT pretax = 0
	FROM accts
	WHERE book_id = 'personal' AND id = 'Zero Opening Balance'
    )
);

SELECT pg_temp.assert_true(
    'direct transaction elements call line descriptions memos',
    (
	SELECT array_agg(attribute.attname::TEXT ORDER BY attribute.attnum)
	    = ARRAY['acct', 'amt', 'memo']::TEXT[]
	FROM pg_attribute AS attribute
	WHERE attribute.attrelid = 'xaction_elem'::regclass
	  AND attribute.attnum > 0
	  AND NOT attribute.attisdropped
    )
);

SELECT pg_temp.assert_true(
    'valuations require a rate',
    NOT EXISTS (SELECT 1 FROM valuations WHERE rate IS NULL)
);

DO $$
BEGIN
    BEGIN
	INSERT INTO valuations (date, src, dst, rate)
	VALUES ('2026-01-02', 'EUR', 'GBP', 0);

	RAISE EXCEPTION 'zero valuation rate was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO valuations (date, src, dst, rate)
	VALUES ('2026-01-03', 'EUR', 'GBP', -1);

	RAISE EXCEPTION 'negative valuation rate was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO valuations (date, src, dst, rate)
	VALUES ('2026-01-04', 'EUR', 'GBP', 'NaN');

	RAISE EXCEPTION 'non-finite valuation rate was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'valuation rates are positive and finite',
    NOT EXISTS (
	SELECT 1
	FROM valuations
	WHERE rate <= 0
	   OR rate::TEXT IN ('NaN', 'Infinity', '-Infinity')
    )
);

INSERT INTO books (id, name, reporting_asset)
VALUES ('hierarchy-test', 'Account Hierarchy Test', 'GBP');

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('hierarchy-test', 'Assets', 'Assets', 'A', 'GBP', NULL, 'root', TRUE),
    ('hierarchy-test', 'Liabilities', 'Liabilities', 'L', 'GBP', NULL, 'root', TRUE),
    ('hierarchy-test', 'Expenses', 'Expenses', 'E', 'GBP', NULL, 'root', TRUE),
    ('hierarchy-test', 'Fixed Assets', 'Fixed Assets', 'A', 'GBP', 'Assets', 'group', TRUE),
    ('hierarchy-test', 'Mortgages', 'Mortgages', 'L', 'GBP', 'Liabilities', 'group', TRUE),
    ('hierarchy-test', 'House', '12 Acacia Avenue', 'A', 'GBP', 'Fixed Assets', 'fixed_asset', FALSE),
    ('hierarchy-test', 'Mortgage', '12 Acacia Avenue', 'L', 'GBP', 'Mortgages', 'loan', FALSE),
    ('hierarchy-test', 'Bank', NULL, 'A', 'GBP', 'Assets', 'bank', FALSE),
    ('hierarchy-test', 'Gold', 'Gold', 'A', 'XAU', 'Assets', 'investment', FALSE);

SELECT pg_temp.assert_true(
    'accounts form a same-class hierarchy and omitted names default to ids',
    EXISTS (
	SELECT 1
	FROM accts AS house
	JOIN accts AS fixed_assets
	  ON fixed_assets.book_id = house.book_id
	 AND fixed_assets.id = house.parent_id
	JOIN accts AS assets
	  ON assets.book_id = fixed_assets.book_id
	 AND assets.id = fixed_assets.parent_id
	WHERE house.book_id = 'hierarchy-test'
	  AND house.id = 'House'
	  AND house.type = fixed_assets.type
	  AND fixed_assets.type = assets.type
	  AND assets.account_kind = 'root'
	  AND assets.placeholder
    ) AND (
	SELECT name = id
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id = 'Bank'
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO accts (
	    book_id, id, name, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Second House', '12 Acacia Avenue', 'A', 'GBP',
	    'Fixed Assets', 'fixed_asset', FALSE
	);

	RAISE EXCEPTION 'duplicate sibling account name was allowed';
    EXCEPTION WHEN unique_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO accts (
	    book_id, id, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Other Asset Root', 'A', 'GBP', NULL, 'root', TRUE
	);

	RAISE EXCEPTION 'second class root was allowed';
    EXCEPTION WHEN unique_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO accts (
	    book_id, id, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Expense House', 'E', 'GBP', 'Expenses',
	    'fixed_asset', FALSE
	);

	RAISE EXCEPTION 'account kind was allowed with an incompatible class';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO accts (
	    book_id, id, name, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Colon Name', 'Bills:Electricity', 'E', 'GBP',
	    'Expenses', 'posting', FALSE
	);

	RAISE EXCEPTION 'account name containing the path separator was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO accts (
	    book_id, id, name, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Posting Group', 'Posting Group', 'A', 'GBP',
	    'Assets', 'group', FALSE
	);

	RAISE EXCEPTION 'group account accepted direct postings';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'roots, sibling names, and account-kind classes are constrained',
    NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id IN (
	      'Second House', 'Other Asset Root', 'Expense House', 'Colon Name',
	      'Posting Group'
	  )
    )
);

DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET parent_id = 'House'
	WHERE book_id = 'hierarchy-test'
	  AND id = 'Fixed Assets';

	RAISE EXCEPTION 'cyclic account hierarchy was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'account hierarchy rejects cycles',
    (
	SELECT parent_id = 'Assets'
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id = 'Fixed Assets'
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO accts (
	    book_id, id, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Misplaced Expense', 'E', 'GBP', 'Assets',
	    'posting', FALSE
	);

	RAISE EXCEPTION 'cross-class account parent was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'account hierarchy rejects cross-class parents',
    NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id = 'Misplaced Expense'
    )
);

INSERT INTO books (id, name, reporting_asset)
VALUES ('hierarchy-other', 'Other Hierarchy Test', 'GBP');

INSERT INTO accts (
    book_id, id, type, atype, parent_id, account_kind, placeholder
) VALUES (
    'hierarchy-other', 'Other Assets', 'A', 'GBP', NULL, 'root', TRUE
);

DO $$
BEGIN
    BEGIN
	INSERT INTO accts (
	    book_id, id, type, atype, parent_id, account_kind, placeholder
	) VALUES (
	    'hierarchy-test', 'Cross-book Child', 'A', 'GBP', 'Other Assets',
	    'posting', FALSE
	);

	RAISE EXCEPTION 'cross-book account parent was allowed';
    EXCEPTION WHEN foreign_key_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'account parents are scoped to the same book',
    NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id = 'Cross-book Child'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('hierarchy-test', '2026-01-01', 'Placeholder test')
    RETURNING xid INTO test_xid;

    BEGIN
	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES ('hierarchy-test', test_xid, 'Fixed Assets', 1);

	RAISE EXCEPTION 'posting to placeholder account was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    DELETE FROM xactions
    WHERE book_id = 'hierarchy-test'
      AND xid = test_xid;
END;
$$;

SELECT pg_temp.assert_true(
    'placeholder accounts reject postings',
    NOT EXISTS (
	SELECT 1
	FROM xaction_bits
	WHERE book_id = 'hierarchy-test'
	  AND acct = 'Fixed Assets'
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO cash_accounts (book_id, acct)
	VALUES ('hierarchy-test', 'Assets');

	RAISE EXCEPTION 'placeholder root was marked as cash';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'cash accounts must be non-placeholder assets',
    NOT EXISTS (
	SELECT 1
	FROM cash_accounts
	WHERE book_id = 'hierarchy-test'
	  AND acct = 'Assets'
    )
);

CALL create_simple_xaction(
    'hierarchy-test',
    '2026-01-02',
    'House',
    'Bank',
    300000
);

DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET placeholder = TRUE
	WHERE book_id = 'hierarchy-test'
	  AND id = 'House';

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'posted account became a placeholder';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'accounts with postings cannot become placeholders',
    NOT (
	SELECT placeholder
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id = 'House'
    )
);

INSERT INTO account_valuations (book_id, acct, date, dst, value, comment)
VALUES (
    'hierarchy-test', 'House', '2026-08-07', 'GBP', 425000,
    'Estate-agent estimate'
);

DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET account_kind = 'posting'
	WHERE book_id = 'hierarchy-test'
	  AND id = 'House';

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'valued fixed asset changed to a general posting account';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'valued accounts remain posting fixed assets',
    (
	SELECT account_kind = 'fixed_asset' AND NOT placeholder AND type = 'A'
	FROM accts
	WHERE book_id = 'hierarchy-test'
	  AND id = 'House'
    )
);

INSERT INTO valuations (date, src, dst, rate)
VALUES ('2026-08-07', 'XAU', 'GBP', 2500);

SELECT pg_temp.assert_true(
    'commodity accounts hold quantities valued by reusable unit rates',
    EXISTS (
	SELECT 1
	FROM accts
	JOIN valuations
	  ON valuations.src = accts.atype
	WHERE accts.book_id = 'hierarchy-test'
	  AND accts.id = 'Gold'
	  AND accts.atype = 'XAU'
	  AND valuations.dst = 'GBP'
	  AND valuations.rate = 2500
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO account_valuations (
	    book_id, acct, date, dst, value, comment
	) VALUES (
	    'hierarchy-test', 'House', '2026-08-07', 'GBP', 430000,
	    'Duplicate observation'
	);

	RAISE EXCEPTION 'duplicate account valuation was allowed';
    EXCEPTION WHEN unique_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO account_valuations (book_id, acct, date, dst, value)
	VALUES ('hierarchy-test', 'Missing House', '2026-08-07', 'GBP', 1);

	RAISE EXCEPTION 'valuation for a missing account was allowed';
    EXCEPTION WHEN foreign_key_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO account_valuations (book_id, acct, date, dst, value)
	VALUES ('hierarchy-test', 'House', '2026-08-07', 'NOT_AN_ASSET', 1);

	RAISE EXCEPTION 'valuation with a missing destination asset was allowed';
    EXCEPTION WHEN foreign_key_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO account_valuations (book_id, acct, date, dst, value)
	VALUES ('hierarchy-test', 'Gold', '2026-08-08', 'GBP', 1);

	RAISE EXCEPTION 'commodity account accepted a total account valuation';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO account_valuations (book_id, acct, date, dst, value)
	VALUES ('hierarchy-test', 'Fixed Assets', '2026-08-08', 'GBP', 1);

	RAISE EXCEPTION 'placeholder group accepted a total account valuation';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'account valuations are unique and reference real accounts and assets',
    (
	SELECT count(*) = 1 AND min(value) = 425000
	FROM account_valuations
	WHERE book_id = 'hierarchy-test'
	  AND acct = 'House'
	  AND date = '2026-08-07'
	  AND dst = 'GBP'
    )
);

SELECT pg_temp.assert_true(
    'total account valuations belong only to posting fixed assets',
    NOT EXISTS (
	SELECT 1
	FROM account_valuations
	JOIN accts
	  ON accts.book_id = account_valuations.book_id
	 AND accts.id = account_valuations.acct
	WHERE accts.type <> 'A'
	   OR accts.account_kind <> 'fixed_asset'
	   OR accts.placeholder
    )
);

INSERT INTO accts (book_id, id, type, atype, parent_id)
VALUES ('personal', 'USD Expenses', 'E', 'USD', 'Expenses');

CALL open_account('personal', 'Broker USD', '2026-01-01', 'A', 'USD', 123.20);
CALL open_account('personal', 'Current GBP', '2026-01-01', 'A', 'GBP', 50.00);

INSERT INTO cash_accounts (book_id, acct)
VALUES ('personal', 'Current GBP');

DO $$
BEGIN
    BEGIN
	INSERT INTO cash_accounts (book_id, acct)
	VALUES ('personal', 'Expenses');

	RAISE EXCEPTION 'expense account was marked as cash';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'cash accounts must be asset accounts',
    NOT EXISTS (
	SELECT 1
	FROM cash_accounts
	WHERE book_id = 'personal'
	  AND acct = 'Expenses'
    )
);

DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET type = 'E'
	WHERE book_id = 'personal'
	  AND id = 'Current GBP';

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'a referenced cash account changed to a non-asset type';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'cash account types remain protected after account updates',
    (
	SELECT type = 'A'
	FROM accts
	WHERE book_id = 'personal'
	  AND id = 'Current GBP'
    )
);

SELECT pg_temp.assert_true(
    'open_account creates the asset account',
    EXISTS (
	SELECT 1
	FROM accts
	WHERE book_id = 'personal'
	  AND id = 'Broker USD'
	  AND type = 'A'
	  AND atype = 'USD'
    )
);

SELECT pg_temp.assert_true(
    'open_account creates a balanced two-line transaction',
    (
	SELECT count(*) = 2 AND sum(amt) = 0
	FROM xaction_bits
	WHERE book_id = 'personal'
	  AND xid = (
	    SELECT max(xid)
	    FROM xactions
	    WHERE book_id = 'personal'
	)
    )
);

CALL create_simple_xaction(
    'personal',
    '2026-01-15',
    'Broker USD',
    'USD Expenses',
    -23.20
);

SELECT pg_temp.assert_true(
    'ledger reports account entries',
    (
	SELECT count(*) = 2 AND sum(amt) = 100.00
	FROM ledger('personal', 'Broker USD')
    )
);

SELECT pg_temp.assert_true(
    'general_journal reports debit and credit lines',
    EXISTS (
	SELECT 1
	FROM general_journal
	WHERE book_id = 'personal'
	  AND date = '2026-01-15'
	  AND account = 'USD Expenses'
	  AND line_order = 1
	  AND debit = 23.20
	  AND credit IS NULL
	  AND memo IS NULL
    ) AND EXISTS (
	SELECT 1
	FROM general_journal
	WHERE book_id = 'personal'
	  AND date = '2026-01-15'
	  AND account = 'Broker USD'
	  AND line_order = 2
	  AND debit IS NULL
	  AND credit = 23.20
	  AND memo IS NULL
    )
);

SELECT pg_temp.assert_true(
    'bsheet_report is the dated, currency-aware Balance Sheet surface',
    EXISTS (
	SELECT 1
	FROM bsheet_report('personal', '2026-01-31')
	WHERE row_kind = 'account'
	  AND account = 'Broker USD'
	  AND posttax = 81.17
    ) AND EXISTS (
	SELECT 1
	FROM bsheet_report('personal', '2026-01-31')
	WHERE row_kind = 'account'
	  AND account = 'Current GBP'
	  AND posttax = 50.00
    ) AND
    EXISTS (
	SELECT 1
	FROM bsheet_report('personal', '2026-01-31')
	WHERE section = 'Assets'
	  AND row_kind = 'section_total'
	  AND account = 'Total Assets'
    ) AND EXISTS (
	SELECT 1
	FROM bsheet_report('personal', '2026-01-31')
	WHERE row_kind = 'grand_total'
	  AND account = 'Total Liabilities and Equity'
    )
);

SELECT pg_temp.assert_true(
    'net_worth_report uses account estimates and commodity unit rates',
    EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'account'
	  AND account = 'Assets › Fixed Assets › 12 Acacia Avenue'
	  AND native_balance = 325000
	  AND posttax = 425000
	  AND valuation_date = '2026-08-01'
	  AND valuation_source = 'Account estimate'
    ) AND EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'account'
	  AND account = 'Assets › Investments › Gold Bullion'
	  AND commodity = 'XAU'
	  AND native_balance = 5
	  AND posttax = 13100
	  AND valuation_source = 'Unit rate'
    )
);

SELECT pg_temp.assert_true(
    'net_worth_report deducts liabilities from current asset values',
    EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'section_total'
	  AND account = 'Total Assets'
	  AND posttax = 491701.55
    ) AND EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'section_total'
	  AND account = 'Total Liabilities'
	  AND posttax = 246713.20
    ) AND EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'grand_total'
	  AND account = 'Net Worth'
	  AND posttax = 244988.35
    )
);

SELECT pg_temp.assert_true(
    'net_worth_report never uses a future valuation',
    EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-07-31')
	WHERE account = 'Assets › Fixed Assets › 12 Acacia Avenue'
	  AND posttax = 325000
	  AND valuation_date IS NULL
	  AND valuation_source = 'Book value fallback'
    ) AND EXISTS (
	SELECT 1
	FROM net_worth_report('demo', '2026-07-31')
	WHERE account = 'Assets › Investments › Gold Bullion'
	  AND posttax = 10500
	  AND valuation_date = '2026-01-01'
    )
);

SELECT pg_temp.assert_true(
    'hierarchical statements expose visibly nested account rows and group totals',
    EXISTS (
	SELECT 1
	FROM hierarchical_net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'group'
	  AND account = 'Assets'
	  AND depth = 0
	  AND posttax = 491701.55
    ) AND EXISTS (
	SELECT 1
	FROM hierarchical_net_worth_report('demo', '2026-08-06')
	WHERE row_kind = 'account'
	  AND account = '12 Acacia Avenue'
	  AND depth = 2
	  AND posttax = 425000
    ) AND EXISTS (
	SELECT 1
	FROM hierarchical_balance_sheet_report('demo', '2026-08-06')
	WHERE row_kind = 'group'
	  AND account = 'Fixed Assets'
	  AND depth = 1
	  AND posttax = 325000
    ) AND EXISTS (
	SELECT 1
	FROM hierarchical_profit_loss_report(
	    'demo', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'group'
	  AND account = 'Utilities'
	  AND depth = 2
	  AND posttax = 234
    )
);

BEGIN;

DO $$
BEGIN
    PERFORM * FROM api.create_book(
	'net-worth-identity', 'Net Worth identity', 'GBP', TRUE, 'household'
    );
END;
$$;

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES (
    'net-worth-identity', 'stable-asset', 'Original label',
    'A', 'GBP', 'Assets', 'posting', FALSE
);

CALL create_xaction(
    'net-worth-identity',
    '2026-01-01',
    ROW('stable-asset', 100, NULL)::xaction_elem,
    ROW('Opening Balance', -100, NULL)::xaction_elem
);

UPDATE accts
SET name = 'Renamed label'
WHERE book_id = 'net-worth-identity' AND id = 'stable-asset';

SELECT pg_temp.assert_true(
    'Net Worth carries stable account identity independently of its mutable path',
    EXISTS (
	SELECT 1
	FROM njord.net_worth_account_values(
	    'net-worth-identity', '2026-12-31'
	)
	WHERE account_id = 'stable-asset'
	  AND account_path = 'Assets › Renamed label'
    ) AND EXISTS (
	SELECT 1
	FROM hierarchical_net_worth_report(
	    'net-worth-identity', '2026-12-31'
	)
	WHERE row_kind = 'account'
	  AND account_id = 'stable-asset'
	  AND account = 'Renamed label'
    )
);

ROLLBACK;

SELECT pg_temp.assert_true(
    'net worth history returns twelve chronological statement snapshots',
    (
	SELECT count(*) = 12
	    AND min(period_end) = '2025-09-30'
	    AND max(period_end) = '2026-08-06'
	FROM net_worth_history('demo', '2026-08-06', 12)
    ) AND EXISTS (
	SELECT 1
	FROM net_worth_history('demo', '2026-08-06', 12)
	WHERE period_end = '2026-08-06'
	  AND assets = 491701.55
	  AND liabilities = 246713.20
	  AND net_worth = 244988.35
    )
);

SELECT pg_temp.assert_true(
    'report presentation is catalogued in SQL for the generic renderer',
    (SELECT count(*) = 38 FROM report_catalog)
    AND NOT EXISTS (
	SELECT report_id
	FROM report_catalog
	WHERE NOT EXISTS (
	    SELECT 1
	    FROM report_columns
	    WHERE report_columns.report_id = report_catalog.report_id
	)
    )
    AND EXISTS (
	SELECT 1
	FROM report_columns
	WHERE report_id = 'net-worth'
	  AND column_id = 'account'
	  AND tree_column
    )
    AND EXISTS (
	SELECT 1
	FROM report_bar_charts
	WHERE report_id = 'net-worth'
	  AND chart_id = 'net-worth-history'
    )
);

SELECT pg_temp.assert_true(
    'UK company demo has a balanced, richly populated preparation ledger',
    EXISTS (
	SELECT 1
	FROM uk_company_profiles
	WHERE book_id = 'uk-business'
	  AND legal_name = 'Acacia Digital Ltd'
	  AND accounting_framework = 'frs105'
	  AND vat_scheme = 'standard_invoice'
    )
    AND (SELECT count(*) >= 25 FROM xactions WHERE book_id = 'uk-business')
    AND (SELECT count(*) = 9 FROM trade_invoices WHERE book_id = 'uk-business')
    AND (SELECT COALESCE(sum(amt), 0) = 0 FROM xaction_bits WHERE book_id = 'uk-business')
    AND (
	SELECT sum(bits.amt) = 7737
	FROM xaction_bits AS bits
	WHERE bits.book_id = 'uk-business' AND bits.acct = 'Business Bank'
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO uk_accounting_periods (
	    book_id, id, period_start, period_end, status
	) VALUES (
	    'uk-business', 'overlap-test', '2026-06-01', '2027-05-31', 'open'
	);
	RAISE EXCEPTION 'overlapping UK accounting period was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE uk_account_statutory_mappings
	SET line_id = 'turnover'
	WHERE book_id = 'uk-business' AND acct = 'Business Bank';
	RAISE EXCEPTION 'asset account accepted an income statutory mapping';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE trade_invoice_allocations
	SET amount = 6001
	WHERE book_id = 'uk-business' AND invoice_id = 'sale-1001';
	SET CONSTRAINTS trade_invoice_allocations_limits IMMEDIATE;
	RAISE EXCEPTION 'trade invoice was over-allocated';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'UK preparation mappings and trade schedules enforce their data contract',
    NOT EXISTS (
	SELECT 1 FROM uk_accounting_periods
	WHERE book_id = 'uk-business' AND id = 'overlap-test'
    )
    AND EXISTS (
	SELECT 1 FROM uk_account_statutory_mappings
	WHERE book_id = 'uk-business'
	  AND acct = 'Business Bank'
	  AND line_id = 'cash_at_bank_and_in_hand'
    )
    AND EXISTS (
	SELECT 1 FROM trade_invoice_allocations
	WHERE book_id = 'uk-business'
	  AND invoice_id = 'sale-1001'
	  AND amount = 6000
    )
);

DO $$
DECLARE
    small_xid INTEGER;
BEGIN
    BEGIN
	INSERT INTO trade_invoices (
	    book_id, id, party_id, direction, invoice_number, issued_on, due_on,
	    xid, control_acct
	)
	SELECT
	    book_id, 'duplicate-posting-test', party_id, direction, 'DUPLICATE',
	    issued_on, due_on, xid, control_acct
	FROM trade_invoices
	WHERE book_id = 'uk-business' AND id = 'sale-1001';
	RAISE EXCEPTION 'one invoice posting was referenced twice';
    EXCEPTION WHEN unique_violation THEN
	NULL;
    END;

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-08-04', 'Small invoice repoint test')
    RETURNING xid INTO small_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('uk-business', small_xid, 'Trade Debtors', 100),
	('uk-business', small_xid, 'Consultancy Revenue', -83.33),
	('uk-business', small_xid, 'VAT Control', -16.67);

    BEGIN
	UPDATE trade_invoices
	SET xid = small_xid, issued_on = '2026-08-04', due_on = '2026-09-03'
	WHERE book_id = 'uk-business' AND id = 'sale-1001';
	RAISE EXCEPTION 'allocated invoice was repointed to a smaller posting';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    DELETE FROM xaction_bits WHERE book_id = 'uk-business' AND xid = small_xid;
    DELETE FROM xactions WHERE book_id = 'uk-business' AND xid = small_xid;
END;
$$;

SELECT pg_temp.assert_true(
    'one invoice owns one control posting and allocated invoices cannot shrink',
    NOT EXISTS (
	SELECT 1 FROM trade_invoices
	WHERE book_id = 'uk-business' AND id = 'duplicate-posting-test'
    )
    AND EXISTS (
	SELECT 1
	FROM trade_invoices AS invoices
	JOIN xaction_bits AS bits
	  ON bits.book_id = invoices.book_id
	 AND bits.xid = invoices.xid
	 AND bits.acct = invoices.control_acct
	WHERE invoices.book_id = 'uk-business'
	  AND invoices.id = 'sale-1001'
	  AND bits.amt = 6000
    )
);

SELECT pg_temp.assert_true(
    'UK statutory statements reconcile mapped ledger values',
    EXISTS (
	SELECT 1
	FROM uk_statutory_statement_values(
	    'uk-business', 'profit_loss', '2026-01-01', '2026-12-31 23:59:59.999999'
	)
	WHERE line_id = 'turnover' AND amount = 15300
    )
    AND EXISTS (
	SELECT 1
	FROM uk_statutory_statement_values(
	    'uk-business', 'profit_loss', '2026-01-01', '2026-12-31 23:59:59.999999'
	)
	WHERE line_id = 'profit_loss_after_tax' AND amount = 2395
    )
    AND EXISTS (
	SELECT 1
	FROM uk_statutory_statement_values(
	    'uk-business', 'balance_sheet', NULL, '2026-12-31 23:59:59.999999'
	)
	WHERE line_id = 'net_assets_liabilities' AND amount = 2495
    )
    AND EXISTS (
	SELECT 1
	FROM uk_statutory_statement_values(
	    'uk-business', 'balance_sheet', NULL, '2026-12-31 23:59:59.999999'
	)
	WHERE line_id = 'shareholders_funds' AND amount = 2495
    )
);

SELECT pg_temp.assert_true(
    'UK company report availability and period defaults are database-owned',
    (
	SELECT count(*) = 5
	FROM api.reports_page('personal')
	WHERE component = 'report_option'
    )
    AND (
	SELECT count(*) = 16
	FROM api.reports_page('uk-business')
	WHERE component = 'report_option'
    )
    AND (
	SELECT count(DISTINCT payload ->> 'report_group') = 4
	FROM api.reports_page('uk-business')
	WHERE component = 'report_option'
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page('uk-business', 'corporation-tax', NULL, NULL, NULL)
	WHERE component = 'page_context'
	  AND payload ->> 'from' = '2026-01-01'
	  AND payload ->> 'to' = '2026-12-31'
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page('uk-business', 'uk-statutory-balance-sheet', NULL, NULL, NULL)
	WHERE component = 'page_context'
	  AND payload ->> 'as_of' = '2026-12-31'
    )
);

UPDATE uk_company_profiles
SET vat_scheme = 'flat_rate'
WHERE book_id = 'uk-business';

SELECT pg_temp.assert_true(
    'unsupported VAT schemes show a blocker without standard-scheme figures',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'uk-business', 'vat-return', NULL, '2026-01-01', '2026-12-31'
	)
	WHERE component = 'page_context'
	  AND payload ->> 'validation_messages' LIKE '%standard invoice scheme only%'
    )
    AND NOT EXISTS (
	SELECT 1
	FROM api.report_page(
	    'uk-business', 'vat-return', NULL, '2026-01-01', '2026-12-31'
	)
	WHERE component = 'generic_report_row'
    )
);

UPDATE uk_company_profiles
SET vat_scheme = 'standard_invoice'
WHERE book_id = 'uk-business';

SELECT pg_temp.assert_true(
    'UK Corporation Tax and changes-in-equity working papers reconcile',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'uk-business', 'corporation-tax', NULL, '2026-01-01', '2026-12-31'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND report.row_key = 'corporation-tax:taxable-profit-before-allowances'
	  AND cell ->> 'column_id' = 'amount'
	  AND (cell ->> 'number')::NUMERIC = 3245
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'uk-business', 'changes-in-equity', NULL, '2026-01-01', '2026-12-31'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND report.row_key = 'changes-in-equity:equity_contributions'
	  AND cell ->> 'column_id' = 'amount'
	  AND (cell ->> 'number')::NUMERIC = 100
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'uk-business', 'changes-in-equity', NULL, '2026-01-01', '2026-12-31'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND report.row_key = 'changes-in-equity:equity_closing'
	  AND cell ->> 'column_id' = 'amount'
	  AND (cell ->> 'number')::NUMERIC = 2495
    )
);

SELECT pg_temp.assert_true(
    'UK VAT return reconciles the demo VAT control activity',
    NOT EXISTS (
	SELECT 1
	FROM (VALUES
	    (1, 3060::NUMERIC), (4, 968::NUMERIC), (5, 2092::NUMERIC),
	    (6, 15300::NUMERIC), (7, 5340::NUMERIC)
	) AS expected(box_number, amount)
	WHERE NOT EXISTS (
	    SELECT 1
	    FROM api.report_page(
		'uk-business', 'vat-return', NULL, '2026-01-01', '2026-12-31'
	    ) AS report
	    CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	    WHERE report.component = 'generic_report_row'
	      AND report.row_key = 'vat-return:box-' || expected.box_number
	      AND cell ->> 'column_id' = 'amount'
	      AND (cell ->> 'number')::NUMERIC = expected.amount
	)
    )
    AND NOT EXISTS (
	SELECT 1
	FROM (VALUES
	    ('vat-control-mapped'::VARCHAR, 2092::NUMERIC),
	    ('vat-control-difference', 0::NUMERIC),
	    ('vat-control-closing', 2092::NUMERIC)
	) AS expected(row_id, amount)
	WHERE NOT EXISTS (
	    SELECT 1
	    FROM api.report_page(
		'uk-business', 'vat-return', NULL, '2026-01-01', '2026-12-31'
	    ) AS report
	    CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	    WHERE report.component = 'generic_report_row'
	      AND report.row_key = 'vat-return:' || expected.row_id
	      AND cell ->> 'column_id' = 'amount'
	      AND (cell ->> 'number')::NUMERIC = expected.amount
	)
    )
);

DO $$
DECLARE
    credit_xid INTEGER;
    output_vat NUMERIC;
    output_net NUMERIC;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-08-01', 'VAT credit-note sign test')
    RETURNING xid INTO credit_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('uk-business', credit_xid, 'Trade Debtors', -120),
	('uk-business', credit_xid, 'Consultancy Revenue', 100),
	('uk-business', credit_xid, 'VAT Control', 20);

    SELECT
	COALESCE(sum(vat_amount) FILTER (WHERE tax_box = 1), 0),
	COALESCE(sum(net_amount) FILTER (WHERE net_box = 6), 0)
    INTO output_vat, output_net
    FROM uk_vat_posting_values(
	'uk-business', '2026-01-01', '2026-12-31 23:59:59.999999'
    );

    IF output_vat <> 3040 OR output_net <> 15200 THEN
	RAISE EXCEPTION 'VAT credit note increased the return (% / %)',
	    output_vat, output_net;
    END IF;

    DELETE FROM xaction_bits
    WHERE book_id = 'uk-business' AND xid = credit_xid;
    DELETE FROM xactions
    WHERE book_id = 'uk-business' AND xid = credit_xid;
END;
$$;

SELECT pg_temp.assert_true(
    'VAT credit notes and reversals reduce return boxes',
    NOT EXISTS (
	SELECT 1 FROM xactions
	WHERE book_id = 'uk-business' AND comment = 'VAT credit-note sign test'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
    subtotal NUMERIC;
    pbt NUMERIC;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-08-02', 'Corporation Tax loss test')
    RETURNING xid INTO test_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('uk-business', test_xid, 'Salaries', 10000),
	('uk-business', test_xid, 'Business Bank', -10000);

    SELECT (cell ->> 'number')::NUMERIC
    INTO subtotal
    FROM uk_company_report_rows(
	'uk-business', 'corporation-tax', '2026-12-31 23:59:59.999999',
	'2026-01-01', '2026-12-31 23:59:59.999999'
    ) AS report
    CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
    WHERE report.row_key = 'taxable-profit-before-allowances'
      AND cell ->> 'column_id' = 'amount';

    IF subtotal <> -6755 THEN
	RAISE EXCEPTION 'Corporation Tax loss was not preserved (%)', subtotal;
    END IF;

    DELETE FROM xaction_bits WHERE book_id = 'uk-business' AND xid = test_xid;
    DELETE FROM xactions WHERE book_id = 'uk-business' AND xid = test_xid;

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-08-03', 'Corporation Tax charge test')
    RETURNING xid INTO test_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('uk-business', test_xid, 'Corporation Tax Expense', 500),
	('uk-business', test_xid, 'Corporation Tax Payable', -500);

    SELECT amount INTO pbt
    FROM uk_statutory_statement_values(
	'uk-business', 'profit_loss', '2026-01-01', '2026-12-31 23:59:59.999999'
    )
    WHERE line_id = 'profit_loss_before_tax';

    SELECT (cell ->> 'number')::NUMERIC
    INTO subtotal
    FROM uk_company_report_rows(
	'uk-business', 'corporation-tax', '2026-12-31 23:59:59.999999',
	'2026-01-01', '2026-12-31 23:59:59.999999'
    ) AS report
    CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
    WHERE report.row_key = 'taxable-profit-before-allowances'
      AND cell ->> 'column_id' = 'amount';

    IF pbt <> 2395 OR subtotal <> 3245 THEN
	RAISE EXCEPTION 'Corporation Tax charge changed PBT/subtotal (% / %)',
	    pbt, subtotal;
    END IF;

    DELETE FROM xaction_bits WHERE book_id = 'uk-business' AND xid = test_xid;
    DELETE FROM xactions WHERE book_id = 'uk-business' AND xid = test_xid;
END;
$$;

DELETE FROM uk_account_statutory_mappings
WHERE book_id = 'uk-business' AND acct = 'Product Revenue';

SELECT pg_temp.assert_true(
    'Corporation Tax fails closed when statutory PBT mapping is incomplete',
    EXISTS (
	SELECT 1
	FROM njord.uk_report_validation_messages(
	    'corporation-tax', 'uk-business', '2026-01-01', '2026-12-31'
	) AS message
	WHERE message::TEXT LIKE '%statutory P&L mapping%'
    )
    AND EXISTS (
	SELECT 1
	FROM uk_company_report_rows(
	    'uk-business', 'corporation-tax', '2026-12-31 23:59:59.999999',
	    '2026-01-01', '2026-12-31 23:59:59.999999'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.row_key = 'taxable-profit-before-allowances'
	  AND cell ->> 'column_id' = 'amount'
	  AND cell -> 'number' = 'null'::JSONB
    )
);

INSERT INTO uk_account_statutory_mappings (book_id, acct, line_id)
VALUES ('uk-business', 'Product Revenue', 'turnover');

SELECT pg_temp.assert_true(
    'Corporation Tax periods over twelve months are blocked',
    NOT EXISTS (
	SELECT 1
	FROM uk_company_report_rows(
	    'uk-business', 'corporation-tax', '2027-01-01 23:59:59.999999',
	    '2026-01-01', '2027-01-01 23:59:59.999999'
	)
    )
    AND njord.uk_report_validation_messages(
	'corporation-tax', 'uk-business', '2026-01-01', '2027-01-01'
    )::TEXT LIKE '%cannot exceed twelve months%'
);

DO $$
DECLARE
    dividend_xid INTEGER;
    distribution NUMERIC;
    closing_equity NUMERIC;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-08-05', 'Dividend classification test')
    RETURNING xid INTO dividend_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('uk-business', dividend_xid, 'Retained Earnings', 500),
	('uk-business', dividend_xid, 'Business Bank', -500);

    SELECT
	max((cell ->> 'number')::NUMERIC)
	    FILTER (WHERE report.row_key = 'equity_distributions'),
	max((cell ->> 'number')::NUMERIC)
	    FILTER (WHERE report.row_key = 'equity_closing')
    INTO distribution, closing_equity
    FROM uk_company_report_rows(
	'uk-business', 'changes-in-equity', '2026-12-31 23:59:59.999999',
	'2026-01-01', '2026-12-31 23:59:59.999999'
    ) AS report
    CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
    WHERE cell ->> 'column_id' = 'amount';

    IF distribution <> -500 OR closing_equity <> 1995 THEN
	RAISE EXCEPTION 'dividend equity movement was misclassified (% / %)',
	    distribution, closing_equity;
    END IF;

    DELETE FROM xaction_bits WHERE book_id = 'uk-business' AND xid = dividend_xid;
    DELETE FROM xactions WHERE book_id = 'uk-business' AND xid = dividend_xid;
END;
$$;

SELECT pg_temp.assert_true(
    'Balance-Sheet retained earnings mapping also classifies dividend movements',
    NOT EXISTS (
	SELECT 1 FROM xactions
	WHERE book_id = 'uk-business' AND comment = 'Dividend classification test'
    )
);

SELECT pg_temp.assert_true(
    'UK aged and fixed-asset supporting schedules use authoritative postings',
    (
	SELECT sum((cell ->> 'number')::NUMERIC) = 6360
	FROM api.report_page(
	    'uk-business', 'aged-debtors', '2026-08-08', NULL, NULL
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND cell ->> 'column_id' = 'total'
    )
    AND (
	SELECT sum((cell ->> 'number')::NUMERIC) = 2760
	FROM api.report_page(
	    'uk-business', 'aged-creditors', '2026-08-08', NULL, NULL
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND cell ->> 'column_id' = 'total'
    )
    AND (
	SELECT sum((cell ->> 'number')::NUMERIC) = 1250
	FROM api.report_page(
	    'uk-business', 'fixed-asset-schedule', NULL, '2026-01-01', '2026-12-31'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND cell ->> 'column_id' = 'closing'
    )
);

SELECT pg_temp.assert_true(
    'semantic UK facts remain a clearly separate future-tagging surface',
    EXISTS (
	SELECT 1
	FROM uk_ixbrl_facts('uk-business', '2026-01-01', '2026-12-31')
	WHERE concept_id = 'njord-uk:profit_loss_after_tax'
	  AND numeric_value = 2395
    )
    AND EXISTS (
	SELECT 1
	FROM uk_ixbrl_facts('uk-business', '2026-01-01', '2026-12-31')
	WHERE concept_id = 'njord-uk:EntityCurrentLegalName'
	  AND text_value = 'Acacia Digital Ltd'
    )
);

SELECT pg_temp.assert_true(
    'Panama residential-property demo keeps business and property accounting facts separate',
    EXISTS (
	SELECT 1
	FROM panama_business_profiles
	WHERE book_id = 'panama-property'
	  AND legal_name = 'Bahia Verde Rentals, S.A.'
    )
    AND EXISTS (
	SELECT 1
	FROM panama_residential_property_profiles
	WHERE book_id = 'panama-property'
    )
    AND (SELECT count(*) = 1 FROM panama_properties WHERE book_id = 'panama-property')
    AND (SELECT count(*) = 3 FROM panama_property_units WHERE book_id = 'panama-property')
    AND (SELECT count(*) = 3 FROM panama_leases WHERE book_id = 'panama-property')
    AND (SELECT count(*) = 4 FROM panama_reportable_payments WHERE book_id = 'panama-property')
    AND (SELECT COALESCE(sum(amt), 0) = 0 FROM xaction_bits WHERE book_id = 'panama-property')
);

SELECT pg_temp.assert_true(
    'Panama reports are database-defined fact summaries through the generic renderer',
    (SELECT count(*) = 10 FROM panama_report_catalog)
    AND NOT EXISTS (
	SELECT report_id
	FROM panama_report_catalog AS catalog
	WHERE NOT EXISTS (
	    SELECT 1
	    FROM panama_report_rows(
		'panama-property', catalog.report_id,
		'2026-08-08 23:59:59.999999',
		'2026-01-01', '2026-12-31 23:59:59.999999'
	    )
	)
    )
    AND (
	SELECT count(*) = 15
	FROM api.reports_page('panama-property')
	WHERE component = 'report_option'
    )
    AND NOT EXISTS (
	SELECT 1
	FROM api.reports_page('personal')
	WHERE component = 'report_option'
	  AND payload ->> 'id' LIKE 'panama-%'
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'panama-property', 'panama-rent-roll', '2026-08-08', NULL, NULL
	)
	WHERE component = 'generic_report_row'
    )
);

BEGIN;

DO $$
BEGIN
    PERFORM * FROM api.create_book(
	'panama-stock-value', 'Panama stock valuation', 'PAB', TRUE, 'company'
    );
    PERFORM * FROM api.configure_panama_business(
	p_book_id => 'panama-stock-value',
	p_legal_name => 'Panama Stock Valuation, S.A.',
	p_ruc => 'stock-value',
	p_legal_form => 'corporation',
	p_municipality => 'panama_district',
	p_period_id => '2040',
	p_period_start => DATE '2040-01-01',
	p_period_end => DATE '2040-12-31'
    );
END;
$$;

INSERT INTO valuations (date, src, dst, rate) VALUES
    ('2040-01-01', 'EUR', 'PAB', 2),
    ('2040-12-31', 'EUR', 'PAB', 3);

CALL open_account(
    'panama-stock-value', 'Foreign asset', '2040-01-01', 'A', 'EUR', 100
);

SELECT pg_temp.assert_true(
    'Panama Form 43 values asset stocks once at the report-date rate',
    EXISTS (
	SELECT 1
	FROM panama_report_rows(
	    'panama-stock-value', 'panama-form-43-threshold', NULL,
	    '2040-01-01', '2040-12-31 23:59:59.999999'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.row_key = 'total-assets'
	  AND cell ->> 'column_id' = 'actual'
	  AND (cell ->> 'number')::NUMERIC = 300
    )
);

ROLLBACK;

SELECT pg_temp.assert_true(
    'Panama rent roll contains only leases active on the as-of date',
    EXISTS (
	SELECT 1
	FROM panama_report_rows(
	    'panama-property', 'panama-rent-roll',
	    '2027-01-01', NULL, NULL
	)
	WHERE row_key = 'lease-9b-2026'
    )
    AND NOT EXISTS (
	SELECT 1
	FROM panama_report_rows(
	    'panama-property', 'panama-rent-roll',
	    '2027-01-01', NULL, NULL
	)
	WHERE row_key IN ('lease-8a-2026', 'lease-10c-summer')
    )
);

SELECT pg_temp.assert_true(
    'Taiwan injection-moulding demo separates business, stock, BOM, run, and equipment facts',
    EXISTS (
	SELECT 1
	FROM taiwan_business_profiles
	WHERE book_id = 'taiwan-injection'
	  AND legal_name = '福爾摩沙精密塑膠有限公司'
    )
    AND EXISTS (
	SELECT 1 FROM taiwan_manufacturing_profiles
	WHERE book_id = 'taiwan-injection'
    )
    AND (SELECT count(*) = 8 FROM taiwan_inventory_items WHERE book_id = 'taiwan-injection')
    AND (SELECT count(*) = 2 FROM taiwan_boms WHERE book_id = 'taiwan-injection')
    AND (SELECT count(*) = 2 FROM taiwan_production_runs WHERE book_id = 'taiwan-injection')
    AND (SELECT count(*) = 3 FROM taiwan_equipment_assets WHERE book_id = 'taiwan-injection')
    AND (SELECT COALESCE(sum(amt), 0) = 0 FROM xaction_bits WHERE book_id = 'taiwan-injection')
);

SELECT pg_temp.assert_true(
    'Taiwan reports are SQL-defined working papers exposed by the generic renderer',
    (SELECT count(*) = 12 FROM taiwan_report_catalog)
    AND NOT EXISTS (
	SELECT report_id
	FROM taiwan_report_catalog AS catalog
	WHERE NOT EXISTS (
	    SELECT 1
	    FROM taiwan_report_rows(
		'taiwan-injection', catalog.report_id,
		'2026-08-08 23:59:59.999999',
		'2026-01-01', '2026-12-31 23:59:59.999999'
	    )
	)
    )
    AND (
	SELECT count(*) = 17
	FROM api.reports_page('taiwan-injection')
	WHERE component = 'report_option'
    )
    AND NOT EXISTS (
	SELECT 1
	FROM api.reports_page('personal')
	WHERE component = 'report_option'
	  AND payload ->> 'id' LIKE 'taiwan-%'
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'taiwan-injection', 'taiwan-production-cost',
	    '2026-08-08', '2026-01-01', '2026-12-31'
	)
	WHERE component = 'generic_report_row'
    )
);

WITH aging AS (
    SELECT
	report.row_key,
	max((cell ->> 'number')::NUMERIC)
	    FILTER (WHERE cell ->> 'column_id' = 'gross') AS gross,
	max((cell ->> 'number')::NUMERIC)
	    FILTER (WHERE cell ->> 'column_id' = 'paid') AS paid,
	max((cell ->> 'number')::NUMERIC)
	    FILTER (WHERE cell ->> 'column_id' = 'outstanding') AS outstanding
    FROM taiwan_report_rows(
	'taiwan-injection', 'taiwan-trade-aging',
	'2026-01-20', NULL, NULL
    ) AS report
    CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
    WHERE report.row_key IN ('AP-ABS-001', 'AP-PP-001')
    GROUP BY report.row_key
)
SELECT pg_temp.assert_true(
    'Taiwan trade aging ignores allocations paid after the as-of date',
    (SELECT count(*) = 2 AND bool_and(paid = 0 AND outstanding = gross) FROM aging)
);

SELECT pg_temp.assert_true(
    'jurisdiction packs share the canonical effective-dated reporting rate',
    to_regprocedure('njord.reporting_rate(varchar,varchar,timestamp)') IS NOT NULL
    AND NOT EXISTS (
	SELECT 1
	FROM pg_proc
	WHERE proname IN (
	    'uk_reporting_rate', 'panama_reporting_rate', 'taiwan_reporting_rate'
	)
    )
);

DO $$
BEGIN
    BEGIN
	INSERT INTO taiwan_fiscal_periods (
	    book_id, id, period_start, period_end, status
	) VALUES (
	    'taiwan-injection', 'overlap-test',
	    '2026-06-01', '2027-05-31', 'open'
	);
	RAISE EXCEPTION 'an overlapping Taiwan fiscal period was allowed';
    EXCEPTION
	WHEN check_violation THEN NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'Taiwan fiscal periods reject overlaps under the serialized validator',
    NOT EXISTS (
	SELECT 1 FROM taiwan_fiscal_periods
	WHERE book_id = 'taiwan-injection' AND id = 'overlap-test'
    )
);

DO $$
BEGIN
    BEGIN
	UPDATE taiwan_boms SET output_quantity = 'NaN'
	WHERE book_id = 'taiwan-injection' AND id = 'BOM-ENC-2026';
	RAISE EXCEPTION 'a non-finite BOM output quantity was allowed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
	UPDATE taiwan_bom_lines SET quantity = 'NaN'
	WHERE book_id = 'taiwan-injection' AND bom_id = 'BOM-ENC-2026'
	  AND material_item_id = 'abs-natural';
	RAISE EXCEPTION 'a non-finite BOM material quantity was allowed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
	UPDATE taiwan_production_runs SET planned_quantity = 'NaN'
	WHERE book_id = 'taiwan-injection' AND id = 'RUN-ENC-001';
	RAISE EXCEPTION 'a non-finite planned quantity was allowed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
	UPDATE taiwan_production_runs SET good_quantity = 'NaN'
	WHERE book_id = 'taiwan-injection' AND id = 'RUN-ENC-001';
	RAISE EXCEPTION 'a non-finite good quantity was allowed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
	UPDATE taiwan_production_runs SET reject_quantity = 'NaN'
	WHERE book_id = 'taiwan-injection' AND id = 'RUN-ENC-001';
	RAISE EXCEPTION 'a non-finite reject quantity was allowed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    BEGIN
	UPDATE taiwan_inventory_movements SET quantity = 'NaN'
	WHERE book_id = 'taiwan-injection' AND id = 'MV-ABS-PUR-01';
	RAISE EXCEPTION 'a non-finite inventory movement was allowed';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'Taiwan production quantities must be finite',
    (SELECT output_quantity = 1000 FROM taiwan_boms
	WHERE book_id = 'taiwan-injection' AND id = 'BOM-ENC-2026')
    AND (SELECT quantity = 200 FROM taiwan_bom_lines
	WHERE book_id = 'taiwan-injection' AND bom_id = 'BOM-ENC-2026'
	  AND material_item_id = 'abs-natural')
    AND (SELECT planned_quantity = 1000 AND good_quantity = 950
	    AND reject_quantity = 50
	FROM taiwan_production_runs
	WHERE book_id = 'taiwan-injection' AND id = 'RUN-ENC-001')
    AND (SELECT quantity = 500 FROM taiwan_inventory_movements
	WHERE book_id = 'taiwan-injection' AND id = 'MV-ABS-PUR-01')
);

DO $$
DECLARE
    missing_fx_xid INTEGER;
BEGIN
    INSERT INTO asset (id) VALUES ('NO_TWD_FX');
    INSERT INTO accts (
	book_id, id, name, type, atype, parent_id, account_kind, placeholder
    ) VALUES
	('taiwan-injection', 'Missing FX Income', '缺少匯率收入',
	    'I', 'NO_TWD_FX', 'Sales', 'posting', FALSE),
	('taiwan-injection', 'Missing FX Equity', '缺少匯率權益',
	    'Q', 'NO_TWD_FX', 'Equity', 'posting', FALSE);
    INSERT INTO taiwan_account_income_tax_mappings (
	book_id, acct, treatment_id
    ) VALUES (
	'taiwan-injection', 'Missing FX Income', 'taxable_income'
    );
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('taiwan-injection', '2026-08-01', '測試缺少換算匯率')
    RETURNING xid INTO missing_fx_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('taiwan-injection', missing_fx_xid, 'Missing FX Income', -1),
	('taiwan-injection', missing_fx_xid, 'Missing FX Equity', 1);
END;
$$;

WITH report AS (
    SELECT *
    FROM taiwan_report_rows(
	'taiwan-injection', 'taiwan-income-tax',
	'2026-12-31', '2026-01-01', '2026-12-31'
    )
)
SELECT pg_temp.assert_true(
    'Taiwan income tax fails closed when a posting lacks an FX rate',
    EXISTS (
	SELECT 1
	FROM report
	WHERE row_key = 'Missing FX Income'
	  AND payload ->> 'row_kind' = 'warning'
	  AND (
	      SELECT count(*) FROM jsonb_array_elements(payload -> 'cells') AS cell
	      WHERE cell ->> 'column_id' IN ('book_amount', 'tax_effect')
		AND cell -> 'number' = 'null'::JSONB
	  ) = 2
	  AND EXISTS (
	      SELECT 1 FROM jsonb_array_elements(payload -> 'cells') AS cell
	      WHERE cell ->> 'column_id' = 'treatment'
		AND cell ->> 'text' LIKE '%缺少換算匯率%'
	  )
    )
    AND EXISTS (
	SELECT 1
	FROM report
	WHERE row_key = 'indicative-result'
	  AND payload ->> 'row_kind' = 'warning'
	  AND EXISTS (
	      SELECT 1 FROM jsonb_array_elements(payload -> 'cells') AS cell
	      WHERE cell ->> 'column_id' = 'tax_effect'
		AND cell -> 'number' = 'null'::JSONB
	  )
    )
);

BEGIN;

DO $$
BEGIN
    PERFORM * FROM api.create_book(
	'fx-completeness', 'FX Completeness', 'TWD', TRUE
    );
END;
$$;

INSERT INTO accts (
    book_id, id, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('fx-completeness', 'Foreign Cash', 'A', 'NO_TWD_FX', 'Assets', 'bank', FALSE),
    ('fx-completeness', 'Foreign Savings', 'A', 'NO_TWD_FX', 'Assets', 'bank', FALSE),
    ('fx-completeness', 'Foreign Income', 'I', 'NO_TWD_FX', 'Income', 'posting', FALSE),
    ('fx-completeness', 'Known Cash', 'A', 'TWD', 'Assets', 'bank', FALSE);

INSERT INTO cash_accounts (book_id, acct) VALUES
    ('fx-completeness', 'Foreign Cash'),
    ('fx-completeness', 'Foreign Savings'),
    ('fx-completeness', 'Known Cash');

SELECT pg_temp.assert_true(
    'empty core reports retain known zero totals',
    EXISTS (
	SELECT 1 FROM bsheet_report('fx-completeness', '2026-12-31')
	WHERE account = 'Total Assets' AND posttax = 0
    ) AND EXISTS (
	SELECT 1 FROM bsheet_report('fx-completeness', '2026-12-31')
	WHERE row_kind = 'grand_total' AND posttax = 0
    ) AND EXISTS (
	SELECT 1 FROM tb_report('fx-completeness', '2026-12-31')
	WHERE row_kind = 'total' AND debit = 0 AND credit = 0
    ) AND EXISTS (
	SELECT 1 FROM pl_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'grand_total' AND posttax = 0
    ) AND (
	SELECT count(*) = 3 AND bool_and(posttax = 0)
	FROM cf_report('fx-completeness', '2026-01-01', '2026-12-31')
	WHERE section = 'Cash Reconciliation'
    )
);

DO $$
DECLARE
    transfer_xid INTEGER;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('fx-completeness', '2026-01-15', 'Foreign cash transfer')
    RETURNING xid INTO transfer_xid;

    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('fx-completeness', transfer_xid, 'Foreign Cash', -25),
	('fx-completeness', transfer_xid, 'Foreign Savings', 25);
END;
$$;

SELECT pg_temp.assert_true(
    'an unvalued cash-to-cash transfer remains a known zero cash flow',
    NOT EXISTS (
	SELECT 1 FROM cf_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'account'
    ) AND (
	SELECT count(*) = 3 AND bool_and(posttax = 0)
	FROM cf_report('fx-completeness', '2026-01-01', '2026-12-31')
	WHERE section = 'Cash Reconciliation'
    )
    AND njord.report_validation_messages(
	'cash-flow', 'fx-completeness', '2026-01-01', '2026-12-31'
    ) = '[]'::JSONB
);

DO $$
DECLARE
    before_xid INTEGER;
    foreign_xid INTEGER;
    known_xid INTEGER;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('fx-completeness', '2025-12-31', 'Unvalued opening cash')
    RETURNING xid INTO before_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('fx-completeness', before_xid, 'Foreign Cash', 100),
	('fx-completeness', before_xid, 'Foreign Income', -100);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('fx-completeness', '2026-06-01', 'Unvalued period cash')
    RETURNING xid INTO foreign_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('fx-completeness', foreign_xid, 'Foreign Cash', 20),
	('fx-completeness', foreign_xid, 'Foreign Income', -20);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('fx-completeness', '2026-07-01', 'Known period cash')
    RETURNING xid INTO known_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('fx-completeness', known_xid, 'Known Cash', 50),
	('fx-completeness', known_xid, 'Uncategorised Income', -50);
END;
$$;

SELECT pg_temp.assert_true(
    'Balance Sheet totals fail closed when any balance lacks FX',
    EXISTS (
	SELECT 1 FROM bsheet_report('fx-completeness', '2026-12-31')
	WHERE account = 'Foreign Cash' AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM bsheet_report('fx-completeness', '2026-12-31')
	WHERE account = 'Current Earnings' AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM bsheet_report('fx-completeness', '2026-12-31')
	WHERE account = 'Total Assets' AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM bsheet_report('fx-completeness', '2026-12-31')
	WHERE row_kind = 'grand_total' AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM hierarchical_balance_sheet_report(
	    'fx-completeness', '2026-12-31'
	)
	WHERE row_kind = 'group' AND account_id = 'Equity' AND posttax IS NULL
    )
);

SELECT pg_temp.assert_true(
    'Trial Balance totals fail closed when any balance lacks FX',
    EXISTS (
	SELECT 1 FROM tb_report('fx-completeness', '2026-12-31')
	WHERE row_kind = 'total' AND debit IS NULL AND credit IS NULL
    )
);

SELECT pg_temp.assert_true(
    'Profit and Loss totals fail closed when any period amount lacks FX',
    EXISTS (
	SELECT 1 FROM pl_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'account' AND account = 'Foreign Income'
	  AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM pl_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'section_total' AND section = 'Income'
	  AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM pl_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'grand_total' AND account = 'Net Profit / Loss'
	  AND posttax IS NULL
    )
);

SELECT pg_temp.assert_true(
    'Cash Flow activity and reconciliation fail closed when FX is missing',
    EXISTS (
	SELECT 1 FROM cf_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'account' AND account = 'Foreign Income'
	  AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM cf_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'section_total' AND section = 'Operating Activities'
	  AND posttax IS NULL
    ) AND EXISTS (
	SELECT 1 FROM cf_report(
	    'fx-completeness', '2026-01-01', '2026-12-31'
	)
	WHERE row_kind = 'grand_total' AND account = 'Net Change in Cash'
	  AND posttax IS NULL
    ) AND (
	SELECT count(*) = 2 AND bool_and(posttax IS NULL)
	FROM cf_report('fx-completeness', '2026-01-01', '2026-12-31')
	WHERE account IN (
	    'Cash at Beginning of Period', 'Cash at End of Period'
	)
    )
);

ROLLBACK;

DO $$
BEGIN
    BEGIN
	UPDATE taiwan_inventory_movements
	SET movement_kind = 'sale'
	WHERE book_id = 'taiwan-injection' AND id = 'MV-ABS-PUR-01';
	RAISE EXCEPTION 'an incoming inventory posting was accepted as a stock issue';
    EXCEPTION
	WHEN check_violation THEN NULL;
    END;
END;
$$;

DO $$
BEGIN
    BEGIN
	INSERT INTO panama_leases (
	    book_id, id, property_id, unit_id, tenant_id,
	    starts_on, ends_on, monthly_rent, tax_treatment,
	    exclusive_residential_use
	) VALUES (
	    'panama-property', 'invalid-short-exemption', 'marina-vista',
	    '8A', 'rojas', '2026-09-01', '2026-12-01', 1800,
	    'residential_over_six_months_exempt', TRUE
	);
	RAISE EXCEPTION 'short residential lease received the over-six-month exemption';
    EXCEPTION
	WHEN check_violation THEN NULL;
    END;
END;
$$;

CALL create_simple_xaction(
    'personal',
    '2026-01-20',
    'Current GBP',
    'Uncategorised Income',
    100.00
);

CALL create_simple_xaction(
    'personal',
    '2026-01-21',
    'Current GBP',
    'Uncategorised Expenses',
    -30.00
);

SELECT pg_temp.assert_true(
    'tb_report balances foreign-currency books',
    (
	SELECT debit = 250.00 AND credit = 250.00
	FROM tb_report('personal', '2026-12-31')
	WHERE row_kind = 'total'
	  AND account = 'Total'
    ) AND NOT EXISTS (
	SELECT 1
	FROM tb_report('personal', '2026-12-31')
	WHERE row_kind = 'difference'
    )
);

SELECT pg_temp.assert_true(
    'tb_report balances as of a date',
    (
	SELECT debit = 150.00 AND credit = 150.00
	FROM tb_report('personal', '2026-01-15')
	WHERE row_kind = 'total'
	  AND account = 'Total'
    ) AND NOT EXISTS (
	SELECT 1
	FROM tb_report('personal', '2026-01-15')
	WHERE row_kind = 'difference'
    )
);

INSERT INTO books (id, name, reporting_asset)
VALUES ('trial', 'Trial Balance Test', 'GBP');

INSERT INTO accts (
    book_id, id, type, atype, parent_id, account_kind, placeholder
)
VALUES
    ('trial', 'Assets', 'A', 'GBP', NULL, 'root', TRUE),
    ('trial', 'Liabilities', 'L', 'GBP', NULL, 'root', TRUE),
    ('trial', 'Equity', 'Q', 'GBP', NULL, 'root', TRUE),
    ('trial', 'Income', 'I', 'GBP', NULL, 'root', TRUE),
    ('trial', 'Expenses', 'E', 'GBP', NULL, 'root', TRUE),
    ('trial', 'Opening Balance', 'Q', 'GBP', 'Equity', 'posting', FALSE),
    ('trial', 'Uncategorised Income', 'I', 'GBP', 'Income', 'posting', FALSE);

CALL open_account('trial', 'Cash', '2026-01-01', 'A', 'GBP', 100.00);

CALL create_simple_xaction(
    'trial',
    '2026-01-02',
    'Cash',
    'Uncategorised Income',
    50.00
);

SELECT pg_temp.assert_true(
    'tb_report balances same-currency books',
    (
	SELECT debit = 150.00 AND credit = 150.00
	FROM tb_report('trial', '2026-12-31')
	WHERE row_kind = 'total'
	  AND account = 'Total'
    ) AND NOT EXISTS (
	SELECT 1
	FROM tb_report('trial', '2026-12-31')
	WHERE row_kind = 'difference'
    )
);

SELECT pg_temp.assert_true(
    'pl_report includes income and expense totals for an explicit period',
    EXISTS (
	SELECT 1
	FROM pl_report('personal', '2026-01-01', '2026-12-31')
	WHERE section = 'Income'
	  AND row_kind = 'section_total'
	  AND account = 'Total Income'
	  AND posttax = 100.00
    ) AND EXISTS (
	SELECT 1
	FROM pl_report('personal', '2026-01-01', '2026-12-31')
	WHERE section = 'Expenses'
	  AND row_kind = 'section_total'
	  AND account = 'Total Expenses'
	  AND posttax = 48.83
    )
);

SELECT pg_temp.assert_true(
    'pl_report reports net profit',
    (
	SELECT posttax = 51.17
	FROM pl_report('personal', '2026-01-01', '2026-12-31')
	WHERE row_kind = 'grand_total'
	  AND account = 'Net Profit'
    )
);

SELECT pg_temp.assert_true(
    'pl_report reports a bounded period',
    (
	SELECT posttax = 100.00
	FROM pl_report('personal', '2026-01-20', '2026-01-20')
	WHERE section = 'Income'
	  AND row_kind = 'section_total'
	  AND account = 'Total Income'
    )
);

SELECT pg_temp.assert_true(
    'cf_report classifies operating cash flow',
    (
	SELECT posttax = 70.00
	FROM cf_report('personal', '2026-01-01', '2026-12-31')
	WHERE section = 'Operating Activities'
	  AND row_kind = 'section_total'
	  AND account = 'Net Cash from Operating Activities'
    )
);

SELECT pg_temp.assert_true(
    'cf_report classifies financing cash flow',
    (
	SELECT posttax = 50.00
	FROM cf_report('personal', '2026-01-01', '2026-12-31')
	WHERE section = 'Financing Activities'
	  AND row_kind = 'section_total'
	  AND account = 'Net Cash from Financing Activities'
    )
);

SELECT pg_temp.assert_true(
    'cf_report reconciles ending cash',
    (
	SELECT posttax = 120.00
	FROM cf_report('personal', '2026-01-01', '2026-12-31')
	WHERE row_kind = 'computed'
	  AND account = 'Cash at End of Period'
    )
);

SELECT pg_temp.assert_true(
    'cf_report reports bounded cash reconciliation',
    (
	SELECT posttax = 50.00
	FROM cf_report('personal', '2026-01-20', '2026-01-20')
	WHERE row_kind = 'computed'
	  AND account = 'Cash at Beginning of Period'
    ) AND (
	SELECT posttax = 150.00
	FROM cf_report('personal', '2026-01-20', '2026-01-20')
	WHERE row_kind = 'computed'
	  AND account = 'Cash at End of Period'
    )
);

INSERT INTO accts (
    book_id,
    id,
    type,
    atype,
    parent_id
) VALUES (
    'personal',
    'JAGUAR Expenses',
    'E',
    'GBP',
    'Expenses'
);

INSERT INTO vendors (book_id, id, name, vat_number)
VALUES ('personal', 'sparkle-wash', 'Sparkle Wash Ltd', 'GB123456789');

CALL create_xaction(
    'personal',
    '2026-01-25',
    ROW('Current GBP', -24.00, 'JAGUAR car wash')::xaction_elem,
    ROW('JAGUAR Expenses', 24.00, 'JAGUAR car wash')::xaction_elem
);

INSERT INTO business_expenses (
    book_id,
    xid,
    vendor_id,
    invoice_number,
    invoice_date,
    supply_date,
    business_purpose,
    receipt_uri
)
SELECT book_id,
       xid,
       'sparkle-wash',
       'SW-100',
       '2026-01-25',
       '2026-01-25',
       'Company car cleaning',
       'receipts/sw-100.pdf'
FROM xactions
WHERE book_id = 'personal'
  AND date = '2026-01-25'
  AND comment = 'JAGUAR car wash';

INSERT INTO business_expense_lines (
    xaction_bit_id, net_amount, vat_amount, gross_amount
)
SELECT xaction_bits.id, 20, 4, 24
FROM xaction_bits
JOIN xactions
  ON xactions.book_id = xaction_bits.book_id
 AND xactions.xid = xaction_bits.xid
WHERE xaction_bits.book_id = 'personal'
  AND xactions.date = '2026-01-25'
  AND xaction_bits.acct = 'JAGUAR Expenses';

SELECT pg_temp.assert_true(
    'business expense detail exposes factual line metadata',
    (
	SELECT vendor_name = 'Sparkle Wash Ltd'
	   AND invoice_number = 'SW-100'
	   AND description = 'JAGUAR car wash'
	   AND memo IS NULL
	   AND net_amount = 20.00
	   AND vat_amount = 4.00
	   AND gross_amount = 24.00
	   AND business_use_percent = 1.0000
	FROM business_expense_detail
	WHERE book_id = 'personal'
	  AND account = 'JAGUAR Expenses'
	  AND invoice_number = 'SW-100'
    )
);

CALL create_xaction(
    'personal',
    '2026-01-26',
    ROW('Current GBP', -800.00, 'JAGUAR insurance')::xaction_elem,
    ROW('JAGUAR Expenses', 800.00, 'JAGUAR insurance')::xaction_elem
);

INSERT INTO business_expenses (book_id, xid, vendor_id, invoice_number)
SELECT book_id, xid, NULL, 'INS-2026'
FROM xactions
WHERE book_id = 'personal'
  AND date = '2026-01-26'
  AND comment = 'JAGUAR insurance';

INSERT INTO business_expense_lines (xaction_bit_id, vat_amount, note)
SELECT xaction_bits.id, 0, 'No VAT shown on invoice'
FROM xaction_bits
JOIN xactions
  ON xactions.book_id = xaction_bits.book_id
 AND xactions.xid = xaction_bits.xid
WHERE xaction_bits.book_id = 'personal'
  AND xactions.date = '2026-01-26'
  AND xaction_bits.acct = 'JAGUAR Expenses';

SELECT pg_temp.assert_true(
    'business expense detail retains explicit VAT facts',
    (
	SELECT vat_amount = 0.00
	   AND note = 'No VAT shown on invoice'
	FROM business_expense_detail
	WHERE book_id = 'personal'
	  AND account = 'JAGUAR Expenses'
	  AND invoice_number = 'INS-2026'
    )
);

DO $$
DECLARE
    jaguar_bit integer;
BEGIN
    SELECT xaction_bits.id
    INTO jaguar_bit
    FROM xaction_bits
    JOIN xactions
      ON xactions.book_id = xaction_bits.book_id
     AND xactions.xid = xaction_bits.xid
    WHERE xaction_bits.book_id = 'personal'
      AND xactions.date = '2026-01-26'
      AND xaction_bits.acct = 'Current GBP';

    BEGIN
	INSERT INTO business_expense_lines (xaction_bit_id, business_use_percent)
	VALUES (jaguar_bit, 1.50);

	RAISE EXCEPTION 'invalid business use percentage was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO business_expense_lines (xaction_bit_id, net_amount)
	VALUES (jaguar_bit, -1);
	RAISE EXCEPTION 'a negative net expense amount was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO business_expense_lines (xaction_bit_id, vat_amount)
	VALUES (jaguar_bit, 'NaN');
	RAISE EXCEPTION 'a non-finite VAT expense amount was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	INSERT INTO business_expense_lines (xaction_bit_id, gross_amount)
	VALUES (jaguar_bit, 'NaN');
	RAISE EXCEPTION 'a non-finite gross expense amount was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'business expense line percentages are constrained',
    NOT EXISTS (
	SELECT 1
	FROM business_expense_lines
	WHERE business_use_percent > 1
    )
);

CALL create_xaction(
    'personal',
    '2026-02-03',
    ROW('Broker USD', -5.00, 'Two-line description')::xaction_elem,
    ROW('USD Expenses', 5.00, 'Two-line description')::xaction_elem
);

SELECT pg_temp.assert_true(
    'two-line transaction comments are stored on the header',
    EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND date = '2026-02-03'
	  AND comment = 'Two-line description'
    ) AND NOT EXISTS (
	SELECT 1
	FROM xaction_bits
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	WHERE xactions.book_id = 'personal'
	  AND xactions.date = '2026-02-03'
	  AND xaction_bits.comment IS NOT NULL
    )
);

DO $$
BEGIN
    BEGIN
	CALL create_xaction(
	    'personal',
	    '2026-02-02',
	    ROW('Broker USD', 1.00, 'same-account debit')::xaction_elem,
	    ROW('Broker USD', -1.00, 'same-account credit')::xaction_elem
	);

	RAISE EXCEPTION 'same-account transaction was allowed';
    EXCEPTION WHEN unique_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'transaction lines cannot reuse an account',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND date = '2026-02-02'
    )
);

INSERT INTO books (id, name, reporting_asset)
VALUES ('business', 'Business', 'GBP');

INSERT INTO accts (
    book_id, id, type, atype, parent_id, account_kind, placeholder
)
VALUES
    ('business', 'Assets', 'A', 'GBP', NULL, 'root', TRUE),
    ('business', 'Liabilities', 'L', 'GBP', NULL, 'root', TRUE),
    ('business', 'Equity', 'Q', 'GBP', NULL, 'root', TRUE),
    ('business', 'Income', 'I', 'GBP', NULL, 'root', TRUE),
    ('business', 'Expenses', 'E', 'GBP', NULL, 'root', TRUE),
    ('business', 'Opening Balance', 'Q', 'GBP', 'Equity', 'posting', FALSE),
    ('business', 'Broker USD', 'A', 'USD', 'Assets', 'investment', FALSE),
    ('business', 'Business Expense', 'E', 'USD', 'Expenses', 'posting', FALSE);

SELECT pg_temp.assert_true(
    'account names are scoped by book',
    (
	SELECT count(*) = 2
	FROM accts
	WHERE id = 'Broker USD'
    )
);

DO $$
DECLARE
    ourxid integer;
BEGIN
    INSERT INTO xactions (book_id, date)
    VALUES ('personal', '2026-02-02')
    RETURNING xid INTO ourxid;

    BEGIN
	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES ('personal', ourxid, 'Business Expense', 1.00);

	RAISE EXCEPTION 'cross-book account reference was allowed';
    EXCEPTION WHEN foreign_key_violation THEN
	NULL;
    END;

    DELETE FROM xactions
    WHERE book_id = 'personal'
      AND xid = ourxid;
END;
$$;

SELECT pg_temp.assert_true(
    'transaction lines cannot reference accounts from another book',
    NOT EXISTS (
	SELECT 1
	FROM xaction_bits
	WHERE book_id = 'personal'
	  AND acct = 'Business Expense'
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

CALL import_csv('personal', 'Broker USD');

SELECT pg_temp.assert_true(
    'import_csv leaves one-sided candidates in staging',
    (SELECT count(*) = 2 FROM import)
    AND NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment IN ('Coffee', 'Refund')
    )
);

SELECT pg_temp.assert_true(
    'one-sided import candidates never enter the ledger',
    NOT EXISTS (
	SELECT 1
	FROM xaction_bits
	JOIN xactions USING (book_id, xid)
	WHERE xaction_bits.book_id = 'personal'
	  AND xactions.comment IN ('Coffee', 'Refund')
    )
);

DROP TABLE import;

DO $$
BEGIN
    BEGIN
	CALL create_xaction_v(
	    'personal',
	    '2026-02-27',
	    ARRAY[]::xaction_elem[]
	);

	RAISE EXCEPTION 'transaction with no lines was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'direct transaction functions require a line',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND date = '2026-02-27'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
BEGIN
    BEGIN
	INSERT INTO xactions (book_id, date, comment)
	VALUES ('personal', '2026-02-28', 'One-line direct write')
	RETURNING xid INTO test_xid;

	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES ('personal', test_xid, 'Current GBP', 1);

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'transaction with one line was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'direct transactions require at least two lines',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment = 'One-line direct write'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('personal', '2026-02-28', 'Zero-line direct write')
    RETURNING xid INTO test_xid;

    BEGIN
	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES ('personal', test_xid, 'Current GBP', 0);

	RAISE EXCEPTION 'zero transaction line was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    DELETE FROM xactions
    WHERE book_id = 'personal' AND xid = test_xid;
END;
$$;

SELECT pg_temp.assert_true(
    'direct transaction lines must be non-zero',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment = 'Zero-line direct write'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('personal', '2026-02-28', 'Non-finite direct write')
    RETURNING xid INTO test_xid;

    BEGIN
	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES ('personal', test_xid, 'Current GBP', 'NaN'::NUMERIC);

	RAISE EXCEPTION 'non-finite transaction line was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    DELETE FROM xactions
    WHERE book_id = 'personal' AND xid = test_xid;
END;
$$;

SELECT pg_temp.assert_true(
    'direct transaction lines must be finite',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment = 'Non-finite direct write'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
BEGIN
    BEGIN
	INSERT INTO xactions (book_id, date, comment)
	VALUES ('personal', '2026-03-01', 'Unbalanced direct write')
	RETURNING xid INTO test_xid;

	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES
	    ('personal', test_xid, 'Current GBP', 10.00),
	    ('personal', test_xid, 'Uncategorised Expenses', -9.00);

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'unbalanced transaction was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'direct transactions must balance',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment = 'Unbalanced direct write'
    )
);

DO $$
DECLARE
    test_xid INTEGER;
BEGIN
    BEGIN
	INSERT INTO xactions (book_id, date, comment)
	VALUES ('personal', '2026-03-02', 'Cross-asset direct write')
	RETURNING xid INTO test_xid;

	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES
	    ('personal', test_xid, 'Current GBP', 1.00),
	    ('personal', test_xid, 'Broker USD', -1.00);

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'cross-asset transaction was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'transactions balance separately per asset',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment = 'Cross-asset direct write'
    )
);

DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET atype = 'USD'
	WHERE book_id = 'personal'
	  AND id = 'Current GBP';

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'an account asset invalidated transactions';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'account asset changes revalidate transactions',
    (
	SELECT atype = 'GBP'
	FROM accts
	WHERE book_id = 'personal'
	  AND id = 'Current GBP'
    )
);

SELECT pg_temp.assert_true(
    'foreign openings use asset-matched equity',
    EXISTS (
	SELECT 1
	FROM accts
	WHERE book_id = 'personal'
	  AND id = 'Opening Balance (USD)'
	  AND type = 'Q'
	  AND atype = 'USD'
    )
);

SELECT pg_temp.assert_true(
    'draft balance returns SQL-owned reciprocal amounts per asset',
    (
	SELECT jsonb_object_agg(asset, amount ORDER BY asset)
	    = '{"GBP": 1.00000, "USD": 0.75000}'::JSONB
	FROM api.transaction_draft_balance(
	    'personal',
	    '[
	      {"account":"Current GBP","amount":-7},
	      {"account":"Uncategorised Expenses","amount":6},
	      {"account":"Broker USD","amount":-2},
	      {"account":"USD Expenses","amount":1.25}
	    ]'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'draft balance omits assets that already balance',
    NOT EXISTS (
	SELECT 1
	FROM api.transaction_draft_balance(
	    'personal',
	    '[
	      {"account":"Current GBP","amount":-7},
	      {"account":"Uncategorised Expenses","amount":7}
	    ]'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'draft balance uses stored ledger precision',
    (
	SELECT asset = 'GBP' AND amount = -0.00002
	FROM api.transaction_draft_balance(
	    'personal',
	    '[
	      {"account":"Current GBP","amount":0.000006},
	      {"account":"Uncategorised Expenses","amount":0.000006}
	    ]'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview reports per-asset imbalance',
    (
	SELECT NOT valid
	   AND error_code = 'TRANSACTION_NOT_BALANCED'
	   AND imbalance = '{"GBP": 1.00000, "USD": -1.00000}'::jsonb
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-03",
	      "lines":[
	        {"account":"Current GBP","amount":1},
	        {"account":"Broker USD","amount":-1}
	      ]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview normalizes simple descriptions',
    (
	SELECT valid
	   AND normalized_transaction ->> 'comment' = 'Preview description'
	   AND normalized_transaction #>> '{lines,0,comment}' IS NULL
	   AND imbalance = '{}'::jsonb
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[
	        {"account":"Current GBP","amount":2,"comment":"Preview description"},
	        {"account":"Uncategorised Expenses","amount":-2,"comment":"Preview description"}
	      ]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'simple transaction intent expands into balanced explicit lines in SQL',
    (
	SELECT valid
	   AND imbalance = '{}'::jsonb
	   AND normalized_transaction ->> 'comment' = 'Register transfer'
	   AND normalized_transaction #>> '{lines,0,account}' = 'Current GBP'
	   AND (normalized_transaction #>> '{lines,0,amount}')::numeric = -12.34
	   AND normalized_transaction #>> '{lines,1,account}' = 'Uncategorised Expenses'
	   AND (normalized_transaction #>> '{lines,1,amount}')::numeric = 12.34
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "comment":"Register transfer",
	      "simple":{
	        "account":"Current GBP",
	        "transfer_account":"Uncategorised Expenses",
	        "amount":"-12.34"
	      }
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects ambiguous simple and explicit shapes',
    (
	SELECT NOT valid AND error_code = 'INVALID_TRANSACTION_SHAPE'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "simple":{"account":"Current GBP","transfer_account":"Uncategorised Expenses","amount":1},
	      "lines":[{"account":"Current GBP","amount":1}]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects missing amounts',
    (
	SELECT NOT valid AND error_code = 'INVALID_LINE'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[{"account":"Current GBP"}]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview discards the register blank row only',
    (
	SELECT valid
	   AND error_code IS NULL
	   AND jsonb_array_length(normalized_transaction -> 'lines') = 2
	   AND normalized_transaction #>> '{lines,0,account}' = 'Current GBP'
	   AND normalized_transaction #>> '{lines,1,account}' =
	       'Uncategorised Expenses'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[
		{"account":"Current GBP","amount":-2},
		{"account":"Uncategorised Expenses","amount":2},
		{"account":"  ","amount":null,"comment":" "}
	      ]
	    }'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview preserves partially filled rows as errors',
    (
	SELECT NOT valid AND error_code = 'INVALID_LINE'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[
		{"account":"Current GBP","amount":-2},
		{"account":"Uncategorised Expenses","amount":2},
		{"account":"","amount":"1","comment":""}
	      ]
	    }'::JSONB
	)
    ) AND (
	SELECT NOT valid AND error_code = 'INVALID_LINE'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[
		{"account":"Current GBP","amount":-2},
		{"account":"Uncategorised Expenses","amount":2},
		{"account":"","amount":"","comment":"memo without posting"}
	      ]
	    }'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects empty and blank-only line arrays',
    (
	SELECT NOT valid AND error_code = 'TRANSACTION_REQUIRES_LINES'
	FROM api.preview_transaction(
	    'personal',
	    '{"date":"2026-03-04","lines":[]}'::JSONB
	)
    ) AND (
	SELECT NOT valid AND error_code = 'TRANSACTION_REQUIRES_LINES'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[{"account":"","amount":"","comment":""}]
	    }'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects one-sided candidates',
    (
	SELECT NOT valid AND error_code = 'TRANSACTION_REQUIRES_TWO_LINES'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[{"account":"Current GBP","amount":1}]
	    }'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects non-finite amounts',
    (
	SELECT NOT valid AND error_code = 'INVALID_LINE'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[{"account":"Current GBP","amount":"Infinity"}]
	    }'::JSONB
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects amounts that store as zero',
    (
	SELECT NOT valid AND error_code = 'INVALID_LINE'
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[{"account":"Current GBP","amount":0.000001}]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview balances at stored precision',
    (
	SELECT NOT valid
	   AND error_code = 'TRANSACTION_NOT_BALANCED'
	   AND imbalance = '{"GBP": 0.00001}'::jsonb
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-04",
	      "lines":[
	        {"account":"Current GBP","amount":0.000006},
	        {"account":"Uncategorised Expenses","amount":0.000006},
	        {"account":"Uncategorised Income","amount":-0.000012}
	      ]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'split preview returns normalized lines and validity',
    (
	SELECT valid
	   AND error_code IS NULL
	   AND imbalance = '{}'::jsonb
	   AND normalized_transaction ->> 'comment' = 'Split preview'
	   AND jsonb_array_length(normalized_transaction -> 'lines') = 3
	   AND NOT jsonb_path_exists(
		normalized_transaction,
		'$.lines[*] ? (@.comment != null)'
	   )
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-05",
	      "lines":[
	        {"account":"Current GBP","amount":-10,"comment":"Split preview"},
	        {"account":"Uncategorised Expenses","amount":6,"comment":"Split preview"},
	        {"account":"Uncategorised Income","amount":4,"comment":"Split preview"}
	      ]
	    }'::jsonb
	)
    )
);

DO $$
BEGIN
    BEGIN
	PERFORM 1
	FROM api.create_transaction(
	    'personal',
	    '{
	      "date":"2026-03-06",
	      "comment":"Invalid API write",
	      "lines":[
	        {"account":"Current GBP","amount":5},
	        {"account":"Uncategorised Expenses","amount":-4}
	      ]
	    }'::jsonb
	);

	RAISE EXCEPTION 'function-based unbalanced transaction was allowed';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'function-based writes enforce transaction validity',
    NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = 'personal'
	  AND comment = 'Invalid API write'
    )
);

SELECT * FROM api.create_book('api-test', 'API Test', 'GBP', TRUE);

SELECT pg_temp.assert_true(
    'create_book creates standard personal accounts',
    (
	SELECT count(*) = 8
	FROM accts
	WHERE book_id = 'api-test'
	  AND id IN (
	      'Assets', 'Liabilities', 'Equity', 'Income', 'Expenses', 'Opening Balance',
	      'Uncategorised Income', 'Uncategorised Expenses'
	  )
    )
);

DO $$
DECLARE
    error_detail TEXT;
    error_hint TEXT;
BEGIN
    PERFORM * FROM api.create_book(
	'standard-account-collision', 'Standard account collision', 'GBP', FALSE
    );

    INSERT INTO accts (
	book_id, id, name, type, atype, parent_id, account_kind, placeholder
    ) VALUES (
	'standard-account-collision', 'Spending', 'Spending', 'E', 'GBP',
	NULL, 'root', TRUE
    );

    BEGIN
	PERFORM njord.ensure_standard_accounts('standard-account-collision');
	RAISE EXCEPTION 'standard account collision was allowed'
	    USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	GET STACKED DIAGNOSTICS
	    error_detail = PG_EXCEPTION_DETAIL,
	    error_hint = PG_EXCEPTION_HINT;
	IF error_detail <> 'STANDARD_ACCOUNT_COLLISION'
	   OR error_hint <>
	      'required_account=Expenses; conflicting_account=Spending' THEN
	    RAISE EXCEPTION 'standard account collision lost its diagnostics'
		USING ERRCODE = 'P0002';
	END IF;
    END;

    IF (SELECT count(*) FROM accts
	WHERE book_id = 'standard-account-collision') <> 1 THEN
	RAISE EXCEPTION 'failed standard account bootstrap left partial accounts'
	    USING ERRCODE = 'P0002';
    END IF;

    DELETE FROM accts WHERE book_id = 'standard-account-collision';
    DELETE FROM book_reporting_currencies
    WHERE book_id = 'standard-account-collision';
    DELETE FROM books WHERE id = 'standard-account-collision';
END;
$$;

SELECT pg_temp.assert_true(
    'ordinary Book page keeps identity stable and company reporting disabled',
    EXISTS (
	SELECT 1
	FROM api.book_page('api-test')
	WHERE component = 'book_identity'
	  AND payload ->> 'id' = 'api-test'
	  AND payload ->> 'reporting_asset' = 'GBP'
	  AND payload ->> 'entity_type' = 'household'
    ) AND EXISTS (
	SELECT 1
	FROM api.book_page('api-test')
	WHERE component = 'page_context'
	  AND payload ->> 'configuration_status' = 'ordinary'
    ) AND (
	SELECT count(*) = 5
	FROM api.reports_page('api-test')
	WHERE component = 'report_option'
    )
);

SELECT * FROM api.update_book_settings(
    'api-test', 'API Test renamed', 'household'
);

SELECT pg_temp.assert_true(
    'book settings update preserves explicit household identity',
    EXISTS (
	SELECT 1
	FROM books
	WHERE id = 'api-test'
	  AND name = 'API Test renamed'
	  AND reporting_asset = 'GBP'
	  AND entity_type = 'household'
    )
);

SELECT * FROM api.update_book_settings('api-test', 'API Test');

DO $$
BEGIN
    PERFORM * FROM api.create_book(
	'reporting-currency-invariant', 'Currency invariant', 'GBP', FALSE
    );

    BEGIN
	INSERT INTO book_reporting_currencies (book_id, effective_from, asset)
	VALUES ('reporting-currency-invariant', CURRENT_DATE + 1, 'USD');
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'future reporting-currency history was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    SET CONSTRAINTS ALL DEFERRED;

    BEGIN
	UPDATE books SET reporting_asset = 'USD'
	WHERE id = 'reporting-currency-invariant';
	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'reporting-currency cache diverged from history';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    SET CONSTRAINTS ALL DEFERRED;

    UPDATE book_reporting_currencies SET asset = 'USD'
    WHERE book_id = 'reporting-currency-invariant';
    UPDATE books SET reporting_asset = 'USD'
    WHERE id = 'reporting-currency-invariant';
    SET CONSTRAINTS ALL IMMEDIATE;

    IF njord.book_reporting_asset_at(
	'reporting-currency-invariant', CURRENT_DATE
    ) <> 'USD' THEN
	RAISE EXCEPTION 'coordinated reporting-currency update failed';
    END IF;

    SET CONSTRAINTS ALL DEFERRED;
    DELETE FROM book_reporting_currencies
    WHERE book_id = 'reporting-currency-invariant';
    DELETE FROM books WHERE id = 'reporting-currency-invariant';
END;
$$;

SELECT * FROM api.set_book_reporting_currency('api-test', 'USD', NULL);

SELECT pg_temp.assert_true(
    'an empty book replaces its initial reporting currency',
    EXISTS (
	SELECT 1 FROM books
	WHERE id = 'api-test' AND reporting_asset = 'USD'
    ) AND EXISTS (
	SELECT 1 FROM book_reporting_currencies
	WHERE book_id = 'api-test'
	  AND effective_from = '-infinity'::DATE
	  AND asset = 'USD'
    ) AND NOT EXISTS (
	SELECT 1 FROM accts
	WHERE book_id = 'api-test' AND atype <> 'USD'
    )
);

SELECT * FROM api.set_book_reporting_currency('api-test', 'GBP', NULL);

SELECT * FROM api.create_book(
    'api-company-vat', 'API Company VAT', 'GBP', TRUE
);

SELECT * FROM api.configure_uk_company(
    p_book_id => 'api-company-vat',
    p_legal_name => 'API Company VAT Ltd',
    p_legal_form => 'private_limited_shares',
    p_accounting_framework => 'frs105',
    p_vat_scheme => 'standard_invoice',
    p_period_id => '2026',
    p_period_start => '2026-01-01',
    p_period_end => '2026-12-31'
);

SELECT pg_temp.assert_true(
    'company configuration atomically creates the period and VAT control account',
    EXISTS (
	SELECT 1
	FROM api.book_page('api-company-vat')
	WHERE component = 'page_context'
	  AND payload ->> 'configuration_status' = 'complete'
    ) AND EXISTS (
	SELECT 1
	FROM uk_company_profiles
	WHERE book_id = 'api-company-vat'
	  AND legal_name = 'API Company VAT Ltd'
	  AND vat_scheme = 'standard_invoice'
    ) AND EXISTS (
	SELECT 1
	FROM uk_accounting_periods
	WHERE book_id = 'api-company-vat'
	  AND id = '2026'
	  AND period_start = DATE '2026-01-01'
	  AND period_end = DATE '2026-12-31'
    ) AND EXISTS (
	SELECT 1
	FROM uk_company_control_accounts AS control
	JOIN accts
	  ON accts.book_id = control.book_id
	 AND accts.id = control.vat_control_acct
	WHERE control.book_id = 'api-company-vat'
	  AND accts.name = 'VAT Control'
	  AND accts.type = 'L'
	  AND accts.atype = 'GBP'
	  AND NOT accts.placeholder
    ) AND (
	SELECT count(*) = 16
	FROM api.reports_page('api-company-vat')
	WHERE component = 'report_option'
    )
);

SELECT * FROM api.create_book(
    'api-company-unregistered', 'API Company Unregistered', 'GBP', TRUE
);

SELECT * FROM api.configure_uk_company(
    p_book_id => 'api-company-unregistered',
    p_legal_name => 'API Company Unregistered Ltd',
    p_legal_form => 'private_limited_shares',
    p_accounting_framework => 'frs105',
    p_vat_scheme => 'not_registered',
    p_period_id => '2026',
    p_period_start => '2026-01-01',
    p_period_end => '2026-12-31'
);

SELECT pg_temp.assert_true(
    'a non-VAT company is complete without a VAT control account',
    EXISTS (
	SELECT 1
	FROM api.book_page('api-company-unregistered')
	WHERE component = 'configuration_check'
	  AND row_key = 'vat_control'
	  AND (payload ->> 'complete')::BOOLEAN
    ) AND NOT EXISTS (
	SELECT 1 FROM uk_company_control_accounts
	WHERE book_id = 'api-company-unregistered'
    )
);

SELECT * FROM api.create_book(
    'api-company-invalid', 'API Company Invalid', 'GBP', TRUE
);

DO $$
BEGIN
    BEGIN
	PERFORM 1
	FROM api.configure_uk_company(
	    p_book_id => 'api-company-invalid',
	    p_legal_name => 'Invalid Company Ltd',
	    p_legal_form => 'private_limited_shares',
	    p_accounting_framework => 'frs105',
	    p_vat_scheme => 'standard_invoice',
	    p_period_id => '2026',
	    p_period_start => '2026-01-01',
	    p_period_end => '2026-12-31',
	    p_vat_control_acct => 'Assets'
	);
	RAISE EXCEPTION 'invalid VAT control account was allowed'
	    USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'failed company configuration rolls back without exposing company reports',
    NOT EXISTS (
	SELECT 1 FROM uk_company_profiles
	WHERE book_id = 'api-company-invalid'
    ) AND NOT EXISTS (
	SELECT 1 FROM uk_accounting_periods
	WHERE book_id = 'api-company-invalid'
    ) AND NOT EXISTS (
	SELECT 1 FROM uk_company_control_accounts
	WHERE book_id = 'api-company-invalid'
    ) AND (
	SELECT count(*) = 5
	FROM api.reports_page('api-company-invalid')
	WHERE component = 'report_option'
    )
);

SELECT * FROM api.create_book(
    'api-company-incomplete', 'API Company Incomplete', 'GBP', TRUE, 'company'
);

INSERT INTO uk_company_profiles (
    book_id, legal_name, legal_form, accounting_framework, vat_scheme
) VALUES (
    'api-company-incomplete', 'API Company Incomplete Ltd',
    'private_limited_shares', 'frs105', 'standard_invoice'
);

SELECT pg_temp.assert_true(
    'an incomplete direct-SQL profile cannot expose company reports',
    EXISTS (
	SELECT 1
	FROM api.book_page('api-company-incomplete')
	WHERE component = 'page_context'
	  AND payload ->> 'configuration_status' = 'incomplete'
    ) AND (
	SELECT count(*) = 5
	FROM api.reports_page('api-company-incomplete')
	WHERE component = 'report_option'
    ) AND NOT EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-company-incomplete', 'vat-return', NULL,
	    DATE '2026-01-01', DATE '2026-12-31'
	)
	WHERE component IN ('report_definition', 'generic_report_row')
    )
);

SELECT * FROM api.create_book(
    'api-company-chartless', 'API Company Chartless', 'GBP', FALSE, 'company'
);

INSERT INTO uk_company_profiles (
    book_id, legal_name, legal_form, accounting_framework, vat_scheme
) VALUES (
    'api-company-chartless', 'API Company Chartless Ltd',
    'private_limited_shares', 'frs105', 'not_registered'
);

INSERT INTO uk_accounting_periods (
    book_id, id, period_start, period_end, status
) VALUES (
    'api-company-chartless', '2026',
    DATE '2026-01-01', DATE '2026-12-31', 'open'
);

SELECT pg_temp.assert_true(
    'company metadata alone is incomplete without a usable account hierarchy',
    NOT njord.uk_company_configuration_complete('api-company-chartless')
    AND EXISTS (
	SELECT 1
	FROM api.book_page('api-company-chartless')
	WHERE component = 'configuration_check'
	  AND row_key = 'account_hierarchy'
	  AND NOT (payload ->> 'complete')::BOOLEAN
    ) AND (
	SELECT count(*) = 5
	FROM api.reports_page('api-company-chartless')
	WHERE component = 'report_option'
    )
);

SELECT * FROM api.configure_uk_company(
    p_book_id => 'api-company-chartless',
    p_legal_name => 'API Company Chartless Ltd',
    p_legal_form => 'private_limited_shares',
    p_accounting_framework => 'frs105',
    p_vat_scheme => 'not_registered',
    p_period_id => '2026',
    p_period_start => '2026-01-01',
    p_period_end => '2026-12-31'
);

SELECT pg_temp.assert_true(
    'company configuration repairs a chartless book with the standard hierarchy',
    njord.uk_company_configuration_complete('api-company-chartless')
    AND (
	SELECT count(*) = 8
	FROM accts
	WHERE book_id = 'api-company-chartless'
	  AND id IN (
	    'Assets', 'Liabilities', 'Equity', 'Income', 'Expenses',
	    'Opening Balance', 'Uncategorised Income',
	    'Uncategorised Expenses'
	  )
    ) AND (
	SELECT count(*) = 16
	FROM api.reports_page('api-company-chartless')
	WHERE component = 'report_option'
    )
);

SELECT * FROM api.create_book(
    'api-company-late-failure', 'API Company Late Failure', 'GBP', FALSE
);

CREATE FUNCTION pg_temp.reject_test_company_period()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.book_id = 'api-company-late-failure' THEN
	RAISE EXCEPTION 'deliberate late company-configuration failure'
	    USING ERRCODE = 'P0001', DETAIL = 'TEST_LATE_FAILURE';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER reject_test_company_period
    BEFORE INSERT ON uk_accounting_periods
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_test_company_period();

DO $$
BEGIN
    BEGIN
	PERFORM 1
	FROM api.configure_uk_company(
	    p_book_id => 'api-company-late-failure',
	    p_legal_name => 'API Company Late Failure Ltd',
	    p_legal_form => 'private_limited_shares',
	    p_accounting_framework => 'frs105',
	    p_vat_scheme => 'standard_invoice',
	    p_period_id => '2026',
	    p_period_start => '2026-01-01',
	    p_period_end => '2026-12-31'
	);
	RAISE EXCEPTION 'late company configuration failure did not fire'
	    USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	NULL;
    END;
END;
$$;

DROP TRIGGER reject_test_company_period ON uk_accounting_periods;

SELECT pg_temp.assert_true(
    'a late failure rolls back profile, period, and auto-created accounts',
    NOT EXISTS (
	SELECT 1 FROM uk_company_profiles
	WHERE book_id = 'api-company-late-failure'
    ) AND NOT EXISTS (
	SELECT 1 FROM uk_accounting_periods
	WHERE book_id = 'api-company-late-failure'
    ) AND NOT EXISTS (
	SELECT 1 FROM accts
	WHERE book_id = 'api-company-late-failure'
    )
);

SELECT * FROM api.create_book(
    'api-company-usd', 'API Company USD', 'USD', TRUE
);

DO $$
BEGIN
    BEGIN
	PERFORM 1
	FROM api.configure_uk_company(
	    p_book_id => 'api-company-usd',
	    p_legal_name => 'API Company USD Ltd',
	    p_legal_form => 'private_limited_shares',
	    p_accounting_framework => 'frs105',
	    p_vat_scheme => 'not_registered',
	    p_period_id => '2026',
	    p_period_start => '2026-01-01',
	    p_period_end => '2026-12-31'
	);
	RAISE EXCEPTION 'non-GBP company configuration was allowed'
	    USING ERRCODE = 'P0002';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'non-GBP company configuration leaves the ordinary book untouched',
    NOT EXISTS (
	SELECT 1 FROM uk_company_profiles WHERE book_id = 'api-company-usd'
    )
);

SELECT *
FROM api.create_account(
    'api-test',
    'Current Account',
    'A',
    'GBP',
    1,
    NULL,
    100,
    '2026-01-01'
);

SELECT pg_temp.assert_true(
    'create_account posts a balanced opening transaction',
    EXISTS (
	SELECT 1
	FROM xaction_bits
	JOIN xactions USING (book_id, xid)
	WHERE xactions.book_id = 'api-test'
	  AND xactions.comment = 'Opening balance'
	GROUP BY xaction_bits.book_id, xaction_bits.xid
	HAVING count(*) = 2 AND sum(xaction_bits.amt) = 0
    )
);

CREATE TEMP TABLE api_created_transaction AS
SELECT *
FROM api.create_transaction(
    'api-test',
    '{
      "date":"2026-01-02",
      "comment":"Groceries",
      "lines":[
        {"account":"Current Account","amount":-20},
        {"account":"Uncategorised Expenses","amount":20}
      ]
    }'::jsonb
);

SELECT pg_temp.assert_true(
    'create_transaction posts normalized lines',
    EXISTS (
	SELECT 1
	FROM api_created_transaction
	JOIN xactions USING (book_id, xid)
	WHERE xactions.comment = 'Groceries'
    )
);

SELECT pg_temp.assert_true(
    'new postings begin unreconciled',
    EXISTS (
	SELECT 1
	FROM api_created_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Current Account'
    )
);

SELECT *
FROM api_created_transaction AS transaction
CROSS JOIN LATERAL api.set_posting_reconciled(
    transaction.book_id,
    transaction.xid,
    'Current Account',
    TRUE
);

CREATE TEMP TABLE api_preserved_transaction AS
SELECT replacement.*
FROM api_created_transaction AS original
CROSS JOIN LATERAL api.replace_transaction(
    original.book_id,
    original.xid,
    '{
      "date":"2026-01-03",
      "comment":"Food shopping",
      "lines":[
	{"account":"Current Account","amount":-20},
	{"account":"Uncategorised Expenses","amount":20}
      ]
    }'::jsonb
) AS replacement;

SELECT pg_temp.assert_true(
    'replace_transaction preserves reconciliation for an unchanged account and amount',
    NOT EXISTS (
	SELECT 1
	FROM api_preserved_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Current Account'
    ) AND EXISTS (
	SELECT 1
	FROM api_preserved_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Uncategorised Expenses'
    )
);

CREATE TEMP TABLE api_replaced_transaction AS
SELECT replacement.*
FROM api_preserved_transaction AS original
CROSS JOIN LATERAL api.replace_transaction(
    original.book_id,
    original.xid,
    '{
      "date":"2026-01-03",
      "comment":"Food shopping",
      "lines":[
	{"account":"Current Account","amount":-25},
	{"account":"Uncategorised Expenses","amount":25}
      ]
    }'::jsonb
) AS replacement;

SELECT pg_temp.assert_true(
    'replace_transaction atomically replaces and reopens a changed amount',
    EXISTS (
	SELECT 1
	FROM api_replaced_transaction
	JOIN xactions USING (book_id, xid)
	WHERE xactions.date = '2026-01-03'
	  AND xactions.comment = 'Food shopping'
    ) AND (
	SELECT sum(amt) = 0 AND max(abs(amt)) = 25
	FROM xaction_bits
	JOIN api_replaced_transaction USING (book_id, xid)
    ) AND EXISTS (
	SELECT 1
	FROM api_replaced_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Current Account'
    )
);

SELECT *
FROM api_replaced_transaction AS transaction
CROSS JOIN LATERAL api.set_posting_reconciled(
    transaction.book_id,
    transaction.xid,
    'Current Account',
    TRUE
);

SELECT updated.*
FROM api_replaced_transaction AS transaction
CROSS JOIN LATERAL api.update_ledger_line(
    transaction.book_id,
    transaction.xid,
    'Current Account',
    '2026-01-04',
    'Updated food shopping'
) AS updated;

SELECT pg_temp.assert_true(
    'header-only ledger edits do not reopen a reconciled posting',
    EXISTS (
	SELECT 1
	FROM api_replaced_transaction
	JOIN xactions USING (book_id, xid)
	WHERE xactions.date = '2026-01-04'
	  AND xactions.comment = 'Updated food shopping'
    ) AND NOT EXISTS (
	SELECT 1
	FROM api_replaced_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Current Account'
    )
);

SELECT pg_temp.assert_true(
    'reconciliation page exposes posting review data and its optional account filter',
    EXISTS (
	SELECT 1
	FROM api.reconciliation_page('api-test', 'Current Account')
	JOIN api_replaced_transaction
	  ON component = 'reconciliation_row'
	 AND (payload ->> 'xid')::INTEGER = api_replaced_transaction.xid
	WHERE payload ->> 'account' = 'Current Account'
	  AND payload ->> 'asset' = 'GBP'
	  AND (payload ->> 'reconciled')::BOOLEAN
	  AND (payload ->> 'amount')::NUMERIC = -25
    ) AND (
	SELECT count(*)
	FROM api.reconciliation_page('api-test', 'Current Account')
	WHERE component = 'reconciliation_row'
    ) = (
	SELECT count(*)
	FROM xaction_bits
	WHERE book_id = 'api-test' AND acct = 'Current Account'
    ) AND (
	SELECT count(*)
	FROM api.reconciliation_page('api-test')
	WHERE component = 'reconciliation_row'
    ) = (
	SELECT count(*)
	FROM xaction_bits
	WHERE book_id = 'api-test'
    )
);

SELECT *
FROM api_replaced_transaction AS transaction
CROSS JOIN LATERAL api.set_posting_reconciled(
    transaction.book_id,
    transaction.xid,
    'Current Account',
    FALSE
);

SELECT *
FROM api_replaced_transaction AS transaction
CROSS JOIN LATERAL api.set_posting_reconciled(
    transaction.book_id,
    transaction.xid,
    'Current Account',
    FALSE
);

SELECT pg_temp.assert_true(
    'posting reconciliation mutation is idempotent in the unreconciled direction',
    (
	SELECT count(*) = 1
	FROM api_replaced_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Current Account'
    )
);

DO $$
BEGIN
    BEGIN
	PERFORM 1
	FROM api.set_posting_reconciled(
	    'api-test', -1, 'Current Account', TRUE
	);

	RAISE EXCEPTION 'missing posting reconciliation was allowed';
    EXCEPTION WHEN SQLSTATE 'PT404' THEN
	NULL;
    END;

    BEGIN
	PERFORM 1
	FROM api.set_posting_reconciled(
	    'api-test', 1, 'Current Account', NULL
	);

	RAISE EXCEPTION 'null reconciliation state was allowed';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
	NULL;
    END;
END;
$$;

CREATE TEMP TABLE api_split_transaction AS
SELECT *
FROM api.create_transaction(
    'api-test',
    '{
      "date":"2026-01-05",
      "comment":"Split description",
      "lines":[
	{"account":"Current Account","amount":-10},
	{"account":"Uncategorised Expenses","amount":6},
	{"account":"Uncategorised Income","amount":4}
      ]
    }'::jsonb
);

SELECT updated.*
FROM api_split_transaction AS transaction
CROSS JOIN LATERAL api.update_ledger_line(
    transaction.book_id,
    transaction.xid,
    'Current Account',
    '2026-01-05',
    'Split description'
) AS updated;

SELECT pg_temp.assert_true(
    'split ledger edits preserve memo normalization',
    EXISTS (
	SELECT 1
	FROM api_split_transaction
	JOIN xaction_bits USING (book_id, xid)
	WHERE xaction_bits.acct = 'Current Account'
	  AND xaction_bits.comment IS NULL
    )
);

SELECT *
FROM api_split_transaction AS transaction
CROSS JOIN LATERAL api.set_posting_reconciled(
    transaction.book_id,
    transaction.xid,
    'Uncategorised Expenses',
    TRUE
);

SELECT replacement.*
FROM api_split_transaction AS transaction
CROSS JOIN LATERAL api.replace_transaction(
    transaction.book_id,
    transaction.xid,
    '{
      "date":"2026-01-05",
      "comment":"Split description",
      "lines":[
	{"account":"Current Account","amount":-10},
	{"account":"Uncategorised Expenses","amount":6,"comment":"Revised split memo"},
	{"account":"Uncategorised Income","amount":4}
      ]
    }'::JSONB
) AS replacement;

SELECT pg_temp.assert_true(
    'replace_transaction preserves reconciliation when only a posting memo changes',
    NOT EXISTS (
	SELECT 1
	FROM api_split_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Uncategorised Expenses'
    )
);

CREATE TEMP TABLE api_account_change_transaction AS
SELECT *
FROM api.create_transaction(
    'api-test',
    '{
      "date":"2099-01-01",
      "comment":"Account change reconciliation fixture",
      "lines":[
	{"account":"Current Account","amount":-3},
	{"account":"Uncategorised Expenses","amount":3}
      ]
    }'::JSONB
);

SELECT *
FROM api_account_change_transaction AS transaction
CROSS JOIN LATERAL api.set_posting_reconciled(
    transaction.book_id,
    transaction.xid,
    'Uncategorised Expenses',
    TRUE
);

SELECT replacement.*
FROM api_account_change_transaction AS transaction
CROSS JOIN LATERAL api.replace_transaction(
    transaction.book_id,
    transaction.xid,
    '{
      "date":"2099-01-01",
      "comment":"Account change reconciliation fixture",
      "lines":[
	{"account":"Current Account","amount":-3},
	{"account":"Uncategorised Income","amount":3}
      ]
    }'::JSONB
) AS replacement;

SELECT pg_temp.assert_true(
    'replace_transaction reopens a posting whose account changes',
    EXISTS (
	SELECT 1
	FROM api_account_change_transaction
	JOIN unreconciled_postings USING (book_id, xid)
	WHERE acct = 'Uncategorised Income'
    ) AND NOT EXISTS (
	SELECT 1
	FROM api_account_change_transaction
	JOIN xaction_bits USING (book_id, xid)
	WHERE acct = 'Uncategorised Expenses'
    )
);

CALL create_simple_xaction(
    'api-test',
    '2026-06-01 12:00:00',
    'Current Account',
    'Uncategorised Expenses',
    -10
);

SELECT pg_temp.assert_true(
    'date-valued report pages include the entire final day',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'profit-loss', NULL, '2026-06-01', '2026-06-01'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE component = 'generic_report_row'
	  AND payload ->> 'row_kind' = 'account'
	  AND payload ->> 'account_id' = 'Uncategorised Expenses'
	  AND cell ->> 'column_id' = 'posttax'
	  AND (cell ->> 'number')::NUMERIC = 10
    ) AND (
	SELECT cell ->> 'number'
	FROM api.report_page(
	    'api-test', 'balance-sheet', '2026-06-01', NULL, NULL
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND report.payload ->> 'account_id' = 'Current Account'
	  AND cell ->> 'column_id' = 'posttax'
    ) IS DISTINCT FROM (
	SELECT cell ->> 'number'
	FROM api.report_page(
	    'api-test', 'balance-sheet', '2026-05-31', NULL, NULL
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE report.component = 'generic_report_row'
	  AND report.payload ->> 'account_id' = 'Current Account'
	  AND cell ->> 'column_id' = 'posttax'
    )
);

SELECT pg_temp.assert_true(
    'empty income and expense periods retain a zero total',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'profit-loss', NULL, '1900-01-01', '1900-01-02'
	) AS report
	CROSS JOIN LATERAL jsonb_array_elements(report.payload -> 'cells') AS cell
	WHERE component = 'generic_report_row'
	  AND payload ->> 'row_kind' = 'grand_total'
	  AND cell ->> 'column_id' = 'posttax'
	  AND (cell ->> 'number')::NUMERIC = 0
    )
);

SELECT pg_temp.assert_true(
    'period pages return authoritative range validation',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'profit-loss', NULL, '2026-12-31', '2026-01-01'
	)
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages' @>
	      '["The start date must not be after the end date."]'::JSONB
    )
);

SELECT pg_temp.assert_true(
    'cash flow pages report missing cash-account configuration',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'cash-flow', NULL, '2026-01-01', '2026-12-31'
	)
	WHERE component = 'page_context'
	  AND jsonb_array_length(payload -> 'validation_messages') > 0
    )
);

SELECT *
FROM api.create_account(
    'api-test',
    'Unvalued EUR',
    'A',
    'EUR',
    1,
    NULL,
    1,
    '2026-01-01'
);

SELECT pg_temp.assert_true(
    'report pages expose missing valuation state',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'balance-sheet', '2026-12-31', NULL, NULL
	)
	WHERE component = 'page_context'
	  AND payload ->> 'validation_messages' LIKE '%Missing valuations%Unvalued EUR%'
    )
);

SELECT pg_temp.assert_true(
    'net worth reports expose missing market valuation state',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', '2026-12-31', NULL, NULL
	)
	WHERE component = 'page_context'
	  AND payload ->> 'validation_messages' LIKE '%Missing valuations%Unvalued EUR%'
    )
);

SELECT pg_temp.assert_true(
    'report validation does not flag zero reporting-asset accounts',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'personal', 'trial-balance', '2026-12-31', NULL, NULL
	)
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages' = '[]'::JSONB
    )
);

SELECT pg_temp.assert_true(
    'shell page returns navigation only; page payloads stay page-specific',
    EXISTS (
	SELECT 1 FROM api.shell_page('api-test') WHERE component = 'book_option'
    ) AND NOT EXISTS (
	SELECT 1 FROM api.shell_page('api-test')
	WHERE component IN ('report_option', 'account_option')
    )
);

SELECT pg_temp.assert_true(
    'reports workspace contains only financial report choices',
    (
	SELECT array_agg(payload ->> 'id' ORDER BY row_order)
	FROM api.reports_page('api-test')
	WHERE component = 'report_option'
    ) = ARRAY['balance-sheet', 'net-worth', 'trial-balance', 'profit-loss', 'cash-flow']
);

SELECT pg_temp.assert_true(
    'reports workspace validates its book context',
    EXISTS (
	SELECT 1
	FROM api.reports_page('missing-book')
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages' = '["Book does not exist."]'::JSONB
    )
);

SELECT pg_temp.assert_true(
    'accounts workspace returns every active-book account with SQL balances',
    (
	SELECT count(*)
	FROM api.accounts_page('api-test')
	WHERE component = 'account_row'
    ) = (
	SELECT count(*)
	FROM accts
	WHERE book_id = 'api-test'
    ) AND NOT EXISTS (
	SELECT 1
	FROM api.accounts_page('api-test') AS page
	JOIN accts
	  ON accts.book_id = 'api-test'
	 AND accts.id = page.payload ->> 'id'
	WHERE page.component = 'account_row'
	  AND (
	    page.payload ->> 'book_id' IS DISTINCT FROM accts.book_id
	    OR page.payload ->> 'type' IS DISTINCT FROM accts.type
	    OR page.payload ->> 'asset' IS DISTINCT FROM accts.atype
	    OR (page.payload ->> 'balance')::NUMERIC IS DISTINCT FROM (
		SELECT COALESCE(sum(xaction_bits.amt), 0)
		FROM xaction_bits
		WHERE xaction_bits.book_id = accts.book_id
		  AND xaction_bits.acct = accts.id
	    )
	  )
    )
);

INSERT INTO valuations (date, src, dst, rate)
VALUES (CURRENT_TIMESTAMP + INTERVAL '1 year', 'XAU', 'GBP', 9999);

INSERT INTO account_valuations (book_id, acct, date, dst, value, comment)
VALUES (
    'demo', '12 Acacia Avenue', CURRENT_TIMESTAMP + INTERVAL '1 year',
    'GBP', 999999,
    'Future illustrative estimate'
);

SELECT pg_temp.assert_true(
    'accounts workspace aggregates hierarchy counts and current valuations',
    (
	SELECT (payload ->> 'reporting_value')::NUMERIC = 425000
	   AND (payload ->> 'balance')::NUMERIC = 325000
	FROM api.accounts_page('demo')
	WHERE component = 'account_row'
	  AND row_key = '12 Acacia Avenue'
    ) AND (
	SELECT (payload ->> 'reporting_value')::NUMERIC =
	       (payload ->> 'balance')::NUMERIC * (
		SELECT rate
		FROM valuations
		WHERE src = 'XAU' AND dst = 'GBP'
		  AND date <= CURRENT_TIMESTAMP
		ORDER BY date DESC
		LIMIT 1
	       )
	   AND payload ->> 'asset' = 'XAU'
	FROM api.accounts_page('demo')
	WHERE component = 'account_row'
	  AND row_key = 'Gold Bullion'
    ) AND (
	SELECT (payload ->> 'reporting_value')::NUMERIC = (
		SELECT sum((holding.payload ->> 'reporting_value')::NUMERIC)
		FROM api.accounts_page('demo') AS holding
		WHERE holding.component = 'account_row'
		  AND holding.row_key IN (
		      'Gold Bullion', 'Silver Bullion', 'Global Equity ETF'
		  )
	    )
	   AND NOT (payload ->> 'subtree_balance_complete')::BOOLEAN
	FROM api.accounts_page('demo')
	WHERE component = 'account_row'
	  AND row_key = 'Investments'
    ) AND (
	SELECT (payload ->> 'posting_count')::BIGINT >
	       (
		SELECT count(*)
		FROM xaction_bits
		WHERE book_id = 'demo' AND acct = 'Assets'
	       )
	FROM api.accounts_page('demo')
	WHERE component = 'account_row'
	  AND row_key = 'Assets'
    )
);

SELECT *
FROM api.create_account(
    'api-test',
    'Empty JPY',
    'A',
    'JPY',
    1,
    NULL,
    NULL,
    NULL
);

SELECT pg_temp.assert_true(
    'empty commodity accounts do not require a valuation',
    (
	SELECT (payload ->> 'reporting_value')::NUMERIC = 0
	FROM api.accounts_page('api-test')
	WHERE component = 'account_row'
	  AND row_key = 'Empty JPY'
    )
);

SELECT pg_temp.assert_true(
    'Balance Sheet values zero foreign balances without hiding missing rates',
    NOT EXISTS (
	SELECT 1
	FROM valuations
	WHERE src = 'JPY' AND dst = 'GBP' AND date <= '2026-12-31'
    ) AND EXISTS (
	SELECT 1
	FROM bsheet_report('api-test', '2026-12-31 23:59:59')
	WHERE row_kind = 'account'
	  AND account = 'Empty JPY'
	  AND posttax = 0
    ) AND EXISTS (
	SELECT 1
	FROM bsheet_report('api-test', '2026-12-31 23:59:59')
	WHERE row_kind = 'account'
	  AND account = 'Unvalued EUR'
	  AND posttax IS NULL
    )
);

SELECT pg_temp.assert_true(
    'accounts workspace validates its active book context',
    EXISTS (
	SELECT 1
	FROM api.accounts_page('missing-book')
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages' = '["Book does not exist."]'::JSONB
    ) AND NOT EXISTS (
	SELECT 1
	FROM api.accounts_page('missing-book')
	WHERE component = 'account_row'
    )
);

SELECT pg_temp.assert_true(
    'accounts workspace includes context and cash-account classification',
    EXISTS (
	SELECT 1
	FROM api.accounts_page('api-test')
	WHERE component = 'page_context'
	  AND payload ->> 'reporting_asset' = 'GBP'
	  AND (payload ->> 'account_count')::BIGINT = (
	      SELECT count(*) FROM accts WHERE book_id = 'api-test'
	  )
    ) AND EXISTS (
	SELECT 1
	FROM api.accounts_page('personal')
	WHERE component = 'account_row'
	  AND payload ->> 'id' = 'Current GBP'
	  AND (payload ->> 'is_cash_account')::BOOLEAN
    )
);

SELECT pg_temp.assert_true(
    'default shell page lists books without silently selecting one',
    EXISTS (
	SELECT 1
	FROM api.shell_page()
	WHERE component = 'book_option'
    ) AND NOT EXISTS (
	SELECT 1
	FROM api.shell_page()
	WHERE component = 'book_option'
	  AND (payload ->> 'selected')::BOOLEAN
    )
);

SELECT pg_temp.assert_true(
    'ledger page is complete in one function',
    EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'ledger_row'
	  AND payload ->> 'description' = 'Updated food shopping'
    ) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'account_option'
	  AND row_key = 'Uncategorised Expenses'
    ) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('personal', 'Current GBP')
	WHERE component = 'account_option'
	  AND row_key = 'Broker USD'
	) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'ledger_row'
	  AND jsonb_array_length(payload -> 'split_lines') = 2
	  AND NOT payload ? 'reconciled'
	) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'page_context'
	  AND payload #>> '{transaction_rules,minimum_lines}' = '2'
	) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'book_option'
    )
);

SELECT pg_temp.assert_true(
    'all Book-local UI pages have canonical SQL functions',
    EXISTS (SELECT 1 FROM api.book_page('api-test') WHERE component = 'book_identity')
    AND EXISTS (SELECT 1 FROM api.reports_page('api-test') WHERE component = 'report_option')
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', '2026-12-31', NULL, NULL
	)
	WHERE component = 'generic_report_row'
    )
    AND EXISTS (SELECT 1 FROM api.accounts_page('api-test') WHERE component = 'account_row')
    AND EXISTS (SELECT 1 FROM api.reconciliation_page('api-test') WHERE component = 'reconciliation_row')
    AND EXISTS (SELECT 1 FROM api.general_journal_page('api-test') WHERE component = 'journal_row')
    AND EXISTS (SELECT 1 FROM api.add_account_page('api-test') WHERE component = 'account_type_option')
);

SELECT pg_temp.assert_true(
    'SQL owns three complete display-language catalogues and their flag choices',
    (
        SELECT count(*) = 3
        FROM presentation.locales
        WHERE enabled AND complete
    )
    AND NOT EXISTS (
        SELECT locale, semantic_key
        FROM presentation.locales
        CROSS JOIN (
            SELECT semantic_key
            FROM presentation.messages
            WHERE locale = 'en-GB'
        ) AS canonical
        WHERE enabled AND complete
        EXCEPT
        SELECT locale, semantic_key
        FROM presentation.messages
    )
    AND (
        SELECT string_agg(payload ->> 'flag', ',' ORDER BY row_order)
        FROM api.presentation_catalogue('en-GB')
        WHERE component = 'language_option'
    ) = '🇬🇧,🇵🇦,🇹🇼'
    AND EXISTS (
        SELECT 1
        FROM api.presentation_catalogue('es-MX')
        WHERE row_key = 'nav.accounts'
          AND payload ->> 'text' = 'Cuentas'
          AND payload ->> 'locale' = 'es-PA'
    )
    AND EXISTS (
        SELECT 1
        FROM api.presentation_catalogue('zh-HK')
        WHERE row_key = 'nav.accounts'
          AND payload ->> 'text' = '科目'
          AND payload ->> 'locale' = 'zh-TW'
    )
    AND presentation.text('entity.company', 'es') = 'Empresa'
    AND presentation.text('entity.company', 'zh') = '公司'
    AND presentation.text('nav.help', 'en') = 'Help'
    AND presentation.text('nav.help', 'es') = 'Ayuda'
    AND presentation.text('nav.help', 'zh') = '說明'
);

SELECT pg_temp.assert_true(
    'generic report pages carry their complete database-defined presentation',
    EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', '2026-12-31', NULL, NULL
	)
	WHERE component = 'report_definition'
	  AND payload ->> 'title' = 'Net Worth'
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', '2026-12-31', NULL, NULL
	)
	WHERE component = 'report_column'
	  AND payload ->> 'column_id' = 'account'
	  AND (payload ->> 'tree_column')::BOOLEAN
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', '2026-12-31', NULL, NULL
	)
	WHERE component = 'bar_chart_definition'
	  AND payload ->> 'chart_id' = 'net-worth-history'
    )
    AND (
	SELECT count(*) = 12
	FROM api.report_page(
	    'api-test', 'net-worth', '2026-12-31', NULL, NULL
	)
	WHERE component = 'bar_chart_point'
    )
    AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'profit-loss', NULL, '2026-01-01', '2026-12-31'
	)
	WHERE component = 'generic_report_row'
	  AND payload ->> 'row_kind' = 'grand_total'
	  AND payload @> '{"cells":[{"column_id":"account"}]}'::JSONB
    )
);

SELECT pg_temp.assert_true(
    'every page function includes the application shell',
    NOT EXISTS (
	SELECT page_name
	FROM (VALUES
	    ('book_page'),
	    ('reports_page'),
	    ('report_page'),
	    ('accounts_page'),
	    ('reconciliation_page'),
	    ('general_journal_page'),
	    ('add_account_page')
	) AS required_pages(page_name)
	WHERE CASE page_name
	    WHEN 'book_page' THEN NOT EXISTS (
		SELECT 1 FROM api.book_page('api-test')
		WHERE component = 'book_option'
	    )
	    WHEN 'reports_page' THEN NOT EXISTS (
		SELECT 1 FROM api.reports_page('api-test')
		WHERE component = 'book_option'
	    )
	    WHEN 'report_page' THEN NOT EXISTS (
		SELECT 1 FROM api.report_page(
		    'api-test', 'balance-sheet', '2026-12-31', NULL, NULL
		)
		WHERE component = 'book_option'
	    )
	    WHEN 'accounts_page' THEN NOT EXISTS (
		SELECT 1 FROM api.accounts_page('api-test')
		WHERE component = 'book_option'
	    )
	    WHEN 'reconciliation_page' THEN NOT EXISTS (
		SELECT 1 FROM api.reconciliation_page('api-test')
		WHERE component = 'book_option'
	    )
	    WHEN 'general_journal_page' THEN NOT EXISTS (
		SELECT 1 FROM api.general_journal_page('api-test')
		WHERE component = 'book_option'
	    )
	    WHEN 'add_account_page' THEN NOT EXISTS (
		SELECT 1 FROM api.add_account_page('api-test')
		WHERE component = 'book_option'
	    )
	END
    )
);

CREATE TEMP TABLE page_contract AS
SELECT 'shell'::TEXT AS page_name, * FROM api.shell_page('api-test')
UNION ALL
SELECT 'ledger', * FROM api.ledger_page('api-test', 'Current Account')
UNION ALL
SELECT 'book', * FROM api.book_page('api-test')
UNION ALL
SELECT 'reports', * FROM api.reports_page('api-test')
UNION ALL
SELECT 'report', * FROM api.report_page(
    'api-test', 'net-worth', '2026-12-31', NULL, NULL
)
UNION ALL
SELECT 'accounts', * FROM api.accounts_page('api-test')
UNION ALL
SELECT 'reconciliation', * FROM api.reconciliation_page('api-test')
UNION ALL
SELECT 'general-journal', * FROM api.general_journal_page('api-test')
UNION ALL
SELECT 'add-account', * FROM api.add_account_page('api-test');

SELECT pg_temp.assert_true(
    'every page row has a complete stable ordering contract',
    NOT EXISTS (
	SELECT 1
	FROM page_contract
	WHERE component IS NULL
	   OR row_order IS NULL
	   OR row_key IS NULL
	   OR payload IS NULL
    ) AND NOT EXISTS (
	SELECT page_name, row_order
	FROM page_contract
	GROUP BY page_name, row_order
	HAVING count(*) > 1
    )
);

SELECT pg_temp.assert_true(
    'add-account page returns database defaults and validation state',
    EXISTS (
	SELECT 1
	FROM api.add_account_page('api-test')
	WHERE component = 'page_context'
	  AND payload ->> 'account_type' = 'A'
	  AND payload ->> 'asset' = 'GBP'
	  AND payload ->> 'opening_date' = CURRENT_DATE::TEXT
	  AND (payload #>> '{validation,opening_date_required_with_balance}')::BOOLEAN
    )
);

SELECT pg_temp.assert_true(
    'page functions report invalid navigation parameters',
    EXISTS (
	SELECT 1
	FROM api.ledger_page('missing-book', 'missing-account')
	WHERE component = 'page_context'
	  AND jsonb_array_length(payload -> 'validation_messages') > 0
    ) AND EXISTS (
	SELECT 1
	FROM api.reconciliation_page('api-test', 'missing-account')
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages'
	      = '["Account does not exist in this book."]'::JSONB
    ) AND EXISTS (
	SELECT 1
	FROM api.general_journal_page('missing-book')
	WHERE component = 'page_context'
	  AND jsonb_array_length(payload -> 'validation_messages') > 0
    ) AND EXISTS (
	SELECT 1
	FROM api.add_account_page('missing-book')
	WHERE component = 'page_context'
	  AND jsonb_array_length(payload -> 'validation_messages') > 0
	) AND EXISTS (
	SELECT 1
	FROM api.add_account_page('api-test', 'missing-parent')
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages'
	      = '["Parent account does not exist in this book."]'::JSONB
    )
);

SELECT * FROM api.set_book_reporting_currency(
    'api-test', 'USD', DATE '2026-07-01'
);

SELECT pg_temp.assert_true(
    'active books keep an effective-dated reporting-currency history',
    njord.book_reporting_asset_at('api-test', DATE '2026-06-30') = 'GBP'
    AND njord.book_reporting_asset_at('api-test', DATE '2026-07-01') = 'USD'
    AND (
	SELECT count(*) = 2
	FROM book_reporting_currencies
	WHERE book_id = 'api-test'
    ) AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'balance-sheet', DATE '2026-06-30', NULL, NULL
	)
	WHERE component = 'page_context'
	  AND payload ->> 'reporting_asset' = 'GBP'
    ) AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'balance-sheet', DATE '2026-07-01', NULL, NULL
	)
	WHERE component = 'page_context'
	  AND payload ->> 'reporting_asset' = 'USD'
	) AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', DATE '2026-06-30', NULL, NULL
	)
	WHERE component = 'report_definition'
	  AND payload ->> 'reporting_asset' = 'GBP'
	) AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', DATE '2026-06-30', NULL, NULL
	)
	WHERE component = 'bar_chart_point'
	  AND payload ->> 'suffix' = 'GBP'
	) AND NOT EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', DATE '2026-06-30', NULL, NULL
	)
	WHERE component = 'bar_chart_point'
	  AND payload ->> 'suffix' IS DISTINCT FROM 'GBP'
	) AND EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', DATE '2026-07-01', NULL, NULL
	)
	WHERE component = 'report_definition'
	  AND payload ->> 'reporting_asset' = 'USD'
	) AND NOT EXISTS (
	SELECT 1
	FROM api.report_page(
	    'api-test', 'net-worth', DATE '2026-07-01', NULL, NULL
	)
	WHERE component = 'bar_chart_point'
	  AND payload ->> 'suffix' IS DISTINCT FROM 'USD'
	)
);

SELECT * FROM api.create_book(
    'api-delete', 'Delete Me', 'GBP', TRUE, 'household'
);

SELECT * FROM api.create_account(
    p_book_id => 'api-delete',
    p_id => 'Bank',
    p_parent_id => 'Assets',
    p_account_kind => 'bank',
    p_opening_balance => 10,
    p_opening_date => DATE '2026-01-01'
);

SELECT * FROM api.archive_book('api-delete');

SELECT pg_temp.assert_true(
    'archive is reversible and hides a book from ordinary navigation',
    EXISTS (
	SELECT 1 FROM books
	WHERE id = 'api-delete' AND archived_at IS NOT NULL
    ) AND NOT EXISTS (
	SELECT 1 FROM api.shell_page(NULL)
	WHERE component = 'book_option' AND row_key = 'api-delete'
    )
);

SELECT * FROM api.restore_book('api-delete');

SELECT pg_temp.assert_true(
    'restore returns an archived book to ordinary navigation',
    EXISTS (
	SELECT 1 FROM books
	WHERE id = 'api-delete' AND archived_at IS NULL
    ) AND EXISTS (
	SELECT 1 FROM api.shell_page(NULL)
	WHERE component = 'book_option' AND row_key = 'api-delete'
    )
);

DO $$
DECLARE
    linked RECORD;
    draft JSONB;
BEGIN
    SELECT payment.book_id, payment.xid, payment.acct,
	posting.id AS posting_id, transaction.date, transaction.comment
    INTO STRICT linked
    FROM panama_reportable_payments AS payment
    JOIN xaction_bits AS posting
      ON posting.book_id = payment.book_id
     AND posting.xid = payment.xid
     AND posting.acct = payment.acct
    JOIN xactions AS transaction
      ON transaction.book_id = payment.book_id
     AND transaction.xid = payment.xid
    WHERE payment.book_id = 'panama-property'
    ORDER BY payment.xid, payment.acct
    LIMIT 1;

    SELECT jsonb_build_object(
	'date', linked.date::DATE,
	'comment', linked.comment,
	'lines', jsonb_agg(
	    jsonb_build_object(
		'account', posting.acct,
		'amount', posting.amt,
		'comment', posting.comment
	    ) ORDER BY posting.id
	)
    )
    INTO draft
    FROM xaction_bits AS posting
    WHERE posting.book_id = linked.book_id
      AND posting.xid = linked.xid;

    PERFORM * FROM api.replace_transaction(linked.book_id, linked.xid, draft);

    IF NOT EXISTS (
	SELECT 1
	FROM panama_reportable_payments AS payment
	JOIN xaction_bits AS posting
	  ON posting.book_id = payment.book_id
	 AND posting.xid = payment.xid
	 AND posting.acct = payment.acct
	WHERE payment.book_id = linked.book_id
	  AND payment.xid = linked.xid
	  AND payment.acct = linked.acct
	  AND posting.id = linked.posting_id
    ) THEN
	RAISE EXCEPTION 'transaction replacement discarded linked posting evidence';
    END IF;
END;
$$;

DO $$
DECLARE
    invoice RECORD;
BEGIN
    SELECT book_id, xid, control_acct, issued_on
    INTO STRICT invoice
    FROM trade_invoices
    WHERE book_id = 'uk-business'
    ORDER BY id
    LIMIT 1;

    BEGIN
	PERFORM * FROM api.update_ledger_line(
	    invoice.book_id, invoice.xid, invoice.control_acct,
	    invoice.issued_on + 1, 'Invalid invoice-date edit'
	);
	SET CONSTRAINTS xactions_preserve_trade_invoice_date IMMEDIATE;
	RAISE EXCEPTION 'a ledger edit broke the linked trade-invoice date';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

DO $$
DECLARE
    checked_xid INTEGER;
BEGIN
    SELECT xid INTO STRICT checked_xid
    FROM taiwan_withholding_payments
    WHERE book_id = 'taiwan-injection'
    ORDER BY id
    LIMIT 1;

    BEGIN
	UPDATE xactions SET date = date + INTERVAL '1 day'
	WHERE book_id = 'taiwan-injection' AND xid = checked_xid;
	SET CONSTRAINTS xactions_preserve_taiwan_ledger_dates IMMEDIATE;
	RAISE EXCEPTION 'a ledger edit broke the linked withholding-payment date';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    SELECT xid INTO STRICT checked_xid
    FROM taiwan_inventory_movements
    WHERE book_id = 'taiwan-injection'
      AND id = 'MV-ENC-FG';

    BEGIN
	UPDATE xactions SET date = date + INTERVAL '1 day'
	WHERE book_id = 'taiwan-injection' AND xid = checked_xid;
	SET CONSTRAINTS xactions_preserve_taiwan_ledger_dates IMMEDIATE;
	RAISE EXCEPTION 'a ledger edit broke the linked inventory-movement date';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    SELECT xid INTO STRICT checked_xid
    FROM taiwan_uniform_invoices
    WHERE book_id = 'taiwan-injection'
      AND id = 'UI-ACCOUNTANT';

    BEGIN
	UPDATE xactions SET date = date + INTERVAL '1 day'
	WHERE book_id = 'taiwan-injection' AND xid = checked_xid;
	SET CONSTRAINTS xactions_preserve_taiwan_ledger_dates IMMEDIATE;
	RAISE EXCEPTION 'a ledger edit broke the linked uniform-invoice date';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

DO $$
DECLARE
    evidence RECORD;
BEGIN
    SELECT payment.book_id, payment.xid, payment.acct
    INTO STRICT evidence
    FROM panama_reportable_payments AS payment
    WHERE payment.book_id = 'panama-property'
    ORDER BY payment.xid, payment.acct
    LIMIT 1;

    BEGIN
	UPDATE xaction_bits SET amt = -amt
	WHERE book_id = evidence.book_id
	  AND xid = evidence.xid
	  AND acct = evidence.acct;
	SET CONSTRAINTS xaction_bits_preserve_panama_payment_evidence IMMEDIATE;
	RAISE EXCEPTION 'a tagged Panama payment became an incoming posting';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    SELECT invoice.book_id, invoice.xid, invoice.net_acct AS acct
    INTO STRICT evidence
    FROM taiwan_uniform_invoices AS invoice
    WHERE invoice.book_id = 'taiwan-injection'
      AND invoice.id = 'UI-ACCOUNTANT';

    BEGIN
	UPDATE xaction_bits SET amt = -amt
	WHERE book_id = evidence.book_id
	  AND xid = evidence.xid
	  AND acct = evidence.acct;
	SET CONSTRAINTS xaction_bits_preserve_taiwan_evidence IMMEDIATE;
	RAISE EXCEPTION 'a Taiwan purchase invoice acquired a sale-sign posting';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    SELECT movement.book_id, movement.xid, item.inventory_acct AS acct
    INTO STRICT evidence
    FROM taiwan_inventory_movements AS movement
    JOIN taiwan_inventory_items AS item
      ON item.book_id = movement.book_id
     AND item.id = movement.item_id
    WHERE movement.book_id = 'taiwan-injection'
      AND movement.id = 'MV-ENC-FG';

    BEGIN
	UPDATE xaction_bits SET amt = -amt
	WHERE book_id = evidence.book_id
	  AND xid = evidence.xid
	  AND acct = evidence.acct;
	SET CONSTRAINTS xaction_bits_preserve_taiwan_evidence IMMEDIATE;
	RAISE EXCEPTION 'a Taiwan inventory receipt acquired an issue-sign posting';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    SELECT payment.book_id, payment.xid, payment.gross_acct AS acct
    INTO STRICT evidence
    FROM taiwan_withholding_payments AS payment
    WHERE payment.book_id = 'taiwan-injection'
    ORDER BY payment.id
    LIMIT 1;

    BEGIN
	UPDATE xaction_bits SET amt = -amt
	WHERE book_id = evidence.book_id
	  AND xid = evidence.xid
	  AND acct = evidence.acct;
	SET CONSTRAINTS xaction_bits_preserve_taiwan_evidence IMMEDIATE;
	RAISE EXCEPTION 'a Taiwan withholding payment acquired an invalid gross posting';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

-- Jurisdiction metadata is a two-sided contract: changing the account later
-- must not invalidate mappings, controls, property roles, or linked evidence.
DO $$
BEGIN
    BEGIN
	UPDATE accts
	SET type = 'E', parent_id = 'Expenses'
	WHERE book_id = 'panama-property' AND id = 'Residential Rent';
	SET CONSTRAINTS accts_preserve_panama_relations IMMEDIATE;
	RAISE EXCEPTION 'a Panama mapped account acquired an incompatible type';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts SET atype = 'USD'
	WHERE book_id = 'panama-property' AND id = 'ITBMS Payable';
	SET CONSTRAINTS accts_preserve_panama_relations IMMEDIATE;
	RAISE EXCEPTION 'a Panama control account left the reporting asset';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts SET account_kind = 'posting'
	WHERE book_id = 'panama-property' AND id = 'Marina Vista Land';
	SET CONSTRAINTS accts_preserve_panama_relations IMMEDIATE;
	RAISE EXCEPTION 'a Panama property account lost its fixed-asset kind';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts SET placeholder = TRUE
	WHERE book_id = 'panama-property' AND id = 'Operating Bank';
	SET CONSTRAINTS accts_preserve_panama_relations IMMEDIATE;
	RAISE EXCEPTION 'a Panama payment account became a placeholder';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts
	SET type = 'E', parent_id = 'Expenses'
	WHERE book_id = 'taiwan-injection' AND id = 'Domestic Product Sales';
	SET CONSTRAINTS accts_preserve_taiwan_relations IMMEDIATE;
	RAISE EXCEPTION 'a Taiwan mapped account acquired an incompatible type';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts
	SET type = 'E', parent_id = 'Expenses'
	WHERE book_id = 'taiwan-injection' AND id = 'ABS Resin Inventory';
	SET CONSTRAINTS accts_preserve_taiwan_relations IMMEDIATE;
	RAISE EXCEPTION 'a Taiwan inventory account became an expense account';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    BEGIN
	UPDATE accts
	SET type = 'A', parent_id = 'Current Assets'
	WHERE book_id = 'taiwan-injection' AND id = 'Withholding Tax Payable';
	SET CONSTRAINTS accts_preserve_taiwan_relations IMMEDIATE;
	RAISE EXCEPTION 'a Taiwan evidence account acquired an incompatible type';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;
