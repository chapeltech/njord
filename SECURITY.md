# Njord Security Model

This document describes the security boundary of the first production
release. It is an operator guide and threat model, not a claim that accounting
software removes the need for sound host administration, backups, or review of
financial records.

## Supported deployment

The supported public deployment is `docker-compose.yml` plus
`compose.github.yaml`, behind an operator-managed HTTPS nginx reverse proxy on
a private Docker network. Only nginx is public. The Njord HTTP listener uses
plain HTTP on that private network; PostgreSQL and every PostgREST listener are
bound inside the appliance and are not publicly exposed. Compose also
publishes the gateway on a configurable loopback-only port. Setting
`NJORD_ALLOW_UNAUTHENTICATED=1` is solely for local demonstrations and is not a
public deployment mode.

The host administrator, Docker daemon, appliance root entrypoint, PostgreSQL
superuser, and anyone holding a backup decryption identity are trusted. Anyone
who controls one of those can read or change every Book. GitHub is trusted to
authenticate the immutable numeric account id returned by OAuth. Browser
users, direct-SQL users, request bodies, imported accounting data, and public
network traffic are untrusted.

## Assets and boundaries

The protected assets are accounting records, Book membership, GitHub identity
bindings, PostgreSQL credentials, browser sessions, OAuth/JWT secrets, backup
archives, and availability of the service.

Traffic crosses these boundaries:

1. The public browser reaches nginx over HTTPS. nginx terminates TLS, applies
   the operator's public connection/rate policy, and proxies a normalized HTTP
   request to the gateway. The gateway deliberately does not trust forwarded
   addresses for identity or redirects; per-client edge throttling therefore
   belongs at nginx, while the gateway enforces global and session bounds.
2. The gateway serves a fixed set of static files, performs GitHub OAuth, and
   routes authenticated JSON RPCs. It never accepts a client-selected database
   endpoint or PostgreSQL role.
3. Control and Book PostgREST processes listen on loopback and connect as the
   dedicated, non-owner `njord_authenticator` role. A browser RPC's verified
   short-lived JWT permits PostgREST to `SET LOCAL ROLE` to exactly one admitted
   human role; separate internal claims select only the narrow
   `njord_gateway` capability.
4. PostgreSQL functions, grants, constraints, and triggers are the final
   authorization and accounting boundary. Each Book is a physical database
   with RO, RW, and Admin capability roles.
5. A small set of gateway operations sends bounded, validated messages over a
   private Unix socket to the lifecycle broker. The broker runs as OS user
   `postgres` and invokes only fixed, argument-vector programs for Book
   provisioning/deletion and role grants; a request cannot supply SQL, a shell
   command, executable path, or database endpoint.

## Authentication and sessions

OAuth uses an unpredictable, signed, ten-minute state cookie, PKCE, a fixed
configured callback, and GitHub's immutable numeric user id. Login is
invitation-only; a renamed GitHub login updates display data but cannot change
the bound PostgreSQL role. A requested post-login destination is accepted only
as a normalized path on the configured public origin. Forwarded headers cannot
select a redirect origin, and the gateway accepts no client role claim.

Only a SHA-256 hash of a browser session token is stored in PostgreSQL. On
HTTPS, both cookies are host-only, `HttpOnly`, `Secure`, and path-scoped to `/`:
the session cookie is `SameSite=Strict`, while the OAuth state cookie is
`SameSite=Lax` for GitHub's top-level callback. State-changing authenticated
RPCs and logout must carry the exact configured public `Origin`. Logout
succeeds only when database revocation succeeds. Expired and revoked session
rows are retained for 30 days and pruned when a new session is created; the hot
resolution path updates last-seen time no more than once per five minutes.

A global administrator can disable an identity. That operation revokes web
sessions, changes the human role to `NOLOGIN`, removes its Book capability
memberships, and terminates existing direct database sessions in one database
transaction. Re-enabling restores only catalogue memberships that still
exist. Revoking an unaccepted GitHub invitation blocks OAuth admission; use
global disable when direct-SQL access must also be removed.

The appliance disables PostgreSQL IP networking and accepts only its explicit
peer-authenticated Unix-socket identities. Network SQL is future work and, if
added, must use GSSAPI or mutual TLS rather than passwords. A Book role never
grants control of another Book.

## Request and process controls

The gateway accepts only the documented methods, content types, static files,
and canonical `/api/control/rpc/NAME` or `/api/books/BOOK/rpc/NAME` routes.
Book handles and RPC names are allowlisted syntactically and routing injects
the path Book id into the JSON body. Hop-by-hop headers are removed. Request
and upstream response sizes, upstream time, concurrent requests, concurrent
session lookups, login attempts, Book adapter starts, and resident adapters
are bounded. Adapters remain resident once started, by product decision, up to
the configured capacity; they are drained on shutdown and deletion.

The browser receives a restrictive CSP, clickjacking, MIME-sniffing, referrer,
permissions, and cache headers. Scripts must be external and same-origin.
Inline CSS is allowed because report charts and arbitrary account depths use
Elm-computed geometry; no untrusted value is interpreted as CSS. Dynamic text
is emitted through Elm text nodes, not HTML.

Control PostgREST death makes readiness fail and terminates the appliance for
Compose restart. A failed Book adapter is discarded and restarted on the next
request. The gateway drains in-flight work before its supervised adapters and
PostgreSQL stop. Book lifecycle operations and physical backups share one
exclusive appliance lock. Startup reconciles the recoverable crash points of
Book creation/deletion before serving.

## Secrets, images, and logs

Production secrets are mode-0600 files mounted from `/run/secrets`; `_FILE`
settings are preferred. They are absent from the Docker build context and the
runtime image allowlist. The gateway passes a minimal environment to child
processes. OAuth codes, access tokens, cookies, authorization headers, session
hashes, request bodies, and database connection secrets must not be logged.
The supplied nginx format omits query strings so an OAuth callback code cannot
enter access logs.

Base images, the downloaded PostgREST archive, and the release-only Syft and
Trivy tools are pinned by digest or checksum. `scripts/build-release` produces
a versioned image and SPDX JSON SBOM, then fails on a known high or critical
image vulnerability. Before deployment, update the pins deliberately, rebuild,
run `npm audit`, review the scan and SBOM, and run all release tests. Never
silently float a production tag. The scanners require the Docker socket and
therefore run only as an explicit trusted-operator release step, never inside
the public service.

The container has a read-only root filesystem, writable tmpfs runtime
directories, no new privileges, and only the Linux capabilities required by
the PostgreSQL entrypoint to adopt the persistent volume and drop privileges.
PostgreSQL and the lifecycle broker run
as OS user `postgres`. The HTTP application and every PostgREST process run as
OS user `njord`; peer authentication allows that account to connect only as
the non-owner database role `njord_authenticator`.

## Backup and incident handling

A physical backup contains the whole cluster, including accounting records,
identity metadata, and roles. Use
`scripts/backup-cluster-encrypted` with an age recipient; it never writes a
plaintext archive. Store its private identity separately, restrict both to the
minimum operators, keep an off-host copy, and test decryption and clean-volume
restore. Plain `scripts/backup-cluster` exists for a trusted pipe but its output
must never be retained or transported unencrypted in production.

For suspected compromise: remove public routing, preserve host/nginx/gateway
and PostgreSQL logs, rotate GitHub and Njord secrets, disable affected users,
invalidate all web sessions, rotate any exposed database credentials and age
identities, verify role membership from the control catalogue, and restore a
known-good backup if accounting integrity cannot be established. GitHub client
secret rotation, session/JWT rotation, backup identity rotation, and full
restore are operational procedures in [OPERATIONS.md](OPERATIONS.md).

## Review record

The release review covers OAuth state/PKCE and redirect binding; cookie,
session, logout and CSRF behaviour; the global and per-Book access matrix over
HTTP and direct SQL; every grant and `SECURITY DEFINER` routine; dynamic SQL;
cross-row constraints and concurrent mutations; API parsing/routing; process
and image boundaries; secret/log handling; lifecycle recovery; and encrypted
backup restore. Regression tests named in `tests/run.sh` and the two Compose
suites are the executable review record. A release is blocked while any review
finding remains open or any release-gate step in
[OPERATIONS.md](OPERATIONS.md) fails for the exact candidate image.

## Out of scope

Njord is an accounting system, not a tax-filing agent, payroll service,
document malware scanner, intrusion-detection platform, or substitute for
nginx/host monitoring. UK filing exports described as future work are not
silently treated as fileable submissions. Those are separate capabilities,
not incomplete security controls in the supported ledger deployment.
