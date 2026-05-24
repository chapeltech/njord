# Architecture

Plutus is a SQL-only financial management package.  PostgreSQL is the
application boundary: the schema, constraints, mutation procedures, import
staging, and reports should all live in SQL.

There is intentionally no command-line wrapper in the core package.  The
Servant server is a thin optional HTTP interface over the same PostgreSQL
schema that an interactive `psql` user uses.  User interfaces may make data
entry pleasant, but they must not become the place where accounting rules are
enforced.

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
- `xactions` stores transaction headers within a book.
- `xaction_bits` stores transaction lines, each attached to one account.
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
- Amounts and valuation rates should use exact numeric types, not floating
  point types.
- Duplicate reference data should be prevented where it would change report
  meaning, such as duplicate valuations for the same date/source/destination.

The key missing invariant is resolved transaction balance.  The intended rule
is that a resolved transaction's lines sum to zero per book and per asset.
Transactions that do not yet balance should exist only while listed in
`xaction_unresolved`.

This is best implemented as a deferred SQL constraint trigger so all lines of
a transaction can be inserted or changed inside one database transaction
before the balance check runs.

## Mutation Path

Data changes should be made through SQL procedures where that improves
ergonomics:

- account opening procedures create the account and opening balance entry;
- transaction procedures create split or simple transactions;
- import procedures turn staging rows into unresolved ledger rows;
- later reconciliation procedures should classify and resolve imports.

Procedures are convenience APIs, not a substitute for constraints.  Direct
table manipulation by an experienced SQL user should still be protected by
database constraints.

All public mutation procedures take a `book_id` argument.  A future UI may
select a default book for a user, but SQL calls should remain explicit about
which book is being changed.

## Reporting

Reports should remain SQL-native:

- views for current state;
- table-returning SQL functions for parameterized reports;
- audit views for unresolved, unbalanced, or incomplete data;
- valuation-aware views for assets held in non-reporting currencies.

Historical reports should use valuations as of the report date, not simply the
latest valuation available today.

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
