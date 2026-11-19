#!/usr/bin/env bash
# Helpers for clickhouse_test scripts:  source "$CLICKHOUSE_TESTLIB"
#
#   ch "SQL"                     run SQL (any number of statements) with
#                                `clickhouse client` in $CLICKHOUSE_DATABASE;
#                                prints the result (TabSeparated)
#   ch [CLIENT_ARGS...]          `clickhouse client` with these arguments
#                                (e.g. ch --format CSV --query "..."); with
#                                no arguments it reads SQL from stdin:
#                                ch < fixtures.sql
#   ch_http "SQL"                the same over HTTP ($CLICKHOUSE_HTTP_URL);
#                                SQL from stdin when none is given
#   ch_wait EXPECTED "SQL"       wait until `ch "SQL"` prints EXPECTED
#                                ($CH_WAIT_TIMEOUT seconds, default 30)
#   clickhouse_stop / clickhouse_start
#                                stop the server / start it again on the
#                                same ports, with the same data
#
# `clickhouse` (the multi-call binary) is also on PATH; `clickhouse client
# -C "$CLICKHOUSE_CLIENT_CONFIG"` connects to this server too.

ch() {
  local base=("$CLICKHOUSE_BIN" client -C "$CLICKHOUSE_CLIENT_CONFIG"
    --host "$CLICKHOUSE_HOST" --port "$CLICKHOUSE_NATIVE_PORT"
    --user "$CLICKHOUSE_USER" --database "$CLICKHOUSE_DATABASE")
  if (( $# == 0 )); then
    "${base[@]}" --multiquery
  elif [[ "$1" == -* ]]; then
    "${base[@]}" "$@"
  else
    local q="$1"; shift
    "${base[@]}" --multiquery --query "$q" "$@"
  fi
}

# The script goes in with -c: stdin is the SQL when no argument is given.
_CH_HTTP_PY='
import os, sys, urllib.error, urllib.parse, urllib.request
sql = sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read()
url = os.environ["CLICKHOUSE_HTTP_URL"] + "/?" + urllib.parse.urlencode(
    {"database": os.environ["CLICKHOUSE_DATABASE"]})
req = urllib.request.Request(url, data=sql.encode(), method="POST", headers={
    "X-ClickHouse-User": os.environ["CLICKHOUSE_USER"],
    "X-ClickHouse-Key": os.environ.get("CLICKHOUSE_PASSWORD", ""),
})
try:
    with urllib.request.urlopen(req, timeout=300) as r:
        sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    sys.stderr.write("ch_http: HTTP %d: %s\n" % (e.code, e.read().decode().strip()))
    sys.exit(1)
except OSError as e:
    sys.stderr.write("ch_http: %s\n" % e)
    sys.exit(1)
'

ch_http() {
  python3 -I -c "$_CH_HTTP_PY" "$@"
}

ch_wait() {
  local want="$1"; shift
  local deadline=$(( $(date +%s) + ${CH_WAIT_TIMEOUT:-30} )) got
  while :; do
    got="$(ch "$@" 2>&1)" || true
    [[ "$got" == "$want" ]] && return 0
    if (( $(date +%s) >= deadline )); then
      echo "ch_wait: \`$*\` printed '$got', not '$want', after ${CH_WAIT_TIMEOUT:-30}s" >&2
      return 1
    fi
    sleep 0.1
  done
}

# clickhouse_stop   SIGTERM: ClickHouse shuts down cleanly; MergeTree parts
#                   already written stay on disk.
# clickhouse_start  start it again on the same ports, with the same config,
#                   password and data directory; waits for /ping. Migrations
#                   and seeds do not run again.
clickhouse_stop()  { _ch_control /stop; }
clickhouse_start() { _ch_control /start; }

_ch_control() {  # _ch_control /stop|/start
  python3 -I - "$CLICKHOUSE_CONTROL_URL$1" "clickhouse_${1#/}" <<'PY'
import sys, urllib.error, urllib.request
url, helper = sys.argv[1:]
try:
    urllib.request.urlopen(urllib.request.Request(url, data=b"", method="POST"), timeout=300)
except urllib.error.HTTPError as e:
    sys.exit(f"{helper}: {e.code}: {e.read().decode().strip()}")
PY
}
