DROP SCHEMA IF EXISTS api CASCADE;
DROP SCHEMA IF EXISTS plutus CASCADE;

DROP FUNCTION IF EXISTS bsheet;
DROP FUNCTION IF EXISTS bsheet_report;
DROP FUNCTION IF EXISTS tb_report;
DROP FUNCTION IF EXISTS pl_report;
DROP FUNCTION IF EXISTS cf_report;
DROP FUNCTION IF EXISTS ledger;

DROP PROCEDURE IF EXISTS open_account;
DROP PROCEDURE IF EXISTS create_simple_xaction;
DROP PROCEDURE IF EXISTS create_xaction;
DROP PROCEDURE IF EXISTS create_xaction_nc;
DROP PROCEDURE IF EXISTS create_xaction_v;

DROP VIEW IF EXISTS balance_sheet;
DROP VIEW IF EXISTS balance_sheet_report;
DROP VIEW IF EXISTS trial_balance_report;
DROP VIEW IF EXISTS profit_loss_report;
DROP VIEW IF EXISTS cash_flow_report;
DROP VIEW IF EXISTS general_journal;
DROP VIEW IF EXISTS balance_sheet_old;
DROP VIEW IF EXISTS full_ledger;
DROP VIEW IF EXISTS full_valuations;
DROP VIEW IF EXISTS valuations_with_reciprocals;
DROP VIEW IF EXISTS current_valuations;
DROP VIEW IF EXISTS join_them;
DROP VIEW IF EXISTS business_expense_detail;

DROP TABLE IF EXISTS xaction_tags;
DROP TABLE IF EXISTS business_expense_lines;
DROP TABLE IF EXISTS business_expenses;
DROP TABLE IF EXISTS xaction_unresolved;
DROP TABLE IF EXISTS xaction_bits;
DROP TABLE IF EXISTS xactions;
DROP TABLE IF EXISTS vendors;
DROP TABLE IF EXISTS cash_accounts;
DROP TABLE IF EXISTS accts;
DROP TABLE IF EXISTS expense_tax_treatments;
DROP TABLE IF EXISTS vat_codes;
DROP TABLE IF EXISTS books;
DROP TABLE IF EXISTS acct_types;
DROP TABLE IF EXISTS valuations;
DROP TABLE IF EXISTS asset;

DROP FUNCTION IF EXISTS ensure_cash_account_is_asset;
DROP FUNCTION IF EXISTS enforce_account_invariants;
DROP FUNCTION IF EXISTS enforce_resolved_xaction_balance;
DROP FUNCTION IF EXISTS assert_resolved_xaction_balance;
DROP FUNCTION IF EXISTS opening_balance_account;

DROP TYPE IF EXISTS xaction_elem;

--
-- OLD THINGS, DEPRECATED:
