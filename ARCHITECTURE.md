# Architecture

Njord is a SQL-only financial management package.  PostgreSQL is the
application boundary: the schema, constraints, mutation procedures, import
staging, and reports should all live in SQL.

There is intentionally no command-line wrapper in the core package.
PostgREST is the HTTP adapter over the same PostgreSQL schema that an
interactive `psql` user uses.  User interfaces may make data entry pleasant,
but they must not become the place where accounting rules are enforced.

The current UI covers personal accounting and a UK limited-company preparation
pack: books, hierarchical accounts, balanced and split transactions, account
ledgers, the General Journal, reconciliation, database-defined financial
reports, statutory-account schedules, Corporation Tax working papers, VAT
working papers, and supporting schedules. It prepares and explains figures; it
does not file accounts or returns with Companies House or HMRC.

## Cluster and Database Topology

A Njord installation uses one PostgreSQL cluster with one control database
and one physical database per Book. It never creates book-named tables or
schemas. Every Book database installs the same production schema and therefore
has ordinary stable names such as `accounts`, `transactions`, `postings`,
`accts`, `xactions`, report views, and the `api` schema.

The control database contains only cluster-wide facts: principals, the global
administrator grant, the Book catalogue, Book membership, supported initial
denominations, provisioning state, and navigation discovery. It contains no
ledger postings. A Book
database contains exactly one `books` settings row and all accounting and
report-pack data for that Book. The Book handle must equal
`current_database()`; an insert/update trigger preserves that invariant, and
the primary key therefore makes a second Book impossible.

The Book database is authoritative for its display name, entity type,
reporting-currency history, and archive state. The matching control-catalogue
fields are a navigation projection. The router refreshes that projection from
the canonical `book_identity` SQL component after Book reads and mutations;
the synchronization is idempotent, and a later Book-page read repairs an
interrupted refresh. No accounting fact is duplicated across databases.

The database handle is a stable, globally unique, lowercase PostgreSQL name,
such as `doodles`; the Book's display name remains freely editable. This makes
direct access natural (`psql -U elric -d doodles`) and gives backup, restore,
retention, and deletion a real ledger boundary.

PostgREST connects to one database, so the HTTP deployment has one control
PostgREST adapter and one adapter for each active Book database. The same-origin
gateway routes `/api/control/rpc/FUNCTION` to the control adapter and
`/api/books/HANDLE/rpc/FUNCTION` to the database resolved from the authorized
control catalogue. A body `p_book_id` is an invariant SQL guard: it may not
choose the database and must agree with the URL when present. The gateway
rejects every unscoped `/rpc/FUNCTION` request.

Book adapters start on demand with a small connection pool and remain resident
until application shutdown or Book deletion. Concurrent first requests share
one startup. Before
forwarding the first request, the gateway calls the authenticated Book-local
`api.adapter_status()` function and requires both its `current_database()`
identity and schema version to match the route. Adapters drain active requests
on shutdown, expose PostgREST health checks, forward labelled logs, and are
restarted on a later request after failure. These are transport and process
lifecycle responsibilities; the gateway must not calculate accounting values,
choose accounts, or validate ledger data.

`CREATE DATABASE` and `DROP DATABASE` cannot run inside the transaction around
a PostgREST RPC. They are the documented operational exception to the SQL-only
application rule. Control SQL records creation intent, while Book-local SQL
authorizes deletion against the physical ledger's identity and lifecycle state.
Narrow provisioning scripts create or drop the exact validated database and
install or unregister the SQL product. Permanent deletion still requires archive
plus exact display-name confirmation and reports that recovery requires a backup.

The control catalogue makes the cross-database lifecycle explicit with
`provisioning`, `ready`, and `deleting` states. A Book is routable only while
`ready`. Creation/deletion, schema migration, and physical backup share one
cluster lifecycle lock. Before HTTP starts, reconciliation removes an abandoned
intent with no database, promotes a complete provisioning database only after
identity/schema/grant checks, removes an incomplete provisioning database, and
finishes an interrupted deletion. These states turn unavoidable nontransactional
`CREATE/DROP DATABASE` gaps into deterministic recovery rather than pretending
the catalogue and cluster change atomically.

Base-table keys and HTTP signatures deliberately retain `book_id`. In a guarded
Book database it is an invariant equal to `njord.database_book_id()`, never a
tenancy selector. Keeping it makes cross-table ownership constraints, portable
exports, and route/body fail-closed checks explicit; it is a stable integrity
field rather than unfinished shared-table tenancy. Clean direct-SQL views and
procedure overloads omit the already-known value.

## Database Roles and Authorization

Every person has one cluster-wide PostgreSQL role. For GitHub-authenticated
people, its spelling is the normalized lowercase GitHub login at the moment
their anchored invitation is created: GitHub user `elric1` maps to PostgreSQL
role `elric1`. GitHub's immutable numeric user id, not the mutable login or
email address, is the external identity key. A later GitHub rename updates the
observed provider login but deliberately does not rename the PostgreSQL role.
A separate immutable principal UUID keeps Book membership and audit history
stable across those external changes.

Web authentication maps a verified external identity to the person's role;
PostgREST then uses `SET LOCAL ROLE`. Direct SQL logs in as the same role.
Consequently `current_user` identifies the same person and reaches the same
SQL constraints and authorization rules through both paths.

Human roles are never superusers, never own product objects, and have
`NOCREATEDB`, `NOCREATEROLE`, `NOREPLICATION`, and `NOBYPASSRLS`. The trusted
PostgreSQL owner applies migrations and runs the lifecycle broker;
`njord_authenticator` is the dedicated non-owner PostgREST login, and
`njord_gateway` is a `NOLOGIN` capability for the gateway's five private
identity/session/catalogue synchronization functions. The authenticator is
`NOINHERIT`: it reaches gateway, anonymous, human, or Book capabilities only
after PostgREST selects the role represented by a verified short-lived JWT.
`njord_control.book_memberships` records owner/editor/viewer access. Database
`CONNECT` and Book-local grants enforce the physical boundary; SQL functions
enforce application capabilities. The browser never makes an authorization
decision.

Each Book has three deterministic, cluster-wide `NOLOGIN` capability roles:
RO, RW, and Admin. Book object privileges are installed on those roles once;
human roles receive exactly one corresponding membership. The control
catalogue trigger changes the catalogue row and cluster role membership in the
same PostgreSQL transaction, so a failed ACL mutation cannot leave a removed
person with stale Book privileges. The group roles own no objects and cannot
log in. PostgREST impersonation and direct SQL therefore inherit the same
capability without mutable per-user Book object grants.

`njord_control.global_administrators` is a separate installation-wide grant.
It controls whether Admin is advertised by `api.shell_page()` and whether the
global Admin API may be called. Owning or administering one or more Books does
not confer this grant. The configured first installation owner bootstraps the
grant; for example, GitHub login `elric1` receives PostgreSQL role `elric1`.

GitHub admission is invitation-only. The operational invitation command first
resolves the requested login through GitHub and records both its normalized
spelling and numeric id in `njord_control.github_invitations`; this prevents a
renamed or recycled login from accepting someone else's pending invitation.
The lower-level SQL function permits an unanchored invitation only for offline
development tests. An unknown verified GitHub user receives no principal,
role, session, or Book access. On first successful OAuth
callback, `njord_control.authenticate_github_identity` atomically consumes the
invitation, creates or binds the principal, and permanently maps the verified
numeric GitHub id. The resulting PostgreSQL role is provisioned as a constrained
human role and receives only its explicit control and Book grants. A recycled
GitHub login cannot take over an existing numeric identity mapping.

The same-origin gateway owns only the GitHub OAuth protocol: authorization-code
redirects, `state`, PKCE, the client secret, GitHub API verification, secure
cookie attributes, and signing a short-lived PostgREST role claim. It passes
verified identity facts into the private control SQL functions and may never
accept a role name supplied by the browser. OAuth credentials and raw GitHub
access tokens are not stored in the ledger or control database.

Browser sessions are SQL-owned control-plane state in
`njord_control.web_sessions`. The cookie is an opaque random bearer token;
only its lowercase SHA-256 hash is stored. Sessions have an absolute expiry of
at most 30 days, update their last-seen time on successful resolution, can be
revoked individually or for a complete principal, and stop resolving
immediately when their principal is disabled. The gateway resolves the hash to
one database role and then issues the short-lived claim consumed by PostgREST.
Logout revokes the server-side session before clearing the cookie. On HTTPS,
the host-only browser session cookie is `Secure`, `HttpOnly`, and
`SameSite=Strict`; the separately signed, ten-minute OAuth state cookie is
`SameSite=Lax` so GitHub's top-level callback can carry it.

## Database-Backed UI Contract

Every Book-local UI page must be represented by one canonical named PostgreSQL view or
table-returning function.  PostgreSQL views do not accept arguments, so in
this document a "parameterized view" means a function declared with `RETURNS
TABLE`.  Use an ordinary view when no runtime parameters are required.  A
persistent application surface such as the top navigation bar is treated as a
page for this purpose and has its own control-database view model. On a direct
or new-tab Book URL, Elm first loads `api.shell_page` from the control database
and then loads exactly one canonical page function from the Book database.
This two-database composition is navigation plumbing, not accounting logic;
Elm does not reconstruct either SQL model.

Unscoped pages belong only to the control database: `api.admin_page()` owns
installation-user administration and `api.add_book_page()` owns Book creation.
`sql/api.sql` must not install Book-local compatibility copies of either
function. Book-local `api.create_book()` remains solely because the physical
Book installer uses it before `sql/book-database.sql` seals the singleton
identity; browser creation routes to the control implementation.

The page function returns the complete model needed to render that page.  This
includes its tables, forms, menus, completion lists, report rows, computed
totals, editability state, and validation state.  For example,
`ledger_page(book_id, account_id)` currently returns both ledger rows and valid transfer
account choices.  Supporting views may be used inside the page function, but
the client must not call them separately and reconstruct the page itself.

When a page contains heterogeneous data, its function returns discriminated
component rows with stable component names, ordering keys, row identities, and
JSONB payloads.  This preserves a single relational page boundary without
forcing unrelated component types into one wide record.

The columns returned by these database objects are the application's view
model.  They should contain stable row identities, display values, ordering
keys, computed values, and any state needed to decide which edits are valid.
The same call made through `psql` must expose the same rows and meaning as the
web UI.

SQL also owns the presentation vocabulary attached to that structure. Every
user-visible field name, table heading, menu item, action label, option label,
placeholder, help message, validation message, empty-state message, and report
caption is returned by the canonical page function or a SQL presentation
catalogue used by it. Elm may contain stable semantic component and field keys
needed by its generic renderers, but it must not translate those keys into
English—or any other display language—with client-side string tables or
page-specific case expressions.

Internationalisation follows the same boundary. Translations are keyed by
stable semantic identifiers and stored in SQL; the page function resolves the
requested locale, applies an explicit fallback locale, and returns the final
display strings. Choice values, database identifiers, account identities, and
other stored facts remain stable and untranslated. Locale-specific formatting
rules may be returned as presentation metadata for a generic Elm formatter,
but the browser must not invent field names or accounting terminology. A
locale is offered to users only when the required presentation catalogue is
complete enough to avoid a silently mixed-language interface.

The concrete catalogue lives in `sql/presentation.sql` and is installed in
the control database and every Book database. `presentation.messages` keys
display strings by locale and stable semantic key; `presentation.locales`
records the explicit fallback and whether a locale is both enabled and
complete. Source vocabulary is written once per semantic key with the three
translations side by side, then unpivoted into `presentation.messages`; this
makes omissions and mismatched meanings visible without maintaining three
parallel dictionaries. `api.presentation_catalogue` returns the resolved vocabulary as
ordered `presentation` components with `{key, text, locale}` payloads. Every
canonical shell/page includes those components. The requested locale may be
supplied explicitly or through the request's `Accept-Language` header; SQL
normalises the request and falls back to `en-GB`. Elm performs only a direct
key lookup and placeholder substitution. A missing key is shown as its stable
semantic identifier so incomplete catalogue data is conspicuous and is never
silently replaced by embedded English.

Language is presently the only user preference. It is browser-local rather
than an accounting fact: the browser stores the explicit choice under one
`localStorage` key and sends its locale with canonical page requests so SQL can
resolve the presentation catalogue. Other tabs observe storage changes and
reload their current canonical page. There is no user-preferences table,
cookie, general Settings page, theme preference, or regional formatting model.

The top bar exposes one compact language button in its upper-right corner. Its
trigger and three menu choices are flags only: 🇬🇧 selects `en-GB`, 🇵🇦
selects `es-PA`, and 🇹🇼 selects `zh-TW`; SQL supplies their accessible names
and tooltips. On a browser with no saved choice, any Spanish browser language
maps to `es-PA`, any Chinese browser language maps to `zh-TW`, and all other
languages map to `en-GB`. This selection changes display language only. Stable
business identifiers remain untranslated, and date, number, currency, theme,
and density preferences are deliberately deferred.

Edits must be represented by PostgreSQL procedures or functions.  An edit
operation accepts the user's complete intent, performs all checks and related
writes atomically, and returns either the resulting view rows or a database
error.  Constraints remain the final protection even when a procedure is the
normal mutation path.

The UI owns only presentation and editing mechanics:

- layout, styling, accessibility, focus, selection, and transient form state;
- formatting database values for display;
- collecting an edit and sending it to the server;
- rendering rows and errors returned by PostgreSQL.

The UI must not own accounting arithmetic, account classification, balancing,
VAT treatment, report grouping, workflow state, or authoritative validation.
If an immediate preview is useful, such as a split imbalance or recoverable
VAT amount, the preview should be returned by a PostgreSQL function rather
than reimplemented in Elm.

## Application Navigation Contract

Book is persistent workspace context, not a dropdown or the first step in a
cascading selection sequence. Navigation has two modes. The unscoped Books
page shows `Books` plus `Admin` only when SQL says the current principal is a
global administrator; neither page has an active Book. After the user opens a
Book, the top row adds `Accounts, Journal, Reports`, and the active Book appears
as plain context in the header. There is no `Select book` control.

Each Book is one ordinary anchor whose complete card is clickable, so a left
click opens its Book-management detail in place and middle-click or
Ctrl/Cmd-click opens it in a browser tab. `Add book…` is a separate action on
the Books page, backed by the control database's `api.add_book_page()` model.

Admin is a global control-database page, never an active-Book page. Its
canonical `api.admin_page()` model lists the people admitted to the Njord
installation, their PostgreSQL roles, login state, Book count, and global-admin
status. Only a principal recorded in `njord_control.global_administrators`
sees the Admin tab or may call this API; Book-level Admin is deliberately
insufficient. The Admin page can admit a GitHub identity but does not display
or edit any Book.

Books owns Book administration. A Book card opens a detail that combines the
Book database's `api.book_page` component stream with the control database's
`api.book_acl_page` component stream; the same-origin gateway only concatenates
those SQL-owned models. On that detail, Books remains active and the
Book-scoped Accounts, Journal, and Reports destinations are available.

On a Book-management detail, the Book identifier is permanent. Its display
name and explicit owner/entity type
(`household`, `sole_trader`, `partnership`, `company`, and the other supplied
organisation types) are editable independently. A new book defaults to
`household`; PostgreSQL and Elm must never infer entity type or jurisdiction
from its name, currency, accounts, or available report packs. Currency merely
makes a pack technically available; only a real profile row activates that
pack and its reports. A deferred database constraint permits at most one base
jurisdiction profile per Book and locks the Book while profile changes are in
flight, so direct SQL and concurrent requests obey the same rule. An ordinary
GBP company book may be configured as a UK company by one complete mutation
that records its company identity, accounting framework, VAT scheme, first
accounting period, usable standard account hierarchy, and any required VAT
control account. PostgreSQL performs that transition atomically and returns
explicit hierarchy, profile, period, and VAT-control completion checks; the UI
must never construct a company profile piecemeal or infer that an incomplete
profile is ready. Enabling standard invoice VAT with
no selected control account creates or reuses a posting `VAT Control` liability
account in the same transaction. Non-GBP books cannot enter the supported UK
company envelope. The accounting-period identifier is a stable key: it is
chosen during initial setup and displayed read-only on subsequent edits.

Reporting currency has its own effective-dated history in
`book_reporting_currencies`. An empty book may replace its initial currency;
the standard accounts follow because no accounting history exists. After the
first transaction, a change adds a present or historical dated transition and never redenominates an
account or posting. An as-of report uses the currency effective on its as-of
date; a period report uses the currency effective at its end date. Missing
rates into that currency are SQL validation messages, not client-side guesses.

The Book-management detail also manages the Book ACL. Its three user-facing levels are `RO`, `RW`,
and `Admin`, backed by the control catalogue's `viewer`, `editor`, and `owner`
memberships and corresponding physical Book-database grants. Only Admin may
invite, change, or remove members. An administrator cannot demote or remove
their own access, and every Book must retain at least one Admin. GitHub login
is display and invitation input; the immutable GitHub numeric id remains the
external identity anchor.

Archiving is the normal reversible removal operation. Archived books remain
addressable from Books so an authorised Book administrator can restore them.
Permanent deletion is permitted only for an archived book and requires the
exact display name as confirmation. Book-local SQL atomically authorizes the
database identity, archive state, and name; the gateway then invokes the narrow
provisioner to drop the complete physical Book database and unregister it from
control. The retained Book-local `api.delete_book()` stub refuses direct SQL
deletion, and neither browser nor SQL performs piecemeal table deletes.

Accounts owns its account selector as contextual page navigation. The selector
is displayed inside an individual account register and chooses which account
register is open; it is not a global or top-navigation control. The Accounts
destination itself opens the canonical SQL-backed account index, which lists
every account in the active Book with its native-asset balance and posting
summary. Each account entry is a link to that account's register; Accounts never
silently jumps to the first or previously selected register. Reconciliation is
a secondary workflow inside Accounts, reached from its account index and
optionally filtered by Account; it is not a top-level destination and its
controls do not appear in the account register. Journal opens the General
Journal for the active Book and does not require an Account selection.

Reports opens an SQL-backed, grouped report library. Every book receives the
general financial reports: Balance Sheet, Net Worth, Trial Balance, Profit &
Loss, and Cash Flow. A configured UK company also receives UK statutory
accounts, HMRC, and supporting-schedule groups. The library selects a report
type; it does not collect that report's runtime arguments. Each actual report
page owns and renders its applicable parameters, such as an as-of date or date
range, using defaults and validation supplied by its canonical SQL page
function.

Primary destinations are ordinary same-origin anchors, not application-tab
buttons. Book cards, account-index entries, and the complete surface of each
report-library card are anchors as well. Normal left clicks are handled in place, while browser
middle-click and Ctrl/Cmd-click retain their native new-tab behaviour. Canonical
root query URLs encode the active Book and destination, plus the Account where
applicable; for example `/?page=admin`, `/?page=book&book=personal`, and
`/?page=ledger&book=personal&account=Current%20Account`.
Elm restores that route on startup and uses the same route loader for Back and
Forward navigation. Internal transaction identifiers and unsaved register state
are never placed in URLs. The static server treats a root query URL as the root
document, so direct loads require no server-side application routing.

## Ledger Interaction Contract

The account ledger must retain the register interaction rather than presenting
transactions through a generic form. Its columns are exactly, and in order:
Date, Description, Transfer, Deposit, Withdrawal, and Balance. Internal
transaction identifiers remain available for keyed rendering and mutation calls
but are never rendered as a column or user-facing label. A row click selects
the transaction and replaces its display cells with inline controls. The ledger
must not add an Actions column, a detached editor, or transaction-local Preview,
Save, Cancel, Split, Add split, or Remove buttons.

The interaction follows the GnuCash basic-ledger register:

- `Enter` records the complete active transaction. A successful mutation reloads
  canonical SQL data and folds an expanded transaction back to its compact row.
- `Tab` and `Shift+Tab` move between fields. An expanded transaction always ends
  in one blank split row; editing it materializes that posting and exposes a new
  blank row, so adding a posting never requires a button.
- `Select account` is only the initial value of an unassigned new transfer or
  blank split row. Once an account is selected, the empty option disappears;
  the posting may be changed to another real account but cannot be reset to an
  accountless state through its selector.
- Whenever the complete posting rows do not balance, PostgreSQL derives the
  exact reciprocal amount at ledger precision and Elm displays it, in muted
  styling, in the appropriate Deposit or Withdrawal field of that final row.
  The suggested row still has no account and is transient presentation state,
  not a posting. Selecting an account in the suggested asset promotes the
  suggestion into a real draft posting; selecting an account in another asset
  leaves its amount empty and keeps the original asset suggestion available.
  Overriding a promoted amount causes the new final row to show the newly
  calculated remainder. A balanced transaction retains an empty final row.
- Expanding a transaction shows every posting beneath its summary row, including
  the posting for the account whose ledger is open. Existing multi-split rows
  expand when selected; selecting `-- Split Transaction --` in a simple row's
  Transfer field performs the equivalent transition for new or two-line input.
- GnuCash 5.16 defines `Escape` as cancellation of the active field edit, not of
  the whole transaction. Njord therefore restores the value captured when that
  field received focus and leaves the rest of the inline transaction untouched.
- A successful `Enter` leaves no selected editor or action bar. A rejected write
  leaves the inline fields open with their input intact so the user can correct
  the database-reported error and press `Enter` again.

Register navigation must not replace the visible page with a loading state.
Moving between clean rows is a local selection change and makes no mutation or
page request. Moving away from a dirty row has explicit `saving` and
`refreshing` phases: the edited row and the complete register remain mounted
while the mutation and canonical `ledger_page` reload are pending. The table,
header, stable transaction-row identities, row count, document height, and both
scroll axes must survive those phases without a blank or loading-panel frame.
Only the editable controls are locked. Further row clicks merely retarget the
pending navigation, so one mutation and one canonical reload select the most
recent target rather than issuing duplicate writes. Once SQL data returns, Elm
patches the keyed rows in place and opens that target from canonical data.

Simple input is a candidate consisting of the selected account, transfer
account, and amount. PostgreSQL expands that intent into reciprocal posting
lines, normalizes it, and decides whether it is valid. Elm must not negate a
counterline or otherwise balance the transfer. The SQL-backed
`api.transaction_draft_balance` RPC is the sole source of balancing suggestions;
Elm only renders the returned asset and signed amount.

The permanent trailing row, its computed suggestion, and partially entered rows
without both an account and a non-zero amount are presentation state and are
omitted from mutation candidates. A malformed non-empty amount is not an
incomplete placeholder and remains a database validation error. Complete posting
data is sent unchanged. Current GnuCash offers rebalancing choices when the user
tries to leave an unbalanced transaction; Njord preserves its stricter,
buttonless analogue: PostgreSQL rejects an unbalanced transaction and
the register keeps the draft open for manual correction. It does not silently
create an `Imbalance-CUR` account. The preview RPC remains an API capability, but
it is not a transaction-local save step. New transaction entry lives in the
register footer and follows the same `Enter`-to-record contract.

This contract is based on the official GnuCash documentation for
[direct register entry](https://www.gnucash.org/docs/v5/C/gnucash-manual/trans-enter.html),
[multiple-split entry](https://www.gnucash.org/docs/v5/C/gnucash-manual/trans-multi-enter.html),
the [register toolbar and menu](https://www.gnucash.org/docs/v5/C/gnucash-manual/gui-acct-reg.html),
and the [expanded split layout](https://code.gnucash.org/docs/C/gnucash-guide/txns-registers1.html).
The GnuCash 5.16 source shows that the blank row's
[counteramount is computed without creating a posting](https://github.com/Gnucash/gnucash/blob/5.16/gnucash/register/ledger-core/split-register-model.c#L1733-L1832),
that tabbing through it
[promotes an edited split and creates another blank row](https://github.com/Gnucash/gnucash/blob/5.16/gnucash/register/ledger-core/split-register-control.cpp#L1780-L1824),
and that leaving an unbalanced transaction invokes
[explicit rebalance handling](https://github.com/Gnucash/gnucash/blob/5.16/gnucash/register/ledger-core/split-register-control.cpp#L89-L230).
The field-level Escape behavior is recorded in the official
[GnuCash 5.16 release notes](https://www.gnucash.org/news.phtml).

## Posting Reconciliation Contract

Reconciliation belongs to an individual posting, not to an entire transaction.
`unreconciled_postings` is a sparse marker table keyed by
`(book_id, xid, acct)`: marker presence means the posting is unreconciled and
marker absence means it is reconciled. Every newly inserted posting receives a
marker. The dedicated `reconciliation_page(book_id, account_id)` workspace shows
posting review data and may filter by account; `set_posting_reconciled` is the
only browser mutation for toggling the marker.

Changing a posting's account or amount reopens that posting. Editing only the
transaction date, transaction description, or posting memo preserves its
reconciliation state. `replace_transaction` snapshots reconciled postings and
restores reconciliation for replacements with the same logical
`(account, amount)` pair, even though the physical posting rows are deleted and
inserted again. Marker foreign keys cascade when their posting is deleted or its
natural key changes.

The account register has no reconciliation column or controls. The General
Journal may display posting-level reconciliation as a compact `R` indicator, but
neither it nor any other browser page renders internal transaction identifiers.

## HTTP Boundary

PostgREST exposes a dedicated `api` schema.  Base accounting tables and
internal helper views are not HTTP resources.  Parameterized page views and
mutations are PostgreSQL functions in the exposed schema and appear under
PostgREST's `/rpc` routes behind an explicit gateway control or Book route.
Ordinary views may be exposed only when they are a deliberate, parameterless
public resource.

A normal Book-page request should:

1. load the independently canonical control-database shell when catalogue
   context is not already present;
2. route the Book request to the database named by the authorized catalogue;
3. decode and type-check HTTP path, query, and body values;
4. call exactly one named PostgreSQL page function in that Book database; and
5. return its rows without another application-services layer.

Mutations use `POST` requests to PostgreSQL functions in the same schema.
PostgREST runs each request in a database transaction, returns PostgreSQL
errors to the client, and rolls the transaction back on failure.  Public HTTP
mutations must therefore be functions; direct-SQL procedures may remain as
conveniences for `psql` users.

PostgREST must not be supplemented by code that performs SQL-domain
arithmetic, chooses accounts, normalizes transaction descriptions, synthesizes
report rows, or enforces accounting rules.  Those behaviours belong in the
database so direct SQL, imports, the REST API, and future clients cannot
disagree.

During UI development every PostgREST adapter binds only to `127.0.0.1`.
The current small hosted deployment authenticates directly with GitHub OAuth
at the trusted same-origin gateway. The gateway signs the PostgREST role claim;
a client may not select an arbitrary role. PostgreSQL remains the authorization
boundary.

PostgREST does not serve the Elm application. A separate same-origin gateway
serves the compiled Elm assets and routes API requests to the control or
selected Book adapter. It also supervises on-demand local adapters, verifies
their database identity and schema version, and drains them on application
shutdown or Book deletion. For the operational exception, it sends a bounded,
validated request over a private Unix socket to the lifecycle broker. That
broker runs as the PostgreSQL OS user and can invoke only fixed Book
provisioning, deletion, unregistration, and role-grant programs after the
corresponding SQL state or authorization exists. The HTTP process cannot submit
a shell command, SQL string, executable path, or database endpoint. Neither
gateway nor broker contains accounting or report logic.

The supported appliance deployment packages PostgreSQL, PostgREST, the
gateway, and the compiled Elm assets in one Docker image. They remain separate
processes with the same boundaries described above; co-location is packaging,
not a merger of responsibilities. PostgreSQL is the only durable component and
stores the control database plus all Book databases in one mounted cluster
volume. The container entrypoint initializes an empty volume once, starts the
processes in dependency order, and forwards shutdown so HTTP and adapters drain
before PostgreSQL stops. PostgreSQL and the lifecycle broker run as OS user
`postgres`; the gateway and all PostgREST processes run as OS user `njord`,
whose local peer mapping permits only the database login
`njord_authenticator`. Public TLS termination remains outside the appliance.

## Schema Evolution and Recovery

The control database and every Book database have separate, append-only
`schema_migrations` ledgers. Each row records one contiguous integer version,
the immutable migration name, its SHA-256 checksum, and application time. The
Book's authenticated `api.adapter_status()` reads that durable version; the
gateway never substitutes an application constant for database state.

Version 1 is the first supported production baseline for both ledgers; there is
no supported production predecessor. Fresh loaders create that baseline only
in a newly created database and immediately enter the migration path. The
installer explicitly enables unversioned adoption for its own output, and the
runner accepts it only when the exact version-1 fingerprint is present. Normal
operator runs fail closed on an unversioned database; the adoption switch is a
controlled recovery/install operation, not a general migration strategy.
Thereafter the runner checks every historical name and checksum,
rejects gaps, empty/partial ledgers and versions newer than the binary, and
applies missing files in filename order. One migration's DDL and ledger insert
share one transaction under an advisory lock. Startup performs this process
before launching PostgREST; incompatible or incompletely provisioned state is
a startup error, never a degraded serving mode. Book capability grants are
recomputed after Book migrations so new API objects do not inherit ambient
privilege accidentally.

The supported recovery unit is the whole PostgreSQL cluster, not an isolated
table dump. A physical `pg_basebackup` captures global roles, control state,
all physical Book databases, and recovery WAL under one consistent PostgreSQL
backup manifest. The production wrapper streams that archive directly through
age encryption. Restore decrypts into private temporary storage, accepts only a
verified PostgreSQL 18 archive and a clean volume, and removes the temporary
plaintext. It never overwrites an existing cluster. Pre-upgrade encrypted
backups and clean-volume restores are the rollback boundary because committed
schema migrations are forward operations; switching back to an old image does
not undo them. The exact operator procedures live in
[OPERATIONS.md](OPERATIONS.md).

## External Components

Some capabilities do not belong naturally in PostgreSQL.  Invoice scanning,
OCR, file conversion, malware scanning, and similar work may be implemented as
server-side components.  They must not run as authoritative business logic in
the browser.

An external component should produce untrusted candidate data and write it to
a staging interface.  PostgreSQL then applies accounting policy, validates and
normalizes the candidate, and exposes the result through a view for review or
posting.  The component may extract text from an invoice; it must not decide
the final VAT treatment, expense account, tax allowability, or ledger posting.

The default design rule is simple: if PostgreSQL can express the behaviour
clearly and testably, implement it in SQL.  Move work outside PostgreSQL only
for a concrete capability or operational reason, and document that exception.

## Dependency Direction

Dependencies flow in one direction:

`Elm presentation -> same-origin router -> control/Book PostgREST -> PostgreSQL api schema -> base tables`

Neither Elm nor PostgREST is a second source of accounting truth.  A feature
is not complete until its SQL page function, SQL mutation path, database
constraints, and SQL tests exist.  REST tests verify transport fidelity, and
UI tests verify presentation and editing behaviour rather than accounting
correctness.

## Data Model

The control database contains:

- `njord_control.principals`, mapping immutable principal IDs to cluster-wide
  PostgreSQL user roles;
- `njord_control.global_administrators`, granting installation-wide Admin
  independently of all Book memberships;
- `njord_control.github_invitations`, recording invitation-only admission by
  normalized initial GitHub login;
- `njord_control.principal_identities`, mapping a verified immutable numeric
  GitHub id to one principal while retaining the latest observed login;
- `njord_control.web_sessions`, storing revocable expiries and SHA-256 hashes
  of opaque browser-session tokens;
- `njord_control.books`, mapping stable Book handles to physical database
  names and navigation metadata;
- `njord_control.book_memberships`, recording owner/editor/viewer access; and
- small initial-denomination and entity-type catalogues used by Book creation.

Each Book database is centered on one double-entry ledger:

- `asset` stores currencies, metals, securities, or other units of account.
- `valuations` stores dated exchange or valuation rates between assets.
- `acct_types` stores the standard account classes:
  assets, liabilities, expenses, income, and equity.
- `account_kinds` describes an account's operational role independently of its
  financial-statement class.
- `book_entity_types` defines explicit user-selected household and organisation
  classifications without embedding jurisdiction rules.
- `books` contains the one Book's settings, current reporting-currency cache,
  explicit entity type, and reversible archive timestamp. The plural name and
  `book_id` keys support explicit relational ownership and portable exports;
  the singleton guard makes them incapable of representing another ledger in
  this database.
- `book_reporting_currencies` stores the effective-dated denomination used by
  dated reports; it does not alter account commodities or postings.
- `accts` stores hierarchical named accounts and the asset each account is
  denominated in. Each account belongs to this database's one class tree.
- `account_valuations` stores dated total valuations for unique physical assets
  represented by particular accounts.
- `cash_accounts` marks which asset accounts are cash or cash equivalents for
  Cash Flow reporting.
- `uk_company_profiles` opts a book into the UK preparation pack and records
  its legal identity, framework, and VAT scheme.
- `uk_accounting_periods` supplies explicit, non-overlapping company periods
  and their preparation status and deadlines.
- `uk_account_statutory_mappings`,
  `uk_account_corporation_tax_mappings`, and `uk_account_vat_mappings`
  classify posting accounts independently for each reporting purpose.
- `uk_company_control_accounts` identifies the VAT control ledger account used
  to reconcile mapped return activity and the closing control balance.
- `panama_business_profiles` and `panama_fiscal_periods` opt a PAB/USD book into
  the simple Panama business working-paper pack and record its bookkeeping
  identity and explicit periods.
- `panama_account_income_tax_mappings`, `panama_account_itbms_mappings`, and
  `panama_reportable_payments` add review classifications while retaining
  ledger postings as the authoritative amounts.
- `panama_residential_property_profiles`, `panama_properties`, units, tenants,
  leases, tax assessments, and instalments are an optional property-management
  extension rather than part of every Panama book.
- `taiwan_business_profiles`, fiscal and business-tax periods, uniform
  invoices, withholding payments, and explicit account mappings opt a TWD book
  into the Taiwan business working-paper pack.
- `taiwan_manufacturing_profiles`, stock items and movements, BOMs, production
  runs, run/posting links, machines, and moulds are the optional injection-
  moulding extension. Ledger postings remain authoritative for money.
- `trade_parties`, `trade_invoices`, and `trade_invoice_allocations` add invoice
  identity, due dates, and allocations while keeping the referenced ledger
  postings authoritative for amounts.
- `xactions` stores transaction headers within a book.
- `xaction_bits` stores transaction lines, each attached to one account.
- `vendors`, `business_expenses`, and `business_expense_lines` attach vendor,
  invoice, receipt, net/VAT/gross, and business-use facts to normal ledger
  transactions and lines.
- `unreconciled_postings` sparsely marks individual postings that have not been
  reconciled.

Reports are dated SQL functions over those base tables. Balance Sheet, Net
Worth, Trial Balance, Profit & Loss, and Cash Flow each have one canonical
book-scoped function; there is no second undated or GBP-only implementation to
drift from it. General Journal remains a view because it has no report date.

### Database-defined report presentation

Financial reports use one generic page contract. PostgreSQL defines both the
accounting result and most of its presentation:

- `report_catalog` defines each report's identifier, title, description,
  group, ordering, profile eligibility, and whether it accepts an as-of date
  or a date range;
- `report_columns` defines column order, labels, alignment, value format, and
  which column renders as a tree;
- report functions produce the accounting rows, including `row_kind`, `depth`,
  stable account identity, and a normalized array of cells; and
- `report_bar_charts` plus normalized chart points define optional
  single-series bar charts.

`api.report_page` combines those SQL definitions into `report_definition`,
`report_column`, `generic_report_row`, `bar_chart_definition`, and
`bar_chart_point` components. Elm has one renderer for every tabular report and
one renderer for every single-series bar chart. It does not contain a Balance
Sheet, Net Worth, or Profit & Loss column layout. Adding another tabular report
therefore requires SQL catalogue/column/data definitions but no Elm change;
adding another bar chart uses the same chart component contract.

Report-library membership is data, not Elm policy. `core_report_catalog`,
`uk_report_catalog`, `panama_report_catalog`, and `taiwan_report_catalog` are
composed into the public catalogue; their column and chart views follow the same pattern.
The packs' accounting and fiscal periods are likewise normalized once in
`report_periods`. `njord.report_default_period` selects one complete row by a
shared policy: a period containing the reference date, otherwise the latest
past period, otherwise the nearest future period. `api.report_page` consumes
that row once; ordinary reports retain calendar-year/current-date defaults.
`api.shell_page` asks PostgreSQL whether the active book has the required
profile. Personal books see the universal reports, while explicit UK, Panama
business, Panama residential-property, Taiwan business, and Taiwan
manufacturing profiles enable their respective groups. Elm groups the supplied cards by `report_group`; it has no jurisdiction
list, filing rules, rates, thresholds, or report-specific table definitions.

Currency conversion is likewise shared policy. `njord.reporting_rate`
selects the Book's effective-dated reporting currency and the latest available
unit rate at the posting date. Jurisdiction packs must use that helper instead
of copying conversion SQL or reading the Book's current currency, because a
later currency change must not rewrite historical reports.

For statement-shaped reports, SQL emits parent group rows, posting-account
rows, section totals, and grand totals in preorder. `tree_column` tells Elm
where to apply the SQL-supplied `depth`, at a visually significant 2.5 rem per
level. Balance Sheet, Net Worth, and Profit & Loss share this hierarchy. Net
Worth additionally supplies twelve chronological month-end snapshots ending
at the selected as-of date for its generic “Net Worth over time” bar chart.

## Account Hierarchy and Asset Valuation

Account classification and account placement are related but distinct facts.
`accts.type` is the financial-statement class (`A`, `L`, `E`, `I`, or `Q`),
while `accts.parent_id` is the immediate parent in the book's account tree. A
normal book created through the application has one placeholder root for each
class, and every non-root account must have a parent of the same class.
Consequently every ordinary `E` account really is a descendant of the Expenses
root, including through intermediate groups, but the letter `E` is not
overloaded as a parent identifier. Low-level callers may deliberately create an
empty book without standard roots; no accounts can be added beneath a missing
class root until that root exists.

The hierarchy has these database-enforced properties:

- parent references are scoped to the same book;
- each class has at most one parentless `root` account per book, while normal
  application-created books supply all five;
- root accounts are placeholders and cannot receive postings;
- a non-root account must have a parent, and parent and child classes match;
- account kinds with a required class must use that class: `bank`, `cash`,
  `fixed_asset`, and `investment` are assets, while `loan` and
  `director_loan` are liabilities;
- cycles and self-parenting are rejected;
- sibling display names are unique, so a colon-delimited full path is
  unambiguous; and
- an account with existing postings cannot be converted to a placeholder.

`accts.id` remains the stable, book-scoped identifier used by postings and
URLs. `accts.name` is the visible leaf name and defaults to `id` for callers
that omit it. Moving an account changes only `parent_id`; renaming the visible
leaf does not rewrite transaction references. The Accounts page should render
this structure as an expandable tree. A placeholder row displays its descendant
subtotal, while only non-placeholder accounts open posting registers.

### A house and its mortgage

A particular house is not modelled as one fungible unit of a `HOUSE`
commodity. Its ledger account is denominated in money and carries its book
cost, while the related debt remains a separate liability:

```text
Assets (A, root, placeholder)
  Fixed Assets (A, group, placeholder)
    12 Acacia Avenue (A, fixed_asset, GBP)

Liabilities (L, root, placeholder)
  Mortgages (L, group, placeholder)
    12 Acacia Avenue Mortgage (L, loan, GBP)
```

For a GBP 300,000 purchase funded by GBP 60,000 cash and a GBP 240,000
mortgage, the balanced purchase transaction posts `+300000` to the house,
`-60000` to the bank, and `-240000` to the mortgage liability. Capitalised
improvements may subsequently post to the house account. The ledger balance is
therefore the historical book value; an estate-agent estimate must not silently
rewrite it.

`account_valuations` records that independent observation, for example the
total value of `12 Acacia Avenue` as GBP 425,000 on a given date. It is keyed by
book, account, timestamp, and destination asset. A valuation-aware net-worth
view may select the latest observation at or before its report date, while
ordinary accounting reports continue to use posted book value. Recording a
formal accounting revaluation still requires a balanced transaction.

Commodity holdings use the existing, different mechanism. A gold account is
denominated in `XAU`, a silver account in `XAG`, and a share account in its
security asset identifier; posting amounts are quantities of that commodity.
`valuations` stores dated *unit rates*, such as one XAU in GBP or one share in
GBP, and reports multiply the account quantity by the applicable rate. These
rates apply to every holding of the source commodity. They do not belong in
`account_valuations`, whose rows are total observations for one unique account.
Commodity conversion also does not weaken transaction integrity: acquisitions
must still supply balanced posting lines in each asset used by the transaction.

## Product SQL and Example Data

`sql/control.sql` loads the production control database and `sql/njord.sql`
loads the production schema inside a Book database. `sql/book-database.sql`
then fixes that Book's immutable physical identity and installs clean
Book-local direct-SQL surfaces. Every file beneath `sql/` is part of the
finished product: control data, core schema/reference data, generic reports,
the UK pack, the Panama pack, the Taiwan pack, mutations, and API contracts.

The `examples/book-*.sql` loaders each add one illustrative Book to its own
database. `examples/njord-demo.sql` remains an intentionally all-in-one
compatibility fixture solely for the broad regression suite; production and
normal development installation never depend on it or on demo transactions.
Its separately named `examples/all-in-one-api-compat.sql` installs the two
unscoped page shims needed by that legacy browser fixture; those shims are not
part of the Book product loader.

`schema.sql` remains jurisdiction-neutral. Each jurisdiction file owns its
tables, reference data, mappings, validators, triggers, report catalogues,
columns, and normalized report-row functions. The API composes these SQL
contracts. This keeps new tabular reports database-defined and prevents Elm
from acquiring jurisdiction or accounting policy.

## SQL Is The Authority

All accounting invariants should be enforced inside PostgreSQL by schema
constraints, foreign keys, triggers, deferred constraint triggers, domains,
and stored procedures.  A user interface may make data entry pleasant, but it
must not be required for correctness.

The goal is that direct SQL use, batch imports, and any future UI all share
the same safety properties.

## Accounting Constraints

The database should enforce these accounting rules:

- Every transaction line must reference an existing account.
- Every account must reference an existing account type and asset.
- Every account must belong to exactly one book.
- A transaction line must reference an account in the same book as its
  transaction.
- A transaction may contain a given account only once.  If two split lines
  would use the same account, they should be combined before insertion.
- A cash-flow cash account must be a non-placeholder asset account.
- Every transaction must contain at least two non-zero, finite posting lines.
- Every transaction must balance independently in each asset.
- One-sided import candidates remain in staging and create no accounting rows.
- Amounts and valuation rates use finite, exact numeric types rather than
  floating point types; transaction-line amounts must also be non-zero.
- Duplicate reference data should be prevented where it would change report
  meaning, such as duplicate valuations for the same date/source/destination.

Transaction completeness and balance are enforced by deferred constraint
triggers. A transaction's lines must sum to zero per book and per asset; there
is no incomplete or unbalanced accounting-row state.

The deferred trigger allows all lines of a transaction to be inserted or
changed inside one database transaction before the balance check runs.

## Mutation Path

Data changes should be made through SQL functions or procedures where that
improves ergonomics:

- account opening procedures create the account and opening balance entry;
- transaction procedures create split or simple transactions;
- import procedures retain one-sided candidates in staging until they can be
  classified into complete, balanced transactions;
- reconciliation procedures mark individual posted lines as reviewed without
  changing accounting validity.

PostgREST mutation endpoints are functions because PostgREST exposes functions
through `/rpc`, not PostgreSQL procedures.  Procedures may remain as
convenience APIs for direct SQL use.  Neither is a substitute for constraints;
direct table manipulation by an experienced SQL user should still be protected
by database constraints.

HTTP mutation functions take a `book_id` route guard, which must equal
`njord.database_book_id()`. Book-local direct-SQL views and
procedure overloads omit it because the connection already selected the Book.
New Book-local APIs should not introduce another redundant tenancy argument.

## UK Company Preparation Pack

The first supported company envelope is deliberately narrow: a standalone UK
private company limited by shares, eligible for the FRS 105 micro-entities
regime, reporting in GBP, using ordinary accrual accounting and the standard
VAT invoice scheme. The profile tables can represent other legal forms,
frameworks, and VAT schemes, but a report must return a conspicuous unsupported
configuration blocker rather than manufacture plausible figures outside the
implemented envelope.

The reporting model has three conceptually separate layers:

1. The double-entry ledger remains the sole source of posted amounts.
2. Explicit statutory, Corporation Tax, and VAT mappings classify those
   amounts for a particular reporting purpose. Account names, hierarchy, and
   the broad `A/L/Q/I/E` classes are never sufficient substitutes.
3. A future filing layer will freeze an approved period and produce immutable
   filing artefacts. That layer is not yet implemented, so all current company
   outputs are preparation working papers.

### Company identity and periods

`uk_company_profiles` is a one-to-one extension of `books`. Row presence opts
the book into the UK report library; it is not an assertion that the book is
complete or filing-ready. The profile records the legal name, company number,
legal form, accounting framework, UTR, VAT registration and scheme, registered
office, and incorporation date. The reporting asset must be GBP.

`uk_accounting_periods` records named accounts periods with status and relevant
dates. Periods for one book may not overlap. UK report defaults are selected
from these explicit periods rather than assuming a calendar year. A statutory
accounts period and a Corporation Tax accounting period are not always the
same thing; periods longer than twelve months will eventually require separate
CT computations. Until that split is modelled, such a configuration must be
reported as unsupported.

### Independent classifications

`uk_statutory_lines` is an extensible statement taxonomy. Each posting account
used by the period maps explicitly to one compatible statutory line. Computed
headings such as gross profit, net current assets, and shareholders' funds
cannot receive account mappings; SQL derives them from their component lines.
The chart-of-accounts hierarchy remains a navigation and management-reporting
structure and may differ from statutory presentation.

Corporation Tax mappings distinguish taxable income, allowable expenditure,
disallowable expenditure, non-taxable amounts, capital-allowance pools, and
manual work still required. The accounts P&L is the starting point, not the tax
answer. The computation working paper shows its mapping basis and must expose
unmapped activity. It does not yet implement effective-dated rates, marginal
relief, losses, group relief, chargeable gains, R&D relief, close-company loan
charges, CT600 XML, or submission.

VAT mappings are separately role-qualified as sales or purchases and carry the
return-box behaviour, tax rate, and recovery fraction. The VAT Return Working
Paper and VAT Detail reports are supported only for standard invoice accounting. Missing
mappings and unsupported schemes fail closed. The reports are a nine-box
working-paper calculation and audit trail. Signed mapped postings preserve
credit notes and refunds, and the return shows the mapped VAT-control movement,
difference from boxes 1 plus 2 less 4, and closing control balance. The selected
dates still use transaction dates: VAT obligations, tax-point adjustments,
frozen returns, MTD submission, and HMRC acknowledgements are not modelled, so
the page always tells the preparer to review those boundaries.

### Invoices and schedules

Aged debtors and creditors cannot be inferred honestly from account balances
alone. `trade_invoices` therefore associates invoice number, party, issue date,
due date, direction, and control account with a real receivable or payable
posting. `trade_invoice_allocations` associates a payment's real control-account
posting with an invoice. It stores only the positive allocated portion; the
ledger remains authoritative for both invoice and payment amounts. Constraints
enforce customer/supplier roles, posting direction, control-account class,
payment sign, and protection against over-allocation.

The supporting pack includes VAT detail, account-level fixed-asset movement,
explicitly classified director-loan movement, and aged debtor and creditor
schedules. The fixed-asset output is a ledger schedule, not a full asset
register with per-item depreciation methods. A market observation in
`account_valuations` may accompany a fixed-asset row, but it is not depreciation
or a capital allowance and never replaces its posted book value.

### Preparation versus filing

The statutory P&L, statutory Balance Sheet, statement of changes in equity, and
notes checklist are useful accounts-preparation surfaces. They are not a full
set of Companies Act accounts: narrative disclosures, eligibility evidence,
comparatives, director approval/signature, audit-exemption statements, document
pagination, taxonomy tagging, validation, and an immutable approved snapshot
remain required. Any `uk_ixbrl_facts` surface is a semantic export for a future
tagger, not an iXBRL document.

Direct filing is out of scope until Njord can generate and validate the
required iXBRL/accounts and CT600 artefacts, submit them through supported
software interfaces, retain acknowledgements, and handle amendments. The same
principle applies to VAT MTD. Relevant primary guidance includes the
[Companies House annual accounts requirements](https://www.gov.uk/annual-accounts),
[FRC FRS 105](https://www.frc.org.uk/library/standards-codes-policy/accounting-and-reporting/uk-accounting-standards/frs-105/),
[HMRC Company Tax Return obligations](https://www.gov.uk/guidance/company-tax-return-obligations),
and [HMRC VAT Return box guidance](https://www.gov.uk/guidance/how-to-fill-in-and-submit-your-vat-return-vat-notice-70012).

## Panama Business and Residential-Property Pack

The Panama pack is intentionally an accounting package extension, not a tax or
legal expert system. A generic business profile comes first. It records the
book's legal identity, RUC/DV, legal form, municipality, fiscal periods,
selected registrations, control accounts, third parties, reportable payments,
and dividend distributions. Explicit account mappings classify income-tax and
ITBMS working-paper activity without guessing from account names.

The optional residential-property profile adds only the operational facts
needed to keep useful books: properties, units, tenants, leases, deposit and
registration dates, property-tax assessments and instalments, and explicit
repair-versus-capital mappings. Land, building, capital improvements,
accumulated depreciation, rent, repairs, and the mortgage remain separate
ledger accounts. Properties are money-denominated fixed assets; a current
property estimate belongs in `account_valuations` and never rewrites book cost.

Lease tax treatment is stored explicitly. The database validates internally
consistent facts—for example, a lease marked with the pack's long-term
residential exemption must actually exceed the configured duration—but it does
not decide whether a particular contract legally qualifies. Likewise,
effective-dated rows in `panama_tax_policies` are editable reference prompts,
not an obligations or tax-calculation engine. Due dates, thresholds, rates,
registrations, exemptions, and filing applicability always require review.

The generic business working papers cover income-tax mapping, Form 20
third-party payments, Form 43 threshold review, dividend distributions,
compliance dates, and ITBMS mapping. The property extension adds Rent Roll,
Property Profit & Loss, Property Tax Schedule, and Repair/Capital Review. All
ten use the same normalized SQL report contract as core and UK reports. They
prepare ledger-backed schedules for an accountant or adviser; they do not
produce returns, legal conclusions, or filing submissions.

`api.configure_panama_business` atomically creates or repairs the standard
five-root chart, stores the generic profile and first fiscal period, and may opt
the book into the residential-property extension. SQL owns eligibility,
validation, and report gating. The same mutation may disable an empty property
extension; foreign-key-protected property or tenant records must be removed
explicitly first, so disabling never cascades away evidence. Elm merely displays database components,
collects temporary form text, and sends the mutation payload.

## Taiwan Business and Injection-Moulding Pack

The Taiwan pack has a small generic-business core and an optional manufacturing
extension. The core records legal identity and Unified Business Number, an
explicit fiscal period, business-tax periods, ledger-linked uniform invoices,
withholding-payment evidence, trade invoices, and separate account mappings for
business tax and profit-seeking-enterprise income-tax review. Business-tax rates
live on explicit SQL treatment rows. Income-tax treatments classify ledger facts,
but deliberately stop before a final tax calculation; neither names nor Elm code
infer tax treatment.

The manufacturing extension adds inventory items for raw material,
consumables, WIP, finished goods, and scrap; BOM revisions and quantities;
machines, moulds, and auxiliary equipment; production runs with good and reject
quantities; stock movements; and links from each run to its authoritative
material, labour, overhead, and completion postings. A stock movement must have
the correct sign for its movement kind and reference a same-book ledger
posting. Financial value always comes from the ledger; production tables carry
the operational quantities and identities needed to explain it.

Taiwan account display names, report titles, descriptions, groups, columns,
validation messages, and textual report cells use Traditional Chinese (Taiwan).
Stable account IDs, report IDs, classification keys, and SQL joins remain
language-neutral implementation keys. The six business reports cover the 401
business-tax working paper, uniform invoices, profit-seeking-enterprise income
tax, withholding payments, the review calendar, and receivables/payables
ageing. The six manufacturing reports cover inventory rollforward, direct
material usage, production and unit cost, production yield, product margin, and
the machine/mould register. All twelve use `taiwan_report_catalog`,
`taiwan_report_columns`, and normalized `taiwan_report_rows`; Elm's existing
generic report renderer has no report-specific branch.

`api.configure_taiwan_business` creates or repairs the five standard account
roots, stores the business profile and first period, and may enable the
manufacturing records. It may disable that extension only before inventory,
equipment, production, or mapping records exist; it never cascades them away.
It does not invent a chart below those roots, inventory
items, BOMs, registrations, deadlines, tax classifications, or filing figures.
The reports are accounting and preparation working papers, not Forms 401,
income-tax returns, electronic cost schedules, or legal conclusions.

This data shape follows Taiwan's official bookkeeping expectations for
manufacturers—including raw-material, WIP, finished-goods, and production
records—and supports the official electronic cost-schedule concepts without
claiming to file them. Applicability and dates require professional review. See
the Taiwan Ministry of Finance guidance on
[manufacturer books](https://www.etax.nat.gov.tw/etwmain/tax-info/understanding/tax-q-and-a/national/profit-seeking-enterprise-income-tax/imputation-credit-account/PpnrP3M),
[business-tax filing](https://www.etax.nat.gov.tw/etwmain/tax-info/understanding/tax-q-and-a/national/business-tax/collection-prcedure/oVL9pwM), and
[electronic cost schedules](https://www.etax.nat.gov.tw/etwmain/etw212w/detail/5642184411389475240),
plus the Ministry of Economic Affairs
[Business Entity Accounting Act](https://law.moea.gov.tw/EngLawContent.aspx?id=10263&lan=E&media=print).

## Business Expense Metadata

Business expenses are not a second ledger. They annotate ordinary `xactions`
and `xaction_bits`; postings remain the accounting source of truth. Generic
metadata records vendor, invoice, business purpose, receipt, business-use
fraction, and factual net, VAT, and gross amounts.

Tax meaning is jurisdiction-owned. A pack may classify those postings through
its own explicit mappings, rates, and validators, but the generic expense
tables do not guess VAT recovery or income-tax treatment.

## Reporting

Reports should remain SQL-native:

- views for current state;
- table-returning SQL functions for parameterized reports;
- audit views for posting reconciliation and data-quality checks;
- valuation-aware views for assets held in non-reporting currencies.

Historical reports should use valuations as of the report date, not simply the
latest valuation available today.

Balance Sheet and Net Worth are intentionally different reports. Balance Sheet
uses posted accounting values and includes accounting equity. Net Worth uses
the latest eligible `account_valuations` estimate for each unique fixed asset,
the latest eligible `valuations` unit rate for commodity holdings, and posted
outstanding liability balances. It reports `market assets - liabilities`, shows
the source and date of each market observation, and flags missing estimates or
rates. Neither report writes revaluations back into the ledger.

Date-valued UI parameters are calendar-day boundaries.  An `as_of` or `to`
date includes postings throughout that final day even though transaction
storage uses timestamps.  Period page contexts return authoritative range,
cash-account configuration, and missing-valuation messages.  The browser
renders those messages; it does not infer whether a report is complete.

The account ledger/register is account-perspective reporting: it may show
transfer accounts, deposit/withdrawal columns, and a running account balance.
The General Journal is transaction-perspective reporting: it shows every line
of each transaction with debit and credit columns and no running balance.
Transaction descriptions belong to `xactions.comment`; line memos belong to
`xaction_bits.comment`.  Simple two-line transactions should not duplicate the
transaction description onto their component lines.

The Trial Balance is the double-entry sanity report.  It presents every
account balance as either a debit or a credit and includes a total row; those
totals should match when posted data is structurally balanced.  A difference
row indicates ledger data that needs audit or stronger SQL constraints.

Cash Flow reports use explicit `cash_accounts` rows to identify cash and
cash-equivalent accounts.  Cash movements are classified by the non-cash side
of each transaction: income and expense accounts are operating activities,
asset accounts are investing activities, and liability or equity accounts are
financing activities.
