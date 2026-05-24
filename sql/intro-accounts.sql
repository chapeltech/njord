
--
-- Account types.  Standard account parlance:

INSERT INTO acct_types VALUES ('A');	-- Assets
INSERT INTO acct_types VALUES ('L');	-- Liabilities
INSERT INTO acct_types VALUES ('E');	-- Expenses
INSERT INTO acct_types VALUES ('I');	-- Income
INSERT INTO acct_types VALUES ('Q');	-- Equity

--
-- VAT and Corporation Tax treatment reference data.  Account defaults can
-- point at these rows, and individual expense lines can override them.

INSERT INTO vat_codes (id, description, vat_rate, recoverable_rate) VALUES
    ('NO_VAT', 'No VAT', 0.0000, 0.0000),
    ('UK_STANDARD_FULL', 'UK VAT 20%, fully recoverable', 0.2000, 1.0000),
    ('UK_STANDARD_BLOCKED', 'UK VAT 20%, blocked', 0.2000, 0.0000),
    ('UK_STANDARD_HALF', 'UK VAT 20%, 50% recoverable', 0.2000, 0.5000),
    ('EXEMPT', 'VAT exempt', 0.0000, 0.0000),
    ('OUTSIDE_SCOPE', 'Outside scope of VAT', 0.0000, 0.0000);

INSERT INTO expense_tax_treatments (id, description) VALUES
    ('ALLOWABLE_REVENUE', 'Allowable trading expense'),
    ('DISALLOWABLE', 'Not deductible for Corporation Tax'),
    ('CAPITAL_ASSET', 'Capital item handled through fixed assets or capital allowances'),
    ('MILEAGE_CLAIM', 'Approved mileage allowance payment'),
    ('MIXED_USE', 'Part business, part private use');

--
-- And now we create the standard accounts that everyone is required
-- to have.  Our new model is to use tags with Expenses, but for the
-- the regular kinds of assets, well, we shall have to see.  Maybe it
-- makes sense, maybe it doesn't?

--
-- Income and expense accounts:

INSERT INTO books VALUES ('personal', 'Personal', 'GBP');

INSERT INTO accts (book_id, id, type, atype)
	VALUES ('personal', 'Opening Balance',	'Q', 'GBP');
INSERT INTO accts (book_id, id, type, atype)
	VALUES ('personal', 'Income',		'I', 'GBP');
INSERT INTO accts (book_id, id, type, atype)
	VALUES ('personal', 'Expenses',		'E', 'GBP');
