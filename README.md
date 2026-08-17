# Njord

Njord is a PostgreSQL-backed, database-per-Book accounting application for personal books, UK
limited-company preparation work, straightforward Panama business/property
bookkeeping, and small Taiwan injection-moulding businesses. PostgreSQL owns the ledger rules, mutations, page models,
mappings, and reports; PostgREST exposes only a dedicated `api` schema; Elm
provides the browser presentation.

## Status

Njord is pre-1.0 production-release-candidate software. The supported public
topology is the database-per-Book Docker Compose appliance with GitHub OAuth
behind HTTPS nginx. Before entrusting a particular revision with real data, an
operator must complete the release, deployment, encrypted-backup, and clean-
restore gates in [OPERATIONS.md](OPERATIONS.md). Pre-1.0 releases do not promise
schema compatibility beyond the migration checks shipped with each image.

## Capabilities

- Hierarchical accounts and commodity-denominated double-entry Books.
- GnuCash-style inline registers, split transactions, General Journal, and a
  separate posting-reconciliation workflow.
- SQL-defined Balance Sheet, Net Worth, Trial Balance, Profit & Loss, Cash Flow,
  hierarchical tables, and reusable bar charts.
- Effective-dated currency and commodity valuations, including fixed assets
  such as property without pretending a house is a unit-traded commodity.
- Optional UK company, compact Panama business/property, and Taiwan small
  manufacturing preparation packs.
- One physical PostgreSQL database per Book, global and per-Book administration,
  browser-tab navigation, direct SQL access, and GitHub invitation-only web
  authentication.
- One Docker Compose appliance with durable migrations and whole-cluster
  backup/restore.

## UI tour

`Books` is the unscoped starting page. Open a card to reach that Book's settings
and ACL; native middle-click opens another browser tab. Within a Book, `Accounts`
shows the indented chart and opens account registers, `Journal` shows every
posting, and `Reports` opens the SQL-defined report library. Reconciliation is
under Accounts rather than a status column in the register. Global `Admin`
appears only to installation administrators. The language flag in the upper
right selects English (`en-GB`), Panamanian Spanish (`es-PA`), or Traditional
Chinese for Taiwan (`zh-TW`).

## Quick demonstration

This deliberately unauthenticated loopback setup loads rich fake data and is
only for evaluation on the local machine:

```sh
cp .env.example .env
install -d -m 0700 secrets
openssl rand -hex 32 >secrets/postgres_password
chmod 0600 secrets/postgres_password
docker network create njord-edge

# Set NJORD_INSTALL_EXAMPLES=1 in .env, then:
docker compose -f compose.yaml -f compose.local.yaml pull njord
docker compose -f compose.yaml -f compose.local.yaml up --no-build -d
```

Open `http://127.0.0.1:8080/`. The examples cover a large personal ledger, a UK
company, a Panama property business, and a Taiwanese injection-moulding factory.
Stop with the same Compose file list and `down`; add `--volumes` only when you
intend to discard the demonstration databases.

The UK pack prepares statutory, Corporation Tax, VAT, and supporting schedules
for review. It does not generate filing-ready accounts or submit anything to
Companies House or HMRC.

The Panama pack records ordinary business facts and extends them with an
optional residential-property register, leases, property-tax schedules, and
repair/capital classifications. Its reports are reviewable working papers, not
legal advice, a filing-obligations engine, or tax returns.

The Taiwan pack starts with ordinary business-tax, invoice, annual-preparation,
withholding, calendar, and trade-aging working papers. Its optional injection-
moulding extension records stock, BOMs, production runs, material issues,
machines, moulds, yields, costs, and product margins. It prepares accounting
evidence; it is not an official-return generator or regulatory adviser.

## Requirements

- PostgreSQL 17 or 18 (the appliance image uses 18)
- Node.js 20 or later and npm
- Chromium for the Playwright browser smoke test (`npx playwright install chromium`)
- `curl`, `sha256sum`, and `xz` for the pinned PostgREST installer
- `age` on the operator host for production backup-key generation and verification

The project pins PostgREST 14.16. On Linux x86-64, install it locally for
source-tree development with:

```sh
scripts/install-postgrest
```

Set `POSTGREST_BIN` instead if PostgREST 14.16 is installed elsewhere or the
platform is not Linux x86-64.

## Docker Compose appliance

The appliance image contains PostgreSQL 18, PostgREST 14.16, Node.js 22, the
gateway, and the compiled Elm UI. One volume holds the entire PostgreSQL
cluster: the control database and every physical Book database. The published
image is a multi-platform OCI image for Linux AMD64 and ARM64, including
AArch64 machines such as AWS Graviton and 64-bit Raspberry Pi systems.

GitHub Actions publishes `ghcr.io/chapeltech/njord`. A push to `master`
updates `latest` and a source-SHA tag; tags such as `v0.1.0` additionally
publish `v0.1.0`, `0.1.0`, and `0.1`. Every image includes OCI provenance and
an SBOM. The canonical deployment files are:

- [compose.yaml](compose.yaml), the hardened appliance and durable volume;
- [compose.github.yaml](compose.github.yaml), GitHub OAuth secrets; and
- [.env.example](.env.example), the documented configuration surface.

Download those files without cloning the source repository:

```sh
curl -fsSLO https://raw.githubusercontent.com/chapeltech/njord/master/compose.yaml
curl -fsSLO https://raw.githubusercontent.com/chapeltech/njord/master/compose.github.yaml
curl -fsSLO https://raw.githubusercontent.com/chapeltech/njord/master/.env.example
cp .env.example .env
```

If the GHCR package is private, log in once with a GitHub token carrying
`read:packages` before pulling. Then prepare the installation:

```sh
install -d -m 0700 secrets
openssl rand -hex 32 >secrets/postgres_password
chmod 0600 secrets/postgres_password
docker network create njord-edge
docker compose -f compose.yaml -f compose.github.yaml pull njord
```

To build the current checkout instead, run `docker compose build`; production
hosts should pull a version tag or immutable digest and use `--no-build`.

The base Compose file publishes no host ports. It attaches the service alias
`njord` to the external network named by `NJORD_DOCKER_NETWORK`; attach the
separately managed nginx service to that network and proxy HTTP to
`http://njord:8080`. Change `NJORD_HTTP_PORT` to change the internal listening
port; because the HTTP process is unprivileged, use a port from 1024 through
65535. For loopback diagnostics, add the local override:

```sh
docker compose -f compose.yaml -f compose.local.yaml up -d
```

This binds `127.0.0.1:${NJORD_HOST_PORT:-8080}` only. A fresh production
volume contains no example Books; set `NJORD_INSTALL_EXAMPLES=1` only for a
demonstration. PostgreSQL listens only on its Unix socket and is unavailable to
nginx or other network peers. For administrative direct SQL, use
`docker compose exec -e PGUSER=postgres njord psql -X ...`; the explicit role
is required by the appliance's peer-authentication map.

Later starts preserve the volume and never reload examples. `docker compose
stop` drains HTTP requests and Book adapters before PostgreSQL. The base image
refuses to start without authentication; `compose.local.yaml` is the explicit
unauthenticated loopback-only exception. Use `compose.github.yaml` for an
internet-facing installation and complete the deployment gate in
[OPERATIONS.md](OPERATIONS.md) for the exact image that will run.

## Backup, restore, and upgrades

The supported production backup is an age-encrypted PostgreSQL 18 physical base
backup. It is consistent across cluster roles, the control database, every Book
database, and the WAL needed for recovery. On a separate operator workstation,
create an age identity once and transfer only the public recipient file to the
server. Retain old private identities for as long as any backup encrypted to
them must remain restorable:

```sh
# Operator workstation:
age-keygen -o njord-backup-age-identity
age-keygen -y njord-backup-age-identity >njord-backup-age-recipient
chmod 0600 njord-backup-age-identity

# Server (after copying only njord-backup-age-recipient here):
install -d -m 0700 backups secrets
install -m 0600 njord-backup-age-recipient secrets/backup_age_recipient

docker compose exec -T -e PGUSER=postgres njord \
  scripts/backup-cluster-encrypted "$(cat secrets/backup_age_recipient)" \
  >"backups/njord-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"

# Operator workstation, after copying the encrypted archive off-host:
age --decrypt --identity njord-backup-age-identity \
  NJORD_BACKUP.tar.gz.age | gzip -t
```

The live volume needs temporary free space approximately equal to the current
cluster while the base backup is staged. The encrypted archive contains all
accounting data, identity metadata, and PostgreSQL role verifiers. Keep at least
one tested off-host copy. Plain `scripts/backup-cluster` exists only as the
trusted stream feeding the encrypted wrapper; do not retain or transport its
unencrypted output in production. A backup that has never survived a clean-
volume restore rehearsal is not a recovery plan.

Restore only into a new, empty named volume, using the same Njord image (and
therefore PostgreSQL 18) that produced the archive. Temporarily copy the needed
private age identity to `secrets/backup_age_identity` on the restore host, then
remove that copy after validation:

```sh
docker compose down
docker volume create njord-restored-data
docker run --rm --user root \
  --volume njord-restored-data:/var/lib/postgresql \
  --volume "$PWD/backups:/backup:ro" \
  --volume "$PWD/secrets/backup_age_identity:/run/secrets/backup_age_identity:ro" \
  --entrypoint /opt/njord/scripts/restore-cluster-encrypted \
  njord:0.1.0 /run/secrets/backup_age_identity \
  /backup/NJORD_BACKUP.tar.gz.age

# Set NJORD_DATA_VOLUME=njord-restored-data in .env, then:
docker compose -f compose.yaml -f compose.github.yaml up -d
docker compose exec -T -e PGUSER=postgres njord \
  scripts/migrate-databases --check
```

Replace `njord:0.1.0` with the immutable image tag that created the backup. The
restore command decrypts into private temporary storage inside the target
volume, rejects a nonempty target, unsafe archive paths, the wrong PostgreSQL
major version, and a failed `pg_verifybackup` manifest check, and removes its
temporary plaintext. It never overwrites the old volume. After startup, verify
the UI, roles, Book list, transaction and reconciliation counts, and important
reports before declaring the restore usable.

For an application upgrade:

1. Record the running image tag and confirm the installation is healthy.
2. Build or pull the new immutable image without stopping the old one.
3. Make and verify an encrypted pre-upgrade backup.
4. Stop the appliance, select the new image tag, and start it.
5. Watch `docker compose logs -f njord` until health is green, then run
   `scripts/migrate-databases --check` and exercise login and a representative
   Book read.

Startup applies only shipped, ordered migrations. Each migration and its ledger
row commit in one PostgreSQL transaction. A gap, changed checksum, partially
written ledger, newer database version, incomplete Book, or missing physical
Book aborts startup before PostgREST is exposed. A failed migration rolls back
that migration, but earlier migrations in the same upgrade may already have
committed. Application-image rollback is therefore not a database rollback:
unless the old release explicitly supports the resulting schema, restore the
pre-upgrade backup into a clean volume and run the old image against that copy.
Never run `sql/control.sql` or `sql/njord.sql` over a durable installation;
those are fresh-database loaders, not upgrades.

The first supported production schema is baseline version 1 for both the
control and Book databases; there is no supported production predecessor to
upgrade from. Fresh installers explicitly adopt their own verified, unversioned
loader output as version 1. Normal migration commands refuse an unversioned
database unless the operator deliberately enables the controlled adoption path
after verifying its fingerprint and taking a backup.

[OPERATIONS.md](OPERATIONS.md) contains the deployment, rollback, monitoring,
backup/restore, incident-response, and secret-rotation checklists. Let the image
manage PostgreSQL file ownership, keep the old data volume until an upgrade and
restore are independently verified, and document who may read backups, secrets,
and the Docker socket.

## Development

```sh
scripts/init-development-databases
npm install
npx playwright install chromium
npm run build
```

This creates the `njord` control database and five physical Book databases:
`demo`, `personal`, `uk-business`, `panama-property`, and
`taiwan-injection`. The control database contains users, catalogue entries,
membership, and provisioning state; it contains no accounting rows. Every
Book database installs the same SQL schema and contains exactly one ledger.
Setup also creates a constrained login role matching the current operating-
system user (`elric` here). Set `NJORD_DATABASE_ROLE` to choose another
lowercase PostgreSQL role independently of the administrative `PGUSER` used
to install the databases.

`sql/control.sql` is the control-plane loader and `sql/njord.sql` is the Book
schema loader. Every file under `sql/` is production code. Rich example books
and transactions live under `examples/` and are installed only when chosen.

## Run the application

Start the control PostgREST adapter, on-demand Book adapters, router, and UI:

```sh
scripts/run-development
```

Open `http://127.0.0.1:8080/`. The same-origin router sends catalogue requests
to the control database and Book requests to an isolated PostgREST adapter for
the selected database. It starts local Book adapters on demand, verifies their
database identity and schema version, and keeps them resident until application
shutdown or Book deletion.
It contains no accounting or report logic.

Useful overrides are:

- `NJORD_CONTROL_DATABASE` and `NJORD_DATABASE_ROLE` for the multi-database launcher;
- `PGRST_DB_URI` and any standard `PGRST_*` setting for PostgREST itself;
- `NJORD_UI_HOST`, `NJORD_UI_PORT`, and `NJORD_CONTROL_POSTGREST_URL` for
  the router;
- `NJORD_BOOK_POSTGREST_URLS` for an externally managed JSON map of Book
  handles to adapters instead of local on-demand processes;
- `NJORD_CONTROL_POSTGREST_POOL_SIZE` for the control adapter and
  `NJORD_BOOK_POSTGREST_POOL_SIZE` for each on-demand Book adapter, with
  `NJORD_BOOK_SHUTDOWN_SECONDS` for graceful shutdown;
  and
- `NJORD_BOOK_SCHEMA_VERSION` for the Book adapter compatibility contract
  (normally leave this at the product default).

All development servers bind to `127.0.0.1` by default. The database-per-Book
launcher is the only supported application topology; lower-level tests start
their own isolated PostgREST processes directly.

## Configuration

`.env.example` is the canonical Compose template. The important settings are:

| Setting | Meaning |
| --- | --- |
| `NJORD_IMAGE` | Appliance image/tag to run; defaults to the published GHCR `latest` image. Pin a version or digest for production. |
| `NJORD_HTTP_PORT` | Unprivileged plain-HTTP port (1024–65535) inside the shared Docker network. |
| `NJORD_DOCKER_NETWORK` | Existing external network shared with nginx. |
| `NJORD_NETWORK_ALIAS` | DNS name nginx uses for the Njord service. |
| `NJORD_DATA_VOLUME` | Durable PostgreSQL cluster volume; treat as installation identity. |
| `NJORD_INSTALL_EXAMPLES` | `0` for production; `1` only on a new demonstration volume. |
| `NJORD_ADMIN_GITHUB_LOGIN` | Lowercase GitHub login of the first global Admin. |
| `NJORD_GITHUB_CLIENT_ID` | Public OAuth App client ID. |
| `NJORD_PUBLIC_URL` | Exact external HTTPS origin, with no application path. |
| `*_FILE` secret settings | Read-only files for PostgreSQL, GitHub, session, and JWT secrets. |
| resource/log settings | Container memory, CPU, PID, shared-memory, and JSON-log limits. |

Names identifying the control database, data volume, and first PostgreSQL role
are durable. Do not casually change them after initialization. The HTTP port,
resource limits, log limits, GitHub client credentials, and external URL are
deployment configuration and may be changed with the corresponding nginx/OAuth
updates and a service recreation. Keep direct secret values out of `.env`; the
GitHub overlay consumes the `_FILE` paths.

## GitHub authentication

Production web access is invitation-only. First choose the one external HTTPS
origin that nginx serves, for example `https://accounts.example.com`. In
GitHub, open **Settings → Developer settings → OAuth Apps → New OAuth App** and
register ([GitHub's OAuth App instructions](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app)):

- **Homepage URL:** `https://accounts.example.com`
- **Authorization callback URL:**
  `https://accounts.example.com/auth/callback`

Do not enable Device Flow and do not add a GitHub scope: Njord reads only the
authenticated account's public numeric ID, login, and display name. Copy the
OAuth Client ID into `.env`, set the initial installation administrator, and
create the secret files:

```sh
# .env
NJORD_ADMIN_GITHUB_LOGIN=elric1
NJORD_GITHUB_CLIENT_ID=replace-with-github-client-id
NJORD_PUBLIC_URL=https://accounts.example.com

printf '%s\n' 'replace-with-github-client-secret' >secrets/github_client_secret
openssl rand -hex 32 >secrets/session_secret
openssl rand -hex 32 >secrets/postgrest_jwt_secret
chmod 0600 secrets/github_client_secret secrets/session_secret \
  secrets/postgrest_jwt_secret

docker compose -f compose.yaml -f compose.github.yaml pull njord
docker compose -f compose.yaml -f compose.github.yaml up --no-build -d
```

The declared administrator is resolved against GitHub during first boot,
invited by immutable numeric GitHub ID, assigned the lowercase PostgreSQL role
`elric1`, and granted global Admin immediately—even if the installation has no
Books. Startup fails rather than silently running half-configured if GitHub is
unreachable or any required OAuth setting or secret is absent. A reboot does
not need GitHub after that invitation has been prepared.

Attach nginx's Compose service to the same external network and proxy the HTTPS
virtual host to `http://njord:8080` (or the configured
`NJORD_HTTP_PORT`). [deploy/nginx-njord.conf.example](deploy/nginx-njord.conf.example)
contains the minimal upstream and location block. Preserve `Host`,
`X-Forwarded-Host`, `X-Forwarded-Proto`, and `X-Forwarded-For`. The gateway does
not trust those headers to invent its public origin: redirects and GitHub's
callback are always built from the exact `NJORD_PUBLIC_URL`, so that value must
match the OAuth App and nginx virtual host.

Loopback HTTP is accepted only for local development; every non-loopback public
URL must use HTTPS. The router keeps the GitHub client secret and transient
OAuth access token out of PostgreSQL, stores only a SHA-256 hash of each opaque
browser-session cookie, and replaces every browser Authorization header with a
signed 60-second PostgREST role JWT. Over HTTPS, both cookies are Secure,
HttpOnly, and host-only: the browser session is `SameSite=Strict`, while the
ten-minute OAuth state cookie is `SameSite=Lax` so GitHub can return it on the
callback. Sessions have a fixed server-side lifetime
(seven days by default), do not slide indefinitely, and are renewed by signing
in again. Logout revokes the server record; expiry, revocation, or disabling a
principal invalidates it on the next request.

The web workflow is preferred: global Admin admits an account from the Admin
page, while a Book Admin may invite an account directly from that Book with RO,
RW, or Admin access. In both cases the gateway resolves the current login to
GitHub's numeric ID before SQL records the invitation. An invited person accepts
the invitation simply by signing in. Global admission grants no Book and no
global Admin access; Book Admin does not imply global Admin.

For recovery or initial development setup, the equivalent operator command
provisions a PostgreSQL role with the exact lowercase login and editor access
to selected existing Books:

```sh
scripts/invite-github-user elric1 demo personal
# Or, for a disposable showcase:
scripts/invite-github-user elric1 --all-books
```

The command records GitHub's immutable numeric user ID, so a renamed or recycled
login cannot accept the invitation. Later GitHub renames update the displayed
provider login but deliberately retain the admitted PostgreSQL role. The command
does not set a PostgreSQL password; an administrator may add one separately if
that person should also use direct SQL.
Global Admin admits people to the installation. Book administrators manage a
particular Book's membership from that Book's detail using three levels: RO,
RW, and Admin. These map to viewer, editor, and owner control memberships and
to fixed `NOLOGIN` capability roles holding the corresponding physical Book
grants. The membership row and role grant change in one transaction. The
global Admin tab is separate and is not implied by administering a Book.

Create another empty Book database with:

```sh
scripts/create-book-database doodles "Doodles Household" USD household
```

The database handle is stable and globally unique; the display name remains
editable. `CREATE DATABASE` cannot run inside a PostgREST request transaction,
so the router invokes this narrowly scoped operational script after control
SQL has validated and recorded the request.

## HTTP API

Only functions in the `api` schema are exposed. Through the same-origin
gateway, control functions use `/api/control/rpc/FUNCTION` and Book functions
use `/api/books/HANDLE/rpc/FUNCTION`. Base tables and internal reports are not
HTTP resources. The gateway rejects unscoped `/rpc/FUNCTION` requests; only
the explicit URL may select a database.

Each UI page is returned by one canonical table-returning function:

- `shell_page`
- control `admin_page`
- control `add_book_page`
- `book_page`
- `accounts_page`
- `ledger_page`
- `reports_page`
- `report_page`
- `general_journal_page`
- `reconciliation_page`
- `add_account_page`

The gateway composes Book `book_page` with control `book_acl_page` for a
Book-management detail; it does not derive settings or authorization data.

`report_page` is the single page function for every financial report. SQL
views define the report catalogue, columns, hierarchy, and reusable bar-chart
metadata, so new tabular reports and single-series bar charts require no Elm
changes.

Report page contexts include authoritative date-range, cash-account, and
missing-valuation messages. Date-valued `as_of` and `to` parameters include
the complete selected calendar day.

The web UI uses shareable root query routes, such as
`/?page=admin`, `/?page=book&book=personal`,
`/?page=accounts&book=personal` and
`/?page=ledger&book=personal&account=Current%20Account`. Primary navigation,
Book cards, account entries, and report cards are ordinary anchors, so browser new-tab
gestures work normally.

Reports use routes such as
`/?page=report&book=personal&report=net-worth`.

The seed data includes `uk-business`, an illustrative FRS 105, standard-VAT
company with sales, purchases, open invoices, VAT control postings, payroll, a
fixed asset, depreciation, and a director loan. Open
`/?page=reports&book=uk-business` to inspect its database-grouped UK preparation
pack. Unsupported company frameworks and VAT schemes are surfaced as blockers;
they are never approximated as filing figures.

The seed data also includes `panama-property`, an illustrative PAB-denominated
property company with a three-unit rent roll, long- and short-term leases,
land/building/improvement accounts, a mortgage, deposits, operating expenses,
property-tax instalments, and dated property valuations. Open
`/?page=reports&book=panama-property` to inspect the SQL-defined Panama business
and residential-property working papers.

The `taiwan-injection` example is a populated TWD-denominated plastics factory
with raw material, WIP, finished goods, BOMs, two production runs, machines,
moulds, domestic and export sales, uniform invoices, withholding, and open
trade balances. Open `/?page=reports&book=taiwan-injection` to inspect all
twelve SQL-defined Taiwan reports. Its account names and Taiwan-specific report
presentation use Traditional Chinese (Taiwan), while stable IDs remain in
English for API and SQL compatibility.

Open `/?page=admin` as a global administrator to manage the people admitted to
the installation. Open `/?page=books` and choose a Book to change its display
name or explicit owner/entity type, manage its effective-dated reporting
currency, archive or restore it, manage its RO/RW/Admin access list, or
configure an eligible optional business pack. New books are
households unless the user says otherwise; a USD household is not a Panama
book. Empty books can replace their initial reporting currency, while active
books add a present or historical dated transition without rewriting accounts or postings. Company
setup atomically adds the initial accounting period, a usable standard account
hierarchy, and any required VAT control account. Book and established-period
identifiers remain read-only. Permanent book deletion requires archive plus
exact-name confirmation; Book-local SQL authorizes it and the narrow
provisioner drops the physical database and unregisters its control entry.

Book-local settings and accounting mutations include:

- `create_book`
- `update_book_settings`
- `set_book_reporting_currency`
- `archive_book`
- `restore_book`
- gateway-routed `delete_book` (Book-local authorization plus physical-database
  provisioner)
- `configure_uk_company`
- `configure_panama_business`
- `configure_taiwan_business`
- `create_account`
- `preview_transaction`
- `create_transaction`
- `replace_transaction`
- `update_ledger_line`
- `set_posting_reconciled`

The control database separately exposes global invitation/enablement and
Book-ACL mutations. Their SQL authorization is global Admin or that Book's
Admin respectively; the gateway's routing does not grant the capability.

For example, fetch a ledger page in one request:

```sh
curl -X POST http://127.0.0.1:8080/api/books/personal/rpc/ledger_page \
  -H 'content-type: application/json' \
  -d '{"p_book_id":"personal","p_account_id":"Current Account"}'
```

Preview a transaction without writing it:

```sh
curl -X POST http://127.0.0.1:8080/api/books/personal/rpc/preview_transaction \
  -H 'content-type: application/json' \
  -d '{
    "p_book_id":"personal",
    "p_transaction":{
      "date":"2026-01-31",
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

In development, connect directly as the same PostgreSQL role used by the Web
UI. The database itself selects the Book:

```sh
psql -U elric -d personal
```

The supported public Compose topology deliberately exposes no PostgreSQL TCP
listener. Enabling internet-facing direct SQL is a separate operator decision:
configure PostgreSQL network access, host/firewall policy, TLS plus SCRAM or
client certificates, and a password or certificate for each human role. Do not
publish the appliance's local socket or rely on the bootstrap password file as
a human credential. Web and direct access then converge on the same constrained
human role and Book capability memberships.

Book-local procedure overloads therefore need no `book_id`. Open an asset
account with an opening balance:

```sql
CALL open_account(
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
    '2026-01-15',
    'Current Account',
    'Expenses',
    -42.50
);
```

Useful SQL report surfaces include:

```sql
SELECT * FROM ledger('Current Account');
SELECT * FROM transactions;
SELECT * FROM postings;
SELECT * FROM accounts;

-- Report signatures accept the invariant Book handle as a fail-closed guard.
SELECT * FROM bsheet_report('personal', '2026-01-31 23:59:59.999999');
SELECT * FROM hierarchical_net_worth_report('personal', '2026-01-31 23:59:59.999999');
SELECT * FROM net_worth_history('personal', '2026-01-31', 12);
SELECT * FROM tb_report('personal', '2026-01-31 23:59:59.999999');
SELECT * FROM hierarchical_profit_loss_report('personal', '2026-01-01', '2026-01-31 23:59:59.999999');
SELECT * FROM cf_report('personal', '2026-01-01', '2026-01-31 23:59:59.999999');

-- UK company preparation surfaces (working papers, not filing artefacts):
SELECT * FROM uk_statutory_statement_values(
    'uk-business', 'profit_loss', '2026-01-01', '2026-12-31 23:59:59.999999'
);
SELECT * FROM uk_company_report_rows(
    'uk-business', 'vat-return', '2026-12-31 23:59:59.999999',
    '2026-01-01', '2026-12-31 23:59:59.999999'
);
SELECT * FROM uk_ixbrl_facts('uk-business', '2026-01-01', '2026-12-31');

-- Panama bookkeeping/tax-preparation working papers (not legal advice or returns):
SELECT * FROM panama_report_rows(
    'panama-property', 'panama-rent-roll', '2026-12-31 23:59:59.999999',
    '2026-01-01', '2026-12-31 23:59:59.999999'
);
SELECT * FROM panama_report_rows(
    'panama-property', 'panama-property-profit-loss',
    '2026-12-31 23:59:59.999999',
    '2026-01-01', '2026-12-31 23:59:59.999999'
);

-- Taiwan injection-moulding working papers (not filed returns):
SELECT * FROM taiwan_report_rows(
    'taiwan-injection', 'taiwan-production-cost',
    '2026-12-31 23:59:59.999999',
    '2026-01-01', '2026-12-31 23:59:59.999999'
);
SELECT * FROM taiwan_report_rows(
    'taiwan-injection', 'taiwan-inventory-rollforward',
    '2026-12-31 23:59:59.999999',
    '2026-01-01', '2026-12-31 23:59:59.999999'
);
```

The core report functions accept timestamps and use exact inclusive bounds.
Use an end-of-day timestamp for a whole calendar day, as above. The `api` page
functions accept dates and apply that calendar-day conversion automatically.
`uk_ixbrl_facts` is a semantic hand-off for future tagging; it is not an iXBRL
document and must not be submitted as one.

One-sided imports remain in staging and do not create accounting rows until
classified into complete transactions. Every transaction must contain at least
two non-zero, finite lines, must not repeat an account, and must balance
separately for every asset.

## Tests

With a reachable PostgreSQL server:

```sh
tests/run.sh
tests/topology.sh
tests/api.sh
npm run build
```

The topology test creates an isolated control database and two guarded Book
databases, proves each rejects a second Book, proves unscoped pages resolve only
through control, verifies the physical-deletion authorization/provisioner
boundary, and removes all three on exit.
The broad SQL and API suites retain an all-in-one compatibility fixture so the
existing accounting/report assertions can exercise several jurisdiction packs
efficiently. That demo fixture alone installs test-only unscoped page shims;
production Book databases do not. `tests/api.sh` starts a temporary PostgREST process and router,
checks every page and mutation RPC, checks structured validation failures, and
confirms that base tables are not exposed. Its browser phase performs real
create/replace/update saves, exercises every report and both add forms, and
checks desktop and mobile layouts.

Set the normal libpq variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`) if
needed. If direct access is unavailable but passwordless `sudo -u postgres` is
available, the scripts use it automatically.

Container acceptance tests require Docker:

```sh
npm run test:compose
npm run test:compose-oauth
```

The first covers a fresh version-1 baseline, repeated same-version startup,
concurrent controlled baseline adoption, future-version refusal, interrupted
Book lifecycle recovery, abrupt failure, persistence, encrypted whole-cluster
backup, exact test-volume destruction, verified clean restore, and restored
product snapshots. The second runs the appliance behind a real nginx container and
tests GitHub OAuth protocol behavior plus global Admin and Book RO/RW/Admin.
GitHub alone is replaced by a deterministic local protocol fixture.

## Future goals

- Remove Node.js from the production appliance by replacing the HTTP gateway,
  PostgREST adapter supervisor, and privileged lifecycle broker with small
  Haskell executables built on WAI/Warp. Keep the upstream PostgREST binary
  unchanged, preserve the existing process and operating-system privilege
  boundaries, and move no accounting or report logic out of SQL. Node may
  remain a development-only tool for browser tests or building Elm. This goal
  is complete only when the release image contains no Node runtime and the
  existing OAuth, authorization, routing, lifecycle, recovery, and Compose
  acceptance suites pass without weakened coverage.

## Limitations

- No jurisdiction pack is tax, legal, payroll, or filing software. The UK,
  Panama, and Taiwan outputs are reviewable working papers.
- UK iXBRL facts are a semantic hand-off, not a filed iXBRL document; Njord
  does not submit to Companies House, HMRC, Panama authorities, or Taiwan
  authorities.
- The first UK envelope is intentionally narrow: standalone private company
  limited by shares, GBP, FRS 105, ordinary accrual accounting, and standard
  invoice VAT. Unsupported configurations fail closed.
- PostgreSQL 18 physical backups restore to PostgreSQL 18. Cross-major upgrades
  require a separately designed and rehearsed logical migration.
- Published appliance images support Linux AMD64 and ARM64. Other CPU
  architectures are not currently built or tested.
- The source currently has no granted open-source licence; see **Licence**.

## Contributing

Start with [ARCHITECTURE.md](ARCHITECTURE.md). Keep accounting rules,
authoritative validation, report structure, presentation vocabulary, and i18n
in SQL, and keep Elm limited to rendering and transient interaction. Every
behavioral change should add the narrowest SQL/API/browser/container regression
test that proves its boundary. Run the relevant suites above and `git diff
--check` before proposing a change. Until a contribution licence and project
governance are chosen, discuss substantial third-party contributions with the
owner before investing work.

## Licence

No licence has been granted yet. Copyright remains with the project owner; the
repository's visibility does not by itself grant permission to copy, modify,
or redistribute it. A future public release must add an explicit `LICENSE`
file before describing Njord as open source.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the page-function contract,
database-per-Book topology, accounting boundary, router exception, and
PostgreSQL-role authorization model. [SECURITY.md](SECURITY.md) documents the
threat model and [OPERATIONS.md](OPERATIONS.md) the production runbooks.
