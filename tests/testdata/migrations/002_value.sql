-- 002 needs 001: adds a column to events.
ALTER TABLE events ADD COLUMN value Float64 DEFAULT 0;
INSERT INTO migration_log VALUES (2, 'value');
