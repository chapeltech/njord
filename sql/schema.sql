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

CREATE TABLE IF NOT EXISTS accts (
	id	VARCHAR PRIMARY KEY,
	type	VARCHAR NOT NULL REFERENCES acct_types(id),
	atype	VARCHAR NOT NULL REFERENCES asset(id),
	pretax	NUMERIC(100,5) NOT NULL DEFAULT 1.0,
	comment	VARCHAR
);

CREATE TABLE IF NOT EXISTS xactions (
	xid	SERIAL PRIMARY KEY,
	date	TIMESTAMP NOT NULL,
	comment	VARCHAR
);

CREATE TABLE IF NOT EXISTS xaction_bits (
	id	SERIAL PRIMARY KEY,
	xid	INTEGER NOT NULL REFERENCES xactions(xid),
	acct	VARCHAR NOT NULL REFERENCES accts(id),
	amt	NUMERIC(100,5) NOT NULL,
	comment	VARCHAR
);

CREATE INDEX IF NOT EXISTS xaction_bits_xid	ON xaction_bits (xid);
CREATE INDEX IF NOT EXISTS xaction_bits_acct	ON xaction_bits (acct);

CREATE TABLE IF NOT EXISTS xaction_unresolved (
	xid	INTEGER PRIMARY KEY REFERENCES xactions(xid)
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
	xid	INTEGER NOT NULL REFERENCES xactions(xid),
	tag	VARCHAR NOT NULL
);
