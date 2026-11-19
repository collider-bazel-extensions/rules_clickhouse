-- A good statement, then one ClickHouse refuses.
INSERT INTO migration_log VALUES (2, 'before the error');

ALTER TABLE events ADD COLUMN value NoSuchType;

INSERT INTO migration_log VALUES (3, 'never runs');
