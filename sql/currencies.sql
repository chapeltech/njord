\ir asset-catalog.sql

INSERT INTO asset (id)
SELECT id FROM njord_asset_catalog;

-- Market rates are observations, not reference data. Production Books start
-- without invented prices; examples and tests insert their own dated rates.
