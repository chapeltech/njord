-- Base jurisdiction packs are mutually exclusive and have explicit reporting-
-- asset eligibility. Extensions such as Panama property and Taiwan
-- manufacturing remain children of their base profile.
CREATE OR REPLACE VIEW njord.jurisdiction_reporting_assets AS
    SELECT *
    FROM (VALUES
	('uk'::VARCHAR, 'GBP'::VARCHAR,
	    'UK company profile requires a GBP-reporting book'::VARCHAR,
	    'uk_company_profile_gbp_reporting'::VARCHAR),
	('panama', 'PAB',
	    'Panama business profile requires a USD- or PAB-reporting book',
	    'panama_business_profile_reporting_asset'),
	('panama', 'USD',
	    'Panama business profile requires a USD- or PAB-reporting book',
	    'panama_business_profile_reporting_asset'),
	('taiwan', 'TWD',
	    '臺灣營業人必須使用 TWD 帳簿',
	    'taiwan_business_profile_reporting_asset')
    ) AS eligible(
	jurisdiction, reporting_asset, violation_message, constraint_name
    );

CREATE OR REPLACE VIEW njord.book_jurisdiction_profiles AS
    SELECT book_id, 'uk'::VARCHAR AS jurisdiction FROM uk_company_profiles
UNION ALL
    SELECT book_id, 'panama' FROM panama_business_profiles
UNION ALL
    SELECT book_id, 'taiwan' FROM taiwan_business_profiles;

-- A profile insert or move locks its target Book before foreign-key checks take
-- weaker row locks. Book updates already own that row lock. Deferred checks see
-- final transaction state, so replacing one pack may happen in either order.
CREATE OR REPLACE FUNCTION njord.enforce_jurisdiction_profile()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    checked_book_id VARCHAR;
    configured_jurisdiction VARCHAR;
    configured_profile_count INTEGER;
    business_packs_allowed BOOLEAN;
    checked_entity_type VARCHAR;
    checked_reporting_asset VARCHAR;
    violation_message VARCHAR;
    violation_constraint VARCHAR;
BEGIN
    IF TG_WHEN = 'BEFORE' THEN
	PERFORM 1 FROM books WHERE id = NEW.book_id FOR UPDATE;
	RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'books' THEN
	checked_book_id := NEW.id;
    ELSE
	checked_book_id := NEW.book_id;
    END IF;

    SELECT count(*), min(jurisdiction)
    INTO configured_profile_count, configured_jurisdiction
    FROM njord.book_jurisdiction_profiles
    WHERE book_id = checked_book_id;

    IF configured_profile_count > 1 THEN
	RAISE EXCEPTION 'book % has more than one jurisdiction profile',
	    checked_book_id
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'one_jurisdiction_profile_per_book';
    END IF;

    IF configured_profile_count = 0 THEN
	RETURN NEW;
    END IF;

    SELECT entity_types.allows_business_packs, books.entity_type,
	   books.reporting_asset
    INTO business_packs_allowed, checked_entity_type, checked_reporting_asset
    FROM books
    JOIN book_entity_types AS entity_types ON entity_types.id = books.entity_type
    WHERE books.id = checked_book_id;

    -- Missing Books are reported by the profile foreign keys.
    IF NOT FOUND THEN
	RETURN NEW;
    END IF;

    IF NOT business_packs_allowed THEN
	RAISE EXCEPTION 'book % entity type % does not allow business packs',
	    checked_book_id, checked_entity_type
	    USING ERRCODE = '23514',
		  CONSTRAINT = 'jurisdiction_profile_business_entity';
    END IF;

    IF NOT EXISTS (
	SELECT 1
	FROM njord.jurisdiction_reporting_assets AS eligible
	WHERE eligible.jurisdiction = configured_jurisdiction
	  AND eligible.reporting_asset = checked_reporting_asset
    ) THEN
	SELECT min(eligible.violation_message), min(eligible.constraint_name)
	INTO violation_message, violation_constraint
	FROM njord.jurisdiction_reporting_assets AS eligible
	WHERE eligible.jurisdiction = configured_jurisdiction;

	RAISE EXCEPTION '%', COALESCE(
	    violation_message,
	    format(
		'jurisdiction %s does not support reporting asset %s',
		configured_jurisdiction, checked_reporting_asset
	    )
	) USING ERRCODE = '23514',
		  CONSTRAINT = COALESCE(
		      violation_constraint,
		      'jurisdiction_profile_reporting_asset'
		  );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER uk_company_profile_serialize
    BEFORE INSERT OR UPDATE OF book_id ON uk_company_profiles
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();
CREATE CONSTRAINT TRIGGER uk_company_profile_validate
    AFTER INSERT OR UPDATE OF book_id ON uk_company_profiles
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();

CREATE TRIGGER panama_business_profile_serialize
    BEFORE INSERT OR UPDATE OF book_id ON panama_business_profiles
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();
CREATE CONSTRAINT TRIGGER panama_business_profile_validate
    AFTER INSERT OR UPDATE OF book_id ON panama_business_profiles
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();

CREATE TRIGGER taiwan_business_profile_serialize
    BEFORE INSERT OR UPDATE OF book_id ON taiwan_business_profiles
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();
CREATE CONSTRAINT TRIGGER taiwan_business_profile_validate
    AFTER INSERT OR UPDATE OF book_id ON taiwan_business_profiles
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();

CREATE CONSTRAINT TRIGGER books_validate_jurisdiction_profile
    AFTER UPDATE OF id, reporting_asset, entity_type ON books
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION njord.enforce_jurisdiction_profile();
