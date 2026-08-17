-- Install after the one intended book has been created in a book database.
-- It seals the relational schema to the Book whose stable handle is the
-- database name. p_book_id parameters remain explicit route/integrity guards;
-- they never select another ledger.

CREATE OR REPLACE FUNCTION njord.enforce_book_handle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.id IS DISTINCT FROM current_database() THEN
        RAISE EXCEPTION 'book % does not belong in database %', NEW.id, current_database()
            USING ERRCODE = 'P0001', DETAIL = 'WRONG_BOOK_DATABASE';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION njord.keep_book_identity()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'drop the physical database to delete its Book'
	USING ERRCODE = '23514', CONSTRAINT = 'book_database_requires_book';
END;
$$;

DO $$
BEGIN
    IF (SELECT count(*) FROM public.books) <> 1
       OR NOT EXISTS (
	SELECT 1 FROM public.books WHERE id = current_database()
       ) THEN
	RAISE EXCEPTION 'book database % requires its one Book to have the same handle',
	    current_database()
	    USING ERRCODE = 'P0001', DETAIL = 'BOOK_DATABASE_NOT_SINGLETON';
    END IF;
END;
$$;

CREATE TRIGGER books_enforce_database_identity
    BEFORE INSERT OR UPDATE OF id ON public.books
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_book_handle();

CREATE TRIGGER books_keep_database_identity
    BEFORE DELETE ON public.books
    FOR EACH ROW EXECUTE FUNCTION njord.keep_book_identity();

CREATE OR REPLACE FUNCTION njord.database_book_id()
RETURNS VARCHAR
LANGUAGE SQL
STABLE
AS $$
    SELECT current_database()::VARCHAR;
$$;

-- The gateway checks this through the caller's ordinary Book role before it
-- sends the first accounting request to an adapter.  The database identity
-- prevents a stale or misconfigured route from crossing Book boundaries;
-- bump schema_version whenever the Book HTTP contract becomes incompatible.
CREATE OR REPLACE FUNCTION api.adapter_status()
RETURNS TABLE (database NAME, schema_version INTEGER)
LANGUAGE SQL
STABLE
AS $$
    SELECT current_database(), 1;
$$;

-- Clean book-local read names for direct SQL. Underlying tables retain the
-- invariant book_id for relational ownership and portable exports; these views
-- expose the natural per-database shape without repeating it.
CREATE OR REPLACE VIEW book_settings AS
SELECT name, reporting_asset, entity_type, archived_at
FROM public.books;

CREATE OR REPLACE VIEW accounts AS
SELECT
    id, name, type AS account_type, atype AS asset, parent_id, account_kind,
    placeholder, pretax AS pretax_factor, comment
FROM public.accts;

CREATE OR REPLACE VIEW transactions AS
SELECT xid AS id, date, comment
FROM public.xactions;

CREATE OR REPLACE VIEW postings AS
SELECT id, xid AS transaction_id, acct AS account, amt AS amount, comment
FROM public.xaction_bits;

-- RW is an accounting-editor capability, not blanket ownership of every
-- public table. New tables are read-only until deliberately classified here;
-- Book identity, lifecycle, account structure, pack profiles, periods,
-- policies, mappings, and control accounts remain Admin-only. Accounts have
-- a narrower column-level profile in set-book-access.sql.
CREATE OR REPLACE VIEW njord.rw_table_catalog (table_name) AS VALUES
    ('account_valuations'::NAME),
    ('cash_accounts'),
    ('valuations'),
    ('xactions'),
    ('xaction_bits'),
    ('unreconciled_postings'),
    ('trade_parties'),
    ('trade_invoices'),
    ('trade_invoice_allocations'),
    ('vendors'),
    ('business_expenses'),
    ('business_expense_lines'),
    ('panama_estimated_tax_installments'),
    ('panama_third_parties'),
    ('panama_reportable_payments'),
    ('panama_dividend_distributions'),
    ('panama_properties'),
    ('panama_property_units'),
    ('panama_tenants'),
    ('panama_leases'),
    ('panama_property_tax_assessments'),
    ('panama_property_tax_installments'),
    ('taiwan_uniform_invoices'),
    ('taiwan_withholding_payments'),
    ('taiwan_inventory_items'),
    ('taiwan_boms'),
    ('taiwan_bom_lines'),
    ('taiwan_equipment_assets'),
    ('taiwan_production_runs'),
    ('taiwan_inventory_movements'),
    ('taiwan_production_run_transactions');

CREATE OR REPLACE FUNCTION ledger(account_id VARCHAR)
RETURNS TABLE (
    date DATE,
    transaction_id INTEGER,
    amount NUMERIC,
    description VARCHAR
)
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM public.ledger(njord.database_book_id(), account_id);
$$;

CREATE OR REPLACE PROCEDURE create_simple_xaction(
    transaction_date TIMESTAMP,
    source_account VARCHAR,
    destination_account VARCHAR,
    amount NUMERIC
)
LANGUAGE SQL
AS $$
    CALL public.create_simple_xaction(
        njord.database_book_id(), transaction_date,
        source_account, destination_account, amount
    );
$$;

CREATE OR REPLACE PROCEDURE open_account(
    account_id VARCHAR,
    opening_date TIMESTAMP,
    account_type VARCHAR,
    asset VARCHAR,
    opening_balance NUMERIC
)
LANGUAGE SQL
AS $$
    CALL public.open_account(
        njord.database_book_id(), account_id, opening_date,
        account_type, asset, opening_balance
    );
$$;

-- Dropping a database is necessarily a cluster operation. The web gateway
-- calls this book-local authorization function first, then invokes the
-- narrowly scoped external deletion script against the control catalogue.
CREATE OR REPLACE FUNCTION api.authorize_book_database_deletion(
    p_book_id VARCHAR,
    p_confirm_name VARCHAR
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    target_name VARCHAR;
    target_archived_at TIMESTAMPTZ;
BEGIN
    IF p_book_id IS DISTINCT FROM njord.database_book_id() THEN
        RAISE EXCEPTION 'book does not belong to this database'
            USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    SELECT name, archived_at INTO target_name, target_archived_at
    FROM public.books
    WHERE id = p_book_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'book does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;
    IF target_archived_at IS NULL THEN
        RAISE EXCEPTION 'archive the book before deleting it'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_NOT_ARCHIVED';
    END IF;
    IF p_confirm_name IS DISTINCT FROM target_name THEN
        RAISE EXCEPTION 'book name confirmation does not match'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_CONFIRMATION_MISMATCH';
    END IF;

    RETURN TRUE;
END;
$$;

-- A direct SQL user must use scripts/delete-book-database so the catalogue
-- and physical database cannot diverge. The gateway rewrites the browser's
-- delete_book RPC to authorize_book_database_deletion.
CREATE OR REPLACE FUNCTION api.delete_book(
    p_book_id VARCHAR,
    p_confirm_name VARCHAR
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    PERFORM api.authorize_book_database_deletion(p_book_id, p_confirm_name);
    RAISE EXCEPTION 'delete this physical book database through the control plane'
        USING ERRCODE = 'P0001',
              DETAIL = 'BOOK_DATABASE_DELETE_REQUIRES_PROVISIONER';
END;
$$;
