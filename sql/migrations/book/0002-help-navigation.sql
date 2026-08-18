-- Keep application chrome database-owned on existing Book databases.
INSERT INTO presentation.messages (locale, semantic_key, display_text)
VALUES
    ('en-GB', 'nav.help', 'Help'),
    ('es-PA', 'nav.help', 'Ayuda'),
    ('zh-TW', 'nav.help', '說明')
ON CONFLICT (locale, semantic_key) DO UPDATE
SET display_text = EXCLUDED.display_text;
