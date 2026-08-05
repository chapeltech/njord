#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

DB="${PLUTUS_API_TEST_DB:-plutus_api_test_$$}"
PORT="${PLUTUS_API_TEST_PORT:-18080}"
ADMIN_PORT="${PLUTUS_API_TEST_ADMIN_PORT:-18082}"
UI_PORT="${PLUTUS_UI_TEST_PORT:-18081}"
PSQL="${PSQL:-psql}"
CREATEDB="${CREATEDB:-createdb}"
DROPDB="${DROPDB:-dropdb}"
CURL="${CURL:-curl}"
NPM="${NPM:-npm}"

SQL_TMP=
SERVER_TMP=
POSTGREST_PID=
STATIC_PID=

if [ -n "${POSTGREST_BIN:-}" ]; then
	postgrest_source=$POSTGREST_BIN
elif command -v postgrest >/dev/null 2>&1; then
	postgrest_source=$(command -v postgrest)
elif [ -x .tools/postgrest ]; then
	postgrest_source=.tools/postgrest
else
	echo "PostgREST is not installed. Run scripts/install-postgrest." >&2
	exit 1
fi

if "$PSQL" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
	run()
	{
		"$@"
	}
	server_as_database_user()
	{
		"$@"
	}
elif command -v sudo >/dev/null 2>&1 &&
    sudo -n -u postgres "$PSQL" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1
then
	run()
	{
		sudo -n -u postgres "$@"
	}
	server_as_database_user()
	{
		sudo -n -u postgres "$@"
	}
else
	echo "Could not connect to PostgreSQL." >&2
	echo "Set PGUSER/PGHOST or run with sudo access to the postgres user." >&2
	exit 1
fi

cleanup()
{
	if [ -n "$STATIC_PID" ]; then
		kill "$STATIC_PID" >/dev/null 2>&1 || true
	fi
	if [ -n "$POSTGREST_PID" ]; then
		server_as_database_user kill "$POSTGREST_PID" >/dev/null 2>&1 ||
		    kill "$POSTGREST_PID" >/dev/null 2>&1 || true
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

SQL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/plutus-api-sql.XXXXXX")
SERVER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/plutus-api-server.XXXXXX")
cp sql/*.sql "$SQL_TMP"/
cp "$postgrest_source" "$SERVER_TMP/postgrest"
chmod a+rx "$SQL_TMP" "$SERVER_TMP" "$SERVER_TMP/postgrest"
chmod a+r "$SQL_TMP"/*.sql

run "$CREATEDB" "$DB"
run env PGOPTIONS="-c client_min_messages=warning" \
    "$PSQL" -q -v ON_ERROR_STOP=1 -X -d "$DB" \
    -f "$SQL_TMP/plutus.sql" >/dev/null

database_role=$(run "$PSQL" -X -d "$DB" -Atqc 'SELECT current_user')

server_as_database_user env \
    PGRST_DB_URI="postgresql:///$DB" \
    PGRST_DB_ANON_ROLE="$database_role" \
    PGRST_SERVER_PORT="$PORT" \
    PGRST_ADMIN_SERVER_PORT="$ADMIN_PORT" \
    "$SERVER_TMP/postgrest" postgrest.conf \
    >"$SERVER_TMP/postgrest.log" 2>&1 &
POSTGREST_PID=$!

BASE="http://127.0.0.1:$PORT"
ADMIN="http://127.0.0.1:$ADMIN_PORT"

for _ in 1 2 3 4 5 6 7 8 9 10; do
	if "$CURL" -fsS "$ADMIN/ready" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

if ! "$CURL" -fsS "$ADMIN/ready" >/dev/null 2>&1; then
	echo "PostgREST did not become ready." >&2
	cat "$SERVER_TMP/postgrest.log" >&2
	exit 1
fi

PLUTUS_UI_PORT="$UI_PORT" \
PLUTUS_POSTGREST_URL="$BASE" \
    node scripts/static-server.mjs >"$SERVER_TMP/static.log" 2>&1 &
STATIC_PID=$!

UI="http://127.0.0.1:$UI_PORT"
for _ in 1 2 3 4 5; do
	if "$CURL" -fsS "$UI/" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

assert_contains()
{
	label=$1
	body=$2
	needle=$3

	if ! printf '%s' "$body" | grep -F "$needle" >/dev/null; then
		echo "not ok - $label" >&2
		echo "$body" >&2
		echo "--- PostgREST log ---" >&2
		cat "$SERVER_TMP/postgrest.log" >&2
		echo "--- static server log ---" >&2
		cat "$SERVER_TMP/static.log" >&2
		exit 1
	fi

	echo "ok - $label"
}

rpc()
{
	name=$1
	body=$2
	"$CURL" -fsS -X POST "$BASE/rpc/$name" \
	    -H 'content-type: application/json' -d "$body"
}

shell=$(rpc shell_page '{}')
assert_contains "shell page includes books" "$shell" '"component":"book_option"'
assert_contains "shell page includes account choices" "$shell" '"component":"account_option"'
assert_contains "shell page includes reports" "$shell" '"component":"report_option"'

book=$(rpc create_book '{
  "p_id":"web-test",
  "p_name":"Web Test",
  "p_reporting_asset":"GBP",
  "p_create_standard_accounts":true
}')
assert_contains "create_book mutation" "$book" '"id":"web-test"'

account=$(rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Current Account",
  "p_type":"A",
  "p_asset":"GBP",
  "p_pretax":1,
  "p_opening_balance":100,
  "p_opening_date":"2026-01-01"
}')
assert_contains "create_account mutation" "$account" '"id":"Current Account"'

rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Food",
  "p_type":"E",
  "p_asset":"GBP"
}' >/dev/null

rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Fees",
  "p_type":"E",
  "p_asset":"GBP"
}' >/dev/null

run "$PSQL" -q -v ON_ERROR_STOP=1 -X -d "$DB" \
    -c "INSERT INTO cash_accounts (book_id, acct) VALUES ('web-test', 'Current Account')" \
    >/dev/null

invalid_preview=$(rpc preview_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-01",
    "resolved":true,
    "lines":[
      {"account":"Current Account","amount":-10},
      {"account":"Food","amount":9}
    ]
  }
}')
assert_contains "preview reports invalid transaction" "$invalid_preview" '"valid":false'
assert_contains "preview reports per-asset imbalance" "$invalid_preview" '"GBP": -1'

missing_amount=$(rpc preview_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-01",
    "resolved":false,
    "lines":[{"account":"Current Account"}]
  }
}')
assert_contains "preview rejects missing amounts" "$missing_amount" '"error_code":"INVALID_LINE"'

split_preview=$(rpc preview_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-01",
    "resolved":true,
    "lines":[
      {"account":"Current Account","amount":-20,"comment":"Split transport"},
      {"account":"Food","amount":15,"comment":"Split transport"},
      {"account":"Fees","amount":5,"comment":"Split transport"}
    ]
  }
}')
assert_contains "split preview is valid" "$split_preview" '"valid":true'
assert_contains "split preview returns normalized header" "$split_preview" '"comment": "Split transport"'
assert_contains "split preview returns normalized lines" "$split_preview" '"account": "Fees"'

created=$(rpc create_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-02",
    "resolved":true,
    "comment":"Groceries",
    "lines":[
      {"account":"Current Account","amount":-12},
      {"account":"Food","amount":12}
    ]
  }
}')
assert_contains "create_transaction mutation" "$created" '"resolved":true'
xid=$(printf '%s\n' "$created" | sed -n 's/.*"xid":\([0-9][0-9]*\).*/\1/p')
if [ -z "$xid" ]; then
	echo "not ok - transaction id returned" >&2
	exit 1
fi

ledger=$(rpc ledger_page "{\"p_book_id\":\"web-test\",\"p_account_id\":\"Current Account\"}")
assert_contains "ledger page includes its complete model" "$ledger" '"component":"ledger_row"'
assert_contains "ledger page includes complete transaction lines" "$ledger" '"account": "Food"'
assert_contains "ledger page includes transfer choices" "$ledger" '"component":"transfer_account_option"'

replaced=$(rpc replace_transaction "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_transaction\":{
    \"date\":\"2026-02-03\",
    \"resolved\":true,
    \"comment\":\"Groceries updated\",
    \"lines\":[
      {\"account\":\"Current Account\",\"amount\":-15},
      {\"account\":\"Food\",\"amount\":15}
    ]
  }
}")
assert_contains "replace_transaction mutation" "$replaced" "\"xid\":$xid"

line=$(rpc update_ledger_line "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_account_id\":\"Current Account\",
  \"p_date\":\"2026-02-04\",
  \"p_description\":\"Line updated\"
}")
assert_contains "update_ledger_line mutation" "$line" '"account_id":"Current Account"'

for page_call in \
    'general_journal_page {"p_book_id":"web-test"}' \
    'balance_sheet_page {"p_book_id":"web-test","p_as_of":"2026-12-31"}' \
    'trial_balance_page {"p_book_id":"web-test","p_as_of":"2026-12-31"}' \
    'profit_loss_page {"p_book_id":"web-test","p_from":"2026-01-01","p_to":"2026-12-31"}' \
    'cash_flow_page {"p_book_id":"web-test","p_from":"2026-01-01","p_to":"2026-12-31"}' \
    'add_book_page {}' \
    'add_account_page {"p_book_id":"web-test"}'
do
	name=${page_call%% *}
	body=${page_call#* }
	page=$(rpc "$name" "$body")
	assert_contains "$name is exposed" "$page" '"component":"page_context"'
	assert_contains "$name includes book navigation" "$page" '"component":"book_option"'
	assert_contains "$name includes report navigation" "$page" '"component":"report_option"'
	assert_contains "$name includes account navigation" "$page" '"component":"account_option"'
done

error_file="$SERVER_TMP/error.json"
error_status=$("$CURL" -sS -o "$error_file" -w '%{http_code}' \
    -X POST "$BASE/rpc/create_transaction" \
    -H 'content-type: application/json' \
    -d '{
      "p_book_id":"web-test",
      "p_transaction":{
        "date":"2026-02-05",
        "resolved":true,
        "lines":[
          {"account":"Current Account","amount":-3},
          {"account":"Food","amount":2}
        ]
      }
    }')
assert_contains "validation failure uses HTTP error status" "$error_status" '400'
assert_contains "validation failure includes structured detail" "$(cat "$error_file")" 'TRANSACTION_NOT_BALANCED'

book_error_status=$("$CURL" -sS -o "$error_file" -w '%{http_code}' \
    -X POST "$BASE/rpc/create_book" \
    -H 'content-type: application/json' \
    -d '{
      "p_id":"",
      "p_name":"Invalid",
      "p_reporting_asset":"GBP"
    }')
assert_contains "book validation uses HTTP error status" "$book_error_status" '400'
assert_contains "book validation includes structured detail" "$(cat "$error_file")" 'BOOK_ID_REQUIRED'

public_status=$("$CURL" -sS -o /dev/null -w '%{http_code}' "$BASE/books")
assert_contains "base tables are not exposed" "$public_status" '404'

index=$("$CURL" -fsS "$UI/")
assert_contains "static server serves Elm" "$index" '<title>Plutus</title>'
head_status=$("$CURL" -sS -o /dev/null -w '%{http_code}' -I "$UI/app.js")
assert_contains "static server supports HEAD" "$head_status" '200'
traversal_status=$("$CURL" --path-as-is -sS -o /dev/null -w '%{http_code}' "$UI/%2e%2e/README.md")
case "$traversal_status" in
    403|404)
	echo "ok - static server confines files to frontend"
	;;
    *)
	echo "not ok - static server confines files to frontend ($traversal_status)" >&2
	exit 1
	;;
esac
method_status=$("$CURL" -sS -o /dev/null -w '%{http_code}' -X POST "$UI/index.html")
assert_contains "static server rejects writes" "$method_status" '405'
proxied=$("$CURL" -fsS -X POST "$UI/rpc/shell_page" -H 'content-type: application/json' -d '{}')
assert_contains "static server proxies RPCs" "$proxied" '"component":"book_option"'

node tests/browser.mjs "$UI"

echo "ok - PostgREST API test suite passed"
