# Architecture

Plutus is a SQL-only financial management package.  PostgreSQL is the
application boundary: the schema, constraints, mutation procedures, import
staging, and reports should all live in SQL.

There is intentionally no command-line wrapper in the core package.
PostgREST is the HTTP adapter over the same PostgreSQL schema that an
interactive `psql` user uses.  User interfaces may make data entry pleasant,
but they must not become the place where accounting rules are enforced.

The current UI delivery scope is simple personal accounting: books, accounts,
balanced and split transactions, account ledgers, the General Journal, and
basic financial reports.  Business-expense, VAT, invoice, import, and other
company-accounting SQL may remain in the database, but those features are not
part of the current PostgREST and Elm migration.

## Database-Backed UI Contract

Every UI page must be represented by one canonical named PostgreSQL view or
table-returning function.  PostgreSQL views do not accept arguments, so in
this document a "parameterized view" means a function declared with `RETURNS
TABLE`.  Use an ordinary view when no runtime parameters are required.  A
persistent application surface such as the top navigation bar is treated as a
page for this purpose and has its own database view model.

The page function returns the complete model needed to render that page.  This
includes its tables, forms, menus, completion lists, report rows, computed
totals, editability state, and validation state.  For example,
`ledger_page(book_id, account_id)` returns both ledger rows and valid transfer
account choices.  Supporting views may be used inside the page function, but
the client must not call them separately and reconstruct the page itself.

When a page contains heterogeneous data, its function returns discriminated
component rows with stable component names, ordering keys, row identities, and
JSONB payloads.  This preserves a single relational page boundary without
forcing unrelated component types into one wide record.

The columns returned by these database objects are the application's view
model.  They should contain stable row identities, display values, ordering
keys, computed values, and any state needed to decide which edits are valid.
The same call made through `psql` must expose the same rows and meaning as the
web UI.

Edits must be represented by PostgreSQL procedures or functions.  An edit
operation accepts the user's complete intent, performs all checks and related
writes atomically, and returns either the resulting view rows or a database
error.  Constraints remain the final protection even when a procedure is the
normal mutation path.

The UI owns only presentation and editing mechanics:

- layout, styling, accessibility, focus, selection, and transient form state;
- formatting database values for display;
- collecting an edit and sending it to the server;
- rendering rows and errors returned by PostgreSQL.

The UI must not own accounting arithmetic, account classification, balancing,
VAT treatment, report grouping, workflow state, or authoritative validation.
If an immediate preview is useful, such as a split imbalance or recoverable
VAT amount, the preview should be returned by a PostgreSQL function rather
than reimplemented in Elm.

## HTTP Boundary

PostgREST exposes a dedicated `api` schema.  Base accounting tables and
internal helper views are not HTTP resources.  Parameterized page views and
mutations are PostgreSQL functions in the exposed schema and appear under
PostgREST's `/rpc` routes.  Ordinary views may be exposed only when they are a
deliberate, parameterless public resource.

A normal page request should:

1. decode and type-check HTTP path, query, and body values;
2. call exactly one named PostgreSQL page function;
3. return its rows without another application-services layer.

Mutations use `POST` requests to PostgreSQL functions in the same schema.
PostgREST runs each request in a database transaction, returns PostgreSQL
errors to the client, and rolls the transaction back on failure.  Public HTTP
mutations must therefore be functions; direct-SQL procedures may remain as
conveniences for `psql` users.

PostgREST must not be supplemented by code that performs SQL-domain
arithmetic, chooses accounts, normalizes transaction descriptions, synthesizes
report rows, or enforces accounting rules.  Those behaviours belong in the
database so direct SQL, imports, the REST API, and future clients cannot
disagree.

During UI development PostgREST binds only to `127.0.0.1`; access control is
not part of the current work.  The intended production authentication boundary
is an HTTP/Negotiate-capable reverse proxy using GSSAPI.  It will pass an
authenticated principal through a trusted request context to PostgreSQL,
where authorization can be enforced without changing page or mutation
contracts.

PostgREST does not serve the Elm application.  A separate static-file server
serves the compiled Elm assets and proxies API requests to PostgREST on the
same origin.  This server contains no accounting or application logic.

## External Components

Some capabilities do not belong naturally in PostgreSQL.  Invoice scanning,
OCR, file conversion, malware scanning, and similar work may be implemented as
server-side components.  They must not run as authoritative business logic in
the browser.

An external component should produce untrusted candidate data and write it to
a staging interface.  PostgreSQL then applies accounting policy, validates and
normalizes the candidate, and exposes the result through a view for review or
posting.  The component may extract text from an invoice; it must not decide
the final VAT treatment, expense account, tax allowability, or ledger posting.

The default design rule is simple: if PostgreSQL can express the behaviour
clearly and testably, implement it in SQL.  Move work outside PostgreSQL only
for a concrete capability or operational reason, and document that exception.

## Dependency Direction

Dependencies flow in one direction:

`Elm presentation -> PostgREST -> PostgreSQL api schema -> base tables`

Neither Elm nor PostgREST is a second source of accounting truth.  A feature
is not complete until its SQL page function, SQL mutation path, database
constraints, and SQL tests exist.  REST tests verify transport fidelity, and
UI tests verify presentation and editing behaviour rather than accounting
correctness.

## Data Model

The schema is centered on a double-entry ledger:

- `asset` stores currencies, metals, securities, or other units of account.
- `valuations` stores dated exchange or valuation rates between assets.
- `acct_types` stores the standard account classes:
  assets, liabilities, expenses, income, and equity.
- `books` stores independent ledgers, such as personal or business books.
- `accts` stores named accounts and the asset each account is denominated in.
  Each account belongs to exactly one book.
- `cash_accounts` marks which asset accounts are cash or cash equivalents for
  Cash Flow reporting.
- `vat_codes` and `expense_tax_treatments` define reusable VAT recovery and
  Corporation Tax treatment policies for business expense reporting.
- `xactions` stores transaction headers within a book.
- `xaction_bits` stores transaction lines, each attached to one account.
- `vendors`, `business_expenses`, and `business_expense_lines` attach business
  expense metadata to normal ledger transactions and lines.
- `xaction_unresolved` marks imported or incomplete transactions that still
  require classification or balancing.
- `xaction_tags` stores user-defined tags for reporting and classification.

Reports are SQL views or SQL functions over those base tables.  Current
examples include ledger/register, General Journal, balance-sheet, Profit &
Loss, and Cash Flow views/functions.

## SQL Is The Authority

All accounting invariants should be enforced inside PostgreSQL by schema
constraints, foreign keys, triggers, deferred constraint triggers, domains,
and stored procedures.  A user interface may make data entry pleasant, but it
must not be required for correctness.

The goal is that direct SQL use, batch imports, and any future UI all share
the same safety properties.

## Accounting Constraints

The database should enforce these accounting rules:

- Every transaction line must reference an existing account.
- Every account must reference an existing account type and asset.
- Every account must belong to exactly one book.
- A transaction line must reference an account in the same book as its
  transaction.
- A transaction may contain a given account only once.  If two split lines
  would use the same account, they should be combined before insertion.
- A cash-flow cash account must be an asset account.
- Every resolved transaction must balance.
- Imported one-sided transactions must be marked unresolved until completed.
- A transaction should not be both unresolved and treated as final.
- Amounts and valuation rates use finite, exact numeric types rather than
  floating point types; transaction-line amounts must also be non-zero.
- Duplicate reference data should be prevented where it would change report
  meaning, such as duplicate valuations for the same date/source/destination.

Resolved transaction balance is enforced by a deferred constraint trigger. A
resolved transaction's lines must sum to zero per book and per asset.
Transactions that do not yet balance should exist only while listed in
`xaction_unresolved`.

The deferred trigger allows all lines of a transaction to be inserted or
changed inside one database transaction before the balance check runs.

## Mutation Path

Data changes should be made through SQL functions or procedures where that
improves ergonomics:

- account opening procedures create the account and opening balance entry;
- transaction procedures create split or simple transactions;
- import procedures turn staging rows into unresolved ledger rows;
- later reconciliation procedures should classify and resolve imports.

PostgREST mutation endpoints are functions because PostgREST exposes functions
through `/rpc`, not PostgreSQL procedures.  Procedures may remain as
convenience APIs for direct SQL use.  Neither is a substitute for constraints;
direct table manipulation by an experienced SQL user should still be protected
by database constraints.

All public mutation procedures take a `book_id` argument.  A future UI may
select a default book for a user, but SQL calls should remain explicit about
which book is being changed.

## Business Expense Metadata

Business expenses are not a second ledger.  They are annotations over
ordinary `xactions` and `xaction_bits` rows.  The posting lines remain the
accounting source of truth; expense metadata records vendor, invoice, business
purpose, receipt, VAT recovery, and Corporation Tax treatment.

Expense accounts may carry default VAT and tax treatment.  This supports
fast entry for accounts such as `JAGUAR Expenses`, where most lines share the
same VAT and tax behaviour.  `business_expense_lines` may override those
defaults for real exceptions, such as insurance with no VAT or a lease cost
with partial VAT recovery.

Reports should compute effective treatment with line override first, account
default second.  VAT recovery and Corporation Tax allowability are separate
concepts and should remain separate fields.

## Reporting

Reports should remain SQL-native:

- views for current state;
- table-returning SQL functions for parameterized reports;
- audit views for unresolved, unbalanced, or incomplete data;
- valuation-aware views for assets held in non-reporting currencies.

Historical reports should use valuations as of the report date, not simply the
latest valuation available today.

Date-valued UI parameters are calendar-day boundaries.  An `as_of` or `to`
date includes postings throughout that final day even though transaction
storage uses timestamps.  Period page contexts return authoritative range,
cash-account configuration, and missing-valuation messages.  The browser
renders those messages; it does not infer whether a report is complete.

The account ledger/register is account-perspective reporting: it may show
transfer accounts, deposit/withdrawal columns, and a running account balance.
The General Journal is transaction-perspective reporting: it shows every line
of each transaction with debit and credit columns and no running balance.
Transaction descriptions belong to `xactions.comment`; line memos belong to
`xaction_bits.comment`.  Simple two-line transactions should not duplicate the
transaction description onto their component lines.

The Trial Balance is the double-entry sanity report.  It presents every
account balance as either a debit or a credit and includes a total row; those
totals should match when posted data is structurally balanced.  A difference
row indicates ledger data that needs audit or stronger SQL constraints.

Cash Flow reports use explicit `cash_accounts` rows to identify cash and
cash-equivalent accounts.  Cash movements are classified by the non-cash side
of each transaction: income and expense accounts are operating activities,
asset accounts are investing activities, and liability or equity accounts are
financing activities.
