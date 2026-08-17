-- Variable required from psql: book_id
DELETE FROM njord_control.books WHERE id = :'book_id';
