#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

DB="${PLUTUS_TEST_DB:-plutus_test_$$}"
PSQL="${PSQL:-psql}"
CREATEDB="${CREATEDB:-createdb}"
DROPDB="${DROPDB:-dropdb}"
SQL_TMP=

if "$PSQL" -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
	run()
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
else
	echo "Could not connect to PostgreSQL." >&2
	echo "Set PGUSER/PGHOST or run with sudo access to the postgres user." >&2
	exit 1
fi

cleanup()
{
	run "$DROPDB" --if-exists "$DB" >/dev/null 2>&1 || true
	if [ -n "$SQL_TMP" ]; then
		rm -rf "$SQL_TMP"
	fi
}

trap cleanup EXIT HUP INT TERM

cleanup
run "$CREATEDB" "$DB"

SQL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/plutus-sql.XXXXXX")
cp sql/*.sql "$SQL_TMP"/
cp tests/basic.sql "$SQL_TMP"/basic.sql
chmod a+rx "$SQL_TMP"
chmod a+r "$SQL_TMP"/*.sql

run_sql()
{
	run env PGOPTIONS="-c client_min_messages=warning" \
	    "$PSQL" -q -v ON_ERROR_STOP=1 -X -d "$DB" -f "$1"
}

load_schema()
{
	run_sql "$SQL_TMP/plutus.sql" >/dev/null
}

load_schema
load_schema
run_sql "$SQL_TMP/basic.sql"

echo "ok - SQL test suite passed"
