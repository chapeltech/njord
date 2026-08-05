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

SELECT pg_temp.assert_true(
    'valuations require a rate',
    NOT EXISTS (SELECT 1 FROM valuations WHERE rate IS NULL)
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
    'trial_balance_report balances foreign-currency books',
    (
	SELECT debit = 250.00 AND credit = 250.00
	FROM trial_balance_report
	WHERE book_id = 'personal'
	  AND row_kind = 'total'
	  AND account = 'Total'
    ) AND NOT EXISTS (
	SELECT 1
	FROM trial_balance_report
	WHERE book_id = 'personal'
	  AND row_kind = 'difference'
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

SELECT pg_temp.assert_true(
    'import_csv leaves one-sided transactions unresolved',
    (
	SELECT count(*) = 2
	FROM xaction_unresolved
	JOIN xactions
	  ON xactions.book_id = xaction_unresolved.book_id
	 AND xactions.xid = xaction_unresolved.xid
	WHERE xactions.book_id = 'personal'
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
	    FALSE,
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
	RAISE EXCEPTION 'resolved transaction with one line was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'direct resolved transactions require at least two lines',
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

    INSERT INTO xaction_unresolved (book_id, xid)
    VALUES ('personal', test_xid);

    BEGIN
	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	VALUES ('personal', test_xid, 'Current GBP', 'NaN'::NUMERIC);

	RAISE EXCEPTION 'non-finite transaction line was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;

    DELETE FROM xaction_unresolved
    WHERE book_id = 'personal' AND xid = test_xid;
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
	    ('personal', test_xid, 'Expenses', -9.00);

	SET CONSTRAINTS ALL IMMEDIATE;
	RAISE EXCEPTION 'unbalanced resolved transaction was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'direct resolved transactions must balance',
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
	RAISE EXCEPTION 'cross-asset resolved transaction was allowed';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'resolved transactions balance separately per asset',
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
	RAISE EXCEPTION 'an account asset invalidated resolved transactions';
    EXCEPTION WHEN check_violation THEN
	NULL;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'account asset changes revalidate resolved transactions',
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
    'transaction preview reports per-asset imbalance',
    (
	SELECT NOT valid
	   AND error_code = 'TRANSACTION_NOT_BALANCED'
	   AND imbalance = '{"GBP": 1.00000, "USD": -1.00000}'::jsonb
	FROM api.preview_transaction(
	    'personal',
	    '{
	      "date":"2026-03-03",
	      "resolved":true,
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
	      "resolved":true,
	      "lines":[
	        {"account":"Current GBP","amount":2,"comment":"Preview description"},
	        {"account":"Expenses","amount":-2,"comment":"Preview description"}
	      ]
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
	      "resolved":false,
	      "lines":[{"account":"Current GBP"}]
	    }'::jsonb
	)
    )
);

SELECT pg_temp.assert_true(
    'transaction preview rejects empty line arrays',
    (
	SELECT NOT valid AND error_code = 'TRANSACTION_REQUIRES_LINES'
	FROM api.preview_transaction(
	    'personal',
	    '{"date":"2026-03-04","resolved":false,"lines":[]}'::JSONB
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
	      "resolved":false,
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
	      "resolved":false,
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
	      "resolved":true,
	      "lines":[
	        {"account":"Current GBP","amount":0.000006},
	        {"account":"Expenses","amount":0.000006},
	        {"account":"Income","amount":-0.000012}
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
	      "resolved":true,
	      "lines":[
	        {"account":"Current GBP","amount":-10,"comment":"Split preview"},
	        {"account":"Expenses","amount":6,"comment":"Split preview"},
	        {"account":"Income","amount":4,"comment":"Split preview"}
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
	      "resolved":true,
	      "comment":"Invalid API write",
	      "lines":[
	        {"account":"Current GBP","amount":5},
	        {"account":"Expenses","amount":-4}
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
	SELECT count(*) = 3
	FROM accts
	WHERE book_id = 'api-test'
	  AND id IN ('Opening Balance', 'Income', 'Expenses')
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
      "resolved":true,
      "comment":"Groceries",
      "lines":[
        {"account":"Current Account","amount":-20},
        {"account":"Expenses","amount":20}
      ]
    }'::jsonb
);

SELECT pg_temp.assert_true(
    'create_transaction posts normalized lines',
    EXISTS (
	SELECT 1
	FROM api_created_transaction
	JOIN xactions USING (book_id, xid)
	WHERE resolved
	  AND xactions.comment = 'Groceries'
    )
);

CREATE TEMP TABLE api_replaced_transaction AS
SELECT replacement.*
FROM api_created_transaction AS original
CROSS JOIN LATERAL api.replace_transaction(
    original.book_id,
    original.xid,
    '{
      "date":"2026-01-03",
      "resolved":true,
      "comment":"Food shopping",
      "lines":[
        {"account":"Current Account","amount":-25},
        {"account":"Expenses","amount":25}
      ]
    }'::jsonb
) AS replacement;

SELECT pg_temp.assert_true(
    'replace_transaction atomically replaces the posting',
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
    )
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
    'update_ledger_line updates simple transaction headers',
    EXISTS (
	SELECT 1
	FROM api_replaced_transaction
	JOIN xactions USING (book_id, xid)
	WHERE xactions.date = '2026-01-04'
	  AND xactions.comment = 'Updated food shopping'
    )
);

CREATE TEMP TABLE api_split_transaction AS
SELECT *
FROM api.create_transaction(
    'api-test',
    '{
      "date":"2026-01-05",
      "resolved":true,
      "comment":"Split description",
      "lines":[
	{"account":"Current Account","amount":-10},
	{"account":"Expenses","amount":6},
	{"account":"Income","amount":4}
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

CALL create_simple_xaction(
    'api-test',
    '2026-06-01 12:00:00',
    'Current Account',
    'Expenses',
    -10
);

SELECT pg_temp.assert_true(
    'date-valued report pages include the entire final day',
    EXISTS (
	SELECT 1
	FROM api.profit_loss_page('api-test', '2026-06-01', '2026-06-01')
	WHERE component = 'report_row'
	  AND payload ->> 'row_kind' = 'account'
	  AND payload ->> 'account' = 'Expenses'
	  AND (payload ->> 'posttax')::NUMERIC = 10
    ) AND (
	SELECT current_day.payload ->> 'posttax'
	    IS DISTINCT FROM previous_day.payload ->> 'posttax'
	FROM api.balance_sheet_page('api-test', '2026-06-01') AS current_day
	CROSS JOIN api.balance_sheet_page('api-test', '2026-05-31') AS previous_day
	WHERE current_day.component = 'report_row'
	  AND previous_day.component = 'report_row'
	  AND current_day.payload ->> 'row_kind' = 'account'
	  AND previous_day.payload ->> 'row_kind' = 'account'
	  AND current_day.payload ->> 'account' = 'Current Account'
	  AND previous_day.payload ->> 'account' = 'Current Account'
    )
);

SELECT pg_temp.assert_true(
    'empty income and expense periods retain a zero total',
    EXISTS (
	SELECT 1
	FROM api.profit_loss_page('api-test', '1900-01-01', '1900-01-02')
	WHERE component = 'report_row'
	  AND payload ->> 'row_kind' = 'grand_total'
	  AND (payload ->> 'posttax')::NUMERIC = 0
    )
);

SELECT pg_temp.assert_true(
    'period pages return authoritative range validation',
    EXISTS (
	SELECT 1
	FROM api.profit_loss_page('api-test', '2026-12-31', '2026-01-01')
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages' @>
	      '["The start date must not be after the end date."]'::JSONB
    )
);

SELECT pg_temp.assert_true(
    'cash flow pages report missing cash-account configuration',
    EXISTS (
	SELECT 1
	FROM api.cash_flow_page('api-test', '2026-01-01', '2026-12-31')
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
	FROM api.balance_sheet_page('api-test', '2026-12-31')
	WHERE component = 'page_context'
	  AND payload ->> 'validation_messages' LIKE '%Missing valuations%Unvalued EUR%'
    )
);

SELECT pg_temp.assert_true(
    'report validation does not flag zero reporting-asset accounts',
    EXISTS (
	SELECT 1
	FROM api.trial_balance_page('personal', '2026-12-31')
	WHERE component = 'page_context'
	  AND payload -> 'validation_messages' = '[]'::JSONB
    )
);

SELECT pg_temp.assert_true(
    'shell page returns navigation and account choices',
    EXISTS (
	SELECT 1 FROM api.shell_page('api-test') WHERE component = 'book_option'
    ) AND EXISTS (
	SELECT 1 FROM api.shell_page('api-test') WHERE component = 'report_option'
    ) AND EXISTS (
	SELECT 1 FROM api.shell_page('api-test') WHERE component = 'account_option'
    )
);

SELECT pg_temp.assert_true(
    'default shell page selects a book and returns its accounts',
    EXISTS (
	SELECT 1
	FROM api.shell_page()
	WHERE component = 'book_option'
	  AND (payload ->> 'selected')::BOOLEAN
    ) AND EXISTS (
	SELECT 1
	FROM api.shell_page()
	WHERE component = 'account_option'
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
	WHERE component = 'transfer_account_option'
	  AND row_key = 'Expenses'
	) AND NOT EXISTS (
	SELECT 1
	FROM api.ledger_page('personal', 'Current GBP')
	WHERE component = 'transfer_account_option'
	  AND row_key = 'Broker USD'
	) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'ledger_row'
	  AND jsonb_array_length(payload -> 'split_lines') = 2
	) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'page_context'
	  AND payload #>> '{transaction_rules,minimum_resolved_lines}' = '2'
	) AND EXISTS (
	SELECT 1
	FROM api.ledger_page('api-test', 'Current Account')
	WHERE component = 'book_option'
    )
);

SELECT pg_temp.assert_true(
    'all personal UI pages have canonical SQL functions',
    EXISTS (SELECT 1 FROM api.general_journal_page('api-test') WHERE component = 'journal_row')
    AND EXISTS (SELECT 1 FROM api.balance_sheet_page('api-test', '2026-12-31') WHERE component = 'report_row')
    AND EXISTS (SELECT 1 FROM api.trial_balance_page('api-test', '2026-12-31') WHERE component = 'trial_balance_row')
    AND EXISTS (SELECT 1 FROM api.profit_loss_page('api-test', '2026-01-01', '2026-12-31') WHERE component = 'report_row')
    AND EXISTS (SELECT 1 FROM api.cash_flow_page('api-test', '2026-01-01', '2026-12-31') WHERE component = 'page_context')
    AND EXISTS (SELECT 1 FROM api.add_book_page() WHERE component = 'asset_option')
    AND EXISTS (SELECT 1 FROM api.add_account_page('api-test') WHERE component = 'account_type_option')
);

SELECT pg_temp.assert_true(
    'every page function includes the application shell',
    NOT EXISTS (
	SELECT page_name
	FROM (VALUES
	    ('general_journal_page'),
	    ('balance_sheet_page'),
	    ('trial_balance_page'),
	    ('profit_loss_page'),
	    ('cash_flow_page'),
	    ('add_book_page'),
	    ('add_account_page')
	) AS required_pages(page_name)
	WHERE CASE page_name
	    WHEN 'general_journal_page' THEN NOT EXISTS (
		SELECT 1 FROM api.general_journal_page('api-test')
		WHERE component = 'book_option'
	    )
	    WHEN 'balance_sheet_page' THEN NOT EXISTS (
		SELECT 1 FROM api.balance_sheet_page('api-test', '2026-12-31')
		WHERE component = 'book_option'
	    )
	    WHEN 'trial_balance_page' THEN NOT EXISTS (
		SELECT 1 FROM api.trial_balance_page('api-test', '2026-12-31')
		WHERE component = 'book_option'
	    )
	    WHEN 'profit_loss_page' THEN NOT EXISTS (
		SELECT 1 FROM api.profit_loss_page('api-test', '2026-01-01', '2026-12-31')
		WHERE component = 'book_option'
	    )
	    WHEN 'cash_flow_page' THEN NOT EXISTS (
		SELECT 1 FROM api.cash_flow_page('api-test', '2026-01-01', '2026-12-31')
		WHERE component = 'book_option'
	    )
	    WHEN 'add_book_page' THEN NOT EXISTS (
		SELECT 1 FROM api.add_book_page()
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
SELECT 'general-journal', * FROM api.general_journal_page('api-test')
UNION ALL
SELECT 'balance-sheet', * FROM api.balance_sheet_page('api-test', '2026-12-31')
UNION ALL
SELECT 'trial-balance', * FROM api.trial_balance_page('api-test', '2026-12-31')
UNION ALL
SELECT 'profit-loss', * FROM api.profit_loss_page('api-test', '2026-01-01', '2026-12-31')
UNION ALL
SELECT 'cash-flow', * FROM api.cash_flow_page('api-test', '2026-01-01', '2026-12-31')
UNION ALL
SELECT 'add-book', * FROM api.add_book_page()
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
    'add-page functions return database defaults and validation state',
    EXISTS (
	SELECT 1
	FROM api.add_book_page()
	WHERE component = 'page_context'
	  AND payload ->> 'reporting_asset' = 'GBP'
	  AND (payload #>> '{validation,id_required}')::BOOLEAN
    ) AND EXISTS (
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
	FROM api.general_journal_page('missing-book')
	WHERE component = 'page_context'
	  AND jsonb_array_length(payload -> 'validation_messages') > 0
    ) AND EXISTS (
	SELECT 1
	FROM api.add_account_page('missing-book')
	WHERE component = 'page_context'
	  AND jsonb_array_length(payload -> 'validation_messages') > 0
    )
);
