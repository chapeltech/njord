# Plutus

Plutus is a PostgreSQL-backed personal-accounting application. PostgreSQL owns
the ledger rules, mutations, page models, and reports; PostgREST exposes only a
dedicated `api` schema; Elm provides the browser presentation.

The database also retains SQL support for business-expense metadata, VAT,
imports, and other company-accounting work. Those features are intentionally
outside the current web UI.

## Requirements

- PostgreSQL 17 (older supported releases may work, but CI-style development
  testing currently uses 17)
- Node.js 20 or later and npm
- Chromium for the Playwright browser smoke test (`npx playwright install chromium`)
- `curl`, `sha256sum`, and `xz` for the pinned PostgREST installer

The project pins PostgREST 14.16. On Linux x86-64, install it locally with:

```sh
scripts/install-postgrest
```

Set `POSTGREST_BIN` instead if PostgREST 14.16 is installed elsewhere or the
platform is not Linux x86-64.

## Set up a development database

```sh
createdb finances
psql -v ON_ERROR_STOP=1 -d finances -f sql/plutus.sql
npm install
npx playwright install chromium
npm run build
```

The SQL loader is deliberately repeatable: it recreates Plutus objects and
loads the schema, reference data, accounting functions and reports, and the
PostgREST API.

## Run the application

Start PostgREST in one terminal:

```sh
PLUTUS_DATABASE=finances scripts/run-postgrest
```

Start the static Elm server in another:

```sh
npm run serve
```

Open `http://127.0.0.1:8080/`. The static server proxies same-origin `/rpc`
requests to PostgREST at `http://127.0.0.1:3000`; it contains no accounting
logic.

Useful overrides are:

- `PLUTUS_DATABASE` and `PLUTUS_DATABASE_ROLE` for the PostgREST launcher;
- `PGRST_DB_URI` and any standard `PGRST_*` setting for PostgREST itself;
- `PLUTUS_UI_HOST`, `PLUTUS_UI_PORT`, and `PLUTUS_POSTGREST_URL` for the static
  server.

Both development servers bind to `127.0.0.1` by default. Authentication is
deliberately deferred for this localhost phase.

## HTTP API

Only functions in the `api` schema are exposed, under PostgREST `/rpc` routes.
Base tables and internal reports are not HTTP resources.

Each UI page is returned by one canonical table-returning function:

- `shell_page`
- `ledger_page`
- `general_journal_page`
- `balance_sheet_page`
- `trial_balance_page`
- `profit_loss_page`
- `cash_flow_page`
- `add_book_page`
- `add_account_page`

Report page contexts include authoritative date-range, cash-account, and
missing-valuation messages. Date-valued `as_of` and `to` parameters include
the complete selected calendar day.

Public mutations are:

- `create_book`
- `create_account`
- `preview_transaction`
- `create_transaction`
- `replace_transaction`
- `update_ledger_line`

For example, fetch a ledger page in one request:

```sh
curl -X POST http://127.0.0.1:3000/rpc/ledger_page \
  -H 'content-type: application/json' \
  -d '{"p_book_id":"personal","p_account_id":"Current Account"}'
```

Preview a transaction without writing it:

```sh
curl -X POST http://127.0.0.1:3000/rpc/preview_transaction \
  -H 'content-type: application/json' \
  -d '{
    "p_book_id":"personal",
    "p_transaction":{
      "date":"2026-01-31",
      "resolved":true,
      "comment":"Example",
      "lines":[
        {"account":"Current Account","amount":-25},
        {"account":"Expenses","amount":25}
      ]
    }
  }'
```

Expected validation failures are PostgreSQL errors with a stable code in the
PostgREST `details` field. Constraints remain the final protection for direct
SQL writes.

## Direct SQL use

The seed data creates the `personal` book and standard accounts. Open an asset
account with an opening balance:

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

Post a simple transfer:

```sql
CALL create_simple_xaction(
    'personal',
    '2026-01-15',
    'Current Account',
    'Expenses',
    -42.50
);
```

Useful SQL report surfaces include:

```sql
SELECT * FROM ledger('personal', 'Current Account');
SELECT * FROM general_journal WHERE book_id = 'personal';
SELECT * FROM bsheet_report('personal', '2026-01-31 23:59:59.999999');
SELECT * FROM tb_report('personal', '2026-01-31 23:59:59.999999');
SELECT * FROM pl_report('personal', '2026-01-01', '2026-01-31 23:59:59.999999');
SELECT * FROM cf_report('personal', '2026-01-01', '2026-01-31 23:59:59.999999');
```

The core report functions accept timestamps and use exact inclusive bounds.
Use an end-of-day timestamp for a whole calendar day, as above. The `api` page
functions accept dates and apply that calendar-day conversion automatically.

Incomplete imports remain in `xaction_unresolved` until classified and
balanced. Resolved transactions must contain at least two non-zero, finite lines,
must not repeat an account, and must balance separately for every asset.

## Tests

With a reachable PostgreSQL server:

```sh
tests/run.sh
tests/api.sh
npm run build
```

The SQL and API scripts create isolated temporary databases and remove them on
exit. `tests/api.sh` starts a temporary PostgREST process and static server,
checks every page and mutation RPC, checks structured validation failures, and
confirms that base tables are not exposed. Its browser phase performs real
create/replace/update saves, exercises every report and both add forms, and
checks desktop and mobile layouts.

Set the normal libpq variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`) if
needed. If direct access is unavailable but passwordless `sudo -u postgres` is
available, the scripts use it automatically.

## Design

See [ARCHITECTURE.md](ARCHITECTURE.md) for the page-function contract,
accounting boundary, static-server role, and future authentication seam.
