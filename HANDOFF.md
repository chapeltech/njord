# Plutus Migration Handoff

## Status

The localhost PostgREST migration is complete. Every item in `TODO.md` has
direct SQL, HTTP, or browser test evidence and is checked off. The supported
web scope is personal accounting: books, accounts, balanced and split
transactions, ledgers, the General Journal, Balance Sheet, Trial Balance,
Income and Expenses, and Cash Flow.

Business-expense, VAT, invoice, import, and wider company-accounting UI work
remains outside this migration. Its existing database model and reporting
fallbacks remain intact.

## Final Architecture

- PostgreSQL is the application and accounting boundary.
- PostgREST 14.16 replaces the custom Haskell/Servant executable and exposes
  only the `api` schema.
- PostgREST and the static UI server bind to `127.0.0.1` by default.
- Each Elm page is loaded from one canonical table-returning SQL function.
- Page functions return discriminated `component`, `row_order`, `row_key`,
  and `payload jsonb` rows containing the page context, navigation, choices,
  report rows, computed amounts, totals, and validation metadata.
- Elm owns rendering, selection, expansion, temporary input text, formatting,
  and HTTP interaction. PostgreSQL owns accounting arithmetic,
  classification, normalization, balancing, grouping, and authoritative
  validation.
- Public `/rpc` functions implement writes and previews; database constraints
  remain the final protection for direct SQL writes.
- `scripts/static-server.mjs` serves compiled Elm assets and proxies
  same-origin `/rpc` requests without business logic.
- Production authentication remains deliberately deferred. The planned seam
  is HTTP/Negotiate with GSSAPI at a trusted reverse proxy, passing the
  principal into PostgreSQL request context.

See `ARCHITECTURE.md` for the complete boundary and dependency rules.

## Page API

The canonical page functions in `sql/api.sql` are:

1. `api.shell_page`
2. `api.ledger_page`
3. `api.general_journal_page`
4. `api.balance_sheet_page`
5. `api.trial_balance_page`
6. `api.profit_loss_page`
7. `api.cash_flow_page`
8. `api.add_book_page`
9. `api.add_account_page`

Every rendered page response includes the application shell. The ledger takes
a book and account; dated reports take their applicable book and date or date
range. Elm sorts the returned components by `row_order` and applies defaults
from the SQL `page_context` row.

## Mutation API

The exposed mutation functions are:

- `api.create_book`
- `api.create_account`, including optional asset-matched opening balances
- `api.preview_transaction`
- `api.create_transaction`
- `api.replace_transaction`
- `api.update_ledger_line`

Transaction preview returns normalized headers and lines, validity, a stable
error code/message, and imbalance by asset. Expected write failures raise
structured PostgreSQL errors whose stable code is returned by PostgREST in
the `details` field and displayed by Elm.

## Ledger Guarantees

PostgreSQL now enforces all migration invariants for both API functions and
direct table writes:

- every resolved transaction has at least two non-zero, finite lines;
- resolved transactions balance separately for every asset;
- account asset changes revalidate all affected resolved transactions;
- incomplete transactions are represented by `xaction_unresolved`;
- one-sided CSV imports are unresolved;
- an account appears at most once in a transaction;
- deferred constraint triggers validate final transaction state after all
  lines in the database transaction have been written; and
- non-reporting-asset opening balances use an asset-matched equity account,
  such as `Opening Balance (USD)`.

Preview normalizes amounts to the ledger's `NUMERIC(100,5)` storage precision
before checking zero values or balance. Valuations are unique for each
date/source/destination tuple, and report page contexts surface invalid date
ranges, missing cash-account configuration, and missing valuation data.

The pre-existing business-expense view still applies `NO_VAT` and
`ALLOWABLE_REVENUE` fallbacks when neither a line nor account supplies an
override.

## TODO Evidence

1. **Green baseline:** `tests/run.sh` loads the complete schema twice into a
   fresh database before running assertions.
2. **Ledger invariants:** `tests/basic.sql` exercises resolved/unresolved,
   zero-line, one-line, duplicate-account, per-asset balance, import, and
   asset-matched opening-balance paths through both direct SQL and functions.
3. **Page schema:** SQL and PostgREST tests call every page function and verify
   its shell, context, choices, report data, ordering contract, and defaults.
4. **Mutation schema:** SQL/API tests exercise all six public mutation and
   preview functions, including normalized split previews and structured
   failure responses.
5. **Local PostgREST:** `postgrest.conf`, `scripts/run-postgrest`, and the
   checksum-pinned installer configure only the `api` schema on loopback.
6. **Elm conversion:** `frontend/src/Main.elm` uses one shared `/rpc` POST
   helper, one page RPC per load, SQL preview/default data, and no accounting
   calculations or authoritative validation.
7. **Servant removal:** `app/Main.hs`, `plutus.cabal`, and `cabal.project` are
   removed. The Node static server serves Elm and proxies only transport.
8. **Boundary verification:** `tests/api.sh` exercises every RPC, confirms
   base tables are not exposed, checks the static-file boundary, and runs
   Playwright through all reports and real create/replace/update workflows at
   desktop and mobile sizes.

## Verification

The final verification completed successfully on 2026-08-05 using PostgreSQL
17 for the test server, PostgREST 14.16, Node.js 22.22.2, npm 10.9.7, Elm
0.19.1, and Playwright 1.62.1:

```sh
tests/run.sh
tests/api.sh
npm run build
```

The API suite creates an isolated database, launches temporary PostgREST and
static-server processes, and removes them on exit. Its browser phase covers
desktop and 390-pixel mobile viewports and rejects document overflow, console
errors, and page errors.

The final source-boundary searches also pass:

```sh
rg -n 'Servant|servant-server|app/Main.hs' .
rg -n 'Http\.(get|post|request)' frontend/src/Main.elm
rg -n -i 'sum|balance|vat|tax' frontend/src/Main.elm
```

The first search has no live implementation matches. Elm has one shared
`Http.post` helper. Its remaining balance/pretax terms are fields and display
labels sourced from SQL rather than client-side accounting decisions.

## Running the Application

Follow `README.md` for database creation and dependency installation. The
normal development processes are:

```sh
PLUTUS_DATABASE=finances scripts/run-postgrest
npm run serve
```

Then open `http://127.0.0.1:8080/`.
