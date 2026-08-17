-- Test/demo-only compatibility for the intentionally all-in-one fixture.
-- Production Book databases do not own either unscoped page; control.sql does.

-- The fixture has no separate control database, so its one database owner is
-- the global administrator. Production Book shells deliberately omit this
-- control-owned authority.
ALTER FUNCTION api.shell_page(VARCHAR) RENAME TO book_shell_page;

CREATE OR REPLACE FUNCTION api.shell_page(p_book_id VARCHAR DEFAULT NULL)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.book_shell_page(p_book_id)
UNION ALL
    SELECT
	'admin_context'::VARCHAR,
	900::BIGINT,
	'global'::VARCHAR,
	jsonb_build_object('can_administer_global', TRUE);
$$;

CREATE OR REPLACE FUNCTION api.admin_page()
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT
	'global_user'::VARCHAR,
	1000::BIGINT,
	current_user::VARCHAR,
	jsonb_build_object(
	    'principal_id', current_user,
	    'database_role', current_user,
	    'display_name', current_user,
	    'github_login', NULL,
	    'provider_subject', NULL,
	    'status', 'direct',
	    'enabled', TRUE,
	    'can_change_enabled', FALSE,
	    'action_key', 'action.admin.disable-user',
	    'action_label', presentation.text('action.admin.disable-user'),
	    'book_count', (SELECT count(*) FROM public.books),
	    'global_admin', TRUE,
	    'current_user', TRUE
	)
UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
$$;

CREATE OR REPLACE FUNCTION api.add_book_page()
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT * FROM api.shell_page(NULL)
UNION ALL
    SELECT
	'page_context'::VARCHAR,
	9000::BIGINT,
	'add-book'::VARCHAR,
	jsonb_build_object(
	    'page', 'add-book',
	    'reporting_asset', 'GBP',
	    'entity_type', 'household',
	    'validation', jsonb_build_object(
		'id_required', TRUE,
		'name_required', TRUE,
		'entity_type_required', TRUE,
		'reporting_asset_required', TRUE
	    )
	)
UNION ALL
    SELECT
	'asset_option'::VARCHAR,
	10000 + row_number() OVER (ORDER BY asset.id),
	asset.id,
	jsonb_build_object('id', asset.id)
    FROM public.asset
UNION ALL
    SELECT
	'book_entity_type_option'::VARCHAR,
	11000 + row_number() OVER (
	    ORDER BY presentation.text('entity.' || book_entity_types.id)
	),
	book_entity_types.id,
	jsonb_build_object(
	    'id', book_entity_types.id,
	    'label', presentation.text('entity.' || book_entity_types.id)
	)
    FROM public.book_entity_types;
$$;
