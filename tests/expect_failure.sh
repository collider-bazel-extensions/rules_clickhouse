#!/usr/bin/env bash
# Runs a clickhouse_server (or clickhouse_test trampoline) that must fail,
# and checks its exit code, its output, that it wrote no env file and that
# no clickhouse server it started is still running.
#
# Argv: <executable (rootpath)> <exit code> <fixed string>... [-- <args for the executable>...]
set -uo pipefail
target="$1" want_rc="$2"; shift 2
strings=()
while (( $# )) && [[ "$1" != -- ]]; do strings+=("$1"); shift; done
[[ "${1:-}" == -- ]] && shift
inner_tmp="$TEST_TMPDIR/inner"; mkdir -p "$inner_tmp"
out=$(cd "$TEST_SRCDIR/_main" && env -u XML_OUTPUT_FILE -u TEST_UNDECLARED_OUTPUTS_DIR TEST_TMPDIR="$inner_tmp" \
  timeout 300 "$TEST_SRCDIR/_main/$target" "$@" 2>&1)
rc=$?
echo "$out"
echo "---- exit $rc"
status=0
if [[ "$rc" != "$want_rc" ]]; then echo "FAIL: exit $rc, want $want_rc" >&2; status=1; fi
for s in "${strings[@]}"; do
  if grep -qF -- "$s" <<<"$out"; then echo "ok: $s"; else echo "FAIL: not in the output: $s" >&2; status=1; fi
done
if grep -q "TEST BODY RAN" <<<"$out"; then echo "FAIL: the test body ran" >&2; status=1; fi
envs=$(find "$inner_tmp" -maxdepth 1 -name '*.env')
if [[ -n "$envs" ]]; then echo "FAIL: env file written: $envs" >&2; status=1; fi
for pidf in "$inner_tmp"/clickhouse-*/clickhouse-server.pid; do
  [[ -f "$pidf" ]] || continue
  if kill -0 "$(cat "$pidf")" 2>/dev/null; then
    echo "FAIL: clickhouse server $(cat "$pidf") still running" >&2; status=1
  else
    echo "ok: the server it started ($(cat "$pidf")) is gone"
  fi
done
[[ $status == 0 ]] && echo PASS
exit $status
