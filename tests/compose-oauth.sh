#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.."

command -v docker >/dev/null 2>&1 || {
	echo "docker is required for the Compose OAuth test" >&2
	exit 1
}
docker compose version >/dev/null

test_id=$$
temporary=$(mktemp -d "${TMPDIR:-/tmp}/njord-compose-oauth.${test_id}.XXXXXX")
app_project="njord-oauth-$test_id"
nginx_project="njord-oauth-nginx-$test_id"
network="njord-oauth-edge-$test_id"
volume="njord-oauth-data-$test_id"
image=${NJORD_COMPOSE_OAUTH_TEST_IMAGE:-njord:compose-oauth-test}
app_compose=(docker compose -f docker-compose.yml -f compose.github.yaml -f tests/compose.oauth.yaml)
nginx_compose=(docker compose -f tests/compose.nginx.yaml)
internal_port=18083

cleanup()
{
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		"${app_compose[@]}" logs --no-color --tail 300 >&2 || true
		"${nginx_compose[@]}" logs --no-color --tail 100 >&2 || true
	fi
	"${nginx_compose[@]}" down --remove-orphans >/dev/null 2>&1 || true
	"${app_compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
	rm -rf "$temporary"
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

umask 077
printf '%s\n' 'compose-oauth-client-secret' >"$temporary/github_client_secret"
printf '%s\n' 'compose-oauth-session-secret-00000000000000000000000000000001' >"$temporary/session_secret"
printf '%s\n' 'compose-oauth-postgrest-jwt-secret-0000000000000000000000000001' >"$temporary/postgrest_jwt_secret"

export NJORD_COMPOSE_PROJECT=$app_project
export NJORD_NGINX_TEST_PROJECT=$nginx_project
export NJORD_DATA_VOLUME=$volume
export NJORD_DOCKER_NETWORK=$network
export NJORD_HTTP_PORT=$internal_port
export NJORD_HOST_PORT=0
export NJORD_IMAGE=$image
export NJORD_INSTALL_EXAMPLES=0
export NJORD_GITHUB_CLIENT_SECRET_FILE=$temporary/github_client_secret
export NJORD_SESSION_SECRET_FILE=$temporary/session_secret
export NJORD_POSTGREST_JWT_SECRET_FILE=$temporary/postgrest_jwt_secret
export NJORD_GITHUB_CLIENT_ID=compose-oauth-client
export NJORD_PUBLIC_URL=https://accounts.test
export NJORD_ADMIN_GITHUB_LOGIN=elric1
export NJORD_DATABASE_ROLE=

case "${NJORD_COMPOSE_OAUTH_TEST_BUILD:-1}" in
	0) ;;
	1) docker build --tag "$image" . ;;
	*) echo "NJORD_COMPOSE_OAUTH_TEST_BUILD must be 0 or 1." >&2; exit 2 ;;
esac
"${app_compose[@]}" up --no-build --detach
"${nginx_compose[@]}" up --detach

container_id=$("${app_compose[@]}" ps --quiet njord)
tries=0
while [ "$tries" -lt 240 ]; do
	state=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container_id")
	case "$state" in
		'running healthy') break ;;
		exited*|'dead '*) echo "OAuth appliance stopped: $state" >&2; exit 1 ;;
	esac
	tries=$((tries + 1))
	sleep 0.5
done
[ "$state" = 'running healthy' ] || {
	echo "OAuth appliance did not become healthy: $state" >&2
	exit 1
}

docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" |
	grep -qx 'NJORD_ALLOW_UNAUTHENTICATED=0'
direct_port=$("${app_compose[@]}" port njord "$internal_port" | sed 's/.*://')
direct_status=$(curl --silent --show-error --max-time 60 \
	--output /dev/null --write-out '%{http_code}' \
	--header 'Content-Type: application/json' --data '{}' \
	"http://127.0.0.1:$direct_port/api/control/rpc/shell_page")
case "$direct_status" in
	4??) ;;
	*) echo "direct gateway request returned HTTP $direct_status, expected a 4xx denial" >&2; exit 1 ;;
esac

nginx_port=$("${nginx_compose[@]}" port nginx 8080 | sed 's/.*://')
origin="http://127.0.0.1:$nginx_port"

request()
{
	local method=$1 path=$2 cookie=${3:-} payload=${4:-}
	local args=(
		--silent --show-error --max-time 60
		--request "$method"
		--header 'Host: accounts.test'
		--dump-header "$temporary/headers"
		--output "$temporary/body"
		--write-out '%{http_code}'
	)
	if [ -n "$cookie" ]; then args+=(--header "Cookie: $cookie"); fi
	if [ "$method" = POST ] && [ -n "$cookie" ]; then
		args+=(--header 'Origin: https://accounts.test')
	fi
	if [ -n "$payload" ]; then
		args+=(--header 'Content-Type: application/json' --data "$payload")
	fi
	status=$(curl "${args[@]}" "$origin$path")
}

location_path()
{
	node -e 'const url = new URL(process.argv[1]); process.stdout.write(url.pathname + url.search)' "$1"
}

header_location()
{
	sed -n 's/^location: //Ip' "$temporary/headers" | tr -d '\r' | tail -1
}

header_cookie()
{
	local name=$1
	sed -n "s/^set-cookie: \($name=[^;]*\).*/\1/Ip" "$temporary/headers" | tr -d '\r' | head -1
}

assert_status()
{
	local expected=$1 context=$2
	if [ "$status" != "$expected" ]; then
		echo "$context returned HTTP $status, expected $expected" >&2
		cat "$temporary/body" >&2
		exit 1
	fi
}

assert_denied()
{
	local context=$1
	case "$status" in
		4??) ;;
		*) echo "$context returned HTTP $status, expected a 4xx denial" >&2; cat "$temporary/body" >&2; exit 1 ;;
	esac
}

select_identity()
{
	request POST "/__github/__test/identity?login=$1"
	assert_status 200 "selecting fake GitHub identity $1"
}

login()
{
	local login_name=$1 return_to=${2:-/}
	select_identity "$login_name"
	request GET "/auth/login?return_to=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$return_to")"
	assert_status 302 "starting GitHub login for $login_name"
	local oauth_cookie authorize_location authorize_path callback_location callback_path
	oauth_cookie=$(header_cookie __Host-njord_oauth)
	authorize_location=$(header_location)
	[ -n "$oauth_cookie" ] && [ -n "$authorize_location" ] || {
		echo "GitHub login did not return OAuth state and destination" >&2
		exit 1
	}
	case "$authorize_location" in
		https://accounts.test/__github/authorize*) ;;
		*) echo "Gateway did not use its configured public OAuth URL: $authorize_location" >&2; exit 1 ;;
	esac
	authorize_path=$(location_path "$authorize_location")
	request GET "$authorize_path"
	assert_status 302 "authorizing fake GitHub identity $login_name"
	callback_location=$(header_location)
	case "$callback_location" in
		https://accounts.test/auth/callback*) ;;
		*) echo "OAuth callback was not the configured external HTTPS URL: $callback_location" >&2; exit 1 ;;
	esac
	callback_path=$(location_path "$callback_location")
	request GET "$callback_path" "$oauth_cookie"
	assert_status 302 "completing GitHub login for $login_name"
	session_cookie=$(header_cookie __Host-njord_session)
	[ -n "$session_cookie" ] || {
		echo "OAuth callback did not create a browser session" >&2
		exit 1
	}
	grep -Eiq '^set-cookie: __Host-njord_session=.*; Path=/; HttpOnly; SameSite=Strict; Secure;' "$temporary/headers" || {
		echo "OAuth session cookie does not have the production attributes" >&2
		cat "$temporary/headers" >&2
		exit 1
	}
}

rpc()
{
	request POST "$1" "$2" "$3"
}

control_psql()
{
	"${app_compose[@]}" exec -T -e PGHOST=/var/run/postgresql -e PGUSER=postgres \
		njord psql -X -v ON_ERROR_STOP=1 -q -d njord "$@"
}

# The declared first administrator is immediately usable on an empty cluster.
login elric1 '/?page=admin'
admin_cookie=$session_cookie
request GET /auth/me "$admin_cookie"
assert_status 200 'reading first administrator session'
grep -q '"database_role":"elric1"' "$temporary/body"
rpc /api/control/rpc/admin_page "$admin_cookie" '{}'
assert_status 200 'opening global Admin before creating a Book'

# Create a physical Book through the public nginx path.
rpc /api/control/rpc/create_book "$admin_cookie" \
	'{"p_id":"oauth-book","p_name":"OAuth Test Book","p_reporting_asset":"GBP","p_entity_type":"household","p_create_standard_accounts":true}'
assert_status 200 'creating a Book through nginx'
grep -q '"id":"oauth-book"' "$temporary/body"

# A global invitation admits a user but does not silently grant global Admin
# or access to any Book.
rpc /api/control/rpc/invite_global_user "$admin_cookie" '{"p_github_login":"observer1"}'
assert_status 200 'inviting a global user'
login observer1 '/?page=books'
observer_cookie=$session_cookie
rpc /api/control/rpc/admin_page "$observer_cookie" '{}'
assert_denied 'opening global Admin as an ordinary admitted user'
rpc /api/books/oauth-book/rpc/accounts_page "$observer_cookie" '{"p_book_id":"oauth-book"}'
assert_denied 'opening an ungranted Book'

# A Book Admin can invite a GitHub identity directly at RO.
rpc /api/books/oauth-book/rpc/invite_book_user "$admin_cookie" \
	'{"p_book_id":"oauth-book","p_github_login":"friend1","p_access_level":"ro"}'
assert_status 200 'inviting a read-only Book user'
friend_principal=$(node -e '
  const fs = require("node:fs");
  const rows = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const row = rows.find((candidate) => candidate.component === "book_access_result");
  if (!row?.payload?.principal_id) process.exit(1);
  process.stdout.write(row.payload.principal_id);
' "$temporary/body")

login friend1 '/?page=accounts&book=oauth-book'
friend_ro_cookie=$session_cookie
rpc /api/books/oauth-book/rpc/accounts_page "$friend_ro_cookie" '{"p_book_id":"oauth-book"}'
assert_status 200 'reading a Book at RO'
rpc /api/books/oauth-book/rpc/create_account "$friend_ro_cookie" \
	'{"p_book_id":"oauth-book","p_id":"Denied Expense","p_type":"E","p_asset":"GBP"}'
assert_denied 'creating an account at RO'

# RW can post and organise accounting data, but cannot mutate Book identity.
rpc /api/books/oauth-book/rpc/update_book_access "$admin_cookie" \
	"{\"p_book_id\":\"oauth-book\",\"p_principal_id\":\"$friend_principal\",\"p_access_level\":\"rw\"}"
assert_status 200 'promoting a Book user to RW'
rpc /api/books/oauth-book/rpc/create_account "$friend_ro_cookie" \
	'{"p_book_id":"oauth-book","p_id":"Allowed Expense","p_type":"E","p_asset":"GBP"}'
assert_status 200 'creating an account at RW'
rpc /api/books/oauth-book/rpc/update_book_settings "$friend_ro_cookie" \
	'{"p_book_id":"oauth-book","p_name":"RW must not rename","p_entity_type":"household"}'
assert_denied 'updating Book settings at RW'

# Book Admin may mutate Book settings, but still has no global Admin grant.
rpc /api/books/oauth-book/rpc/update_book_access "$admin_cookie" \
	"{\"p_book_id\":\"oauth-book\",\"p_principal_id\":\"$friend_principal\",\"p_access_level\":\"admin\"}"
assert_status 200 'promoting a Book user to Admin'
rpc /api/books/oauth-book/rpc/update_book_settings "$friend_ro_cookie" \
	'{"p_book_id":"oauth-book","p_name":"OAuth Test Book Renamed","p_entity_type":"household"}'
assert_status 200 'updating Book settings at Admin'
rpc /api/control/rpc/admin_page "$friend_ro_cookie" '{}'
assert_denied 'opening global Admin as a Book Admin'

# GitHub rename: the immutable numeric subject follows the same principal and
# PostgreSQL role while the current provider login is refreshed.
request POST '/__github/__test/rename?login=friend-renamed'
assert_status 200 'renaming a fake GitHub account'
login friend-renamed '/?page=books'
friend_renamed_cookie=$session_cookie
request GET /auth/me "$friend_renamed_cookie"
assert_status 200 'reading renamed GitHub session'
grep -q '"database_role":"friend1"' "$temporary/body"
grep -q '"provider_login":"friend-renamed"' "$temporary/body"

# Disabling through the public Admin API invalidates sessions and enforces the
# same state at PostgreSQL LOGIN, authenticator, and Book-capability layers.
rpc /api/control/rpc/set_global_user_enabled "$admin_cookie" \
	"{\"p_principal_id\":\"$friend_principal\",\"p_enabled\":false}"
assert_status 200 'disabling a principal as global Admin'
request GET /auth/me "$friend_renamed_cookie"
assert_status 401 'using a session after its principal is disabled'
disabled_enforcement=$(control_psql -Atqc "
SELECT NOT role.rolcanlogin
   AND NOT pg_has_role('njord_authenticator', 'friend1', 'member')
   AND NOT pg_has_role('friend1', njord_control.book_access_role('oauth-book', 'ro'), 'member')
   AND NOT pg_has_role('friend1', njord_control.book_access_role('oauth-book', 'rw'), 'member')
   AND NOT pg_has_role('friend1', njord_control.book_access_role('oauth-book', 'admin'), 'member')
FROM pg_roles AS role WHERE role.rolname = 'friend1'")
[ "$disabled_enforcement" = t ]
disabled_broker_result=$("${app_compose[@]}" exec -T --user njord njord node -e '
  const net = require("node:net");
  const socket = net.connect("/run/njord/lifecycle.sock", () => {
    socket.end(JSON.stringify({ operation: "grant_role", databaseRole: "friend1" }));
  });
  let response = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => { response += chunk; });
  socket.on("end", () => process.stdout.write(response.trim()));
  socket.on("error", () => process.exit(2));
')
[ "$disabled_broker_result" = '{"ok":false}' ]
rpc /api/control/rpc/set_global_user_enabled "$admin_cookie" \
	"{\"p_principal_id\":\"$friend_principal\",\"p_enabled\":true}"
assert_status 200 're-enabling a principal as global Admin'
enabled_enforcement=$(control_psql -Atqc "
SELECT role.rolcanlogin
   AND pg_has_role('njord_authenticator', 'friend1', 'member')
   AND pg_has_role('friend1', njord_control.book_access_role('oauth-book', 'admin'), 'member')
FROM pg_roles AS role WHERE role.rolname = 'friend1'")
[ "$enabled_enforcement" = t ]

# Expired invitations cannot be accepted.
rpc /api/control/rpc/invite_global_user "$admin_cookie" '{"p_github_login":"expired1"}'
assert_status 200 'creating an invitation for expiry testing'
control_psql -c "UPDATE njord_control.github_invitations SET invited_at = clock_timestamp() - interval '2 hours', expires_at = clock_timestamp() - interval '1 hour' WHERE github_login = 'expired1'" >/dev/null
select_identity expired1
request GET /auth/login
assert_status 302 'starting login with an expired invitation'
expired_oauth_cookie=$(header_cookie __Host-njord_oauth)
expired_authorize_path=$(location_path "$(header_location)")
request GET "$expired_authorize_path"
assert_status 302 'authorizing an expired invitation identity'
expired_callback_path=$(location_path "$(header_location)")
request GET "$expired_callback_path" "$expired_oauth_cookie"
assert_status 403 'rejecting an expired invitation'

# Server expiry is authoritative. Reauthentication creates a fresh session;
# it never resurrects the expired token.
login friend-renamed '/?page=books'
expired_session_cookie=$session_cookie
expired_token=${expired_session_cookie#*=}
expired_hash=$(printf '%s' "$expired_token" | sha256sum | cut -d' ' -f1)
control_psql -c "UPDATE njord_control.web_sessions SET created_at = clock_timestamp() - interval '2 hours', expires_at = clock_timestamp() - interval '1 hour' WHERE token_hash = '$expired_hash'" >/dev/null
request GET /auth/me "$expired_session_cookie"
assert_status 401 'using an expired browser session'
login friend-renamed '/?page=books'
renewed_cookie=$session_cookie
[ "$renewed_cookie" != "$expired_session_cookie" ]
request GET /auth/me "$renewed_cookie"
assert_status 200 'renewing a session by reauthenticating'

# Logout revokes the server-side session, not just the browser cookie.
renewed_token=${renewed_cookie#*=}
renewed_hash=$(printf '%s' "$renewed_token" | sha256sum | cut -d' ' -f1)
request POST /auth/logout "$renewed_cookie"
assert_status 302 'logging out'
request GET /auth/me "$renewed_cookie"
assert_status 401 'reusing a logged-out session'
revoked=$(control_psql -Atqc "SELECT revoked_at IS NOT NULL FROM njord_control.web_sessions WHERE token_hash = '$renewed_hash'")
[ "$revoked" = t ]

nginx_logs=$("${nginx_compose[@]}" logs --no-color nginx)
if printf '%s\n' "$nginx_logs" | grep -Eq '\?(.*)(code|state)='; then
	echo 'nginx access log disclosed an OAuth code or state query value' >&2
	exit 1
fi

printf 'ok - GitHub login, invitations, sessions, rename handling, nginx, and RO/RW/Admin boundaries passed\n'
