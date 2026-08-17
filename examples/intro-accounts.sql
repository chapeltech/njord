--
-- And now we create the standard accounts that everyone is required
-- to have.  Our new model is to use tags with Expenses, but for the
-- the regular kinds of assets, well, we shall have to see.  Maybe it
-- makes sense, maybe it doesn't?

--
-- Income and expense accounts:

-- The legacy all-in-one demo loader leaves njord_example_book unset and
-- therefore loads both examples for broad SQL regression tests. The
-- database-per-book development loader selects exactly one branch.
\if :{?njord_example_book}
SELECT :'njord_example_book' IN ('all', 'personal') AS load_personal,
       :'njord_example_book' IN ('all', 'demo') AS load_demo
\gset
\else
\set load_personal true
\set load_demo true
\endif

\if :load_personal

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('personal', 'Personal', 'GBP', 'household');

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('personal', 'Assets', 'Assets', 'A', 'GBP', NULL, 'root', TRUE),
    ('personal', 'Liabilities', 'Liabilities', 'L', 'GBP', NULL, 'root', TRUE),
    ('personal', 'Equity', 'Equity', 'Q', 'GBP', NULL, 'root', TRUE),
    ('personal', 'Income', 'Income', 'I', 'GBP', NULL, 'root', TRUE),
    ('personal', 'Expenses', 'Expenses', 'E', 'GBP', NULL, 'root', TRUE);

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('personal', 'Opening Balance', 'Opening Balance', 'Q', 'GBP',
	'Equity', 'posting', FALSE),
    ('personal', 'Uncategorised Income', 'Uncategorised Income', 'I', 'GBP',
	'Income', 'posting', FALSE),
    ('personal', 'Uncategorised Expenses', 'Uncategorised Expenses', 'E', 'GBP',
	'Expenses', 'posting', FALSE);

\endif

-- The default UI book is intentionally rich enough to explore without first
-- entering data.  A house remains a GBP-denominated fixed-asset account; XAU,
-- XAG, and VWRL accounts hold quantities of their respective commodities.
\if :load_demo
INSERT INTO asset (id) VALUES ('VWRL');

INSERT INTO books (id, name, reporting_asset, entity_type)
VALUES ('demo', 'A Demo Household', 'GBP', 'household');

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('demo', 'Assets', 'Assets', 'A', 'GBP', NULL, 'root', TRUE),
    ('demo', 'Liabilities', 'Liabilities', 'L', 'GBP', NULL, 'root', TRUE),
    ('demo', 'Equity', 'Equity', 'Q', 'GBP', NULL, 'root', TRUE),
    ('demo', 'Income', 'Income', 'I', 'GBP', NULL, 'root', TRUE),
    ('demo', 'Expenses', 'Expenses', 'E', 'GBP', NULL, 'root', TRUE);

INSERT INTO accts (
    book_id, id, name, type, atype, parent_id, account_kind, placeholder
) VALUES
    ('demo', 'Current Assets', 'Current Assets', 'A', 'GBP',
	'Assets', 'group', TRUE),
    ('demo', 'Everyday Current Account', 'Everyday Current Account', 'A', 'GBP',
	'Current Assets', 'bank', FALSE),
    ('demo', 'Household Cash', 'Household Cash', 'A', 'GBP',
	'Current Assets', 'cash', FALSE),
    ('demo', 'Rainy Day Savings', 'Rainy Day Savings', 'A', 'GBP',
	'Current Assets', 'bank', FALSE),
    ('demo', 'Fixed Assets', 'Fixed Assets', 'A', 'GBP',
	'Assets', 'group', TRUE),
    ('demo', '12 Acacia Avenue', '12 Acacia Avenue', 'A', 'GBP',
	'Fixed Assets', 'fixed_asset', FALSE),
    ('demo', 'Investments', 'Investments', 'A', 'GBP',
	'Assets', 'group', TRUE),
    ('demo', 'Gold Bullion', 'Gold Bullion', 'A', 'XAU',
	'Investments', 'investment', FALSE),
    ('demo', 'Silver Bullion', 'Silver Bullion', 'A', 'XAG',
	'Investments', 'investment', FALSE),
    ('demo', 'Global Equity ETF', 'Global Equity ETF', 'A', 'VWRL',
	'Investments', 'investment', FALSE),

    ('demo', 'Mortgage Loans', 'Mortgage Loans', 'L', 'GBP',
	'Liabilities', 'group', TRUE),
    ('demo', '12 Acacia Avenue Mortgage', '12 Acacia Avenue Mortgage', 'L', 'GBP',
	'Mortgage Loans', 'loan', FALSE),
    ('demo', 'Credit Cards', 'Credit Cards', 'L', 'GBP',
	'Liabilities', 'group', TRUE),
    ('demo', 'Household Credit Card', 'Household Credit Card', 'L', 'GBP',
	'Credit Cards', 'posting', FALSE),

    ('demo', 'Opening Balance', 'Opening Balance', 'Q', 'GBP',
	'Equity', 'posting', FALSE),
    ('demo', 'Opening Balance (XAU)', 'Opening Balance (XAU)', 'Q', 'XAU',
	'Equity', 'posting', FALSE),
    ('demo', 'Opening Balance (XAG)', 'Opening Balance (XAG)', 'Q', 'XAG',
	'Equity', 'posting', FALSE),
    ('demo', 'Opening Balance (VWRL)', 'Opening Balance (VWRL)', 'Q', 'VWRL',
	'Equity', 'posting', FALSE),

    ('demo', 'Employment Income', 'Employment', 'I', 'GBP',
	'Income', 'group', TRUE),
    ('demo', 'Salary', 'Salary', 'I', 'GBP',
	'Employment Income', 'posting', FALSE),
    ('demo', 'Investment Income', 'Investment Income', 'I', 'GBP',
	'Income', 'group', TRUE),
    ('demo', 'Dividends', 'Dividends', 'I', 'GBP',
	'Investment Income', 'posting', FALSE),
    ('demo', 'Savings Interest', 'Savings Interest', 'I', 'GBP',
	'Investment Income', 'posting', FALSE),
    ('demo', 'Uncategorised Income', 'Uncategorised Income', 'I', 'GBP',
	'Income', 'posting', FALSE),

    ('demo', 'Household Expenses', 'Household', 'E', 'GBP',
	'Expenses', 'group', TRUE),
    ('demo', 'Groceries', 'Groceries', 'E', 'GBP',
	'Household Expenses', 'posting', FALSE),
    ('demo', 'Council Tax', 'Council Tax', 'E', 'GBP',
	'Household Expenses', 'posting', FALSE),
    ('demo', 'Utilities', 'Utilities', 'E', 'GBP',
	'Household Expenses', 'group', TRUE),
    ('demo', 'Electricity', 'Electricity', 'E', 'GBP',
	'Utilities', 'posting', FALSE),
    ('demo', 'Gas', 'Gas', 'E', 'GBP',
	'Utilities', 'posting', FALSE),
    ('demo', 'Water', 'Water', 'E', 'GBP',
	'Utilities', 'posting', FALSE),
    ('demo', 'Broadband', 'Broadband', 'E', 'GBP',
	'Utilities', 'posting', FALSE),
    ('demo', 'Mobile Telephone', 'Mobile Telephone', 'E', 'GBP',
	'Utilities', 'posting', FALSE),
    ('demo', 'Housing Costs', 'Housing', 'E', 'GBP',
	'Expenses', 'group', TRUE),
    ('demo', 'Mortgage Interest', 'Mortgage Interest', 'E', 'GBP',
	'Housing Costs', 'posting', FALSE),
    ('demo', 'Home Insurance', 'Home Insurance', 'E', 'GBP',
	'Housing Costs', 'posting', FALSE),
    ('demo', 'Repairs', 'Repairs', 'E', 'GBP',
	'Housing Costs', 'posting', FALSE),
    ('demo', 'Transport', 'Transport', 'E', 'GBP',
	'Expenses', 'group', TRUE),
    ('demo', 'Fuel', 'Fuel', 'E', 'GBP',
	'Transport', 'posting', FALSE),
    ('demo', 'Rail Travel', 'Rail Travel', 'E', 'GBP',
	'Transport', 'posting', FALSE),
    ('demo', 'Leisure', 'Leisure', 'E', 'GBP',
	'Expenses', 'group', TRUE),
    ('demo', 'Dining Out', 'Dining Out', 'E', 'GBP',
	'Leisure', 'posting', FALSE),
    ('demo', 'Entertainment', 'Entertainment', 'E', 'GBP',
	'Leisure', 'posting', FALSE),
    ('demo', 'Holidays', 'Holidays', 'E', 'GBP',
	'Leisure', 'posting', FALSE),
    ('demo', 'Uncategorised Expenses', 'Uncategorised Expenses', 'E', 'GBP',
	'Expenses', 'posting', FALSE);

INSERT INTO cash_accounts (book_id, acct) VALUES
    ('demo', 'Everyday Current Account'),
    ('demo', 'Household Cash'),
    ('demo', 'Rainy Day Savings');

INSERT INTO valuations (date, src, dst, rate) VALUES
    ('2026-01-01', 'XAU', 'GBP', 2100.00000),
    ('2026-08-01', 'XAU', 'GBP', 2620.00000),
    ('2026-01-01', 'XAG', 'GBP', 24.50000),
    ('2026-08-01', 'XAG', 'GBP', 29.50000),
    ('2026-01-01', 'VWRL', 'GBP', 104.25000),
    ('2026-08-01', 'VWRL', 'GBP', 112.40000);

INSERT INTO account_valuations (book_id, acct, date, dst, value, comment)
VALUES (
    'demo', '12 Acacia Avenue', '2026-08-01', 'GBP', 425000.00000,
    'Illustrative estate-agent estimate'
);

-- Seed balanced postings directly because the convenience transaction
-- procedures are loaded after this reference/demo data file.
DO $$
DECLARE
    seed_xid INTEGER;
    entry RECORD;
BEGIN
    INSERT INTO xactions (book_id, date, comment)
    VALUES ('demo', '2026-01-01', 'Opening household balances')
    RETURNING xid INTO seed_xid;

    INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	('demo', seed_xid, 'Everyday Current Account', 8400.00),
	('demo', seed_xid, 'Rainy Day Savings', 17000.00),
	('demo', seed_xid, 'Household Cash', 180.00),
	('demo', seed_xid, '12 Acacia Avenue', 325000.00),
	('demo', seed_xid, '12 Acacia Avenue Mortgage', -248000.00),
	('demo', seed_xid, 'Household Credit Card', -620.00),
	('demo', seed_xid, 'Opening Balance', -101960.00);

    FOR entry IN
	SELECT * FROM (VALUES
	    ('2026-01-01'::TIMESTAMP, 'Opening gold holding'::VARCHAR,
		'Gold Bullion'::VARCHAR, 5.00000::NUMERIC,
		'Opening Balance (XAU)'::VARCHAR, -5.00000::NUMERIC),
	    ('2026-01-01'::TIMESTAMP, 'Opening silver holding'::VARCHAR,
		'Silver Bullion'::VARCHAR, 200.00000::NUMERIC,
		'Opening Balance (XAG)'::VARCHAR, -200.00000::NUMERIC),
	    ('2026-01-01'::TIMESTAMP, 'Opening ETF holding'::VARCHAR,
		'Global Equity ETF'::VARCHAR, 120.00000::NUMERIC,
		'Opening Balance (VWRL)'::VARCHAR, -120.00000::NUMERIC)
	) AS holdings(date, description, acct1, amt1, acct2, amt2)
    LOOP
	INSERT INTO xactions (book_id, date, comment)
	VALUES ('demo', entry.date, entry.description)
	RETURNING xid INTO seed_xid;

	INSERT INTO xaction_bits (book_id, xid, acct, amt) VALUES
	    ('demo', seed_xid, entry.acct1, entry.amt1),
	    ('demo', seed_xid, entry.acct2, entry.amt2);
    END LOOP;

    FOR entry IN
	SELECT * FROM (VALUES
	    ('2026-01-25'::TIMESTAMP, 'January salary'::VARCHAR,
		'Everyday Current Account'::VARCHAR, 3200.00::NUMERIC,
		'Salary'::VARCHAR, -3200.00::NUMERIC, NULL::VARCHAR, NULL::NUMERIC),
	    ('2026-02-25', 'February salary', 'Everyday Current Account', 3200.00,
		'Salary', -3200.00, NULL, NULL),
	    ('2026-03-25', 'March salary', 'Everyday Current Account', 3200.00,
		'Salary', -3200.00, NULL, NULL),
	    ('2026-04-25', 'April salary', 'Everyday Current Account', 3200.00,
		'Salary', -3200.00, NULL, NULL),
	    ('2026-02-02', 'Weekly groceries', 'Everyday Current Account', -86.45,
		'Groceries', 86.45, NULL, NULL),
	    ('2026-02-03', 'Council tax', 'Everyday Current Account', -190.00,
		'Council Tax', 190.00, NULL, NULL),
	    ('2026-02-05', 'Electricity bill', 'Everyday Current Account', -82.00,
		'Electricity', 82.00, NULL, NULL),
	    ('2026-02-06', 'Gas bill', 'Everyday Current Account', -64.00,
		'Gas', 64.00, NULL, NULL),
	    ('2026-02-07', 'Water bill', 'Everyday Current Account', -38.00,
		'Water', 38.00, NULL, NULL),
	    ('2026-02-08', 'Broadband', 'Everyday Current Account', -32.00,
		'Broadband', 32.00, NULL, NULL),
	    ('2026-02-09', 'Mobile telephone', 'Everyday Current Account', -18.00,
		'Mobile Telephone', 18.00, NULL, NULL),
	    ('2026-02-11', 'Petrol station', 'Everyday Current Account', -72.00,
		'Fuel', 72.00, NULL, NULL),
	    ('2026-02-14', 'Train tickets', 'Everyday Current Account', -49.00,
		'Rail Travel', 49.00, NULL, NULL),
	    ('2026-02-16', 'Home insurance', 'Everyday Current Account', -31.00,
		'Home Insurance', 31.00, NULL, NULL),
	    ('2026-02-18', 'Boiler repair', 'Everyday Current Account', -215.00,
		'Repairs', 215.00, NULL, NULL),
	    ('2026-02-20', 'Dinner with friends', 'Everyday Current Account', -74.00,
		'Dining Out', 74.00, NULL, NULL),
	    ('2026-02-21', 'Cinema', 'Everyday Current Account', -28.00,
		'Entertainment', 28.00, NULL, NULL),
	    ('2026-02-22', 'Holiday deposit', 'Rainy Day Savings', -450.00,
		'Holidays', 450.00, NULL, NULL),
	    ('2026-02-26', 'Move money to savings', 'Everyday Current Account', -500.00,
		'Rainy Day Savings', 500.00, NULL, NULL),
	    ('2026-02-28', 'Savings interest', 'Rainy Day Savings', 18.00,
		'Savings Interest', -18.00, NULL, NULL),
	    ('2026-03-01', 'ETF distribution', 'Everyday Current Account', 45.00,
		'Dividends', -45.00, NULL, NULL),
	    ('2026-03-02', 'Mortgage payment', 'Everyday Current Account', -1200.00,
		'12 Acacia Avenue Mortgage', 800.00, 'Mortgage Interest', 400.00),
	    ('2026-04-02', 'Mortgage payment', 'Everyday Current Account', -1200.00,
		'12 Acacia Avenue Mortgage', 800.00, 'Mortgage Interest', 400.00),
	    ('2026-04-05', 'Credit-card repayment', 'Everyday Current Account', -400.00,
		'Household Credit Card', 400.00, NULL, NULL),
	    ('2026-04-07', 'Weekly groceries', 'Household Credit Card', -93.20,
		'Groceries', 93.20, NULL, NULL)
	) AS activity(date, description, acct1, amt1, acct2, amt2, acct3, amt3)
    LOOP
	INSERT INTO xactions (book_id, date, comment)
	VALUES ('demo', entry.date, entry.description)
	RETURNING xid INTO seed_xid;

	INSERT INTO xaction_bits (book_id, xid, acct, amt)
	SELECT 'demo', seed_xid, line.acct, line.amt
	FROM (VALUES
	    (entry.acct1, entry.amt1),
	    (entry.acct2, entry.amt2),
	    (entry.acct3, entry.amt3)
	) AS line(acct, amt)
	WHERE line.acct IS NOT NULL;
    END LOOP;
END;
$$;

-- Older example activity is already reconciled; recent entries remain in the
-- dedicated reconciliation queue so that page is useful on first launch.
DELETE FROM unreconciled_postings
USING xactions
WHERE unreconciled_postings.book_id = xactions.book_id
  AND unreconciled_postings.xid = xactions.xid
  AND xactions.book_id = 'demo'
  AND xactions.date < '2026-04-01';
\endif
