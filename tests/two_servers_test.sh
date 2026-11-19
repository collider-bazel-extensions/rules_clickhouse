#!/usr/bin/env bash
# Two clickhouse_servers in one test: own ports, own state dirs, own data;
# both up at once, both stopped by SIGTERM.
#
# Argv: <server a> <server b>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }

pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done' EXIT
"$TEST_SRCDIR/_main/$1" & pids+=($!)
"$TEST_SRCDIR/_main/$2" & pids+=($!)
for name in two_a two_b; do
  for _ in $(seq 1 1200); do [[ -f "$TEST_TMPDIR/$name.env" ]] && break; sleep 0.1; done
  [[ -f "$TEST_TMPDIR/$name.env" ]] || fail "$name: env file not written"
done
q() { ( set -a; source "$TEST_TMPDIR/$1.env"; "$CLICKHOUSE_BIN" client -C "$CLICKHOUSE_CLIENT_CONFIG" \
          --database "$CLICKHOUSE_DATABASE" --multiquery --query "$2" ); }
val() { ( source "$TEST_TMPDIR/$1.env"; eval "echo \$$2" ); }

ports=("$(val two_a CLICKHOUSE_HTTP_PORT)" "$(val two_a CLICKHOUSE_NATIVE_PORT)"
       "$(val two_b CLICKHOUSE_HTTP_PORT)" "$(val two_b CLICKHOUSE_NATIVE_PORT)")
[[ "$(printf '%s\n' "${ports[@]}" | sort -u | wc -l)" == 4 ]] || fail "ports collide: ${ports[*]}"
[[ "$(val two_a CLICKHOUSE_STATE_DIR)" != "$(val two_b CLICKHOUSE_STATE_DIR)" ]] || fail "one state dir"
[[ "$(val two_a CLICKHOUSE_DATABASE)" == db_a && "$(val two_b CLICKHOUSE_DATABASE)" == db_b ]] || fail "databases"
echo "ok: a on ${ports[0]}/${ports[1]}, b on ${ports[2]}/${ports[3]}"

q two_a "CREATE TABLE only_in_a (x UInt8) ENGINE = MergeTree ORDER BY x; INSERT INTO only_in_a VALUES (1);"
q two_b "CREATE TABLE only_in_b (x UInt8) ENGINE = MergeTree ORDER BY x; INSERT INTO only_in_b VALUES (2), (3);"
[[ "$(q two_a "SELECT count() FROM only_in_a")" == 1 ]] || fail "a"
[[ "$(q two_b "SELECT count() FROM only_in_b")" == 2 ]] || fail "b"
[[ "$(q two_a "EXISTS TABLE db_b.only_in_b")" == 0 && "$(q two_b "EXISTS TABLE db_a.only_in_a")" == 0 ]] \
  || fail "the servers share data"
[[ "$(q two_a "SELECT count() FROM system.databases WHERE name IN ('db_a', 'db_b')")" == 1 ]] || fail "a sees b's database"
echo "ok: separate data"

for p in "${pids[@]}"; do kill -TERM "$p"; done
for p in "${pids[@]}"; do wait "$p" || fail "SIGTERM exit status $?"; done
pids=()
for port in "${ports[@]}"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then fail "port $port still open"; fi
done
echo "ok: both stopped"
echo "PASS"
