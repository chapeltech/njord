#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

DB="${NJORD_API_TEST_DB:-njord_api_test_$$}"
PORT="${NJORD_API_TEST_PORT:-18080}"
ADMIN_PORT="${NJORD_API_TEST_ADMIN_PORT:-18082}"
UI_PORT="${NJORD_UI_TEST_PORT:-18081}"
PSQL="${PSQL:-psql}"
CREATEDB="${CREATEDB:-createdb}"
DROPDB="${DROPDB:-dropdb}"
CURL="${CURL:-curl}"
NPM="${NPM:-npm}"
JWT_SECRET="${NJORD_API_TEST_JWT_SECRET:-test-api-postgrest-jwt-secret-000000000001}"

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
	start_server_as_database_user()
	{
		exec "$@"
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
	start_server_as_database_user()
	{
		exec sudo -n -u postgres "$@"
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

SQL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/njord-api-sql.XXXXXX")
SERVER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/njord-api-server.XXXXXX")
mkdir "$SQL_TMP/sql" "$SQL_TMP/examples"
cp sql/*.sql "$SQL_TMP/sql"/
cp examples/*.sql "$SQL_TMP/examples"/
cp "$postgrest_source" "$SERVER_TMP/postgrest"
chmod a+rx "$SQL_TMP" "$SQL_TMP/sql" "$SQL_TMP/examples" \
    "$SERVER_TMP" "$SERVER_TMP/postgrest"
chmod a+r "$SQL_TMP/sql"/*.sql "$SQL_TMP/examples"/*.sql

run "$CREATEDB" "$DB"
run env PGOPTIONS="-c client_min_messages=warning" \
    "$PSQL" -q -v ON_ERROR_STOP=1 -X -d "$DB" \
    -f "$SQL_TMP/examples/njord-demo.sql" >/dev/null

database_role=$(run "$PSQL" -X -d "$DB" -Atqc 'SELECT current_user')

start_server_as_database_user env \
    PGRST_DB_URI="postgresql:///$DB" \
    PGRST_DB_ANON_ROLE="$database_role" \
    PGRST_JWT_SECRET="$JWT_SECRET" \
    PGRST_JWT_AUD=njord \
    PGRST_SERVER_PORT="$PORT" \
    PGRST_ADMIN_SERVER_PORT="$ADMIN_PORT" \
    "$SERVER_TMP/postgrest" postgrest.conf \
    >"$SERVER_TMP/postgrest.log" 2>&1 &
POSTGREST_PID=$!

BASE="http://127.0.0.1:$PORT"
ADMIN="http://127.0.0.1:$ADMIN_PORT"

for _ in 1 2 3 4 5 6 7 8 9 10; do
	if ! kill -0 "$POSTGREST_PID" >/dev/null 2>&1; then
		break
	fi
	if "$CURL" -fsS "$ADMIN/ready" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

if ! kill -0 "$POSTGREST_PID" >/dev/null 2>&1 ||
    ! "$CURL" -fsS "$ADMIN/ready" >/dev/null 2>&1
then
	echo "PostgREST did not become ready." >&2
	cat "$SERVER_TMP/postgrest.log" >&2
	exit 1
fi

NJORD_UI_PORT="$UI_PORT" \
NJORD_POSTGREST_URL="$BASE" \
NJORD_DATABASE_ROLE="$database_role" \
NODE_ENV=test \
NJORD_TEST_ALL_IN_ONE=1 \
NJORD_POSTGREST_JWT_SECRET="$JWT_SECRET" \
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

assert_not_contains()
{
	label=$1
	body=$2
	needle=$3

	if printf '%s' "$body" | grep -F "$needle" >/dev/null; then
		echo "not ok - $label" >&2
		echo "$body" >&2
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
assert_not_contains "shell page omits page-specific account choices" "$shell" '"component":"account_option"'
assert_not_contains "shell page omits page-specific report choices" "$shell" '"component":"report_option"'
assert_contains "shell page includes SQL-owned presentation vocabulary" "$shell" '"component":"presentation"'
assert_contains "shell page resolves navigation labels in SQL" "$shell" '"key": "nav.accounts", "text": "Accounts"'
assert_contains "shell page resolves Help in SQL" "$shell" '"key": "nav.help", "text": "Help"'
assert_contains "shell page exposes SQL-owned language choices" "$shell" '"component":"language_option"'
assert_contains "shell page exposes the UK flag" "$shell" '"flag": "🇬🇧"'
assert_not_contains "shell account choices exclude placeholder roots" "$shell" '"row_key":"Assets"'

spanish_shell=$("$CURL" -fsS -X POST "$BASE/rpc/shell_page" \
    -H 'content-type: application/json' \
    -H 'accept-language: es-PA' \
    -d '{}')
assert_contains "Accept-Language selects SQL-owned Panamanian Spanish" "$spanish_shell" '"key": "nav.accounts", "text": "Cuentas", "locale": "es-PA"'
assert_contains "Spanish includes SQL-owned Help" "$spanish_shell" '"key": "nav.help", "text": "Ayuda", "locale": "es-PA"'
assert_contains "Spanish includes SQL-owned Book help" "$spanish_shell" '"key": "help.book.identity", "text": "El identificador es permanente.'

chinese_shell=$("$CURL" -fsS -X POST "$BASE/rpc/shell_page" \
    -H 'content-type: application/json' \
    -H 'accept-language: zh-TW' \
    -d '{}')
assert_contains "Accept-Language selects SQL-owned Traditional Chinese" "$chinese_shell" '"key": "nav.accounts", "text": "科目", "locale": "zh-TW"'
assert_contains "Chinese includes SQL-owned Help" "$chinese_shell" '"key": "nav.help", "text": "說明", "locale": "zh-TW"'
assert_contains "Chinese includes SQL-owned status vocabulary" "$chinese_shell" '"key": "status.transaction.saving", "text": "正在儲存交易"'
assert_contains "Chinese includes SQL-owned chart accessibility text" "$chinese_shell" '"key": "aria.chart.bar", "text": "長條圖。{summary}"'

book=$(rpc create_book '{
  "p_id":"web-test",
  "p_name":"Web Test",
  "p_reporting_asset":"GBP",
  "p_create_standard_accounts":true
}')
assert_contains "create_book mutation" "$book" '"id":"web-test"'

book_page=$(rpc book_page '{"p_book_id":"web-test"}')
assert_contains "Book page exposes explicit household identity" "$book_page" '"entity_type": "household"'
assert_contains "ordinary Book page reports ordinary status" "$book_page" '"configuration_status": "ordinary"'

renamed_book=$(rpc update_book_settings '{
  "p_book_id":"web-test",
  "p_name":"Web Test renamed",
  "p_entity_type":"household"
}')
assert_contains "update_book_settings returns the canonical Book page" "$renamed_book" '"component":"book_identity"'
assert_contains "update_book_settings updates the display name" "$renamed_book" '"name": "Web Test renamed"'
rpc update_book_settings '{"p_book_id":"web-test","p_name":"Web Test"}' >/dev/null

currency_page=$(rpc set_book_reporting_currency '{
  "p_book_id":"web-test",
  "p_asset":"USD",
  "p_effective_from":null
}')
assert_contains "empty book reporting currency can be replaced" "$currency_page" '"reporting_asset": "USD"'
assert_contains "Book page exposes reporting-currency history" "$currency_page" '"component":"reporting_currency"'
rpc set_book_reporting_currency '{
  "p_book_id":"web-test",
  "p_asset":"GBP",
  "p_effective_from":null
}' >/dev/null

rpc create_book '{
  "p_id":"doodles-household",
  "p_name":"Doodles Household",
  "p_reporting_asset":"USD",
  "p_entity_type":"household",
  "p_create_standard_accounts":true
}' >/dev/null
doodles_page=$(rpc book_page '{"p_book_id":"doodles-household"}')
assert_contains "USD household remains explicitly a household" "$doodles_page" '"entity_type_label": "Household or individual"'
assert_not_contains "USD household does not pretend to have a Panama profile" "$doodles_page" '"component":"panama_business_profile"'

rpc archive_book '{"p_book_id":"doodles-household"}' >/dev/null
archived_shell=$(rpc shell_page '{}')
assert_not_contains "archived book leaves normal navigation" "$archived_shell" '"row_key":"doodles-household"'
rpc restore_book '{"p_book_id":"doodles-household"}' >/dev/null
restored_shell=$(rpc shell_page '{}')
assert_contains "restored book returns to normal navigation" "$restored_shell" '"row_key":"doodles-household"'

account=$(rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Current Account",
  "p_type":"A",
  "p_asset":"GBP",
  "p_account_kind":"bank",
  "p_pretax":1,
  "p_opening_balance":100,
  "p_opening_date":"2026-01-01"
}')
assert_contains "create_account mutation" "$account" '"id":"Current Account"'
assert_contains "create_account defaults to the matching class root" "$account" '"parent_id":"Assets"'
assert_contains "account kind is returned" "$account" '"account_kind":"bank"'

group=$(rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Household Expenses",
  "p_name":"Household",
  "p_parent_id":"Expenses",
  "p_account_kind":"group",
  "p_placeholder":true
}')
assert_contains "placeholder group mutation" "$group" '"name":"Household"'
assert_contains "placeholder group inherits its class" "$group" '"type":"E"'
assert_contains "placeholder group is returned as a placeholder" "$group" '"placeholder":true'

rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Food",
  "p_parent_id":"Household Expenses"
}' >/dev/null

rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"Fees",
  "p_type":"E",
  "p_asset":"GBP"
}' >/dev/null

rpc create_account '{
  "p_book_id":"web-test",
  "p_id":"EUR Wallet",
  "p_type":"A",
  "p_asset":"EUR"
}' >/dev/null

draft_balance=$(rpc transaction_draft_balance '{
  "p_book_id":"web-test",
  "p_lines":[
    {"account":"Current Account","amount":-7},
    {"account":"Food","amount":6}
  ]
}')
assert_contains "draft balance is exposed through PostgREST" "$draft_balance" '"asset":"GBP"'
assert_contains "draft balance returns the signed reciprocal" "$draft_balance" '"amount":1.00000'

balanced_draft=$(rpc transaction_draft_balance '{
  "p_book_id":"web-test",
  "p_lines":[
    {"account":"Current Account","amount":-7},
    {"account":"Food","amount":7}
  ]
}')
assert_contains "balanced draft has no suggested posting" "$balanced_draft" '[]'

precise_draft=$(rpc transaction_draft_balance_text '{
  "p_book_id":"web-test",
  "p_lines":[
    {"account":"Current Account","amount":"-9007199254740993.00001"}
  ]
}')
assert_contains "editable draft balances preserve exact decimals as strings" "$precise_draft" '"amount":"9007199254740993.00001"'

invalid_preview=$(rpc preview_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-01",
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
    "lines":[{"account":"Current Account"}]
  }
}')
assert_contains "preview rejects missing amounts" "$missing_amount" '"error_code":"INVALID_LINE"'

split_preview=$(rpc preview_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-01",
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

simple_preview=$(rpc preview_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-01",
    "comment":"Simple register entry",
    "simple":{
      "account":"Current Account",
      "transfer_account":"Food",
      "amount":"-8"
    }
  }
}')
assert_contains "simple preview is expanded by SQL" "$simple_preview" '"valid":true'
assert_contains "simple preview returns its counterline" "$simple_preview" '"amount": 8.00000'

created=$(rpc create_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-02",
    "comment":"Groceries",
    "lines":[
      {"account":"Current Account","amount":-12},
      {"account":"Food","amount":12}
    ]
  }
}')
assert_contains "create_transaction mutation" "$created" '"book_id":"web-test"'
xid=$(printf '%s\n' "$created" | sed -n 's/.*"xid":\([0-9][0-9]*\).*/\1/p')
if [ -z "$xid" ]; then
	echo "not ok - transaction id returned" >&2
	exit 1
fi

accounts=$(rpc accounts_page '{"p_book_id":"web-test"}')
assert_contains "accounts page is exposed" "$accounts" '"component":"account_row"'
assert_contains "accounts page includes its SQL context" "$accounts" '"component":"page_context"'
assert_contains "accounts page includes native-asset balances as exact text" "$accounts" '"balance": "88.00000"'
assert_contains "accounts page includes visible account names" "$accounts" '"name": "Household"'
assert_contains "accounts page includes parent relationships" "$accounts" '"parent_id": "Household Expenses"'
assert_contains "accounts page includes hierarchy depth" "$accounts" '"depth": 2'
assert_contains "accounts page includes full account paths" "$accounts" '"path": "Expenses:Household:Food"'
assert_contains "accounts page identifies expandable accounts" "$accounts" '"has_children": true'
assert_contains "accounts page includes subtree balances" "$accounts" '"subtree_balance"'
assert_contains "accounts page marks mixed-commodity subtree totals" "$accounts" '"subtree_balance_complete"'
assert_contains "accounts page includes reporting values" "$accounts" '"reporting_value"'
assert_contains "accounts page includes posting counts" "$accounts" '"posting_count": 2'
assert_contains "accounts page includes reconciliation counts" "$accounts" '"unreconciled_count": 2'
assert_contains "accounts page classifies cash accounts" "$accounts" '"is_cash_account": true'

add_child=$(rpc add_account_page '{
  "p_book_id":"web-test",
  "p_parent_id":"Household Expenses"
}')
assert_contains "add-account page preserves requested parent" "$add_child" '"parent_id": "Household Expenses"'
assert_contains "add-account page inherits parent class" "$add_child" '"account_type": "E"'
assert_contains "add-account page exposes hierarchical parent paths" "$add_child" '"path": "Expenses:Household"'
assert_contains "add-account page exposes account kinds" "$add_child" '"component":"account_kind_option"'
assert_contains "add-account page exposes parent choices" "$add_child" '"component":"parent_account_option"'

default_add=$(rpc add_account_page '{"p_book_id":"web-test"}')
assert_contains "add-account page defaults to the Assets root" "$default_add" '"parent_id": "Assets"'

demo_accounts=$(rpc accounts_page '{"p_book_id":"demo"}')
assert_contains "demo includes the GBP-denominated house" "$demo_accounts" '"id": "12 Acacia Avenue"'
assert_contains "demo includes the exact house market valuation" "$demo_accounts" '"reporting_value": "425000.00000"'
assert_contains "demo includes gold quantities" "$demo_accounts" '"asset": "XAU"'
assert_contains "demo includes silver quantities" "$demo_accounts" '"asset": "XAG"'
assert_contains "demo includes share quantities" "$demo_accounts" '"asset": "VWRL"'

generic_net_worth=$(rpc report_page '{
  "p_book_id":"demo",
  "p_report_id":"net-worth",
  "p_as_of":"2026-12-31"
}')
assert_contains "generic report page includes its database definition" "$generic_net_worth" '"component":"report_definition"'
assert_contains "generic report page gets its title from SQL" "$generic_net_worth" '"title": "Net Worth"'
assert_contains "generic report page includes SQL-defined columns" "$generic_net_worth" '"component":"report_column"'
assert_contains "generic report page normalizes table rows" "$generic_net_worth" '"component":"generic_report_row"'
assert_contains "generic report page preserves hierarchy depth" "$generic_net_worth" '"depth": 2'
assert_contains "generic report page includes a reusable chart definition" "$generic_net_worth" '"component":"bar_chart_definition"'
assert_contains "generic report page includes reusable chart points" "$generic_net_worth" '"component":"bar_chart_point"'
assert_contains "generic report page labels chart values with the reporting asset" "$generic_net_worth" '"suffix": "GBP"'
assert_contains "generic net worth uses the house market estimate" "$generic_net_worth" '"number": 425000.00'
assert_contains "generic report numbers include lossless display text" "$generic_net_worth" '"exact": "425000.00"'
assert_contains "generic net worth identifies account estimates" "$generic_net_worth" '"text": "Account estimate'
assert_contains "generic net worth uses commodity unit rates" "$generic_net_worth" '"text": "Unit rate'
assert_contains "generic net worth totals assets less liabilities" "$generic_net_worth" '"number": 244988.35'
assert_contains "generic net worth includes hierarchical group rows" "$generic_net_worth" '"row_kind": "group"'

generic_profit_loss=$(rpc report_page '{
  "p_book_id":"demo",
  "p_report_id":"profit-loss",
  "p_from":"2026-01-01",
  "p_to":"2026-12-31"
}')
assert_contains "Profit and Loss is SQL-defined" "$generic_profit_loss" '"title": "Profit & Loss"'
assert_contains "Profit and Loss uses generic report rows" "$generic_profit_loss" '"component":"generic_report_row"'
assert_contains "Profit and Loss includes its calculated result" "$generic_profit_loss" '"text": "Net Profit"'

for report_id in balance-sheet net-worth trial-balance profit-loss cash-flow
do
	generic_page=$(rpc report_page "{\"p_book_id\":\"web-test\",\"p_report_id\":\"$report_id\",\"p_as_of\":\"2026-12-31\",\"p_from\":\"2026-01-01\",\"p_to\":\"2026-12-31\"}")
	assert_contains "$report_id is exposed through the generic report page" "$generic_page" '"component":"report_definition"'
	assert_contains "$report_id supplies generic columns" "$generic_page" '"component":"report_column"'
	assert_contains "$report_id supplies generic rows" "$generic_page" '"component":"generic_report_row"'
done

uk_reports=$(rpc reports_page '{"p_book_id":"uk-business"}')
assert_contains "UK company report library is complete-configuration-gated" "$uk_reports" '"name": "UK Statutory Balance Sheet"'
assert_contains "VAT output is labelled as a working paper" "$uk_reports" '"name": "VAT Return Working Paper"'
assert_contains "UK report library exposes statutory grouping" "$uk_reports" '"report_group": "UK statutory accounts"'
assert_contains "UK report library exposes HMRC grouping" "$uk_reports" '"report_group": "HMRC"'
assert_contains "UK report library exposes supporting schedules" "$uk_reports" '"report_group": "Supporting schedules"'

personal_reports=$(rpc reports_page '{"p_book_id":"personal"}')
assert_not_contains "personal books do not receive company reports" "$personal_reports" '"name": "UK Statutory Balance Sheet"'
assert_not_contains "personal books do not receive Panama reports" "$personal_reports" '"name": "Panama Residential Rent Roll"'
assert_not_contains "personal books do not receive Taiwan reports" "$personal_reports" '"name": "存貨進銷存明細表"'

panama_reports=$(rpc reports_page '{"p_book_id":"panama-property"}')
assert_contains "Panama business reports are profile-gated" "$panama_reports" '"name": "Panama Corporate Income Tax Working Paper"'
assert_contains "Panama property extension exposes the rent roll" "$panama_reports" '"name": "Panama Residential Rent Roll"'
assert_contains "Panama property extension exposes repair classifications" "$panama_reports" '"name": "Panama Repairs vs Capital Schedule"'

for report_id in \
    panama-income-tax panama-form-20 panama-form-43-threshold \
    panama-dividend-tax panama-compliance-calendar panama-itbms \
    panama-rent-roll panama-property-profit-loss panama-property-tax \
    panama-repair-capital
do
	panama_page=$(rpc report_page "{\"p_book_id\":\"panama-property\",\"p_report_id\":\"$report_id\",\"p_as_of\":\"2026-08-08\",\"p_from\":\"2026-01-01\",\"p_to\":\"2026-12-31\"}")
	assert_contains "$report_id is exposed through the generic report page" "$panama_page" '"component":"report_definition"'
	assert_contains "$report_id supplies database-defined columns" "$panama_page" '"component":"report_column"'
	assert_contains "$report_id supplies accounting working-paper rows" "$panama_page" '"component":"generic_report_row"'
done

panama_book_page=$(rpc book_page '{"p_book_id":"panama-property"}')
assert_contains "Panama Book page exposes its SQL-owned profile" "$panama_book_page" '"component":"panama_business_profile"'
assert_contains "Panama Book page reports the property extension" "$panama_book_page" '"residential_property_enabled": true'
assert_not_contains "Panama Book page does not expose UK configuration" "$panama_book_page" '"component":"company_profile"'

rpc create_book '{
  "p_id":"web-panama",
  "p_name":"Web Panama Business",
  "p_reporting_asset":"PAB",
  "p_create_standard_accounts":false
}' >/dev/null

configured_panama=$(rpc configure_panama_business '{
  "p_book_id":"web-panama",
  "p_legal_name":"Web Panama Business, S.A.",
  "p_ruc":"155700001-2-2026",
  "p_verification_digit":"19",
  "p_legal_form":"corporation",
  "p_municipality":"panama_district",
  "p_itbms_registered":false,
  "p_conducts_lodging_activity":false,
  "p_enable_residential_property":true,
  "p_period_id":"2026",
  "p_period_start":"2026-01-01",
  "p_period_end":"2026-12-31",
  "p_period_status":"open"
}')
assert_contains "configure_panama_business returns the canonical Book page" "$configured_panama" '"component":"panama_business_profile"'
assert_contains "configure_panama_business enables the optional property data seam" "$configured_panama" '"residential_property_enabled": true'

configured_panama_accounts=$(rpc accounts_page '{"p_book_id":"web-panama"}')
assert_contains "configure_panama_business creates the standard hierarchy in SQL" "$configured_panama_accounts" '"id": "Assets"'

configured_panama_reports=$(rpc reports_page '{"p_book_id":"web-panama"}')
assert_contains "configured generic Panama business receives business summaries" "$configured_panama_reports" '"name": "Panama ITBMS Working Paper"'
assert_not_contains "property reports wait for a recorded property" "$configured_panama_reports" '"name": "Panama Residential Rent Roll"'

taiwan_reports=$(rpc reports_page '{"p_book_id":"taiwan-injection"}')
assert_contains "Taiwan business reports are profile-gated" "$taiwan_reports" '"name": "營業人銷售額與稅額申報書（401）工作底稿"'
assert_contains "Taiwan manufacturing reports are extension-gated" "$taiwan_reports" '"name": "生產成本及單位成本表"'
assert_contains "Taiwan pack groups production schedules in SQL" "$taiwan_reports" '"report_group": "射出成型・生產"'

for report_id in \
    taiwan-business-tax-401 taiwan-uniform-invoices taiwan-income-tax \
    taiwan-withholding taiwan-compliance-calendar taiwan-trade-aging \
    taiwan-inventory-rollforward taiwan-direct-material-usage \
    taiwan-production-cost taiwan-production-yield taiwan-product-margin \
    taiwan-equipment-register
do
	taiwan_page=$(rpc report_page "{\"p_book_id\":\"taiwan-injection\",\"p_report_id\":\"$report_id\",\"p_as_of\":\"2026-08-08\",\"p_from\":\"2026-01-01\",\"p_to\":\"2026-12-31\"}")
	assert_contains "$report_id is exposed through the generic report page" "$taiwan_page" '"component":"report_definition"'
	assert_contains "$report_id supplies database-defined columns" "$taiwan_page" '"component":"report_column"'
	assert_contains "$report_id supplies accounting working-paper rows" "$taiwan_page" '"component":"generic_report_row"'
done

taiwan_book_page=$(rpc book_page '{"p_book_id":"taiwan-injection"}')
assert_contains "Taiwan Book page exposes its SQL-owned profile" "$taiwan_book_page" '"component":"taiwan_business_profile"'
assert_contains "Taiwan Book page reports the manufacturing extension" "$taiwan_book_page" '"manufacturing_enabled": true'
assert_contains "Taiwan Book page exposes the Traditional Chinese legal name" "$taiwan_book_page" '"legal_name": "福爾摩沙精密塑膠有限公司"'
assert_not_contains "Taiwan Book page does not expose UK configuration" "$taiwan_book_page" '"component":"company_profile"'
assert_not_contains "Taiwan Book page does not expose Panama configuration" "$taiwan_book_page" '"component":"panama_business_profile"'

taiwan_accounts=$(rpc accounts_page '{"p_book_id":"taiwan-injection"}')
assert_contains "Taiwan account names are Traditional Chinese" "$taiwan_accounts" '"name": "營運銀行存款"'

rpc create_book '{
  "p_id":"web-taiwan",
  "p_name":"Web Taiwan Factory",
  "p_reporting_asset":"TWD",
  "p_create_standard_accounts":false
}' >/dev/null

configured_taiwan=$(rpc configure_taiwan_business '{
  "p_book_id":"web-taiwan",
  "p_legal_name":"Web Taiwan Factory Co., Ltd.",
  "p_unified_business_number":"12345678",
  "p_legal_form":"limited_company",
  "p_business_tax_frequency":"bimonthly",
  "p_uses_uniform_invoices":true,
  "p_enable_manufacturing":true,
  "p_period_id":"2026",
  "p_period_start":"2026-01-01",
  "p_period_end":"2026-12-31",
  "p_period_status":"open"
}')
assert_contains "configure_taiwan_business returns the canonical Book page" "$configured_taiwan" '"component":"taiwan_business_profile"'
assert_contains "configure_taiwan_business enables the optional manufacturing seam" "$configured_taiwan" '"manufacturing_enabled": true'

configured_taiwan_accounts=$(rpc accounts_page '{"p_book_id":"web-taiwan"}')
assert_contains "configure_taiwan_business creates the standard hierarchy in SQL" "$configured_taiwan_accounts" '"id": "Assets"'

configured_taiwan_reports=$(rpc reports_page '{"p_book_id":"web-taiwan"}')
assert_contains "configured Taiwan business receives business working papers" "$configured_taiwan_reports" '"name": "統一發票登記簿"'
assert_contains "enabled manufacturing seam exposes its empty schedules" "$configured_taiwan_reports" '"name": "存貨進銷存明細表"'

for report_id in \
    uk-statutory-profit-loss uk-statutory-balance-sheet changes-in-equity \
    uk-statutory-notes corporation-tax vat-return vat-detail \
    fixed-asset-schedule director-loan-schedule aged-debtors aged-creditors
do
	uk_page=$(rpc report_page "{\"p_book_id\":\"uk-business\",\"p_report_id\":\"$report_id\",\"p_as_of\":\"2026-08-08\",\"p_from\":\"2026-01-01\",\"p_to\":\"2026-12-31\"}")
	assert_contains "$report_id is exposed through the generic report page" "$uk_page" '"component":"report_definition"'
	assert_contains "$report_id supplies generic columns" "$uk_page" '"component":"report_column"'
	assert_contains "$report_id supplies preparation rows" "$uk_page" '"component":"generic_report_row"'
done

uk_default_period=$(rpc report_page '{
  "p_book_id":"uk-business",
  "p_report_id":"corporation-tax"
}')
assert_contains "UK reports default from the configured accounting period" "$uk_default_period" '"from": "2026-01-01"'
assert_contains "UK reports default to the configured accounting period end" "$uk_default_period" '"to": "2026-12-31"'

uk_vat=$(rpc report_page '{
  "p_book_id":"uk-business",
  "p_report_id":"vat-return",
  "p_from":"2026-01-01",
  "p_to":"2026-12-31"
}')
assert_contains "UK VAT return includes all SQL-defined boxes" "$uk_vat" '"row_key":"vat-return:box-9"'
assert_contains "UK VAT return computes output VAT from net postings" "$uk_vat" '"number": 3060.00'
assert_contains "UK VAT return computes VAT payable" "$uk_vat" '"number": 2092.00'

uk_ct=$(rpc report_page '{
  "p_book_id":"uk-business",
  "p_report_id":"corporation-tax",
  "p_from":"2026-01-01",
  "p_to":"2026-12-31"
}')
assert_contains "Corporation Tax report remains a preparation computation" "$uk_ct" '"text": "Preparation subtotal only"'
assert_contains "Corporation Tax report does not invent a filing liability" "$uk_ct" '"text": "Rates, associated companies, marginal relief, losses, and claims are not configured"'

placeholder_ledger=$(rpc ledger_page '{
  "p_book_id":"web-test",
  "p_account_id":"Expenses"
}')
assert_contains "placeholder accounts cannot be opened as registers" "$placeholder_ledger" '"account_exists": false'

placeholder_reconciliation=$(rpc reconciliation_page '{
  "p_book_id":"web-test",
  "p_account_id":"Expenses"
}')
assert_contains "placeholder accounts cannot filter reconciliation" "$placeholder_reconciliation" '"account_exists": false'

ledger=$(rpc ledger_page "{\"p_book_id\":\"web-test\",\"p_account_id\":\"Current Account\"}")
assert_contains "ledger page includes its complete model" "$ledger" '"component":"ledger_row"'
assert_contains "ledger page includes complete transaction lines" "$ledger" '"account": "Food"'
assert_contains "ledger page includes transfer choices" "$ledger" '"component":"account_option"'
assert_contains "ledger exposes editable amounts as lossless strings" "$ledger" '"amount": "-12.00000"'
assert_not_contains "ledger keeps reconciliation out of the register" "$ledger" '"reconciled"'

reconciliation=$(rpc reconciliation_page '{
  "p_book_id":"web-test",
  "p_account_id":"Current Account"
}')
assert_contains "reconciliation page is exposed" "$reconciliation" '"component":"reconciliation_row"'
assert_contains "reconciliation page includes posting assets" "$reconciliation" '"asset": "GBP"'
assert_contains "new postings are unreconciled" "$reconciliation" '"reconciled": false'

reconciled=$(rpc set_posting_reconciled "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_account_id\":\"Current Account\",
  \"p_reconciled\":true
}")
assert_contains "set_posting_reconciled marks a posting" "$reconciled" '"reconciled":true'
assert_contains "set_posting_reconciled echoes natural posting identity" "$reconciled" '"account":"Current Account"'

replaced=$(rpc replace_transaction "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_transaction\":{
    \"date\":\"2026-02-03\",
    \"comment\":\"Groceries updated\",
    \"lines\":[
      {\"account\":\"Current Account\",\"amount\":-15},
      {\"account\":\"Food\",\"amount\":15}
    ]
  }
}")
assert_contains "replace_transaction mutation" "$replaced" "\"xid\":$xid"

reopened=$(rpc reconciliation_page '{
  "p_book_id":"web-test",
  "p_account_id":"Current Account"
}')
assert_contains "changing a posting amount reopens reconciliation" "$reopened" '"reconciled": false'

rpc set_posting_reconciled "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_account_id\":\"Current Account\",
  \"p_reconciled\":true
}" >/dev/null

preserved=$(rpc replace_transaction "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_transaction\":{
    \"date\":\"2026-02-03\",
    \"comment\":\"Header-only replacement\",
    \"lines\":[
      {\"account\":\"Current Account\",\"amount\":-15},
      {\"account\":\"Food\",\"amount\":15}
    ]
  }
}")
assert_contains "replace_transaction preserves unchanged posting identity and amount" "$preserved" "\"xid\":$xid"

line=$(rpc update_ledger_line "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_account_id\":\"Current Account\",
  \"p_date\":\"2026-02-04\",
  \"p_description\":\"Line updated\"
}")
assert_contains "update_ledger_line mutation" "$line" '"account_id":"Current Account"'

unreconciled=$(rpc set_posting_reconciled "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_account_id\":\"Current Account\",
  \"p_reconciled\":false
}")
assert_contains "set_posting_reconciled can undo reconciliation" "$unreconciled" '"reconciled":false'
assert_contains "set_posting_reconciled is idempotent" "$(rpc set_posting_reconciled "{
  \"p_book_id\":\"web-test\",
  \"p_xid\":$xid,
  \"p_account_id\":\"Current Account\",
  \"p_reconciled\":false
}")" '"reconciled":false'

split_fixture=$(rpc create_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-05",
    "comment":"Browser split fixture",
    "lines":[
      {"account":"Current Account","amount":-20},
      {"account":"Food","amount":15,"comment":"Food share"},
      {"account":"Fees","amount":5,"comment":"Fee share"}
    ]
  }
}')
assert_contains "browser split fixture" "$split_fixture" '"book_id":"web-test"'

precision_fixture=$(rpc create_transaction '{
  "p_book_id":"web-test",
  "p_transaction":{
    "date":"2026-02-05",
    "comment":"Precision fixture",
    "lines":[
      {"account":"Current Account","amount":"-9007199254740993.00001"},
      {"account":"Food","amount":"9007199254740993.00001"}
    ]
  }
}')
assert_contains "browser precision fixture" "$precision_fixture" '"book_id":"web-test"'
precise_ledger=$(rpc ledger_page '{"p_book_id":"web-test","p_account_id":"Current Account"}')
assert_contains "ledger preserves exact high-precision amounts as strings" "$precise_ledger" '"amount": "-9007199254740993.00001"'
precise_journal=$(rpc general_journal_page '{"p_book_id":"web-test"}')
assert_contains "Journal preserves exact high-precision display amounts" "$precise_journal" '"9007199254740993.00001"'
precise_reconciliation=$(rpc reconciliation_page '{"p_book_id":"web-test","p_account_id":"Current Account"}')
assert_contains "Reconciliation preserves exact high-precision display amounts" "$precise_reconciliation" '"amount": "-9007199254740993.00001"'
precise_accounts=$(rpc accounts_page '{"p_book_id":"web-test"}')
assert_contains "account summaries expose exact decimals as text" "$precise_accounts" '.00001"'
precise_report=$(rpc report_page '{"p_book_id":"web-test","p_report_id":"trial-balance","p_as_of":"2026-12-31"}')
assert_contains "report cells expose exact decimals as text" "$precise_report" '"exact":'
assert_contains "report cells preserve rounded high-magnitude values without Float loss" "$precise_report" '9007199254741028.00"'

navigation_fixture=1
while [ "$navigation_fixture" -le 18 ]; do
	navigation_label=$(printf '%02d' "$navigation_fixture")
	rpc create_transaction "{
  \"p_book_id\":\"web-test\",
  \"p_transaction\":{
    \"date\":\"2026-02-06\",
    \"comment\":\"Navigation fixture $navigation_label\",
    \"simple\":{
      \"account\":\"Current Account\",
      \"transfer_account\":\"Food\",
      \"amount\":\"-1\"
    }
  }
}" >/dev/null
	navigation_fixture=$((navigation_fixture + 1))
done

admin_page=$(rpc admin_page '{}')
assert_contains "global admin page is exposed" "$admin_page" '"component":"global_user"'
assert_contains "global admin page identifies its administrator" "$admin_page" '"global_admin": true'
assert_contains "global users expose SQL-owned enable actions" "$admin_page" '"action_key": "action.admin.disable-user"'
assert_contains "global users expose SQL-owned action labels" "$admin_page" '"action_label": "Disable"'
assert_not_contains "global admin page has no attached Book context" "$admin_page" '"component":"book_option"'

for page_call in \
    'book_page {"p_book_id":"web-test"}' \
    'reports_page {"p_book_id":"web-test"}' \
    'report_page {"p_book_id":"web-test","p_report_id":"balance-sheet","p_as_of":"2026-12-31"}' \
    'accounts_page {"p_book_id":"web-test"}' \
	'reconciliation_page {"p_book_id":"web-test"}' \
	'general_journal_page {"p_book_id":"web-test"}' \
	'add_book_page {}' \
    'add_account_page {"p_book_id":"web-test"}'
do
	name=${page_call%% *}
	body=${page_call#* }
	page=$(rpc "$name" "$body")
	assert_contains "$name is exposed" "$page" '"component":"page_context"'
	assert_contains "$name includes book navigation" "$page" '"component":"book_option"'
done

report_library=$(rpc reports_page '{"p_book_id":"web-test"}')
assert_contains "report library includes its report choices" "$report_library" '"component":"report_option"'
assert_not_contains "report library omits account choices" "$report_library" '"component":"account_option"'
account_workspace=$(rpc accounts_page '{"p_book_id":"web-test"}')
assert_not_contains "account list omits register-only account choices" "$account_workspace" '"component":"account_option"'
assert_not_contains "account list omits report choices" "$account_workspace" '"component":"report_option"'
all_reconciliation=$(rpc reconciliation_page '{"p_book_id":"web-test"}')
assert_contains "reconciliation includes its account filter choices" "$all_reconciliation" '"component":"account_option"'
assert_not_contains "reconciliation omits report choices" "$all_reconciliation" '"component":"report_option"'

error_file="$SERVER_TMP/error.json"

rpc create_book '{
  "p_id":"web-company",
  "p_name":"Web Company",
  "p_reporting_asset":"GBP",
  "p_create_standard_accounts":true
}' >/dev/null
company_page=$(rpc configure_uk_company '{
  "p_book_id":"web-company",
  "p_legal_name":"Web Company Ltd",
  "p_legal_form":"private_limited_shares",
  "p_accounting_framework":"frs105",
  "p_vat_scheme":"standard_invoice",
  "p_period_id":"2026",
  "p_period_start":"2026-01-01",
  "p_period_end":"2026-12-31"
}')
assert_contains "configure_uk_company returns complete Book page" "$company_page" '"configuration_status": "complete"'
assert_contains "configure_uk_company creates a VAT control choice" "$company_page" '"path": "Liabilities › VAT Control"'
company_reports=$(rpc reports_page '{"p_book_id":"web-company"}')
company_report_count=$(printf '%s' "$company_reports" | grep -o '"component":"report_option"' | wc -l)
assert_contains "configured company exposes all report choices" "$company_report_count" '16'

rpc create_book '{
  "p_id":"web-company-invalid",
  "p_name":"Web Company Invalid",
  "p_reporting_asset":"GBP",
  "p_create_standard_accounts":true
}' >/dev/null
invalid_company_status=$("$CURL" -sS -o "$error_file" -w '%{http_code}' \
    -X POST "$BASE/rpc/configure_uk_company" \
    -H 'content-type: application/json' \
    -d '{
      "p_book_id":"web-company-invalid",
      "p_legal_name":"Web Company Invalid Ltd",
      "p_legal_form":"private_limited_shares",
      "p_accounting_framework":"frs105",
      "p_vat_scheme":"standard_invoice",
      "p_period_id":"2026",
      "p_period_start":"2026-01-01",
      "p_period_end":"2026-12-31",
      "p_vat_control_acct":"Assets"
    }')
assert_contains "invalid company configuration uses HTTP error status" "$invalid_company_status" '400'
assert_contains "invalid company control returns structured detail" "$(cat "$error_file")" 'VAT_CONTROL_ACCOUNT_INVALID'
invalid_company_page=$(rpc book_page '{"p_book_id":"web-company-invalid"}')
assert_contains "failed company configuration remains ordinary" "$invalid_company_page" '"configuration_status": "ordinary"'

missing_posting_status=$("$CURL" -sS -o "$error_file" -w '%{http_code}' \
    -X POST "$BASE/rpc/set_posting_reconciled" \
    -H 'content-type: application/json' \
    -d '{
      "p_book_id":"web-test",
      "p_xid":-1,
      "p_account_id":"Current Account",
      "p_reconciled":true
    }')
assert_contains "missing posting reconciliation uses HTTP error status" "$missing_posting_status" '404'
assert_contains "missing posting reconciliation includes structured detail" "$(cat "$error_file")" 'POSTING_NOT_FOUND'

error_status=$("$CURL" -sS -o "$error_file" -w '%{http_code}' \
    -X POST "$BASE/rpc/create_transaction" \
    -H 'content-type: application/json' \
    -d '{
      "p_book_id":"web-test",
      "p_transaction":{
        "date":"2026-02-05",
        "lines":[
          {"account":"Current Account","amount":-3},
          {"account":"Food","amount":2}
        ]
      }
    }')
assert_contains "validation failure uses HTTP error status" "$error_status" '400'
assert_contains "validation failure includes structured detail" "$(cat "$error_file")" 'TRANSACTION_NOT_BALANCED'

one_sided_status=$("$CURL" -sS -o "$error_file" -w '%{http_code}' \
    -X POST "$BASE/rpc/create_transaction" \
    -H 'content-type: application/json' \
    -d '{
      "p_book_id":"web-test",
      "p_transaction":{
        "date":"2026-02-05",
        "lines":[{"account":"Current Account","amount":-3}]
      }
    }')
assert_contains "one-sided transaction uses HTTP error status" "$one_sided_status" '400'
assert_contains "one-sided transaction includes structured detail" "$(cat "$error_file")" 'TRANSACTION_REQUIRES_TWO_LINES'

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
assert_contains "static server serves Elm" "$index" '<title>Njord</title>'
bootstrap=$("$CURL" -fsS "$UI/bootstrap.js")
assert_contains "static server serves its external bootstrap" "$bootstrap" 'Elm.Main.init'
source_status=$("$CURL" -sS -o /dev/null -w '%{http_code}' "$UI/src/Main.elm")
assert_contains "static server hides frontend source" "$source_status" '404'
routed_index=$("$CURL" -fsS "$UI/?page=journal&book=web-test")
assert_contains "static server serves shareable query routes" "$routed_index" '<title>Njord</title>'
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
proxied=$("$CURL" -fsS -X POST "$UI/api/control/rpc/shell_page" -H 'content-type: application/json' -d '{}')
assert_contains "static server proxies explicit control RPCs" "$proxied" '"component":"book_option"'
unscoped_status=$("$CURL" -sS -o /dev/null -w '%{http_code}' -X POST "$UI/rpc/shell_page" -H 'content-type: application/json' -d '{}')
assert_contains "static server rejects unscoped RPCs" "$unscoped_status" '404'

# Chromium can emit large core files when its short-lived new-tab processes
# terminate in constrained CI/container environments. They are not test output.
ulimit -c 0 2>/dev/null || true
node tests/browser.mjs "$UI"

echo "ok - PostgREST API test suite passed"
