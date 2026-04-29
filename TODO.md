# TODO

## Accounting Constraints

- Add a deferred constraint trigger that rejects any resolved transaction
  whose lines do not sum to zero per asset.
- Make CSV imports create unresolved transactions instead of resolved
  one-sided transactions.
- Add an audit view for unbalanced transactions.
- Add an audit view for unresolved transactions with all line details.
- Add uniqueness for `valuations(date, src, dst)`.
- Add uniqueness for `xaction_tags(xid, tag)`.
- Consider making `valuations.rate` `NOT NULL` and positive.
- Consider making account tax treatment a named policy instead of a raw
  multiplier on `accts`.

## Valuations

- Make historical reports use the latest valuation at or before the report
  date.
- Decide how foreign-exchange transactions should balance: strict per-asset
  balancing, explicit exchange accounts, or a separate exchange-lot model.
- Add reports for accounts or assets without a valuation path to the reporting
  currency.
- Decide whether `full_valuations` should include date-sensitive paths or only
  current conversion paths.

## Imports

- Replace temporary-only CSV import with persistent import batches and import
  rows.
- Store source filename, import time, source account, and row number for each
  imported row.
- Add reconciliation procedures that convert staged rows into balanced
  transactions.
- Add duplicate detection for bank imports.
- Support per-bank CSV layouts without changing core ledger tables.

## Reporting

- Add income statement reports by date range.
- Add cash-flow reports by date range.
- Add account register reports with running balances and counterparty account
  summaries.
- Add tag-based spending reports.
- Add expected income/yield reports for accounts and assets.

## Project Shape

- Keep the core package SQL-only.
- Expand the SQL test suite as accounting constraints are added.
- Document each public procedure and report view in one place.
- Avoid putting accounting correctness in future UI code; UI code should call
  SQL APIs and rely on database constraints.
