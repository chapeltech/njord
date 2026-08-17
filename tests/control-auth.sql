\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

SET client_min_messages TO warning;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(label TEXT, ok BOOLEAN)
RETURNS TEXT AS $$
BEGIN
    IF NOT COALESCE(ok, FALSE) THEN
        RAISE EXCEPTION 'not ok - %', label;
    END IF;
    RETURN 'ok - ' || label;
END;
$$ LANGUAGE plpgsql;

-- Membership tests create real cluster roles. Derive their names from the
-- disposable control database so parallel and interrupted runs cannot touch a
-- developer's ordinary roles.
CREATE OR REPLACE FUNCTION pg_temp.test_role(stem TEXT)
RETURNS TEXT AS $$
    SELECT stem || '-' || substr(md5(current_database()), 1, 8);
$$ LANGUAGE SQL STABLE;

SELECT pg_temp.assert_true(
    'GitHub logins normalize to lowercase PostgreSQL role names',
    njord_control.normalize_github_login('  Elric1  ') = 'elric1'
);

DO $$
DECLARE
    error_detail TEXT;
BEGIN
    BEGIN
        PERFORM njord_control.normalize_github_login('-not-valid');
        RAISE EXCEPTION 'invalid GitHub login was accepted';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'INVALID_GITHUB_LOGIN' THEN
            RAISE;
        END IF;
    END;

    BEGIN
        PERFORM * FROM njord_control.authenticate_github_identity(
            1000001, 'not-invited', 'Uninvited User'
        );
        RAISE EXCEPTION 'uninvited GitHub identity was accepted';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'GITHUB_IDENTITY_NOT_INVITED' THEN
            RAISE;
        END IF;
    END;
END;
$$;

SELECT * FROM njord_control.invite_github_identity(
    pg_temp.test_role('elric1'), clock_timestamp() + INTERVAL '1 day'
);

CREATE TEMP TABLE accepted_identity AS
SELECT * FROM njord_control.authenticate_github_identity(
    1000002, pg_temp.test_role('elric1'), 'Elric Example'
);

SELECT pg_temp.assert_true(
    'an invited GitHub identity creates a principal named after its login',
    (SELECT database_role::TEXT = pg_temp.test_role('elric1') AND identity_created
     FROM accepted_identity)
    AND EXISTS (
        SELECT 1
        FROM njord_control.github_invitations AS invitation
        JOIN njord_control.principal_identities AS identity
          ON identity.principal_id = invitation.principal_id
        WHERE invitation.github_login = pg_temp.test_role('elric1')
          AND identity.provider_subject = 1000002
          AND invitation.accepted_at IS NOT NULL
    )
);

CREATE TEMP TABLE returning_identity AS
SELECT * FROM njord_control.authenticate_github_identity(
    1000002, pg_temp.test_role('elric-renamed'), 'Elric Renamed'
);

SELECT pg_temp.assert_true(
    'the immutable numeric subject survives a GitHub login rename',
    (SELECT database_role::TEXT = pg_temp.test_role('elric1') AND NOT identity_created
     FROM returning_identity)
    AND EXISTS (
        SELECT 1
        FROM njord_control.principal_identities
        WHERE provider_subject = 1000002
          AND provider_login = pg_temp.test_role('elric-renamed')
    )
);

BEGIN;
INSERT INTO njord_control.books (
    id, name, reporting_asset, provisioning_state
) VALUES (
    'shared-demo', 'Shared demo', 'GBP', 'ready'
);
INSERT INTO njord_control.book_memberships (
    book_id, principal_id, membership_role
)
SELECT 'shared-demo', principal_id, 'owner'
FROM accepted_identity;
COMMIT;

DO $$
DECLARE
    access_role NAME := njord_control.book_access_role('shared-demo', 'ro');
    parent_role NAME := pg_temp.test_role('cap-parent')::NAME;
    error_detail TEXT;
BEGIN
    BEGIN
        EXECUTE format('ALTER ROLE %I INHERIT', access_role);
        PERFORM njord_control.ensure_book_access_roles('shared-demo');
        RAISE EXCEPTION 'an inheriting capability role was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'UNSAFE_BOOK_ACCESS_ROLE' THEN RAISE; END IF;
    END;

    EXECUTE format('CREATE ROLE %I NOLOGIN NOINHERIT', parent_role);
    BEGIN
        EXECUTE format('GRANT %I TO %I', parent_role, access_role);
        PERFORM njord_control.ensure_book_access_roles('shared-demo');
        RAISE EXCEPTION 'a capability role with inherited parents was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'UNSAFE_BOOK_ACCESS_ROLE' THEN RAISE; END IF;
    END;
    EXECUTE format('DROP ROLE %I', parent_role);
END;
$$;

DO $$
DECLARE
    member_role NAME := pg_temp.test_role('privileged-child')::NAME;
    parent_role NAME := pg_temp.test_role('privileged-parent')::NAME;
    error_detail TEXT;
BEGIN
    EXECUTE format('CREATE ROLE %I LOGIN', member_role);
    EXECUTE format('CREATE ROLE %I NOLOGIN CREATEROLE', parent_role);
    EXECUTE format('GRANT %I TO %I', parent_role, member_role);

    BEGIN
        PERFORM njord_control.set_book_role_membership(
            'shared-demo', member_role, 'reader'
        );
        RAISE EXCEPTION 'a Book member with a privileged parent was accepted';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'PRIVILEGED_BOOK_MEMBER_ROLE' THEN RAISE; END IF;
    END;

    EXECUTE format('REVOKE %I FROM %I', parent_role, member_role);
    EXECUTE format('DROP ROLE %I', member_role);
    EXECUTE format('DROP ROLE %I', parent_role);
EXCEPTION WHEN OTHERS THEN
    BEGIN
        EXECUTE format('REVOKE %I FROM %I', parent_role, member_role);
    EXCEPTION WHEN undefined_object THEN NULL;
    END;
    BEGIN
        EXECUTE format('DROP ROLE %I', member_role);
    EXCEPTION WHEN undefined_object THEN NULL;
    END;
    BEGIN
        EXECUTE format('DROP ROLE %I', parent_role);
    EXCEPTION WHEN undefined_object THEN NULL;
    END;
    RAISE;
END;
$$;

BEGIN;
INSERT INTO njord_control.books (
    id, name, reporting_asset, provisioning_state
) VALUES
    ('owner-source', 'Owner source', 'GBP', 'ready'),
    ('owner-target', 'Owner target', 'GBP', 'ready');
INSERT INTO njord_control.principals (database_role)
VALUES (pg_temp.test_role('move-owner')), (pg_temp.test_role('target-owner'));
INSERT INTO njord_control.book_memberships (
    book_id, principal_id, membership_role
)
SELECT 'owner-source', id, 'owner'
FROM njord_control.principals
WHERE database_role = pg_temp.test_role('move-owner')
UNION ALL
SELECT 'owner-target', id, 'owner'
FROM njord_control.principals
WHERE database_role = pg_temp.test_role('target-owner');
COMMIT;

DO $$
DECLARE
    error_constraint TEXT;
BEGIN
    BEGIN
        UPDATE njord_control.book_memberships
        SET book_id = 'owner-target'
        WHERE book_id = 'owner-source';
        SET CONSTRAINTS njord_control.memberships_require_book_owner IMMEDIATE;
        RAISE EXCEPTION 'moving the final owner was allowed';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS error_constraint = CONSTRAINT_NAME;
        IF error_constraint <> 'book_requires_owner' THEN
            RAISE;
        END IF;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'moving a membership cannot leave its old Book ownerless',
    EXISTS (
        SELECT 1 FROM njord_control.book_memberships
        WHERE book_id = 'owner-source' AND membership_role = 'owner'
    )
);

CREATE TEMP TABLE revoked_friend AS
SELECT * FROM njord_control.prepare_github_user(
    pg_temp.test_role('revoked-friend'), 'Revoked Friend',
    clock_timestamp() + INTERVAL '1 day',
    ARRAY['shared-demo']::VARCHAR[], 'editor', 1000006
);

SELECT pg_temp.assert_true(
    'a prepared invitation can be revoked',
    njord_control.revoke_github_invitation(pg_temp.test_role('revoked-friend'))
);

SELECT pg_temp.assert_true(
    'revoking a prepared invitation removes provisional direct and Book access',
    EXISTS (
        SELECT 1
        FROM njord_control.github_invitations AS invitation
        JOIN revoked_friend USING (principal_id)
        WHERE invitation.revoked_at IS NOT NULL
    )
    AND EXISTS (
        SELECT 1
        FROM njord_control.principals AS principal
        JOIN revoked_friend ON revoked_friend.principal_id = principal.id
        JOIN pg_roles AS role ON role.rolname = principal.database_role
        WHERE principal.disabled_at IS NOT NULL AND NOT role.rolcanlogin
    )
    AND NOT EXISTS (
        SELECT 1
        FROM njord_control.book_memberships AS membership
        JOIN revoked_friend USING (principal_id)
    )
);

INSERT INTO njord_control.book_memberships (
    book_id, principal_id, membership_role
)
SELECT 'shared-demo', principal_id, 'viewer' FROM revoked_friend;

SELECT pg_temp.assert_true(
    'catalogue edits cannot regrant a disabled principal physical Book access',
    EXISTS (
        SELECT 1 FROM njord_control.book_memberships AS membership
        JOIN revoked_friend USING (principal_id)
        WHERE membership.book_id = 'shared-demo'
    )
    AND NOT EXISTS (
        SELECT 1
        FROM pg_auth_members AS membership
        JOIN pg_roles AS member ON member.oid = membership.member
        JOIN revoked_friend ON revoked_friend.database_role = member.rolname
        JOIN pg_roles AS granted ON granted.oid = membership.roleid
        WHERE granted.rolname = njord_control.book_access_role(
            'shared-demo', 'ro'
        )
    )
);

DELETE FROM njord_control.book_memberships
WHERE principal_id = (SELECT principal_id FROM revoked_friend);

CREATE TEMP TABLE prepared_friend AS
SELECT * FROM njord_control.prepare_github_user(
    pg_temp.test_role('some-friend'), 'Some Friend',
    clock_timestamp() + INTERVAL '1 day',
    ARRAY['shared-demo']::VARCHAR[], 'editor', 1000003
);

SELECT pg_temp.assert_true(
    'administrative preparation binds an invitation and Book memberships',
    (SELECT database_role::TEXT = pg_temp.test_role('some-friend')
         AND github_login = pg_temp.test_role('some-friend')
         AND invited_provider_subject = 1000003
         AND membership_role = 'editor'
         AND book_ids = ARRAY['shared-demo']::VARCHAR[]
     FROM prepared_friend)
    AND EXISTS (
        SELECT 1
        FROM njord_control.github_invitations AS invitation
        JOIN prepared_friend
          ON prepared_friend.principal_id = invitation.principal_id
        WHERE invitation.github_login = pg_temp.test_role('some-friend')
    )
    AND EXISTS (
        SELECT 1
        FROM njord_control.book_memberships AS membership
        JOIN prepared_friend
          ON prepared_friend.principal_id = membership.principal_id
        WHERE membership.book_id = 'shared-demo'
          AND membership.membership_role = 'editor'
    )
);

UPDATE njord_control.github_invitations
SET invited_at = clock_timestamp() - INTERVAL '2 days',
    expires_at = clock_timestamp() - INTERVAL '1 day'
WHERE github_login = pg_temp.test_role('some-friend');

SELECT pg_temp.assert_true(
    'expired GitHub invitations are not presented as pending',
    (SELECT status = 'expired'
     FROM njord_control.principal_directory
     WHERE database_role = pg_temp.test_role('some-friend'))
);

UPDATE njord_control.github_invitations
SET expires_at = clock_timestamp() + INTERVAL '1 day'
WHERE github_login = pg_temp.test_role('some-friend');

INSERT INTO njord_control.principals (database_role, display_name)
VALUES (pg_temp.test_role('existing-owner'), 'Existing Owner');
INSERT INTO njord_control.book_memberships (
    book_id, principal_id, membership_role
)
SELECT 'shared-demo', id, 'owner'
FROM njord_control.principals
WHERE database_role = pg_temp.test_role('existing-owner');

SELECT * FROM njord_control.prepare_github_user(
    pg_temp.test_role('existing-owner'), 'Existing Owner',
    clock_timestamp() + INTERVAL '1 day',
    ARRAY['shared-demo']::VARCHAR[], 'editor', 1000005
);

SELECT pg_temp.assert_true(
    'inviting an existing Book owner does not downgrade ownership',
    EXISTS (
        SELECT 1
        FROM njord_control.book_memberships AS membership
        JOIN njord_control.principals AS principal
          ON principal.id = membership.principal_id
        WHERE membership.book_id = 'shared-demo'
          AND principal.database_role = pg_temp.test_role('existing-owner')
          AND membership.membership_role = 'owner'
    )
);

DO $$
DECLARE
    error_detail TEXT;
BEGIN
    BEGIN
        PERFORM * FROM njord_control.authenticate_github_identity(
            1000004, pg_temp.test_role('some-friend'),
            'Wrong numeric identity'
        );
        RAISE EXCEPTION 'login-only invitation accepted the wrong numeric identity';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'GITHUB_IDENTITY_NOT_INVITED' THEN
            RAISE;
        END IF;
    END;
END;
$$;

DO $$
DECLARE
    error_constraint TEXT;
BEGIN
    BEGIN
        UPDATE njord_control.principals
        SET database_role = pg_temp.test_role('renamed-illegally')::NAME
        WHERE id = (SELECT principal_id FROM accepted_identity);
        RAISE EXCEPTION 'a principal database role was renamed in the catalogue';
    EXCEPTION WHEN check_violation THEN
        GET STACKED DIAGNOSTICS error_constraint = CONSTRAINT_NAME;
        IF error_constraint <> 'principal_database_role_immutable' THEN
            RAISE;
        END IF;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    'an anchored invitation accepts only the resolved numeric GitHub id',
    EXISTS (
        SELECT 1
        FROM njord_control.authenticate_github_identity(
            1000003, pg_temp.test_role('some-friend'), 'Some Friend'
        )
        WHERE database_role::TEXT = pg_temp.test_role('some-friend')
          AND identity_created
    )
);

CREATE TEMP TABLE prepared_active_friend AS
SELECT * FROM njord_control.prepare_github_user(
    pg_temp.test_role('some-friend'), 'Some Friend', NULL,
    ARRAY[]::VARCHAR[], 'viewer', 1000003
);

SELECT pg_temp.assert_true(
    'an active numeric GitHub identity can be prepared for more access',
    (SELECT database_role = pg_temp.test_role('some-friend')::NAME
     FROM prepared_active_friend)
    AND (SELECT principal_id FROM prepared_active_friend) = (
        SELECT principal_id
        FROM njord_control.principal_identities
        WHERE provider_subject = 1000003
    )
);

SELECT format(
    'GRANT %I TO %I', friend.database_role, settings.authenticator_role
)
FROM prepared_active_friend AS friend
CROSS JOIN njord_control.settings AS settings
WHERE settings.singleton
\gexec

UPDATE njord_control.principals
SET disabled_at = clock_timestamp()
WHERE id = (SELECT principal_id FROM prepared_active_friend);

SELECT pg_temp.assert_true(
    'disabling a principal revokes LOGIN, Book roles, and authenticator SET ROLE',
    EXISTS (
        SELECT 1
        FROM prepared_active_friend AS friend
        JOIN pg_roles AS role ON role.rolname = friend.database_role
        WHERE NOT role.rolcanlogin
    )
    AND NOT EXISTS (
        SELECT 1
        FROM prepared_active_friend AS friend
        JOIN pg_roles AS role ON role.rolname = friend.database_role
        JOIN pg_auth_members AS membership ON membership.roleid = role.oid
        JOIN njord_control.settings AS settings ON settings.singleton
        JOIN pg_roles AS authenticator
          ON authenticator.rolname = settings.authenticator_role
         AND authenticator.oid = membership.member
    )
    AND NOT EXISTS (
        SELECT 1
        FROM prepared_active_friend AS friend
        JOIN pg_roles AS member ON member.rolname = friend.database_role
        JOIN pg_auth_members AS membership ON membership.member = member.oid
        JOIN pg_roles AS granted ON granted.oid = membership.roleid
        WHERE granted.rolname = njord_control.book_access_role(
            'shared-demo', 'rw'
        )
    )
);

UPDATE njord_control.principals
SET disabled_at = NULL
WHERE id = (SELECT principal_id FROM prepared_active_friend);

SELECT pg_temp.assert_true(
    're-enabling a principal restores LOGIN, catalogue Book roles, and authenticator SET ROLE',
    EXISTS (
        SELECT 1
        FROM prepared_active_friend AS friend
        JOIN pg_roles AS role ON role.rolname = friend.database_role
        WHERE role.rolcanlogin
    )
    AND EXISTS (
        SELECT 1
        FROM prepared_active_friend AS friend
        JOIN pg_roles AS role ON role.rolname = friend.database_role
        JOIN pg_auth_members AS membership ON membership.roleid = role.oid
        JOIN njord_control.settings AS settings ON settings.singleton
        JOIN pg_roles AS authenticator
          ON authenticator.rolname = settings.authenticator_role
         AND authenticator.oid = membership.member
    )
    AND EXISTS (
        SELECT 1
        FROM prepared_active_friend AS friend
        JOIN pg_roles AS member ON member.rolname = friend.database_role
        JOIN pg_auth_members AS membership ON membership.member = member.oid
        JOIN pg_roles AS granted ON granted.oid = membership.roleid
        WHERE granted.rolname = njord_control.book_access_role(
            'shared-demo', 'rw'
        )
    )
);

DO $$
DECLARE
    error_detail TEXT;
BEGIN
    BEGIN
        UPDATE njord_control.principal_identities
        SET provider_subject = 9999999
        WHERE provider_subject = 1000002;
        RAISE EXCEPTION 'external identity was reassigned';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'IDENTITY_MAPPING_IMMUTABLE' THEN
            RAISE;
        END IF;
    END;
END;
$$;

INSERT INTO njord_control.web_sessions (
    token_hash, principal_id, created_at, last_seen_at, expires_at, revoked_at
)
SELECT repeat('03', 32), principal_id,
       clock_timestamp() - INTERVAL '40 days',
       clock_timestamp() - INTERVAL '40 days',
       clock_timestamp() - INTERVAL '35 days', NULL::TIMESTAMPTZ
FROM accepted_identity
UNION ALL
SELECT repeat('04', 32), principal_id,
       clock_timestamp() - INTERVAL '2 days',
       clock_timestamp() - INTERVAL '2 days',
       clock_timestamp() - INTERVAL '1 day', NULL
FROM accepted_identity;

CREATE TEMP TABLE created_session AS
SELECT * FROM njord_control.create_web_session(
    (SELECT principal_id FROM accepted_identity),
    repeat('01', 32),
    clock_timestamp() + INTERVAL '7 days'
);

SELECT pg_temp.assert_true(
    'only a token hash is stored for an active session',
    (SELECT database_role::TEXT = pg_temp.test_role('elric1')
     FROM created_session)
    AND EXISTS (
        SELECT 1
        FROM njord_control.web_sessions
        WHERE token_hash = repeat('01', 32)
    )
    AND (
        SELECT database_role::TEXT = pg_temp.test_role('elric1')
           AND provider_subject = 1000002
	FROM njord_control.resolve_web_session(repeat('01', 32))
    )
    AND NOT EXISTS (
        SELECT 1 FROM njord_control.web_sessions
        WHERE token_hash = repeat('03', 32)
    )
    AND EXISTS (
        SELECT 1 FROM njord_control.web_sessions
        WHERE token_hash = repeat('04', 32)
    )
);

SELECT pg_temp.assert_true(
    'logout revokes the session immediately',
    njord_control.revoke_web_session(repeat('01', 32))
    AND NOT EXISTS (
        SELECT 1
        FROM njord_control.resolve_web_session(repeat('01', 32))
    )
);

INSERT INTO njord_control.web_sessions (
    token_hash, principal_id, created_at, last_seen_at, expires_at
)
SELECT repeat('02', 32), principal_id,
       clock_timestamp() - INTERVAL '2 days',
       clock_timestamp() - INTERVAL '2 days',
       clock_timestamp() - INTERVAL '1 day'
FROM accepted_identity;

CREATE TEMP TABLE pruned_sessions AS
SELECT njord_control.prune_web_sessions() AS count;

SELECT pg_temp.assert_true(
    'session creation retains 30 days of audit history and explicit pruning removes it',
    (SELECT count = 3 FROM pruned_sessions)
    AND NOT EXISTS (SELECT 1 FROM njord_control.web_sessions)
);

DO $$
DECLARE
    original_max_books INTEGER;
    error_detail TEXT;
BEGIN
    BEGIN
        DELETE FROM njord_control.settings WHERE singleton;
        RAISE EXCEPTION 'the control settings singleton was deleted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    SELECT max_books INTO original_max_books
    FROM njord_control.settings WHERE singleton;

    UPDATE njord_control.settings
    SET max_books = (SELECT count(*) FROM njord_control.books)
    WHERE singleton;

    BEGIN
        PERFORM * FROM api.create_book(
            'over-capacity', 'Over capacity', 'GBP', TRUE, 'household'
        );
        RAISE EXCEPTION 'the configured Book capacity was exceeded';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'BOOK_LIMIT_REACHED' THEN RAISE; END IF;
    END;

    UPDATE njord_control.settings SET max_books = original_max_books
    WHERE singleton;
END;
$$;

DO $$
DECLARE
    error_detail TEXT;
BEGIN
    BEGIN
        PERFORM * FROM njord_control.create_web_session(
            (SELECT principal_id FROM accepted_identity),
            'raw-cookie-value',
            clock_timestamp() + INTERVAL '1 day'
        );
        RAISE EXCEPTION 'an unhashed session token was accepted';
    EXCEPTION WHEN SQLSTATE 'P0001' THEN
        GET STACKED DIAGNOSTICS error_detail = PG_EXCEPTION_DETAIL;
        IF error_detail <> 'INVALID_SESSION_TOKEN_HASH' THEN
            RAISE;
        END IF;
    END;
END;
$$;

-- Leave the shared cluster as clean as the disposable control catalogue. Book
-- deletion removes the capability roles; the remaining test principals and
-- LOGIN roles have no product grants after their fixtures are gone.
DELETE FROM njord_control.books
WHERE id IN ('shared-demo', 'owner-source', 'owner-target');

DELETE FROM njord_control.github_invitations
WHERE github_login IN (
    pg_temp.test_role('elric1'),
    pg_temp.test_role('some-friend'),
	pg_temp.test_role('existing-owner'),
	pg_temp.test_role('revoked-friend')
);

DELETE FROM njord_control.principals
WHERE database_role::TEXT IN (
    pg_temp.test_role('elric1'),
    pg_temp.test_role('some-friend'),
    pg_temp.test_role('move-owner'),
	pg_temp.test_role('target-owner'),
	pg_temp.test_role('existing-owner'),
	pg_temp.test_role('revoked-friend')
);

DO $$
DECLARE
    stem TEXT;
    role_name TEXT;
BEGIN
    FOREACH stem IN ARRAY ARRAY[
        'elric1', 'some-friend', 'move-owner',
	'target-owner', 'existing-owner', 'revoked-friend'
    ] LOOP
        role_name := pg_temp.test_role(stem);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name) THEN
            EXECUTE format('DROP ROLE %I', role_name);
        END IF;
    END LOOP;
END;
$$;
