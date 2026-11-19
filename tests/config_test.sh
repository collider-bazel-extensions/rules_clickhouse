#!/usr/bin/env bash
# config / users fragments and extra_args apply; the settings rules_clickhouse
# owns (paths, listeners, logging, crash reports, the default user's
# password and networks) don't.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$CLICKHOUSE_TESTLIB"
setting() { ch "SELECT value FROM system.server_settings WHERE name = '$1'"; }

[[ "$(ch "SELECT timezone()")" == Europe/Berlin ]] || fail "config fragment's timezone not applied"
[[ "$(ch "SELECT getMacro('shard')")" == 01 ]] || fail "macros not applied"
[[ "$(setting max_concurrent_queries)" == 42 ]] || fail "extra_args not applied: $(setting max_concurrent_queries)"
[[ "$(ch "SELECT value FROM system.settings WHERE name = 'max_result_rows'")" == 100000 ]] || fail "users profile not applied"
echo "ok: config, users and extra_args apply"

# Paths stay in the state dir.
data=$(ch "SELECT path FROM system.disks WHERE name = 'default'")
[[ "$data" == "$CLICKHOUSE_STATE_DIR/data/" ]] || fail "data path $data"
[[ -s "$CLICKHOUSE_STATE_DIR/log/clickhouse-server.log" ]] || fail "no log in the state dir"
grep -q "<Debug>" "$CLICKHOUSE_STATE_DIR/log/clickhouse-server.log" || fail "logger level from the fragment not applied"
[[ ! -e /var/lib/clickhouse/metadata && ! -e /var/log/clickhouse-server/clickhouse-server.log ]] \
  || echo "note: this host has a system ClickHouse; checking the merged config instead"
merged="$CLICKHOUSE_STATE_DIR/data/preprocessed_configs/config.xml"
if grep -E "/var/lib/clickhouse|/var/log/clickhouse|<mysql_port>|<postgresql_port>|<interserver_http_port>|<prometheus>|<listen_host>::|0\.0\.0\.0|<enabled>true" "$merged"; then
  fail "a setting rules_clickhouse owns survived in $merged"
fi
echo "ok: the fragment's paths, listeners, logger files and crash reports were dropped"

# Exactly two listeners, both loopback: HTTP and native.
pid=$(cat "$CLICKHOUSE_STATE_DIR/clickhouse-server.pid")
listening=$(python3 -I "$1" "$pid")
echo "$listening"
want="$(printf '%s\n%s\n' "$CLICKHOUSE_HTTP_PORT" "$CLICKHOUSE_NATIVE_PORT" | sort -n)"
[[ "$(awk '{print $1}' <<<"$listening" | sort -n)" == "$want" ]] || fail "listeners: $listening"
if awk '$3 != "0100007F"' <<<"$listening" | grep -q .; then fail "a non-loopback listener: $listening"; fi
echo "ok: listening only on 127.0.0.1:$CLICKHOUSE_HTTP_PORT and :$CLICKHOUSE_NATIVE_PORT"

# The default user keeps rules_clickhouse's (empty) password; the second
# user works, read-only.
[[ "$(ch "SELECT 1")" == 1 ]] || fail "default user's password was changed"
[[ "$("$CLICKHOUSE_BIN" client --port "$CLICKHOUSE_NATIVE_PORT" --user reader --password reader-pw --query "SELECT currentUser()")" == reader ]] || fail "reader can't log in"
if "$CLICKHOUSE_BIN" client --port "$CLICKHOUSE_NATIVE_PORT" --user reader --password reader-pw --query "CREATE TABLE x (a UInt8) ENGINE = Memory" 2>/dev/null; then
  fail "reader isn't read-only"
fi
echo "ok: users fragment"
echo "PASS"
