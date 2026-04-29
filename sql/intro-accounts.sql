
--
-- Account types.  Standard account parlance:

INSERT INTO acct_types VALUES ('A');	-- Assets
INSERT INTO acct_types VALUES ('L');	-- Liabilities
INSERT INTO acct_types VALUES ('E');	-- Expenses
INSERT INTO acct_types VALUES ('I');	-- Income
INSERT INTO acct_types VALUES ('Q');	-- Equity

--
-- And now we create the standard accounts that everyone is required
-- to have.  Our new model is to use tags with Expenses, but for the
-- the regular kinds of assets, well, we shall have to see.  Maybe it
-- makes sense, maybe it doesn't?

--
-- Income and expense accounts:

INSERT INTO accts VALUES ('Opening Balance',	'Q', 'GBP');
INSERT INTO accts VALUES ('Income',		'I', 'GBP');
INSERT INTO accts VALUES ('Expenses',		'E', 'GBP');
