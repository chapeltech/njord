#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

CONTROL_DB="${NJORD_TOPOLOGY_CONTROL_DB:-njord_control_test_$$}"
BOOK_A="${NJORD_TOPOLOGY_BOOK_A:-njord_book_a_$$}"
BOOK_B="${NJORD_TOPOLOGY_BOOK_B:-njord_book_b_$$}"
TEST_ROLE="${NJORD_TOPOLOGY_ROLE:-njord_topology_user_$$}"
FRIEND_ROLE="${NJORD_TOPOLOGY_FRIEND_ROLE:-topology-friend-$$}"
GLOBAL_USER_ROLE="${NJORD_TOPOLOGY_GLOBAL_USER_ROLE:-topology-global-$$}"
RACE_OWNER_ROLE="${NJORD_TOPOLOGY_RACE_OWNER_ROLE:-topology-race-owner-$$}"
AUTHENTICATOR_ROLE="${NJORD_TOPOLOGY_AUTHENTICATOR_ROLE:-topology-authenticator-$$}"
ANONYMOUS_ROLE="${NJORD_TOPOLOGY_ANONYMOUS_ROLE:-topology-anonymous-$$}"
GATEWAY_ROLE="${NJORD_TOPOLOGY_GATEWAY_ROLE:-topology-gateway-$$}"
PRIVILEGED_PARENT_ROLE="${NJORD_TOPOLOGY_PRIVILEGED_PARENT_ROLE:-topology-privileged-parent-$$}"
UNSAFE_CHILD_ROLE="${NJORD_TOPOLOGY_UNSAFE_CHILD_ROLE:-topology-unsafe-child-$$}"
PSQL=${PSQL:-psql}
CREATEDB=${CREATEDB:-createdb}
DROPDB=${DROPDB:-dropdb}
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
	exit 1
fi

cleanup()
{
	run "$DROPDB" --if-exists --force "$BOOK_A" >/dev/null 2>&1 || true
	run "$DROPDB" --if-exists --force "$BOOK_B" >/dev/null 2>&1 || true
	run "$DROPDB" --if-exists --force "$CONTROL_DB" >/dev/null 2>&1 || true
	run "$PSQL" -X -d postgres -c "DROP ROLE IF EXISTS \"$TEST_ROLE\"" >/dev/null 2>&1 || true
	run "$PSQL" -X -d postgres -c "DROP ROLE IF EXISTS \"$FRIEND_ROLE\"" >/dev/null 2>&1 || true
	for cleanup_role in "$GLOBAL_USER_ROLE" "$RACE_OWNER_ROLE" \
	    "$AUTHENTICATOR_ROLE" "$ANONYMOUS_ROLE" "$GATEWAY_ROLE" \
	    "$UNSAFE_CHILD_ROLE" "$PRIVILEGED_PARENT_ROLE"
	do
		run "$PSQL" -X -d postgres -c \
		    "DROP ROLE IF EXISTS \"$cleanup_role\"" >/dev/null 2>&1 || true
	done
	for book_id in "$BOOK_A" "$BOOK_B"
	do
		for access_level in ro rw admin
		do
			access_role=$(run "$PSQL" -X -d postgres -Atqc \
			    "SELECT format('njord_%s_%s_%s', left('$book_id', 20), substr(md5('$book_id'), 1, 24), '$access_level')")
			run "$PSQL" -X -d postgres -c \
			    "DROP ROLE IF EXISTS \"$access_role\"" >/dev/null 2>&1 || true
		done
	done
	[ -z "$SQL_TMP" ] || rm -rf "$SQL_TMP"
}
trap cleanup EXIT HUP INT TERM

cleanup
SQL_TMP=$(mktemp -d "${TMPDIR:-/tmp}/njord-topology.XXXXXX")
mkdir "$SQL_TMP/sql" "$SQL_TMP/examples"
cp sql/*.sql "$SQL_TMP/sql/"
cp examples/*.sql "$SQL_TMP/examples/"
cp tests/control-auth.sql "$SQL_TMP/control-auth.sql"
chmod a+rx "$SQL_TMP" "$SQL_TMP/sql" "$SQL_TMP/examples"
chmod a+r "$SQL_TMP"/*.sql "$SQL_TMP/sql"/*.sql "$SQL_TMP/examples"/*.sql

run "$CREATEDB" "$CONTROL_DB"
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" \
    -f "$SQL_TMP/sql/control.sql" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres \
    -v authenticator_role="$AUTHENTICATOR_ROLE" \
    -v anonymous_role="$ANONYMOUS_ROLE" -v gateway_role="$GATEWAY_ROLE" \
    -f "$SQL_TMP/sql/create-web-runtime-roles.sql" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" \
    -v authenticator_role="$AUTHENTICATOR_ROLE" \
    -v anonymous_role="$ANONYMOUS_ROLE" -v gateway_role="$GATEWAY_ROLE" \
    -f "$SQL_TMP/sql/grant-control-gateway.sql" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT has_function_privilege(
       '$GATEWAY_ROLE',
       'api.authenticate_gateway_identity(bigint,text,text)', 'EXECUTE')
       AND NOT has_function_privilege(
       '$ANONYMOUS_ROLE',
       'api.authenticate_gateway_identity(bigint,text,text)', 'EXECUTE')")" = t ]
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT pg_has_role('$AUTHENTICATOR_ROLE', '$GATEWAY_ROLE', 'MEMBER')")" = t ]

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres -c \
    "CREATE ROLE \"$PRIVILEGED_PARENT_ROLE\" NOLOGIN CREATEDB;
     CREATE ROLE \"$UNSAFE_CHILD_ROLE\" NOLOGIN NOINHERIT;
     GRANT \"$PRIVILEGED_PARENT_ROLE\" TO \"$UNSAFE_CHILD_ROLE\";" >/dev/null
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres \
    -v database_role="$UNSAFE_CHILD_ROLE" -v role_login=NOLOGIN \
    -v role_kind=test -f "$SQL_TMP/sql/ensure-unprivileged-role.sql" \
    >/dev/null 2>&1
then
	echo "runtime role with a privileged ancestor was accepted" >&2
	exit 1
fi
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres -c \
    "REVOKE \"$PRIVILEGED_PARENT_ROLE\" FROM \"$UNSAFE_CHILD_ROLE\";
     DROP ROLE \"$UNSAFE_CHILD_ROLE\";" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" \
    -f "$SQL_TMP/control-auth.sql" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres \
    -v database_role="$TEST_ROLE" \
    -f "$SQL_TMP/sql/create-user-role.sql" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres -c \
    "ALTER ROLE \"$TEST_ROLE\" NOINHERIT" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres \
    -v database_role="$TEST_ROLE" \
    -f "$SQL_TMP/sql/create-user-role.sql" >/dev/null
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT rolinherit FROM pg_roles WHERE rolname = '$TEST_ROLE'")" = t ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" \
    -v control_database="$CONTROL_DB" -v database_role="$TEST_ROLE" \
    -f "$SQL_TMP/sql/grant-control-user.sql" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT has_schema_privilege('$TEST_ROLE', 'public', 'CREATE')")" = f ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "CREATE FUNCTION public.control_default_privilege_probe()
     RETURNS INTEGER LANGUAGE SQL AS 'SELECT 1';" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE', 'public.control_default_privilege_probe()', 'EXECUTE')")" = f ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "DROP FUNCTION public.control_default_privilege_probe();" >/dev/null

database_role=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc 'SELECT current_user')

create_test_book()
{
	book_id=$1
	book_name=$2
	run "$CREATEDB" "$book_id"
	run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$book_id" \
	    -v book_id="$book_id" -v book_name="$book_name" \
	    -v reporting_asset=GBP -v entity_type=household \
	    -v create_standard_accounts=true \
	    -f "$SQL_TMP/examples/new-book.sql" >/dev/null
	run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" \
	    -v book_id="$book_id" -v book_name="$book_name" \
	    -v reporting_asset=GBP -v entity_type=household \
	    -v database_role="$database_role" \
	    -f "$SQL_TMP/sql/register-book.sql" >/dev/null
}

create_test_book "$BOOK_A" 'Topology A'
create_test_book "$BOOK_B" 'Topology B'
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    'SELECT count(*) FROM njord_control.global_administrators')" = 1 ]

if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" \
    -v book_id="$BOOK_B" -f "$SQL_TMP/sql/set-book-access.sql" \
    >/dev/null 2>&1
then
	echo "Book access installer accepted the wrong database" >&2
	exit 1
fi

for book_id in "$BOOK_A" "$BOOK_B"
do
	run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$book_id" \
	    -v book_id="$book_id" \
	    -f "$SQL_TMP/sql/set-book-access.sql" >/dev/null
done
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "CREATE FUNCTION public.book_default_privilege_probe()
     RETURNS INTEGER LANGUAGE SQL AS 'SELECT 1';" >/dev/null
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE', 'public.book_default_privilege_probe()', 'EXECUTE')")" = f ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "DROP FUNCTION public.book_default_privilege_probe();" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SELECT njord_control.register_existing_book(
       '$BOOK_A', 'Topology A', 'GBP', 'household', '$TEST_ROLE');
     SELECT njord_control.register_existing_book(
       '$BOOK_B', 'Topology B', 'GBP', 'household', '$TEST_ROLE');" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "INSERT INTO njord_control.global_administrators (principal_id, granted_by)
     SELECT id, id FROM njord_control.principals
      WHERE database_role = '$TEST_ROLE'
     ON CONFLICT (principal_id) DO NOTHING;" >/dev/null

BOOK_A_RO_ROLE=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT njord_control.book_access_role('$BOOK_A', 'ro')")
BOOK_A_RW_ROLE=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT njord_control.book_access_role('$BOOK_A', 'rw')")
BOOK_A_ADMIN_ROLE=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT njord_control.book_access_role('$BOOK_A', 'admin')")
BOOK_B_RO_ROLE=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT njord_control.book_access_role('$BOOK_B', 'ro')")
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT count(*) FROM pg_roles
      WHERE rolname IN ('$BOOK_A_RO_ROLE', '$BOOK_A_RW_ROLE', '$BOOK_A_ADMIN_ROLE')
        AND NOT rolcanlogin AND NOT rolsuper AND NOT rolcreatedb
        AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls")" = 3 ]
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT pg_has_role('$TEST_ROLE', '$BOOK_A_ADMIN_ROLE', 'MEMBER')")" = t ]
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT rolinherit FROM pg_roles WHERE rolname = '$TEST_ROLE'")" = t ]

[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc 'SELECT count(*) FROM books')" = 1 ]
[ "$(run "$PSQL" -X -d "$BOOK_B" -Atqc 'SELECT count(*) FROM books')" = 1 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_schema_privilege('$TEST_ROLE', 'public', 'CREATE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc 'SELECT njord.database_book_id()')" = "$BOOK_A" ]
[ "$(run "$PSQL" -X -d "$BOOK_B" -Atqc 'SELECT njord.database_book_id()')" = "$BOOK_B" ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT to_regprocedure('api.admin_page()') IS NULL")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT to_regprocedure('api.add_book_page()') IS NULL")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT to_regprocedure(
       'api.create_book(character varying,character varying,character varying,boolean,character varying)'
     ) IS NOT NULL")" = t ]

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "CALL open_account('Topology Bank', '2026-01-01', 'A', 'GBP', 100)" \
    >/dev/null
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT count(*) FROM accounts WHERE id = 'Topology Bank'")" = 1 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc 'SELECT count(*) FROM transactions')" = 1 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc 'SELECT count(*) FROM postings')" = 2 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT count(*) FROM postings
      JOIN transactions ON transactions.id = postings.transaction_id
      JOIN accounts ON accounts.id = postings.account
     WHERE accounts.account_type IN ('A', 'Q')")" = 2 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT count(*) FROM ledger('Topology Bank')")" = 1 ]

if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "INSERT INTO books (id, name, reporting_asset) VALUES ('wrong_book', 'Wrong', 'GBP')" \
    >/dev/null 2>&1
then
	echo "singleton book guard accepted a second book" >&2
	exit 1
fi

if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "BEGIN;
     DELETE FROM book_reporting_currencies WHERE book_id = '$BOOK_A';
     DELETE FROM books WHERE id = '$BOOK_A';
     COMMIT;" >/dev/null 2>&1
then
	echo "singleton Book identity could be deleted without dropping its database" >&2
	exit 1
fi
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc 'SELECT count(*) FROM books')" = 1 ]

[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*) FROM api.shell_page(NULL) WHERE component = 'book_option'")" = 2 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT payload ->> 'text' FROM api.shell_page(NULL)
      WHERE component = 'presentation' AND row_key = 'nav.accounts'")" = "Accounts" ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT presentation.resolve_locale('en')")" = "en-GB" ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT presentation.resolve_locale('zz-ZZ')")" = "en-GB" ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT count(*) FROM api.shell_page('$BOOK_A')
      WHERE component = 'presentation'")" -gt 100 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT count(*) FROM api.shell_page('$BOOK_A')
      WHERE component = 'admin_context'")" = 0 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT count(*) FROM api.shell_page('$BOOK_A')
      WHERE component = 'book_option'
        AND payload ? 'access_level'")" = 0 ]

[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM api.shell_page(NULL) WHERE component = 'book_option'")" = 2 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM api.admin_page() WHERE component = 'global_user'")" -ge 1 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM api.admin_page() WHERE component = 'book_option'")" = 0 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM api.add_book_page()
      WHERE component IN ('page_context', 'asset_option', 'book_entity_type_option')")" -gt 2 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT payload ->> 'reporting_asset' FROM api.add_book_page()
      WHERE component = 'page_context'")" = GBP ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT payload ->> 'can_administer_global' FROM api.shell_page(NULL)
      WHERE component = 'admin_context'")" = true ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM api.book_acl_page('$BOOK_A')
      WHERE component = 'book_access_level_option'")" = 3 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT payload ->> 'access_level' FROM api.book_acl_page('$BOOK_A')
      WHERE component = 'book_access' AND payload ->> 'current_user' = 'true'")" = admin ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SET ROLE \"$TEST_ROLE\";
     SELECT * FROM api.invite_global_user(
       '$GLOBAL_USER_ROLE', 987654320, 'Topology Global User'
     );" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*) FROM njord_control.principals
      WHERE database_role = '$GLOBAL_USER_ROLE'")" = 1 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*)
       FROM njord_control.book_memberships AS membership
       JOIN njord_control.principals AS principal
         ON principal.id = membership.principal_id
      WHERE principal.database_role = '$GLOBAL_USER_ROLE'")" = 0 ]
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*)
       FROM njord_control.global_administrators AS administrator
       JOIN njord_control.principals AS principal
         ON principal.id = administrator.principal_id
      WHERE principal.database_role = '$GLOBAL_USER_ROLE'")" = 0 ]
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM njord_control.books" >/dev/null 2>&1
then
	echo "control user could read private catalogue tables" >&2
	exit 1
fi
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$TEST_ROLE\"; SELECT count(*) FROM accounts")" -gt 0 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) FROM api.shell_page('$BOOK_A')
      WHERE component = 'presentation'")" -gt 100 ]

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "BEGIN;
     SELECT * FROM api.create_book(
       'catalog_only', 'Catalogue transaction', 'GBP', TRUE, 'household'
     );
     ROLLBACK;" >/dev/null
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT count(*) FROM pg_roles
      WHERE rolname LIKE 'njord_catalog_only_%'")" = 0 ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SELECT * FROM api.create_book(
       'catalog_delete', 'Catalogue deletion', 'GBP', TRUE, 'household'
     );" >/dev/null
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT count(*) FROM pg_roles
      WHERE rolname LIKE 'njord_catalog_delete_%'")" = 3 ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "DELETE FROM njord_control.books WHERE id = 'catalog_delete';" >/dev/null
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT count(*) FROM pg_roles
      WHERE rolname LIKE 'njord_catalog_delete_%'")" = 0 ]

if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "DELETE FROM njord_control.book_memberships
      WHERE book_id = '$BOOK_A'" >/dev/null 2>&1
then
	echo "control catalogue allowed the final owner to be removed" >&2
	exit 1
fi
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT pg_has_role('$TEST_ROLE', '$BOOK_A_ADMIN_ROLE', 'MEMBER')")" = t ]

# Two sessions must not each remove the owner visible to the other. Both delete
# before commit; the common Book row lock gives them a serial order, so exactly
# one commit succeeds and the losing transaction restores its owner on rollback.
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "INSERT INTO njord_control.principals (database_role, display_name)
     VALUES ('$RACE_OWNER_ROLE', 'Race Owner');
     INSERT INTO njord_control.book_memberships (
       book_id, principal_id, membership_role
     ) SELECT '$BOOK_A', id, 'owner'
         FROM njord_control.principals
        WHERE database_role = '$RACE_OWNER_ROLE';
     DELETE FROM njord_control.book_memberships AS membership
      USING njord_control.principals AS principal
      WHERE membership.book_id = '$BOOK_A'
        AND membership.principal_id = principal.id
        AND principal.database_role = '$database_role';" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*) FROM njord_control.book_memberships
      WHERE book_id = '$BOOK_A' AND membership_role = 'owner'")" = 2 ]
test_principal=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT id FROM njord_control.principals WHERE database_role = '$TEST_ROLE'")
race_principal=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT id FROM njord_control.principals WHERE database_role = '$RACE_OWNER_ROLE'")

race_a_status=0
race_b_status=0
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "BEGIN;
     DELETE FROM njord_control.book_memberships
      WHERE book_id = '$BOOK_A' AND principal_id = '$test_principal';
     SELECT pg_sleep(1);
     COMMIT;" >"$SQL_TMP/race-a.out" 2>&1 &
race_a_pid=$!
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "BEGIN;
     DELETE FROM njord_control.book_memberships
      WHERE book_id = '$BOOK_A' AND principal_id = '$race_principal';
     SELECT pg_sleep(1);
     COMMIT;" >"$SQL_TMP/race-b.out" 2>&1 &
race_b_pid=$!
wait "$race_a_pid" || race_a_status=$?
wait "$race_b_pid" || race_b_status=$?
if { [ "$race_a_status" -eq 0 ] && [ "$race_b_status" -eq 0 ]; } || \
   { [ "$race_a_status" -ne 0 ] && [ "$race_b_status" -ne 0 ]; }
then
	echo "last-owner race did not produce exactly one successful commit" >&2
	cat "$SQL_TMP/race-a.out" "$SQL_TMP/race-b.out" >&2
	exit 1
fi
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*) FROM njord_control.book_memberships
      WHERE book_id = '$BOOK_A' AND membership_role = 'owner'")" = 1 ]

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "INSERT INTO njord_control.book_memberships (
       book_id, principal_id, membership_role
     ) VALUES
       ('$BOOK_A', '$test_principal', 'owner'),
       ('$BOOK_A', '$race_principal', 'owner')
     ON CONFLICT (book_id, principal_id) DO UPDATE
       SET membership_role = EXCLUDED.membership_role;" >/dev/null

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SET ROLE \"$TEST_ROLE\";
     SELECT * FROM api.invite_book_user(
       '$BOOK_A', '$FRIEND_ROLE', 'ro', 987654321, 'Topology Friend'
     );" >/dev/null
friend_principal=$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT principal.id
       FROM njord_control.principals AS principal
      WHERE principal.database_role = '$FRIEND_ROLE'")
[ -n "$friend_principal" ]
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT pg_has_role('$FRIEND_ROLE', '$BOOK_A_RO_ROLE', 'MEMBER')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$FRIEND_ROLE\"; SELECT count(*) > 0 FROM accounts")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$FRIEND_ROLE\";
     SELECT count(*) > 0 FROM njord.standard_account_catalog")" = t ]
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "SET ROLE \"$FRIEND_ROLE\";
     INSERT INTO asset (id) VALUES ('FRIEND-RO-MUST-FAIL')" >/dev/null 2>&1
then
	echo "RO capability role allowed a direct SQL write" >&2
	exit 1
fi
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "UPDATE njord_control.book_memberships
        SET book_id = '$BOOK_B'
      WHERE book_id = '$BOOK_A'
        AND principal_id = '$friend_principal';" >/dev/null
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT NOT pg_has_role('$FRIEND_ROLE', '$BOOK_A_RO_ROLE', 'MEMBER')
        AND pg_has_role('$FRIEND_ROLE', '$BOOK_B_RO_ROLE', 'MEMBER')")" = t ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "UPDATE njord_control.book_memberships
        SET book_id = '$BOOK_A'
      WHERE book_id = '$BOOK_B'
        AND principal_id = '$friend_principal';" >/dev/null
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT pg_has_role('$FRIEND_ROLE', '$BOOK_A_RO_ROLE', 'MEMBER')
        AND NOT pg_has_role('$FRIEND_ROLE', '$BOOK_B_RO_ROLE', 'MEMBER')")" = t ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d postgres \
    -v database_role="$FRIEND_ROLE" \
    -f "$SQL_TMP/sql/create-user-role.sql" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" \
    -v control_database="$CONTROL_DB" -v database_role="$FRIEND_ROLE" \
    -f "$SQL_TMP/sql/grant-control-user.sql" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SET ROLE \"$FRIEND_ROLE\";
     SELECT payload ->> 'can_administer_global' FROM api.shell_page(NULL)
      WHERE component = 'admin_context'")" = false ]
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SET ROLE \"$FRIEND_ROLE\"; SELECT * FROM api.admin_page()" \
    >/dev/null 2>&1
then
	echo "Book user could open global Admin" >&2
	exit 1
fi
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT membership.membership_role
       FROM njord_control.book_memberships AS membership
      WHERE membership.book_id = '$BOOK_A'
        AND membership.principal_id = '$friend_principal'")" = viewer ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SET ROLE \"$TEST_ROLE\";
     SELECT * FROM api.update_book_access(
       '$BOOK_A', '$friend_principal', 'rw'
     );" >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT membership.membership_role
       FROM njord_control.book_memberships AS membership
      WHERE membership.book_id = '$BOOK_A'
        AND membership.principal_id = '$friend_principal'")" = editor ]
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT NOT pg_has_role('$FRIEND_ROLE', '$BOOK_A_RO_ROLE', 'MEMBER')
        AND pg_has_role('$FRIEND_ROLE', '$BOOK_A_RW_ROLE', 'MEMBER')")" = t ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "SET ROLE \"$FRIEND_ROLE\";
     SELECT * FROM api.create_transaction(
       '$BOOK_A',
       '{\"date\":\"2026-01-02\",\"comment\":\"Friend RW edit\",\"lines\":[
          {\"account\":\"Topology Bank\",\"amount\":-2},
          {\"account\":\"Uncategorised Expenses\",\"amount\":2}
        ]}'::jsonb
     );" >/dev/null
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "DELETE FROM njord_control.principals
      WHERE id = '$friend_principal'" >/dev/null 2>&1
then
	echo "control catalogue deleted a principal with Book access" >&2
	exit 1
fi
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "SET ROLE \"$TEST_ROLE\";
     SELECT * FROM api.remove_book_access('$BOOK_A', '$friend_principal');" \
    >/dev/null
[ "$(run "$PSQL" -X -d "$CONTROL_DB" -Atqc \
    "SELECT count(*) FROM njord_control.book_memberships
      WHERE book_id = '$BOOK_A' AND principal_id = '$friend_principal'")" = 0 ]
[ "$(run "$PSQL" -X -d postgres -Atqc \
    "SELECT NOT pg_has_role('$FRIEND_ROLE', '$BOOK_A_RO_ROLE', 'MEMBER')
        AND NOT pg_has_role('$FRIEND_ROLE', '$BOOK_A_RW_ROLE', 'MEMBER')
        AND NOT pg_has_role('$FRIEND_ROLE', '$BOOK_A_ADMIN_ROLE', 'MEMBER')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT NOT has_table_privilege('$FRIEND_ROLE', 'accounts', 'SELECT')")" = t ]

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "UPDATE njord_control.book_memberships
        SET membership_role = 'viewer'
      WHERE book_id = '$BOOK_A'
        AND principal_id = (
            SELECT id FROM njord_control.principals
            WHERE database_role = '$TEST_ROLE'
        );" >/dev/null
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$TEST_ROLE\"; SELECT database FROM api.adapter_status()")" = "$BOOK_A" ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$TEST_ROLE\"; SELECT count(*) FROM api.accounts_page('$BOOK_A')")" -gt 0 ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SET ROLE \"$TEST_ROLE\";
     SELECT count(*) >= 0
     FROM bsheet_report('$BOOK_A', TIMESTAMP '2026-12-31')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE',
       'api.authorize_book_database_deletion(character varying,character varying)',
       'EXECUTE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_sequence_privilege('$TEST_ROLE', 'xactions_xid_seq', 'SELECT')")" = f ]
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "SET ROLE \"$TEST_ROLE\";
     INSERT INTO asset (id) VALUES ('RO-MUST-FAIL')" >/dev/null 2>&1
then
	echo "RO Book access allowed a direct SQL write" >&2
	exit 1
fi

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "UPDATE njord_control.book_memberships
        SET membership_role = 'editor'
      WHERE book_id = '$BOOK_A'
        AND principal_id = (
            SELECT id FROM njord_control.principals
            WHERE database_role = '$TEST_ROLE'
        );" >/dev/null
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE',
       'api.create_transaction(character varying,jsonb)', 'EXECUTE')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE',
       'api.update_book_settings(character varying,character varying,character varying)',
       'EXECUTE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE',
       'api.authorize_book_database_deletion(character varying,character varying)',
       'EXECUTE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_table_privilege('$TEST_ROLE', 'xactions', 'INSERT')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_table_privilege('$TEST_ROLE', 'accts', 'INSERT')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_column_privilege('$TEST_ROLE', 'accts', 'name', 'UPDATE')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_column_privilege('$TEST_ROLE', 'accts', 'type', 'UPDATE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_column_privilege('$TEST_ROLE', 'accts', 'atype', 'UPDATE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_table_privilege('$TEST_ROLE', 'books', 'UPDATE')")" = f ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_table_privilege(
       '$TEST_ROLE', 'uk_company_profiles', 'INSERT')")" = f ]
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "SET ROLE \"$TEST_ROLE\";
     SELECT * FROM api.create_transaction(
       '$BOOK_A',
       '{\"date\":\"2026-01-02\",\"comment\":\"RW edit\",\"lines\":[
          {\"account\":\"Topology Bank\",\"amount\":-1},
          {\"account\":\"Uncategorised Expenses\",\"amount\":1}
        ]}'::jsonb
     );" >/dev/null
if run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "SET ROLE \"$TEST_ROLE\";
     UPDATE accts SET type = 'L'
      WHERE book_id = '$BOOK_A' AND id = 'Topology Bank';" >/dev/null 2>&1
then
	echo "RW Book access allowed an account-class mutation" >&2
	exit 1
fi

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$CONTROL_DB" -c \
    "UPDATE njord_control.book_memberships
        SET membership_role = 'owner'
      WHERE book_id = '$BOOK_A'
        AND principal_id = (
            SELECT id FROM njord_control.principals
            WHERE database_role = '$TEST_ROLE'
        );" >/dev/null
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE',
       'api.update_book_settings(character varying,character varying,character varying)',
       'EXECUTE')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_function_privilege(
       '$TEST_ROLE',
       'api.authorize_book_database_deletion(character varying,character varying)',
       'EXECUTE')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT has_table_privilege('$TEST_ROLE', 'books', 'UPDATE')")" = t ]

run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "DO \$\$
     DECLARE error_detail TEXT;
     BEGIN
       BEGIN
         PERFORM api.authorize_book_database_deletion('$BOOK_A', 'Topology A');
         RAISE EXCEPTION 'active Book passed deletion authorization'
           USING ERRCODE = 'P0002';
       EXCEPTION WHEN SQLSTATE 'P0001' THEN
         GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
         IF error_detail IS DISTINCT FROM 'BOOK_NOT_ARCHIVED' THEN
           RAISE EXCEPTION 'unexpected deletion error: %', error_detail;
         END IF;
       END;
     END
     \$\$;" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "SELECT * FROM api.archive_book('$BOOK_A');" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "DO \$\$
     DECLARE error_detail TEXT;
     BEGIN
       BEGIN
         PERFORM api.authorize_book_database_deletion('$BOOK_A', 'Wrong name');
         RAISE EXCEPTION 'wrong name passed deletion authorization'
           USING ERRCODE = 'P0002';
       EXCEPTION WHEN SQLSTATE 'P0001' THEN
         GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
         IF error_detail IS DISTINCT FROM 'BOOK_CONFIRMATION_MISMATCH' THEN
           RAISE EXCEPTION 'unexpected deletion error: %', error_detail;
         END IF;
       END;
     END
     \$\$;" >/dev/null
run "$PSQL" -X -v ON_ERROR_STOP=1 -q -d "$BOOK_A" -c \
    "DO \$\$
     DECLARE error_detail TEXT;
     BEGIN
       BEGIN
         PERFORM 1 FROM api.delete_book('$BOOK_A', 'Topology A');
         RAISE EXCEPTION 'Book database performed its own physical deletion'
           USING ERRCODE = 'P0002';
       EXCEPTION WHEN SQLSTATE 'P0001' THEN
         GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
         IF error_detail IS DISTINCT FROM 'BOOK_DATABASE_DELETE_REQUIRES_PROVISIONER' THEN
           RAISE EXCEPTION 'unexpected deletion error: %', error_detail;
         END IF;
       END;
     END
     \$\$;" >/dev/null
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc \
    "SELECT api.authorize_book_database_deletion('$BOOK_A', 'Topology A')")" = t ]
[ "$(run "$PSQL" -X -d "$BOOK_A" -Atqc 'SELECT count(*) FROM books')" = 1 ]

echo "ok - database-per-book topology test passed"
