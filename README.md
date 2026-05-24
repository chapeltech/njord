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

The seed data creates a default book named `personal`.  Add another book and
its standard accounts with:

```sql
INSERT INTO books (id, name, reporting_asset)
VALUES ('business', 'Business', 'GBP');

INSERT INTO accts (book_id, id, type, atype)
VALUES
    ('business', 'Opening Balance', 'Q', 'GBP'),
    ('business', 'Income', 'I', 'GBP'),
    ('business', 'Expenses', 'E', 'GBP');
```

Accounts belong to one book, so account names only need to be unique inside a
book.

Open an account with an opening balance:

```sql
CALL open_account(
    'personal',
    'Current Account',
    '2026-01-01',
    'A',
    'GBP',
    1000.00
);
```

Open a pretax asset account:

```sql
CALL open_account_pretax('personal', 'Pension', '2026-01-01', 'GBP', 50000.00);
```

Mark an asset account as cash or cash-equivalent so it participates in the
Cash Flow report:

```sql
INSERT INTO cash_accounts (book_id, acct)
VALUES ('personal', 'Current Account');
```

Move money between two accounts in the same asset:

```sql
CALL create_simple_xaction(
    'personal',
    '2026-01-15',
    'Current Account',
    'Expenses',
    -42.50
);
```

Create a split transaction:

```sql
CALL create_xaction(
    'personal',
    '2026-01-31',
    TRUE,
    ROW('Current Account', 2200.00, 'Salary payment')::xaction_elem,
    ROW('Income', -2200.00, 'Salary payment')::xaction_elem
);
```

The `TRUE` argument marks the transaction resolved.  Imported or incomplete
transactions should be marked unresolved until they are balanced and
classified.

## Business Expenses

Business expense data is metadata over normal double-entry transactions.  The
ledger remains the accounting truth; the extra tables record suppliers,
invoice references, VAT treatment, Corporation Tax treatment, business
purpose, and receipts.

Expense accounts can carry default VAT and tax treatment:

```sql
INSERT INTO accts (
    book_id, id, type, atype,
    default_vat_code, default_tax_treatment
) VALUES (
    'business', 'JAGUAR Expenses', 'E', 'GBP',
    'UK_STANDARD_BLOCKED', 'ALLOWABLE_REVENUE'
);
```

Create the actual accounting entry as usual:

```sql
CALL create_xaction(
    'business',
    '2026-04-10',
    TRUE,
    ROW('Current Account', -24.00, 'JAGUAR car wash')::xaction_elem,
    ROW('JAGUAR Expenses', 24.00, 'JAGUAR car wash')::xaction_elem
);
```

Attach the business expense header to the transaction:

```sql
INSERT INTO vendors (book_id, id, name)
VALUES ('business', 'sparkle-wash', 'Sparkle Wash Ltd');

INSERT INTO business_expenses (
    book_id, xid, vendor_id, invoice_number, invoice_date, business_purpose
)
SELECT book_id, xid, 'sparkle-wash', 'SW-100', '2026-04-10',
       'Company car cleaning'
FROM xactions
WHERE book_id = 'business'
  AND date = '2026-04-10'
  AND comment = 'JAGUAR car wash';
```

Line-level rows are optional.  If a line has no override, reports use the
account defaults.  Add a line override only for exceptions, such as insurance
with no VAT:

```sql
INSERT INTO business_expense_lines (xaction_bit_id, vat_code, note)
SELECT xaction_bits.id, 'NO_VAT', 'Insurance is VAT exempt/no VAT on invoice'
FROM xaction_bits
JOIN xactions
  ON xactions.book_id = xaction_bits.book_id
 AND xactions.xid = xaction_bits.xid
WHERE xaction_bits.book_id = 'business'
  AND xaction_bits.acct = 'JAGUAR Expenses'
  AND xactions.comment = 'JAGUAR insurance';
```

Use `business_expense_detail` to see the effective treatment after defaults
and overrides are applied:

```sql
SELECT *
FROM business_expense_detail
WHERE book_id = 'business'
ORDER BY date, xid, account;
```

## Reports

Current balance sheet:

```sql
SELECT * FROM balance_sheet WHERE book_id = 'personal';
```

Report-shaped balance sheet with sections and totals:

```sql
SELECT *
FROM balance_sheet_report
WHERE book_id = 'personal'
ORDER BY section_order, row_order, account;
```

Balance sheet as of a date:

```sql
SELECT * FROM bsheet('personal', '2026-01-31');
```

Report-shaped balance sheet as of a date:

```sql
SELECT * FROM bsheet_report('personal', '2026-01-31');
```

Trial Balance:

```sql
SELECT *
FROM trial_balance_report
WHERE book_id = 'personal'
ORDER BY row_order, account;
```

Trial Balance as of a date:

```sql
SELECT * FROM tb_report('personal', '2026-01-31');
```

Report-shaped Profit & Loss:

```sql
SELECT *
FROM profit_loss_report
WHERE book_id = 'personal'
ORDER BY section_order, row_order, account;
```

Profit & Loss for a period:

```sql
SELECT * FROM pl_report('personal', '2026-01-01', '2026-01-31');
```

Report-shaped Cash Flow:

```sql
SELECT *
FROM cash_flow_report
WHERE book_id = 'personal'
ORDER BY section_order, row_order, account;
```

Cash Flow for a period:

```sql
SELECT * FROM cf_report('personal', '2026-01-01', '2026-01-31');
```

Ledger for one account:

```sql
SELECT * FROM ledger('personal', 'Current Account');
```

Full ledger:

```sql
SELECT *
FROM full_ledger
WHERE book_id = 'personal'
ORDER BY acct, date, xid;
```

General Journal:

```sql
SELECT *
FROM general_journal
WHERE book_id = 'personal'
ORDER BY date, xid, line_order, line_id;
```

In the General Journal, `description` is the transaction header from
`xactions.comment`; `memo` is the individual line comment from
`xaction_bits.comment`.  Simple two-line transactions should store their text
in `description` and leave line memos empty.

Latest GBP valuations:

```sql
SELECT * FROM current_valuations ORDER BY src;
```

## Tests

Run the SQL test suite with:

```sh
tests/run.sh
```

Run the REST API smoke test with:

```sh
tests/api.sh
```

The test runners create temporary PostgreSQL databases, load the schema, run
assertions, and drop the databases afterwards.  If the current user cannot
connect directly but has passwordless sudo access to the `postgres` system
user, the runners use that automatically.

## REST Server

The server is a thin Servant interface over the PostgreSQL schema.  It expects
the database to have already been loaded with `sql/plutus.sql`.

The current Cabal project is configured for GHC 9.6.7 because the installed
default GHC is newer than the released Servant dependency bounds.  The
PostgreSQL client development headers are also required, for example
`libpq-dev` on Debian.

Build and run the Servant server with:

```sh
npm install
npm run build
cabal build plutus-server
PLUTUS_DATABASE_URL='dbname=finances' cabal run plutus-server
```

The server listens on port `8080` by default.  Set `PLUTUS_PORT` to override
that.  The Elm app is served from `/` by the same server.

Available endpoints:

- `GET /health`
- `GET /books`
- `POST /books`
- `GET /books/:book_id/accounts`
- `POST /books/:book_id/accounts`
- `POST /books/:book_id/transactions`
- `GET /books/:book_id/ledger/:account_id`
- `GET /books/:book_id/reports/balance-sheet`
- `GET /books/:book_id/reports/balance-sheet?as_of=2026-01-31`
- `GET /books/:book_id/reports/trial-balance`
- `GET /books/:book_id/reports/trial-balance?as_of=2026-01-31`
- `GET /books/:book_id/reports/profit-loss`
- `GET /books/:book_id/reports/profit-loss?from=2026-01-01&to=2026-01-31`
- `GET /books/:book_id/reports/cash-flow`
- `GET /books/:book_id/reports/cash-flow?from=2026-01-01&to=2026-01-31`
- `GET /books/:book_id/reports/general-journal`
- `GET /books/:book_id/balance-sheet`
- `GET /books/:book_id/balance-sheet?as_of=2026-01-31`

Create a book:

```sh
curl -X POST http://127.0.0.1:8080/books \
  -H 'content-type: application/json' \
  -d '{"id":"business","name":"Business","reporting_asset":"GBP"}'
```

Create an account:

```sh
curl -X POST http://127.0.0.1:8080/books/personal/accounts \
  -H 'content-type: application/json' \
  -d '{"id":"Current Account","type":"A","asset":"GBP"}'
```

Create a transaction:

```sh
curl -X POST http://127.0.0.1:8080/books/personal/transactions \
  -H 'content-type: application/json' \
  -d '{
        "date": "2026-01-31",
        "resolved": true,
        "lines": [
          {"account": "Current Account", "amount": 25.00},
          {"account": "Income", "amount": -25.00}
        ]
      }'
```

## Direct SQL Workflow

The package assumes users are comfortable with SQL.  The normal workflow is:

1. Load the schema with `psql -f sql/plutus.sql`.
2. Add books, accounts, and transactions using SQL procedures.
3. Use views and table-returning functions for reports.
4. Keep incomplete imported rows unresolved until reconciled.
5. Add new reports as SQL views or functions.

All durable accounting rules should be enforced by PostgreSQL itself.  Future
interfaces should remain thin clients over this SQL representation.
