"""Providers exposed by rules_clickhouse."""

ClickHouseBinaryInfo = provider(
    doc = "The ClickHouse toolchain: one multi-call `clickhouse` binary " +
          "(`clickhouse server`, `clickhouse client`, `clickhouse local`).",
    fields = {
        "version": "string: the pinned ClickHouse version, e.g. 26.9.32.8",
        "clickhouse": "File: the clickhouse binary",
        "files": "depset of File: everything a runfiles tree needs to run it",
    },
)

ClickHouseSchemaInfo = provider(
    doc = "An ordered list of SQL migration files (clickhouse_schema).",
    fields = {
        "migrations": "list of File: SQL files, in the order they are applied",
    },
)
