#!/usr/bin/env bash
# clickhouse_stop / clickhouse_start: clients fail while stopped; the server
# comes back on the same ports with its data; repeatable.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$CLICKHOUSE_TESTLIB"

ch "CREATE TABLE kept (k UInt32) ENGINE = MergeTree ORDER BY k; INSERT INTO kept VALUES (1), (2), (3);"
ch "CREATE TABLE gone (k UInt32) ENGINE = Memory; INSERT INTO gone VALUES (1);"
http=$CLICKHOUSE_HTTP_PORT native=$CLICKHOUSE_NATIVE_PORT

clickhouse_stop
rc=0; out=$(ch "SELECT 1" 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "server still answering after clickhouse_stop"
grep -q "Connection refused" <<<"$out" || fail "no connection error while stopped: $out"
rc=0; ch_http "SELECT 1" >/dev/null 2>&1 || rc=$?
[[ "$rc" != 0 ]] || fail "HTTP still answering after clickhouse_stop"
echo "ok: stopped; clients fail"

t=$(date +%s.%N)
clickhouse_start
echo "restart took $(python3 -c "print(round($(date +%s.%N) - $t, 2))")s"
clickhouse_start   # already running: no-op
[[ "$CLICKHOUSE_HTTP_PORT" == "$http" && "$CLICKHOUSE_NATIVE_PORT" == "$native" ]] || fail "ports changed"
[[ "$(ch "SELECT sum(k) FROM kept")" == 6 ]] || fail "MergeTree data lost: $(ch "SELECT sum(k) FROM kept" 2>&1)"
[[ "$(ch "SELECT count() FROM gone")" == 0 ]] || fail "Memory table survived"
[[ "$(ch_http "SELECT count() FROM migration_log")" == 3 ]] || fail "migrated tables lost"
[[ "$(ch "SELECT count() FROM migration_log")" == 3 ]] || fail "migrations ran again"
echo "ok: started again on $http/$native; MergeTree data kept, Memory table empty"

ch "INSERT INTO kept VALUES (4)"
clickhouse_stop && clickhouse_start
[[ "$(ch "SELECT sum(k) FROM kept")" == 10 ]] || fail "second restart"
echo "PASS"
