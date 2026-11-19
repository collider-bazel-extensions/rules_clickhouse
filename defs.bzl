"""Public API for rules_clickhouse.

  clickhouse_schema        ordered SQL migration files
  clickhouse_server        long-running `clickhouse server` on free loopback
                           ports, everything under $TEST_TMPDIR; runs the
                           migrations and seeds, then writes
                           $TEST_TMPDIR/<name>.env
  clickhouse_health_check  pairs with clickhouse_server for itest_service
  clickhouse_test          sh_test macro: auto-launched server + `ch` helpers
"""

load("//private:providers.bzl",
     _ClickHouseBinaryInfo = "ClickHouseBinaryInfo",
     _ClickHouseSchemaInfo = "ClickHouseSchemaInfo")
load("//private:schema.bzl", _clickhouse_schema = "clickhouse_schema")
load("//private:server.bzl",
     _ClickHouseServerInfo = "ClickHouseServerInfo",
     _clickhouse_health_check = "clickhouse_health_check",
     _clickhouse_server = "clickhouse_server")
load("//private:test.bzl", _clickhouse_test = "clickhouse_test")

clickhouse_schema = _clickhouse_schema
clickhouse_server = _clickhouse_server
clickhouse_health_check = _clickhouse_health_check
clickhouse_test = _clickhouse_test
ClickHouseBinaryInfo = _ClickHouseBinaryInfo
ClickHouseSchemaInfo = _ClickHouseSchemaInfo
ClickHouseServerInfo = _ClickHouseServerInfo
