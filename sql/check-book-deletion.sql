-- Variables required from psql: book_id, confirm_name
-- The book-local function is the authoritative guard shared with the web
-- gateway. It verifies database identity, archive state, and exact display name.
SELECT api.authorize_book_database_deletion(:'book_id', :'confirm_name');
