-- SQL-owned Admin, Books, and Book-ACL page models and mutations.

-- One private identity directory supplies the same name, GitHub identity, and
-- lifecycle status to global administration and per-Book access pages.
CREATE OR REPLACE VIEW njord_control.principal_directory AS
SELECT
    principal.id AS principal_id,
    principal.database_role,
    COALESCE(principal.display_name, principal.database_role::TEXT) AS display_name,
    COALESCE(identity.provider_login, invitation.github_login) AS github_login,
    COALESCE(identity.provider_subject,
             invitation.invited_provider_subject) AS provider_subject,
    principal.disabled_at,
    CASE
        WHEN principal.disabled_at IS NOT NULL THEN 'disabled'
        WHEN identity.principal_id IS NOT NULL THEN 'active'
        WHEN invitation.revoked_at IS NOT NULL THEN 'revoked'
        WHEN invitation.accepted_at IS NULL
         AND invitation.expires_at <= CURRENT_TIMESTAMP THEN 'expired'
        WHEN invitation.principal_id IS NOT NULL
         AND invitation.accepted_at IS NULL
         AND invitation.revoked_at IS NULL THEN 'pending'
        ELSE 'direct'
    END AS status,
    administrator.principal_id IS NOT NULL AS global_administrator
FROM njord_control.principals AS principal
LEFT JOIN njord_control.principal_identities AS identity
  ON identity.principal_id = principal.id
LEFT JOIN njord_control.github_invitations AS invitation
  ON invitation.principal_id = principal.id
LEFT JOIN njord_control.global_administrators AS administrator
  ON administrator.principal_id = principal.id;

CREATE OR REPLACE VIEW njord_control.book_access_directory AS
SELECT
    membership.book_id,
    directory.*,
    membership.membership_role,
    levels.access_level
FROM njord_control.book_memberships AS membership
JOIN njord_control.principal_directory AS directory
  ON directory.principal_id = membership.principal_id
JOIN njord_control.access_levels AS levels
  ON levels.membership_role = membership.membership_role;

CREATE OR REPLACE FUNCTION njord_control.book_access_level(p_book_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
STABLE
AS $$
    SELECT access.access_level
    FROM njord_control.book_access_directory AS access
    WHERE access.book_id = p_book_id
      AND access.database_role = njord_control.invoking_database_role()
      AND access.disabled_at IS NULL;
$$;

CREATE OR REPLACE FUNCTION njord_control.can_administer_book(p_book_id VARCHAR)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT COALESCE(njord_control.book_access_level(p_book_id) = 'admin', FALSE);
$$;

CREATE OR REPLACE FUNCTION njord_control.can_administer_global()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM njord_control.principal_directory AS principal
        WHERE principal.database_role = njord_control.invoking_database_role()
          AND principal.global_administrator
          AND principal.disabled_at IS NULL
    );
$$;

CREATE OR REPLACE FUNCTION njord_control.require_global_administrator()
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT njord_control.can_administer_global() THEN
        RAISE EXCEPTION 'Global administrator access is required'
            USING ERRCODE = 'P0001', DETAIL = 'GLOBAL_ADMIN_REQUIRED';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION njord_control.require_book_administrator(
    p_book_id VARCHAR
)
RETURNS VOID
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF NOT njord_control.can_administer_book(p_book_id) THEN
        RAISE EXCEPTION 'Book administrator access is required'
            USING ERRCODE = 'P0001', DETAIL = 'BOOK_ADMIN_REQUIRED';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION api.shell_page(p_book_id VARCHAR DEFAULT NULL)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
    SELECT
	'book_option'::VARCHAR,
        1000 + row_number() OVER (ORDER BY books.name, books.id),
        books.id,
        jsonb_build_object(
            'id', books.id,
            'name', books.name,
            'reporting_asset', books.reporting_asset,
            'entity_type', books.entity_type,
            'access_level', access.access_level,
            'selected', books.id = p_book_id
        )
    FROM njord_control.books AS books
    JOIN njord_control.book_access_directory AS access
      ON access.book_id = books.id
     AND access.database_role = njord_control.invoking_database_role()
     AND access.disabled_at IS NULL
    WHERE books.provisioning_state = 'ready'
UNION ALL
    SELECT
        'admin_context'::VARCHAR,
        900::BIGINT,
        'global'::VARCHAR,
        jsonb_build_object(
            'can_administer_global', njord_control.can_administer_global()
        )
UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
$$;

-- Admin is a cluster-wide destination for facts which live outside every
-- Book database. It deliberately has no active-Book selection.
CREATE OR REPLACE FUNCTION api.admin_page()
RETURNS SETOF api.page_component
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM njord_control.require_global_administrator();

    RETURN QUERY
    SELECT
        'admin_context'::VARCHAR,
        900::BIGINT,
        'global'::VARCHAR,
        jsonb_build_object('can_administer_global', TRUE)
    UNION ALL
    SELECT
        'global_user'::VARCHAR,
        1000 + row_number() OVER (
            ORDER BY lower(principal.display_name),
                     principal.database_role::TEXT
        ),
        principal.principal_id::VARCHAR,
        jsonb_build_object(
            'principal_id', principal.principal_id,
            'database_role', principal.database_role,
            'display_name', principal.display_name,
            'github_login', principal.github_login,
            'provider_subject', principal.provider_subject,
            'status', principal.status,
            'book_count', (
                SELECT count(*)
                FROM njord_control.book_memberships AS membership
                WHERE membership.principal_id = principal.principal_id
            ),
	    'global_admin', principal.global_administrator,
	    'current_user', principal.database_role = njord_control.invoking_database_role(),
	    'enabled', principal.disabled_at IS NULL,
	    'can_change_enabled',
	        principal.database_role <> njord_control.invoking_database_role()
	        AND NOT principal.global_administrator,
	    'action_key', CASE WHEN principal.disabled_at IS NULL
	        THEN 'action.admin.disable-user'
	        ELSE 'action.admin.enable-user'
	    END,
	    'action_label', presentation.text(
	        CASE WHEN principal.disabled_at IS NULL
	            THEN 'action.admin.disable-user'
	            ELSE 'action.admin.enable-user'
	        END
	    )
	)
    FROM njord_control.principal_directory AS principal
    UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
END;
$$;

CREATE OR REPLACE FUNCTION api.invite_global_user(
    p_github_login TEXT,
    p_provider_subject BIGINT,
    p_display_name TEXT DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    prepared RECORD;
BEGIN
    PERFORM njord_control.require_global_administrator();

    SELECT * INTO prepared
    FROM njord_control.prepare_github_user(
        p_github_login,
        p_display_name,
        NULL,
        ARRAY[]::VARCHAR[],
        'viewer',
        p_provider_subject
    );

    RETURN QUERY SELECT
        'global_user_result'::VARCHAR,
        899::BIGINT,
        prepared.principal_id::VARCHAR,
        jsonb_build_object(
            'principal_id', prepared.principal_id,
            'database_role', prepared.database_role
        );
    RETURN QUERY SELECT * FROM api.admin_page();
END;
$$;

CREATE OR REPLACE FUNCTION api.set_global_user_enabled(
    p_principal_id UUID,
    p_enabled BOOLEAN
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    target RECORD;
BEGIN
    PERFORM njord_control.require_global_administrator();
    IF p_enabled IS NULL THEN
        RAISE EXCEPTION 'enabled state is required'
            USING ERRCODE = 'P0001', DETAIL = 'ENABLED_STATE_REQUIRED';
    END IF;

    SELECT principal.id, principal.database_role,
           administrator.principal_id IS NOT NULL AS global_admin
    INTO target
    FROM njord_control.principals AS principal
    LEFT JOIN njord_control.global_administrators AS administrator
      ON administrator.principal_id = principal.id
    WHERE principal.id = p_principal_id
    FOR UPDATE OF principal;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'global user does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'GLOBAL_USER_NOT_FOUND';
    END IF;
    IF target.database_role = njord_control.invoking_database_role() THEN
        RAISE EXCEPTION 'use another global administrator to change your own access'
            USING ERRCODE = 'P0001', DETAIL = 'CANNOT_CHANGE_OWN_ACCESS';
    END IF;
    IF target.global_admin AND NOT p_enabled THEN
        RAISE EXCEPTION 'global administrators must be removed from that role before disabling them'
            USING ERRCODE = 'P0001', DETAIL = 'GLOBAL_ADMINISTRATOR_ACTIVE';
    END IF;

    UPDATE njord_control.principals
    SET disabled_at = CASE WHEN p_enabled THEN NULL ELSE clock_timestamp() END
    WHERE id = p_principal_id
      AND (disabled_at IS NULL) = (NOT p_enabled);

    RETURN QUERY SELECT * FROM api.admin_page();
END;
$$;

-- Access control belongs to the cluster control database, not to an
-- individual ledger database.  The gateway composes these SQL-owned rows
-- with the selected Book's settings rows for a Book-management detail page.
CREATE OR REPLACE FUNCTION api.book_acl_page(p_book_id VARCHAR)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);

    RETURN QUERY
    SELECT
        'book_access_context'::VARCHAR,
        8000::BIGINT,
        p_book_id,
        jsonb_build_object(
            'book_id', p_book_id,
            'can_administer', TRUE,
            'current_access_level', 'admin'
        )
    UNION ALL
    SELECT
        'book_access_level_option'::VARCHAR,
        8010 + levels.row_order,
        levels.access_level,
        jsonb_build_object(
            'id', levels.access_level,
            'label', presentation.text(levels.semantic_key)
        )
    FROM njord_control.access_levels AS levels
    UNION ALL
    SELECT
        'book_access'::VARCHAR,
        8100 + row_number() OVER (
            ORDER BY lower(access.display_name), access.database_role::TEXT
        ),
        access.principal_id::TEXT,
        jsonb_build_object(
            'principal_id', access.principal_id,
            'database_role', access.database_role,
            'display_name', access.display_name,
            'github_login', access.github_login,
            'access_level', access.access_level,
            'status', access.status,
            'current_user', access.database_role = njord_control.invoking_database_role()
        )
    FROM njord_control.book_access_directory AS access
    WHERE access.book_id = p_book_id
    UNION ALL
    SELECT * FROM api.presentation_catalogue(NULL);
END;
$$;

-- Every ACL mutation returns its changed row first, followed by the refreshed
-- SQL-owned page. Keeping that response envelope here makes the three mutation
-- functions focus on authorization and state changes.
CREATE OR REPLACE FUNCTION njord_control.book_access_change_page(
    p_book_id VARCHAR,
    p_principal_id UUID,
    p_database_role NAME,
    p_access_level VARCHAR
)
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
AS $$
    SELECT
        'book_access_result'::VARCHAR,
        7999::BIGINT,
        p_principal_id::VARCHAR,
        jsonb_build_object(
            'principal_id', p_principal_id,
            'database_role', p_database_role,
            'access_level', p_access_level
        )
UNION ALL
    SELECT * FROM api.book_acl_page(p_book_id);
$$;

CREATE OR REPLACE FUNCTION api.invite_book_user(
    p_book_id VARCHAR,
    p_github_login TEXT,
    p_access_level VARCHAR,
    p_provider_subject BIGINT,
    p_display_name TEXT DEFAULT NULL
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    actor_principal_id UUID := njord_control.current_principal_id();
    prepared RECORD;
    membership_role VARCHAR := (
        SELECT levels.membership_role
        FROM njord_control.access_levels AS levels
        WHERE levels.access_level = lower(btrim(p_access_level))
    );
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);
    IF membership_role IS NULL THEN
        RAISE EXCEPTION 'access level must be RO, RW, or Admin'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_ACCESS_LEVEL';
    END IF;
    IF p_provider_subject IS NULL OR p_provider_subject <= 0 THEN
        RAISE EXCEPTION 'GitHub provider subject must be a positive numeric id'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_PROVIDER_SUBJECT';
    END IF;

    SELECT * INTO prepared
    FROM njord_control.prepare_github_user(
        p_github_login,
        p_display_name,
        NULL,
        ARRAY[]::VARCHAR[],
        membership_role,
        p_provider_subject
    );

    INSERT INTO njord_control.book_memberships AS membership (
        book_id, principal_id, membership_role, changed_by
    ) VALUES (
        p_book_id, prepared.principal_id, membership_role, actor_principal_id
    )
    ON CONFLICT ON CONSTRAINT book_memberships_pkey DO UPDATE SET
        membership_role = EXCLUDED.membership_role,
        changed_at = clock_timestamp(),
        changed_by = EXCLUDED.changed_by;

    RETURN QUERY SELECT *
    FROM njord_control.book_access_change_page(
        p_book_id, prepared.principal_id, prepared.database_role,
        lower(btrim(p_access_level))
    );
END;
$$;

CREATE OR REPLACE FUNCTION api.update_book_access(
    p_book_id VARCHAR,
    p_principal_id UUID,
    p_access_level VARCHAR
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    requested_role VARCHAR := (
        SELECT levels.membership_role
        FROM njord_control.access_levels AS levels
        WHERE levels.access_level = lower(btrim(p_access_level))
    );
    target_database_role NAME;
    actor_principal_id UUID := njord_control.current_principal_id();
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);
    IF requested_role IS NULL THEN
        RAISE EXCEPTION 'access level must be RO, RW, or Admin'
            USING ERRCODE = 'P0001', DETAIL = 'INVALID_ACCESS_LEVEL';
    END IF;

    SELECT principal.database_role INTO target_database_role
    FROM njord_control.book_memberships AS membership
    JOIN njord_control.principals AS principal
      ON principal.id = membership.principal_id
    WHERE membership.book_id = p_book_id
      AND membership.principal_id = p_principal_id
      AND principal.disabled_at IS NULL
    FOR UPDATE OF membership;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Book access entry does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'BOOK_ACCESS_NOT_FOUND';
    END IF;

    IF target_database_role = njord_control.invoking_database_role()
       AND requested_role <> 'owner' THEN
        RAISE EXCEPTION 'use another administrator to change your own access'
            USING ERRCODE = 'P0001', DETAIL = 'CANNOT_CHANGE_OWN_ACCESS';
    END IF;

    UPDATE njord_control.book_memberships
    SET membership_role = requested_role,
        changed_at = clock_timestamp(),
        changed_by = actor_principal_id
    WHERE book_id = p_book_id
      AND principal_id = p_principal_id;

    RETURN QUERY SELECT *
    FROM njord_control.book_access_change_page(
        p_book_id, p_principal_id, target_database_role,
        lower(btrim(p_access_level))
    );
END;
$$;

CREATE OR REPLACE FUNCTION api.remove_book_access(
    p_book_id VARCHAR,
    p_principal_id UUID
)
RETURNS SETOF api.page_component
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    target_database_role NAME;
BEGIN
    PERFORM njord_control.require_book_administrator(p_book_id);

    SELECT principal.database_role INTO target_database_role
    FROM njord_control.book_memberships AS membership
    JOIN njord_control.principals AS principal
      ON principal.id = membership.principal_id
    WHERE membership.book_id = p_book_id
      AND membership.principal_id = p_principal_id
    FOR UPDATE OF membership;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Book access entry does not exist'
            USING ERRCODE = 'PT404', DETAIL = 'BOOK_ACCESS_NOT_FOUND';
    END IF;

    IF target_database_role = njord_control.invoking_database_role() THEN
        RAISE EXCEPTION 'use another administrator to remove your own access'
            USING ERRCODE = 'P0001', DETAIL = 'CANNOT_REMOVE_OWN_ACCESS';
    END IF;

    DELETE FROM njord_control.book_memberships
    WHERE book_id = p_book_id
      AND principal_id = p_principal_id;

    RETURN QUERY SELECT *
    FROM njord_control.book_access_change_page(
        p_book_id, p_principal_id, target_database_role, NULL
    );
END;
$$;

CREATE OR REPLACE FUNCTION api.add_book_page()
RETURNS SETOF api.page_component
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
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
        10000 + row_number() OVER (ORDER BY assets.id),
        assets.id,
        jsonb_build_object('id', assets.id)
    FROM njord_control.assets AS assets
UNION ALL
    SELECT
        'book_entity_type_option'::VARCHAR,
        11000 + row_number() OVER (
            ORDER BY presentation.text('entity.' || entity_types.id)
        ),
        entity_types.id,
        jsonb_build_object(
            'id', entity_types.id,
            'label', presentation.text('entity.' || entity_types.id)
        )
    FROM njord_control.entity_types AS entity_types;
$$;
