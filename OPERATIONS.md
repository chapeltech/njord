# Njord Operations

These runbooks cover the supported public deployment: `compose.yaml` plus
`compose.github.yaml`, with an operator-managed HTTPS nginx proxy on the shared
private Docker network. The commands intentionally omit `compose.local.yaml`;
that overlay enables unauthenticated loopback demonstration mode.

## Release Gate

Run this gate for the exact committed revision and immutable image that will be
deployed:

1. Confirm that `git status` contains no unexplained changes and review
   [SECURITY.md](SECURITY.md) against the deployment.
2. Run the SQL, topology, API, browser, and container acceptance suites:

   ```sh
   npm ci
   npm audit
   npm run build
   tests/run.sh
   tests/topology.sh
   tests/api.sh
   npm run test:compose
   npm run test:compose-oauth
   git diff --check
   ```

3. Build, label, inventory, and scan a versioned image. The build fails on a
   detected high or critical image vulnerability:

   ```sh
   NJORD_RELEASE_VERSION=0.1.0 \
   NJORD_RELEASE_IMAGE=registry.example/njord \
     scripts/build-release
   docker push registry.example/njord:0.1.0
   ```

4. Retain the generated SPDX JSON SBOM and `.image-id` beside the release
   record. Record the immutable registry digest, source revision, test results,
   scanner result, and the operator who approved deployment.
5. Rehearse the deployment on a clean staging volume, complete GitHub login,
   create and edit a Book, run a representative report, make an encrypted
   backup, and restore it into another clean volume. Do not waive the restore
   rehearsal merely because backup creation succeeded.

The first production database contract is schema version 1 for both control
and Book databases. It has no supported production predecessor. The acceptance
suite therefore tests fresh installation, repeated same-version startup,
controlled concurrent adoption of installer output, and refusal of a future
version—not a fictional upgrade from an earlier release.

## Deployment Checklist

1. Install Docker Engine with Compose v2 and `age`; restrict membership of the
   host's Docker group to installation administrators.
2. Set `NJORD_IMAGE` in `.env` to the approved immutable image tag or digest,
   leave `NJORD_INSTALL_EXAMPLES=0` and
   `NJORD_ALLOW_UNAUTHENTICATED=0`, and choose durable values for
   `NJORD_DATA_VOLUME` and `NJORD_CONTROL_DATABASE`. Do not rename those
   after initialization.
3. Create the external Docker network and the four mode-0600 service secret
   files. Secret values do not belong in `.env`:

   ```sh
   cp .env.example .env
   chmod 0600 .env
   install -d -m 0700 secrets
   openssl rand -hex 32 >secrets/postgres_password
   openssl rand -hex 32 >secrets/session_secret
   openssl rand -hex 32 >secrets/postgrest_jwt_secret
   # Write the GitHub OAuth App secret to secrets/github_client_secret.
   chmod 0600 secrets/postgres_password secrets/github_client_secret \
     secrets/session_secret secrets/postgrest_jwt_secret
   docker network create njord-edge
   ```

4. Register the GitHub OAuth App exactly as described in
   [README.md](README.md#github-authentication). Set the matching external HTTPS
   origin in `NJORD_PUBLIC_URL`, the OAuth client id, and the lowercase initial
   administrator login in `.env`.
5. Attach nginx to `NJORD_DOCKER_NETWORK`, adapt
   [deploy/nginx-njord.conf.example](deploy/nginx-njord.conf.example), and
   verify its upstream port agrees with `NJORD_HTTP_PORT`. Only nginx should
   publish a public port. PostgreSQL and PostgREST remain private to the
   appliance.
6. Validate the rendered Compose model, pull the approved image, and start the
   authenticated overlay without rebuilding it on the server:

   ```sh
   docker compose -f compose.yaml -f compose.github.yaml config --quiet
   docker compose -f compose.yaml -f compose.github.yaml pull njord
   docker compose -f compose.yaml -f compose.github.yaml up --no-build -d
   docker compose -f compose.yaml -f compose.github.yaml ps
   docker compose -f compose.yaml -f compose.github.yaml logs --tail=200 njord
   ```

7. Require a healthy container and successful readiness through nginx:

   ```sh
   curl --fail --silent --show-error https://accounts.example.com/readyz
   docker inspect --format '{{.State.Health.Status}}' \
     "$(docker compose -f compose.yaml -f compose.github.yaml ps -q njord)"
   docker compose -f compose.yaml -f compose.github.yaml exec -T \
     -e PGUSER=postgres njord scripts/migrate-databases --check
   ```

8. Sign in as the declared administrator. Confirm that Admin is visible only
   to that global administrator, the fresh Books list is empty, an invited
   non-admin cannot open Admin, and RO/RW/Admin Book access behaves as named.
9. Make the first encrypted backup and complete a clean-volume restore before
   entering irreplaceable data. Record the recovery-time and recovery-point
   expectations, backup schedule, retention, off-host destination, and named
   operators.

The appliance starts as container root only long enough to adopt the durable
volume and supervise initialization. PostgreSQL and the fixed lifecycle broker
run as OS user `postgres`. The gateway and every PostgREST process run as OS
user `njord`; peer authentication lets that user connect only as the
non-owner database role `njord_authenticator`. PostgREST switches per request
to `njord_gateway`, `njord_anonymous`, or one verified human role. The broker
accepts a bounded set of validated operations on a private Unix socket and
runs only fixed provisioning, deletion, and role-grant programs. No public
request supplies a shell command or database connection string.

## Encrypted Backup Checklist

1. Keep the age private identity off the server. Install only its public
   recipient text at `secrets/backup_age_recipient` with mode 0600.
2. Confirm enough free space in the live volume to stage approximately one
   additional copy of the PostgreSQL cluster.
3. Stream the checked physical backup directly through age:

   ```sh
   install -d -m 0700 backups
   backup="backups/njord-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"
   docker compose -f compose.yaml -f compose.github.yaml exec -T \
     -e PGUSER=postgres njord scripts/backup-cluster-encrypted \
     "$(cat secrets/backup_age_recipient)" >"$backup"
   test -s "$backup"
   ```

4. Copy the encrypted file off-host. On the operator workstation, authenticate
   and decompress the complete stream without retaining plaintext:

   ```sh
   age --decrypt --identity njord-backup-age-identity \
     NJORD_BACKUP.tar.gz.age | gzip -t
   ```

5. Periodically perform the clean-volume restore below. Record archive name,
   creation time, producing image digest, verification result, restore result,
   and retention expiry. Protect and test more than one generation.

`scripts/backup-cluster` is a lower-level trusted pipe and must not be redirected
to persistent plaintext in production. Both backup scripts acquire the same
exclusive lifecycle lock used by migrations and Book creation/deletion. Normal
ledger writes may continue while PostgreSQL produces the consistent base backup.

## Clean-Volume Restore Checklist

Use the exact producing image when available and always the same PostgreSQL
major version. Never restore over the current volume.

1. Stop Njord, retain the old volume, and create a new explicitly named one:

   ```sh
   docker compose -f compose.yaml -f compose.github.yaml stop njord
   docker volume create njord-restored-data
   ```

2. Temporarily place the required age identity on the restore host with mode
   0600, then decrypt, verify, and install the cluster into the empty volume:

   ```sh
   docker run --rm --user root \
     --volume njord-restored-data:/var/lib/postgresql \
     --volume "$PWD/backups:/backup:ro" \
     --volume "$PWD/secrets/backup_age_identity:/run/secrets/backup_age_identity:ro" \
     --entrypoint /opt/njord/scripts/restore-cluster-encrypted \
     njord:0.1.0 /run/secrets/backup_age_identity \
     /backup/NJORD_BACKUP.tar.gz.age
   ```

   Replace `njord:0.1.0` with the image that produced the backup. The command
   refuses a nonempty target and runs `pg_verifybackup` before installing it.

3. Set `NJORD_DATA_VOLUME=njord-restored-data`, start the authenticated
   overlays, and validate the durable migration ledgers:

   ```sh
   docker compose -f compose.yaml -f compose.github.yaml up --no-build -d
   docker compose -f compose.yaml -f compose.github.yaml exec -T \
     -e PGUSER=postgres njord scripts/migrate-databases --check
   ```

4. Verify login, enabled/disabled users, global administrators, the Book list
   and ACLs, transaction and reconciliation counts, important account balances,
   and representative core and jurisdiction reports. Compare these with the
   backup record or a known snapshot.
5. Remove the temporary private age identity from the restore host. Keep the
   old volume untouched until the restored service has passed acceptance and a
   new backup has been verified.

## Upgrade and Rollback Checklist

1. Record the running image digest, schema versions, health, volume name, and a
   representative data snapshot.
2. Complete the release gate for the candidate image and make a verified
   encrypted pre-upgrade backup.
3. Pull the new immutable image, stop Njord gracefully, change
   `NJORD_IMAGE`, and start with `--no-build`. Watch logs and readiness, run
   `scripts/migrate-databases --check`, then test login, one mutation, and
   representative reports.
4. Keep the old image and data volume until acceptance and restore rehearsal
   succeed.

If startup fails before any migration commits and the old image accepts the
current schema, selecting the old image may be sufficient. Otherwise, changing
the image tag is not a database rollback: stop the candidate, restore the
pre-upgrade backup into a new clean volume, select the old image and restored
volume, and repeat deployment acceptance. Never use `docker compose down
--volumes`, reuse a partially restored volume, edit a migration ledger, or run
fresh loaders over durable data.

## Monitoring Checklist

- Poll `/healthz` for gateway liveness and `/readyz` for the control PostgREST
  dependency. Compose health uses `/readyz`; alert on `unhealthy`, restarts, or
  a container exit. A Book adapter failure is recovered on a later request and
  is visible in labelled logs.
- Watch nginx 5xx/429 rates and latency without logging query strings. Watch
  `docker compose logs` for migration, lifecycle, authentication, PostgREST,
  PostgreSQL, and graceful-shutdown failures. Compose rotates its JSON logs
  using the configured size and file-count limits.
- Monitor free bytes and inodes on the filesystem backing Docker's data root,
  plus database growth and connection pressure:

  ```sh
  docker compose -f compose.yaml -f compose.github.yaml exec -T \
    -e PGUSER=postgres njord psql -X -d postgres -c \
    "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
       FROM pg_database WHERE datallowconn ORDER BY pg_database_size(datname) DESC"
  docker compose -f compose.yaml -f compose.github.yaml exec -T \
    -e PGUSER=postgres njord psql -X -d postgres -c \
    "SELECT datname, count(*) AS connections
       FROM pg_stat_activity GROUP BY datname ORDER BY connections DESC"
  ```

- Alert when the latest off-host encrypted backup or clean-restore rehearsal is
  older than the installation's stated recovery objective. Periodically test
  that the retained age identities still decrypt every retained generation.
- Review admitted principals, disabled state, global administrators, Book ACLs,
  unexpected direct logins, and role attributes. The default maximum of 32
  resident Book adapters matches the default control-plane Book limit; change
  both deliberately if capacity planning justifies it.

## Incident Checklist

1. Remove the nginx route or otherwise stop new public traffic. If hostile writes
   may still be occurring, stop Njord gracefully; do not delete its container,
   volume, logs, or backups.
2. Record UTC time, symptoms, image/container ids, Compose configuration, host
   state, and affected accounts. Preserve nginx and appliance logs before their
   retention window rotates:

   ```sh
   install -d -m 0700 incident
   docker compose -f compose.yaml -f compose.github.yaml logs \
     --no-color --timestamps njord >incident/njord.log
   docker inspect "$(docker compose -f compose.yaml -f compose.github.yaml \
     ps -q njord)" >incident/njord-container.json
   ```

3. Preserve an encrypted cluster backup when doing so will not overwrite a
   known-good generation. Treat it as compromised evidence, not automatically
   as a recovery source.
4. Disable affected non-global principals through Admin. This revokes their
   sessions, changes their PostgreSQL roles to `NOLOGIN`, removes Book
   capability role memberships, and terminates existing direct sessions. A
   global administrator must first be removed from that grant by a trusted
   database operator, while retaining another enabled global administrator. If
   all browser sessions may be exposed, revoke them from the control database:

   ```sh
   docker compose -f compose.yaml -f compose.github.yaml exec -T \
     -e PGUSER=postgres njord psql -X -d njord -v ON_ERROR_STOP=1 -c \
     "UPDATE njord_control.web_sessions
         SET revoked_at = clock_timestamp()
       WHERE revoked_at IS NULL"
   ```

5. Rotate affected OAuth, session, JWT, database, TLS, and backup credentials as
   applicable. Verify control catalogue membership against actual PostgreSQL
   role membership and inspect accounting changes from the incident window.
6. If ledger integrity cannot be established, restore a known-good pre-incident
   backup into a clean volume. Keep the suspect volume read-only for investigation
   and re-enter only independently verified transactions.
7. Restore public routing only after the clean service passes the deployment
   checklist. Record scope, decisions, recovered data boundary, credentials
   changed, and follow-up fixes.

## Secret Rotation Checklist

- **GitHub client secret:** create the replacement in GitHub, atomically replace
  `secrets/github_client_secret` with mode 0600, recreate Njord with both
  Compose files, test a new login, then revoke the old GitHub secret. Existing
  Njord browser sessions remain valid unless separately revoked.
- **Session secret:** atomically replace `secrets/session_secret`, recreate the
  service, and test login. This invalidates in-flight signed OAuth state; it does
  not revoke established database-backed browser sessions. Revoke those rows
  explicitly when compromise is suspected.
- **PostgREST JWT secret:** atomically replace
  `secrets/postgrest_jwt_secret`, recreate the service so the gateway and all
  adapters agree, and test control and Book calls. Old internal claims expire
  after their 60-second lifetime; browser sessions need not be discarded unless
  the incident also exposed them.
- **PostgreSQL password:** `secrets/postgres_password` bootstraps only a new
  cluster. Replacing the file does not change roles in an existing volume. The
  supported Compose topology exposes no PostgreSQL TCP listener. An operator
  who deliberately adds direct network SQL must rotate the affected role
  verifier with `ALTER ROLE`, require TLS plus SCRAM or client certificates, and
  update clients independently.
- **Age identity:** generate a new identity off-host, install only its recipient
  on the server, and use it for new backups. Keep each old private identity until
  all backups encrypted to it have expired or been decrypted and re-encrypted.
  Complete a clean restore with the new identity before relying on it.
- **nginx TLS keys:** rotate them in the separately managed nginx deployment;
  Njord deliberately receives plain HTTP only on the private Docker network.

Write replacement files through a mode-0600 temporary file followed by an
atomic rename. Do not put secret values in `.env`, command-line arguments,
Compose labels, image layers, logs, tickets, or release records.
