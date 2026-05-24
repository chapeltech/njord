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

CREATE TABLE IF NOT EXISTS accts (
	book_id	VARCHAR NOT NULL REFERENCES books(id),
	id	VARCHAR NOT NULL,
	type	VARCHAR NOT NULL REFERENCES acct_types(id),
	atype	VARCHAR NOT NULL REFERENCES asset(id),
	pretax	NUMERIC(100,5) NOT NULL DEFAULT 1.0,
	comment	VARCHAR,

	PRIMARY KEY (book_id, id)
);

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
