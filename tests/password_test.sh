#!/usr/bin/env bash
# password: the default user needs it over both protocols; it is exported
# raw and percent-encoded in the DSN.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$CLICKHOUSE_TESTLIB"

[[ "$CLICKHOUSE_PASSWORD" == 'p@ss w&rd:/<x>' ]] || fail "CLICKHOUSE_PASSWORD: $CLICKHOUSE_PASSWORD"
[[ "$CLICKHOUSE_DSN" == "clickhouse://default:p%40ss%20w%26rd%3A%2F%3Cx%3E@127.0.0.1:$CLICKHOUSE_NATIVE_PORT/test" ]] \
  || fail "dsn: $CLICKHOUSE_DSN"
[[ "$(ch "SELECT 1")" == 1 ]] || fail "ch with password"
[[ "$(ch_http "SELECT 2")" == 2 ]] || fail "ch_http with password"

# clickhouse client reads CLICKHOUSE_USER / CLICKHOUSE_PASSWORD / CLICKHOUSE_HOST
# itself; without them (or with a wrong one) it is refused.
rc=0; out=$(env -u CLICKHOUSE_PASSWORD "$CLICKHOUSE_BIN" client --host 127.0.0.1 \
  --port "$CLICKHOUSE_NATIVE_PORT" --user default --query "SELECT 1" 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "no password accepted"
grep -q "AUTHENTICATION_FAILED\|Authentication failed" <<<"$out" || fail "native refusal: $out"
rc=0; out=$(CLICKHOUSE_PASSWORD=wrong ch_http "SELECT 1" 2>&1) || rc=$?
[[ "$rc" != 0 ]] || fail "wrong password accepted over HTTP"
grep -q "Authentication failed" <<<"$out" || fail "HTTP refusal: $out"
echo "PASS"
