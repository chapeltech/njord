# Plutus

Plutus is a SQL-only financial management package for PostgreSQL.  Use `psql`
directly to create accounts, record transactions, import data, and run
reports.

## Setup

Create a database and load the schema:

```sh
createdb finances
psql -d finances -f sql/plutus.sql
```

The loader resets and recreates the schema using:

- `sql/schema.sql`
- `sql/currencies.sql`
- `sql/intro-accounts.sql`
- `sql/updating.sql`
- `sql/reports.sql`

## Basic Use

Start an interactive SQL session:

```sh
psql -d finances
```

Open an account with an opening balance:

```sql
CALL open_account('Current Account', '2026-01-01', 'A', 'GBP', 1000.00);
```

Open a pretax asset account:

```sql
CALL open_account_pretax('Pension', '2026-01-01', 'GBP', 50000.00);
```

Move money between two accounts in the same asset:

```sql
CALL create_simple_xaction(
    '2026-01-15',
    'Current Account',
    'Expenses',
    -42.50
);
```

Create a split transaction:

```sql
CALL create_xaction(
    '2026-01-31',
    TRUE,
    ROW('Current Account', 2200.00, 'Salary payment')::xaction_elem,
    ROW('Income', -2200.00, 'Salary payment')::xaction_elem
);
```

The `TRUE` argument marks the transaction resolved.  Imported or incomplete
transactions should be marked unresolved until they are balanced and
classified.

## Reports

Current balance sheet:

```sql
SELECT * FROM balance_sheet;
```

Balance sheet as of a date:

```sql
SELECT * FROM bsheet('2026-01-31');
```

Ledger for one account:

```sql
SELECT * FROM ledger('Current Account');
```

Full ledger:

```sql
SELECT * FROM full_ledger ORDER BY acct, date, xid;
```

Latest GBP valuations:

```sql
SELECT * FROM current_valuations ORDER BY src;
```

## Tests

Run the SQL test suite with:

```sh
tests/run.sh
```

The test runner creates a temporary PostgreSQL database, loads the schema,
runs SQL assertions, and drops the database afterwards.  If the current user
cannot connect directly but has passwordless sudo access to the `postgres`
system user, the runner uses that automatically.

## Direct SQL Workflow

The package assumes users are comfortable with SQL.  The normal workflow is:

1. Load the schema with `psql -f sql/plutus.sql`.
2. Add accounts and transactions using SQL procedures.
3. Use views and table-returning functions for reports.
4. Keep incomplete imported rows unresolved until reconciled.
5. Add new reports as SQL views or functions.

All durable accounting rules should be enforced by PostgreSQL itself.  Future
interfaces should remain thin clients over this SQL representation.
