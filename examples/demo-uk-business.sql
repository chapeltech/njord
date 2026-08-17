-- A richly populated UK limited-company book for the browser demo and report
-- tests.  The company is deliberately inside the first supported preparation
-- envelope: standalone private micro-entity, FRS 105, GBP, standard invoice
-- VAT accounting.  Nothing in this seed claims to be a filed return.

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('uk-business', 'Acacia Digital Ltd', 'GBP', 'company');

INSERT INTO uk_company_profiles (
    book_id, legal_name, company_number, legal_form, accounting_framework,
    utr, vat_registration_number, vat_scheme, registered_office,
    incorporated_on, notes
) VALUES (
    'uk-business', 'Acacia Digital Ltd', '12345678',
    'private_limited_shares', 'frs105', '1234567890', 'GB123456789',
    'standard_invoice', '12 Acacia Avenue, London, N1 1AA', '2025-12-01',
    'Illustrative development company. Preparation reports are not filed returns.'
);

INSERT INTO uk_accounting_periods (
    book_id, id, period_start, period_end, status, accounts_due_on,
    corporation_tax_due_on, notes
) VALUES (
    'uk-business', '2026', '2026-01-01', '2026-12-31', 'open',
    '2027-09-30', '2027-10-01',
    'First illustrative full-year reporting period.'
);

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('uk-business', 'Assets', 'Assets', 'A', 'GBP', NULL, 'root', TRUE),
    ('uk-business', 'Liabilities', 'Liabilities', 'L', 'GBP', NULL, 'root', TRUE),
    ('uk-business', 'Equity', 'Equity', 'Q', 'GBP', NULL, 'root', TRUE),
    ('uk-business', 'Income', 'Income', 'I', 'GBP', NULL, 'root', TRUE),
    ('uk-business', 'Expenses', 'Expenses', 'E', 'GBP', NULL, 'root', TRUE),

    ('uk-business', 'Current Assets', 'Current Assets', 'A', 'GBP',
        'Assets', 'group', TRUE),
    ('uk-business', 'Business Bank', 'Business Bank', 'A', 'GBP',
        'Current Assets', 'bank', FALSE),
    ('uk-business', 'Trade Debtors', 'Trade Debtors', 'A', 'GBP',
        'Current Assets', 'posting', FALSE),
    ('uk-business', 'Fixed Assets', 'Fixed Assets', 'A', 'GBP',
        'Assets', 'group', TRUE),
    ('uk-business', 'Computer Equipment', 'Computer Equipment', 'A', 'GBP',
        'Fixed Assets', 'fixed_asset', FALSE),
    ('uk-business', 'Accumulated Depreciation', 'Accumulated Depreciation', 'A', 'GBP',
        'Fixed Assets', 'fixed_asset', FALSE),

    ('uk-business', 'Current Liabilities', 'Current Liabilities', 'L', 'GBP',
        'Liabilities', 'group', TRUE),
    ('uk-business', 'Trade Creditors', 'Trade Creditors', 'L', 'GBP',
        'Current Liabilities', 'posting', FALSE),
    ('uk-business', 'VAT Control', 'VAT Control', 'L', 'GBP',
        'Current Liabilities', 'posting', FALSE),
    ('uk-business', 'Corporation Tax Payable', 'Corporation Tax Payable', 'L', 'GBP',
        'Current Liabilities', 'posting', FALSE),
    ('uk-business', 'PAYE and NIC', 'PAYE and NIC', 'L', 'GBP',
        'Current Liabilities', 'posting', FALSE),
    ('uk-business', 'Director Loan Account', 'Director Loan Account', 'L', 'GBP',
        'Current Liabilities', 'director_loan', FALSE),

    ('uk-business', 'Share Capital', 'Share Capital', 'Q', 'GBP',
        'Equity', 'posting', FALSE),
    ('uk-business', 'Retained Earnings', 'Retained Earnings', 'Q', 'GBP',
        'Equity', 'posting', FALSE),

    ('uk-business', 'Turnover', 'Turnover', 'I', 'GBP',
        'Income', 'group', TRUE),
    ('uk-business', 'Consultancy Revenue', 'Consultancy Revenue', 'I', 'GBP',
        'Turnover', 'posting', FALSE),
    ('uk-business', 'Product Revenue', 'Product Revenue', 'I', 'GBP',
        'Turnover', 'posting', FALSE),
    ('uk-business', 'Other Income', 'Other Income', 'I', 'GBP',
        'Income', 'group', TRUE),
    ('uk-business', 'Bank Interest', 'Bank Interest', 'I', 'GBP',
        'Other Income', 'posting', FALSE),

    ('uk-business', 'Cost of Sales', 'Cost of Sales', 'E', 'GBP',
        'Expenses', 'group', TRUE),
    ('uk-business', 'Subcontractors', 'Subcontractors', 'E', 'GBP',
        'Cost of Sales', 'posting', FALSE),
    ('uk-business', 'Hosting', 'Hosting', 'E', 'GBP',
        'Cost of Sales', 'posting', FALSE),
    ('uk-business', 'Administrative Expenses', 'Administrative Expenses', 'E', 'GBP',
        'Expenses', 'group', TRUE),
    ('uk-business', 'Salaries', 'Salaries', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Software Subscriptions', 'Software Subscriptions', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Office Costs', 'Office Costs', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Professional Fees', 'Professional Fees', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Travel', 'Travel', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Client Entertainment', 'Client Entertainment', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Blocked Input VAT', 'Blocked Input VAT', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Depreciation', 'Depreciation', 'E', 'GBP',
        'Administrative Expenses', 'posting', FALSE),
    ('uk-business', 'Finance Costs', 'Finance Costs', 'E', 'GBP',
        'Expenses', 'group', TRUE),
    ('uk-business', 'Bank Charges', 'Bank Charges', 'E', 'GBP',
        'Finance Costs', 'posting', FALSE),
    ('uk-business', 'Tax Expense', 'Tax Expense', 'E', 'GBP',
        'Expenses', 'group', TRUE),
    ('uk-business', 'Corporation Tax Expense', 'Corporation Tax Expense', 'E', 'GBP',
        'Tax Expense', 'posting', FALSE);

INSERT INTO cash_accounts (book_id, acct)
VALUES ('uk-business', 'Business Bank');

INSERT INTO uk_company_control_accounts (book_id, vat_control_acct)
VALUES ('uk-business', 'VAT Control');

-- Explicit statutory mappings are independent of the display hierarchy.
INSERT INTO uk_account_statutory_mappings (book_id, acct, line_id) VALUES
    ('uk-business', 'Business Bank', 'cash_at_bank_and_in_hand'),
    ('uk-business', 'Trade Debtors', 'debtors'),
    ('uk-business', 'Computer Equipment', 'tangible_assets'),
    ('uk-business', 'Accumulated Depreciation', 'tangible_assets'),
    ('uk-business', 'Trade Creditors', 'creditors_due_within_one_year'),
    ('uk-business', 'VAT Control', 'creditors_due_within_one_year'),
    ('uk-business', 'Corporation Tax Payable', 'creditors_due_within_one_year'),
    ('uk-business', 'PAYE and NIC', 'creditors_due_within_one_year'),
    ('uk-business', 'Director Loan Account', 'creditors_due_within_one_year'),
    ('uk-business', 'Share Capital', 'called_up_share_capital'),
    ('uk-business', 'Retained Earnings', 'profit_and_loss_account'),
    ('uk-business', 'Consultancy Revenue', 'turnover'),
    ('uk-business', 'Product Revenue', 'turnover'),
    ('uk-business', 'Bank Interest', 'interest_receivable'),
    ('uk-business', 'Subcontractors', 'cost_of_sales'),
    ('uk-business', 'Hosting', 'cost_of_sales'),
    ('uk-business', 'Salaries', 'administrative_expenses'),
    ('uk-business', 'Software Subscriptions', 'administrative_expenses'),
    ('uk-business', 'Office Costs', 'administrative_expenses'),
    ('uk-business', 'Professional Fees', 'administrative_expenses'),
    ('uk-business', 'Travel', 'administrative_expenses'),
    ('uk-business', 'Client Entertainment', 'administrative_expenses'),
    ('uk-business', 'Blocked Input VAT', 'administrative_expenses'),
    ('uk-business', 'Depreciation', 'administrative_expenses'),
    ('uk-business', 'Bank Charges', 'interest_payable'),
    ('uk-business', 'Corporation Tax Expense', 'tax_on_profit');

INSERT INTO uk_account_corporation_tax_mappings (
    book_id, acct, treatment_id, inclusion_percent
) VALUES
    ('uk-business', 'Consultancy Revenue', 'trading_income', 1),
    ('uk-business', 'Product Revenue', 'trading_income', 1),
    ('uk-business', 'Bank Interest', 'other_taxable_income', 1),
    ('uk-business', 'Subcontractors', 'allowable_expense', 1),
    ('uk-business', 'Hosting', 'allowable_expense', 1),
    ('uk-business', 'Salaries', 'allowable_expense', 1),
    ('uk-business', 'Software Subscriptions', 'allowable_expense', 1),
    ('uk-business', 'Office Costs', 'allowable_expense', 1),
    ('uk-business', 'Professional Fees', 'allowable_expense', 1),
    ('uk-business', 'Travel', 'allowable_expense', 1),
    ('uk-business', 'Client Entertainment', 'disallowable_expense', 1),
    ('uk-business', 'Blocked Input VAT', 'disallowable_expense', 1),
    ('uk-business', 'Depreciation', 'disallowable_expense', 1),
    ('uk-business', 'Bank Charges', 'allowable_expense', 1),
    ('uk-business', 'Corporation Tax Expense', 'accounts_tax_charge', 1),
    ('uk-business', 'Computer Equipment', 'capital_allowance_pool', 1);

-- VAT mappings fail closed: every revenue, expense, and purchased fixed-asset
-- account used by this demo has an explicit behaviour.
INSERT INTO uk_account_vat_mappings (
    book_id, acct, transaction_role, behaviour_id
) VALUES
    ('uk-business', 'Consultancy Revenue', 'sale', 'sale_standard'),
    ('uk-business', 'Product Revenue', 'sale', 'sale_standard'),
    ('uk-business', 'Bank Interest', 'sale', 'sale_exempt'),
    ('uk-business', 'Subcontractors', 'purchase', 'purchase_standard'),
    ('uk-business', 'Hosting', 'purchase', 'purchase_standard'),
    ('uk-business', 'Salaries', 'purchase', 'purchase_outside_scope'),
    ('uk-business', 'Software Subscriptions', 'purchase', 'purchase_standard'),
    ('uk-business', 'Office Costs', 'purchase', 'purchase_standard'),
    ('uk-business', 'Professional Fees', 'purchase', 'purchase_standard'),
    ('uk-business', 'Travel', 'purchase', 'purchase_outside_scope'),
    ('uk-business', 'Client Entertainment', 'purchase', 'purchase_blocked'),
    ('uk-business', 'Blocked Input VAT', 'purchase', 'purchase_outside_scope'),
    ('uk-business', 'Depreciation', 'purchase', 'purchase_outside_scope'),
    ('uk-business', 'Bank Charges', 'purchase', 'purchase_outside_scope'),
    ('uk-business', 'Corporation Tax Expense', 'purchase', 'purchase_outside_scope'),
    ('uk-business', 'Computer Equipment', 'purchase', 'purchase_standard'),
    ('uk-business', 'Accumulated Depreciation', 'purchase', 'purchase_outside_scope');

INSERT INTO trade_parties (
    book_id, id, name, is_customer, is_supplier, default_terms_days
) VALUES
    ('uk-business', 'alpha', 'Alpha Design Co', TRUE, FALSE, 30),
    ('uk-business', 'beta', 'Beta Retail Ltd', TRUE, FALSE, 30),
    ('uk-business', 'cloud', 'Cloud Host UK Ltd', FALSE, TRUE, 30),
    ('uk-business', 'freelancer', 'Freelance Studio Ltd', FALSE, TRUE, 30),
    ('uk-business', 'accountant', 'Numbers & Co LLP', FALSE, TRUE, 30),
    ('uk-business', 'hardware', 'Computer Warehouse Ltd', FALSE, TRUE, 30),
    ('uk-business', 'software', 'Software Tools UK Ltd', FALSE, TRUE, 30);

DO $$
DECLARE
    sale_1 INTEGER;
    sale_2 INTEGER;
    sale_3 INTEGER;
    sale_4 INTEGER;
    receipt_1 INTEGER;
    receipt_2 INTEGER;
    receipt_3 INTEGER;
    purchase_1 INTEGER;
    purchase_2 INTEGER;
    purchase_3 INTEGER;
    purchase_4 INTEGER;
    purchase_5 INTEGER;
    payment_1 INTEGER;
    payment_2 INTEGER;
    payment_4 INTEGER;
    seed_xid INTEGER;
    salary_date DATE;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-01-01', 'Ordinary share capital issued')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Business Bank', 100),
        ('uk-business', seed_xid, 'Share Capital', -100);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-01-02', 'Director working-capital loan')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Business Bank', 8000),
        ('uk-business', seed_xid, 'Director Loan Account', -8000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-01-15', 'Alpha Design Co - INV-1001')
    RETURNING xid INTO sale_1;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', sale_1, 'Trade Debtors', 6000, 'INV-1001'),
        ('uk-business', sale_1, 'Consultancy Revenue', -5000, NULL),
        ('uk-business', sale_1, 'VAT Control', -1000, NULL);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-02-10', 'Beta Retail Ltd - INV-1002')
    RETURNING xid INTO sale_2;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', sale_2, 'Trade Debtors', 4320, 'INV-1002'),
        ('uk-business', sale_2, 'Consultancy Revenue', -3600, NULL),
        ('uk-business', sale_2, 'VAT Control', -720, NULL);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-03-20', 'Beta Retail Ltd - INV-1003')
    RETURNING xid INTO sale_3;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', sale_3, 'Trade Debtors', 3000, 'INV-1003'),
        ('uk-business', sale_3, 'Product Revenue', -2500, NULL),
        ('uk-business', sale_3, 'VAT Control', -500, NULL);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-05-05', 'Alpha Design Co - INV-1004')
    RETURNING xid INTO sale_4;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', sale_4, 'Trade Debtors', 5040, 'INV-1004'),
        ('uk-business', sale_4, 'Consultancy Revenue', -4200, NULL),
        ('uk-business', sale_4, 'VAT Control', -840, NULL);

    INSERT INTO trade_invoices (
        book_id, id, party_id, direction, invoice_number, issued_on, due_on,
        xid, control_acct
    ) VALUES
        ('uk-business', 'sale-1001', 'alpha', 'receivable', 'INV-1001',
            '2026-01-15', '2026-02-14', sale_1, 'Trade Debtors'),
        ('uk-business', 'sale-1002', 'beta', 'receivable', 'INV-1002',
            '2026-02-10', '2026-03-12', sale_2, 'Trade Debtors'),
        ('uk-business', 'sale-1003', 'beta', 'receivable', 'INV-1003',
            '2026-03-20', '2026-04-19', sale_3, 'Trade Debtors'),
        ('uk-business', 'sale-1004', 'alpha', 'receivable', 'INV-1004',
            '2026-05-05', '2026-06-04', sale_4, 'Trade Debtors');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-02-12', 'Alpha Design Co receipt - INV-1001')
    RETURNING xid INTO receipt_1;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', receipt_1, 'Business Bank', 6000),
        ('uk-business', receipt_1, 'Trade Debtors', -6000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-03-05', 'Beta Retail Ltd part receipt - INV-1002')
    RETURNING xid INTO receipt_2;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', receipt_2, 'Business Bank', 3000),
        ('uk-business', receipt_2, 'Trade Debtors', -3000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-04-15', 'Beta Retail Ltd receipt - INV-1003')
    RETURNING xid INTO receipt_3;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', receipt_3, 'Business Bank', 3000),
        ('uk-business', receipt_3, 'Trade Debtors', -3000);

    INSERT INTO trade_invoice_allocations (
        book_id, invoice_id, payment_xid, control_acct, amount
    ) VALUES
        ('uk-business', 'sale-1001', receipt_1, 'Trade Debtors', 6000),
        ('uk-business', 'sale-1002', receipt_2, 'Trade Debtors', 3000),
        ('uk-business', 'sale-1003', receipt_3, 'Trade Debtors', 3000);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-01-25', 'Freelance Studio Ltd - SUB-301')
    RETURNING xid INTO purchase_1;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', purchase_1, 'Subcontractors', 1600, NULL),
        ('uk-business', purchase_1, 'VAT Control', 320, NULL),
        ('uk-business', purchase_1, 'Trade Creditors', -1920, 'SUB-301');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-02-18', 'Software Tools UK Ltd - SOFT-88')
    RETURNING xid INTO purchase_2;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', purchase_2, 'Software Subscriptions', 240, NULL),
        ('uk-business', purchase_2, 'VAT Control', 48, NULL),
        ('uk-business', purchase_2, 'Trade Creditors', -288, 'SOFT-88');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-03-22', 'Numbers & Co LLP - ACC-2026')
    RETURNING xid INTO purchase_3;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', purchase_3, 'Professional Fees', 800, NULL),
        ('uk-business', purchase_3, 'VAT Control', 160, NULL),
        ('uk-business', purchase_3, 'Trade Creditors', -960, 'ACC-2026');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-04-02', 'Cloud Host UK Ltd - CLOUD-404')
    RETURNING xid INTO purchase_4;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', purchase_4, 'Hosting', 300, NULL),
        ('uk-business', purchase_4, 'VAT Control', 60, NULL),
        ('uk-business', purchase_4, 'Trade Creditors', -360, 'CLOUD-404');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-05-19', 'Computer Warehouse Ltd - HW-501')
    RETURNING xid INTO purchase_5;
    INSERT INTO xaction_bits (book_id, xid, acct, amt, comment) VALUES
        ('uk-business', purchase_5, 'Computer Equipment', 1500, NULL),
        ('uk-business', purchase_5, 'VAT Control', 300, NULL),
        ('uk-business', purchase_5, 'Trade Creditors', -1800, 'HW-501');

    INSERT INTO trade_invoices (
        book_id, id, party_id, direction, invoice_number, issued_on, due_on,
        xid, control_acct
    ) VALUES
        ('uk-business', 'purchase-301', 'freelancer', 'payable', 'SUB-301',
            '2026-01-25', '2026-02-24', purchase_1, 'Trade Creditors'),
        ('uk-business', 'purchase-88', 'software', 'payable', 'SOFT-88',
            '2026-02-18', '2026-03-20', purchase_2, 'Trade Creditors'),
        ('uk-business', 'purchase-2026', 'accountant', 'payable', 'ACC-2026',
            '2026-03-22', '2026-04-21', purchase_3, 'Trade Creditors'),
        ('uk-business', 'purchase-404', 'cloud', 'payable', 'CLOUD-404',
            '2026-04-02', '2026-05-02', purchase_4, 'Trade Creditors'),
        ('uk-business', 'purchase-501', 'hardware', 'payable', 'HW-501',
            '2026-05-19', '2026-06-18', purchase_5, 'Trade Creditors');

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-02-20', 'Paid SUB-301')
    RETURNING xid INTO payment_1;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', payment_1, 'Trade Creditors', 1920),
        ('uk-business', payment_1, 'Business Bank', -1920);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-03-18', 'Paid SOFT-88')
    RETURNING xid INTO payment_2;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', payment_2, 'Trade Creditors', 288),
        ('uk-business', payment_2, 'Business Bank', -288);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-04-25', 'Paid CLOUD-404')
    RETURNING xid INTO payment_4;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', payment_4, 'Trade Creditors', 360),
        ('uk-business', payment_4, 'Business Bank', -360);

    INSERT INTO trade_invoice_allocations (
        book_id, invoice_id, payment_xid, control_acct, amount
    ) VALUES
        ('uk-business', 'purchase-301', payment_1, 'Trade Creditors', 1920),
        ('uk-business', 'purchase-88', payment_2, 'Trade Creditors', 288),
        ('uk-business', 'purchase-404', payment_4, 'Trade Creditors', 360);

    FOREACH salary_date IN ARRAY ARRAY[
        '2026-01-31'::DATE, '2026-02-28'::DATE, '2026-03-31'::DATE,
        '2026-04-30'::DATE, '2026-05-31'::DATE, '2026-06-30'::DATE,
        '2026-07-31'::DATE
    ] LOOP
        INSERT INTO xactions (book_id, date, comment)
        VALUES (
            'uk-business', salary_date,
            'Monthly payroll - ' || to_char(salary_date, 'Mon YYYY')
        ) RETURNING xid INTO seed_xid;
        INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
            ('uk-business', seed_xid, 'Salaries', 1200),
            ('uk-business', seed_xid, 'Business Bank', -1200);
    END LOOP;

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-05-12', 'Office supplies')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Office Costs', 400),
        ('uk-business', seed_xid, 'VAT Control', 80),
        ('uk-business', seed_xid, 'Business Bank', -480);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-06-08', 'UK rail travel')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Travel', 240),
        ('uk-business', seed_xid, 'Business Bank', -240);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-06-20', 'Client entertaining - VAT blocked')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Client Entertainment', 500),
        ('uk-business', seed_xid, 'Blocked Input VAT', 100),
        ('uk-business', seed_xid, 'Business Bank', -600);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-07-15', 'Bank charges to date')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Bank Charges', 75),
        ('uk-business', seed_xid, 'Business Bank', -75);

    INSERT INTO xactions (book_id, date, comment)
    VALUES ('uk-business', '2026-07-31', 'Laptop depreciation to date')
    RETURNING xid INTO seed_xid;
    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
        ('uk-business', seed_xid, 'Depreciation', 250),
        ('uk-business', seed_xid, 'Accumulated Depreciation', -250);
END;
$$;

COMMENT ON TABLE uk_company_profiles IS
    'Optional UK company identity and preparation-policy configuration. Presence enables the UK preparation-report library; it does not imply filing capability.';
