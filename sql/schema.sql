CREATE SCHEMA njord;

CREATE OR REPLACE FUNCTION njord.is_finite(value NUMERIC)
RETURNS BOOLEAN
LANGUAGE SQL
IMMUTABLE STRICT
AS $$
    SELECT value::TEXT NOT IN ('NaN', 'Infinity', '-Infinity');
$$;

-- Draft entry may contain transient text such as "-" while the user is still
-- typing. Parse only values that can become finite, stored-precision postings;
-- callers can discard NULL without turning an incomplete draft into an error.
CREATE OR REPLACE FUNCTION njord.parse_ledger_amount_or_null(value TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE STRICT
AS $$
DECLARE
    parsed NUMERIC(100,5);
BEGIN
    parsed := NULLIF(btrim(value), '')::NUMERIC;
    IF parsed IS NULL OR NOT njord.is_finite(parsed) THEN
	RETURN NULL;
    END IF;
    RETURN parsed;
EXCEPTION
    WHEN invalid_text_representation OR numeric_value_out_of_range THEN
	RETURN NULL;
END;
$$;

CREATE TABLE asset (
	id	VARCHAR PRIMARY KEY
);

CREATE TABLE valuations (
	date	TIMESTAMP NOT NULL,
	src	VARCHAR NOT NULL REFERENCES asset(id),
	dst	VARCHAR NOT NULL REFERENCES asset(id),
	rate	NUMERIC(100,5) NOT NULL,

	CONSTRAINT valuations_one_rate_per_date UNIQUE (src, dst, date),
	CONSTRAINT valuations_finite_date CHECK (isfinite(date)),
	CONSTRAINT valuations_positive_finite_rate CHECK (
	    rate > 0
	    AND njord.is_finite(rate)
	)
);

CREATE INDEX valuations_dst ON valuations(dst);

CREATE TABLE acct_types (
	id	VARCHAR PRIMARY KEY
);

-- Account class answers which financial-statement family an account belongs
-- to.  Account kind is deliberately separate: it describes how an account is
-- used without deciding where it sits in the hierarchy.  Reference rows are
-- loaded after acct_types in reference-data.sql.
CREATE TABLE account_kinds (
	id		VARCHAR PRIMARY KEY,
	label		VARCHAR NOT NULL,
	required_type	VARCHAR REFERENCES acct_types(id)
);

-- A book's owner/entity classification is explicit user-owned identity.  It
-- must never be inferred from the book name, currency, accounts, or an
-- available jurisdiction pack.
CREATE TABLE book_entity_types (
	id		VARCHAR PRIMARY KEY,
	allows_business_packs BOOLEAN NOT NULL
);

CREATE TABLE books (
	id		VARCHAR PRIMARY KEY,
	name		VARCHAR NOT NULL,
	reporting_asset	VARCHAR NOT NULL REFERENCES asset(id),
	entity_type	VARCHAR NOT NULL DEFAULT 'household'
		REFERENCES book_entity_types(id),
	archived_at	TIMESTAMPTZ
);

-- Reporting currency is effective-dated.  books.reporting_asset is retained
-- as the current-date cache used by register and account views; dated reports
-- resolve their denomination through njord.book_reporting_asset_at().
CREATE TABLE book_reporting_currencies (
	book_id		VARCHAR NOT NULL REFERENCES books(id),
	effective_from	DATE NOT NULL,
	asset		VARCHAR NOT NULL REFERENCES asset(id),

	PRIMARY KEY (book_id, effective_from)
);

CREATE OR REPLACE FUNCTION njord.seed_book_reporting_currency()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO book_reporting_currencies (book_id, effective_from, asset)
    VALUES (NEW.id, '-infinity'::DATE, NEW.reporting_asset)
    ON CONFLICT (book_id, effective_from) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER books_seed_reporting_currency
    AFTER INSERT ON books
    FOR EACH ROW EXECUTE FUNCTION njord.seed_book_reporting_currency();

CREATE OR REPLACE FUNCTION njord.book_reporting_asset_at(
    p_book_id VARCHAR,
    p_on_date DATE DEFAULT CURRENT_DATE
)
RETURNS VARCHAR
LANGUAGE SQL
STABLE
AS $$
    SELECT history.asset
    FROM book_reporting_currencies AS history
    WHERE history.book_id = p_book_id
      AND history.effective_from <= COALESCE(p_on_date, CURRENT_DATE)
    ORDER BY history.effective_from DESC
    LIMIT 1;
$$;

-- Keep the current-value cache and its effective-dated source inseparable for
-- direct SQL as well as the API. Future rows are forbidden because they could
-- become current without a statement to refresh books.reporting_asset.
CREATE OR REPLACE FUNCTION njord.enforce_reporting_currency_history()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    checked_book_id VARCHAR;
    checked_book_ids VARCHAR[];
BEGIN
    IF TG_TABLE_NAME = 'books' THEN
	checked_book_ids := ARRAY[COALESCE(NEW.id, OLD.id)];
    ELSIF TG_OP = 'INSERT' THEN
	checked_book_ids := ARRAY[NEW.book_id];
    ELSIF TG_OP = 'DELETE' THEN
	checked_book_ids := ARRAY[OLD.book_id];
    ELSE
	checked_book_ids := ARRAY[OLD.book_id, NEW.book_id];
    END IF;

    FOREACH checked_book_id IN ARRAY checked_book_ids LOOP
	PERFORM 1 FROM books WHERE id = checked_book_id FOR UPDATE;
	IF FOUND THEN
	    IF EXISTS (
		SELECT 1 FROM book_reporting_currencies
		WHERE book_id = checked_book_id AND effective_from > CURRENT_DATE
	    ) THEN
		RAISE EXCEPTION 'reporting-currency changes cannot start in the future'
		    USING ERRCODE = '23514',
			  CONSTRAINT = 'book_reporting_currency_not_future';
	    END IF;

	    IF (SELECT reporting_asset FROM books WHERE id = checked_book_id)
	       IS DISTINCT FROM
	       njord.book_reporting_asset_at(checked_book_id, CURRENT_DATE) THEN
		RAISE EXCEPTION 'book % reporting currency does not match its history',
		    checked_book_id
		    USING ERRCODE = '23514',
			  CONSTRAINT = 'book_reporting_currency_current';
	    END IF;
	END IF;
    END LOOP;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER books_reporting_currency_history
    AFTER INSERT OR UPDATE OR DELETE ON books
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_reporting_currency_history();

CREATE CONSTRAINT TRIGGER book_reporting_currencies_current_cache
    AFTER INSERT OR UPDATE OR DELETE ON book_reporting_currencies
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_reporting_currency_history();

CREATE TABLE accts (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	id	VARCHAR NOT NULL,
	name	VARCHAR NOT NULL,
	type	VARCHAR NOT NULL REFERENCES acct_types(id),
	atype	VARCHAR NOT NULL REFERENCES asset(id),
	parent_id VARCHAR,
	account_kind VARCHAR NOT NULL DEFAULT 'posting',
	placeholder BOOLEAN NOT NULL DEFAULT FALSE,
	pretax	NUMERIC(100,5) NOT NULL DEFAULT 1.0,
	default_business_use_percent NUMERIC(6,4) NOT NULL DEFAULT 1.0,
	comment	VARCHAR,

	PRIMARY KEY (book_id, id),
	CONSTRAINT accts_account_kind
	    FOREIGN KEY (account_kind) REFERENCES account_kinds(id),
	CONSTRAINT accts_parent_account
	    FOREIGN KEY (book_id, parent_id) REFERENCES accts(book_id, id)
	    DEFERRABLE INITIALLY IMMEDIATE,
	CONSTRAINT accts_root_shape CHECK (
	    (parent_id IS NULL AND account_kind = 'root' AND placeholder)
	    OR (parent_id IS NOT NULL AND account_kind <> 'root')
	),
	CONSTRAINT accts_group_is_placeholder
	    CHECK (account_kind <> 'group' OR placeholder),
	CONSTRAINT accts_name_has_no_path_separator
	    CHECK (position(':' IN name) = 0),
	CONSTRAINT accts_pretax_nonnegative_finite CHECK (
	    pretax >= 0 AND njord.is_finite(pretax)
	),
	CONSTRAINT accts_default_business_use_percent_range CHECK (
	    default_business_use_percent >= 0
	    AND default_business_use_percent <= 1
	)
);

CREATE UNIQUE INDEX accts_one_root_per_type
    ON accts (book_id, type)
    WHERE parent_id IS NULL;

CREATE UNIQUE INDEX accts_sibling_name
    ON accts (book_id, parent_id, name) NULLS NOT DISTINCT;

CREATE OR REPLACE FUNCTION validate_account_hierarchy()
RETURNS trigger AS $$
DECLARE
    parent_type VARCHAR;
    kind_required_type VARCHAR;
BEGIN
    -- Serializing hierarchy changes per book closes the concurrent-update gap
    -- in cycle and parent/child validation without locking unrelated books.
    PERFORM 1
    FROM books
    WHERE id = NEW.book_id
    FOR UPDATE;

    IF NEW.name IS NULL OR btrim(NEW.name) = '' THEN
	NEW.name := NEW.id;
    END IF;

    SELECT required_type
    INTO kind_required_type
    FROM account_kinds
    WHERE id = NEW.account_kind;

    IF FOUND AND kind_required_type IS NOT NULL
       AND kind_required_type <> NEW.type THEN
	RAISE EXCEPTION 'account kind % requires type %, not %',
	    NEW.account_kind,
	    kind_required_type,
	    NEW.type
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'accts_kind_type';
    END IF;

    IF NEW.parent_id IS NOT NULL THEN
	IF NEW.parent_id = NEW.id THEN
	    RAISE EXCEPTION 'account %.% cannot be its own parent',
		NEW.book_id,
		NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'accts_parent_cycle';
	END IF;

	SELECT type
	INTO parent_type
	FROM accts
	WHERE book_id = NEW.book_id
	  AND id = NEW.parent_id;

	IF FOUND AND parent_type <> NEW.type THEN
	    RAISE EXCEPTION 'account %.% has type %, but parent % has type %',
		NEW.book_id,
		NEW.id,
		NEW.type,
		NEW.parent_id,
		parent_type
		USING ERRCODE = '23514',
		      CONSTRAINT = 'accts_parent_type';
	END IF;

	IF EXISTS (
	    WITH RECURSIVE ancestors AS (
		SELECT id, parent_id
		FROM accts
		WHERE book_id = NEW.book_id
		  AND id = NEW.parent_id

		UNION ALL

		SELECT parent.id, parent.parent_id
		FROM accts AS parent
		JOIN ancestors AS child
		  ON parent.book_id = NEW.book_id
		 AND parent.id = child.parent_id
	    )
	    SELECT 1
	    FROM ancestors
	    WHERE id = NEW.id
	) THEN
	    RAISE EXCEPTION 'account %.% would create a parent cycle',
		NEW.book_id,
		NEW.id
		USING ERRCODE = '23514',
		      CONSTRAINT = 'accts_parent_cycle';
	END IF;
    END IF;

    IF EXISTS (
	SELECT 1
	FROM accts AS child
	WHERE child.book_id = NEW.book_id
	  AND child.parent_id = NEW.id
	  AND child.type <> NEW.type
    ) THEN
	RAISE EXCEPTION 'account %.% cannot change type while its children have another type',
	    NEW.book_id,
	    NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'accts_parent_type';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER accts_validate_hierarchy
    BEFORE INSERT OR UPDATE OF book_id, id, name, type, atype, parent_id,
        account_kind, placeholder
    ON accts
    FOR EACH ROW
    EXECUTE FUNCTION validate_account_hierarchy();

-- Commodity valuations above are unit rates (for example one XAU in GBP).
-- This table records the total observed value of a unique account, such as a
-- particular house, without pretending that the property is a fungible unit.
CREATE TABLE account_valuations (
	book_id	VARCHAR NOT NULL,
	acct	VARCHAR NOT NULL,
	date	TIMESTAMP NOT NULL,
	dst	VARCHAR NOT NULL REFERENCES asset(id),
	value	NUMERIC(100,5) NOT NULL,
	comment	VARCHAR,

	PRIMARY KEY (book_id, acct, dst, date),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
	CONSTRAINT account_valuations_finite_date CHECK (isfinite(date)),
	CHECK (
	    value >= 0
	    AND njord.is_finite(value)
	)
);

CREATE INDEX account_valuations_dst ON account_valuations(dst);

CREATE OR REPLACE FUNCTION validate_account_valuation()
RETURNS trigger AS $$
BEGIN
    -- Coordinate with account shape changes so a valuation cannot race an
    -- account becoming a group, liability, or commodity holding.
    PERFORM 1
    FROM books
    WHERE books.id = NEW.book_id
    FOR UPDATE;

    -- Leave missing account identities to the composite foreign key so direct
    -- SQL callers receive the normal referential-integrity error.
    IF NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE accts.book_id = NEW.book_id
	  AND accts.id = NEW.acct
    ) THEN
	RETURN NEW;
    END IF;

    IF NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE accts.book_id = NEW.book_id
	  AND accts.id = NEW.acct
	  AND accts.type = 'A'
	  AND accts.account_kind = 'fixed_asset'
	  AND NOT accts.placeholder
    ) THEN
	RAISE EXCEPTION 'account valuation %.% requires a posting fixed-asset account',
	    NEW.book_id,
	    NEW.acct
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'account_valuations_fixed_asset';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER account_valuations_validate
    BEFORE INSERT OR UPDATE OF book_id, acct ON account_valuations
    FOR EACH ROW
    EXECUTE FUNCTION validate_account_valuation();

CREATE TABLE cash_accounts (
	book_id	VARCHAR NOT NULL,
	acct	VARCHAR NOT NULL,

	PRIMARY KEY (book_id, acct),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id)
);

CREATE OR REPLACE FUNCTION ensure_cash_account_is_asset()
RETURNS trigger AS $$
BEGIN
    PERFORM 1
    FROM books
    WHERE books.id = NEW.book_id
    FOR UPDATE;

    IF NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE accts.book_id = NEW.book_id
	  AND accts.id = NEW.acct
	  AND accts.type = 'A'
	  AND NOT accts.placeholder
    ) THEN
	RAISE EXCEPTION 'cash account %.% must be a non-placeholder asset account',
	    NEW.book_id,
	    NEW.acct
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'cash_accounts_asset_account';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER cash_accounts_asset_account
    BEFORE INSERT OR UPDATE ON cash_accounts
    FOR EACH ROW
    EXECUTE FUNCTION ensure_cash_account_is_asset();

CREATE TABLE xactions (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	xid	SERIAL NOT NULL,
	date	TIMESTAMP NOT NULL,
	comment	VARCHAR,

	PRIMARY KEY (book_id, xid),
	CONSTRAINT xactions_finite_date CHECK (isfinite(date))
);

CREATE INDEX xactions_date ON xactions (book_id, date);

CREATE TABLE xaction_bits (
	id	SERIAL PRIMARY KEY,
	book_id	VARCHAR NOT NULL,
	xid	INTEGER NOT NULL,
	acct	VARCHAR NOT NULL,
	amt	NUMERIC(100,5) NOT NULL,
	comment	VARCHAR,

	CHECK (
	    amt <> 0
	    AND njord.is_finite(amt)
	),

	FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id),
	CONSTRAINT xaction_bits_one_line_per_account
	    UNIQUE (book_id, xid, acct)
);

CREATE OR REPLACE FUNCTION ensure_posting_account_accepts_entries()
RETURNS trigger AS $$
BEGIN
    -- Coordinate with account hierarchy updates so a posting and a change to
    -- placeholder status cannot race each other inside the same book.
    PERFORM 1
    FROM books
    WHERE id = NEW.book_id
    FOR UPDATE;

    IF EXISTS (
	SELECT 1
	FROM accts
	WHERE book_id = NEW.book_id
	  AND id = NEW.acct
	  AND placeholder
    ) THEN
	RAISE EXCEPTION 'placeholder account %.% cannot receive postings',
	    NEW.book_id,
	    NEW.acct
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'accts_placeholder_postings';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER xaction_bits_posting_account
    BEFORE INSERT OR UPDATE OF book_id, acct ON xaction_bits
    FOR EACH ROW
    EXECUTE FUNCTION ensure_posting_account_accepts_entries();

CREATE INDEX xaction_bits_acct	ON xaction_bits (book_id, acct);

-- Aged debtor/creditor schedules need invoice identity, due dates, and explicit
-- payment allocation. Amounts are never duplicated here: invoice and payment
-- values remain the referenced ledger posting amounts.
CREATE TABLE trade_parties (
	book_id VARCHAR NOT NULL REFERENCES books(id),
	id VARCHAR NOT NULL,
	name VARCHAR NOT NULL,
	is_customer BOOLEAN NOT NULL DEFAULT FALSE,
	is_supplier BOOLEAN NOT NULL DEFAULT FALSE,
	company_number VARCHAR,
	vat_number VARCHAR,
	default_terms_days INTEGER NOT NULL DEFAULT 0,
	notes VARCHAR,

	PRIMARY KEY (book_id, id),
	CHECK (btrim(id) <> ''),
	CHECK (btrim(name) <> ''),
	CHECK (is_customer OR is_supplier),
	CHECK (default_terms_days >= 0)
);

CREATE TABLE trade_invoices (
	book_id VARCHAR NOT NULL,
	id VARCHAR NOT NULL,
	party_id VARCHAR NOT NULL,
	direction VARCHAR NOT NULL,
	invoice_number VARCHAR NOT NULL,
	issued_on DATE NOT NULL,
	due_on DATE NOT NULL,
	xid INTEGER NOT NULL,
	control_acct VARCHAR NOT NULL,
	notes VARCHAR,

	PRIMARY KEY (book_id, id),
	UNIQUE (book_id, id, control_acct),
	UNIQUE (book_id, xid, control_acct),
	UNIQUE (book_id, direction, party_id, invoice_number),
	FOREIGN KEY (book_id, party_id) REFERENCES trade_parties(book_id, id),
	FOREIGN KEY (book_id, xid, control_acct)
	    REFERENCES xaction_bits(book_id, xid, acct),
	CHECK (direction IN ('receivable', 'payable')),
	CHECK (btrim(id) <> ''),
	CHECK (btrim(invoice_number) <> ''),
	CHECK (issued_on <= due_on),
	CONSTRAINT trade_invoices_finite_dates CHECK (
	    isfinite(issued_on) AND isfinite(due_on)
	)
);

CREATE TABLE trade_invoice_allocations (
	book_id VARCHAR NOT NULL,
	invoice_id VARCHAR NOT NULL,
	payment_xid INTEGER NOT NULL,
	control_acct VARCHAR NOT NULL,
	amount NUMERIC(100,5) NOT NULL,
	notes VARCHAR,

	PRIMARY KEY (book_id, invoice_id, payment_xid, control_acct),
	FOREIGN KEY (book_id, invoice_id, control_acct)
	    REFERENCES trade_invoices(book_id, id, control_acct),
	FOREIGN KEY (book_id, payment_xid, control_acct)
	    REFERENCES xaction_bits(book_id, xid, acct),
	CHECK (
	    amount > 0
	    AND njord.is_finite(amount)
	)
);

CREATE INDEX trade_invoices_due
    ON trade_invoices (book_id, direction, due_on);
CREATE INDEX trade_invoices_party
    ON trade_invoices (book_id, party_id);
CREATE INDEX trade_invoice_allocations_payment
    ON trade_invoice_allocations (book_id, payment_xid, control_acct);

CREATE OR REPLACE FUNCTION protect_trade_party_roles()
RETURNS trigger AS $$
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    IF EXISTS (
	SELECT 1
	FROM trade_invoices
	WHERE trade_invoices.book_id = NEW.book_id
	  AND trade_invoices.party_id = NEW.id
	  AND (
	      (trade_invoices.direction = 'receivable' AND NOT NEW.is_customer)
	      OR (trade_invoices.direction = 'payable' AND NOT NEW.is_supplier)
	  )
    ) THEN
	RAISE EXCEPTION 'trade party %.% roles are required by existing invoices',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_invoice_party_role';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trade_parties_protect_roles
    BEFORE UPDATE OF book_id, id, is_customer, is_supplier ON trade_parties
    FOR EACH ROW EXECUTE FUNCTION protect_trade_party_roles();

CREATE OR REPLACE FUNCTION validate_trade_invoice()
RETURNS trigger AS $$
DECLARE
    party_customer BOOLEAN;
    party_supplier BOOLEAN;
    posting_amount NUMERIC;
    posting_date DATE;
    allocated_amount NUMERIC;
    control_type VARCHAR;
    control_placeholder BOOLEAN;
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT is_customer, is_supplier
    INTO party_customer, party_supplier
    FROM trade_parties
    WHERE book_id = NEW.book_id
      AND id = NEW.party_id;

    IF FOUND AND (
	(NEW.direction = 'receivable' AND NOT party_customer)
	OR (NEW.direction = 'payable' AND NOT party_supplier)
    ) THEN
	RAISE EXCEPTION 'trade party %.% does not support invoice direction %',
	    NEW.book_id, NEW.party_id, NEW.direction
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_invoice_party_role';
    END IF;

    SELECT bits.amt, xactions.date::DATE, accts.type, accts.placeholder
    INTO posting_amount, posting_date, control_type, control_placeholder
    FROM xaction_bits AS bits
    JOIN xactions
      ON xactions.book_id = bits.book_id
     AND xactions.xid = bits.xid
    JOIN accts
      ON accts.book_id = bits.book_id
     AND accts.id = bits.acct
    WHERE bits.book_id = NEW.book_id
      AND bits.xid = NEW.xid
      AND bits.acct = NEW.control_acct;

    IF FOUND AND (
	control_placeholder
	OR (NEW.direction = 'receivable'
	    AND (control_type <> 'A' OR posting_amount <= 0))
	OR (NEW.direction = 'payable'
	    AND (control_type <> 'L' OR posting_amount >= 0))
    ) THEN
	RAISE EXCEPTION 'trade invoice % has an invalid % control posting',
	    NEW.id, NEW.direction
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_invoice_control_posting';
    END IF;

    IF posting_date IS NOT NULL AND NEW.issued_on <> posting_date THEN
	RAISE EXCEPTION 'trade invoice % issue date % does not match ledger date %',
	    NEW.id, NEW.issued_on, posting_date
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_invoice_ledger_date';
    END IF;

    SELECT COALESCE(sum(amount), 0)
    INTO allocated_amount
    FROM trade_invoice_allocations
    WHERE book_id = NEW.book_id
      AND invoice_id = NEW.id
      AND control_acct = NEW.control_acct;

    IF posting_amount IS NOT NULL AND allocated_amount > abs(posting_amount) THEN
	RAISE EXCEPTION 'allocations exceed replacement invoice %.% amount',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_invoice_not_overallocated';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trade_invoices_validate
    BEFORE INSERT OR UPDATE ON trade_invoices
    FOR EACH ROW EXECUTE FUNCTION validate_trade_invoice();

-- Transaction dates are duplicated by several optional evidence tables. Take
-- the same per-Book lock as their validators before changing the authoritative
-- ledger date, so metadata insertion and date editing have a serial order.
CREATE OR REPLACE FUNCTION serialize_xaction_date_change()
RETURNS trigger AS $$
BEGIN
    PERFORM 1
    FROM books
    WHERE id IN (OLD.book_id, NEW.book_id)
    ORDER BY id
    FOR UPDATE;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER xactions_serialize_date_change
    BEFORE UPDATE OF book_id, date ON xactions
    FOR EACH ROW EXECUTE FUNCTION serialize_xaction_date_change();

-- Invoice issue dates duplicate the linked ledger date for reporting. Check
-- the reverse direction as a deferred constraint so direct SQL may update the
-- transaction first and its invoice metadata later in the same transaction.
CREATE OR REPLACE FUNCTION enforce_trade_invoice_ledger_date()
RETURNS trigger AS $$
BEGIN
    IF EXISTS (
	SELECT 1
	FROM trade_invoices
	WHERE trade_invoices.book_id = NEW.book_id
	  AND trade_invoices.xid = NEW.xid
	  AND trade_invoices.issued_on <> NEW.date::DATE
    ) THEN
	RAISE EXCEPTION 'transaction %.% date does not match its trade invoice',
	    NEW.book_id, NEW.xid
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'trade_invoice_ledger_date';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER xactions_preserve_trade_invoice_date
    AFTER UPDATE ON xactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    WHEN (OLD.date IS DISTINCT FROM NEW.date)
    EXECUTE FUNCTION enforce_trade_invoice_ledger_date();

CREATE OR REPLACE FUNCTION validate_trade_allocation()
RETURNS trigger AS $$
DECLARE
    invoice_direction VARCHAR;
    payment_amount NUMERIC;
BEGIN
    PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;

    SELECT invoices.direction, payment.amt
    INTO invoice_direction, payment_amount
    FROM trade_invoices AS invoices
    JOIN xaction_bits AS payment
      ON payment.book_id = NEW.book_id
     AND payment.xid = NEW.payment_xid
     AND payment.acct = NEW.control_acct
    WHERE invoices.book_id = NEW.book_id
      AND invoices.id = NEW.invoice_id
      AND invoices.control_acct = NEW.control_acct;

    IF FOUND AND (
	(invoice_direction = 'receivable' AND payment_amount >= 0)
	OR (invoice_direction = 'payable' AND payment_amount <= 0)
    ) THEN
	RAISE EXCEPTION 'payment posting has the wrong sign for % invoice %',
	    invoice_direction, NEW.invoice_id
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_allocation_payment_sign';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trade_invoice_allocations_validate
    BEFORE INSERT OR UPDATE ON trade_invoice_allocations
    FOR EACH ROW EXECUTE FUNCTION validate_trade_allocation();

CREATE OR REPLACE FUNCTION assert_trade_allocation_limits(
    checked_book VARCHAR,
    checked_invoice VARCHAR,
    checked_payment_xid INTEGER,
    checked_control_acct VARCHAR
)
RETURNS VOID AS $$
DECLARE
    invoice_amount NUMERIC;
    invoice_allocated NUMERIC;
    payment_amount NUMERIC;
    payment_allocated NUMERIC;
BEGIN
    SELECT abs(bits.amt), COALESCE(sum(allocations.amount), 0)
    INTO invoice_amount, invoice_allocated
    FROM trade_invoices AS invoices
    JOIN xaction_bits AS bits
      ON bits.book_id = invoices.book_id
     AND bits.xid = invoices.xid
     AND bits.acct = invoices.control_acct
    LEFT JOIN trade_invoice_allocations AS allocations
      ON allocations.book_id = invoices.book_id
     AND allocations.invoice_id = invoices.id
     AND allocations.control_acct = invoices.control_acct
    WHERE invoices.book_id = checked_book
      AND invoices.id = checked_invoice
    GROUP BY bits.amt;

    IF FOUND AND invoice_allocated > invoice_amount THEN
	RAISE EXCEPTION 'allocations exceed invoice %.% amount',
	    checked_book, checked_invoice
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_invoice_not_overallocated';
    END IF;

    SELECT abs(payment.amt), COALESCE(sum(allocations.amount), 0)
    INTO payment_amount, payment_allocated
    FROM xaction_bits AS payment
    LEFT JOIN trade_invoice_allocations AS allocations
      ON allocations.book_id = payment.book_id
     AND allocations.payment_xid = payment.xid
     AND allocations.control_acct = payment.acct
    WHERE payment.book_id = checked_book
      AND payment.xid = checked_payment_xid
      AND payment.acct = checked_control_acct
    GROUP BY payment.amt;

    IF FOUND AND payment_allocated > payment_amount THEN
	RAISE EXCEPTION 'allocations exceed payment posting %:%:% amount',
	    checked_book, checked_payment_xid, checked_control_acct
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_payment_not_overallocated';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION enforce_trade_allocation_limits()
RETURNS trigger AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
	PERFORM assert_trade_allocation_limits(
	    OLD.book_id, OLD.invoice_id, OLD.payment_xid, OLD.control_acct
	);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
	PERFORM assert_trade_allocation_limits(
	    NEW.book_id, NEW.invoice_id, NEW.payment_xid, NEW.control_acct
	);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER trade_invoice_allocations_limits
    AFTER INSERT OR UPDATE OR DELETE ON trade_invoice_allocations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_trade_allocation_limits();

CREATE OR REPLACE FUNCTION protect_trade_posting_amount()
RETURNS trigger AS $$
BEGIN
    PERFORM 1
    FROM books
    WHERE id IN (OLD.book_id, NEW.book_id)
    ORDER BY id
    FOR UPDATE;

    IF OLD.amt IS DISTINCT FROM NEW.amt AND EXISTS (
	SELECT 1 FROM trade_invoices
	WHERE book_id = OLD.book_id AND xid = OLD.xid AND control_acct = OLD.acct
	UNION ALL
	SELECT 1 FROM trade_invoice_allocations
	WHERE book_id = OLD.book_id
	  AND payment_xid = OLD.xid
	  AND control_acct = OLD.acct
    ) THEN
	RAISE EXCEPTION 'remove trade invoice/allocation metadata before changing its posting amount'
	    USING ERRCODE = '23514', CONSTRAINT = 'trade_posting_amount_immutable';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER xaction_bits_protect_trade_amount
    BEFORE UPDATE OF amt ON xaction_bits
    FOR EACH ROW EXECUTE FUNCTION protect_trade_posting_amount();

COMMENT ON TABLE trade_parties IS
    'Per-book customers and suppliers; a party may fulfil both roles.';
COMMENT ON TABLE trade_invoices IS
    'Invoice identity and due date linked to its authoritative receivable/payable ledger posting.';
COMMENT ON TABLE trade_invoice_allocations IS
    'Positive payment allocations; invoice and payment totals remain authoritative ledger posting amounts.';

-- Reconciliation belongs to an individual posting, not to the transaction's
-- balance and completeness invariants.  Use the posting's accounting identity
-- rather than its internal serial id so callers can address the same row they
-- see in a register.
CREATE TABLE unreconciled_postings (
	book_id	VARCHAR NOT NULL,
	xid	INTEGER NOT NULL,
	acct	VARCHAR NOT NULL,

	PRIMARY KEY (book_id, xid, acct),
	FOREIGN KEY (book_id, xid, acct)
	    REFERENCES xaction_bits (book_id, xid, acct)
	    ON UPDATE CASCADE
	    ON DELETE CASCADE
);

CREATE OR REPLACE FUNCTION mark_new_posting_unreconciled()
RETURNS trigger AS $$
BEGIN
    INSERT INTO unreconciled_postings (book_id, xid, acct)
    VALUES (NEW.book_id, NEW.xid, NEW.acct)
    ON CONFLICT (book_id, xid, acct) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION reopen_changed_posting()
RETURNS trigger AS $$
BEGIN
    -- This is deliberately a BEFORE trigger.  If the posting's natural key is
    -- changing, mark its old identity first and let the cascading foreign key
    -- carry the marker to the new identity without depending on AFTER-trigger
    -- ordering.
    INSERT INTO unreconciled_postings (book_id, xid, acct)
    VALUES (OLD.book_id, OLD.xid, OLD.acct)
    ON CONFLICT (book_id, xid, acct) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER xaction_bits_new_posting_unreconciled
    AFTER INSERT ON xaction_bits
    FOR EACH ROW
    EXECUTE FUNCTION mark_new_posting_unreconciled();


CREATE TRIGGER xaction_bits_changed_posting_unreconciled
    BEFORE UPDATE OF acct, amt ON xaction_bits
    FOR EACH ROW
    WHEN (
	(OLD.acct, OLD.amt)
	IS DISTINCT FROM
	(NEW.acct, NEW.amt)
    )
    EXECUTE FUNCTION reopen_changed_posting();

CREATE OR REPLACE FUNCTION assert_xaction_balance(
    checked_book_id VARCHAR,
    checked_xid INTEGER
)
RETURNS VOID AS $$
DECLARE
    line_count INTEGER;
    unbalanced_assets VARCHAR;
BEGIN
    IF NOT EXISTS (
	SELECT 1
	FROM xactions
	WHERE book_id = checked_book_id
	  AND xid = checked_xid
    ) THEN
	RETURN;
    END IF;

    SELECT count(*)
    INTO line_count
    FROM xaction_bits
    WHERE book_id = checked_book_id
      AND xid = checked_xid;

    IF line_count < 2 THEN
	RAISE EXCEPTION 'transaction %:% requires at least two lines',
	    checked_book_id,
	    checked_xid
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'xaction_balanced';
    END IF;

    SELECT string_agg(asset || '=' || amount, ', ' ORDER BY asset)
    INTO unbalanced_assets
    FROM (
	SELECT accts.atype AS asset, sum(xaction_bits.amt) AS amount
	FROM xaction_bits
	JOIN accts
	  ON accts.book_id = xaction_bits.book_id
	 AND accts.id = xaction_bits.acct
	WHERE xaction_bits.book_id = checked_book_id
	  AND xaction_bits.xid = checked_xid
	GROUP BY accts.atype
	HAVING sum(xaction_bits.amt) <> 0
    ) AS imbalances;

    IF unbalanced_assets IS NOT NULL THEN
	RAISE EXCEPTION 'transaction %:% is not balanced',
	    checked_book_id,
	    checked_xid
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'xaction_balanced',
		  DETAIL = 'Asset imbalances: ' || unbalanced_assets;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION enforce_xaction_balance()
RETURNS trigger AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
	PERFORM assert_xaction_balance(OLD.book_id, OLD.xid);
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') AND
       (TG_OP = 'INSERT' OR
	(OLD.book_id, OLD.xid) IS DISTINCT FROM (NEW.book_id, NEW.xid)) THEN
	PERFORM assert_xaction_balance(NEW.book_id, NEW.xid);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER xactions_balance
    AFTER INSERT OR UPDATE OR DELETE ON xactions
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION enforce_xaction_balance();

CREATE CONSTRAINT TRIGGER xaction_bits_balance
    AFTER INSERT OR UPDATE OR DELETE ON xaction_bits
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION enforce_xaction_balance();

CREATE OR REPLACE FUNCTION enforce_account_invariants()
RETURNS trigger AS $$
DECLARE
    affected RECORD;
BEGIN
    IF EXISTS (
	SELECT 1
	FROM trade_invoices
	WHERE trade_invoices.book_id = NEW.book_id
	  AND trade_invoices.control_acct = NEW.id
	  AND (
	      (trade_invoices.direction = 'receivable' AND NEW.type <> 'A')
	      OR (trade_invoices.direction = 'payable' AND NEW.type <> 'L')
	  )
    ) THEN
	RAISE EXCEPTION 'account %.% type is required by existing trade invoices',
	    NEW.book_id, NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'trade_invoice_control_posting';
    END IF;

    IF EXISTS (
	SELECT 1
	FROM account_valuations
	WHERE account_valuations.book_id = NEW.book_id
	  AND account_valuations.acct = NEW.id
    ) AND (
	NEW.type <> 'A'
	OR NEW.account_kind <> 'fixed_asset'
	OR NEW.placeholder
    ) THEN
	RAISE EXCEPTION 'valued account %.% must remain a posting fixed-asset account',
	    NEW.book_id,
	    NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'account_valuations_fixed_asset';
    END IF;

    IF NEW.placeholder AND EXISTS (
	SELECT 1
	FROM xaction_bits
	WHERE xaction_bits.book_id = NEW.book_id
	  AND xaction_bits.acct = NEW.id
    ) THEN
	RAISE EXCEPTION 'account %.% has postings and cannot be a placeholder',
	    NEW.book_id,
	    NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'accts_placeholder_postings';
    END IF;

    IF (NEW.type <> 'A' OR NEW.placeholder) AND EXISTS (
	SELECT 1
	FROM cash_accounts
	WHERE cash_accounts.book_id = NEW.book_id
	  AND cash_accounts.acct = NEW.id
    ) THEN
	RAISE EXCEPTION 'cash account %.% must be a non-placeholder asset account',
	    NEW.book_id,
	    NEW.id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'cash_accounts_asset_account';
    END IF;

    IF OLD.atype IS NOT DISTINCT FROM NEW.atype THEN
	RETURN NULL;
    END IF;

    FOR affected IN
	SELECT DISTINCT xaction_bits.book_id, xaction_bits.xid
	FROM xaction_bits
	WHERE xaction_bits.book_id = NEW.book_id
	  AND xaction_bits.acct = NEW.id
    LOOP
	PERFORM assert_xaction_balance(
	    affected.book_id,
	    affected.xid
	);
    END LOOP;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER accts_asset_balance
    AFTER UPDATE ON accts
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW
    EXECUTE FUNCTION enforce_account_invariants();

CREATE TABLE vendors (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	id	VARCHAR NOT NULL,
	name	VARCHAR NOT NULL,
	vat_number VARCHAR,
	notes	VARCHAR,

	PRIMARY KEY (book_id, id)
);

CREATE TABLE business_expenses (
	book_id		VARCHAR NOT NULL,
	xid		INTEGER NOT NULL,
	vendor_id	VARCHAR,
	invoice_number	VARCHAR,
	invoice_date	DATE,
	supply_date	DATE,
	business_purpose VARCHAR,
	receipt_uri	VARCHAR,
	notes		VARCHAR,

	PRIMARY KEY (book_id, xid),
	FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid),
	FOREIGN KEY (book_id, vendor_id) REFERENCES vendors(book_id, id),
	CONSTRAINT business_expenses_finite_dates CHECK (
	    (invoice_date IS NULL OR isfinite(invoice_date))
	    AND (supply_date IS NULL OR isfinite(supply_date))
	)
);

CREATE TABLE business_expense_lines (
	xaction_bit_id		INTEGER PRIMARY KEY REFERENCES xaction_bits(id),
	business_use_percent	NUMERIC(6,4),
	net_amount		NUMERIC(100,5),
	vat_amount		NUMERIC(100,5),
	gross_amount		NUMERIC(100,5),
	note			VARCHAR,

	CHECK (business_use_percent IS NULL OR
	       (business_use_percent >= 0 AND business_use_percent <= 1)),
	CONSTRAINT business_expense_lines_unsigned_finite_amounts CHECK (
	    (net_amount IS NULL OR
	     (net_amount >= 0 AND njord.is_finite(net_amount)))
	    AND (vat_amount IS NULL OR
		 (vat_amount >= 0 AND njord.is_finite(vat_amount)))
	    AND (gross_amount IS NULL OR
		 (gross_amount >= 0 AND njord.is_finite(gross_amount)))
	)
);

CREATE INDEX business_expenses_vendor
    ON business_expenses (book_id, vendor_id);

CREATE OR REPLACE VIEW business_expense_detail AS
    SELECT
	xaction_bits.book_id,
	xaction_bits.xid,
	xaction_bits.id AS xaction_bit_id,
	CAST(xactions.date AS date) AS date,
	business_expenses.vendor_id,
	vendors.name AS vendor_name,
	business_expenses.invoice_number,
	business_expenses.invoice_date,
	business_expenses.supply_date,
	business_expenses.business_purpose,
	business_expenses.receipt_uri,
	xactions.comment AS description,
	xaction_bits.acct AS account,
	accts.type AS account_type,
	xaction_bits.comment AS memo,
	xaction_bits.amt AS amount,
	COALESCE(
	    business_expense_lines.business_use_percent,
	    accts.default_business_use_percent
	) AS business_use_percent,
	business_expense_lines.net_amount,
	business_expense_lines.vat_amount,
	business_expense_lines.gross_amount,
	business_expense_lines.note,
	business_expenses.notes AS expense_notes
    FROM business_expenses
    JOIN xactions
      ON xactions.book_id = business_expenses.book_id
     AND xactions.xid = business_expenses.xid
    JOIN xaction_bits
      ON xaction_bits.book_id = business_expenses.book_id
     AND xaction_bits.xid = business_expenses.xid
    JOIN accts
      ON accts.book_id = xaction_bits.book_id
     AND accts.id = xaction_bits.acct
    LEFT JOIN vendors
      ON vendors.book_id = business_expenses.book_id
     AND vendors.id = business_expenses.vendor_id
    LEFT JOIN business_expense_lines
      ON business_expense_lines.xaction_bit_id = xaction_bits.id;
