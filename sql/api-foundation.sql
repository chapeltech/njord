-- Shared API types and helpers required by both core pages and optional packs.
-- Load this after the ledger/report schema and before any jurisdiction pack.

CREATE SCHEMA api;

\ir presentation.sql

-- One ordered definition drives every standard chart bootstrap. The five
-- roots are the hierarchy contract; the final rows are optional conveniences.
CREATE OR REPLACE VIEW njord.standard_account_catalog (
    account_order, id, name, account_type, parent_id,
    account_kind, placeholder, onboarding
) AS VALUES
    (1, 'Assets'::VARCHAR, 'Assets'::VARCHAR, 'A'::VARCHAR,
	NULL::VARCHAR, 'root'::VARCHAR, TRUE, FALSE),
    (2, 'Liabilities', 'Liabilities', 'L', NULL, 'root', TRUE, FALSE),
    (3, 'Equity', 'Equity', 'Q', NULL, 'root', TRUE, FALSE),
    (4, 'Income', 'Income', 'I', NULL, 'root', TRUE, FALSE),
    (5, 'Expenses', 'Expenses', 'E', NULL, 'root', TRUE, FALSE),
    (6, 'Opening Balance', 'Opening Balance', 'Q', 'Equity',
	'posting', FALSE, TRUE),
    (7, 'Uncategorised Income', 'Uncategorised Income', 'I', 'Income',
	'posting', FALSE, TRUE),
    (8, 'Uncategorised Expenses', 'Uncategorised Expenses', 'E', 'Expenses',
	'posting', FALSE, TRUE);

-- Reuse compatible rows, but never silently reinterpret an occupied account
-- identity or hierarchy slot. Insertion order keeps parents ahead of leaves.
CREATE OR REPLACE FUNCTION njord.ensure_standard_accounts(
    p_book_id VARCHAR,
    p_include_onboarding BOOLEAN DEFAULT TRUE
)
RETURNS VOID
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    reporting_asset VARCHAR;
    required_account RECORD;
    colliding_account VARCHAR;
BEGIN
    SELECT books.reporting_asset
    INTO reporting_asset
    FROM public.books
    WHERE books.id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    FOR required_account IN
	SELECT *
	FROM njord.standard_account_catalog
	WHERE p_include_onboarding OR NOT onboarding
	ORDER BY account_order
    LOOP
	CONTINUE WHEN EXISTS (
	    SELECT 1
	    FROM public.accts
	    WHERE accts.book_id = p_book_id
	      AND accts.id = required_account.id
	      AND accts.type = required_account.account_type
	      AND accts.atype = reporting_asset
	      AND accts.parent_id IS NOT DISTINCT FROM required_account.parent_id
	      AND accts.account_kind = required_account.account_kind
	      AND accts.placeholder = required_account.placeholder
	);

	SELECT accts.id
	INTO colliding_account
	FROM public.accts
	WHERE accts.book_id = p_book_id
	  AND (
	    accts.id = required_account.id
	    OR (
		required_account.parent_id IS NULL
		AND accts.parent_id IS NULL
		AND accts.type = required_account.account_type
	    ) OR (
		required_account.parent_id IS NOT NULL
		AND accts.parent_id = required_account.parent_id
		AND accts.name = required_account.name
	    )
	  )
	ORDER BY (accts.id = required_account.id) DESC
	LIMIT 1;

	IF FOUND THEN
	    RAISE EXCEPTION 'standard account % conflicts with existing account %',
		required_account.id, colliding_account
		USING ERRCODE = 'P0001',
		      DETAIL = 'STANDARD_ACCOUNT_COLLISION',
		      HINT = 'required_account=' || required_account.id
			  || '; conflicting_account=' || colliding_account;
	END IF;

	INSERT INTO public.accts (
	    book_id, id, name, type, atype, parent_id,
	    account_kind, placeholder
	) VALUES (
	    p_book_id, required_account.id, required_account.name,
	    required_account.account_type, reporting_asset,
	    required_account.parent_id, required_account.account_kind,
	    required_account.placeholder
	);
    END LOOP;
END;
$$;

-- Packs may require the five compatible class roots without imposing the
-- optional onboarding accounts on an established custom chart.
CREATE OR REPLACE FUNCTION njord.standard_account_hierarchy_complete(
    p_book_id VARCHAR
)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
	SELECT 1
	FROM public.books
	WHERE books.id = p_book_id
	  AND NOT EXISTS (
	    SELECT 1
	    FROM njord.standard_account_catalog AS required
	    WHERE NOT required.onboarding
	      AND NOT EXISTS (
		SELECT 1
		FROM public.accts
		WHERE accts.book_id = books.id
		  AND accts.id = required.id
		  AND accts.type = required.account_type
		  AND accts.atype = books.reporting_asset
		  AND accts.parent_id IS NOT DISTINCT FROM required.parent_id
		  AND accts.account_kind = required.account_kind
		  AND accts.placeholder = required.placeholder
	    )
	  )
    );
$$;

CREATE OR REPLACE FUNCTION njord.configuration_check_payload(
    p_id TEXT,
    p_label TEXT,
    p_complete BOOLEAN,
    p_message TEXT
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
	'id', p_id,
	'label', p_label,
	'complete', p_complete,
	'message', p_message
    );
$$;

CREATE OR REPLACE FUNCTION njord.labelled_option_payload(
    p_id TEXT,
    p_label TEXT
)
RETURNS JSONB
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object('id', p_id, 'label', p_label);
$$;

-- Configuration mutations lock the Book before checking its denomination.
CREATE OR REPLACE FUNCTION njord.lock_book_reporting_asset(p_book_id VARCHAR)
RETURNS VARCHAR
LANGUAGE plpgsql
VOLATILE
AS $$
DECLARE
    reporting_asset VARCHAR;
BEGIN
    SELECT books.reporting_asset
    INTO reporting_asset
    FROM public.books
    WHERE books.id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
	RAISE EXCEPTION 'book does not exist'
	    USING ERRCODE = 'PT404', DETAIL = 'BOOK_NOT_FOUND';
    END IF;

    RETURN reporting_asset;
END;
$$;
