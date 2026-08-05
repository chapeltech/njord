# TODO

The only active project is replacing the custom Servant server with a
localhost PostgREST API for the simple personal-accounting UI.  Business
expense, VAT, invoice, import, and other company-accounting work is outside
this migration.  Existing SQL support for those areas remains in place.

1. [x] Restore a green baseline.
   Complete the interrupted SQL loader work and make the existing SQL and API
   tests pass before changing transport behaviour.

2. [x] Enforce the core ledger invariants in PostgreSQL.
   Add deferred resolved-transaction balance enforcement, require incomplete
   imports to remain unresolved, and test both direct SQL and function-based
   writes.

3. [x] Create the PostgREST `api` schema.
   Add one canonical table-returning page function for the application shell,
   account ledger, General Journal, Balance Sheet, Trial Balance, income and
   expense report, add-book page, and add-account page.  Each function must
   return the complete page model in one call.

4. [x] Create the SQL mutation API.
   Add functions for creating books and accounts, creating and replacing
   transactions, updating ledger lines, and previewing split transactions.
   Keep accounting validation and description/memo normalization in SQL.

5. [x] Run PostgREST locally.
   Add a checked-in development configuration and launcher that expose only
   the `api` schema and bind PostgREST to `127.0.0.1`.

6. [x] Convert Elm one page at a time.
   Replace existing REST requests with PostgREST `/rpc` calls, starting with
   the shell and ledger.  Remove accounting calculations, account-choice
   filtering, and authoritative validation from Elm as their SQL equivalents
   become available.

7. [x] Remove Servant.
   After endpoint parity, remove the custom Haskell server and its Cabal
   dependencies.  Serve the compiled Elm files with a small localhost static
   server that proxies API requests to PostgREST.

8. [x] Verify the boundary.
   Use SQL tests for accounting behaviour, PostgREST smoke tests for page and
   mutation functions, and an Elm build plus browser smoke test for
   presentation and editing behaviour.
