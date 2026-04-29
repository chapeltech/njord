# Architecture

Plutus is a SQL-only financial management package.  PostgreSQL is the
application boundary: the schema, constraints, mutation procedures, import
staging, and reports should all live in SQL.

There is intentionally no command-line wrapper or application layer in the
core package.  Future user interfaces can call the same SQL procedures and
queries that an interactive `psql` user calls, but they must not become the
place where accounting rules are enforced.

## Data Model

The schema is centered on a double-entry ledger:

- `asset` stores currencies, metals, securities, or other units of account.
- `valuations` stores dated exchange or valuation rates between assets.
- `acct_types` stores the standard account classes:
  assets, liabilities, expenses, income, and equity.
- `accts` stores named accounts and the asset each account is denominated in.
- `xactions` stores transaction headers.
- `xaction_bits` stores transaction lines, each attached to one account.
- `xaction_unresolved` marks imported or incomplete transactions that still
  require classification or balancing.
- `xaction_tags` stores user-defined tags for reporting and classification.

Reports are SQL views or SQL functions over those base tables.  Current
examples include balance-sheet and ledger views/functions.

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
- Every resolved transaction must balance.
- Imported one-sided transactions must be marked unresolved until completed.
- A transaction should not be both unresolved and treated as final.
- Amounts and valuation rates should use exact numeric types, not floating
  point types.
- Duplicate reference data should be prevented where it would change report
  meaning, such as duplicate valuations for the same date/source/destination.

The key missing invariant is resolved transaction balance.  The intended rule
is that a resolved transaction's lines sum to zero per asset.  Transactions
that do not yet balance should exist only while listed in
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

## Reporting

Reports should remain SQL-native:

- views for current state;
- table-returning SQL functions for parameterized reports;
- audit views for unresolved, unbalanced, or incomplete data;
- valuation-aware views for assets held in non-reporting currencies.

Historical reports should use valuations as of the report date, not simply the
latest valuation available today.
