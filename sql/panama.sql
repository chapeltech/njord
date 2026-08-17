-- Panama business and residential-property production pack.
--
-- This file deliberately contains definitions and reference classifications,
-- never a demo company.  Every result is a preparation working paper: the
-- pack does not submit returns or claim to create filing-ready forms.

-- Generic Panama business ---------------------------------------------------

CREATE TABLE panama_legal_forms (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE panama_period_statuses (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE panama_municipalities (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    annual_return_rule VARCHAR NOT NULL DEFAULT 'manual_review'
);

-- Periods pin an effective-dated policy so changing a current rate cannot
-- silently alter a previously prepared working paper.
CREATE TABLE panama_tax_policies (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    effective_from DATE NOT NULL,
    effective_to DATE,
    corporate_income_tax_rate NUMERIC(8,6) NOT NULL,
    form_43_revenue_threshold NUMERIC(100,5) NOT NULL,
    form_43_asset_threshold NUMERIC(100,5) NOT NULL,
    standard_itbms_rate NUMERIC(8,6) NOT NULL,
    lodging_itbms_rate NUMERIC(8,6) NOT NULL,
    property_early_payment_discount_rate NUMERIC(8,6) NOT NULL,
    CHECK (effective_to IS NULL OR effective_from <= effective_to),
    CHECK (isfinite(effective_from)),
    CHECK (effective_to IS NULL OR isfinite(effective_to)),
    CHECK (corporate_income_tax_rate BETWEEN 0 AND 1),
    CONSTRAINT panama_form_43_revenue_threshold CHECK (
        form_43_revenue_threshold >= 0
        AND njord.is_finite(form_43_revenue_threshold)
    ),
    CONSTRAINT panama_form_43_asset_threshold CHECK (
        form_43_asset_threshold >= 0
        AND njord.is_finite(form_43_asset_threshold)
    ),
    CHECK (standard_itbms_rate BETWEEN 0 AND 1),
    CHECK (lodging_itbms_rate BETWEEN 0 AND 1),
    CHECK (property_early_payment_discount_rate BETWEEN 0 AND 1)
);

CREATE TABLE panama_income_tax_treatments (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    required_type VARCHAR REFERENCES acct_types(id),
    effect VARCHAR NOT NULL,
    default_inclusion_percent NUMERIC(8,6) NOT NULL DEFAULT 1,
    CHECK (effect IN (
        'taxable_income', 'deductible_expense',
        'non_deductible_expense', 'foreign_source_exempt',
        'capital_or_depreciation', 'manual_adjustment', 'excluded'
    )),
    CHECK (default_inclusion_percent BETWEEN 0 AND 1)
);

CREATE TABLE panama_itbms_treatments (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    transaction_role VARCHAR NOT NULL,
    rate_kind VARCHAR NOT NULL,
    recoverable_percent NUMERIC(8,6) NOT NULL DEFAULT 0,
    CHECK (transaction_role IN ('sale', 'purchase')),
    CHECK (rate_kind IN (
        'standard', 'lodging', 'zero_rated', 'exempt', 'out_of_scope'
    )),
    CHECK (recoverable_percent BETWEEN 0 AND 1)
);

CREATE TABLE panama_third_party_types (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE panama_payment_categories (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    form_20_code VARCHAR
);

CREATE TABLE panama_dividend_sources (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

INSERT INTO panama_legal_forms (id, label) VALUES
    ('corporation', 'Corporation (Sociedad Anonima)'),
    ('limited_liability_company', 'Limited liability company (SRL)'),
    ('foreign_branch', 'Registered foreign-company branch'),
    ('sole_proprietor', 'Sole proprietor'),
    ('other', 'Other / manual review');

INSERT INTO panama_period_statuses (id, label) VALUES
    ('open', 'Open'),
    ('prepared', 'Prepared'),
    ('filed', 'Filed'),
    ('closed', 'Closed');

INSERT INTO panama_municipalities (id, label, annual_return_rule) VALUES
    ('panama_district', 'District of Panama', 'first_90_days'),
    ('other', 'Other municipality / manual review', 'manual_review');

INSERT INTO panama_tax_policies (
    id, label, effective_from, effective_to,
    corporate_income_tax_rate,
    form_43_revenue_threshold, form_43_asset_threshold,
    standard_itbms_rate, lodging_itbms_rate,
    property_early_payment_discount_rate
) VALUES (
    'current_2026',
    'Current Panama working-paper assumptions (review annually)',
    DATE '2026-01-01', NULL, 0.25, 1000000, 3000000, 0.07, 0.10, 0.10
);

INSERT INTO panama_income_tax_treatments (
    id, label, required_type, effect, default_inclusion_percent
) VALUES
    ('taxable_income', 'Panama-source taxable income', 'I', 'taxable_income', 1),
    ('foreign_source_exempt', 'Foreign-source exempt income', 'I', 'foreign_source_exempt', 1),
    ('deductible_expense', 'Deductible business expense', 'E', 'deductible_expense', 1),
    ('non_deductible_expense', 'Non-deductible expense', 'E', 'non_deductible_expense', 1),
    ('capital_or_depreciation', 'Capital/depreciation schedule item', NULL, 'capital_or_depreciation', 1),
    ('manual_adjustment', 'Manual tax reconciliation adjustment', NULL, 'manual_adjustment', 1),
    ('excluded', 'Excluded from income-tax working paper', NULL, 'excluded', 1);

INSERT INTO panama_itbms_treatments (
    id, label, transaction_role, rate_kind, recoverable_percent
) VALUES
    ('sale_standard', 'Standard-rate sale', 'sale', 'standard', 0),
    ('sale_lodging', 'Lodging / short-stay accommodation', 'sale', 'lodging', 0),
    ('sale_zero_rated', 'Zero-rated sale', 'sale', 'zero_rated', 0),
    ('sale_exempt', 'Exempt sale', 'sale', 'exempt', 0),
    ('sale_out_of_scope', 'Out-of-scope sale', 'sale', 'out_of_scope', 0),
    ('purchase_recoverable', 'Recoverable standard-rate purchase', 'purchase', 'standard', 1),
    ('purchase_nonrecoverable', 'Non-recoverable standard-rate purchase', 'purchase', 'standard', 0),
    ('purchase_exempt', 'Exempt purchase', 'purchase', 'exempt', 0),
    ('purchase_out_of_scope', 'Out-of-scope purchase', 'purchase', 'out_of_scope', 0);

INSERT INTO panama_third_party_types (id, label) VALUES
    ('individual', 'Individual'),
    ('legal_entity', 'Legal entity'),
    ('government', 'Government body'),
    ('foreign_person', 'Foreign person'),
    ('other', 'Other / manual review');

INSERT INTO panama_payment_categories (id, label, form_20_code) VALUES
    ('services', 'Services', NULL),
    ('professional_fees', 'Professional fees', NULL),
    ('rent', 'Rent', NULL),
    ('commissions', 'Commissions', NULL),
    ('contractor', 'Contractor or repair work', NULL),
    ('other', 'Other / manual classification', NULL);

INSERT INTO panama_dividend_sources (id, label) VALUES
    ('panama_source', 'Panama-source profits'),
    ('foreign_source', 'Foreign-source profits'),
    ('exempt', 'Exempt profits'),
    ('mixed_or_manual', 'Mixed source / manual review');

CREATE TABLE panama_business_profiles (
    book_id VARCHAR PRIMARY KEY REFERENCES books(id),
    legal_name VARCHAR NOT NULL,
    ruc VARCHAR NOT NULL,
    verification_digit VARCHAR,
    legal_form VARCHAR NOT NULL REFERENCES panama_legal_forms(id),
    municipality VARCHAR NOT NULL REFERENCES panama_municipalities(id),
    default_tax_policy_id VARCHAR NOT NULL REFERENCES panama_tax_policies(id),
    incorporated_on DATE,
    resident_agent VARCHAR,
    registered_address VARCHAR,
    operations_notice_number VARCHAR,
    itbms_registered BOOLEAN NOT NULL DEFAULT FALSE,
    conducts_lodging_activity BOOLEAN NOT NULL DEFAULT FALSE,
    form_43_override BOOLEAN,
    notes VARCHAR,
    CHECK (btrim(legal_name) <> ''),
    CHECK (btrim(ruc) <> ''),
    CHECK (verification_digit IS NULL OR btrim(verification_digit) <> ''),
    CHECK (resident_agent IS NULL OR btrim(resident_agent) <> ''),
    CHECK (registered_address IS NULL OR btrim(registered_address) <> ''),
    CHECK (
        operations_notice_number IS NULL
        OR btrim(operations_notice_number) <> ''
    ),
    CHECK (incorporated_on IS NULL OR isfinite(incorporated_on))
);

CREATE TABLE panama_fiscal_periods (
    book_id VARCHAR NOT NULL REFERENCES panama_business_profiles(book_id),
    id VARCHAR NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    status VARCHAR NOT NULL REFERENCES panama_period_statuses(id),
    tax_policy_id VARCHAR NOT NULL REFERENCES panama_tax_policies(id),
    income_tax_return_due_on DATE,
    income_tax_return_filed_on DATE,
    municipal_return_due_on DATE,
    municipal_return_filed_on DATE,
    form_43_filed_through DATE,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    UNIQUE (book_id, period_start, period_end),
    CHECK (btrim(id) <> ''),
    CHECK (period_start <= period_end),
    CONSTRAINT panama_fiscal_periods_finite_dates CHECK (
        isfinite(period_start) AND isfinite(period_end)
        AND (income_tax_return_due_on IS NULL OR isfinite(income_tax_return_due_on))
        AND (income_tax_return_filed_on IS NULL OR isfinite(income_tax_return_filed_on))
        AND (municipal_return_due_on IS NULL OR isfinite(municipal_return_due_on))
        AND (municipal_return_filed_on IS NULL OR isfinite(municipal_return_filed_on))
        AND (form_43_filed_through IS NULL OR isfinite(form_43_filed_through))
    )
);

CREATE TABLE panama_estimated_tax_installments (
    book_id VARCHAR NOT NULL,
    period_id VARCHAR NOT NULL,
    installment_number SMALLINT NOT NULL,
    due_on DATE NOT NULL,
    amount NUMERIC(100,5) NOT NULL,
    paid_on DATE,
    amount_paid NUMERIC(100,5),
    reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, period_id, installment_number),
    FOREIGN KEY (book_id, period_id)
        REFERENCES panama_fiscal_periods(book_id, id),
    CHECK (installment_number BETWEEN 1 AND 3),
    CHECK (amount >= 0 AND njord.is_finite(amount)),
    CHECK (
        amount_paid IS NULL
        OR (amount_paid >= 0 AND njord.is_finite(amount_paid))
    ),
    CHECK ((paid_on IS NULL) = (amount_paid IS NULL))
    , CHECK (isfinite(due_on) AND (paid_on IS NULL OR isfinite(paid_on)))
);

CREATE TABLE panama_account_income_tax_mappings (
    book_id VARCHAR NOT NULL,
    acct VARCHAR NOT NULL,
    treatment_id VARCHAR NOT NULL REFERENCES panama_income_tax_treatments(id),
    inclusion_percent NUMERIC(8,6) NOT NULL DEFAULT 1,
    notes VARCHAR,
    PRIMARY KEY (book_id, acct),
    FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
    CHECK (inclusion_percent BETWEEN 0 AND 1)
);

CREATE TABLE panama_account_itbms_mappings (
    book_id VARCHAR NOT NULL,
    acct VARCHAR NOT NULL,
    transaction_role VARCHAR NOT NULL,
    treatment_id VARCHAR NOT NULL REFERENCES panama_itbms_treatments(id),
    notes VARCHAR,
    PRIMARY KEY (book_id, acct, transaction_role),
    FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
    CHECK (transaction_role IN ('sale', 'purchase'))
);

CREATE TABLE panama_business_control_accounts (
    book_id VARCHAR PRIMARY KEY REFERENCES panama_business_profiles(book_id),
    itbms_payable_acct VARCHAR,
    itbms_receivable_acct VARCHAR,
    income_tax_payable_acct VARCHAR,
    FOREIGN KEY (book_id, itbms_payable_acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, itbms_receivable_acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, income_tax_payable_acct) REFERENCES accts(book_id, id),
    CHECK (
        itbms_payable_acct IS NULL OR itbms_receivable_acct IS NULL
        OR itbms_payable_acct <> itbms_receivable_acct
    )
);

-- Tax identity extends the generic party master; names and roles remain
-- authoritative in trade_parties.
CREATE TABLE panama_third_parties (
    book_id VARCHAR NOT NULL,
    party_id VARCHAR NOT NULL,
    taxpayer_id VARCHAR,
    verification_digit VARCHAR,
    party_type VARCHAR NOT NULL REFERENCES panama_third_party_types(id),
    country_code VARCHAR(2) NOT NULL DEFAULT 'PA',
    form_20_reportable BOOLEAN NOT NULL DEFAULT TRUE,
    notes VARCHAR,
    PRIMARY KEY (book_id, party_id),
    FOREIGN KEY (book_id, party_id) REFERENCES trade_parties(book_id, id),
    CHECK (taxpayer_id IS NULL OR btrim(taxpayer_id) <> ''),
    CHECK (verification_digit IS NULL OR btrim(verification_digit) <> ''),
    CHECK (country_code ~ '^[A-Z]{2}$')
);

-- The posting is authoritative for payment date and amount.
CREATE TABLE panama_reportable_payments (
    book_id VARCHAR NOT NULL,
    xid INTEGER NOT NULL,
    acct VARCHAR NOT NULL,
    party_id VARCHAR NOT NULL,
    payment_category VARCHAR NOT NULL REFERENCES panama_payment_categories(id),
    document_reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, xid, acct),
    FOREIGN KEY (book_id, xid, acct)
        REFERENCES xaction_bits(book_id, xid, acct)
        ON UPDATE CASCADE,
    FOREIGN KEY (book_id, party_id)
        REFERENCES panama_third_parties(book_id, party_id)
);

CREATE TABLE panama_dividend_distributions (
    book_id VARCHAR NOT NULL REFERENCES panama_business_profiles(book_id),
    id VARCHAR NOT NULL,
    declared_on DATE NOT NULL,
    paid_on DATE,
    recipient_name VARCHAR NOT NULL,
    recipient_taxpayer_id VARCHAR,
    source VARCHAR NOT NULL REFERENCES panama_dividend_sources(id),
    gross_dividend NUMERIC(100,5) NOT NULL,
    withholding_tax NUMERIC(100,5) NOT NULL DEFAULT 0,
    complementary_tax NUMERIC(100,5) NOT NULL DEFAULT 0,
    withholding_paid_on DATE,
    xid INTEGER,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(recipient_name) <> ''),
    CHECK (paid_on IS NULL OR declared_on <= paid_on),
    CHECK (gross_dividend > 0 AND njord.is_finite(gross_dividend)),
    CHECK (withholding_tax >= 0 AND njord.is_finite(withholding_tax)),
    CHECK (complementary_tax >= 0 AND njord.is_finite(complementary_tax)),
    CHECK (withholding_tax + complementary_tax <= gross_dividend),
    CONSTRAINT panama_dividend_finite_dates CHECK (
        isfinite(declared_on)
        AND (paid_on IS NULL OR isfinite(paid_on))
        AND (withholding_paid_on IS NULL OR isfinite(withholding_paid_on))
    )
);

CREATE OR REPLACE FUNCTION validate_panama_fiscal_period()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;
    IF EXISTS (
        SELECT 1 FROM panama_fiscal_periods AS existing
        WHERE existing.book_id = NEW.book_id
          AND existing.id <> NEW.id
          AND daterange(existing.period_start, existing.period_end, '[]')
              && daterange(NEW.period_start, NEW.period_end, '[]')
    ) THEN
        RAISE EXCEPTION 'Panama fiscal period %.% overlaps another period', NEW.book_id, NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_fiscal_periods_no_overlap';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_fiscal_periods_validate
    BEFORE INSERT OR UPDATE OF book_id, id, period_start, period_end
    ON panama_fiscal_periods
    FOR EACH ROW EXECUTE FUNCTION validate_panama_fiscal_period();

CREATE OR REPLACE FUNCTION validate_panama_account_mapping()
RETURNS trigger AS $$
DECLARE
    mapped_type VARCHAR;
    mapped_placeholder BOOLEAN;
    required_type VARCHAR;
    expected_role VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-panama-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT type, placeholder INTO mapped_type, mapped_placeholder
    FROM accts WHERE book_id = NEW.book_id AND id = NEW.acct;
    IF NOT FOUND THEN RETURN NEW; END IF;
    IF mapped_placeholder THEN
        RAISE EXCEPTION 'Panama account mapping %.% requires a posting account', NEW.book_id, NEW.acct
            USING ERRCODE = '23514', CONSTRAINT = 'panama_account_mapping_posting_account';
    END IF;

    IF TG_TABLE_NAME = 'panama_account_income_tax_mappings' THEN
	SELECT treatment.required_type INTO required_type
	FROM panama_income_tax_treatments AS treatment
	WHERE treatment.id = NEW.treatment_id;
    ELSE
        SELECT transaction_role INTO expected_role
        FROM panama_itbms_treatments WHERE id = NEW.treatment_id;
        IF FOUND AND expected_role <> NEW.transaction_role THEN
            RAISE EXCEPTION 'ITBMS treatment % is for %, not %',
                NEW.treatment_id, expected_role, NEW.transaction_role
                USING ERRCODE = '23514', CONSTRAINT = 'panama_itbms_mapping_role';
        END IF;
        IF NEW.transaction_role = 'sale' AND mapped_type <> 'I' THEN
            RAISE EXCEPTION 'Panama sale mappings require an income account'
                USING ERRCODE = '23514', CONSTRAINT = 'panama_itbms_mapping_account_type';
        ELSIF NEW.transaction_role = 'purchase' AND mapped_type NOT IN ('E', 'A') THEN
            RAISE EXCEPTION 'Panama purchase mappings require an expense or asset account'
                USING ERRCODE = '23514', CONSTRAINT = 'panama_itbms_mapping_account_type';
        END IF;
    END IF;
    IF required_type IS NOT NULL AND required_type <> mapped_type THEN
        RAISE EXCEPTION 'Panama tax mapping requires account type %, not %', required_type, mapped_type
            USING ERRCODE = '23514', CONSTRAINT = 'panama_account_mapping_account_type';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_account_income_tax_mapping_validate
    BEFORE INSERT OR UPDATE ON panama_account_income_tax_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_panama_account_mapping();

CREATE TRIGGER panama_account_itbms_mapping_validate
    BEFORE INSERT OR UPDATE ON panama_account_itbms_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_panama_account_mapping();

CREATE OR REPLACE FUNCTION validate_panama_business_control_accounts()
RETURNS trigger AS $$
DECLARE
    control RECORD;
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    FOR control IN
        SELECT * FROM (VALUES
            (NEW.itbms_payable_acct, 'L'::VARCHAR, 'ITBMS payable'),
            (NEW.itbms_receivable_acct, 'A'::VARCHAR, 'ITBMS receivable'),
            (NEW.income_tax_payable_acct, 'L'::VARCHAR, 'income tax payable')
        ) AS controls(acct, required_type, label)
        WHERE acct IS NOT NULL
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM accts JOIN books ON books.id = accts.book_id
            WHERE accts.book_id = NEW.book_id
              AND accts.id = control.acct
              AND accts.type = control.required_type
              AND NOT accts.placeholder
              AND accts.atype = books.reporting_asset
        ) THEN
            RAISE EXCEPTION 'Panama % control account %.% is incompatible',
                control.label, NEW.book_id, control.acct
                USING ERRCODE = '23514', CONSTRAINT = 'panama_business_control_account_type';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_business_control_accounts_validate
    BEFORE INSERT OR UPDATE ON panama_business_control_accounts
    FOR EACH ROW EXECUTE FUNCTION validate_panama_business_control_accounts();

CREATE OR REPLACE FUNCTION njord.panama_reportable_payment_valid(
    p_book_id VARCHAR,
    p_xid INTEGER,
    p_acct VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM xaction_bits AS posting
        JOIN accts AS account
          ON account.book_id = posting.book_id
         AND account.id = posting.acct
        WHERE posting.book_id = p_book_id
          AND posting.xid = p_xid
          AND posting.acct = p_acct
          AND posting.amt < 0
          AND account.type IN ('A', 'L')
          AND NOT account.placeholder
    );
$$;

CREATE OR REPLACE FUNCTION validate_panama_reportable_payment()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF NOT njord.panama_reportable_payment_valid(
        NEW.book_id, NEW.xid, NEW.acct
    ) THEN
        RAISE EXCEPTION 'Panama reportable payment must tag an outgoing asset or liability posting'
            USING ERRCODE = '23514', CONSTRAINT = 'panama_reportable_payment_posting';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_reportable_payments_validate
    BEFORE INSERT OR UPDATE ON panama_reportable_payments
    FOR EACH ROW EXECUTE FUNCTION validate_panama_reportable_payment();

-- The metadata-side trigger above is only half of the invariant: posting
-- edits must not turn a tagged payment into an incoming or non-payment line.
CREATE OR REPLACE FUNCTION enforce_panama_posting_evidence()
RETURNS trigger AS $$
DECLARE
    invalid_acct VARCHAR;
BEGIN
    SELECT payment.acct INTO invalid_acct
    FROM panama_reportable_payments AS payment
    WHERE (
        (
            TG_OP <> 'INSERT'
            AND payment.book_id = OLD.book_id
            AND payment.xid = OLD.xid
        ) OR (
            TG_OP <> 'DELETE'
            AND payment.book_id = NEW.book_id
            AND payment.xid = NEW.xid
        )
    )
    AND NOT njord.panama_reportable_payment_valid(
        payment.book_id, payment.xid, payment.acct
    )
    LIMIT 1;

    IF invalid_acct IS NOT NULL THEN
        RAISE EXCEPTION 'Panama reportable payment posting is no longer valid: %',
            invalid_acct
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_reportable_payment_posting';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER xaction_bits_preserve_panama_payment_evidence
    AFTER INSERT OR UPDATE OR DELETE ON xaction_bits
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_panama_posting_evidence();

COMMENT ON TABLE panama_business_profiles IS
    'Panama business identity and current configuration; reporting rates are pinned by effective-dated tax policies.';
COMMENT ON TABLE panama_fiscal_periods IS
    'Non-overlapping Panama fiscal periods and filing facts, each pinned to a tax policy.';
COMMENT ON TABLE panama_estimated_tax_installments IS
    'Explicit estimated income-tax installment schedule; values are preparation facts, never guessed from a hard-coded formula.';
COMMENT ON TABLE panama_reportable_payments IS
    'Form 20 working-paper classifications linked to authoritative outgoing ledger postings.';
COMMENT ON TABLE panama_dividend_distributions IS
    'Dividend, withholding, and complementary-tax preparation facts; not a filing submission record.';

-- Panama residential-property extension -----------------------------------

CREATE TABLE panama_property_uses (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL
);

CREATE TABLE panama_lease_tax_treatments (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    rate_kind VARCHAR NOT NULL,
    requires_exclusive_residential_use BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (rate_kind IN ('standard', 'lodging', 'exempt', 'manual_review'))
);

CREATE TABLE panama_property_expense_treatments (
    id VARCHAR PRIMARY KEY,
    label VARCHAR NOT NULL,
    required_type VARCHAR NOT NULL REFERENCES acct_types(id),
    accounting_effect VARCHAR NOT NULL,
    CHECK (accounting_effect IN (
        'deductible_repair', 'capital_improvement', 'depreciation',
        'property_tax', 'municipal_tax', 'insurance', 'utilities',
        'management', 'manual_review'
    ))
);

INSERT INTO panama_property_uses (id, label) VALUES
    ('long_term_residential', 'Long-term residential rental'),
    ('short_stay_lodging', 'Short-stay lodging'),
    ('mixed_use', 'Mixed use / manual allocation');

INSERT INTO panama_lease_tax_treatments (
    id, label, rate_kind, requires_exclusive_residential_use
) VALUES
    ('residential_over_six_months_exempt', 'Exclusive residential lease over six months (exempt)', 'exempt', TRUE),
    ('short_stay_lodging', 'Short-stay lodging', 'lodging', FALSE),
    ('standard_taxable', 'Standard taxable lease', 'standard', FALSE),
    ('manual_review', 'Manual ITBMS review', 'manual_review', FALSE);

INSERT INTO panama_property_expense_treatments (
    id, label, required_type, accounting_effect
) VALUES
    ('repairs', 'Repairs and maintenance', 'E', 'deductible_repair'),
    ('capital_improvements', 'Capital improvements', 'A', 'capital_improvement'),
    ('depreciation', 'Building and improvement depreciation', 'E', 'depreciation'),
    ('property_tax', 'Property tax', 'E', 'property_tax'),
    ('municipal_tax', 'Municipal tax', 'E', 'municipal_tax'),
    ('insurance', 'Property insurance', 'E', 'insurance'),
    ('utilities', 'Property utilities', 'E', 'utilities'),
    ('management', 'Property management', 'E', 'management'),
    ('manual_review', 'Other / manual review', 'E', 'manual_review');

CREATE TABLE panama_residential_property_profiles (
    book_id VARCHAR PRIMARY KEY REFERENCES panama_business_profiles(book_id),
    enabled_on DATE NOT NULL DEFAULT CURRENT_DATE,
    tenant_deposit_control_acct VARCHAR,
    notes VARCHAR,
    FOREIGN KEY (book_id, tenant_deposit_control_acct)
        REFERENCES accts(book_id, id),
    CHECK (isfinite(enabled_on))
);

CREATE TABLE panama_properties (
    book_id VARCHAR NOT NULL REFERENCES panama_residential_property_profiles(book_id),
    id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    property_use VARCHAR NOT NULL REFERENCES panama_property_uses(id),
    finca_number VARCHAR,
    municipality VARCHAR NOT NULL REFERENCES panama_municipalities(id),
    address VARCHAR,
    acquired_on DATE,
    land_acct VARCHAR NOT NULL,
    building_acct VARCHAR NOT NULL,
    improvements_acct VARCHAR,
    accumulated_depreciation_acct VARCHAR,
    rent_income_acct VARCHAR NOT NULL,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, land_acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, building_acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, improvements_acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, accumulated_depreciation_acct)
        REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, rent_income_acct) REFERENCES accts(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(name) <> ''),
    CHECK (land_acct <> building_acct),
    CHECK (improvements_acct IS NULL OR improvements_acct <> land_acct),
    CHECK (improvements_acct IS NULL OR improvements_acct <> building_acct),
    CHECK (acquired_on IS NULL OR isfinite(acquired_on)),
    CONSTRAINT panama_property_distinct_depreciation_account CHECK (
        accumulated_depreciation_acct IS NULL
        OR accumulated_depreciation_acct NOT IN (
            land_acct, building_acct, improvements_acct
        )
    )
);

CREATE TABLE panama_property_units (
    book_id VARCHAR NOT NULL,
    property_id VARCHAR NOT NULL,
    id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    bedrooms SMALLINT,
    floor_area_square_metres NUMERIC(12,3),
    notes VARCHAR,
    PRIMARY KEY (book_id, property_id, id),
    FOREIGN KEY (book_id, property_id)
        REFERENCES panama_properties(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(name) <> ''),
    CHECK (bedrooms IS NULL OR bedrooms >= 0),
    CONSTRAINT panama_property_unit_floor_area CHECK (
        floor_area_square_metres IS NULL
        OR (
            floor_area_square_metres > 0
            AND njord.is_finite(floor_area_square_metres)
        )
    )
);

CREATE TABLE panama_tenants (
    book_id VARCHAR NOT NULL REFERENCES panama_residential_property_profiles(book_id),
    id VARCHAR NOT NULL,
    name VARCHAR NOT NULL,
    taxpayer_id VARCHAR,
    trade_party_id VARCHAR,
    email VARCHAR,
    phone VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    UNIQUE (book_id, trade_party_id),
    FOREIGN KEY (book_id, trade_party_id)
        REFERENCES trade_parties(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (btrim(name) <> ''),
    CHECK (taxpayer_id IS NULL OR btrim(taxpayer_id) <> '')
);

CREATE TABLE panama_leases (
    book_id VARCHAR NOT NULL,
    id VARCHAR NOT NULL,
    property_id VARCHAR NOT NULL,
    unit_id VARCHAR NOT NULL,
    tenant_id VARCHAR NOT NULL,
    starts_on DATE NOT NULL,
    ends_on DATE,
    monthly_rent NUMERIC(100,5) NOT NULL,
    tax_treatment VARCHAR NOT NULL REFERENCES panama_lease_tax_treatments(id),
    exclusive_residential_use BOOLEAN NOT NULL DEFAULT TRUE,
    security_deposit NUMERIC(100,5) NOT NULL DEFAULT 0,
    contract_registered_on DATE,
    deposit_consigned_on DATE,
    notes VARCHAR,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, property_id, unit_id)
        REFERENCES panama_property_units(book_id, property_id, id),
    FOREIGN KEY (book_id, tenant_id)
        REFERENCES panama_tenants(book_id, id),
    CHECK (btrim(id) <> ''),
    CHECK (ends_on IS NULL OR starts_on < ends_on),
    CHECK (monthly_rent > 0 AND njord.is_finite(monthly_rent)),
    CHECK (security_deposit >= 0 AND njord.is_finite(security_deposit)),
    CHECK (contract_registered_on IS NULL OR starts_on <= contract_registered_on),
    CHECK (deposit_consigned_on IS NULL OR starts_on <= deposit_consigned_on),
    CONSTRAINT panama_leases_finite_dates CHECK (
        isfinite(starts_on)
        AND (ends_on IS NULL OR isfinite(ends_on))
        AND (contract_registered_on IS NULL OR isfinite(contract_registered_on))
        AND (deposit_consigned_on IS NULL OR isfinite(deposit_consigned_on))
    )
);

CREATE TABLE panama_property_tax_assessments (
    book_id VARCHAR NOT NULL,
    property_id VARCHAR NOT NULL,
    tax_year INTEGER NOT NULL,
    taxable_value NUMERIC(100,5) NOT NULL,
    annual_tax NUMERIC(100,5) NOT NULL,
    early_payment_discount_rate NUMERIC(8,6) NOT NULL DEFAULT 0.10,
    paid_in_full_on DATE,
    reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, property_id, tax_year),
    FOREIGN KEY (book_id, property_id)
        REFERENCES panama_properties(book_id, id),
    CHECK (tax_year BETWEEN 1900 AND 9999),
    CHECK (taxable_value >= 0 AND njord.is_finite(taxable_value)),
    CHECK (annual_tax >= 0 AND njord.is_finite(annual_tax)),
    CHECK (early_payment_discount_rate BETWEEN 0 AND 1),
    CHECK (paid_in_full_on IS NULL OR isfinite(paid_in_full_on))
);

CREATE TABLE panama_property_tax_installments (
    book_id VARCHAR NOT NULL,
    property_id VARCHAR NOT NULL,
    tax_year INTEGER NOT NULL,
    installment_number SMALLINT NOT NULL,
    due_on DATE NOT NULL,
    amount NUMERIC(100,5) NOT NULL,
    paid_on DATE,
    amount_paid NUMERIC(100,5),
    reference VARCHAR,
    notes VARCHAR,
    PRIMARY KEY (book_id, property_id, tax_year, installment_number),
    FOREIGN KEY (book_id, property_id, tax_year)
        REFERENCES panama_property_tax_assessments(book_id, property_id, tax_year),
    CHECK (installment_number BETWEEN 1 AND 3),
    CHECK (amount >= 0 AND njord.is_finite(amount)),
    CHECK (
        amount_paid IS NULL
        OR (amount_paid >= 0 AND njord.is_finite(amount_paid))
    ),
    CHECK ((paid_on IS NULL) = (amount_paid IS NULL)),
    CHECK (isfinite(due_on) AND (paid_on IS NULL OR isfinite(paid_on)))
);

CREATE TABLE panama_account_property_expense_mappings (
    book_id VARCHAR NOT NULL,
    acct VARCHAR NOT NULL,
    property_id VARCHAR NOT NULL,
    treatment_id VARCHAR NOT NULL REFERENCES panama_property_expense_treatments(id),
    notes VARCHAR,
    PRIMARY KEY (book_id, acct),
    FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
    FOREIGN KEY (book_id, property_id)
        REFERENCES panama_properties(book_id, id)
);

CREATE OR REPLACE FUNCTION validate_panama_residential_control_account()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF NEW.tenant_deposit_control_acct IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM accts JOIN books ON books.id = accts.book_id
        WHERE accts.book_id = NEW.book_id
          AND accts.id = NEW.tenant_deposit_control_acct
          AND accts.type = 'L'
          AND NOT accts.placeholder
          AND accts.atype = books.reporting_asset
    ) THEN
        RAISE EXCEPTION 'tenant deposit control %.% must be a posting liability in the reporting asset',
            NEW.book_id, NEW.tenant_deposit_control_acct
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_tenant_deposit_control_account';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_residential_property_profiles_validate
    BEFORE INSERT OR UPDATE ON panama_residential_property_profiles
    FOR EACH ROW EXECUTE FUNCTION validate_panama_residential_control_account();

CREATE OR REPLACE FUNCTION validate_panama_property_accounts()
RETURNS trigger AS $$
DECLARE
    account_spec RECORD;
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    FOR account_spec IN
        SELECT * FROM (VALUES
            (NEW.land_acct, 'A'::VARCHAR, TRUE, 'land'),
            (NEW.building_acct, 'A'::VARCHAR, TRUE, 'building'),
            (NEW.improvements_acct, 'A'::VARCHAR, TRUE, 'improvements'),
            (NEW.accumulated_depreciation_acct, 'A'::VARCHAR, FALSE, 'accumulated depreciation'),
            (NEW.rent_income_acct, 'I'::VARCHAR, FALSE, 'rent income')
        ) AS specs(acct, required_type, requires_fixed_asset, label)
        WHERE acct IS NOT NULL
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM accts
            WHERE accts.book_id = NEW.book_id
              AND accts.id = account_spec.acct
              AND accts.type = account_spec.required_type
              AND NOT accts.placeholder
              AND (NOT account_spec.requires_fixed_asset OR accts.account_kind = 'fixed_asset')
        ) THEN
            RAISE EXCEPTION 'Panama property % account %.% is incompatible',
                account_spec.label, NEW.book_id, account_spec.acct
                USING ERRCODE = '23514', CONSTRAINT = 'panama_property_account_type';
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_properties_validate_accounts
    BEFORE INSERT OR UPDATE ON panama_properties
    FOR EACH ROW EXECUTE FUNCTION validate_panama_property_accounts();

CREATE OR REPLACE FUNCTION validate_panama_lease()
RETURNS trigger AS $$
DECLARE
    requires_residential BOOLEAN;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-panama-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT requires_exclusive_residential_use INTO requires_residential
    FROM panama_lease_tax_treatments WHERE id = NEW.tax_treatment;
    IF requires_residential AND NOT NEW.exclusive_residential_use THEN
        RAISE EXCEPTION 'lease treatment % requires exclusive residential use', NEW.tax_treatment
            USING ERRCODE = '23514', CONSTRAINT = 'panama_lease_exclusive_residential_use';
    END IF;
    IF NEW.tax_treatment = 'residential_over_six_months_exempt'
       AND NEW.ends_on IS NOT NULL
       AND NEW.ends_on <= (NEW.starts_on + INTERVAL '6 months')::DATE THEN
        RAISE EXCEPTION 'residential ITBMS exemption requires a lease over six months'
            USING ERRCODE = '23514', CONSTRAINT = 'panama_lease_minimum_exempt_term';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_leases_validate
    BEFORE INSERT OR UPDATE ON panama_leases
    FOR EACH ROW EXECUTE FUNCTION validate_panama_lease();

CREATE OR REPLACE FUNCTION validate_panama_property_expense_mapping()
RETURNS trigger AS $$
DECLARE
    mapped_type VARCHAR;
    mapped_placeholder BOOLEAN;
    required_type VARCHAR;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-panama-reference-data', 0)
    );
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT type, placeholder INTO mapped_type, mapped_placeholder
    FROM accts WHERE book_id = NEW.book_id AND id = NEW.acct;
    SELECT treatment.required_type INTO required_type
    FROM panama_property_expense_treatments AS treatment
    WHERE treatment.id = NEW.treatment_id;
    IF mapped_type IS NOT NULL AND (mapped_placeholder OR mapped_type <> required_type) THEN
        RAISE EXCEPTION 'property treatment % requires a posting account of type %',
            NEW.treatment_id, required_type
            USING ERRCODE = '23514', CONSTRAINT = 'panama_property_expense_mapping_type';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_account_property_expense_mapping_validate
    BEFORE INSERT OR UPDATE ON panama_account_property_expense_mappings
    FOR EACH ROW EXECUTE FUNCTION validate_panama_property_expense_mapping();

-- Product reference rows are extensible, but changing their semantic fields
-- must not silently invalidate already configured Books.
CREATE OR REPLACE FUNCTION protect_panama_reference_relations()
RETURNS trigger AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('njord-panama-reference-data', 0)
    );
    PERFORM 1
    FROM books
    WHERE id IN (
        SELECT mapping.book_id
        FROM panama_account_income_tax_mappings AS mapping
        WHERE TG_TABLE_NAME = 'panama_income_tax_treatments'
          AND mapping.treatment_id = NEW.id
        UNION
        SELECT mapping.book_id
        FROM panama_account_itbms_mappings AS mapping
        WHERE TG_TABLE_NAME = 'panama_itbms_treatments'
          AND mapping.treatment_id = NEW.id
        UNION
        SELECT mapping.book_id
        FROM panama_account_property_expense_mappings AS mapping
        WHERE TG_TABLE_NAME = 'panama_property_expense_treatments'
          AND mapping.treatment_id = NEW.id
        UNION
        SELECT lease.book_id
        FROM panama_leases AS lease
        WHERE TG_TABLE_NAME = 'panama_lease_tax_treatments'
          AND lease.tax_treatment = NEW.id
    )
    ORDER BY id
    FOR UPDATE;

    IF TG_TABLE_NAME = 'panama_income_tax_treatments' AND EXISTS (
        SELECT 1
        FROM panama_account_income_tax_mappings AS mapping
        JOIN accts
          ON accts.book_id = mapping.book_id AND accts.id = mapping.acct
        WHERE mapping.treatment_id = NEW.id
          AND NEW.required_type IS NOT NULL
          AND accts.type <> NEW.required_type
    ) THEN
        RAISE EXCEPTION 'Panama income-tax treatment % is incompatible with existing mappings', NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_income_tax_treatment_existing_mappings';
    ELSIF TG_TABLE_NAME = 'panama_itbms_treatments' AND EXISTS (
        SELECT 1 FROM panama_account_itbms_mappings AS mapping
        WHERE mapping.treatment_id = NEW.id
          AND mapping.transaction_role <> NEW.transaction_role
    ) THEN
        RAISE EXCEPTION 'Panama ITBMS treatment % role is required by existing mappings', NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_itbms_treatment_existing_mappings';
    ELSIF TG_TABLE_NAME = 'panama_property_expense_treatments' AND EXISTS (
        SELECT 1
        FROM panama_account_property_expense_mappings AS mapping
        JOIN accts
          ON accts.book_id = mapping.book_id AND accts.id = mapping.acct
        WHERE mapping.treatment_id = NEW.id
          AND accts.type <> NEW.required_type
    ) THEN
        RAISE EXCEPTION 'Panama property treatment % is incompatible with existing mappings', NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_property_treatment_existing_mappings';
    ELSIF TG_TABLE_NAME = 'panama_lease_tax_treatments'
          AND NEW.requires_exclusive_residential_use
          AND EXISTS (
              SELECT 1 FROM panama_leases AS lease
              WHERE lease.tax_treatment = NEW.id
                AND NOT lease.exclusive_residential_use
          ) THEN
        RAISE EXCEPTION 'Panama lease treatment % is incompatible with existing leases', NEW.id
            USING ERRCODE = '23514',
                  CONSTRAINT = 'panama_lease_treatment_existing_leases';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER panama_income_tax_treatments_protect_relations
    BEFORE UPDATE ON panama_income_tax_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_panama_reference_relations();
CREATE TRIGGER panama_itbms_treatments_protect_relations
    BEFORE UPDATE ON panama_itbms_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_panama_reference_relations();
CREATE TRIGGER panama_property_expense_treatments_protect_relations
    BEFORE UPDATE ON panama_property_expense_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_panama_reference_relations();
CREATE TRIGGER panama_lease_tax_treatments_protect_relations
    BEFORE UPDATE ON panama_lease_tax_treatments
    FOR EACH ROW EXECUTE FUNCTION protect_panama_reference_relations();

-- Metadata validators protect writes to the Panama tables; this deferred
-- account-side check protects the same contracts from later account edits.
CREATE OR REPLACE FUNCTION enforce_panama_account_relations()
RETURNS trigger AS $$
DECLARE
    account accts%ROWTYPE;
BEGIN
    SELECT * INTO account
    FROM accts WHERE book_id = NEW.book_id AND id = NEW.id;
    IF NOT FOUND THEN RETURN NULL; END IF;

    IF EXISTS (
	SELECT 1
	FROM panama_account_income_tax_mappings AS mapping
	JOIN panama_income_tax_treatments AS treatment
	  ON treatment.id = mapping.treatment_id
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND (
	      account.placeholder
	      OR (treatment.required_type IS NOT NULL
		  AND treatment.required_type <> account.type)
	  )
    ) OR EXISTS (
	SELECT 1
	FROM panama_account_itbms_mappings AS mapping
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND (
	      account.placeholder
	      OR (mapping.transaction_role = 'sale' AND account.type <> 'I')
	      OR (mapping.transaction_role = 'purchase'
		  AND account.type NOT IN ('E', 'A'))
	  )
    ) OR EXISTS (
	SELECT 1
	FROM panama_account_property_expense_mappings AS mapping
	JOIN panama_property_expense_treatments AS treatment
	  ON treatment.id = mapping.treatment_id
	WHERE mapping.book_id = NEW.book_id
	  AND mapping.acct = NEW.id
	  AND (account.placeholder OR treatment.required_type <> account.type)
    ) THEN
	RAISE EXCEPTION 'account %.% is incompatible with its Panama mapping',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'panama_account_mapping_account_type';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM panama_business_control_accounts AS controls
	JOIN books ON books.id = controls.book_id
	WHERE controls.book_id = NEW.book_id
	  AND NEW.id IN (
	      controls.itbms_payable_acct,
	      controls.itbms_receivable_acct,
	      controls.income_tax_payable_acct
	  )
	  AND (
	      account.placeholder
	      OR account.atype <> books.reporting_asset
	      OR (controls.itbms_payable_acct = NEW.id AND account.type <> 'L')
	      OR (controls.itbms_receivable_acct = NEW.id AND account.type <> 'A')
	      OR (controls.income_tax_payable_acct = NEW.id AND account.type <> 'L')
	  )
    ) OR EXISTS (
	SELECT 1
	FROM panama_residential_property_profiles AS profile
	JOIN books ON books.id = profile.book_id
	WHERE profile.book_id = NEW.book_id
	  AND profile.tenant_deposit_control_acct = NEW.id
	  AND (
	      account.type <> 'L'
	      OR account.placeholder
	      OR account.atype <> books.reporting_asset
	  )
    ) THEN
	RAISE EXCEPTION 'account %.% is incompatible with its Panama control relation',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'panama_control_account_type';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM panama_properties AS property
	WHERE property.book_id = NEW.book_id
	  AND NEW.id IN (
	      property.land_acct, property.building_acct,
	      property.improvements_acct,
	      property.accumulated_depreciation_acct,
	      property.rent_income_acct
	  )
	  AND (
	      account.placeholder
	      OR (NEW.id IN (
		      property.land_acct, property.building_acct,
		      property.improvements_acct
		  ) AND (account.type <> 'A'
		      OR account.account_kind <> 'fixed_asset'))
	      OR (property.accumulated_depreciation_acct = NEW.id
		  AND account.type <> 'A')
	      OR (property.rent_income_acct = NEW.id AND account.type <> 'I')
	  )
    ) THEN
	RAISE EXCEPTION 'account %.% is incompatible with its Panama property relation',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'panama_property_account_type';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM panama_reportable_payments AS payment
	WHERE payment.book_id = NEW.book_id
	  AND payment.acct = NEW.id
	  AND NOT njord.panama_reportable_payment_valid(
	      payment.book_id, payment.xid, payment.acct
	  )
    ) THEN
	RAISE EXCEPTION 'account %.% invalidates Panama payment evidence',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'panama_reportable_payment_posting';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER accts_preserve_panama_relations
    AFTER UPDATE ON accts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (
	(OLD.type, OLD.atype, OLD.account_kind, OLD.placeholder)
	IS DISTINCT FROM
	(NEW.type, NEW.atype, NEW.account_kind, NEW.placeholder)
    )
    EXECUTE FUNCTION enforce_panama_account_relations();

COMMENT ON TABLE panama_residential_property_profiles IS
    'Optional extension marker and tenant-deposit control for Panama residential-property businesses.';
COMMENT ON TABLE panama_properties IS
    'Property register with land, building, improvements, depreciation, and rent accounts kept explicit and separate.';
COMMENT ON TABLE panama_leases IS
    'Lease, ITBMS-treatment, MIVIOT registration, and security-deposit preparation facts.';
COMMENT ON TABLE panama_property_tax_assessments IS
    'Annual property-tax assessment facts; installments are recorded separately.';

-- Panama report definitions -------------------------------------------------

CREATE OR REPLACE VIEW panama_report_catalog AS
    SELECT *
    FROM (VALUES
	(100, 'panama-income-tax'::VARCHAR,
	    'Panama Corporate Income Tax Working Paper'::VARCHAR,
	    'Mapped accounting income and expenses reconciled to an indicative taxable result; review losses, incentives, source, and claims before filing.'::VARCHAR,
	    'period'::VARCHAR, 'Panama business · DGI'::VARCHAR,
	    'panama_business'::VARCHAR),
	(102, 'panama-form-20'::VARCHAR,
	    'Panama Form 20 Third-party Payments'::VARCHAR,
	    'Reportable third-party payment dataset for review against Form 20 requirements; not a filed information return.'::VARCHAR,
	    'period'::VARCHAR, 'Panama business · DGI'::VARCHAR,
	    'panama_business'::VARCHAR),
	(103, 'panama-form-43-threshold'::VARCHAR,
	    'Panama Form 43 Threshold Check'::VARCHAR,
	    'Gross-revenue and total-asset indicators compared with the effective configured policy thresholds.'::VARCHAR,
	    'period'::VARCHAR, 'Panama business · DGI'::VARCHAR,
	    'panama_business'::VARCHAR),
	(104, 'panama-dividend-tax'::VARCHAR,
	    'Panama Dividend & Complementary Tax Schedule'::VARCHAR,
	    'Declared distributions and recorded tax amounts by recipient and source; not a Form 07 or payment instruction.'::VARCHAR,
	    'period'::VARCHAR, 'Panama business · DGI'::VARCHAR,
	    'panama_business'::VARCHAR),
	(105, 'panama-compliance-calendar'::VARCHAR,
	    'Panama Business Compliance Calendar'::VARCHAR,
	    'Configured and derived business deadlines in one review calendar; confirm every obligation with the responsible adviser or authority.'::VARCHAR,
	    'period'::VARCHAR, 'Panama business · Compliance'::VARCHAR,
	    'panama_business'::VARCHAR),
	(200, 'panama-rent-roll'::VARCHAR,
	    'Panama Residential Rent Roll'::VARCHAR,
	    'Property, unit, tenant, lease, monthly rent, deposit, and indirect-tax facts at a chosen date.'::VARCHAR,
	    'as_of'::VARCHAR, 'Panama residential property'::VARCHAR,
	    'panama_residential_property'::VARCHAR),
	(201, 'panama-property-profit-loss'::VARCHAR,
	    'Panama Property Profit & Loss'::VARCHAR,
	    'Rent and mapped property costs by property for a period, including repair and capital classifications.'::VARCHAR,
	    'period'::VARCHAR, 'Panama residential property'::VARCHAR,
	    'panama_residential_property'::VARCHAR),
	(106, 'panama-itbms'::VARCHAR,
	    'Panama ITBMS Working Paper'::VARCHAR,
	    'Mapped taxable, exempt, and out-of-scope activity with policy rates and an ITBMS control check; not Form 430.'::VARCHAR,
	    'period'::VARCHAR, 'Panama business · DGI'::VARCHAR,
	    'panama_business'::VARCHAR),
	(203, 'panama-property-tax'::VARCHAR,
	    'Panama Property Tax Schedule'::VARCHAR,
	    'Recorded property assessments, instalment dates, and payments for review.'::VARCHAR,
	    'period'::VARCHAR, 'Panama residential property'::VARCHAR,
	    'panama_residential_property'::VARCHAR),
	(205, 'panama-repair-capital'::VARCHAR,
	    'Panama Repairs vs Capital Schedule'::VARCHAR,
	    'Posting-level review of mapped repairs, improvements, depreciation, and manual classifications.'::VARCHAR,
	    'period'::VARCHAR, 'Panama residential property'::VARCHAR,
	    'panama_residential_property'::VARCHAR)
    ) AS reports(
	report_order, report_id, title, description, parameter_kind,
	report_group, profile_kind
    );

CREATE OR REPLACE VIEW panama_report_columns AS
    SELECT *
    FROM (VALUES
	('panama-income-tax'::VARCHAR, 1, 'item'::VARCHAR, 'Computation item'::VARCHAR, 'left'::VARCHAR, 'text'::VARCHAR, FALSE),
	('panama-income-tax', 2, 'accounting_amount', 'Accounting amount', 'right', 'number', FALSE),
	('panama-income-tax', 3, 'taxable_effect', 'Taxable effect', 'right', 'number', FALSE),
	('panama-income-tax', 4, 'basis', 'Treatment / basis', 'left', 'text', FALSE),
	('panama-form-20', 1, 'third_party', 'Third party', 'left', 'text', FALSE),
	('panama-form-20', 2, 'tax_id', 'RUC / identifier', 'left', 'text', FALSE),
	('panama-form-20', 3, 'nature', 'Payment nature', 'left', 'text', FALSE),
	('panama-form-20', 4, 'payments', 'Payments', 'right', 'number', FALSE),
	('panama-form-20', 5, 'review', 'Review', 'left', 'text', FALSE),
	('panama-form-43-threshold', 1, 'metric', 'Metric', 'left', 'text', FALSE),
	('panama-form-43-threshold', 2, 'actual', 'Book amount', 'right', 'number', FALSE),
	('panama-form-43-threshold', 3, 'threshold', 'Policy threshold', 'right', 'number', FALSE),
	('panama-form-43-threshold', 4, 'result', 'Indicator', 'left', 'text', FALSE),
	('panama-dividend-tax', 1, 'declared', 'Declared', 'left', 'text', FALSE),
	('panama-dividend-tax', 2, 'recipient', 'Recipient', 'left', 'text', FALSE),
	('panama-dividend-tax', 3, 'source', 'Source', 'left', 'text', FALSE),
	('panama-dividend-tax', 4, 'gross', 'Gross distribution', 'right', 'number', FALSE),
	('panama-dividend-tax', 5, 'withheld', 'Dividend tax', 'right', 'number', FALSE),
	('panama-dividend-tax', 6, 'complementary', 'Complementary tax', 'right', 'number', FALSE),
	('panama-dividend-tax', 7, 'status', 'Status', 'left', 'text', FALSE),
	('panama-compliance-calendar', 1, 'obligation', 'Obligation', 'left', 'text', FALSE),
	('panama-compliance-calendar', 2, 'period', 'Period / basis', 'left', 'text', FALSE),
	('panama-compliance-calendar', 3, 'due', 'Due', 'left', 'text', FALSE),
	('panama-compliance-calendar', 4, 'completed', 'Completed', 'left', 'text', FALSE),
	('panama-compliance-calendar', 5, 'status', 'Status', 'left', 'text', FALSE),
	('panama-rent-roll', 1, 'property', 'Property', 'left', 'text', FALSE),
	('panama-rent-roll', 2, 'unit', 'Unit', 'left', 'text', FALSE),
	('panama-rent-roll', 3, 'tenant', 'Tenant', 'left', 'text', FALSE),
	('panama-rent-roll', 4, 'term', 'Lease term', 'left', 'text', FALSE),
	('panama-rent-roll', 5, 'monthly_rent', 'Monthly rent', 'right', 'number', FALSE),
	('panama-rent-roll', 6, 'tax', 'ITBMS treatment', 'left', 'text', FALSE),
	('panama-rent-roll', 7, 'deposit', 'Deposit', 'right', 'number', FALSE),
	('panama-rent-roll', 8, 'status', 'Status', 'left', 'text', FALSE),
	('panama-property-profit-loss', 1, 'property', 'Property', 'left', 'text', FALSE),
	('panama-property-profit-loss', 2, 'rent', 'Rent income', 'right', 'number', FALSE),
	('panama-property-profit-loss', 3, 'repairs', 'Repairs', 'right', 'number', FALSE),
	('panama-property-profit-loss', 4, 'other_costs', 'Other costs', 'right', 'number', FALSE),
	('panama-property-profit-loss', 5, 'capital', 'Capital additions', 'right', 'number', FALSE),
	('panama-property-profit-loss', 6, 'net', 'Net before tax', 'right', 'number', FALSE),
	('panama-itbms', 1, 'treatment', 'Treatment', 'left', 'text', FALSE),
	('panama-itbms', 2, 'rate', 'Rate', 'right', 'percent', FALSE),
	('panama-itbms', 3, 'taxable_base', 'Taxable base', 'right', 'number', FALSE),
	('panama-itbms', 4, 'tax', 'Computed ITBMS', 'right', 'number', FALSE),
	('panama-itbms', 5, 'basis', 'Basis / control', 'left', 'text', FALSE),
	('panama-property-tax', 1, 'property', 'Property', 'left', 'text', FALSE),
	('panama-property-tax', 2, 'tax_year', 'Tax year', 'left', 'text', FALSE),
	('panama-property-tax', 3, 'taxable_value', 'Taxable value', 'right', 'number', FALSE),
	('panama-property-tax', 4, 'assessed_tax', 'Assessed tax', 'right', 'number', FALSE),
	('panama-property-tax', 5, 'due', 'Due', 'left', 'text', FALSE),
	('panama-property-tax', 6, 'paid', 'Paid', 'right', 'number', FALSE),
	('panama-property-tax', 7, 'status', 'Status', 'left', 'text', FALSE),
	('panama-repair-capital', 1, 'date', 'Date', 'left', 'text', FALSE),
	('panama-repair-capital', 2, 'property', 'Property', 'left', 'text', FALSE),
	('panama-repair-capital', 3, 'account', 'Account', 'left', 'text', FALSE),
	('panama-repair-capital', 4, 'description', 'Description', 'left', 'text', FALSE),
	('panama-repair-capital', 5, 'amount', 'Amount', 'right', 'number', FALSE),
	('panama-repair-capital', 6, 'treatment', 'Treatment', 'left', 'text', FALSE),
	('panama-repair-capital', 7, 'review', 'Review', 'left', 'text', FALSE)
    ) AS columns(
	report_id, column_order, column_id, label, alignment, value_format,
	tree_column
    );

CREATE OR REPLACE FUNCTION njord.panama_report_validation_messages(
    p_report_id VARCHAR,
    p_book_id VARCHAR,
    p_start DATE,
    p_end DATE
)
RETURNS VARCHAR[]
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    messages VARCHAR[] := ARRAY[]::VARCHAR[];
    requires_property BOOLEAN := p_report_id IN (
	'panama-rent-roll', 'panama-property-profit-loss',
	'panama-property-tax', 'panama-repair-capital'
    );
BEGIN
    IF NOT EXISTS (
	SELECT 1 FROM panama_business_profiles WHERE book_id = p_book_id
    ) THEN
	RETURN ARRAY[
	    'Configure the Panama business profile on the Book page before opening this working paper.'
	]::VARCHAR[];
    END IF;

    IF requires_property AND NOT EXISTS (
	SELECT 1 FROM panama_residential_property_profiles
	WHERE book_id = p_book_id
    ) THEN
	messages := array_append(
	    messages,
	    'Enable the residential-property extension before opening this working paper.'
	);
    END IF;

    IF p_report_id IN (
	'panama-income-tax', 'panama-form-43-threshold', 'panama-itbms',
	'panama-compliance-calendar'
    ) AND NOT EXISTS (
	SELECT 1
	FROM panama_fiscal_periods AS period
	WHERE period.book_id = p_book_id
	  AND period.period_start <= COALESCE(p_end, CURRENT_DATE)
	  AND period.period_end >= COALESCE(p_start, p_end, CURRENT_DATE)
    ) THEN
	messages := array_append(
	    messages,
	    'No configured Panama fiscal period covers the selected dates.'
	);
    END IF;

    IF p_report_id = 'panama-income-tax' AND EXISTS (
	SELECT 1
	FROM report_postings AS posting
	WHERE posting.book_id = p_book_id
	  AND posting.account_type IN ('I', 'E')
	  AND posting.transaction_date::DATE
	      BETWEEN COALESCE(p_start, '-infinity'::DATE)
		  AND COALESCE(p_end, 'infinity'::DATE)
	  AND NOT EXISTS (
	      SELECT 1 FROM panama_account_income_tax_mappings AS mapping
	      WHERE mapping.book_id = posting.book_id
		AND mapping.acct = posting.account_id
	  )
    ) THEN
	messages := array_append(
	    messages,
	    'Unmapped income or expense postings are shown as review rows and excluded from the tax subtotal.'
	);
    END IF;

    IF p_report_id = 'panama-itbms' AND EXISTS (
	SELECT 1
	FROM report_postings AS posting
	WHERE posting.book_id = p_book_id
	  AND posting.account_type IN ('I', 'E')
	  AND posting.transaction_date::DATE
	      BETWEEN COALESCE(p_start, '-infinity'::DATE)
		  AND COALESCE(p_end, 'infinity'::DATE)
	  AND NOT EXISTS (
	      SELECT 1 FROM panama_account_itbms_mappings AS mapping
	      WHERE mapping.book_id = posting.book_id
		AND mapping.acct = posting.account_id
	  )
    ) THEN
	messages := array_append(
	    messages,
	    'Unmapped income or expense postings are excluded from the ITBMS summary.'
	);
    END IF;

    RETURN messages;
END;
$$;

-- One normalized row source feeds the generic report renderer.  Calculated
-- values are deliberately labelled as working-paper figures: the authoritative
-- facts remain the ledger and the configuration tables above.
CREATE OR REPLACE FUNCTION panama_report_rows(
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
    IF NOT EXISTS (
	SELECT 1 FROM panama_business_profiles WHERE book_id = b
    ) THEN
	RETURN;
    END IF;

    IF requested_report IN (
	'panama-rent-roll', 'panama-property-profit-loss',
	'panama-property-tax', 'panama-repair-capital'
    ) AND NOT EXISTS (
	SELECT 1 FROM panama_residential_property_profiles WHERE book_id = b
    ) THEN
	RETURN;
    END IF;

    IF requested_report = 'panama-income-tax' THEN
	RETURN QUERY
	WITH mapped AS (
	    SELECT
		posting.account_id AS id,
		posting.account_name AS name,
		posting.account_type AS type,
		treatment.label AS treatment_label,
		treatment.effect,
		mapping.inclusion_percent,
		njord.sum_if_complete(
		    CASE posting.account_type
			WHEN 'I' THEN -posting.reporting_amount
			ELSE posting.reporting_amount
		    END
		) AS accounting_amount
	    FROM panama_account_income_tax_mappings AS mapping
	    JOIN panama_income_tax_treatments AS treatment
	      ON treatment.id = mapping.treatment_id
	    JOIN report_postings AS posting
	      ON posting.book_id = mapping.book_id
	     AND posting.account_id = mapping.acct
	    WHERE mapping.book_id = b
	      AND posting.transaction_date BETWEEN start_date AND end_date
	    GROUP BY posting.account_id, posting.account_name,
		posting.account_type, treatment.label,
		treatment.effect, mapping.inclusion_percent
	),
	valued AS (
	    SELECT mapped.*,
		CASE mapped.effect
		    WHEN 'taxable_income' THEN mapped.accounting_amount * mapped.inclusion_percent
		    WHEN 'deductible_expense' THEN -mapped.accounting_amount * mapped.inclusion_percent
		    WHEN 'foreign_source_exempt' THEN 0
		    WHEN 'non_deductible_expense' THEN 0
		    WHEN 'excluded' THEN 0
		    ELSE NULL
		END::NUMERIC AS taxable_effect
	    FROM mapped
	),
	policy AS (
	    SELECT tax_policy.*
	    FROM panama_fiscal_periods AS period
	    JOIN panama_tax_policies AS tax_policy ON tax_policy.id = period.tax_policy_id
	    WHERE period.book_id = b
	      AND period.period_start <= end_date::DATE
	      AND period.period_end >= start_date::DATE
	    ORDER BY period.period_end DESC
	    LIMIT 1
	),
	summary AS (
	    SELECT
		njord.sum_if_complete(
		    CASE valued.type WHEN 'I' THEN valued.accounting_amount
				     ELSE -valued.accounting_amount END
		) FILTER (WHERE valued.type IN ('I', 'E')) AS accounting_profit,
		njord.sum_if_complete(
		    CASE WHEN valued.accounting_amount IS NULL THEN NULL
			 ELSE COALESCE(valued.taxable_effect, 0) END
		) AS mapped_taxable_result
	    FROM valued
	),
	unmapped AS (
	    SELECT
		posting.account_id AS id,
		posting.account_name AS name,
		njord.sum_if_complete(
		    CASE posting.account_type
			WHEN 'I' THEN -posting.reporting_amount
			ELSE posting.reporting_amount
		    END
		) AS amount
	    FROM report_postings AS posting
	    WHERE posting.book_id = b
	      AND posting.account_type IN ('I', 'E')
	      AND posting.transaction_date BETWEEN start_date AND end_date
	      AND NOT EXISTS (
		SELECT 1 FROM panama_account_income_tax_mappings AS mapping
		WHERE mapping.book_id = posting.book_id
		  AND mapping.acct = posting.account_id
	      )
	    GROUP BY posting.account_id, posting.account_name, posting.account_type
	)
	SELECT
	    row_number() OVER (ORDER BY valued.name, valued.id)::BIGINT,
	    ('account:' || valued.id)::VARCHAR,
	    njord.report_payload(
		CASE WHEN valued.taxable_effect IS NULL THEN 'warning' ELSE 'account' END,
		valued.id,
		jsonb_build_array(
		    njord.report_text_cell('item', valued.name),
		    njord.report_number_cell('accounting_amount', round(valued.accounting_amount, 2)),
		    njord.report_number_cell('taxable_effect', round(valued.taxable_effect, 2)),
		    njord.report_text_cell(
			'basis', valued.treatment_label
			|| ' · ' || round(valued.inclusion_percent * 100, 2) || '%'
		    )
		)
	    )
	FROM valued
	UNION ALL
	SELECT
	    rows.order_no::BIGINT,
	    rows.id::VARCHAR,
	    njord.report_payload(
		rows.kind, rows.id,
		jsonb_build_array(
		    njord.report_text_cell('item', rows.label),
		    njord.report_number_cell('accounting_amount', round(rows.accounting_amount, 2)),
		    njord.report_number_cell('taxable_effect', round(rows.taxable_effect, 2)),
		    njord.report_text_cell('basis', rows.basis)
		)
	    )
	FROM summary
	LEFT JOIN policy ON TRUE
	CROSS JOIN LATERAL (VALUES
	    (800, 'accounting-profit'::VARCHAR, 'Accounting profit from mapped accounts'::VARCHAR,
		summary.accounting_profit, NULL::NUMERIC,
		'Mapped ledger subtotal'::VARCHAR, 'total'::VARCHAR),
	    (810, 'taxable-result', 'Mapped taxable result', NULL,
		summary.mapped_taxable_result,
		'Working-paper subtotal before losses, incentives, credits, and manual adjustments', 'grand_total'),
	    (820, 'indicative-tax', 'Indicative tax at configured policy rate', NULL,
		greatest(summary.mapped_taxable_result, 0) * policy.corporate_income_tax_rate,
		CASE WHEN policy.id IS NULL THEN 'No covering tax policy'
		ELSE policy.label || ' · not a filed return' END,
		CASE WHEN policy.id IS NULL THEN 'warning' ELSE 'total' END)
	) AS rows(order_no, id, label, accounting_amount, taxable_effect, basis, kind)
	UNION ALL
	SELECT
	    900000 + row_number() OVER (ORDER BY unmapped.name, unmapped.id),
	    ('unmapped:' || unmapped.id)::VARCHAR,
	    njord.report_payload(
		'warning', unmapped.id,
		jsonb_build_array(
		    njord.report_text_cell('item', 'Unmapped: ' || unmapped.name),
		    njord.report_number_cell('accounting_amount', round(unmapped.amount, 2)),
		    njord.report_number_cell('taxable_effect', NULL),
		    njord.report_text_cell('basis', 'Review and map; excluded from subtotal')
		)
	    )
	FROM unmapped;
    ELSIF requested_report = 'panama-form-20' THEN
	RETURN QUERY
	WITH payments AS (
	    SELECT
		party.id AS party_id,
		party.name AS party_name,
		panama_party.taxpayer_id,
		panama_party.verification_digit,
		category.id AS category_id,
		category.label AS category_label,
		category.form_20_code,
		njord.sum_if_complete(-posting.reporting_amount) AS amount
	    FROM panama_reportable_payments AS tagged
	    JOIN panama_third_parties AS panama_party
	      ON panama_party.book_id = tagged.book_id
	     AND panama_party.party_id = tagged.party_id
	    JOIN trade_parties AS party
	      ON party.book_id = panama_party.book_id AND party.id = panama_party.party_id
	    JOIN panama_payment_categories AS category ON category.id = tagged.payment_category
	    JOIN report_postings AS posting
	      ON posting.book_id = tagged.book_id
	     AND posting.xid = tagged.xid
	     AND posting.account_id = tagged.acct
	    WHERE tagged.book_id = b
	      AND panama_party.form_20_reportable
	      AND posting.transaction_date BETWEEN start_date AND end_date
	    GROUP BY party.id, party.name, panama_party.taxpayer_id,
		panama_party.verification_digit, category.id, category.label,
		category.form_20_code
	)
	SELECT
	    row_number() OVER (ORDER BY payments.party_name, payments.category_label)::BIGINT,
	    (payments.party_id || ':' || payments.category_id)::VARCHAR,
	    njord.report_payload(
		CASE WHEN payments.taxpayer_id IS NULL OR payments.form_20_code IS NULL
		    THEN 'warning' ELSE 'account' END,
		payments.party_id,
		jsonb_build_array(
		    njord.report_text_cell('third_party', payments.party_name),
		    njord.report_text_cell(
			'tax_id',
			concat_ws('-', payments.taxpayer_id, payments.verification_digit)
		    ),
		    njord.report_text_cell('nature', payments.category_label),
		    njord.report_number_cell('payments', round(payments.amount, 2)),
		    njord.report_text_cell(
			'review',
			CASE
			    WHEN payments.taxpayer_id IS NULL THEN 'Missing taxpayer identifier'
			    WHEN payments.form_20_code IS NULL THEN 'Form code not configured — review'
			    ELSE 'Recorded facts'
			END
		    )
		)
	    )
	FROM payments;
    ELSIF requested_report = 'panama-form-43-threshold' THEN
	RETURN QUERY
	WITH period_policy AS (
	    SELECT policy.*
	    FROM panama_fiscal_periods AS period
	    JOIN panama_tax_policies AS policy ON policy.id = period.tax_policy_id
	    WHERE period.book_id = b
	      AND period.period_start <= end_date::DATE
	      AND period.period_end >= start_date::DATE
	    ORDER BY period.period_end DESC
	    LIMIT 1
	),
	profile AS (
	    SELECT * FROM panama_business_profiles WHERE book_id = b
	),
	revenue AS (
	    SELECT njord.sum_if_complete(-posting.reporting_amount) AS amount
	    FROM report_postings AS posting
	    WHERE posting.book_id = b AND posting.account_type = 'I'
	      AND posting.transaction_date BETWEEN start_date AND end_date
	),
	assets AS (
	    -- Assets are a stock: accumulate each native balance first, then
	    -- translate it once at the report date.  Summing transaction-date
	    -- conversions would turn exchange-rate history into a fictitious gain.
	    SELECT njord.sum_if_complete(balance.report_value) AS amount
	    FROM njord.account_balances_at(b, end_date) AS balance
	    WHERE balance.account_type = 'A'
	),
	metrics AS (
	    SELECT
		values.order_no,
		values.id,
		values.label,
		values.actual,
		values.threshold,
		profile.form_43_override
	    FROM revenue CROSS JOIN assets CROSS JOIN period_policy CROSS JOIN profile
	    CROSS JOIN LATERAL (VALUES
		(1, 'gross-revenue'::VARCHAR, 'Gross ledger revenue'::VARCHAR,
		    revenue.amount, period_policy.form_43_revenue_threshold),
		(2, 'total-assets', 'Ledger asset balance',
		    assets.amount, period_policy.form_43_asset_threshold)
	    ) AS values(order_no, id, label, actual, threshold)
	)
	SELECT
	    metrics.order_no::BIGINT,
	    metrics.id::VARCHAR,
	    njord.report_payload(
		CASE WHEN metrics.actual IS NULL THEN 'warning' ELSE 'account' END,
		metrics.id,
		jsonb_build_array(
		    njord.report_text_cell('metric', metrics.label),
		    njord.report_number_cell('actual', round(metrics.actual, 2)),
		    njord.report_number_cell('threshold', round(metrics.threshold, 2)),
		    njord.report_text_cell(
			'result',
			CASE
			    WHEN metrics.form_43_override IS TRUE THEN 'Profile says include — review'
			    WHEN metrics.form_43_override IS FALSE THEN 'Profile says exclude — review'
			    WHEN metrics.actual IS NULL THEN 'Unavailable: missing valuation'
			    WHEN metrics.actual >= metrics.threshold THEN 'Configured threshold reached — review'
			    ELSE 'Below configured threshold'
			END
		    )
		)
	    )
	FROM metrics;
    ELSIF requested_report = 'panama-dividend-tax' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (ORDER BY distribution.declared_on, distribution.id)::BIGINT,
	    distribution.id::VARCHAR,
	    njord.report_payload(
		CASE WHEN distribution.withholding_paid_on IS NULL
		     AND (distribution.withholding_tax + distribution.complementary_tax) > 0
		    THEN 'warning' ELSE 'account' END,
		distribution.id,
		jsonb_build_array(
		    njord.report_text_cell('declared', distribution.declared_on::VARCHAR),
		    njord.report_text_cell('recipient', distribution.recipient_name),
		    njord.report_text_cell('source', source.label),
		    njord.report_number_cell('gross', round(distribution.gross_dividend, 2)),
		    njord.report_number_cell('withheld', round(distribution.withholding_tax, 2)),
		    njord.report_number_cell('complementary', round(distribution.complementary_tax, 2)),
		    njord.report_text_cell(
			'status',
			CASE
			    WHEN distribution.withholding_paid_on IS NOT NULL
				THEN 'Tax recorded paid ' || distribution.withholding_paid_on
			    WHEN distribution.withholding_tax + distribution.complementary_tax > 0
				THEN 'Payment date not recorded'
			    ELSE 'No tax amount recorded'
			END
		    )
		)
	    )
	FROM panama_dividend_distributions AS distribution
	JOIN panama_dividend_sources AS source ON source.id = distribution.source
	WHERE distribution.book_id = b
	  AND distribution.declared_on BETWEEN start_date::DATE AND end_date::DATE;
    ELSIF requested_report = 'panama-compliance-calendar' THEN
	RETURN QUERY
	WITH selected_period AS (
	    SELECT *
	    FROM panama_fiscal_periods AS period
	    WHERE period.book_id = b
	      AND period.period_start <= end_date::DATE
	      AND period.period_end >= start_date::DATE
	    ORDER BY period.period_end DESC
	    LIMIT 1
	),
	items AS (
	    SELECT values.*
	    FROM selected_period AS period
	    CROSS JOIN LATERAL (VALUES
		(10, 'income-tax-return'::VARCHAR, 'Corporate income-tax return'::VARCHAR,
		    period.id::VARCHAR, period.income_tax_return_due_on,
		    period.income_tax_return_filed_on,
		    'Configured fiscal-period dates'::VARCHAR),
		(20, 'municipal-return', 'Municipal annual return',
		    period.id, period.municipal_return_due_on,
		    period.municipal_return_filed_on,
		    'Configured fiscal-period dates'),
		(30, 'form-43-through', 'Form 43 recorded through',
		    period.id, NULL::DATE, period.form_43_filed_through,
		    'Recorded coverage date; review applicability')
	    ) AS values(order_no, id, obligation, period_label, due_on, completed_on, basis)
	    UNION ALL
	    SELECT
		100 + installment.installment_number,
		('estimated-tax-' || installment.installment_number)::VARCHAR,
		('Estimated tax instalment ' || installment.installment_number)::VARCHAR,
		installment.period_id::VARCHAR,
		installment.due_on,
		installment.paid_on,
		('Scheduled ' || round(installment.amount, 2)
		 || '; recorded paid ' || COALESCE(round(installment.amount_paid, 2)::VARCHAR, '0'))::VARCHAR
	    FROM panama_estimated_tax_installments AS installment
	    JOIN selected_period AS period
	      ON period.book_id = installment.book_id AND period.id = installment.period_id
	)
	SELECT
	    items.order_no::BIGINT,
	    items.id::VARCHAR,
	    njord.report_payload(
		CASE
		WHEN items.due_on IS NOT NULL AND items.completed_on IS NULL
		 AND items.due_on < CURRENT_DATE THEN 'warning'
		ELSE 'account'
		END,
		items.id,
		jsonb_build_array(
		    njord.report_text_cell('obligation', items.obligation),
		    njord.report_text_cell('period', items.period_label),
		    njord.report_text_cell('due', items.due_on::VARCHAR),
		    njord.report_text_cell('completed', items.completed_on::VARCHAR),
		    njord.report_text_cell(
			'status',
			CASE
			    WHEN items.completed_on IS NOT NULL THEN 'Recorded complete · ' || items.basis
			    WHEN items.due_on IS NULL THEN items.basis
			    WHEN items.due_on < CURRENT_DATE THEN 'Past configured due date · review'
			    ELSE 'Open · ' || items.basis
			END
		    )
		)
	    )
	FROM items;
    ELSIF requested_report = 'panama-itbms' THEN
	RETURN QUERY
	WITH period_policy AS (
	    SELECT policy.*
	    FROM panama_fiscal_periods AS period
	    JOIN panama_tax_policies AS policy ON policy.id = period.tax_policy_id
	    WHERE period.book_id = b
	      AND period.period_start <= end_date::DATE
	      AND period.period_end >= start_date::DATE
	    ORDER BY period.period_end DESC
	    LIMIT 1
	),
	mapped AS (
	    SELECT
		treatment.id,
		treatment.label,
		treatment.transaction_role,
		treatment.rate_kind,
		treatment.recoverable_percent,
		CASE treatment.rate_kind
		    WHEN 'standard' THEN policy.standard_itbms_rate
		    WHEN 'lodging' THEN policy.lodging_itbms_rate
		    ELSE 0
		END::NUMERIC AS rate,
		njord.sum_if_complete(
		    CASE posting.account_type
			WHEN 'I' THEN -posting.reporting_amount
			ELSE posting.reporting_amount
		    END
		) AS taxable_base
	    FROM panama_account_itbms_mappings AS mapping
	    JOIN panama_itbms_treatments AS treatment
	      ON treatment.id = mapping.treatment_id
	     AND treatment.transaction_role = mapping.transaction_role
	    JOIN report_postings AS posting
	      ON posting.book_id = mapping.book_id
	     AND posting.account_id = mapping.acct
	    CROSS JOIN period_policy AS policy
	    WHERE mapping.book_id = b
	      AND posting.transaction_date BETWEEN start_date AND end_date
	    GROUP BY treatment.id, treatment.label, treatment.transaction_role,
		treatment.rate_kind, treatment.recoverable_percent,
		policy.standard_itbms_rate, policy.lodging_itbms_rate
	),
	valued AS (
	    SELECT mapped.*,
		CASE mapped.transaction_role
		    WHEN 'sale' THEN mapped.taxable_base * mapped.rate
		    ELSE -mapped.taxable_base * mapped.rate * mapped.recoverable_percent
		END::NUMERIC AS net_tax
	    FROM mapped
	),
	control AS (
	    SELECT njord.sum_if_complete(-posting.reporting_amount)
		FILTER (WHERE posting.xid IS NOT NULL) AS movement
	    FROM panama_business_control_accounts AS controls
	    LEFT JOIN report_postings AS posting
	      ON posting.book_id = controls.book_id
	     AND posting.account_id IN (
		controls.itbms_payable_acct, controls.itbms_receivable_acct
	     )
	     AND posting.transaction_date BETWEEN start_date AND end_date
	    WHERE controls.book_id = b
	),
	summary AS (
	    SELECT njord.sum_if_complete(valued.net_tax) AS mapped_tax FROM valued
	)
	SELECT
	    row_number() OVER (ORDER BY valued.transaction_role DESC, valued.label)::BIGINT,
	    valued.id::VARCHAR,
	    njord.report_payload(
		CASE WHEN valued.net_tax IS NULL THEN 'warning' ELSE 'account' END,
		valued.id,
		jsonb_build_array(
		    njord.report_text_cell('treatment', valued.label),
		    njord.report_number_cell('rate', valued.rate * 100, '%'),
		    njord.report_number_cell('taxable_base', round(valued.taxable_base, 2)),
		    njord.report_number_cell('tax', round(valued.net_tax, 2)),
		    njord.report_text_cell(
			'basis',
			CASE valued.transaction_role WHEN 'sale' THEN 'Output'
			ELSE 'Recoverable input at ' || round(valued.recoverable_percent * 100, 2) || '%' END
		    )
		)
	    )
	FROM valued
	UNION ALL
	SELECT
	    rows.order_no::BIGINT,
	    rows.id::VARCHAR,
	    njord.report_payload(
		rows.kind,
		rows.id,
		jsonb_build_array(
		    njord.report_text_cell('treatment', rows.label),
		    njord.report_number_cell('rate', NULL),
		    njord.report_number_cell('taxable_base', NULL),
		    njord.report_number_cell('tax', round(rows.amount, 2)),
		    njord.report_text_cell('basis', rows.basis)
		)
	    )
	FROM summary CROSS JOIN control
	CROSS JOIN LATERAL (VALUES
	    (800, 'mapped-net'::VARCHAR, 'Mapped net ITBMS'::VARCHAR,
		summary.mapped_tax, 'Calculated from mapped ledger activity'::VARCHAR, 'total'::VARCHAR),
	    (810, 'control-movement', 'ITBMS control-account movement',
		control.movement, 'Recorded ledger controls', 'total'),
	    (820, 'control-difference', 'Difference',
		control.movement - summary.mapped_tax, 'Control movement less mapped amount · review',
		CASE WHEN control.movement - summary.mapped_tax = 0 THEN 'grand_total' ELSE 'warning' END)
	) AS rows(order_no, id, label, amount, basis, kind);
    ELSIF requested_report = 'panama-rent-roll' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (ORDER BY property.name, unit.name, lease.starts_on)::BIGINT,
	    lease.id::VARCHAR,
	    njord.report_payload(
		CASE WHEN lease.contract_registered_on IS NULL
		     OR (lease.security_deposit > 0 AND lease.deposit_consigned_on IS NULL)
		    THEN 'warning' ELSE 'account' END,
		lease.id,
		jsonb_build_array(
		    njord.report_text_cell('property', property.name),
		    njord.report_text_cell('unit', unit.name),
		    njord.report_text_cell('tenant', tenant.name),
		    njord.report_text_cell(
			'term',
			lease.starts_on || ' to ' || COALESCE(lease.ends_on::VARCHAR, 'open-ended')
		    ),
		    njord.report_number_cell('monthly_rent', round(lease.monthly_rent, 2)),
		    njord.report_text_cell('tax', tax_treatment.label),
		    njord.report_number_cell('deposit', round(lease.security_deposit, 2)),
		    njord.report_text_cell(
			'status', concat_ws(' · ',
			    'Active',
			    CASE WHEN lease.contract_registered_on IS NULL
				THEN 'Registration not recorded'
				ELSE 'Registered ' || lease.contract_registered_on END,
			    CASE
				WHEN lease.security_deposit = 0 THEN 'No deposit recorded'
				WHEN lease.deposit_consigned_on IS NULL THEN 'Deposit consignment not recorded'
				ELSE 'Deposit consigned ' || lease.deposit_consigned_on
			    END
			))
		)
	    )
	FROM panama_leases AS lease
	JOIN panama_properties AS property
	  ON property.book_id = lease.book_id AND property.id = lease.property_id
	JOIN panama_property_units AS unit
	  ON unit.book_id = lease.book_id AND unit.property_id = lease.property_id
	 AND unit.id = lease.unit_id
	JOIN panama_tenants AS tenant
	  ON tenant.book_id = lease.book_id AND tenant.id = lease.tenant_id
	JOIN panama_lease_tax_treatments AS tax_treatment
	  ON tax_treatment.id = lease.tax_treatment
	WHERE lease.book_id = b
	  AND lease.starts_on <= as_of_date::DATE
	  AND (lease.ends_on IS NULL OR lease.ends_on >= as_of_date::DATE);
    ELSIF requested_report = 'panama-property-profit-loss' THEN
	RETURN QUERY
	WITH rent AS (
	    SELECT property.id AS property_id,
		njord.sum_if_complete(-posting.reporting_amount)
		    FILTER (WHERE posting.xid IS NOT NULL) AS amount
	    FROM panama_properties AS property
	    LEFT JOIN report_postings AS posting
	      ON posting.book_id = property.book_id
	     AND posting.account_id = property.rent_income_acct
	     AND posting.transaction_date BETWEEN start_date AND end_date
	    WHERE property.book_id = b
	    GROUP BY property.id
	),
	expenses AS (
	    SELECT mapping.property_id,
		njord.sum_if_complete(CASE
		    WHEN posting.reporting_rate IS NULL THEN NULL
		    WHEN treatment.accounting_effect = 'deductible_repair'
			THEN posting.reporting_amount
		    ELSE 0
		END) AS repairs,
		njord.sum_if_complete(CASE
		    WHEN posting.reporting_rate IS NULL THEN NULL
		    WHEN treatment.accounting_effect NOT IN (
			'deductible_repair', 'capital_improvement'
		    ) THEN posting.reporting_amount
		    ELSE 0
		END) AS other_costs,
		njord.sum_if_complete(CASE
		    WHEN posting.reporting_rate IS NULL THEN NULL
		    WHEN treatment.accounting_effect = 'capital_improvement'
			THEN posting.reporting_amount
		    ELSE 0
		END) AS capital
	    FROM panama_account_property_expense_mappings AS mapping
	    JOIN panama_property_expense_treatments AS treatment
	      ON treatment.id = mapping.treatment_id
	    JOIN report_postings AS posting
	      ON posting.book_id = mapping.book_id
	     AND posting.account_id = mapping.acct
	    WHERE mapping.book_id = b
	      AND posting.transaction_date BETWEEN start_date AND end_date
	    GROUP BY mapping.property_id
	)
	SELECT
	    row_number() OVER (ORDER BY property.name, property.id)::BIGINT,
	    property.id::VARCHAR,
	    njord.report_payload(
		CASE WHEN rent.amount IS NULL OR expenses.repairs IS NULL
		    THEN 'warning' ELSE 'account' END,
		property.id,
		jsonb_build_array(
		    njord.report_text_cell('property', property.name),
		    njord.report_number_cell('rent', round(rent.amount, 2)),
		    njord.report_number_cell('repairs', round(
			CASE WHEN expenses.property_id IS NULL THEN 0
			     ELSE expenses.repairs END, 2
		    )),
		    njord.report_number_cell('other_costs', round(
			CASE WHEN expenses.property_id IS NULL THEN 0
			     ELSE expenses.other_costs END, 2
		    )),
		    njord.report_number_cell('capital', round(
			CASE WHEN expenses.property_id IS NULL THEN 0
			     ELSE expenses.capital END, 2
		    )),
		    njord.report_number_cell(
			'net',
			round(
			    rent.amount
			    - CASE WHEN expenses.property_id IS NULL THEN 0
				   ELSE expenses.repairs END
			    - CASE WHEN expenses.property_id IS NULL THEN 0
				   ELSE expenses.other_costs END,
			    2
			)
		    )
		)
	    )
	FROM panama_properties AS property
	LEFT JOIN rent ON rent.property_id = property.id
	LEFT JOIN expenses ON expenses.property_id = property.id
	WHERE property.book_id = b;
    ELSIF requested_report = 'panama-property-tax' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (
		ORDER BY installment.due_on, property.name, installment.installment_number
	    )::BIGINT,
	    (property.id || ':' || assessment.tax_year || ':' || installment.installment_number)::VARCHAR,
	    njord.report_payload(
		CASE WHEN installment.paid_on IS NULL AND installment.due_on < CURRENT_DATE
		    THEN 'warning' ELSE 'account' END,
		property.id,
		jsonb_build_array(
		    njord.report_text_cell('property', property.name),
		    njord.report_text_cell('tax_year', assessment.tax_year::VARCHAR),
		    njord.report_number_cell('taxable_value', round(assessment.taxable_value, 2)),
		    njord.report_number_cell('assessed_tax', round(assessment.annual_tax, 2)),
		    njord.report_text_cell('due', installment.due_on::VARCHAR),
		    njord.report_number_cell('paid', round(installment.amount_paid, 2)),
		    njord.report_text_cell(
			'status',
			CASE
			    WHEN installment.paid_on IS NOT NULL THEN 'Recorded paid ' || installment.paid_on
			    WHEN installment.due_on < CURRENT_DATE THEN 'Past configured due date · review'
			    ELSE 'Open · configured instalment ' || round(installment.amount, 2)
			END
		    )
		)
	    )
	FROM panama_property_tax_assessments AS assessment
	JOIN panama_properties AS property
	  ON property.book_id = assessment.book_id AND property.id = assessment.property_id
	JOIN panama_property_tax_installments AS installment
	  ON installment.book_id = assessment.book_id
	 AND installment.property_id = assessment.property_id
	 AND installment.tax_year = assessment.tax_year
	WHERE assessment.book_id = b
	  AND installment.due_on BETWEEN start_date::DATE AND end_date::DATE;
    ELSIF requested_report = 'panama-repair-capital' THEN
	RETURN QUERY
	SELECT
	    row_number() OVER (
		ORDER BY posting.transaction_date, posting.posting_id
	    )::BIGINT,
	    ('posting:' || posting.posting_id)::VARCHAR,
	    njord.report_payload(
		CASE WHEN treatment.accounting_effect = 'manual_review'
		    THEN 'warning' ELSE 'account' END,
		mapping.acct,
		jsonb_build_array(
		    njord.report_text_cell(
			'date', posting.transaction_date::DATE::VARCHAR
		    ),
		    njord.report_text_cell('property', property.name),
		    njord.report_text_cell('account', posting.account_name),
		    njord.report_text_cell(
			'description',
			COALESCE(posting.posting_comment, posting.transaction_comment)
		    ),
		    njord.report_number_cell(
			'amount',
			round(posting.reporting_amount, 2)
		    ),
		    njord.report_text_cell('treatment', treatment.label),
		    njord.report_text_cell(
			'review',
			CASE treatment.accounting_effect
			    WHEN 'deductible_repair' THEN 'Recorded repair classification'
			    WHEN 'capital_improvement' THEN 'Capital addition; review asset/depreciation schedule'
			    WHEN 'depreciation' THEN 'Recorded depreciation classification'
			    WHEN 'manual_review' THEN 'Manual classification required'
			    ELSE 'Recorded property cost classification'
			END
		    )
		)
	    )
	FROM panama_account_property_expense_mappings AS mapping
	JOIN panama_property_expense_treatments AS treatment
	  ON treatment.id = mapping.treatment_id
	JOIN panama_properties AS property
	  ON property.book_id = mapping.book_id AND property.id = mapping.property_id
	JOIN report_postings AS posting
	  ON posting.book_id = mapping.book_id
	 AND posting.account_id = mapping.acct
	WHERE mapping.book_id = b
	  AND posting.transaction_date BETWEEN start_date AND end_date;
    END IF;
END;
$$;

COMMENT ON FUNCTION panama_report_rows(VARCHAR, VARCHAR, TIMESTAMP, TIMESTAMP, TIMESTAMP) IS
    'Normalized Panama business and residential-property fact summaries for the generic SQL-defined report renderer; never a filing submission.';
