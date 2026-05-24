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
	SELECT count(*) = 3
	FROM accts
	WHERE book_id = 'personal'
	  AND id IN ('Opening Balance', 'Income', 'Expenses')
    )
);

SELECT pg_temp.assert_true(
    'business expense reference data is loaded',
    EXISTS (SELECT 1 FROM vat_codes WHERE id = 'UK_STANDARD_BLOCKED') AND
    EXISTS (SELECT 1 FROM expense_tax_treatments WHERE id = 'ALLOWABLE_REVENUE')
);

SELECT pg_temp.assert_true(
    'currency reference data is loaded',
    EXISTS (SELECT 1 FROM asset WHERE id = 'GBP') AND
    EXISTS (SELECT 1 FROM asset WHERE id = 'USD')
);

SELECT pg_temp.assert_true(
    'USD valuation to GBP is loaded',
    EXISTS (
	SELECT 1
	FROM current_valuations
	WHERE src = 'USD' AND round(rate, 5) = 0.81169
    )
);

INSERT INTO accts (book_id, id, type, atype)
VALUES ('personal', 'USD Expenses', 'E', 'USD');

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
    'full_ledger reports running balances',
    (
	SELECT runningtotal = 100.00
	FROM full_ledger
	WHERE book_id = 'personal'
	  AND acct = 'Broker USD'
	ORDER BY date DESC, xid DESC
	LIMIT 1
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
    'balance_sheet values assets in GBP',
    (
	SELECT posttax = 81.17
	FROM balance_sheet
	WHERE book_id = 'personal'
	  AND account = 'Broker USD'
    )
);

SELECT pg_temp.assert_true(
    'bsheet reports balances as of a date',
    (
	SELECT posttax = 81.17
	FROM bsheet('personal', '2026-01-31')
	WHERE account = 'Broker USD'
    )
);

SELECT pg_temp.assert_true(
    'balance_sheet_report values reporting-currency assets',
    (
	SELECT posttax = 50.00
	FROM balance_sheet_report
	WHERE book_id = 'personal'
	  AND section = 'Assets'
	  AND row_kind = 'account'
	  AND account = 'Current GBP'
    )
);

SELECT pg_temp.assert_true(
    'balance_sheet_report includes balance sheet totals',
    EXISTS (
	SELECT 1
	FROM balance_sheet_report
	WHERE book_id = 'personal'
	  AND row_kind = 'section_total'
	  AND account = 'Total Assets'
    ) AND EXISTS (
	SELECT 1
	FROM balance_sheet_report
	WHERE book_id = 'personal'
	  AND row_kind = 'grand_total'
	  AND account = 'Total Liabilities and Equity'
    )
);

SELECT pg_temp.assert_true(
    'bsheet_report reports as-of sections',
    EXISTS (
	SELECT 1
	FROM bsheet_report('personal', '2026-01-31')
	WHERE section = 'Assets'
	  AND row_kind = 'section_total'
	  AND account = 'Total Assets'
    )
);

CALL create_simple_xaction(
    'personal',
    '2026-01-20',
    'Current GBP',
    'Income',
    100.00
);

CALL create_simple_xaction(
    'personal',
    '2026-01-21',
    'Current GBP',
    'Expenses',
    -30.00
);

SELECT pg_temp.assert_true(
    'trial_balance_report exposes reporting-currency differences',
    (
	SELECT debit = 250.00 AND credit = 273.20
	FROM trial_balance_report
	WHERE book_id = 'personal'
	  AND row_kind = 'total'
	  AND account = 'Total'
    ) AND (
	SELECT debit = 23.20 AND credit IS NULL
	FROM trial_balance_report
	WHERE book_id = 'personal'
	  AND row_kind = 'difference'
	  AND account = 'Difference'
    )
);

SELECT pg_temp.assert_true(
    'tb_report reports as-of differences',
    (
	SELECT debit = 150.00 AND credit = 173.20
	FROM tb_report('personal', '2026-01-15')
	WHERE row_kind = 'total'
	  AND account = 'Total'
    ) AND (
	SELECT debit = 23.20 AND credit IS NULL
	FROM tb_report('personal', '2026-01-15')
	WHERE row_kind = 'difference'
	  AND account = 'Difference'
    )
);

INSERT INTO books (id, name, reporting_asset)
VALUES ('trial', 'Trial Balance Test', 'GBP');

INSERT INTO accts (book_id, id, type, atype)
VALUES
    ('trial', 'Opening Balance', 'Q', 'GBP'),
    ('trial', 'Income', 'I', 'GBP');

CALL open_account('trial', 'Cash', '2026-01-01', 'A', 'GBP', 100.00);

CALL create_simple_xaction(
    'trial',
    '2026-01-02',
    'Cash',
    'Income',
    50.00
);

SELECT pg_temp.assert_true(
    'trial_balance_report balances same-currency books',
    (
	SELECT debit = 150.00 AND credit = 150.00
	FROM trial_balance_report
	WHERE book_id = 'trial'
	  AND row_kind = 'total'
	  AND account = 'Total'
    ) AND NOT EXISTS (
	SELECT 1
	FROM trial_balance_report
	WHERE book_id = 'trial'
	  AND row_kind = 'difference'
    )
);

SELECT pg_temp.assert_true(
    'profit_loss_report includes income and expense totals',
    EXISTS (
	SELECT 1
	FROM profit_loss_report
	WHERE book_id = 'personal'
	  AND section = 'Income'
	  AND row_kind = 'section_total'
	  AND account = 'Total Income'
	  AND posttax = 100.00
    ) AND EXISTS (
	SELECT 1
	FROM profit_loss_report
	WHERE book_id = 'personal'
	  AND section = 'Expenses'
	  AND row_kind = 'section_total'
	  AND account = 'Total Expenses'
	  AND posttax = 48.83
    )
);

SELECT pg_temp.assert_true(
    'profit_loss_report reports net profit',
    (
	SELECT posttax = 51.17
	FROM profit_loss_report
	WHERE book_id = 'personal'
	  AND row_kind = 'grand_total'
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
    'cash_flow_report classifies operating cash flow',
    (
	SELECT posttax = 70.00
	FROM cash_flow_report
	WHERE book_id = 'personal'
	  AND section = 'Operating Activities'
	  AND row_kind = 'section_total'
	  AND account = 'Net Cash from Operating Activities'
    )
);

SELECT pg_temp.assert_true(
    'cash_flow_report classifies financing cash flow',
    (
	SELECT posttax = 50.00
	FROM cash_flow_report
	WHERE book_id = 'personal'
	  AND section = 'Financing Activities'
	  AND row_kind = 'section_total'
	  AND account = 'Net Cash from Financing Activities'
    )
);

SELECT pg_temp.assert_true(
    'cash_flow_report reconciles ending cash',
    (
	SELECT posttax = 120.00
	FROM cash_flow_report
	WHERE book_id = 'personal'
	  AND row_kind = 'computed'
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
    default_vat_code,
    default_tax_treatment
) VALUES (
    'personal',
    'JAGUAR Expenses',
    'E',
    'GBP',
    'UK_STANDARD_BLOCKED',
    'ALLOWABLE_REVENUE'
);

INSERT INTO vendors (book_id, id, name, vat_number)
VALUES ('personal', 'sparkle-wash', 'Sparkle Wash Ltd', 'GB123456789');

CALL create_xaction_nc(
    'personal',
    '2026-01-25',
    TRUE,
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

INSERT INTO business_expense_lines (xaction_bit_id)
SELECT xaction_bits.id
FROM xaction_bits
JOIN xactions
  ON xactions.book_id = xaction_bits.book_id
 AND xactions.xid = xaction_bits.xid
WHERE xaction_bits.book_id = 'personal'
  AND xactions.date = '2026-01-25'
  AND xaction_bits.acct = 'JAGUAR Expenses';

SELECT pg_temp.assert_true(
    'business expense detail inherits account tax defaults',
    (
	SELECT vendor_name = 'Sparkle Wash Ltd'
	   AND invoice_number = 'SW-100'
	   AND description = 'JAGUAR car wash'
	   AND memo IS NULL
	   AND vat_code = 'UK_STANDARD_BLOCKED'
	   AND vat_rate = 0.2000
	   AND vat_recoverable_rate = 0.0000
	   AND tax_treatment = 'ALLOWABLE_REVENUE'
	   AND business_use_percent = 1.0000
	FROM business_expense_detail
	WHERE book_id = 'personal'
	  AND account = 'JAGUAR Expenses'
	  AND invoice_number = 'SW-100'
    )
);

CALL create_xaction_nc(
    'personal',
    '2026-01-26',
    TRUE,
    ROW('Current GBP', -800.00, 'JAGUAR insurance')::xaction_elem,
    ROW('JAGUAR Expenses', 800.00, 'JAGUAR insurance')::xaction_elem
);

INSERT INTO business_expenses (book_id, xid, vendor_id, invoice_number)
SELECT book_id, xid, NULL, 'INS-2026'
FROM xactions
WHERE book_id = 'personal'
  AND date = '2026-01-26'
  AND comment = 'JAGUAR insurance';

INSERT INTO business_expense_lines (xaction_bit_id, vat_code, note)
SELECT xaction_bits.id, 'NO_VAT', 'Insurance is VAT exempt/no VAT on invoice'
FROM xaction_bits
JOIN xactions
  ON xactions.book_id = xaction_bits.book_id
 AND xactions.xid = xaction_bits.xid
WHERE xaction_bits.book_id = 'personal'
  AND xactions.date = '2026-01-26'
  AND xaction_bits.acct = 'JAGUAR Expenses';

SELECT pg_temp.assert_true(
    'business expense line overrides account VAT defaults',
    (
	SELECT vat_code = 'NO_VAT'
	   AND vat_rate = 0.0000
	   AND vat_recoverable_rate = 0.0000
	   AND tax_treatment = 'ALLOWABLE_REVENUE'
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

CALL create_xaction_nc(
    'personal',
    '2026-02-03',
    TRUE,
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

CALL create_xaction(
    'personal',
    '2026-02-01',
    FALSE,
    ROW('Broker USD', -10.00, 'Unmatched row')::xaction_elem
);

SELECT pg_temp.assert_true(
    'unresolved transactions are tracked',
    (
	SELECT count(*) = 1
	FROM xaction_unresolved
	WHERE book_id = 'personal'
    )
);

DO $$
BEGIN
    BEGIN
	CALL create_xaction_nc(
	    'personal',
	    '2026-02-02',
	    TRUE,
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

INSERT INTO accts (book_id, id, type, atype)
VALUES
    ('business', 'Opening Balance', 'Q', 'GBP'),
    ('business', 'Broker USD', 'A', 'USD'),
    ('business', 'Business Expense', 'E', 'USD');

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
    'import_csv creates ledger lines from staging rows',
    (
	SELECT count(*) = 2
	FROM xaction_bits
	JOIN xactions
	  ON xactions.book_id = xaction_bits.book_id
	 AND xactions.xid = xaction_bits.xid
	WHERE xaction_bits.book_id = 'personal'
	  AND acct = 'Broker USD'
	  AND xactions.comment IN ('Coffee', 'Refund')
	  AND xaction_bits.comment IS NULL
    )
);

DROP TABLE import;
