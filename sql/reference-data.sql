
--
-- Account types.  Standard account parlance:

INSERT INTO acct_types VALUES ('A');	-- Assets
INSERT INTO acct_types VALUES ('L');	-- Liabilities
INSERT INTO acct_types VALUES ('E');	-- Expenses
INSERT INTO acct_types VALUES ('I');	-- Income
INSERT INTO acct_types VALUES ('Q');	-- Equity

-- Account class and account kind are deliberately orthogonal.  Class decides
-- the financial-statement branch; kind describes how a node is used.
INSERT INTO account_kinds (id, label, required_type) VALUES
    ('root', 'Root', NULL),
    ('group', 'Group', NULL),
    ('posting', 'Posting account', NULL),
    ('bank', 'Bank account', 'A'),
    ('cash', 'Cash', 'A'),
    ('fixed_asset', 'Fixed asset', 'A'),
    ('investment', 'Investment', 'A'),
    ('loan', 'Loan', 'L'),
    ('director_loan', 'Director loan', 'L');

INSERT INTO book_entity_types (id, allows_business_packs) VALUES
	('household', FALSE),
	('sole_trader', TRUE),
	('partnership', TRUE),
	('company', TRUE),
	('charity', TRUE),
	('trust', TRUE),
	('other_organisation', TRUE);
