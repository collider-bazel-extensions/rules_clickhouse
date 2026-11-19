-- 001: the events table (OpenMeter-shaped: a namespace, a type, a subject, a time).
CREATE TABLE events
(
    namespace String,
    type      LowCardinality(String),
    subject   String,
    time      DateTime64(3, 'UTC')
)
ENGINE = MergeTree
ORDER BY (namespace, type, subject, time);

CREATE TABLE migration_log (step UInt8, note String) ENGINE = MergeTree ORDER BY step;
INSERT INTO migration_log VALUES (1, 'events');
