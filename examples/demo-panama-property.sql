-- A richly populated Panamanian residential-property company for the browser
-- demo and report tests.  The tax and compliance surfaces are working papers,
-- not filing artefacts or substitutes for review by a Panamanian accountant.

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('panama-property', 'Bahia Verde Rentals, S.A.', 'PAB', 'company');

INSERT INTO panama_business_profiles (
    book_id, legal_name, ruc, verification_digit, legal_form, municipality,
    default_tax_policy_id, incorporated_on, resident_agent,
    registered_address, operations_notice_number, itbms_registered,
    conducts_lodging_activity, notes
) VALUES (
    'panama-property', 'Bahia Verde Rentals, S.A.', '155742345-2-2025', '81',
    'corporation', 'panama_district', 'current_2026', '2025-05-12',
    'Isthmus Corporate Services',
    'Calle 50, Torre Bahia, Piso 8, Panama, Republic of Panama',
    'AV-2025-18421', TRUE, FALSE,
    'Illustrative development company. Review every working paper before filing.'
);

INSERT INTO panama_fiscal_periods (
    book_id, id, period_start, period_end, status, tax_policy_id,
    income_tax_return_due_on, municipal_return_due_on, notes
) VALUES (
    'panama-property', '2026', '2026-01-01', '2026-12-31', 'open',
    'current_2026', '2027-03-31', '2027-03-31',
    'Illustrative calendar-year fiscal period.'
);

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('panama-property', 'Assets', 'Assets', 'A', 'PAB', NULL, 'root', TRUE),
    ('panama-property', 'Liabilities', 'Liabilities', 'L', 'PAB', NULL, 'root', TRUE),
    ('panama-property', 'Equity', 'Equity', 'Q', 'PAB', NULL, 'root', TRUE),
    ('panama-property', 'Income', 'Income', 'I', 'PAB', NULL, 'root', TRUE),
    ('panama-property', 'Expenses', 'Expenses', 'E', 'PAB', NULL, 'root', TRUE),

    ('panama-property', 'Current Assets', 'Current Assets', 'A', 'PAB',
        'Assets', 'group', TRUE),
    ('panama-property', 'Operating Bank', 'Operating Bank', 'A', 'PAB',
        'Current Assets', 'bank', FALSE),
    ('panama-property', 'Rent Receivable', 'Rent Receivable', 'A', 'PAB',
        'Current Assets', 'posting', FALSE),
    ('panama-property', 'ITBMS Receivable', 'ITBMS Receivable', 'A', 'PAB',
        'Current Assets', 'posting', FALSE),
    ('panama-property', 'Income Tax Prepayments', 'Income Tax Prepayments', 'A', 'PAB',
        'Current Assets', 'posting', FALSE),
    ('panama-property', 'Rental Property', 'Rental Property', 'A', 'PAB',
        'Assets', 'group', TRUE),
    ('panama-property', 'Marina Vista Land', 'Marina Vista - Land', 'A', 'PAB',
        'Rental Property', 'fixed_asset', FALSE),
    ('panama-property', 'Marina Vista Building', 'Marina Vista - Building', 'A', 'PAB',
        'Rental Property', 'fixed_asset', FALSE),
    ('panama-property', 'Marina Vista Improvements', 'Marina Vista - Improvements', 'A', 'PAB',
        'Rental Property', 'fixed_asset', FALSE),
    ('panama-property', 'Marina Vista Accumulated Depreciation',
        'Marina Vista - Accumulated Depreciation', 'A', 'PAB',
        'Rental Property', 'fixed_asset', FALSE),

    ('panama-property', 'Current Liabilities', 'Current Liabilities', 'L', 'PAB',
        'Liabilities', 'group', TRUE),
    ('panama-property', 'ITBMS Payable', 'ITBMS Payable', 'L', 'PAB',
        'Current Liabilities', 'posting', FALSE),
    ('panama-property', 'Income Tax Payable', 'Income Tax Payable', 'L', 'PAB',
        'Current Liabilities', 'posting', FALSE),
    ('panama-property', 'Dividend Withholding Payable', 'Dividend Withholding Payable', 'L', 'PAB',
        'Current Liabilities', 'posting', FALSE),
    ('panama-property', 'Tenant Deposits Held', 'Tenant Deposits Held', 'L', 'PAB',
        'Current Liabilities', 'posting', FALSE),
    ('panama-property', 'Mortgage Payable', 'Mortgage Payable', 'L', 'PAB',
        'Liabilities', 'loan', FALSE),

    ('panama-property', 'Share Capital', 'Share Capital', 'Q', 'PAB',
        'Equity', 'posting', FALSE),
    ('panama-property', 'Dividend Distributions', 'Dividend Distributions', 'Q', 'PAB',
        'Equity', 'posting', FALSE),

    ('panama-property', 'Rental Income', 'Rental Income', 'I', 'PAB',
        'Income', 'group', TRUE),
    ('panama-property', 'Residential Rent', 'Residential Rent', 'I', 'PAB',
        'Rental Income', 'posting', FALSE),
    ('panama-property', 'Other Property Income', 'Other Property Income', 'I', 'PAB',
        'Rental Income', 'posting', FALSE),

    ('panama-property', 'Property Operating Expenses', 'Property Operating Expenses', 'E', 'PAB',
        'Expenses', 'group', TRUE),
    ('panama-property', 'Repairs and Maintenance', 'Repairs and Maintenance', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Nonrecoverable ITBMS', 'Nonrecoverable ITBMS', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Property Management', 'Property Management', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'PH Common Charges', 'PH Common Charges', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Property Insurance', 'Property Insurance', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Property Utilities', 'Property Utilities', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Property Tax', 'Property Tax', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Municipal Tax', 'Municipal Tax', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Depreciation', 'Depreciation', 'E', 'PAB',
        'Property Operating Expenses', 'posting', FALSE),
    ('panama-property', 'Professional Fees', 'Professional Fees', 'E', 'PAB',
        'Expenses', 'posting', FALSE),
    ('panama-property', 'Bank Charges', 'Bank Charges', 'E', 'PAB',
        'Expenses', 'posting', FALSE);

INSERT INTO cash_accounts (book_id, acct)
VALUES ('panama-property', 'Operating Bank');

INSERT INTO panama_business_control_accounts (
    book_id, itbms_payable_acct, itbms_receivable_acct,
    income_tax_payable_acct
) VALUES (
    'panama-property', 'ITBMS Payable', 'ITBMS Receivable',
    'Income Tax Payable'
);

INSERT INTO panama_account_income_tax_mappings (
    book_id, acct, treatment_id, inclusion_percent
) VALUES
    ('panama-property', 'Residential Rent', 'taxable_income', 1),
    ('panama-property', 'Other Property Income', 'taxable_income', 1),
    ('panama-property', 'Repairs and Maintenance', 'deductible_expense', 1),
    ('panama-property', 'Nonrecoverable ITBMS', 'deductible_expense', 1),
    ('panama-property', 'Property Management', 'deductible_expense', 1),
    ('panama-property', 'PH Common Charges', 'deductible_expense', 1),
    ('panama-property', 'Property Insurance', 'deductible_expense', 1),
    ('panama-property', 'Property Utilities', 'deductible_expense', 1),
    ('panama-property', 'Property Tax', 'deductible_expense', 1),
    ('panama-property', 'Municipal Tax', 'deductible_expense', 1),
    ('panama-property', 'Depreciation', 'deductible_expense', 1),
    ('panama-property', 'Professional Fees', 'deductible_expense', 1),
    ('panama-property', 'Bank Charges', 'deductible_expense', 1),
    ('panama-property', 'Marina Vista Improvements', 'capital_or_depreciation', 1);

INSERT INTO panama_account_itbms_mappings (
    book_id, acct, transaction_role, treatment_id
) VALUES
    ('panama-property', 'Residential Rent', 'sale', 'sale_standard'),
    ('panama-property', 'Other Property Income', 'sale', 'sale_out_of_scope'),
    ('panama-property', 'Repairs and Maintenance', 'purchase', 'purchase_nonrecoverable'),
    ('panama-property', 'Property Management', 'purchase', 'purchase_recoverable'),
    ('panama-property', 'Marina Vista Improvements', 'purchase', 'purchase_nonrecoverable'),
    ('panama-property', 'Property Insurance', 'purchase', 'purchase_exempt'),
    ('panama-property', 'PH Common Charges', 'purchase', 'purchase_out_of_scope'),
    ('panama-property', 'Property Utilities', 'purchase', 'purchase_nonrecoverable');

INSERT INTO panama_residential_property_profiles (
    book_id, enabled_on, tenant_deposit_control_acct, notes
) VALUES (
    'panama-property', '2026-01-01', 'Tenant Deposits Held',
    'Security deposits are tracked by lease and consignment status; the liability account is available for amounts temporarily held.'
);

INSERT INTO panama_properties (
    book_id, id, name, property_use, finca_number, municipality, address,
    acquired_on, land_acct, building_acct, improvements_acct,
    accumulated_depreciation_acct, rent_income_acct, notes
) VALUES (
    'panama-property', 'marina-vista', 'Marina Vista Apartments', 'mixed_use',
    '30123456', 'panama_district',
    'Avenida Balboa, PH Marina Vista, Panama', '2025-12-15',
    'Marina Vista Land', 'Marina Vista Building',
    'Marina Vista Improvements', 'Marina Vista Accumulated Depreciation',
    'Residential Rent',
    'Two long-term homes and one short-term residential unit demonstrate both exempt and taxable lease treatment.'
);

INSERT INTO panama_property_units (
    book_id, property_id, id, name, bedrooms, floor_area_square_metres
) VALUES
    ('panama-property', 'marina-vista', '8A', 'Apartment 8A', 2, 91.5),
    ('panama-property', 'marina-vista', '9B', 'Apartment 9B', 3, 122.0),
    ('panama-property', 'marina-vista', '10C', 'Apartment 10C', 1, 62.0);

INSERT INTO trade_parties (
    book_id, id, name, is_customer, is_supplier, default_terms_days
) VALUES
    ('panama-property', 'tenant-rojas', 'Lucia Rojas', TRUE, FALSE, 0),
    ('panama-property', 'tenant-chen', 'Daniel Chen', TRUE, FALSE, 0),
    ('panama-property', 'tenant-walker', 'Emma Walker', TRUE, FALSE, 0),
    ('panama-property', 'property-manager', 'Gestion Istmena, S.A.', FALSE, TRUE, 15),
    ('panama-property', 'plumber', 'Servicios Hidraulicos Rivera', FALSE, TRUE, 15),
    ('panama-property', 'builder', 'Mejoras del Pacifico, S.A.', FALSE, TRUE, 30),
    ('panama-property', 'accountant', 'Contadores del Istmo, S.A.', FALSE, TRUE, 30);

INSERT INTO panama_tenants (
    book_id, id, name, taxpayer_id, trade_party_id, email
) VALUES
    ('panama-property', 'rojas', 'Lucia Rojas', '8-812-441', 'tenant-rojas', 'lucia.rojas@example.test'),
    ('panama-property', 'chen', 'Daniel Chen', 'E-8-142201', 'tenant-chen', 'daniel.chen@example.test'),
    ('panama-property', 'walker', 'Emma Walker', 'PE-144201', 'tenant-walker', 'emma.walker@example.test');

INSERT INTO panama_leases (
    book_id, id, property_id, unit_id, tenant_id, starts_on, ends_on,
    monthly_rent, tax_treatment, exclusive_residential_use,
    security_deposit, contract_registered_on, deposit_consigned_on, notes
) VALUES
    ('panama-property', 'lease-8a-2026', 'marina-vista', '8A', 'rojas',
        '2026-01-01', '2026-12-31', 1800,
        'residential_over_six_months_exempt', TRUE, 1800,
        '2026-01-05', '2026-01-05', 'Long-term residential lease.'),
    ('panama-property', 'lease-9b-2026', 'marina-vista', '9B', 'chen',
        '2026-02-01', NULL, 2200,
        'residential_over_six_months_exempt', TRUE, 2200,
        '2026-02-04', '2026-02-04', 'Open-ended long-term residential lease.'),
    ('panama-property', 'lease-10c-summer', 'marina-vista', '10C', 'walker',
        '2026-05-01', '2026-08-31', 1000,
        'standard_taxable', TRUE, 1000,
        '2026-05-03', '2026-05-03',
        'Four-month residential lease is not eligible for the over-six-month exemption.');

INSERT INTO panama_property_tax_assessments (
    book_id, property_id, tax_year, taxable_value, annual_tax,
    early_payment_discount_rate, reference, notes
) VALUES (
    'panama-property', 'marina-vista', 2026, 700000, 6300, 0.10,
    'FINCA-30123456-2026',
    'Illustrative assessment; verify cadastral value and exemptions with DGI.'
);

INSERT INTO panama_property_tax_installments (
    book_id, property_id, tax_year, installment_number, due_on, amount,
    paid_on, amount_paid, reference
) VALUES
    ('panama-property', 'marina-vista', 2026, 1, '2026-04-30', 2100,
        '2026-04-28', 2100, 'DGI-PT-001'),
    ('panama-property', 'marina-vista', 2026, 2, '2026-08-31', 2100,
        NULL, NULL, NULL),
    ('panama-property', 'marina-vista', 2026, 3, '2026-12-31', 2100,
        NULL, NULL, NULL);

INSERT INTO panama_estimated_tax_installments (
    book_id, period_id, installment_number, due_on, amount,
    paid_on, amount_paid, reference
) VALUES
    ('panama-property', '2026', 1, '2026-06-30', 3750,
        '2026-06-29', 3750, 'DGI-ISR-EST-1'),
    ('panama-property', '2026', 2, '2026-09-30', 3750,
        NULL, NULL, NULL),
    ('panama-property', '2026', 3, '2026-12-31', 3750,
        NULL, NULL, NULL);

INSERT INTO panama_account_property_expense_mappings (
    book_id, acct, property_id, treatment_id
) VALUES
    ('panama-property', 'Repairs and Maintenance', 'marina-vista', 'repairs'),
    ('panama-property', 'Marina Vista Improvements', 'marina-vista', 'capital_improvements'),
    ('panama-property', 'Depreciation', 'marina-vista', 'depreciation'),
    ('panama-property', 'Property Tax', 'marina-vista', 'property_tax'),
    ('panama-property', 'Municipal Tax', 'marina-vista', 'municipal_tax'),
    ('panama-property', 'Property Insurance', 'marina-vista', 'insurance'),
    ('panama-property', 'Property Utilities', 'marina-vista', 'utilities'),
    ('panama-property', 'Property Management', 'marina-vista', 'management'),
    ('panama-property', 'PH Common Charges', 'marina-vista', 'manual_review'),
    ('panama-property', 'Nonrecoverable ITBMS', 'marina-vista', 'manual_review');

INSERT INTO panama_third_parties (
    book_id, party_id, taxpayer_id, verification_digit, party_type,
    form_20_reportable
) VALUES
    ('panama-property', 'property-manager', '155660001-2-2024', '32', 'legal_entity', TRUE),
    ('panama-property', 'plumber', '8-771-991', '11', 'individual', TRUE),
    ('panama-property', 'builder', '155612344-2-2023', '75', 'legal_entity', TRUE),
    ('panama-property', 'accountant', '155698721-2-2020', '44', 'legal_entity', TRUE);

INSERT INTO account_valuations (book_id, acct, date, dst, value, comment) VALUES
    ('panama-property', 'Marina Vista Land', '2026-08-01', 'PAB', 240000,
        'Illustrative independent land allocation'),
    ('panama-property', 'Marina Vista Building', '2026-08-01', 'PAB', 560000,
        'Illustrative independent building estimate'),
    ('panama-property', 'Marina Vista Improvements', '2026-08-01', 'PAB', 30000,
        'Illustrative improvements estimate');

DO $$
DECLARE
    seed_xid INTEGER;
    manager_xid INTEGER;
    plumber_xid INTEGER;
    builder_xid INTEGER;
    accountant_xid INTEGER;
    dividend_xid INTEGER;
    rent_month INTEGER;
    rent_date DATE;
    rent_amount NUMERIC;
    itbms_amount NUMERIC;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-01-01', 'Opening property and financing')
    RETURNING xid INTO seed_xid;

    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('panama-property', seed_xid, 'Operating Bank', 90000, 'Initial working capital'),
        ('panama-property', seed_xid, 'Marina Vista Land', 220000, 'Allocated land cost'),
        ('panama-property', seed_xid, 'Marina Vista Building', 480000, 'Allocated building cost'),
        ('panama-property', seed_xid, 'Marina Vista Improvements', 20000, 'Existing improvements'),
        ('panama-property', seed_xid, 'Mortgage Payable', -500000, 'Acquisition mortgage'),
        ('panama-property', seed_xid, 'Share Capital', -310000, 'Subscribed capital');

    FOR rent_month IN 1..8 LOOP
        rent_date := make_date(2026, rent_month, 5);
        rent_amount := CASE
            WHEN rent_month = 1 THEN 1800
            WHEN rent_month <= 4 THEN 4000
            ELSE 5000
        END;
        itbms_amount := CASE WHEN rent_month >= 5 THEN 70 ELSE 0 END;

        INSERT INTO xactions (book_id, date, comment)
        VALUES (
            'panama-property', rent_date,
            to_char(rent_date, 'FMMonth YYYY') || ' rents'
        ) RETURNING xid INTO seed_xid;

        INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
            ('panama-property', seed_xid, 'Operating Bank',
                rent_amount + itbms_amount, 'Rent receipts'),
            ('panama-property', seed_xid, 'Residential Rent',
                -rent_amount, 'Lease income');

        IF itbms_amount <> 0 THEN
            INSERT INTO xaction_bits (book_id, xid, acct, amt, comment)
            VALUES ('panama-property', seed_xid, 'ITBMS Payable',
                -itbms_amount, '7% ITBMS on short lease');
        END IF;
    END LOOP;

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-02-12', 'Property management services')
    RETURNING xid INTO manager_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', manager_xid, 'Operating Bank', -535),
        ('panama-property', manager_xid, 'Property Management', 500),
        ('panama-property', manager_xid, 'ITBMS Receivable', 35);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-03-18', 'Emergency plumbing repair')
    RETURNING xid INTO plumber_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', plumber_xid, 'Operating Bank', -1337.50),
        ('panama-property', plumber_xid, 'Repairs and Maintenance', 1250),
        ('panama-property', plumber_xid, 'Nonrecoverable ITBMS', 87.50);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-07-14', 'Kitchen modernization - capital improvement')
    RETURNING xid INTO builder_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', builder_xid, 'Operating Bank', -12840),
        ('panama-property', builder_xid, 'Marina Vista Improvements', 12840);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-03-28', 'Annual accounting services')
    RETURNING xid INTO accountant_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', accountant_xid, 'Operating Bank', -1070),
        ('panama-property', accountant_xid, 'Professional Fees', 1000),
        ('panama-property', accountant_xid, 'ITBMS Receivable', 70);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-01-20', 'Annual property insurance')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Operating Bank', -2400),
        ('panama-property', seed_xid, 'Property Insurance', 2400);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-06-01', 'PH common charges January to June')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Operating Bank', -1800),
        ('panama-property', seed_xid, 'PH Common Charges', 1800);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-06-15', 'Property utilities')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Operating Bank', -600),
        ('panama-property', seed_xid, 'Property Utilities', 600);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-04-28', 'First property-tax installment')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Operating Bank', -2100),
        ('panama-property', seed_xid, 'Property Tax', 2100);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-05-30', 'Municipal tax installment')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Operating Bank', -500),
        ('panama-property', seed_xid, 'Municipal Tax', 500);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-06-29', 'First estimated income-tax installment')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Operating Bank', -3750),
        ('panama-property', seed_xid, 'Income Tax Prepayments', 3750);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-08-01', 'Depreciation through August')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', seed_xid, 'Depreciation', 8000),
        ('panama-property', seed_xid, 'Marina Vista Accumulated Depreciation', -8000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('panama-property', '2026-08-03', 'Panama-source dividend')
    RETURNING xid INTO dividend_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('panama-property', dividend_xid, 'Dividend Distributions', 10000),
        ('panama-property', dividend_xid, 'Operating Bank', -9000),
        ('panama-property', dividend_xid, 'Dividend Withholding Payable', -1000);

    INSERT INTO panama_reportable_payments (
        book_id, xid, acct, party_id, payment_category, document_reference
    ) VALUES
        ('panama-property', manager_xid, 'Operating Bank', 'property-manager',
            'services', 'GIS-2026-0212'),
        ('panama-property', plumber_xid, 'Operating Bank', 'plumber',
            'contractor', 'SHR-1842'),
        ('panama-property', builder_xid, 'Operating Bank', 'builder',
            'contractor', 'MP-2026-441'),
        ('panama-property', accountant_xid, 'Operating Bank', 'accountant',
            'professional_fees', 'CDI-2026-103');

    INSERT INTO panama_dividend_distributions (
        book_id, id, declared_on, paid_on, recipient_name,
        recipient_taxpayer_id, source, gross_dividend, withholding_tax,
        complementary_tax, withholding_paid_on, xid, notes
    ) VALUES (
        'panama-property', 'DIV-2026-01', '2026-08-01', '2026-08-03',
        'Bahia Verde Holdings Inc.', 'RUC-FOREIGN-001', 'panama_source',
        10000, 1000, 0, NULL, dividend_xid,
        'Form 07 remains due within ten days; payment is intentionally pending in the demo.'
    );
END;
$$;
