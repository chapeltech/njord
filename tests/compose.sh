#!/bin/sh

set -eu

cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || {
	echo "docker is required for the Compose test" >&2
	exit 1
}
docker compose version >/dev/null

test_id=$$
temporary=$(mktemp -d "${TMPDIR:-/tmp}/njord-compose.${test_id}.XXXXXX")
project="njord-test-$test_id"
network="njord-test-edge-$test_id"
volume="njord-test-data-$test_id"
image=${NJORD_COMPOSE_TEST_IMAGE:-njord:compose-test}
internal_port=18082
compose="docker compose -f compose.yaml"
sentinel_marker="njord-build-secret-sentinel-$test_id"
sentinel_env=".env.njord-build-sentinel-$test_id"
sentinel_secret="secrets/.njord-build-sentinel-$test_id"
created_secrets_directory=false

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		$compose logs --no-color --tail 240 >&2 || true
	fi
	$compose down --volumes --remove-orphans >/dev/null 2>&1 || true
	docker network rm "$network" >/dev/null 2>&1 || true
	rm -f "$sentinel_env" "$sentinel_secret"
	if [ "$created_secrets_directory" = true ]; then rmdir secrets >/dev/null 2>&1 || true; fi
	rm -rf "$temporary"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

umask 077
if [ ! -d secrets ]; then mkdir secrets; created_secrets_directory=true; fi
printf '%s\n' "$sentinel_marker" >"$sentinel_env"
printf '%s\n' "$sentinel_marker" >"$sentinel_secret"
printf '%s\n' 'compose-test-postgres-password' >"$temporary/postgres_password"

export NJORD_COMPOSE_PROJECT=$project
export NJORD_DATA_VOLUME=$volume
export NJORD_DOCKER_NETWORK=$network
export NJORD_HTTP_PORT=$internal_port
export NJORD_IMAGE=$image
export NJORD_INSTALL_EXAMPLES=0
export NJORD_ALLOW_UNAUTHENTICATED=1
export NJORD_POSTGRES_PASSWORD_FILE=$temporary/postgres_password

docker network create "$network" >/dev/null
case "${NJORD_COMPOSE_TEST_BUILD:-1}" in
	0) $compose up --no-build --detach ;;
	1) $compose up --build --detach ;;
	*) echo "NJORD_COMPOSE_TEST_BUILD must be 0 or 1." >&2; exit 2 ;;
esac

docker run --rm --entrypoint sh -e NJORD_SENTINEL="$sentinel_marker" "$image" -c \
    'if grep -R -F "$NJORD_SENTINEL" /opt/njord >/dev/null 2>&1; then exit 1; fi'

container_id=$($compose ps --quiet njord)
[ -n "$container_id" ]

wait_healthy()
{
	tries=0
	while [ "$tries" -lt 180 ]
	do
		state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id")
		case "$state" in
			'running healthy') return 0 ;;
			exited*|'dead '*) echo "Compose appliance stopped: $state" >&2; return 1 ;;
		esac
		tries=$((tries + 1))
		sleep 0.5
	done
	echo "Compose appliance did not become healthy: $state" >&2
	return 1
}

wait_healthy

[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container_id")" = true ]
docker inspect --format '{{json .HostConfig.SecurityOpt}}' "$container_id" | grep -q 'no-new-privileges'
runtime_uids=$(docker exec --user root "$container_id" sh -c '
  for process in /proc/[0-9]*; do
    [ "${process##*/}" = "$$" ] && continue
    command=$(tr "\000" " " <"$process/cmdline" 2>/dev/null || true)
    case "$command" in
      *"node scripts/static-server.mjs"*|*"postgrest postgrest.conf"*) stat -c %u "$process" ;;
    esac
  done
')
[ -n "$runtime_uids" ]
if printf '%s\n' "$runtime_uids" | grep -qx 0; then
	echo "public application process is running as root" >&2
	exit 1
fi
authenticator_connections=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d postgres -Atqc \
    "SELECT count(*) FROM pg_stat_activity WHERE usename = 'njord_authenticator'")
[ "$authenticator_connections" -gt 0 ]
if docker exec --user njord -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    "$container_id" psql -X -d postgres -Atqc 'SELECT 1' >/dev/null 2>&1; then
	echo "unprivileged application user can authenticate as PostgreSQL owner" >&2
	exit 1
fi

port_bindings=$(docker inspect --format '{{json .HostConfig.PortBindings}}' "$container_id")
case "$port_bindings" in
	'{}'|'null') ;;
	*) echo "base Compose deployment unexpectedly publishes host ports: $port_bindings" >&2; exit 1 ;;
esac

health=$(docker run --rm --network "$network" --entrypoint curl "$image" \
    --fail --silent --show-error "http://njord:$internal_port/healthz")
[ "$health" = ok ]
docker run --rm --network "$network" --entrypoint curl "$image" \
    --fail --silent --show-error \
    --header 'Content-Type: application/json' --data '{}' \
    "http://njord:$internal_port/api/control/rpc/shell_page" >/dev/null
docker run --rm --network "$network" --entrypoint node "$image" -e '
  const net = require("node:net");
  const socket = net.connect(5432, "njord", () => process.exit(1));
  socket.on("error", () => process.exit(0));
  setTimeout(() => process.exit(0), 1000);
'

book_count=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc 'SELECT count(*) FROM njord_control.books')
[ "$book_count" = 0 ]
control_version=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc 'SELECT max(version) FROM njord_control.schema_migrations')
[ "$control_version" = 1 ]

# Explicit legacy adoption is serialized by the cluster lifecycle lock. Two
# installers may discover an unversioned baseline together, but they must
# converge on one complete, checksummed ledger rather than racing its INSERT.
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord createdb compose-adoption
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -v ON_ERROR_STOP=1 -q -d compose-adoption \
    -v book_id=compose-adoption -v book_name='Compose Adoption' \
    -v reporting_asset=GBP -v entity_type=household \
    -v create_standard_accounts=false -f examples/new-book.sql >/dev/null
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    -e NJORD_ALLOW_LEGACY_ADOPTION=1 njord \
    scripts/migrate-database book compose-adoption >"$temporary/adopt-one.log" 2>&1 &
adopt_one=$!
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    -e NJORD_ALLOW_LEGACY_ADOPTION=1 njord \
    scripts/migrate-database book compose-adoption >"$temporary/adopt-two.log" 2>&1 &
adopt_two=$!
wait "$adopt_one"
wait "$adopt_two"
adopted_ledger=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d compose-adoption -Atqc \
    'SELECT count(*) = 1 AND min(version) = 1 AND max(version) = 1 FROM njord.schema_migrations')
[ "$adopted_ledger" = t ]
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord dropdb compose-adoption

$compose exec -T \
    -e PGHOST=/var/run/postgresql \
    -e PGUSER=postgres \
    -e NJORD_BOOK_OWNER_ROLE=njord \
    njord scripts/create-book-database \
    compose-persist 'Compose Persist' GBP household >/dev/null

physical_book=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d postgres -Atqc \
    "SELECT count(*) FROM pg_database WHERE datname = 'compose-persist'")
[ "$physical_book" = 1 ]

book_version=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d compose-persist -Atqc 'SELECT max(version) FROM njord.schema_migrations')
[ "$book_version" = 1 ]
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord scripts/migrate-databases --check >/dev/null

# Rehearse every durable lifecycle crash state. Startup must remove a
# provisioning row with no database, promote a fully loaded physical Book,
# and finish a deletion whose physical database still exists.
$compose exec -T \
    -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    -e NJORD_BOOK_OWNER_ROLE=njord \
    njord scripts/create-book-database \
    compose-recover 'Compose Recover' GBP household false >/dev/null
$compose exec -T \
    -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    -e NJORD_BOOK_OWNER_ROLE=njord \
    njord scripts/create-book-database \
    compose-delete 'Compose Delete' GBP household false >/dev/null
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -v ON_ERROR_STOP=1 -q -d njord >/dev/null <<'SQL'
BEGIN;
INSERT INTO njord_control.books (
    id, name, reporting_asset, entity_type, provisioning_state
) VALUES (
    'compose-missing', 'Compose Missing', 'GBP', 'household', 'provisioning'
);
INSERT INTO njord_control.book_memberships (
    book_id, principal_id, membership_role, changed_by
)
SELECT 'compose-missing', principal.id, 'owner', principal.id
FROM njord_control.principals AS principal
WHERE principal.database_role = 'njord';
COMMIT;
UPDATE njord_control.books
SET provisioning_state = 'provisioning'
WHERE id = 'compose-recover';
UPDATE njord_control.books
SET provisioning_state = 'deleting'
WHERE id = 'compose-delete';
SQL

# A durable invitation can outlive a failed broker call. Startup reconciliation
# must recreate the missing safe role and its authenticator/control grants.
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -v ON_ERROR_STOP=1 -q -d njord >/dev/null <<'SQL'
SELECT *
FROM njord_control.prepare_github_user(
    'recoveryfriend', 'Recovery Friend', NULL,
    ARRAY[]::VARCHAR[], 'viewer', 91002
);
DO $block$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'recoveryfriend') THEN
        EXECUTE 'DROP ROLE recoveryfriend';
    END IF;
END
$block$;
SQL

# Version 1 is the first production baseline. A same-version replacement must
# restart without rewriting either migration ledger.
$compose restart njord >/dev/null
container_id=$($compose ps --quiet njord)
wait_healthy

reconciled_principal=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    "SELECT rolcanlogin AND pg_has_role('njord_authenticator', 'recoveryfriend', 'member') AND has_database_privilege('recoveryfriend', 'njord', 'CONNECT') FROM pg_roles WHERE rolname = 'recoveryfriend'")
[ "$reconciled_principal" = t ]

reconciled_lifecycle=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    "SELECT count(*) = 1 AND min(provisioning_state) = 'ready' FROM njord_control.books WHERE id IN ('compose-recover', 'compose-missing', 'compose-delete')")
[ "$reconciled_lifecycle" = t ]
physical_lifecycle=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d postgres -Atqc \
    "SELECT count(*) = 1 FROM pg_database WHERE datname IN ('compose-recover', 'compose-delete')")
[ "$physical_lifecycle" = t ]

upgraded_versions=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord sh -c "psql -X -d njord -Atqc 'SELECT max(version) FROM njord_control.schema_migrations'; psql -X -d compose-persist -Atqc 'SELECT max(version) FROM njord.schema_migrations'")
[ "$upgraded_versions" = "1
1" ]

$compose up --detach --force-recreate >/dev/null
container_id=$($compose ps --quiet njord)
wait_healthy

catalogue_book=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    "SELECT count(*) FROM njord_control.books WHERE id = 'compose-persist'")
[ "$catalogue_book" = 1 ]

# Readiness tracks the control PostgREST dependency, and an unexpected control
# exit tears down the whole appliance so Compose can restart a coherent unit.
control_pid=$(docker exec --user root "$container_id" sh -c '
  for process in /proc/[0-9]*; do
    [ "${process##*/}" = "$$" ] && continue
    command=$(tr "\000" " " <"$process/cmdline" 2>/dev/null || true)
    case "$command" in
      *"postgrest postgrest.conf"*) echo "${process##*/}"; exit 0 ;;
    esac
  done
  exit 1
')
docker exec --user root "$container_id" sh -c "kill -STOP $control_pid"
if docker run --rm --network "$network" --entrypoint curl "$image" \
    --fail --silent --show-error --max-time 5 \
    "http://njord:$internal_port/readyz" >/dev/null 2>&1; then
	echo 'readiness remained successful while control PostgREST was stopped' >&2
	exit 1
fi
docker exec --user root "$container_id" sh -c "kill -CONT $control_pid"
wait_healthy
restart_count=$(docker inspect --format '{{.RestartCount}}' "$container_id")
docker exec --user root "$container_id" sh -c "kill -KILL $control_pid"
tries=0
while [ "$tries" -lt 180 ]
do
	new_restart_count=$(docker inspect --format '{{.RestartCount}}' "$container_id")
	state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id")
	if [ "$new_restart_count" -gt "$restart_count" ] && [ "$state" = 'running healthy' ]; then
		break
	fi
	tries=$((tries + 1))
	sleep 0.5
done
[ "$new_restart_count" -gt "$restart_count" ]
[ "$state" = 'running healthy' ]

restart_count=$(docker inspect --format '{{.RestartCount}}' "$container_id")
docker exec --user root "$container_id" sh -c '
  for process in /proc/[0-9]*; do
    command=$(tr "\000" " " <"$process/cmdline" 2>/dev/null || true)
    case "$command" in
      "bash /opt/njord/scripts/run-appliance "*)
        kill -KILL "${process##*/}"
        exit 0
        ;;
    esac
  done
  exit 1
' >/dev/null 2>&1 || true
tries=0
while [ "$tries" -lt 180 ]
do
	new_restart_count=$(docker inspect --format '{{.RestartCount}}' "$container_id")
	state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id")
	if [ "$new_restart_count" -gt "$restart_count" ] && [ "$state" = 'running healthy' ]; then
		break
	fi
	tries=$((tries + 1))
	sleep 0.5
done
[ "$new_restart_count" -gt "$restart_count" ]
[ "$state" = 'running healthy' ]

$compose stop --timeout 30 njord >/dev/null
[ "$(docker inspect --format '{{.State.Status}}' "$container_id")" = exited ]
$compose start njord >/dev/null
wait_healthy

restored_book=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d compose-persist -Atqc 'SELECT name FROM books')
[ "$restored_book" = 'Compose Persist' ]

# Put representative real state in both planes before the restore rehearsal:
# a human role and ACL, an opening transaction, mixed reconciliation state,
# and reportable accounting data.
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -v ON_ERROR_STOP=1 -q -d njord >/dev/null <<'SQL'
SELECT *
FROM njord_control.prepare_github_user(
    'backupfriend', 'Backup Friend', NULL,
    ARRAY['compose-persist']::VARCHAR[], 'viewer', 91001
);
SQL
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -v ON_ERROR_STOP=1 -q -d njord \
    -v control_database=njord -v database_role=backupfriend \
    -f sql/grant-control-user.sql >/dev/null
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -v ON_ERROR_STOP=1 -q -d compose-persist >/dev/null <<'SQL'
SELECT * FROM api.create_account(
    p_book_id => 'compose-persist',
    p_id => 'Backup Cash',
    p_type => 'A',
    p_asset => 'GBP',
    p_opening_balance => 123.45,
    p_opening_date => DATE '2026-08-01',
    p_parent_id => 'Assets',
    p_name => 'Backup Cash'
);
SELECT * FROM api.set_posting_reconciled(
    'compose-persist',
    (SELECT min(xid) FROM public.xaction_bits WHERE acct = 'Backup Cash'),
    'Backup Cash', TRUE
);
SQL

snapshot()
{
	$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
	    njord sh -c "
psql -X -d njord -Atqc \"SELECT count(*), string_agg(id || ':' || name, ',' ORDER BY id) FROM njord_control.books\";
psql -X -d njord -Atqc \"SELECT count(*), bool_and(pg_has_role('backupfriend', njord_control.book_access_role(book_id, access_level), 'member')) FROM njord_control.book_access_directory WHERE database_role = 'backupfriend'\";
psql -X -d compose-persist -Atqc \"SELECT count(*), md5(string_agg(to_jsonb(row_data)::text, '|' ORDER BY to_jsonb(row_data)::text)) FROM (SELECT xid, date, comment FROM public.xactions) AS row_data\";
psql -X -d compose-persist -Atqc \"SELECT count(*), md5(string_agg(to_jsonb(row_data)::text, '|' ORDER BY to_jsonb(row_data)::text)) FROM (SELECT xid, acct, amt, comment FROM public.xaction_bits) AS row_data\";
psql -X -d compose-persist -Atqc \"SELECT count(*) FROM public.unreconciled_postings\";
psql -X -d compose-persist -Atqc \"SELECT count(*), md5(string_agg(to_jsonb(report_row)::text, '|' ORDER BY to_jsonb(report_row)::text)) FROM hierarchical_net_worth_report('compose-persist', TIMESTAMP '2026-08-31 23:59:59.999999') AS report_row\";
psql -X -d compose-persist -Atqc \"SET ROLE backupfriend; SELECT count(*) FROM api.accounts_page('compose-persist')\";
"
}

before_backup=$(snapshot)
docker run --rm --entrypoint age-keygen "$image" \
    >"$temporary/age-identity.txt" 2>"$temporary/age-key.log"
age_recipient=$(sed -n 's/^Public key: //p' "$temporary/age-key.log")
[ -n "$age_recipient" ]
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord scripts/backup-cluster-encrypted "$age_recipient" >"$temporary/njord-backup.age"
[ "$(wc -c <"$temporary/njord-backup.age")" -gt 100000 ]

# Destroy the exact isolated test volume, restore into a new volume, and prove
# product data, reports, reconciliation, roles, and ACLs are byte-for-byte or
# value-for-value equivalent at their stable SQL surfaces.
$compose down --remove-orphans >/dev/null
docker volume rm "$volume" >/dev/null
docker volume create "$volume" >/dev/null
docker run --rm --user root \
    --volume "$volume:/var/lib/postgresql" \
    --volume "$temporary:/backup:ro,Z" \
    --entrypoint /opt/njord/scripts/restore-cluster-encrypted \
    "$image" /backup/age-identity.txt /backup/njord-backup.age >/dev/null
$compose up --detach >/dev/null
container_id=$($compose ps --quiet njord)
wait_healthy
after_restore=$(snapshot)
[ "$after_restore" = "$before_backup" ] || {
	echo 'restored cluster does not match its pre-backup product snapshot' >&2
	printf 'before:\n%s\nafter:\n%s\n' "$before_backup" "$after_restore" >&2
	exit 1
}
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord scripts/migrate-databases --check >/dev/null

# Checksum drift and newer product versions are refused even when their rows
# are otherwise contiguous.
original_checksum=$($compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    'SELECT checksum FROM njord_control.schema_migrations WHERE version = 1')
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    "UPDATE njord_control.schema_migrations SET checksum = repeat('0', 64) WHERE version = 1" >/dev/null
if $compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord scripts/migrate-databases --check >"$temporary/mismatch.log" 2>&1; then
	echo 'migration checksum mismatch was accepted' >&2
	exit 1
fi
grep -q 'does not match the shipped name and checksum' "$temporary/mismatch.log"
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    "UPDATE njord_control.schema_migrations SET checksum = '$original_checksum' WHERE version = 1" >/dev/null
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    "INSERT INTO njord_control.schema_migrations VALUES (2, 'future', repeat('1', 64), clock_timestamp())" >/dev/null
if $compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord scripts/migrate-databases --check >"$temporary/future.log" 2>&1; then
	echo 'newer database schema was accepted' >&2
	exit 1
fi
grep -q 'newer than this application' "$temporary/future.log"
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    'DELETE FROM njord_control.schema_migrations WHERE version = 2' >/dev/null

# A legacy-looking database with no ledger is never silently adopted.
$compose exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
    njord psql -X -d njord -Atqc \
    'DROP TABLE njord_control.schema_migrations CASCADE' >/dev/null
$compose stop --timeout 30 njord >/dev/null
if $compose run --rm --no-deps njord >"$temporary/partial.log" 2>&1; then
	echo 'appliance started with a partial migration ledger' >&2
	exit 1
fi
grep -q 'has no control migration ledger; refusing implicit legacy adoption' "$temporary/partial.log"

printf 'ok - Compose initialization, migration, persistence, recovery, and startup guards passed\n'
