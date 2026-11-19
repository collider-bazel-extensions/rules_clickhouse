-- 003 needs 002: writes the new column, and a view over it.
INSERT INTO events (namespace, type, subject, time, value) VALUES
    ('default', 'api_call', 'customer-1', '2026-01-01 00:00:00', 1),
    ('default', 'api_call', 'customer-1', '2026-01-01 00:01:00', 2.5);

CREATE VIEW usage AS
SELECT subject, sum(value) AS total FROM events GROUP BY subject;

INSERT INTO migration_log VALUES (3, 'backfill');
