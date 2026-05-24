CREATE TABLE IF NOT EXISTS asset (
	id	VARCHAR PRIMARY KEY
	-- XXXrcd: boolean for multiples
	-- tagging is kewl!  We should add it here...
);

CREATE TABLE IF NOT EXISTS valuations (
	date	TIMESTAMP NOT NULL,
	src	VARCHAR NOT NULL REFERENCES asset(id),
	dst	VARCHAR NOT NULL REFERENCES asset(id),
	rate	NUMERIC(100,5)
);
CREATE INDEX IF NOT EXISTS valuations_src  ON valuations(src);
CREATE INDEX IF NOT EXISTS valuations_dst  ON valuations(dst);
CREATE INDEX IF NOT EXISTS valuations_date ON valuations(date);

CREATE TABLE IF NOT EXISTS acct_types (
	id	VARCHAR PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS books (
	id		VARCHAR PRIMARY KEY,
	name		VARCHAR NOT NULL,
	reporting_asset	VARCHAR NOT NULL REFERENCES asset(id)
);

CREATE TABLE IF NOT EXISTS vat_codes (
	id			VARCHAR PRIMARY KEY,
	description		VARCHAR NOT NULL,
	vat_rate		NUMERIC(6,4) NOT NULL,
	recoverable_rate	NUMERIC(6,4) NOT NULL,

	CHECK (vat_rate >= 0),
	CHECK (recoverable_rate >= 0 AND recoverable_rate <= 1)
);

CREATE TABLE IF NOT EXISTS expense_tax_treatments (
	id		VARCHAR PRIMARY KEY,
	description	VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS accts (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	id	VARCHAR NOT NULL,
	type	VARCHAR NOT NULL REFERENCES acct_types(id),
	atype	VARCHAR NOT NULL REFERENCES asset(id),
	pretax	NUMERIC(100,5) NOT NULL DEFAULT 1.0,
	default_vat_code VARCHAR REFERENCES vat_codes(id),
	default_tax_treatment VARCHAR REFERENCES expense_tax_treatments(id),
	default_business_use_percent NUMERIC(6,4) NOT NULL DEFAULT 1.0,
	comment	VARCHAR,

	PRIMARY KEY (book_id, id)
);

ALTER TABLE accts
    ADD COLUMN IF NOT EXISTS default_vat_code VARCHAR REFERENCES vat_codes(id);

ALTER TABLE accts
    ADD COLUMN IF NOT EXISTS default_tax_treatment VARCHAR REFERENCES expense_tax_treatments(id);

ALTER TABLE accts
    ADD COLUMN IF NOT EXISTS default_business_use_percent NUMERIC(6,4) NOT NULL DEFAULT 1.0;

DO $$
BEGIN
    ALTER TABLE accts
	ADD CONSTRAINT accts_default_business_use_percent_range
	CHECK (default_business_use_percent >= 0 AND default_business_use_percent <= 1);
EXCEPTION
    WHEN duplicate_object THEN
	NULL;
END;
$$;

CREATE TABLE IF NOT EXISTS cash_accounts (
	book_id	VARCHAR NOT NULL,
	acct	VARCHAR NOT NULL,

	PRIMARY KEY (book_id, acct),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id)
);

CREATE OR REPLACE FUNCTION ensure_cash_account_is_asset()
RETURNS trigger AS $$
BEGIN
    IF NOT EXISTS (
	SELECT 1
	FROM accts
	WHERE accts.book_id = NEW.book_id
	  AND accts.id = NEW.acct
	  AND accts.type = 'A'
    ) THEN
	RAISE EXCEPTION 'cash account %.% must be an asset account',
	    NEW.book_id,
	    NEW.acct
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'cash_accounts_asset_account';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS cash_accounts_asset_account ON cash_accounts;

CREATE TRIGGER cash_accounts_asset_account
    BEFORE INSERT OR UPDATE ON cash_accounts
    FOR EACH ROW
    EXECUTE FUNCTION ensure_cash_account_is_asset();

CREATE TABLE IF NOT EXISTS xactions (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	xid	SERIAL NOT NULL,
	date	TIMESTAMP NOT NULL,
	comment	VARCHAR,

	PRIMARY KEY (book_id, xid)
);

CREATE TABLE IF NOT EXISTS xaction_bits (
	id	SERIAL PRIMARY KEY,
	book_id	VARCHAR NOT NULL,
	xid	INTEGER NOT NULL,
	acct	VARCHAR NOT NULL,
	amt	NUMERIC(100,5) NOT NULL,
	comment	VARCHAR,

	FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid),
	FOREIGN KEY (book_id, acct) REFERENCES accts(book_id, id)
);

CREATE INDEX IF NOT EXISTS xaction_bits_xid	ON xaction_bits (book_id, xid);
CREATE INDEX IF NOT EXISTS xaction_bits_acct	ON xaction_bits (book_id, acct);

DO $$
BEGIN
    ALTER TABLE xaction_bits
	ADD CONSTRAINT xaction_bits_one_line_per_account
	UNIQUE (book_id, xid, acct);
EXCEPTION
    WHEN duplicate_object OR duplicate_table THEN
	NULL;
END;
$$;

CREATE TABLE IF NOT EXISTS xaction_unresolved (
	book_id	VARCHAR NOT NULL,
	xid	INTEGER NOT NULL,

	PRIMARY KEY (book_id, xid),
	FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid)
);

CREATE TABLE IF NOT EXISTS vendors (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	id	VARCHAR NOT NULL,
	name	VARCHAR NOT NULL,
	vat_number VARCHAR,
	notes	VARCHAR,

	PRIMARY KEY (book_id, id)
);

CREATE TABLE IF NOT EXISTS business_expenses (
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
	FOREIGN KEY (book_id, vendor_id) REFERENCES vendors(book_id, id)
);

CREATE TABLE IF NOT EXISTS business_expense_lines (
	xaction_bit_id		INTEGER PRIMARY KEY REFERENCES xaction_bits(id),
	vat_code		VARCHAR REFERENCES vat_codes(id),
	tax_treatment		VARCHAR REFERENCES expense_tax_treatments(id),
	business_use_percent	NUMERIC(6,4),
	net_amount		NUMERIC(100,5),
	vat_amount		NUMERIC(100,5),
	gross_amount		NUMERIC(100,5),
	note			VARCHAR,

	CHECK (business_use_percent IS NULL OR
	       (business_use_percent >= 0 AND business_use_percent <= 1))
);

CREATE INDEX IF NOT EXISTS business_expenses_vendor
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
	COALESCE(business_expense_lines.vat_code, accts.default_vat_code)
	    AS vat_code,
	vat_codes.vat_rate,
	vat_codes.recoverable_rate AS vat_recoverable_rate,
	COALESCE(
	    business_expense_lines.tax_treatment,
	    accts.default_tax_treatment
	) AS tax_treatment,
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
      ON business_expense_lines.xaction_bit_id = xaction_bits.id
    LEFT JOIN vat_codes
      ON vat_codes.id =
	 COALESCE(business_expense_lines.vat_code, accts.default_vat_code);

-- CREATE RULE xaction_immutable AS ON UPDATE TO xactions
-- 	WHERE OLD.xid <> NEW.xid OR OLD.id <> NEW.id
-- 	DO INSTEAD
-- 		UPDATE xactions SET
-- 			acct = NEW.acct,
-- 			amt  = NEW.amt
-- ;

-- XXXrcd: location is interesting.  Does this attach as a tag?
--         How precise do we do it?  Should we tag multiple times
--         for location, e.g. Europe/UK/London/Tower Hamlets?  Or
--         maybe we create longitude/lattitude and do an amazing
--         amount of work figuring it out.
-- XXXrcd: Can should entire xactions be tagged or their
--         constituent parts?
CREATE TABLE IF NOT EXISTS xaction_tags (
	book_id	VARCHAR NOT NULL,
	xid	INTEGER NOT NULL,
	tag	VARCHAR NOT NULL,

	FOREIGN KEY (book_id, xid) REFERENCES xactions(book_id, xid)
);
