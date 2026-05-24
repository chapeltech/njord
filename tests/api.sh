#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

DB="${PLUTUS_API_TEST_DB:-plutus_api_test_$$}"
PORT="${PLUTUS_API_TEST_PORT:-18080}"
PSQL="${PSQL:-psql}"
CREATEDB="${CREATEDB:-createdb}"
DROPDB="${DROPDB:-dropdb}"
CABAL="${CABAL:-cabal}"
CURL="${CURL:-curl}"
NPM="${NPM:-npm}"

SQL_TMP=
SERVER_TMP=
SERVER_PID=

if "$PSQL" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
	run()
	{
		"$@"
	}
	run_server()
	{
		cd "$SERVER_TMP" &&
		    env PLUTUS_DATABASE_URL="dbname=$DB" \
		    PLUTUS_PORT="$PORT" ./plutus-server
	}
elif command -v sudo >/dev/null 2>&1 &&
    sudo -n -u postgres "$PSQL" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1
then
	run()
	{
		sudo -n -u postgres "$@"
	}
	run_server()
	{
		cd "$SERVER_TMP" &&
		    sudo -n -u postgres env PLUTUS_DATABASE_URL="dbname=$DB" \
		    PLUTUS_PORT="$PORT" ./plutus-server
	}
else
	echo "Could not connect to PostgreSQL." >&2
	echo "Set PGUSER/PGHOST or run with sudo access to the postgres user." >&2
	exit 1
fi

cleanup()
{
	if [ -n "$SERVER_PID" ]; then
		run kill "$SERVER_PID" >/dev/null 2>&1 || \
		    kill "$SERVER_PID" >/dev/null 2>&1 || true
	fi
	if command -v lsof >/dev/null 2>&1; then
		for pid in $(run lsof -t -i :"$PORT" 2>/dev/null || true); do
			run kill "$pid" >/dev/null 2>&1 || true
		done
	fi
	run "$DROPDB" --if-exists "$DB" >/dev/null 2>&1 || true
	if [ -n "$SQL_TMP" ]; then
		rm -rf "$SQL_TMP"
	fi
	if [ -n "$SERVER_TMP" ]; then
		rm -rf "$SERVER_TMP"
	fi
}

trap cleanup EXIT HUP INT TERM

cleanup

"$NPM" run build >/dev/null
"$CABAL" build plutus-server >/dev/null
SERVER_BIN=$("$CABAL" list-bin plutus-server)

SQL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/plutus-api-sql.XXXXXX")
SERVER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/plutus-api-server.XXXXXX")
cp sql/*.sql "$SQL_TMP"/
mkdir "$SERVER_TMP/frontend"
cp frontend/index.html frontend/style.css frontend/app.js "$SERVER_TMP/frontend"/
cp "$SERVER_BIN" "$SERVER_TMP"/plutus-server
chmod a+rx "$SQL_TMP" "$SERVER_TMP" "$SERVER_TMP/frontend" \
    "$SERVER_TMP"/plutus-server
chmod a+r "$SQL_TMP"/*.sql
chmod a+r "$SERVER_TMP"/frontend/*

run "$CREATEDB" "$DB"
run env PGOPTIONS="-c client_min_messages=warning" \
    "$PSQL" -q -v ON_ERROR_STOP=1 -X -d "$DB" \
    -f "$SQL_TMP/plutus.sql" >/dev/null

run_server >"$SERVER_TMP/server.log" 2>&1 &
SERVER_PID=$!

BASE="http://127.0.0.1:$PORT"

for _ in 1 2 3 4 5 6 7 8 9 10; do
	if "$CURL" -fsS "$BASE/health" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

assert_contains()
{
	label="$1"
	body="$2"
	needle="$3"

	if ! printf '%s' "$body" | grep -F "$needle" >/dev/null; then
		echo "not ok - $label" >&2
		echo "$body" >&2
		echo "--- server log ---" >&2
		cat "$SERVER_TMP/server.log" >&2
		exit 1
	fi

	echo "ok - $label"
}

health=$("$CURL" -fsS "$BASE/health")
assert_contains "health endpoint" "$health" '"status":"ok"'

index=$("$CURL" -fsS "$BASE/")
assert_contains "Elm app index" "$index" '<title>Plutus</title>'

books=$("$CURL" -fsS "$BASE/books")
assert_contains "books endpoint lists personal book" "$books" '"id":"personal"'

business=$("$CURL" -fsS -X POST "$BASE/books" \
    -H 'content-type: application/json' \
    -d '{"id":"business","name":"Business","reporting_asset":"GBP"}')
assert_contains "book creation endpoint" "$business" '"id":"business"'

acct=$("$CURL" -fsS -X POST "$BASE/books/personal/accounts" \
    -H 'content-type: application/json' \
    -d '{"id":"Broker USD","type":"A","asset":"USD"}')
assert_contains "account creation endpoint" "$acct" '"id":"Broker USD"'

run "$PSQL" -q -v ON_ERROR_STOP=1 -X -d "$DB" \
    -c "INSERT INTO cash_accounts (book_id, acct) VALUES ('personal', 'Broker USD')" \
    >/dev/null

expense=$("$CURL" -fsS -X POST "$BASE/books/personal/accounts" \
    -H 'content-type: application/json' \
    -d '{"id":"USD Expenses","type":"E","asset":"USD"}')
assert_contains "expense account creation endpoint" "$expense" '"id":"USD Expenses"'

fees=$("$CURL" -fsS -X POST "$BASE/books/personal/accounts" \
    -H 'content-type: application/json' \
    -d '{"id":"USD Fees","type":"E","asset":"USD"}')
assert_contains "second expense account creation endpoint" "$fees" '"id":"USD Fees"'

xaction=$("$CURL" -fsS -X POST "$BASE/books/personal/transactions" \
    -H 'content-type: application/json' \
    -d '{
          "date": "2026-01-15",
          "resolved": true,
          "lines": [
            {"account": "Broker USD", "amount": 10.00},
            {"account": "USD Expenses", "amount": -10.00}
          ]
        }')
assert_contains "transaction creation endpoint" "$xaction" '"book_id":"personal"'

xid=$(printf '%s\n' "$xaction" | sed -n 's/.*"xid":\([0-9][0-9]*\).*/\1/p')
if [ -z "$xid" ]; then
	echo "not ok - transaction id was returned" >&2
	echo "$xaction" >&2
	exit 1
fi

"$CURL" -fsS -X PATCH "$BASE/books/personal/transactions/$xid/lines/Broker%20USD" \
    -H 'content-type: application/json' \
    -d '{"date":"2026-01-20","description":"Updated broker memo"}' \
    >/dev/null

"$CURL" -fsS -X PATCH "$BASE/books/personal/transactions/$xid" \
    -H 'content-type: application/json' \
    -d '{
          "date": "2026-01-21",
          "resolved": true,
          "comment": "Patched transaction",
          "lines": [
            {"account": "Broker USD", "amount": 12.00, "comment": "Broker patched"},
            {"account": "USD Expenses", "amount": -12.00, "comment": "Expense patched"}
          ]
        }' \
    >/dev/null

split_xaction=$("$CURL" -fsS -X POST "$BASE/books/personal/transactions" \
    -H 'content-type: application/json' \
    -d '{
          "date": "2026-01-16",
          "resolved": true,
          "comment": "Split expense",
          "lines": [
            {"account": "Broker USD", "amount": -15.00},
            {"account": "USD Expenses", "amount": 10.00},
            {"account": "USD Fees", "amount": 5.00}
          ]
        }')
assert_contains "split transaction creation endpoint" "$split_xaction" \
    '"book_id":"personal"'

same_account_status=$("$CURL" -sS -o "$SERVER_TMP/same-account.out" \
    -w '%{http_code}' -X POST "$BASE/books/personal/transactions" \
    -H 'content-type: application/json' \
    -d '{
          "date": "2026-01-17",
          "resolved": true,
          "lines": [
            {"account": "Broker USD", "amount": 1.00},
            {"account": "Broker USD", "amount": -1.00}
          ]
        }')
same_account_body=$(cat "$SERVER_TMP/same-account.out")
if [ "$same_account_status" != 400 ]; then
	echo "not ok - same-account transaction was rejected" >&2
	echo "$same_account_body" >&2
	echo "--- server log ---" >&2
	cat "$SERVER_TMP/server.log" >&2
	exit 1
fi
assert_contains "same-account transaction error is returned" \
    "$same_account_body" "xaction_bits_one_line_per_account"

ledger=$("$CURL" -fsS "$BASE/books/personal/ledger/Broker%20USD")
assert_contains "ledger endpoint" "$ledger" '"amount":12'
assert_contains "ledger endpoint reports patched date" "$ledger" '"date":"2026-01-21"'
assert_contains "ledger endpoint reports patched description" \
    "$ledger" '"description":"Patched transaction"'
assert_contains "ledger endpoint includes split transaction" "$ledger" '"amount":-15'
assert_contains "ledger endpoint reports transfer account" \
    "$ledger" '"transfer":"USD Expenses"'
assert_contains "ledger endpoint reports split marker" "$ledger" '"split":true'
assert_contains "ledger endpoint includes split lines" "$ledger" '"split_lines":['
assert_contains "ledger endpoint reports running balance" "$ledger" '"balance":-3'

all_ledger=$("$CURL" -fsS "$BASE/books/personal/ledger")
assert_contains "all-account ledger endpoint includes broker account" \
    "$all_ledger" '"account":"Broker USD"'
assert_contains "all-account ledger endpoint includes fees account" \
    "$all_ledger" '"account":"USD Fees"'

general_journal=$("$CURL" -fsS "$BASE/books/personal/reports/general-journal")
assert_contains "general journal endpoint includes transaction lines" \
    "$general_journal" '"account":"Broker USD"'
assert_contains "general journal endpoint includes debit column" \
    "$general_journal" '"debit":10'
assert_contains "general journal endpoint includes credit column" \
    "$general_journal" '"credit":12'
assert_contains "general journal endpoint includes line order" \
    "$general_journal" '"line_order":1'
assert_contains "general journal endpoint leaves simple memos empty" \
    "$general_journal" '"memo":null'

balance=$("$CURL" -fsS "$BASE/books/personal/balance-sheet?as_of=2026-01-31")
assert_contains "balance-sheet endpoint" "$balance" '"account":"Broker USD"'

balance_report=$("$CURL" -fsS "$BASE/books/personal/reports/balance-sheet?as_of=2026-01-31")
assert_contains "balance-sheet report endpoint groups assets" \
    "$balance_report" '"section":"Assets"'
assert_contains "balance-sheet report endpoint includes account rows" \
    "$balance_report" '"row_kind":"account"'
assert_contains "balance-sheet report endpoint includes asset total" \
    "$balance_report" '"account":"Total Assets"'
assert_contains "balance-sheet report endpoint includes grand total" \
    "$balance_report" '"account":"Total Liabilities and Equity"'

trial_balance=$("$CURL" -fsS "$BASE/books/personal/reports/trial-balance?as_of=2026-01-31")
assert_contains "trial-balance report endpoint includes account rows" \
    "$trial_balance" '"row_kind":"account"'
assert_contains "trial-balance report endpoint includes debit column" \
    "$trial_balance" '"debit":4.06'
assert_contains "trial-balance report endpoint includes credit column" \
    "$trial_balance" '"credit":4.06'
assert_contains "trial-balance report endpoint includes total row" \
    "$trial_balance" '"account":"Total"'

profit_loss=$("$CURL" -fsS "$BASE/books/personal/reports/profit-loss?from=2026-01-01&to=2026-01-31")
assert_contains "profit-loss report endpoint groups expenses" \
    "$profit_loss" '"section":"Expenses"'
assert_contains "profit-loss report endpoint includes account rows" \
    "$profit_loss" '"row_kind":"account"'
assert_contains "profit-loss report endpoint includes expense total" \
    "$profit_loss" '"account":"Total Expenses"'
assert_contains "profit-loss report endpoint includes net loss" \
    "$profit_loss" '"account":"Net Loss"'

cash_flow=$("$CURL" -fsS "$BASE/books/personal/reports/cash-flow?from=2026-01-01&to=2026-01-31")
assert_contains "cash-flow report endpoint groups operating activities" \
    "$cash_flow" '"section":"Operating Activities"'
assert_contains "cash-flow report endpoint includes account rows" \
    "$cash_flow" '"row_kind":"account"'
assert_contains "cash-flow report endpoint includes cash reconciliation" \
    "$cash_flow" '"section":"Cash Reconciliation"'
assert_contains "cash-flow report endpoint includes net cash row" \
    "$cash_flow" '"account":"Net Decrease in Cash"'

echo "ok - REST API smoke test passed"
