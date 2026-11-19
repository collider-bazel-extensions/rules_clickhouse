#!/usr/bin/env bash
# clickhouse_test end to end: the env contract, migrations in order, seeds,
# and create / insert / query over both the native protocol (ch) and HTTP
# (ch_http).
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$CLICKHOUSE_TESTLIB"

# ---- the env contract (rules_openmeter reads these) ----
for v in CLICKHOUSE_HOST CLICKHOUSE_HTTP_PORT CLICKHOUSE_NATIVE_PORT CLICKHOUSE_NATIVE_ADDR \
         CLICKHOUSE_DATABASE CLICKHOUSE_USER CLICKHOUSE_HTTP_URL CLICKHOUSE_DSN \
         CLICKHOUSE_VERSION CLICKHOUSE_BIN CLICKHOUSE_CLIENT_CONFIG CLICKHOUSE_STATE_DIR \
         CLICKHOUSE_LOG CLICKHOUSE_ERROR_LOG CLICKHOUSE_CONTROL_URL CLICKHOUSE_TESTLIB; do
  [[ -n "${!v:-}" ]] || fail "$v not set"
done
[[ -v CLICKHOUSE_PASSWORD && -z "$CLICKHOUSE_PASSWORD" ]] || fail "CLICKHOUSE_PASSWORD should be set and empty"
[[ "$CLICKHOUSE_HOST" == 127.0.0.1 ]] || fail "host $CLICKHOUSE_HOST"
[[ "$CLICKHOUSE_HTTP_PORT" != "$CLICKHOUSE_NATIVE_PORT" ]] || fail "one port for both"
[[ "$CLICKHOUSE_NATIVE_ADDR" == "127.0.0.1:$CLICKHOUSE_NATIVE_PORT" ]] || fail "addr $CLICKHOUSE_NATIVE_ADDR"
[[ "$CLICKHOUSE_DATABASE" == analytics ]] || fail "database $CLICKHOUSE_DATABASE"
[[ "$CLICKHOUSE_USER" == default ]] || fail "user $CLICKHOUSE_USER"
[[ "$CLICKHOUSE_HTTP_URL" == "http://127.0.0.1:$CLICKHOUSE_HTTP_PORT" ]] || fail "url $CLICKHOUSE_HTTP_URL"
[[ "$CLICKHOUSE_DSN" == "clickhouse://default@127.0.0.1:$CLICKHOUSE_NATIVE_PORT/analytics" ]] || fail "dsn $CLICKHOUSE_DSN"
[[ "$CLICKHOUSE_STATE_DIR" == "$TEST_TMPDIR"/* ]] || fail "state dir outside TEST_TMPDIR: $CLICKHOUSE_STATE_DIR"
[[ "$(command -v clickhouse)" == "$CLICKHOUSE_BIN" ]] || fail "clickhouse not on PATH"
echo "ok: env ($CLICKHOUSE_DSN, $CLICKHOUSE_HTTP_URL)"

# ---- the pinned binary ----
[[ "$(ch "SELECT version()")" == "$CLICKHOUSE_VERSION" ]] || fail "version: $(ch "SELECT version()") != $CLICKHOUSE_VERSION"
[[ "$(ch "SELECT currentDatabase()")" == analytics ]] || fail "ch database"
[[ "$(ch "SELECT timezone()")" == UTC ]] || fail "server timezone not UTC"
echo "ok: ClickHouse $CLICKHOUSE_VERSION"

# ---- migrations, in order ----
[[ "$(ch "SELECT groupArray(step) FROM (SELECT step FROM migration_log ORDER BY step)")" == "[1,2,3]" ]] \
  || fail "migration_log: $(ch "SELECT * FROM migration_log")"
[[ "$(ch "SELECT total FROM usage WHERE subject = 'customer-1'")" == 3.5 ]] || fail "backfill/view"
echo "ok: migrations 001, 002, 003 applied in order"

# ---- seeds: .sql, then .csv (into events) ----
[[ "$(ch "SELECT count() FROM events WHERE subject = 'customer-2'")" == 1 ]] || fail "seed.sql not loaded"
[[ "$(ch "SELECT sum(value) FROM events WHERE subject = 'customer-3'")" == 300 ]] || fail "events.csv not loaded"
echo "ok: seeds"

# ---- create, insert, query: native ----
ch "CREATE TABLE t_native (id UInt32, name String) ENGINE = MergeTree ORDER BY id;
    INSERT INTO t_native VALUES (1, 'one'), (2, 'two');"
[[ "$(ch "SELECT name FROM t_native WHERE id = 2")" == two ]] || fail "native round trip"
ch <<'SQL'
INSERT INTO t_native VALUES (3, 'three');
INSERT INTO t_native VALUES (4, 'four');
SQL
[[ "$(ch --query "SELECT count() FROM t_native")" == 4 ]] || fail "ch from stdin"
[[ "$(ch --format CSV --query "SELECT id, name FROM t_native WHERE id = 1")" == '1,"one"' ]] || fail "ch client args"
echo "ok: native protocol"

# ---- create, insert, query: HTTP ----
ch_http "CREATE TABLE t_http (id UInt32, v Float64) ENGINE = MergeTree ORDER BY id"
ch_http "INSERT INTO t_http VALUES (1, 0.5), (2, 1.5)"
[[ "$(ch_http "SELECT sum(v) FROM t_http")" == 2 ]] || fail "HTTP round trip"
[[ "$(echo "SELECT count() FROM t_native" | ch_http)" == 4 ]] || fail "ch_http from stdin"
# Both protocols see the same data.
[[ "$(ch "SELECT sum(v) FROM t_http")" == 2 ]] || fail "native can't see HTTP's table"
[[ "$(ch_http "SELECT name FROM t_native WHERE id = 3")" == three ]] || fail "HTTP can't see native's table"
if ch_http "SELECT * FROM no_such_table" 2>"$TEST_TMPDIR/err"; then fail "bad query succeeded"; fi
grep -q "UNKNOWN_TABLE" "$TEST_TMPDIR/err" || fail "ch_http error: $(cat "$TEST_TMPDIR/err")"
echo "ok: HTTP"

# ---- ch_wait ----
( sleep 1; ch "INSERT INTO t_native VALUES (5, 'five')" ) &
ch_wait 5 "SELECT count() FROM t_native"
wait
echo "ok: ch_wait"

# ---- args ----
[[ "$#" == 2 && "$1" == one && "$2" == "two words" ]] || fail "args: $*"
echo "PASS"
