-- UK business reference data and preparation reports.
--

-- This production pack defines working papers and supporting schedules.  It
-- does not submit returns or claim to produce filing-ready accounts.

-- UK reporting reference classifications. A book becomes a configured UK
-- company only when it has a uk_company_profiles row.
CREATE TABLE uk_company_legal_forms (
	id VARCHAR PRIMARY KEY,
	label VARCHAR NOT NULL
);

CREATE TABLE uk_accounting_frameworks (
	id VARCHAR PRIMARY KEY,
	label VARCHAR NOT NULL
);

CREATE TABLE uk_vat_schemes (
	id VARCHAR PRIMARY KEY,
	label VARCHAR NOT NULL
);

CREATE TABLE uk_period_statuses (
	id VARCHAR PRIMARY KEY,
	label VARCHAR NOT NULL
);

CREATE TABLE uk_statutory_lines (
	id VARCHAR PRIMARY KEY,
	statement VARCHAR NOT NULL,
	label VARCHAR NOT NULL,
	parent_id VARCHAR REFERENCES uk_statutory_lines(id),
	required_type VARCHAR REFERENCES acct_types(id),
	display_order INTEGER NOT NULL,
	mappable BOOLEAN NOT NULL DEFAULT TRUE,

	CHECK (statement IN ('balance_sheet', 'profit_loss', 'equity')),
	CHECK (display_order >= 0),
	CHECK (parent_id IS NULL OR parent_id <> id)
);

CREATE TABLE uk_corporation_tax_treatments (
	id VARCHAR PRIMARY KEY,
	label VARCHAR NOT NULL,
	required_type VARCHAR REFERENCES acct_types(id),
	effect VARCHAR NOT NULL,
	default_inclusion_percent NUMERIC(6,4) NOT NULL DEFAULT 1,

	CHECK (effect IN (
	    'taxable_income', 'deductible_expense', 'disallowable_expense',
	    'non_taxable', 'capital_allowance_pool', 'manual_adjustment',
	    'excluded_from_profit_before_tax'
	)),
	CHECK (
	    default_inclusion_percent >= 0
	    AND default_inclusion_percent <= 1
	)
);

CREATE TABLE uk_vat_behaviours (
	id VARCHAR PRIMARY KEY,
	label VARCHAR NOT NULL,
	transaction_role VARCHAR NOT NULL,
	vat_rate NUMERIC(6,4) NOT NULL,
	recoverable_rate NUMERIC(6,4) NOT NULL,
	tax_box SMALLINT,
	net_box SMALLINT,

	CHECK (transaction_role IN ('sale', 'purchase')),
	CONSTRAINT uk_vat_behaviours_vat_rate_range CHECK (
	    vat_rate BETWEEN 0 AND 1 AND njord.is_finite(vat_rate)
	),
	CHECK (recoverable_rate >= 0 AND recoverable_rate <= 1),
	CHECK (tax_box IS NULL OR tax_box BETWEEN 1 AND 9),
	CHECK (net_box IS NULL OR net_box BETWEEN 1 AND 9)
);

CREATE TABLE uk_company_profiles (
	book_id VARCHAR PRIMARY KEY REFERENCES books(id),
	legal_name VARCHAR NOT NULL,
	company_number VARCHAR,
	legal_form VARCHAR NOT NULL REFERENCES uk_company_legal_forms(id),
	accounting_framework VARCHAR NOT NULL REFERENCES uk_accounting_frameworks(id),
	utr VARCHAR,
	vat_registration_number VARCHAR,
	vat_scheme VARCHAR NOT NULL REFERENCES uk_vat_schemes(id),
	registered_office VARCHAR,
	incorporated_on DATE,
	notes VARCHAR,

	CHECK (btrim(legal_name) <> ''),
	CHECK (company_number IS NULL OR btrim(company_number) <> ''),
	CHECK (utr IS NULL OR btrim(utr) <> ''),
	CHECK (
	    vat_registration_number IS NULL
	    OR btrim(vat_registration_number) <> ''
	),
	CHECK (incorporated_on IS NULL OR isfinite(incorporated_on))
);

CREATE TABLE uk_accounting_periods (
	book_id VARCHAR NOT NULL REFERENCES uk_company_profiles(book_id),
	id VARCHAR NOT NULL,
	period_start DATE NOT NULL,
	period_end DATE NOT NULL,
	status VARCHAR NOT NULL REFERENCES uk_period_statuses(id),
	accounts_due_on DATE,
	corporation_tax_due_on DATE,
	accounts_filed_on DATE,
	ct600_filed_on DATE,
	notes VARCHAR,

	PRIMARY KEY (book_id, id),
	UNIQUE (book_id, period_start, period_end),
	CHECK (btrim(id) <> ''),
	CHECK (period_start <= period_end),
	CONSTRAINT uk_accounting_periods_finite_dates CHECK (
	    isfinite(period_start) AND isfinite(period_end)
	    AND (accounts_due_on IS NULL OR isfinite(accounts_due_on))
	    AND (corporation_tax_due_on IS NULL OR isfinite(corporation_tax_due_on))
	    AND (accounts_filed_on IS NULL OR isfinite(accounts_filed_on))
	    AND (ct600_filed_on IS NULL OR isfinite(ct600_filed_on))
	)
);

CREATE OR REPLACE FUNCTION validate_uk_accounting_period()
RETURNS trigger AS $$
BEGIN
    PERFORM 1
    FROM books
    WHERE books.id = NEW.book_id
    FOR UPDATE;

    IF EXISTS (
	SELECT 1
	FROM uk_accounting_periods AS existing
	WHERE existing.book_id = NEW.book_id
	  AND existing.id <> NEW.id
	  AND daterange(existing.period_start, existing.period_end, '[]')
	      && daterange(NEW.period_start, NEW.period_end, '[]')
    ) THEN
	RAISE EXCEPTION 'UK accounting period %.% overlaps another period',
	    NEW.book_id,
	    NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_accounting_periods_no_overlap';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER uk_accounting_periods_validate
    BEFORE INSERT OR UPDATE OF book_id, id, period_start, period_end
    ON uk_accounting_periods
    FOR EACH ROW
    EXECUTE FUNCTION validate_uk_accounting_period();

COMMENT ON TABLE uk_company_profiles IS
    'Optional per-book UK company identity and filing-policy configuration; UK reports require this profile plus a period and any required VAT control mapping.';
COMMENT ON TABLE uk_accounting_periods IS
    'Explicit non-overlapping UK accounts and Corporation Tax reporting periods.';
COMMENT ON TABLE uk_statutory_lines IS
    'Extensible statutory statement taxonomy used by explicit account mappings.';
COMMENT ON TABLE uk_corporation_tax_treatments IS
    'Extensible Corporation Tax effects; percentages are fractions between zero and one.';
COMMENT ON TABLE uk_vat_behaviours IS
    'UK VAT sale/purchase behaviours including rate, recovery, and VAT-return boxes.';

CREATE TABLE uk_account_statutory_mappings (
	book_id VARCHAR NOT NULL,
	acct VARCHAR NOT NULL,
	line_id VARCHAR NOT NULL REFERENCES uk_statutory_lines(id),
	notes VARCHAR,

	PRIMARY KEY (book_id, acct),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id)
);

CREATE TABLE uk_account_corporation_tax_mappings (
	book_id VARCHAR NOT NULL,
	acct VARCHAR NOT NULL,
	treatment_id VARCHAR NOT NULL REFERENCES uk_corporation_tax_treatments(id),
	inclusion_percent NUMERIC(6,4) NOT NULL DEFAULT 1,
	notes VARCHAR,

	PRIMARY KEY (book_id, acct),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
	CHECK (inclusion_percent >= 0 AND inclusion_percent <= 1)
);

CREATE TABLE uk_account_vat_mappings (
	book_id VARCHAR NOT NULL,
	acct VARCHAR NOT NULL,
	transaction_role VARCHAR NOT NULL,
	behaviour_id VARCHAR NOT NULL REFERENCES uk_vat_behaviours(id),
	notes VARCHAR,

	PRIMARY KEY (book_id, acct, transaction_role),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
	CHECK (transaction_role IN ('sale', 'purchase'))
);

CREATE OR REPLACE FUNCTION validate_uk_statutory_line()
RETURNS trigger AS $$
DECLARE
    parent_statement VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-uk-reference-data', 0)
    );
    PERFORM 1
    FROM books
    WHERE id IN (
        SELECT mapping.book_id
        FROM uk_account_statutory_mappings AS mapping
        WHERE mapping.line_id = NEW.id
    )
    ORDER BY id
    FOR UPDATE;

    IF NEW.parent_id IS NOT NULL THEN
	SELECT statement INTO parent_statement
	FROM uk_statutory_lines
	WHERE id = NEW.parent_id;

	IF FOUND AND parent_statement <> NEW.statement THEN
	    RAISE EXCEPTION 'UK statutory line % and parent % belong to different statements',
		NEW.id, NEW.parent_id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_statutory_line_parent_statement';
	END IF;

	IF EXISTS (
	    WITH RECURSIVE ancestors AS (
		SELECT id, parent_id FROM uk_statutory_lines
		WHERE id = NEW.parent_id
		UNION ALL
		SELECT parent.id, parent.parent_id
		FROM uk_statutory_lines AS parent
		JOIN ancestors AS child ON child.parent_id = parent.id
	    )
	    SELECT 1 FROM ancestors WHERE id = NEW.id
	) THEN
	    RAISE EXCEPTION 'UK statutory line % would create a cycle', NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_statutory_line_cycle';
	END IF;
    END IF;

    IF EXISTS (
	SELECT 1
	FROM uk_statutory_lines AS child
	WHERE child.parent_id = NEW.id
	  AND child.statement <> NEW.statement
    ) THEN
	RAISE EXCEPTION 'UK statutory line % and an existing child belong to different statements', NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_statutory_line_child_statement';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM uk_account_statutory_mappings AS mapping
	JOIN accts
	  ON accts.book_id = mapping.book_id
	 AND accts.id = mapping.acct
	WHERE mapping.line_id = NEW.id
	  AND (
	      NOT NEW.mappable
	      OR (NEW.required_type IS NOT NULL AND accts.type <> NEW.required_type)
	  )
    ) THEN
	RAISE EXCEPTION 'UK statutory line % is incompatible with existing mappings', NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_statutory_line_existing_mappings';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION validate_uk_account_mapping()
RETURNS trigger AS $$
DECLARE
    mapped_type VARCHAR;
    mapped_placeholder BOOLEAN;
    required_type VARCHAR;
    expected_role VARCHAR;
    can_map BOOLEAN;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-uk-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT type, placeholder
    INTO mapped_type, mapped_placeholder
    FROM accts
    WHERE book_id = NEW.book_id
      AND id = NEW.acct;

    -- Let the composite FK report a missing account normally.
    IF NOT FOUND THEN
	RETURN NEW;
    END IF;

    IF mapped_placeholder THEN
	RAISE EXCEPTION 'UK account mapping %.% requires a posting account',
	    NEW.book_id,
	    NEW.acct
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_account_mapping_posting_account';
    END IF;

    IF TG_TABLE_NAME = 'uk_account_statutory_mappings' THEN
	SELECT line.required_type, line.mappable
	INTO required_type, can_map
	FROM uk_statutory_lines AS line
	WHERE line.id = NEW.line_id;

	IF FOUND AND NOT can_map THEN
	    RAISE EXCEPTION 'UK statutory line % is a computed line and cannot receive account mappings',
		NEW.line_id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_statutory_line_mappable';
	END IF;
    ELSIF TG_TABLE_NAME = 'uk_account_corporation_tax_mappings' THEN
	SELECT treatment.required_type
	INTO required_type
	FROM uk_corporation_tax_treatments AS treatment
	WHERE treatment.id = NEW.treatment_id;
    ELSIF TG_TABLE_NAME = 'uk_account_vat_mappings' THEN
	SELECT behaviour.transaction_role
	INTO expected_role
	FROM uk_vat_behaviours AS behaviour
	WHERE behaviour.id = NEW.behaviour_id;

	IF FOUND AND expected_role <> NEW.transaction_role THEN
	    RAISE EXCEPTION 'VAT behaviour % is for %, not %',
		NEW.behaviour_id,
		expected_role,
		NEW.transaction_role
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_vat_mapping_role';
	END IF;

	IF NEW.transaction_role = 'sale' AND mapped_type <> 'I' THEN
	    RAISE EXCEPTION 'sale VAT mappings require an income account'
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_vat_mapping_account_type';
	ELSIF NEW.transaction_role = 'purchase'
	      AND mapped_type NOT IN ('E', 'A') THEN
	    RAISE EXCEPTION 'purchase VAT mappings require an expense or asset account'
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_vat_mapping_account_type';
	END IF;
    END IF;

    IF required_type IS NOT NULL AND required_type <> mapped_type THEN
	RAISE EXCEPTION 'UK mapping requires account type %, not %',
	    required_type,
	    mapped_type
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_account_mapping_account_type';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER uk_account_statutory_mapping_validate
    BEFORE INSERT OR UPDATE ON uk_account_statutory_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_uk_account_mapping();

CREATE TRIGGER uk_account_corporation_tax_mapping_validate
    BEFORE INSERT OR UPDATE ON uk_account_corporation_tax_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_uk_account_mapping();

CREATE TRIGGER uk_account_vat_mapping_validate
    BEFORE INSERT OR UPDATE ON uk_account_vat_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_uk_account_mapping();

CREATE TRIGGER uk_statutory_lines_validate
    BEFORE INSERT OR UPDATE ON uk_statutory_lines
    FOR EACH ROW EXECUTE FUNCTION validate_uk_statutory_line();

CREATE OR REPLACE FUNCTION protect_uk_treatment_mappings()
RETURNS trigger AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-uk-reference-data', 0)
    );
    PERFORM 1
    FROM books
    WHERE id IN (
        SELECT mapping.book_id
        FROM uk_account_corporation_tax_mappings AS mapping
        WHERE TG_TABLE_NAME = 'uk_corporation_tax_treatments'
          AND mapping.treatment_id = NEW.id
        UNION
        SELECT mapping.book_id
        FROM uk_account_vat_mappings AS mapping
        WHERE TG_TABLE_NAME = 'uk_vat_behaviours'
          AND mapping.behaviour_id = NEW.id
    )
    ORDER BY id
    FOR UPDATE;

    IF TG_TABLE_NAME = 'uk_corporation_tax_treatments' THEN
	IF EXISTS (
	    SELECT 1
	    FROM uk_account_corporation_tax_mappings AS mapping
	    JOIN accts
	      ON accts.book_id = mapping.book_id
	     AND accts.id = mapping.acct
	    WHERE mapping.treatment_id = NEW.id
	      AND NEW.required_type IS NOT NULL
	      AND accts.type <> NEW.required_type
	) THEN
	    RAISE EXCEPTION 'Corporation Tax treatment % is incompatible with existing mappings', NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_tax_treatment_existing_mappings';
	END IF;
    ELSIF TG_TABLE_NAME = 'uk_vat_behaviours' THEN
	IF EXISTS (
	    SELECT 1
	    FROM uk_account_vat_mappings AS mapping
	    WHERE mapping.behaviour_id = NEW.id
	      AND mapping.transaction_role <> NEW.transaction_role
	) THEN
	    RAISE EXCEPTION 'VAT behaviour % role is required by existing mappings', NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'uk_vat_behaviour_existing_mappings';
	END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER uk_corporation_tax_treatments_protect_mappings
    BEFORE UPDATE ON uk_corporation_tax_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_uk_treatment_mappings();

CREATE TRIGGER uk_vat_behaviours_protect_mappings
    BEFORE UPDATE ON uk_vat_behaviours
    FOR EACH ROW EXECUTE FUNCTION protect_uk_treatment_mappings();

COMMENT ON TABLE uk_account_statutory_mappings IS
    'One explicit statutory statement classification per posting account.';
COMMENT ON TABLE uk_account_corporation_tax_mappings IS
    'Per-account Corporation Tax treatment and inclusion fraction.';
COMMENT ON TABLE uk_account_vat_mappings IS
    'Per-account UK VAT behaviour, separately classifiable for sales and purchases.';

CREATE TABLE uk_company_control_accounts (
    book_id VARCHAR PRIMARY KEY REFERENCES uk_company_profiles(book_id),
    vat_control_acct VARCHAR NOT NULL,

    FOREIGN KEY (book_id, vat_control_acct)
	REFERENCES accts(book_id, id)
);

CREATE OR REPLACE FUNCTION validate_uk_company_control_accounts()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF NOT EXISTS (
	SELECT 1
	FROM accts
	JOIN books ON books.id = accts.book_id
	WHERE accts.book_id = NEW.book_id
	  AND accts.id = NEW.vat_control_acct
	  AND accts.type = 'L'
	  AND NOT accts.placeholder
	  AND accts.atype = books.reporting_asset
    ) THEN
	RAISE EXCEPTION 'VAT control account %.% must be a posting liability in the book reporting asset',
	    NEW.book_id, NEW.vat_control_acct
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_vat_control_liability_account';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER uk_company_control_accounts_validate
    BEFORE INSERT OR UPDATE ON uk_company_control_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_uk_company_control_accounts();

COMMENT ON TABLE uk_company_control_accounts IS
    'Explicit ledger control accounts used to reconcile UK preparation working papers.';

-- Account-side protection complements the mapping-table validators above.
-- Keep it deferred so coordinated account and mapping updates can complete in
-- either statement order within one transaction.
CREATE OR REPLACE FUNCTION enforce_uk_account_invariants()
RETURNS trigger AS $$
BEGIN
    IF EXISTS (
	SELECT 1
	FROM uk_company_control_accounts
	JOIN books ON books.id = uk_company_control_accounts.book_id
	WHERE uk_company_control_accounts.book_id = NEW.book_id
	  AND uk_company_control_accounts.vat_control_acct = NEW.id
	  AND (
	      NEW.type <> 'L'
	      OR NEW.placeholder
	      OR NEW.atype <> books.reporting_asset
	  )
    ) THEN
	RAISE EXCEPTION 'VAT control account %.% must remain a posting liability in the book reporting asset',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_vat_control_liability_account';
    END IF;

    IF NEW.placeholder AND (
	EXISTS (
	    SELECT 1 FROM uk_account_statutory_mappings
	    WHERE book_id = NEW.book_id AND acct = NEW.id
	) OR EXISTS (
	    SELECT 1 FROM uk_account_corporation_tax_mappings
	    WHERE book_id = NEW.book_id AND acct = NEW.id
	) OR EXISTS (
	    SELECT 1 FROM uk_account_vat_mappings
	    WHERE book_id = NEW.book_id AND acct = NEW.id
	)
    ) THEN
	RAISE EXCEPTION 'mapped UK account %.% must remain a posting account',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_account_mapping_posting_account';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM uk_account_statutory_mappings AS mapping
	JOIN uk_statutory_lines AS line ON line.id = mapping.line_id
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND line.required_type IS NOT NULL
	  AND line.required_type <> NEW.type
    ) OR EXISTS (
	SELECT 1
	FROM uk_account_corporation_tax_mappings AS mapping
	JOIN uk_corporation_tax_treatments AS treatment
	  ON treatment.id = mapping.treatment_id
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND treatment.required_type IS NOT NULL
	  AND treatment.required_type <> NEW.type
    ) OR EXISTS (
	SELECT 1
	FROM uk_account_vat_mappings AS mapping
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND (
	      (mapping.transaction_role = 'sale' AND NEW.type <> 'I')
	      OR (mapping.transaction_role = 'purchase'
		  AND NEW.type NOT IN ('E', 'A'))
	  )
    ) THEN
	RAISE EXCEPTION 'account %.% type is incompatible with its UK mappings',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'uk_account_mapping_account_type';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER accts_uk_account_invariants
    AFTER UPDATE ON accts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION enforce_uk_account_invariants();

-- Extensible UK reporting reference data. These are classifications only;
-- company identities, periods, mappings, invoices, and payments belong to a
-- particular book and are never seeded here.
INSERT INTO uk_company_legal_forms (id, label) VALUES
    ('private_limited_shares', 'Private company limited by shares'),
    ('private_limited_guarantee', 'Private company limited by guarantee'),
    ('public_limited', 'Public limited company'),
    ('llp', 'Limited liability partnership');

INSERT INTO uk_accounting_frameworks (id, label) VALUES
    ('frs105', 'FRS 105 micro-entities regime'),
    ('frs102_section_1a', 'FRS 102 Section 1A small entities'),
    ('frs102', 'FRS 102');

INSERT INTO uk_vat_schemes (id, label) VALUES
    ('not_registered', 'Not VAT registered'),
    ('standard_invoice', 'Standard invoice accounting'),
    ('cash_accounting', 'Cash Accounting Scheme'),
    ('flat_rate', 'Flat Rate Scheme');

INSERT INTO uk_period_statuses (id, label) VALUES
    ('open', 'Open'),
    ('closed', 'Closed'),
    ('filed', 'Filed');

INSERT INTO uk_statutory_lines (
    id, statement, label, parent_id, required_type, display_order, mappable
) VALUES
    ('fixed_assets', 'balance_sheet', 'Fixed assets', NULL, 'A', 100, TRUE),
    ('intangible_assets', 'balance_sheet', 'Intangible assets', 'fixed_assets', 'A', 110, TRUE),
    ('tangible_assets', 'balance_sheet', 'Tangible assets', 'fixed_assets', 'A', 120, TRUE),
    ('investments_fixed_assets', 'balance_sheet', 'Investments', 'fixed_assets', 'A', 130, TRUE),
    ('current_assets', 'balance_sheet', 'Current assets', NULL, 'A', 200, TRUE),
    ('stocks', 'balance_sheet', 'Stocks', 'current_assets', 'A', 210, TRUE),
    ('debtors', 'balance_sheet', 'Debtors', 'current_assets', 'A', 220, TRUE),
    ('cash_at_bank_and_in_hand', 'balance_sheet', 'Cash at bank and in hand', 'current_assets', 'A', 230, TRUE),
    ('prepayments_and_accrued_income', 'balance_sheet', 'Prepayments and accrued income', 'current_assets', 'A', 240, TRUE),
    ('creditors_due_within_one_year', 'balance_sheet', 'Creditors: amounts falling due within one year', NULL, 'L', 300, TRUE),
    ('net_current_assets_liabilities', 'balance_sheet', 'Net current assets (liabilities)', NULL, NULL, 400, FALSE),
    ('total_assets_less_current_liabilities', 'balance_sheet', 'Total assets less current liabilities', NULL, NULL, 500, FALSE),
    ('creditors_due_after_one_year', 'balance_sheet', 'Creditors: amounts falling due after more than one year', NULL, 'L', 600, TRUE),
    ('provisions_for_liabilities', 'balance_sheet', 'Provisions for liabilities', NULL, 'L', 700, TRUE),
    ('net_assets_liabilities', 'balance_sheet', 'Net assets (liabilities)', NULL, NULL, 800, FALSE),
    ('called_up_share_capital', 'balance_sheet', 'Called up share capital', NULL, 'Q', 900, TRUE),
    ('share_premium', 'balance_sheet', 'Share premium account', NULL, 'Q', 910, TRUE),
    ('profit_and_loss_account', 'balance_sheet', 'Profit and loss account', NULL, 'Q', 920, TRUE),
    ('other_reserves', 'balance_sheet', 'Other reserves', NULL, 'Q', 930, TRUE),
    ('shareholders_funds', 'balance_sheet', 'Shareholders funds', NULL, NULL, 1000, FALSE),
    ('turnover', 'profit_loss', 'Turnover', NULL, 'I', 100, TRUE),
    ('cost_of_sales', 'profit_loss', 'Cost of sales', NULL, 'E', 200, TRUE),
    ('gross_profit_loss', 'profit_loss', 'Gross profit (loss)', NULL, NULL, 300, FALSE),
    ('distribution_costs', 'profit_loss', 'Distribution costs', NULL, 'E', 400, TRUE),
    ('administrative_expenses', 'profit_loss', 'Administrative expenses', NULL, 'E', 500, TRUE),
    ('other_operating_income', 'profit_loss', 'Other operating income', NULL, 'I', 600, TRUE),
    ('operating_profit_loss', 'profit_loss', 'Operating profit (loss)', NULL, NULL, 700, FALSE),
    ('interest_receivable', 'profit_loss', 'Interest receivable and similar income', NULL, 'I', 800, TRUE),
    ('interest_payable', 'profit_loss', 'Interest payable and similar expenses', NULL, 'E', 900, TRUE),
    ('profit_loss_before_tax', 'profit_loss', 'Profit (loss) before tax', NULL, NULL, 1000, FALSE),
    ('tax_on_profit', 'profit_loss', 'Tax on profit or loss', NULL, 'E', 1100, TRUE),
    ('profit_loss_after_tax', 'profit_loss', 'Profit (loss) after tax', NULL, NULL, 1200, FALSE),
    ('equity_opening', 'equity', 'Equity at start of period', NULL, NULL, 100, FALSE),
    ('equity_profit_loss', 'equity', 'Profit or loss for period', NULL, NULL, 200, FALSE),
    ('equity_contributions', 'equity', 'Capital introduced', NULL, 'Q', 300, TRUE),
    ('equity_distributions', 'equity', 'Distributions', NULL, 'Q', 400, TRUE),
    ('equity_closing', 'equity', 'Equity at end of period', NULL, NULL, 500, FALSE);

INSERT INTO uk_corporation_tax_treatments (
    id, label, required_type, effect, default_inclusion_percent
) VALUES
    ('trading_income', 'Taxable trading income', 'I', 'taxable_income', 1),
    ('other_taxable_income', 'Other taxable income', 'I', 'taxable_income', 1),
    ('exempt_income', 'Exempt or non-taxable income', 'I', 'non_taxable', 1),
    ('allowable_expense', 'Allowable revenue expense', 'E', 'deductible_expense', 1),
    ('disallowable_expense', 'Disallowable expense', 'E', 'disallowable_expense', 1),
    ('accounts_tax_charge', 'Tax charge excluded from accounting profit before tax', 'E',
	'excluded_from_profit_before_tax', 1),
    ('capital_allowance_pool', 'Capital allowances pool', 'A', 'capital_allowance_pool', 1),
    ('manual_adjustment', 'Manual tax computation adjustment', NULL, 'manual_adjustment', 1);

INSERT INTO uk_vat_behaviours (
    id, label, transaction_role, vat_rate, recoverable_rate, tax_box, net_box
) VALUES
    ('sale_standard', 'Standard-rated sale', 'sale', 0.2000, 0, 1, 6),
    ('sale_reduced', 'Reduced-rated sale', 'sale', 0.0500, 0, 1, 6),
    ('sale_zero', 'Zero-rated sale', 'sale', 0, 0, 1, 6),
    ('sale_exempt', 'Exempt sale', 'sale', 0, 0, NULL, 6),
    ('sale_outside_scope', 'Sale outside the scope of UK VAT', 'sale', 0, 0, NULL, NULL),
    ('purchase_standard', 'Standard-rated recoverable purchase', 'purchase', 0.2000, 1, 4, 7),
    ('purchase_blocked', 'Standard-rated purchase with blocked input VAT', 'purchase', 0.2000, 0, NULL, 7),
    ('purchase_reduced', 'Reduced-rated recoverable purchase', 'purchase', 0.0500, 1, 4, 7),
    ('purchase_zero', 'Zero-rated purchase', 'purchase', 0, 0, 4, 7),
    ('purchase_exempt', 'Exempt purchase', 'purchase', 0, 0, NULL, 7),
    ('purchase_outside_scope', 'Purchase outside the scope of UK VAT', 'purchase', 0, 0, NULL, NULL);

CREATE OR REPLACE VIEW uk_report_catalog AS
    SELECT reports.*, 'uk_company'::VARCHAR AS profile_kind
    FROM (VALUES
	(10, 'uk-statutory-profit-loss'::VARCHAR, 'UK Statutory Profit & Loss'::VARCHAR,
	    'Companies Act preparation support driven by the book''s statutory account mappings; not filing-ready.'::VARCHAR,
	    'period'::VARCHAR, 'UK statutory accounts'::VARCHAR),
	(11, 'uk-statutory-balance-sheet'::VARCHAR, 'UK Statutory Balance Sheet'::VARCHAR,
	    'Companies Act balance-sheet preparation headings; not filing-ready accounts.'::VARCHAR,
	    'as_of'::VARCHAR, 'UK statutory accounts'::VARCHAR),
	(12, 'changes-in-equity'::VARCHAR, 'Statement of Changes in Equity'::VARCHAR,
	    'Preparation schedule for opening equity, movements, profit or loss, and closing equity.'::VARCHAR,
	    'period'::VARCHAR, 'UK statutory accounts'::VARCHAR),
	(13, 'uk-statutory-notes'::VARCHAR, 'UK Statutory Notes Checklist'::VARCHAR,
	    'Preparation support and schedule checks; not filing-ready prose or iXBRL.'::VARCHAR,
	    'as_of'::VARCHAR, 'UK statutory accounts'::VARCHAR),
	(20, 'corporation-tax'::VARCHAR, 'Corporation Tax Computation'::VARCHAR,
	    'Tax-adjusted profit support from explicit Corporation Tax mappings; no filing calculation.'::VARCHAR,
	    'period'::VARCHAR, 'HMRC'::VARCHAR),
	(21, 'vat-return'::VARCHAR, 'VAT Return Working Paper'::VARCHAR,
	    'Nine-box working paper from mapped transaction-date postings; review obligation dates and VAT-control reconciliation.'::VARCHAR,
	    'period'::VARCHAR, 'HMRC'::VARCHAR),
	(30, 'vat-detail'::VARCHAR, 'VAT Detail'::VARCHAR,
	    'Posting-level VAT audit trail behind the VAT return.'::VARCHAR,
	    'period'::VARCHAR, 'Supporting schedules'::VARCHAR),
	(31, 'fixed-asset-schedule'::VARCHAR, 'Fixed Asset Ledger Schedule'::VARCHAR,
	    'Account-level opening book value, movement, closing value, and latest estimate; not a full asset register.'::VARCHAR,
	    'period'::VARCHAR, 'Supporting schedules'::VARCHAR),
	(32, 'director-loan-schedule'::VARCHAR, 'Director Loan Schedule'::VARCHAR,
	    'Ledger movements for accounts explicitly classified as director loans.'::VARCHAR,
	    'period'::VARCHAR, 'Supporting schedules'::VARCHAR),
	(33, 'aged-debtors'::VARCHAR, 'Aged Debtors'::VARCHAR,
	    'Outstanding customer invoices aged from their due dates.'::VARCHAR,
	    'as_of'::VARCHAR, 'Supporting schedules'::VARCHAR),
	(34, 'aged-creditors'::VARCHAR, 'Aged Creditors'::VARCHAR,
	    'Outstanding supplier invoices aged from their due dates.'::VARCHAR,
	    'as_of'::VARCHAR, 'Supporting schedules'::VARCHAR)
    ) AS reports(
	report_order, report_id, title, description, parameter_kind,
	report_group
    );

CREATE OR REPLACE VIEW uk_report_columns AS
    SELECT *
    FROM (VALUES
	('uk-statutory-profit-loss', 1, 'description', 'Statutory heading', 'left', 'text', FALSE),
	('uk-statutory-profit-loss', 2, 'amount', 'Current period', 'right', 'number', FALSE),
	('uk-statutory-profit-loss', 3, 'basis', 'Mapping basis', 'left', 'text', FALSE),
	('uk-statutory-balance-sheet', 1, 'description', 'Statutory heading', 'left', 'text', FALSE),
	('uk-statutory-balance-sheet', 2, 'amount', 'At reporting date', 'right', 'number', FALSE),
	('uk-statutory-balance-sheet', 3, 'basis', 'Mapping basis', 'left', 'text', FALSE),
	('changes-in-equity', 1, 'movement', 'Movement', 'left', 'text', FALSE),
	('changes-in-equity', 2, 'amount', 'Total equity', 'right', 'number', FALSE),
	('corporation-tax', 1, 'item', 'Computation item', 'left', 'text', FALSE),
	('corporation-tax', 2, 'amount', 'Amount', 'right', 'number', FALSE),
	('corporation-tax', 3, 'basis', 'Tax treatment', 'left', 'text', FALSE),
	('vat-return', 1, 'box', 'Box', 'left', 'text', FALSE),
	('vat-return', 2, 'description', 'Description', 'left', 'text', FALSE),
	('vat-return', 3, 'amount', 'Amount', 'right', 'number', FALSE),
	('vat-detail', 1, 'date', 'Date', 'left', 'text', FALSE),
	('vat-detail', 2, 'counterparty', 'Counterparty', 'left', 'text', FALSE),
	('vat-detail', 3, 'reference', 'Reference', 'left', 'text', FALSE),
	('vat-detail', 4, 'account', 'Account', 'left', 'text', FALSE),
	('vat-detail', 5, 'net', 'Net', 'right', 'number', FALSE),
	('vat-detail', 6, 'vat', 'VAT', 'right', 'number', FALSE),
	('vat-detail', 7, 'recoverable', 'Recoverable VAT', 'right', 'number', FALSE),
	('vat-detail', 8, 'behaviour', 'VAT behaviour', 'left', 'text', FALSE),
	('fixed-asset-schedule', 1, 'asset', 'Fixed asset', 'left', 'text', FALSE),
	('fixed-asset-schedule', 2, 'opening', 'Opening book value', 'right', 'number', FALSE),
	('fixed-asset-schedule', 3, 'movement', 'Net ledger movement', 'right', 'number', FALSE),
	('fixed-asset-schedule', 4, 'closing', 'Closing book value', 'right', 'number', FALSE),
	('fixed-asset-schedule', 5, 'estimate', 'Latest estimate', 'right', 'number', FALSE),
	('director-loan-schedule', 1, 'account', 'Director loan account', 'left', 'text', FALSE),
	('director-loan-schedule', 2, 'opening', 'Opening balance', 'right', 'number', FALSE),
	('director-loan-schedule', 3, 'debits', 'Debits / advances', 'right', 'number', FALSE),
	('director-loan-schedule', 4, 'credits', 'Credits / repayments', 'right', 'number', FALSE),
	('director-loan-schedule', 5, 'closing', 'Closing balance', 'right', 'number', FALSE),
	('aged-debtors', 1, 'party', 'Customer', 'left', 'text', FALSE),
	('aged-debtors', 2, 'invoice', 'Invoice', 'left', 'text', FALSE),
	('aged-debtors', 3, 'issued', 'Issued', 'left', 'text', FALSE),
	('aged-debtors', 4, 'due', 'Due', 'left', 'text', FALSE),
	('aged-debtors', 5, 'current', 'Current', 'right', 'number', FALSE),
	('aged-debtors', 6, 'days_1_30', '1–30 days', 'right', 'number', FALSE),
	('aged-debtors', 7, 'days_31_60', '31–60 days', 'right', 'number', FALSE),
	('aged-debtors', 8, 'days_61_90', '61–90 days', 'right', 'number', FALSE),
	('aged-debtors', 9, 'days_91_plus', '91+ days', 'right', 'number', FALSE),
	('aged-debtors', 10, 'total', 'Outstanding', 'right', 'number', FALSE),
	('aged-creditors', 1, 'party', 'Supplier', 'left', 'text', FALSE),
	('aged-creditors', 2, 'invoice', 'Invoice', 'left', 'text', FALSE),
	('aged-creditors', 3, 'issued', 'Issued', 'left', 'text', FALSE),
	('aged-creditors', 4, 'due', 'Due', 'left', 'text', FALSE),
	('aged-creditors', 5, 'current', 'Current', 'right', 'number', FALSE),
	('aged-creditors', 6, 'days_1_30', '1–30 days', 'right', 'number', FALSE),
	('aged-creditors', 7, 'days_31_60', '31–60 days', 'right', 'number', FALSE),
	('aged-creditors', 8, 'days_61_90', '61–90 days', 'right', 'number', FALSE),
	('aged-creditors', 9, 'days_91_plus', '91+ days', 'right', 'number', FALSE),
	('aged-creditors', 10, 'total', 'Outstanding', 'right', 'number', FALSE),
	('uk-statutory-notes', 1, 'disclosure', 'Disclosure / check', 'left', 'text', FALSE),
	('uk-statutory-notes', 2, 'value', 'Value', 'left', 'text', FALSE),
	('uk-statutory-notes', 3, 'status', 'Preparation status', 'left', 'text', FALSE)
    ) AS columns(
	report_id, column_order, column_id, label, alignment, value_format,
	tree_column
    );

CREATE OR REPLACE FUNCTION uk_statutory_statement_values(
    b VARCHAR,
    requested_statement VARCHAR,
    start_date TIMESTAMP,
    end_date TIMESTAMP
)
RETURNS TABLE (
    line_id VARCHAR,
    label VARCHAR,
    display_order INTEGER,
    mappable BOOLEAN,
    amount NUMERIC,
    mapped_accounts BIGINT
)
LANGUAGE SQL
STABLE
AS $$
    WITH RECURSIVE line_closure AS (
	SELECT lines.id AS ancestor_id, lines.id AS descendant_id
	FROM uk_statutory_lines AS lines
	WHERE lines.statement = requested_statement
	UNION ALL
	SELECT closure.ancestor_id, child.id
	FROM line_closure AS closure
	JOIN uk_statutory_lines AS child
	  ON child.parent_id = closure.descendant_id
	 AND child.statement = requested_statement
    ),
    mapped_account_values AS (
	SELECT
	    mappings.line_id,
	    accts.id AS acct,
	    accts.type,
	    njord.sum_if_complete(
		CASE WHEN posting.amount = 0 THEN 0
		     ELSE posting.reporting_amount END
	    ) FILTER (WHERE posting.xid IS NOT NULL) AS ledger_amount
	FROM uk_account_statutory_mappings AS mappings
	JOIN accts
	  ON accts.book_id = mappings.book_id
	 AND accts.id = mappings.acct
	LEFT JOIN report_postings AS posting
	  ON posting.book_id = accts.book_id
	 AND posting.account_id = accts.id
	 AND posting.transaction_date <= end_date
	 AND (
		requested_statement <> 'profit_loss'
		OR start_date IS NULL
		OR posting.transaction_date >= start_date
	 )
	WHERE mappings.book_id = b
	  AND EXISTS (
	    SELECT 1
	    FROM uk_statutory_lines AS mapped_line
	    WHERE mapped_line.id = mappings.line_id
	      AND mapped_line.statement = requested_statement
	  )
	GROUP BY mappings.line_id, accts.id, accts.type
    ),
    presented_account_values AS (
	SELECT
	    line_id,
	    acct,
	    CASE
		WHEN type = 'A' THEN ledger_amount
		WHEN type IN ('I', 'L', 'Q') THEN -ledger_amount
		ELSE ledger_amount
	    END AS amount
	FROM mapped_account_values
    ),
    rolled AS (
	SELECT
	    lines.id AS line_id,
	    lines.label,
	    lines.display_order,
	    lines.mappable,
	    njord.sum_if_complete(values_for_descendants.amount)
		FILTER (WHERE values_for_descendants.acct IS NOT NULL) AS amount,
	    count(values_for_descendants.acct)::BIGINT AS mapped_accounts
	FROM uk_statutory_lines AS lines
	LEFT JOIN line_closure AS closure
	  ON closure.ancestor_id = lines.id
	LEFT JOIN presented_account_values AS values_for_descendants
	  ON values_for_descendants.line_id = closure.descendant_id
	WHERE lines.statement = requested_statement
	GROUP BY lines.id, lines.label, lines.display_order, lines.mappable
    ),
    cumulative_earnings AS (
	SELECT njord.sum_if_complete(
	    CASE WHEN posting.amount = 0 THEN 0
		 ELSE -posting.reporting_amount END
	) AS amount
	FROM report_postings AS posting
	WHERE posting.book_id = b
	  AND posting.account_type IN ('I', 'E')
	  AND posting.transaction_date <= end_date
    ),
    adjusted AS (
	SELECT
	    rolled.line_id,
	    rolled.label,
	    rolled.display_order,
	    rolled.mappable,
	    CASE
		WHEN requested_statement = 'balance_sheet'
		 AND rolled.line_id = 'profit_and_loss_account'
		THEN rolled.amount + cumulative_earnings.amount
		ELSE rolled.amount
	    END AS amount,
	    rolled.mapped_accounts
	FROM rolled
	CROSS JOIN cumulative_earnings
    ),
    calculated AS (
	SELECT
	    adjusted.line_id,
	    adjusted.label,
	    adjusted.display_order,
	    adjusted.mappable,
	    CASE adjusted.line_id
		WHEN 'gross_profit_loss' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'turnover')
		    - (SELECT amount FROM adjusted WHERE line_id = 'cost_of_sales')
		WHEN 'operating_profit_loss' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'turnover')
		    - (SELECT amount FROM adjusted WHERE line_id = 'cost_of_sales')
		    - (SELECT amount FROM adjusted WHERE line_id = 'distribution_costs')
		    - (SELECT amount FROM adjusted WHERE line_id = 'administrative_expenses')
		    + (SELECT amount FROM adjusted WHERE line_id = 'other_operating_income')
		WHEN 'profit_loss_before_tax' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'turnover')
		    - (SELECT amount FROM adjusted WHERE line_id = 'cost_of_sales')
		    - (SELECT amount FROM adjusted WHERE line_id = 'distribution_costs')
		    - (SELECT amount FROM adjusted WHERE line_id = 'administrative_expenses')
		    + (SELECT amount FROM adjusted WHERE line_id = 'other_operating_income')
		    + (SELECT amount FROM adjusted WHERE line_id = 'interest_receivable')
		    - (SELECT amount FROM adjusted WHERE line_id = 'interest_payable')
		WHEN 'profit_loss_after_tax' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'turnover')
		    - (SELECT amount FROM adjusted WHERE line_id = 'cost_of_sales')
		    - (SELECT amount FROM adjusted WHERE line_id = 'distribution_costs')
		    - (SELECT amount FROM adjusted WHERE line_id = 'administrative_expenses')
		    + (SELECT amount FROM adjusted WHERE line_id = 'other_operating_income')
		    + (SELECT amount FROM adjusted WHERE line_id = 'interest_receivable')
		    - (SELECT amount FROM adjusted WHERE line_id = 'interest_payable')
		    - (SELECT amount FROM adjusted WHERE line_id = 'tax_on_profit')
		WHEN 'net_current_assets_liabilities' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'current_assets')
		    - (SELECT amount FROM adjusted WHERE line_id = 'creditors_due_within_one_year')
		WHEN 'total_assets_less_current_liabilities' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'fixed_assets')
		    + (SELECT amount FROM adjusted WHERE line_id = 'current_assets')
		    - (SELECT amount FROM adjusted WHERE line_id = 'creditors_due_within_one_year')
		WHEN 'net_assets_liabilities' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'fixed_assets')
		    + (SELECT amount FROM adjusted WHERE line_id = 'current_assets')
		    - (SELECT amount FROM adjusted WHERE line_id = 'creditors_due_within_one_year')
		    - (SELECT amount FROM adjusted WHERE line_id = 'creditors_due_after_one_year')
		    - (SELECT amount FROM adjusted WHERE line_id = 'provisions_for_liabilities')
		WHEN 'shareholders_funds' THEN
		    (SELECT amount FROM adjusted WHERE line_id = 'called_up_share_capital')
		    + (SELECT amount FROM adjusted WHERE line_id = 'share_premium')
		    + (SELECT amount FROM adjusted WHERE line_id = 'profit_and_loss_account')
		    + (SELECT amount FROM adjusted WHERE line_id = 'other_reserves')
		ELSE adjusted.amount
	    END::NUMERIC AS amount,
	    adjusted.mapped_accounts
	FROM adjusted
    )
    SELECT
	calculated.line_id,
	calculated.label,
	calculated.display_order,
	calculated.mappable,
	round(calculated.amount, 2),
	calculated.mapped_accounts
    FROM calculated
    ORDER BY calculated.display_order, calculated.line_id;
$$;

CREATE OR REPLACE FUNCTION uk_vat_posting_values(
    b VARCHAR,
    start_date TIMESTAMP,
    end_date TIMESTAMP
)
RETURNS TABLE (
    xaction_bit_id INTEGER,
    posting_date DATE,
    counterparty VARCHAR,
    reference VARCHAR,
    account VARCHAR,
    behaviour VARCHAR,
    transaction_role VARCHAR,
    tax_box SMALLINT,
    net_box SMALLINT,
    net_amount NUMERIC,
    vat_amount NUMERIC,
    recoverable_vat NUMERIC
)
LANGUAGE SQL
STABLE
AS $$
    WITH posting_inputs AS (
	SELECT
	    posting.posting_id AS id,
	    posting.transaction_date AS date,
	    COALESCE(vendors.name, posting.transaction_comment) AS counterparty,
	    COALESCE(business_expenses.invoice_number, posting.xid::VARCHAR) AS reference,
	    posting.account_id AS acct,
	    behaviours.label,
	    mappings.transaction_role,
	    behaviours.tax_box,
	    behaviours.net_box,
	    behaviours.vat_rate,
	    behaviours.recoverable_rate,
	    COALESCE(
		expense_lines.business_use_percent,
		posting.default_business_use_percent,
		1
	    ) AS business_use_percent,
	    CASE mappings.transaction_role
		WHEN 'sale' THEN -posting.amount
		ELSE posting.amount
	    END AS ledger_net_amount,
	    expense_lines.net_amount AS explicit_net,
	    expense_lines.vat_amount AS explicit_vat
	FROM uk_account_vat_mappings AS mappings
	JOIN uk_vat_behaviours AS behaviours
	  ON behaviours.id = mappings.behaviour_id
	JOIN report_postings AS posting
	  ON posting.book_id = mappings.book_id
	 AND posting.account_id = mappings.acct
	LEFT JOIN business_expenses
	  ON business_expenses.book_id = posting.book_id
	 AND business_expenses.xid = posting.xid
	LEFT JOIN vendors
	  ON vendors.book_id = business_expenses.book_id
	 AND vendors.id = business_expenses.vendor_id
	LEFT JOIN business_expense_lines AS expense_lines
	  ON expense_lines.xaction_bit_id = posting.posting_id
	WHERE mappings.book_id = b
	  AND (start_date IS NULL OR posting.transaction_date >= start_date)
	  AND (end_date IS NULL OR posting.transaction_date <= end_date)
    ),
    split_values AS (
	SELECT
	    posting_inputs.*,
	    CASE
		WHEN explicit_net IS NULL THEN ledger_net_amount
		ELSE sign(ledger_net_amount) * explicit_net
	    END::NUMERIC AS calculated_net,
	    CASE
		WHEN explicit_vat IS NOT NULL
		THEN sign(ledger_net_amount) * explicit_vat
		WHEN explicit_net IS NOT NULL
		THEN sign(ledger_net_amount) * explicit_net * vat_rate
		ELSE ledger_net_amount * vat_rate
	    END::NUMERIC AS calculated_vat
	FROM posting_inputs
    )
    SELECT
	split_values.id,
	split_values.date::DATE,
	split_values.counterparty::VARCHAR,
	split_values.reference::VARCHAR,
	split_values.acct,
	split_values.label,
	split_values.transaction_role,
	split_values.tax_box,
	split_values.net_box,
	round(split_values.calculated_net, 2),
	round(split_values.calculated_vat, 2),
	round(
	    CASE WHEN split_values.transaction_role = 'purchase'
		THEN split_values.calculated_vat
		     * split_values.recoverable_rate
		     * split_values.business_use_percent
		ELSE 0
	    END,
	    2
	)
    FROM split_values;
$$;

CREATE OR REPLACE FUNCTION uk_company_report_rows(
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
    IF NOT EXISTS (SELECT 1 FROM uk_company_profiles WHERE book_id = b) THEN
	RETURN;
    END IF;

    -- Unsupported configurations stop at the validation message returned by
    -- api.report_page.  Do not display standard-scheme or FRS 105 arithmetic
    -- beneath a blocker: a plausible-looking number is more dangerous than an
    -- intentionally empty preparation table.
    IF requested_report IN (
	'uk-statutory-profit-loss', 'uk-statutory-balance-sheet',
	'changes-in-equity', 'uk-statutory-notes', 'corporation-tax'
    ) AND EXISTS (
	SELECT 1
	FROM uk_company_profiles
	WHERE book_id = b
	  AND (
	    legal_form <> 'private_limited_shares'
	    OR accounting_framework <> 'frs105'
	  )
    ) THEN
	RETURN;
    END IF;

    IF requested_report IN ('vat-return', 'vat-detail')
       AND EXISTS (
	SELECT 1
	FROM uk_company_profiles
	WHERE book_id = b
	  AND vat_scheme <> 'standard_invoice'
       ) THEN
	RETURN;
    END IF;

    IF requested_report IN ('vat-return', 'vat-detail')
       AND NOT EXISTS (
	SELECT 1 FROM uk_company_control_accounts WHERE book_id = b
       ) THEN
	RETURN;
    END IF;

    IF requested_report = 'corporation-tax'
       AND end_date::DATE
	   > (start_date::DATE + INTERVAL '1 year' - INTERVAL '1 day')::DATE THEN
	RETURN;
    END IF;

    IF EXISTS (
	SELECT 1
	FROM report_postings AS posting
	JOIN books ON books.id = posting.book_id
	WHERE posting.book_id = b
	  AND posting.account_asset <> books.reporting_asset
	  AND posting.transaction_date <= CASE
	    WHEN requested_report IN (
		'uk-statutory-balance-sheet', 'uk-statutory-notes',
		'aged-debtors', 'aged-creditors'
	    ) THEN as_of_date
	    ELSE end_date
	  END
	  AND (
	    requested_report IN (
		'uk-statutory-balance-sheet', 'uk-statutory-notes',
		'aged-debtors', 'aged-creditors'
	    )
	    OR posting.transaction_date >= start_date
	  )
    ) THEN
	RETURN;
    END IF;

    IF requested_report IN (
	'uk-statutory-profit-loss', 'uk-statutory-balance-sheet'
    ) THEN
	RETURN QUERY
	WITH report_parameters AS (
	    SELECT
		CASE requested_report
		    WHEN 'uk-statutory-profit-loss' THEN 'profit_loss'
		    ELSE 'balance_sheet'
		END::VARCHAR AS statement,
		CASE requested_report
		    WHEN 'uk-statutory-profit-loss' THEN start_date
		    ELSE NULL
		END AS period_start,
		CASE requested_report
		    WHEN 'uk-statutory-profit-loss' THEN end_date
		    ELSE as_of_date
		END AS period_end
	),
	statement_rows AS (
	    SELECT values.*
	    FROM report_parameters
	    CROSS JOIN LATERAL uk_statutory_statement_values(
		b,
		report_parameters.statement,
		report_parameters.period_start,
		report_parameters.period_end
	    ) AS values
	),
	unmapped AS (
	    SELECT
		accts.id,
		accts.name,
		accts.type,
		njord.sum_if_complete(
		    CASE
			WHEN posting.amount = 0 THEN 0
			WHEN accts.type IN ('A', 'E') THEN posting.reporting_amount
			ELSE -posting.reporting_amount
		    END
		) FILTER (WHERE posting.xid IS NOT NULL) AS amount
	    FROM report_parameters
	    JOIN accts
	      ON accts.book_id = b
	     AND NOT accts.placeholder
	     AND (
		(report_parameters.statement = 'profit_loss' AND accts.type IN ('I', 'E'))
		OR (report_parameters.statement = 'balance_sheet' AND accts.type IN ('A', 'L', 'Q'))
	     )
	    LEFT JOIN report_postings AS posting
	      ON posting.book_id = accts.book_id
	     AND posting.account_id = accts.id
	     AND posting.transaction_date <= report_parameters.period_end
	     AND (
		report_parameters.statement <> 'profit_loss'
		OR report_parameters.period_start IS NULL
		OR posting.transaction_date >= report_parameters.period_start
	     )
	    WHERE NOT EXISTS (
		SELECT 1
		FROM uk_account_statutory_mappings AS mappings
		JOIN uk_statutory_lines AS line ON line.id = mappings.line_id
		WHERE mappings.book_id = accts.book_id
		  AND mappings.acct = accts.id
		  AND line.statement = report_parameters.statement
	    )
	    GROUP BY accts.id, accts.name, accts.type
	    HAVING COALESCE(sum(abs(posting.amount))
		FILTER (WHERE posting.xid IS NOT NULL), 0) <> 0
	)
	SELECT
	    statement_rows.display_order::BIGINT,
	    ('line:' || statement_rows.line_id)::VARCHAR,
	    njord.report_payload(
		CASE WHEN statement_rows.mappable THEN 'account' ELSE 'total' END,
		statement_rows.line_id,
		jsonb_build_array(
		    njord.report_text_cell('description', statement_rows.label),
		    njord.report_number_cell('amount', statement_rows.amount),
		    njord.report_text_cell(
			'basis',
			CASE WHEN statement_rows.mappable
			    THEN statement_rows.mapped_accounts || ' mapped account(s)'
			    ELSE 'Computed statutory subtotal'
			END
		    )
		)
	    )
	FROM statement_rows
	UNION ALL
	SELECT
	    900000 + row_number() OVER (ORDER BY unmapped.name, unmapped.id),
	    ('unmapped:' || unmapped.id)::VARCHAR,
	    njord.report_payload(
		'warning', unmapped.id,
		jsonb_build_array(
		    njord.report_text_cell('description', 'Unmapped: ' || unmapped.name),
		    njord.report_number_cell('amount', round(unmapped.amount, 2)),
		    njord.report_text_cell('basis', 'Mapping required — excluded from statutory totals')
		)
	    )
	FROM unmapped;
    ELSIF requested_report = 'changes-in-equity' THEN
	RETURN QUERY
	WITH valued AS (
	    SELECT
		posting.account_type AS type,
		mappings.line_id,
		posting.transaction_date AS date,
		posting.reporting_amount AS amount
	    FROM report_postings AS posting
	    LEFT JOIN uk_account_statutory_mappings AS mappings
	      ON mappings.book_id = posting.book_id
	     AND mappings.acct = posting.account_id
	    WHERE posting.book_id = b
	      AND posting.account_type IN ('Q', 'I', 'E')
	      AND posting.transaction_date <= end_date
	),
	amounts AS (
	    SELECT
		njord.sum_if_complete(-amount) FILTER (
		    WHERE date < start_date AND type IN ('Q', 'I', 'E')
		) AS opening,
		njord.sum_if_complete(-amount) FILTER (
		    WHERE date >= start_date AND type IN ('I', 'E')
		) AS profit_loss,
		njord.sum_if_complete(-amount) FILTER (
		    WHERE date >= start_date AND type = 'Q'
		      AND line_id IN (
			'called_up_share_capital', 'share_premium',
			'equity_contributions'
		      )
		) AS contributions,
		njord.sum_if_complete(-amount) FILTER (
		    WHERE date >= start_date AND type = 'Q'
		      AND (
			line_id = 'equity_distributions'
			OR line_id = 'profit_and_loss_account'
			   AND (amount > 0 OR amount IS NULL)
		      )
		) AS distributions,
		njord.sum_if_complete(-amount) FILTER (
		    WHERE date >= start_date AND type = 'Q'
		      AND (line_id IS NULL OR line_id NOT IN (
			'called_up_share_capital', 'share_premium',
			'equity_contributions', 'equity_distributions'
		      ))
		      AND (
			line_id IS NULL
			OR NOT (line_id = 'profit_and_loss_account' AND amount > 0)
		      )
		) AS unmapped_equity
	    FROM valued
	),
	rows AS (
	    SELECT * FROM amounts
	    CROSS JOIN LATERAL (VALUES
		(100, 'equity_opening'::VARCHAR, 'Equity at start of period'::VARCHAR, opening, 'total'::VARCHAR),
		(200, 'equity_profit_loss', 'Profit or loss for period', profit_loss, 'computed'),
		(300, 'equity_contributions', 'Capital introduced', contributions, 'account'),
		(400, 'equity_distributions', 'Distributions', distributions, 'account'),
		(450, 'equity_unmapped', 'Unmapped direct equity movements', unmapped_equity, 'warning'),
		(500, 'equity_closing', 'Equity at end of period',
		    opening + profit_loss + contributions + distributions + unmapped_equity,
		    'grand_total')
	    ) AS values(row_order, row_id, label, amount, row_kind)
	)
	SELECT
	    rows.row_order::BIGINT,
	    rows.row_id,
	    njord.report_payload(
		rows.row_kind, rows.row_id,
		jsonb_build_array(
		    njord.report_text_cell('movement', rows.label),
		    njord.report_number_cell('amount', round(rows.amount, 2))
		)
	    )
	FROM rows;
    ELSIF requested_report = 'corporation-tax' THEN
	RETURN QUERY
	WITH account_amounts AS (
	    SELECT
		posting.account_id AS id,
		posting.account_name AS name,
		posting.account_type AS type,
		treatments.id AS treatment_id,
		treatments.label AS treatment_label,
		treatments.effect,
		mappings.inclusion_percent,
		statutory_lines.id AS statutory_line_id,
		njord.sum_if_complete(
		    CASE posting.account_type
			WHEN 'I' THEN -posting.reporting_amount
			ELSE posting.reporting_amount
		    END
		) AS amount
	    FROM report_postings AS posting
	    LEFT JOIN uk_account_corporation_tax_mappings AS mappings
	      ON mappings.book_id = posting.book_id
	     AND mappings.acct = posting.account_id
	    LEFT JOIN uk_corporation_tax_treatments AS treatments
	      ON treatments.id = mappings.treatment_id
	    LEFT JOIN uk_account_statutory_mappings AS statutory_mappings
	      ON statutory_mappings.book_id = posting.book_id
	     AND statutory_mappings.acct = posting.account_id
	    LEFT JOIN uk_statutory_lines AS statutory_lines
	      ON statutory_lines.id = statutory_mappings.line_id
	     AND statutory_lines.statement = 'profit_loss'
	    WHERE posting.book_id = b
	      AND posting.account_type IN ('I', 'E', 'A')
	      AND posting.transaction_date >= start_date
	      AND posting.transaction_date <= end_date
	    GROUP BY posting.account_id, posting.account_name,
		posting.account_type, treatments.id,
		treatments.label, treatments.effect, mappings.inclusion_percent,
		statutory_lines.id
	),
	profit AS (
	    SELECT CASE
		WHEN EXISTS (
		    SELECT 1 FROM account_amounts
		    WHERE type IN ('I', 'E')
		      AND statutory_line_id IS NULL
		      AND amount <> 0
		) THEN NULL
		ELSE COALESCE(statement.amount, 0)
	    END::NUMERIC AS amount
	    FROM uk_statutory_statement_values(
		b, 'profit_loss', start_date, end_date
	    ) AS statement
	    WHERE statement.line_id = 'profit_loss_before_tax'
	),
	adjustments AS (
	    SELECT
		account_amounts.*,
		CASE
		    WHEN statutory_line_id = 'tax_on_profit' THEN 0
		    WHEN effect = 'excluded_from_profit_before_tax' THEN 0
		    ELSE CASE effect
		    WHEN 'disallowable_expense' THEN amount * inclusion_percent
		    WHEN 'non_taxable' THEN -amount * inclusion_percent
		    WHEN 'deductible_expense' THEN amount * (1 - inclusion_percent)
		    WHEN 'taxable_income' THEN -amount * (1 - inclusion_percent)
		    ELSE 0
		    END
		END::NUMERIC AS adjustment
	    FROM account_amounts
	    WHERE treatment_id IS NOT NULL
	),
	adjustment_total AS (
	    SELECT njord.sum_if_complete(adjustment) AS amount
	    FROM adjustments
	),
	rows AS (
	    SELECT 100 AS order_no, 'accounting-profit'::VARCHAR AS id,
		'Accounting profit (loss) before tax'::VARCHAR AS label,
		profit.amount, 'Ledger profit and loss'::VARCHAR AS basis,
		'total'::VARCHAR AS kind
	    FROM profit
	    UNION ALL
	    SELECT 200 + row_number() OVER (ORDER BY adjustments.name, adjustments.id),
		'adjustment:' || adjustments.id,
		adjustments.name,
		adjustments.adjustment,
		adjustments.treatment_label || ' · ' || round(adjustments.inclusion_percent * 100, 2) || '%',
		'account'
	    FROM adjustments
	    WHERE adjustments.effect NOT IN ('capital_allowance_pool', 'manual_adjustment')
	    UNION ALL
	    SELECT 600 + row_number() OVER (ORDER BY adjustments.name, adjustments.id),
		'capital-pool:' || adjustments.id,
		adjustments.name,
		adjustments.amount,
		'Capital allowance pool movement; no allowance is claimed automatically',
		'account'
	    FROM adjustments
	    WHERE adjustments.effect = 'capital_allowance_pool'
	    UNION ALL
	    SELECT 700 + row_number() OVER (ORDER BY adjustments.name, adjustments.id),
		'manual:' || adjustments.id,
		adjustments.name,
		NULL::NUMERIC,
		'Manual adjustment classification has no stored adjustment fact',
		'warning'
	    FROM adjustments
	    WHERE adjustments.effect = 'manual_adjustment'
	    UNION ALL
	    SELECT 800, 'taxable-profit-before-allowances',
		'Tax-adjusted profit before capital allowances and losses',
		profit.amount + adjustment_total.amount,
		'Preparation subtotal only', 'grand_total'
	    FROM profit CROSS JOIN adjustment_total
	    UNION ALL
	    SELECT 850, 'capital-allowances', 'Capital allowances claimed', NULL::NUMERIC,
		'No allowance-claim facts are stored; review capital pools separately', 'warning'
	    UNION ALL
	    SELECT 900, 'corporation-tax-liability', 'Corporation Tax liability', NULL::NUMERIC,
		'Rates, associated companies, marginal relief, losses, and claims are not configured', 'warning'
	    UNION ALL
	    SELECT 950 + row_number() OVER (ORDER BY account_amounts.name, account_amounts.id),
		'unmapped:' || account_amounts.id,
		'Unmapped: ' || account_amounts.name,
		account_amounts.amount,
		'Corporation Tax mapping required', 'warning'
	    FROM account_amounts
	    WHERE account_amounts.type IN ('I', 'E')
	      AND account_amounts.treatment_id IS NULL
	      AND account_amounts.amount <> 0
	    UNION ALL
	    SELECT 925 + row_number() OVER (ORDER BY account_amounts.name, account_amounts.id),
		'missing-statutory:' || account_amounts.id,
		'Missing statutory P&L mapping: ' || account_amounts.name,
		account_amounts.amount,
		'Accounting profit before tax is unavailable until this account is mapped',
		'warning'
	    FROM account_amounts
	    WHERE account_amounts.type IN ('I', 'E')
	      AND account_amounts.statutory_line_id IS NULL
	      AND account_amounts.amount <> 0
	)
	SELECT
	    rows.order_no::BIGINT,
	    rows.id::VARCHAR,
	    njord.report_payload(
		rows.kind, rows.id,
		jsonb_build_array(
		    njord.report_text_cell('item', rows.label),
		    njord.report_number_cell('amount', round(rows.amount, 2)),
		    njord.report_text_cell('basis', rows.basis)
		)
	    )
	FROM rows;
    ELSIF requested_report = 'vat-return' THEN
	RETURN QUERY
	WITH mapped AS (
	    SELECT * FROM uk_vat_posting_values(b, start_date, end_date)
	),
	box_base AS (
	    SELECT
		COALESCE(sum(CASE WHEN tax_box = 1 THEN vat_amount ELSE 0 END), 0) AS box_1,
		0::NUMERIC AS box_2,
		COALESCE(sum(CASE WHEN tax_box = 4 THEN recoverable_vat ELSE 0 END), 0) AS box_4,
		COALESCE(sum(CASE WHEN net_box = 6 THEN net_amount ELSE 0 END), 0) AS box_6,
		COALESCE(sum(CASE WHEN net_box = 7 THEN net_amount ELSE 0 END), 0) AS box_7,
		COALESCE(sum(CASE WHEN net_box = 8 THEN net_amount ELSE 0 END), 0) AS box_8,
		COALESCE(sum(CASE WHEN net_box = 9 THEN net_amount ELSE 0 END), 0) AS box_9
	    FROM mapped
	),
	control AS (
	    SELECT
		-COALESCE(sum(posting.amount) FILTER (
		    WHERE posting.transaction_date <= end_date
		), 0)::NUMERIC AS closing_liability,
		-COALESCE(sum(posting.amount) FILTER (
		    WHERE posting.transaction_date >= start_date
		      AND posting.transaction_date <= end_date
		      AND EXISTS (
			SELECT 1
			FROM xaction_bits AS mapped_bits
			JOIN uk_account_vat_mappings AS mappings
			  ON mappings.book_id = mapped_bits.book_id
			 AND mappings.acct = mapped_bits.acct
			WHERE mapped_bits.book_id = posting.book_id
			  AND mapped_bits.xid = posting.xid
		      )
		), 0)::NUMERIC AS mapped_transaction_movement
	    FROM uk_company_control_accounts AS controls
	    LEFT JOIN report_postings AS posting
	      ON posting.book_id = controls.book_id
	     AND posting.account_id = controls.vat_control_acct
	    WHERE controls.book_id = b
	),
	box_rows AS (
	    SELECT *
	    FROM box_base
	    CROSS JOIN control
	    CROSS JOIN LATERAL (VALUES
		(1, 'box-1'::VARCHAR, '1'::VARCHAR,
		    'VAT due on sales and other outputs'::VARCHAR, box_1, 'account'::VARCHAR),
		(2, 'box-2', '2', 'VAT due on acquisitions from other EC member states', box_2, 'account'),
		(3, 'box-3', '3', 'Total VAT due', box_1 + box_2, 'total'),
		(4, 'box-4', '4', 'VAT reclaimed on purchases and other inputs', box_4, 'account'),
		(5, 'box-5', '5', 'Net VAT to pay or reclaim (absolute value)',
		    abs(box_1 + box_2 - box_4), 'total'),
		(6, 'box-6', '6', 'Total value of sales and outputs excluding VAT', box_6, 'account'),
		(7, 'box-7', '7', 'Total value of purchases and inputs excluding VAT', box_7, 'account'),
		(8, 'box-8', '8', 'Dispatches of goods to EC member states', box_8, 'account'),
		(9, 'box-9', '9', 'Acquisitions of goods from EC member states', box_9, 'account'),
		(10, 'vat-control-mapped', 'Control',
		    'VAT-control liability movement on mapped transactions',
		    mapped_transaction_movement, 'account'),
		(11, 'vat-control-difference', 'Control check',
		    'Difference: VAT-control movement less boxes 1 + 2 - 4',
		    mapped_transaction_movement - (box_1 + box_2 - box_4), 'total'),
		(12, 'vat-control-closing', 'Control balance',
		    'Closing VAT-control liability (payments and adjustments included)',
		    closing_liability, 'total')
	    ) AS values(row_number, row_id, box_label, description, amount, row_kind)
	),
	unmapped AS (
	    SELECT count(*)::BIGINT AS posting_count
	    FROM report_postings AS posting
	    WHERE posting.book_id = b
	      AND (
		posting.account_type IN ('I', 'E')
		OR posting.account_kind = 'fixed_asset'
	      )
	      AND posting.transaction_date >= start_date
	      AND posting.transaction_date <= end_date
	      AND NOT EXISTS (
		SELECT 1 FROM uk_account_vat_mappings AS mappings
		WHERE mappings.book_id = posting.book_id
		  AND mappings.acct = posting.account_id
	      )
	)
	SELECT
	    box_rows.row_number::BIGINT,
	    box_rows.row_id::VARCHAR,
	    njord.report_payload(
		box_rows.row_kind, box_rows.row_id,
		jsonb_build_array(
		    njord.report_text_cell('box', box_rows.box_label),
		    njord.report_text_cell('description', box_rows.description),
		    njord.report_number_cell('amount', round(box_rows.amount, 2))
		)
	    )
	FROM box_rows
	UNION ALL
	SELECT
	    99,
	    'unmapped-vat-postings'::VARCHAR,
	    njord.report_payload(
		'warning', 'unmapped-vat-postings',
		jsonb_build_array(
		    njord.report_text_cell('box', 'Mapping'),
		    njord.report_text_cell(
			'description',
			unmapped.posting_count || ' relevant posting(s) are unmapped and excluded'
		    ),
		    njord.report_number_cell('amount', NULL)
		)
	    )
	FROM unmapped
	WHERE unmapped.posting_count > 0;
    ELSIF requested_report = 'vat-detail' THEN
	RETURN QUERY
	WITH detail AS (
	    SELECT * FROM uk_vat_posting_values(b, start_date, end_date)
	),
	unmapped AS (
	    SELECT
		posting.posting_id AS id,
		posting.transaction_date::DATE AS date,
		posting.transaction_comment AS comment,
		posting.account_id AS acct,
		abs(posting.amount)::NUMERIC AS gross_amount
	    FROM report_postings AS posting
	    WHERE posting.book_id = b
	      AND (
		posting.account_type IN ('I', 'E')
		OR posting.account_kind = 'fixed_asset'
	      )
	      AND posting.transaction_date >= start_date
	      AND posting.transaction_date <= end_date
	      AND NOT EXISTS (
		SELECT 1 FROM uk_account_vat_mappings AS mappings
		WHERE mappings.book_id = posting.book_id
		  AND mappings.acct = posting.account_id
	      )
	)
	SELECT
	    row_number() OVER (ORDER BY detail.posting_date, detail.xaction_bit_id),
	    ('vat:' || detail.xaction_bit_id)::VARCHAR,
	    njord.report_payload(
		'account', 'vat:' || detail.xaction_bit_id,
		jsonb_build_array(
		    njord.report_text_cell('date', detail.posting_date::VARCHAR),
		    njord.report_text_cell('counterparty', detail.counterparty),
		    njord.report_text_cell('reference', detail.reference),
		    njord.report_text_cell('account', detail.account),
		    njord.report_number_cell('net', detail.net_amount),
		    njord.report_number_cell('vat', detail.vat_amount),
		    njord.report_number_cell('recoverable', detail.recoverable_vat),
		    njord.report_text_cell('behaviour', detail.behaviour)
		)
	    )
	FROM detail
	UNION ALL
	SELECT
	    900000 + row_number() OVER (ORDER BY unmapped.date, unmapped.id),
	    ('unmapped:' || unmapped.id)::VARCHAR,
	    njord.report_payload(
		'warning', 'unmapped:' || unmapped.id,
		jsonb_build_array(
		    njord.report_text_cell('date', unmapped.date::VARCHAR),
		    njord.report_text_cell('counterparty', unmapped.comment),
		    njord.report_text_cell('reference', unmapped.id::VARCHAR),
		    njord.report_text_cell('account', unmapped.acct),
		    njord.report_number_cell('net', NULL),
		    njord.report_number_cell('vat', NULL),
		    njord.report_number_cell('recoverable', NULL),
		    njord.report_text_cell('behaviour', 'Unmapped — excluded from VAT return')
		)
	    )
	FROM unmapped;
    ELSIF requested_report = 'fixed-asset-schedule' THEN
	RETURN QUERY
	WITH schedule AS (
	    SELECT
		accts.id,
		accts.name,
		njord.sum_if_complete(posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date < start_date
		) AS opening_value,
		njord.sum_if_complete(posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date BETWEEN start_date AND end_date
		) AS movement,
		njord.sum_if_complete(posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date <= end_date
		) AS closing_value,
		estimate.value AS estimate
	    FROM accts
	    LEFT JOIN report_postings AS posting
	      ON posting.book_id = accts.book_id
	     AND posting.account_id = accts.id
	    LEFT JOIN LATERAL (
		SELECT account_valuations.value
		FROM account_valuations
		JOIN books ON books.id = account_valuations.book_id
		WHERE account_valuations.book_id = accts.book_id
		  AND account_valuations.acct = accts.id
		  AND account_valuations.dst = books.reporting_asset
		  AND account_valuations.date <= end_date
		ORDER BY account_valuations.date DESC
		LIMIT 1
	    ) AS estimate ON TRUE
	    WHERE accts.book_id = b
	      AND accts.account_kind = 'fixed_asset'
	      AND NOT accts.placeholder
	    GROUP BY accts.id, accts.name, estimate.value
	)
	SELECT
	    row_number() OVER (ORDER BY schedule.name, schedule.id),
	    schedule.id,
	    njord.report_payload(
		'account', schedule.id,
		jsonb_build_array(
		    njord.report_text_cell('asset', schedule.name),
		    njord.report_number_cell('opening', round(schedule.opening_value, 2)),
		    njord.report_number_cell('movement', round(schedule.movement, 2)),
		    njord.report_number_cell('closing', round(schedule.closing_value, 2)),
		    njord.report_number_cell('estimate', round(schedule.estimate, 2))
		)
	    )
	FROM schedule;
    ELSIF requested_report = 'director-loan-schedule' THEN
	RETURN QUERY
	WITH schedule AS (
	    SELECT
		accts.id,
		accts.name,
		njord.sum_if_complete(posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date < start_date
		) AS opening_value,
		njord.sum_if_complete(posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date BETWEEN start_date AND end_date
		      AND posting.amount > 0
		) AS debits,
		njord.sum_if_complete(-posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date BETWEEN start_date AND end_date
		      AND posting.amount < 0
		) AS credits,
		njord.sum_if_complete(posting.reporting_amount) FILTER (
		    WHERE posting.xid IS NOT NULL
		      AND posting.transaction_date <= end_date
		) AS closing_value
	    FROM accts
	    LEFT JOIN report_postings AS posting
	      ON posting.book_id = accts.book_id
	     AND posting.account_id = accts.id
	    WHERE accts.book_id = b
	      AND NOT accts.placeholder
	      AND accts.account_kind = 'director_loan'
	    GROUP BY accts.id, accts.name
	)
	SELECT
	    row_number() OVER (ORDER BY schedule.name, schedule.id),
	    schedule.id,
	    njord.report_payload(
		'account', schedule.id,
		jsonb_build_array(
		    njord.report_text_cell('account', schedule.name),
		    njord.report_number_cell('opening', round(schedule.opening_value, 2)),
		    njord.report_number_cell('debits', round(schedule.debits, 2)),
		    njord.report_number_cell('credits', round(schedule.credits, 2)),
		    njord.report_number_cell('closing', round(schedule.closing_value, 2))
		)
	    )
	FROM schedule;
    ELSIF requested_report IN ('aged-debtors', 'aged-creditors') THEN
	RETURN QUERY
	WITH outstanding AS (
	    SELECT
		invoices.id,
		parties.name AS party,
		invoices.invoice_number,
		invoices.issued_on,
		invoices.due_on,
		greatest(
		    0,
		    abs(invoice_posting.amt) - COALESCE(sum(allocations.amount)
			FILTER (WHERE payment.date <= as_of_date), 0)
		)::NUMERIC AS amount
	    FROM trade_invoices AS invoices
	    JOIN trade_parties AS parties
	      ON parties.book_id = invoices.book_id
	     AND parties.id = invoices.party_id
	    JOIN xaction_bits AS invoice_posting
	      ON invoice_posting.book_id = invoices.book_id
	     AND invoice_posting.xid = invoices.xid
	     AND invoice_posting.acct = invoices.control_acct
	    LEFT JOIN trade_invoice_allocations AS allocations
	      ON allocations.book_id = invoices.book_id
	     AND allocations.invoice_id = invoices.id
	     AND allocations.control_acct = invoices.control_acct
	    LEFT JOIN xactions AS payment
	      ON payment.book_id = allocations.book_id
	     AND payment.xid = allocations.payment_xid
	    WHERE invoices.book_id = b
	      AND invoices.issued_on <= as_of_date::DATE
	      AND invoices.direction = CASE requested_report
		WHEN 'aged-debtors' THEN 'receivable'
		ELSE 'payable'
	      END
	    GROUP BY invoices.id, parties.name, invoices.invoice_number,
		invoices.issued_on, invoices.due_on, invoice_posting.amt
	),
	open_items AS (
	    SELECT *, (as_of_date::DATE - due_on) AS days_overdue
	    FROM outstanding
	    WHERE amount > 0
	)
	SELECT
	    row_number() OVER (ORDER BY open_items.due_on, open_items.party, open_items.id),
	    open_items.id,
	    njord.report_payload(
		'account', open_items.id,
		jsonb_build_array(
		    njord.report_text_cell('party', open_items.party),
		    njord.report_text_cell('invoice', open_items.invoice_number),
		    njord.report_text_cell('issued', open_items.issued_on::VARCHAR),
		    njord.report_text_cell('due', open_items.due_on::VARCHAR),
		    njord.report_number_cell('current',
			CASE WHEN open_items.days_overdue <= 0 THEN round(open_items.amount, 2) ELSE 0 END),
		    njord.report_number_cell('days_1_30',
			CASE WHEN open_items.days_overdue BETWEEN 1 AND 30 THEN round(open_items.amount, 2) ELSE 0 END),
		    njord.report_number_cell('days_31_60',
			CASE WHEN open_items.days_overdue BETWEEN 31 AND 60 THEN round(open_items.amount, 2) ELSE 0 END),
		    njord.report_number_cell('days_61_90',
			CASE WHEN open_items.days_overdue BETWEEN 61 AND 90 THEN round(open_items.amount, 2) ELSE 0 END),
		    njord.report_number_cell('days_91_plus',
			CASE WHEN open_items.days_overdue > 90 THEN round(open_items.amount, 2) ELSE 0 END),
		    njord.report_number_cell('total', round(open_items.amount, 2))
		)
	    )
	FROM open_items;
    ELSIF requested_report = 'uk-statutory-notes' THEN
	RETURN QUERY
	WITH profile AS (
	    SELECT
		profiles.*,
		legal_forms.label AS legal_form_label,
		frameworks.label AS framework_label,
		vat_schemes.label AS vat_scheme_label,
		books.reporting_asset
	    FROM uk_company_profiles AS profiles
	    JOIN books ON books.id = profiles.book_id
	    JOIN uk_company_legal_forms AS legal_forms ON legal_forms.id = profiles.legal_form
	    JOIN uk_accounting_frameworks AS frameworks ON frameworks.id = profiles.accounting_framework
	    JOIN uk_vat_schemes AS vat_schemes ON vat_schemes.id = profiles.vat_scheme
	    WHERE profiles.book_id = b
	),
	period AS (
	    SELECT periods.*
	    FROM uk_accounting_periods AS periods
	    WHERE periods.book_id = b
	      AND as_of_date::DATE BETWEEN periods.period_start AND periods.period_end
	    LIMIT 1
	),
	checks AS (
	    SELECT
		count(*) FILTER (
		    WHERE NOT accts.placeholder
		      AND accts.type IN ('A', 'L', 'Q', 'I', 'E')
		      AND NOT EXISTS (
			SELECT 1 FROM uk_account_statutory_mappings AS mappings
			WHERE mappings.book_id = accts.book_id AND mappings.acct = accts.id
		      )
		) AS unmapped_statutory,
		count(*) FILTER (
		    WHERE NOT accts.placeholder
		      AND accts.type IN ('I', 'E')
		      AND NOT EXISTS (
			SELECT 1 FROM uk_account_corporation_tax_mappings AS mappings
			WHERE mappings.book_id = accts.book_id AND mappings.acct = accts.id
		      )
		) AS unmapped_ct,
		count(*) FILTER (WHERE accts.account_kind = 'fixed_asset') AS fixed_assets
	    FROM accts
	    WHERE accts.book_id = b
	),
	rows AS (
	    SELECT values.*
	    FROM profile
	    CROSS JOIN checks
	    LEFT JOIN period ON TRUE
	    CROSS JOIN LATERAL (VALUES
		(10, 'scope'::VARCHAR, 'Preparation-pack scope'::VARCHAR,
		    'Supporting schedules only; not filing-ready prose, iXBRL, CT600, or VAT submission'::VARCHAR,
		    'Review required'::VARCHAR),
		(20, 'legal-name', 'Legal name', profile.legal_name, 'Profile fact'),
		(30, 'company-number', 'Company number', profile.company_number,
		    CASE WHEN profile.company_number IS NULL THEN 'Missing' ELSE 'Profile fact' END),
		(40, 'legal-form', 'Legal form', profile.legal_form_label, 'Profile fact'),
		(50, 'framework', 'Accounting framework', profile.framework_label, 'Profile fact'),
		(60, 'reporting-currency', 'Reporting currency', profile.reporting_asset, 'Book fact'),
		(70, 'registered-office', 'Registered office', profile.registered_office,
		    CASE WHEN profile.registered_office IS NULL THEN 'Missing' ELSE 'Profile fact' END),
		(80, 'incorporated-on', 'Incorporated on', profile.incorporated_on::VARCHAR,
		    CASE WHEN profile.incorporated_on IS NULL THEN 'Missing' ELSE 'Profile fact' END),
		(90, 'vat-scheme', 'VAT scheme', profile.vat_scheme_label, 'Profile fact'),
		(100, 'vat-registration', 'VAT registration number', profile.vat_registration_number,
		    CASE
			WHEN profile.vat_scheme = 'not_registered' THEN 'Not applicable'
			WHEN profile.vat_registration_number IS NULL THEN 'Missing'
			ELSE 'Profile fact'
		    END),
		(110, 'period', 'Accounting period',
		    CASE WHEN period.id IS NULL THEN NULL
			ELSE period.period_start || ' to ' || period.period_end
		    END,
		    CASE WHEN period.id IS NULL THEN 'No matching configured period' ELSE period.status END),
		(120, 'statutory-mappings', 'Unmapped statutory accounts', checks.unmapped_statutory::VARCHAR,
		    CASE WHEN checks.unmapped_statutory = 0 THEN 'Complete' ELSE 'Mapping required' END),
		(130, 'ct-mappings', 'Unmapped Corporation Tax accounts', checks.unmapped_ct::VARCHAR,
		    CASE WHEN checks.unmapped_ct = 0 THEN 'Complete' ELSE 'Mapping required' END),
		(140, 'fixed-assets', 'Fixed assets in schedule', checks.fixed_assets::VARCHAR,
		    'Schedule summary')
	    ) AS values(order_no, id, disclosure, value, status)
	)
	SELECT
	    rows.order_no::BIGINT,
	    rows.id,
	    njord.report_payload(
		CASE WHEN rows.status IN ('Missing', 'Mapping required', 'No matching configured period', 'Review required')
		    THEN 'warning' ELSE 'account' END,
		rows.id,
		jsonb_build_array(
		    njord.report_text_cell('disclosure', rows.disclosure),
		    njord.report_text_cell('value', rows.value),
		    njord.report_text_cell('status', rows.status)
		)
	    )
	FROM rows;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION uk_ixbrl_facts(
    b VARCHAR,
    period_start DATE,
    period_end DATE
)
RETURNS TABLE (
    concept_id VARCHAR,
    label VARCHAR,
    context_start DATE,
    context_end DATE,
    instant DATE,
    unit VARCHAR,
    numeric_value NUMERIC,
    text_value VARCHAR,
    comparative BOOLEAN
)
LANGUAGE SQL
STABLE
AS $$
    SELECT
	('njord-uk:' || statement.line_id)::VARCHAR,
	statement.label,
	CASE WHEN lines.statement = 'profit_loss' THEN period_start ELSE NULL END,
	CASE WHEN lines.statement = 'profit_loss' THEN period_end ELSE NULL END,
	CASE WHEN lines.statement = 'balance_sheet' THEN period_end ELSE NULL END,
	books.reporting_asset,
	statement.amount,
	NULL::VARCHAR,
	FALSE
    FROM books
    CROSS JOIN (VALUES
	('profit_loss'::VARCHAR),
	('balance_sheet'::VARCHAR)
    ) AS requested(statement_name)
    CROSS JOIN LATERAL uk_statutory_statement_values(
	b,
	requested.statement_name,
	CASE WHEN requested.statement_name = 'profit_loss' THEN period_start::TIMESTAMP ELSE NULL END,
	period_end::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
    ) AS statement
    JOIN uk_statutory_lines AS lines ON lines.id = statement.line_id
    WHERE books.id = b
      AND EXISTS (SELECT 1 FROM uk_company_profiles WHERE book_id = b)
UNION ALL
    SELECT
	profile_fact.concept_id,
	profile_fact.label,
	NULL::DATE,
	NULL::DATE,
	period_end,
	NULL::VARCHAR,
	NULL::NUMERIC,
	profile_fact.value,
	FALSE
    FROM uk_company_profiles AS profile
    CROSS JOIN LATERAL (VALUES
	('njord-uk:EntityCurrentLegalName'::VARCHAR, 'Entity current legal name'::VARCHAR, profile.legal_name::VARCHAR),
	('njord-uk:UKCompaniesHouseRegisteredNumber', 'Companies House registered number', profile.company_number),
	('njord-uk:AccountingFramework', 'Accounting framework', profile.accounting_framework)
    ) AS profile_fact(concept_id, label, value)
    WHERE profile.book_id = b;
$$;

CREATE OR REPLACE FUNCTION njord.uk_report_validation_messages(
    p_report VARCHAR,
    p_book_id VARCHAR,
    p_from DATE,
    p_to DATE
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    profile uk_company_profiles%ROWTYPE;
    messages TEXT[] := ARRAY[]::TEXT[];
    unmapped_count BIGINT;
    statutory_unmapped_count BIGINT;
    foreign_account_count BIGINT;
    statement_id VARCHAR;
BEGIN
    IF NOT EXISTS (
	SELECT 1 FROM report_catalog
	WHERE report_id = p_report AND profile_kind = 'uk_company'
    ) THEN
	RETURN '[]'::JSONB;
    END IF;

    SELECT * INTO profile
    FROM uk_company_profiles
    WHERE book_id = p_book_id;

    IF NOT FOUND THEN
	RETURN jsonb_build_array(
	    'This report requires a configured UK company profile.'
	);
    END IF;

    IF p_report IN (
	'uk-statutory-profit-loss', 'uk-statutory-balance-sheet',
	'changes-in-equity', 'uk-statutory-notes', 'corporation-tax',
	'vat-return', 'vat-detail'
    ) AND (
	profile.legal_form <> 'private_limited_shares'
	OR profile.accounting_framework <> 'frs105'
    ) THEN
	messages := array_append(
	    messages,
	    'Preparation calculations currently support standalone private companies limited by shares using FRS 105 only.'
	);
    END IF;

    SELECT count(DISTINCT posting.account_id)
    INTO foreign_account_count
    FROM report_postings AS posting
    JOIN books ON books.id = posting.book_id
    WHERE posting.book_id = p_book_id
	AND posting.account_asset <> books.reporting_asset
	AND (p_from IS NULL OR posting.transaction_date >= p_from::TIMESTAMP)
	AND (p_to IS NULL OR posting.transaction_date
	    <= p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond');

    IF foreign_account_count > 0 THEN
	messages := array_append(
	    messages,
	    'UK preparation calculations currently require every active account in the selected dates to be GBP-denominated.'
	);
    END IF;

    IF p_report IN ('vat-return', 'vat-detail')
       AND profile.vat_scheme <> 'standard_invoice' THEN
	messages := array_append(
	    messages,
	    'VAT calculations currently support the standard invoice scheme only; cash and flat-rate treatments require different timing and formulae.'
	);
    END IF;

    IF p_report IN ('vat-return', 'vat-detail') THEN
	IF NOT EXISTS (
	    SELECT 1 FROM uk_company_control_accounts WHERE book_id = p_book_id
	) THEN
	    messages := array_append(
		messages,
		'Configure an explicit VAT control account before preparing VAT working papers.'
	    );
	END IF;
	messages := array_append(
	    messages,
	    'VAT obligation periods and tax-point adjustments are not stored; verify the selected transaction dates and VAT-control reconciliation before using this working paper.'
	);
    END IF;

    IF p_report IN (
	'uk-statutory-profit-loss', 'changes-in-equity', 'corporation-tax'
    ) AND NOT EXISTS (
	SELECT 1
	FROM uk_accounting_periods
	WHERE book_id = p_book_id
	  AND period_start = p_from
	  AND period_end = p_to
    ) THEN
	messages := array_append(
	    messages,
	    'The selected dates do not exactly match a configured UK accounting period.'
	);
    END IF;

    IF p_report IN ('uk-statutory-balance-sheet', 'uk-statutory-notes')
       AND NOT EXISTS (
	SELECT 1
	FROM uk_accounting_periods
	WHERE book_id = p_book_id
	  AND period_end = p_to
    ) THEN
	messages := array_append(
	    messages,
	    'The selected reporting date is not the end of a configured UK accounting period.'
	);
    END IF;

    IF p_report IN ('uk-statutory-profit-loss', 'uk-statutory-balance-sheet') THEN
	statement_id := CASE p_report
	    WHEN 'uk-statutory-profit-loss' THEN 'profit_loss'
	    ELSE 'balance_sheet'
	END;

	SELECT count(DISTINCT posting.account_id) INTO unmapped_count
	FROM report_postings AS posting
	WHERE posting.book_id = p_book_id
	  AND NOT posting.placeholder
	  AND (
	    (statement_id = 'profit_loss' AND posting.account_type IN ('I', 'E'))
	    OR (
		statement_id = 'balance_sheet'
		AND posting.account_type IN ('A', 'L', 'Q')
	    )
	  )
	  AND posting.transaction_date
	      <= p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
	  AND (
	      statement_id <> 'profit_loss'
	      OR posting.transaction_date >= p_from::TIMESTAMP
	  )
	  AND posting.amount <> 0
	  AND NOT EXISTS (
	    SELECT 1
	    FROM uk_account_statutory_mappings AS mappings
	    JOIN uk_statutory_lines AS lines ON lines.id = mappings.line_id
	    WHERE mappings.book_id = posting.book_id
	      AND mappings.acct = posting.account_id
	      AND lines.statement = statement_id
	  );

	IF unmapped_count > 0 THEN
	    messages := array_append(
		messages,
		unmapped_count || ' active account(s) lack a ' ||
		statement_id || ' statutory mapping and are excluded from statutory totals.'
	    );
	END IF;
    END IF;

    IF p_report = 'corporation-tax' THEN
	IF p_from IS NOT NULL
	   AND p_to IS NOT NULL
	   AND p_to > (p_from + INTERVAL '1 year' - INTERVAL '1 day')::DATE THEN
	    messages := array_append(
		messages,
		'Corporation Tax accounting periods cannot exceed twelve months; split this accounts period before preparing the computation.'
	    );
	END IF;

	SELECT
	    count(DISTINCT posting.account_id) FILTER (WHERE NOT EXISTS (
		SELECT 1
		FROM uk_account_corporation_tax_mappings AS mappings
		WHERE mappings.book_id = posting.book_id
		  AND mappings.acct = posting.account_id
	    )),
	    count(DISTINCT posting.account_id) FILTER (WHERE NOT EXISTS (
		SELECT 1
		FROM uk_account_statutory_mappings AS mappings
		JOIN uk_statutory_lines AS lines ON lines.id = mappings.line_id
		WHERE mappings.book_id = posting.book_id
		  AND mappings.acct = posting.account_id
		  AND lines.statement = 'profit_loss'
	    ))
	INTO unmapped_count, statutory_unmapped_count
	FROM report_postings AS posting
	WHERE posting.book_id = p_book_id
	  AND posting.account_type IN ('I', 'E')
	  AND posting.transaction_date >= p_from::TIMESTAMP
	  AND posting.transaction_date
	      <= p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
	  AND posting.amount <> 0;

	IF unmapped_count > 0 THEN
	    messages := array_append(messages,
		unmapped_count || ' active income/expense account(s) lack a Corporation Tax mapping.');
	END IF;

	IF statutory_unmapped_count > 0 THEN
	    messages := array_append(
		messages,
		statutory_unmapped_count || ' active income/expense account(s) lack the statutory P&L mapping required for accounting profit before tax.'
	    );
	END IF;
    END IF;

    IF p_report IN ('vat-return', 'vat-detail') THEN
	SELECT count(DISTINCT posting.account_id) INTO unmapped_count
	FROM report_postings AS posting
	WHERE posting.book_id = p_book_id
	  AND (
	      posting.account_type IN ('I', 'E')
	      OR posting.account_kind = 'fixed_asset'
	  )
	  AND posting.transaction_date >= p_from::TIMESTAMP
	  AND posting.transaction_date
	      <= p_to::TIMESTAMP + INTERVAL '1 day' - INTERVAL '1 microsecond'
	  AND posting.amount <> 0
	  AND NOT EXISTS (
	    SELECT 1 FROM uk_account_vat_mappings AS mappings
	    WHERE mappings.book_id = posting.book_id
	      AND mappings.acct = posting.account_id
	  );
	IF unmapped_count > 0 THEN
	    messages := array_append(messages,
		unmapped_count || ' relevant active account(s) lack a VAT behaviour mapping.');
	END IF;
    END IF;

    RETURN to_jsonb(messages);
END;
$$;

--

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

-- One pack-local projection feeds status, form fields, and setup checks. This
-- keeps UK rules out of the generic Book-page compositor.
CREATE OR REPLACE VIEW njord.uk_book_configuration AS
SELECT
    books.id AS book_id,
    books.name AS book_name,
    books.reporting_asset = 'GBP'
	AND books.entity_type = 'company' AS available,
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
    EXISTS (
	SELECT 1 FROM public.uk_accounting_periods AS period
	WHERE period.book_id = books.id
    ) AS has_period,
    EXISTS (
	SELECT 1 FROM public.uk_company_control_accounts AS control
	WHERE control.book_id = books.id
    ) AS has_vat_control,
    njord.standard_account_hierarchy_complete(books.id)
	AS has_standard_account_hierarchy,
    njord.uk_company_configuration_complete(books.id)
	AS configuration_complete
FROM public.books
LEFT JOIN public.uk_company_profiles AS profiles
  ON profiles.book_id = books.id;

CREATE OR REPLACE FUNCTION api.uk_book_status(p_book_id VARCHAR)
RETURNS JSONB
LANGUAGE SQL
STABLE
AS $$
    SELECT jsonb_build_object(
	'configuration_status', CASE
	    WHEN NOT configuration.profile_enabled THEN 'ordinary'
	    WHEN configuration.configuration_complete THEN 'complete'
	    ELSE 'incomplete'
	END,
	'validation_messages', to_jsonb(array_remove(ARRAY[
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
    )
    FROM njord.uk_book_configuration AS configuration
    WHERE configuration.book_id = p_book_id;
$$;

CREATE OR REPLACE FUNCTION api.uk_book_components(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    WITH configuration AS (
	SELECT *
	FROM njord.uk_book_configuration
	WHERE book_id = p_book_id AND available
    )
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
	    'vat_registration_number', configuration.vat_registration_number,
	    'vat_scheme', COALESCE(
		configuration.vat_scheme, 'not_registered'
	    ),
	    'registered_office', configuration.registered_office,
	    'incorporated_on', configuration.incorporated_on,
	    'notes', configuration.notes
	)
    FROM configuration
UNION ALL
    SELECT
	'configuration_check'::VARCHAR,
	check_row.row_order,
	check_row.id,
	njord.configuration_check_payload(
	    check_row.id, check_row.label,
	    check_row.complete, check_row.message
	)
    FROM configuration
    CROSS JOIN LATERAL (VALUES
	(9300::BIGINT, 'account_hierarchy'::VARCHAR, 'Account hierarchy'::TEXT,
	 configuration.has_standard_account_hierarchy,
	 CASE
	     WHEN configuration.has_standard_account_hierarchy THEN NULL
	     WHEN configuration.profile_enabled THEN
		 'Save company settings to create the standard account hierarchy.'
	     ELSE
		 'The standard account hierarchy will be created when company settings are saved.'
	 END),
	(9301, 'profile', 'Company profile', configuration.profile_enabled,
	 CASE WHEN configuration.profile_enabled THEN NULL
	     ELSE 'Enable UK company reporting to add a company profile.' END),
	(9302, 'period', 'Accounting period',
	 configuration.profile_enabled AND configuration.has_period,
	 CASE
	     WHEN NOT configuration.profile_enabled THEN
		 'Enable UK company reporting first.'
	     WHEN NOT configuration.has_period THEN
		 'Add at least one accounting period.'
	 END),
	(9303, 'vat_control', 'VAT control account',
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
	 END)
    ) AS check_row(row_order, id, label, complete, message)
UNION ALL
    SELECT
	options.component,
	options.base_order + row_number() OVER (
	    PARTITION BY options.component ORDER BY options.label, options.id
	),
	options.id,
	njord.labelled_option_payload(options.id, options.label)
    FROM configuration
    CROSS JOIN LATERAL (
	SELECT 'legal_form_option'::VARCHAR AS component,
	       9400::BIGINT AS base_order, id, label
	FROM public.uk_company_legal_forms
	UNION ALL
	SELECT 'accounting_framework_option', 9500, id, label
	FROM public.uk_accounting_frameworks
	UNION ALL
	SELECT 'vat_scheme_option', 9600, id, label
	FROM public.uk_vat_schemes
	UNION ALL
	SELECT 'period_status_option', 9700, id, label
	FROM public.uk_period_statuses
    ) AS options
UNION ALL
    SELECT
	'accounting_period'::VARCHAR,
	10000 + row_number() OVER (
	    ORDER BY periods.period_start DESC, periods.id
	),
	periods.id,
	jsonb_build_object(
	    'id', periods.id,
	    'period_start', periods.period_start,
	    'period_end', periods.period_end,
	    'status', periods.status,
	    'accounts_due_on', periods.accounts_due_on,
	    'corporation_tax_due_on', periods.corporation_tax_due_on,
	    'accounts_filed_on', periods.accounts_filed_on,
	    'ct600_filed_on', periods.ct600_filed_on,
	    'notes', periods.notes
	)
    FROM public.uk_accounting_periods AS periods
    WHERE periods.book_id = p_book_id
UNION ALL
    SELECT
	'vat_control_account_option'::VARCHAR,
	11000 + row_number() OVER (ORDER BY accounts.sort_path),
	accounts.id,
	jsonb_build_object(
	    'id', accounts.id,
	    'name', accounts.name,
	    'path', accounts.display_path,
	    'selected', EXISTS (
		SELECT 1
		FROM public.uk_company_control_accounts AS control
		WHERE control.book_id = p_book_id
		  AND control.vat_control_acct = accounts.id
	    )
	)
    FROM public.report_account_tree AS accounts
    JOIN public.books ON books.id = accounts.book_id
    WHERE accounts.book_id = p_book_id
      AND accounts.type = 'L'
      AND NOT accounts.placeholder
      AND accounts.atype = books.reporting_asset;
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

COMMENT ON FUNCTION api.configure_uk_company(
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, DATE,
    VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, VARCHAR,
    DATE, DATE, DATE, DATE, VARCHAR
) IS
    'Atomically ensure the standard hierarchy and configure a UK company profile, period, and required VAT control account';
