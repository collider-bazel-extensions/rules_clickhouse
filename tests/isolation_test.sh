#!/usr/bin/env bash
# Nothing is written outside $TEST_TMPDIR: clickhouse_server runs from a
# read-only working directory with a read-only HOME and TMPDIR, the test
# makes it write everything it can (MergeTree parts, a SQL UDF, a file()
# table in user_files, a temporary table, a user), and afterwards no file
# outside $TEST_TMPDIR is newer than a marker. Also: the server listens on
# exactly its two loopback ports.
#
# Argv: <clickhouse_server> <listeners.py>
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
SERVER="$TEST_SRCDIR/_main/$1"
LISTENERS="$TEST_SRCDIR/_main/$2"

ro="$TEST_TMPDIR/readonly"
mkdir -p "$ro"
marker="$TEST_TMPDIR/marker"
touch "$marker"
sleep 1   # mtime granularity
chmod 555 "$ro"

env_file="$TEST_TMPDIR/isolation_server.env"
(cd "$ro" && HOME="$ro" TMPDIR="$ro" exec "$SERVER") &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; chmod 755 "$ro"' EXIT
for _ in $(seq 1 1200); do [[ -f "$env_file" ]] && break; kill -0 "$pid" 2>/dev/null || fail "server exited"; sleep 0.1; done
[[ -f "$env_file" ]] || fail "env file not written"
set -a; source "$env_file"; set +a
ch() { (cd "$ro" && HOME="$ro" TMPDIR="$ro" "$CLICKHOUSE_BIN" client -C "$CLICKHOUSE_CLIENT_CONFIG" \
  --port "$CLICKHOUSE_NATIVE_PORT" --database "$CLICKHOUSE_DATABASE" --multiquery --query "$1"); }

ch "CREATE TABLE parts (k UInt64, s String) ENGINE = MergeTree ORDER BY k;
    INSERT INTO parts SELECT number, toString(number) FROM numbers(100000);
    OPTIMIZE TABLE parts FINAL;
    CREATE FUNCTION rc_double AS (x) -> x * 2;
    INSERT INTO FUNCTION file('export.csv', 'CSV', 'k UInt64') SELECT number FROM numbers(10);
    CREATE TEMPORARY TABLE scratch (a UInt8) ENGINE = Memory;
    CREATE USER rc_user IDENTIFIED WITH no_password;
    SELECT k FROM parts ORDER BY s DESC FORMAT Null SETTINGS max_bytes_before_external_sort = 1;"
[[ "$(ch "SELECT rc_double(21)")" == 42 ]] || fail "UDF"
[[ "$(ch "SELECT sum(k) FROM file('export.csv', 'CSV', 'k UInt64')")" == 45 ]] || fail "file()"
echo "ok: wrote parts, a UDF, a user_files file, a user"

# Where those went.
for p in data/store user_defined/function_rc_double.sql user_files/export.csv access clickhouse-server.pid log/clickhouse-server.log; do
  [[ -e "$CLICKHOUSE_STATE_DIR/$p" ]] || fail "expected $CLICKHOUSE_STATE_DIR/$p"
done
[[ "$CLICKHOUSE_STATE_DIR" == "$TEST_TMPDIR/clickhouse-isolation_server" ]] || fail "state dir $CLICKHOUSE_STATE_DIR"
echo "ok: all under $CLICKHOUSE_STATE_DIR"

# Listeners: exactly HTTP and native, on 127.0.0.1.
spid=$(cat "$CLICKHOUSE_STATE_DIR/clickhouse-server.pid")
listening=$(python3 -I "$LISTENERS" "$spid")
want="$(printf '%s\n%s\n' "$CLICKHOUSE_HTTP_PORT" "$CLICKHOUSE_NATIVE_PORT" | sort -n)"
[[ "$(awk '{print $1}' <<<"$listening" | sort -n)" == "$want" ]] || fail "listeners: $listening"
if awk '$3 != "0100007F"' <<<"$listening" | grep -q .; then fail "non-loopback listener: $listening"; fi
echo "ok: listening on exactly 127.0.0.1:$CLICKHOUSE_HTTP_PORT and :$CLICKHOUSE_NATIVE_PORT"

kill -TERM "$pid"; wait "$pid" || fail "SIGTERM exit status $?"
trap 'chmod 755 "$ro"' EXIT

# Nothing newer than the marker outside $TEST_TMPDIR, wherever a process
# here could write: the working directory and the runfiles tree, /tmp (the
# sandbox's own), and, by name, the host-shared /var/tmp and /dev/shm.
outside=()
for d in "$PWD" "$TEST_SRCDIR" /tmp /var/tmp /dev/shm; do
  [[ -d "$d" ]] || continue
  filter=(cat)
  [[ "$d" == /var/tmp || "$d" == /dev/shm ]] && filter=(grep -i clickhouse)
  while IFS= read -r f; do outside+=("$f"); done < <(
    find "$d" -xdev \( -path "$TEST_TMPDIR" -o -path "$TEST_TMPDIR/*" \) -prune -o -newer "$marker" \
      ! -type d -print 2>/dev/null | "${filter[@]}" || true)
done
if (( ${#outside[@]} )); then printf '  %s\n' "${outside[@]}" >&2; fail "files written outside \$TEST_TMPDIR"; fi
echo "ok: no file outside \$TEST_TMPDIR is newer than the start"
echo "PASS"
