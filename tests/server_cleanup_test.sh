#!/usr/bin/env bash
# clickhouse_test's trampoline stops ClickHouse when the test ends: run it to
# completion (in its own session, so nothing else kills its children), then
# check the ports it recorded are closed.
#
# Argv: <trampoline> <record_port server> <record_port inner> <testlib.sh>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

export RECORD_FILE="$TEST_TMPDIR/ports"
inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
TEST_TMPDIR="$inner_tmp" setsid "$TEST_SRCDIR/_main/$1" "$2" "$3" record_port_clickhouse "$4" \
  || fail "trampoline exited $?"
read -r http native < "$RECORD_FILE"
[[ -n "$http" && -n "$native" ]] || fail "no ports recorded"
for port in "$http" "$native"; do
  for _ in $(seq 1 100); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || continue 2
    sleep 0.1
  done
  fail "ClickHouse still listening on $port after the test ended"
done
pidf="$inner_tmp/clickhouse-record_port_clickhouse/clickhouse-server.pid"
if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then fail "clickhouse server still running"; fi
echo "PASS: ClickHouse on $http/$native stopped"
