-- Variables required from psql: control_database, database_role
-- The public catalogue API is SECURITY DEFINER; its base tables remain private.
REVOKE CONNECT ON DATABASE :"control_database" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"control_database" TO :"database_role";
GRANT USAGE ON SCHEMA api, presentation TO :"database_role";
GRANT SELECT ON ALL TABLES IN SCHEMA presentation TO :"database_role";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA presentation TO :"database_role";
GRANT EXECUTE ON FUNCTION
    api.shell_page(VARCHAR),
    api.admin_page(),
    api.invite_global_user(TEXT, BIGINT, TEXT),
    api.set_global_user_enabled(UUID, BOOLEAN),
    api.book_acl_page(VARCHAR),
    api.add_book_page(),
    api.presentation_catalogue(VARCHAR),
    api.create_book(VARCHAR, VARCHAR, VARCHAR, BOOLEAN, VARCHAR),
    api.invite_book_user(VARCHAR, TEXT, VARCHAR, BIGINT, TEXT),
    api.update_book_access(VARCHAR, UUID, VARCHAR),
    api.remove_book_access(VARCHAR, UUID)
TO :"database_role";
