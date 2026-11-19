#!/usr/bin/env bash
# clickhouse_server run directly (as rules_itest runs it): the env file
# appears once ready; the caller's CLICKHOUSE_* variables don't leak into
# the server or the launcher's clients; SIGTERM stops it, exit 0, env file
# removed, ports closed.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

SERVER="$TEST_SRCDIR/_main/$1"
env_file="$TEST_TMPDIR/test_server.env"
rm -f "$env_file"
start=$(date +%s.%N)
CLICKHOUSE_HOST=192.0.2.1 CLICKHOUSE_USER=nobody CLICKHOUSE_PASSWORD=wrong CLICKHOUSE_CONFIG=/nonexistent.xml \
  CLICKHOUSE_WATCHDOG_ENABLE=1 "$SERVER" 2>"$TEST_TMPDIR/launcher.log" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 1200); do [[ -f "$env_file" ]] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
[[ -f "$env_file" ]] || { cat "$TEST_TMPDIR/launcher.log" >&2; fail "env file not written"; }
echo "env file after $(python3 -c "print(round($(date +%s.%N) - $start, 2))")s"
cat "$TEST_TMPDIR/launcher.log"
set -a; source "$env_file"; set +a
q() { "$CLICKHOUSE_BIN" client -C "$CLICKHOUSE_CLIENT_CONFIG" --database "$CLICKHOUSE_DATABASE" --query "$1"; }
[[ "$(q "SELECT count() FROM migration_log")" == 3 ]] || fail "not migrated"
[[ "$(q "SELECT value FROM system.server_settings WHERE name = 'max_concurrent_queries'")" == 7 ]] || fail "extra_args"
# No watchdog: the pid file names the server itself, a child of the launcher.
spid=$(cat "$CLICKHOUSE_STATE_DIR/clickhouse-server.pid")
[[ "$(ps -o ppid= -p "$spid" | tr -d ' ')" == "$pid" ]] || fail "server $spid is not the launcher's child (watchdog?)"
grep -q "ClickHouse $CLICKHOUSE_VERSION ready on 127.0.0.1: HTTP $CLICKHOUSE_HTTP_PORT, native $CLICKHOUSE_NATIVE_PORT, database test; started in" \
  "$TEST_TMPDIR/launcher.log" || fail "no ready line"
echo "ok: ready, migrated, configured; caller's CLICKHOUSE_* ignored"

kill -TERM "$pid"
rc=0; wait "$pid" || rc=$?
trap - EXIT
[[ "$rc" == 0 ]] || fail "SIGTERM exit status $rc"
[[ ! -f "$env_file" ]] || fail "env file left after SIGTERM"
kill -0 "$spid" 2>/dev/null && fail "clickhouse server $spid still running"
for port in "$CLICKHOUSE_HTTP_PORT" "$CLICKHOUSE_NATIVE_PORT"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "port $port still open"; fi
done
echo "ok: SIGTERM stops the server, exit 0, env file removed, ports closed"
echo "PASS"
