DROP FUNCTION IF EXISTS bsheet;
DROP FUNCTION IF EXISTS ledger;

DROP PROCEDURE IF EXISTS open_account;
DROP PROCEDURE IF EXISTS create_simple_xaction;
DROP PROCEDURE IF EXISTS create_xaction;
DROP PROCEDURE IF EXISTS create_xaction_nc;
DROP PROCEDURE IF EXISTS create_xaction_v;

DROP VIEW IF EXISTS balance_sheet;
DROP VIEW IF EXISTS balance_sheet_old;
DROP VIEW IF EXISTS full_valuations;
DROP VIEW IF EXISTS valuations_with_reciprocals;
DROP VIEW IF EXISTS current_valuations;
DROP VIEW IF EXISTS join_them;

DROP TABLE IF EXISTS xaction_tags;
DROP TABLE IF EXISTS xaction_unresolved;
DROP TABLE IF EXISTS xaction_bits;
DROP TABLE IF EXISTS xactions;
DROP TABLE IF EXISTS accts;
DROP TABLE IF EXISTS acct_types;
DROP TABLE IF EXISTS valuations;
DROP TABLE IF EXISTS asset;

DROP TYPE IF EXISTS xaction_elem;

--
-- OLD THINGS, DEPRECATED:
