#!/usr/bin/env bash
# The test half of a rules_itest service_test: clickhouse_server ran as an
# itest_service and its health check passed, so its env file is there.
set -euo pipefail
set -a; source "$TEST_TMPDIR/itest_server.env"; set +a
got=$("$CLICKHOUSE_BIN" client -C "$CLICKHOUSE_CLIENT_CONFIG" --database "$CLICKHOUSE_DATABASE" \
  --query "SELECT total FROM usage WHERE subject = 'customer-1'")
[[ "$got" == 3.5 ]] || { echo "FAIL: got '$got'" >&2; exit 1; }
# And over HTTP, as a service in any language would.
got=$(python3 -I -c '
import os, urllib.parse, urllib.request
q = urllib.parse.urlencode({"database": os.environ["CLICKHOUSE_DATABASE"], "query": "SELECT count() FROM events"})
print(urllib.request.urlopen(os.environ["CLICKHOUSE_HTTP_URL"] + "/?" + q).read().decode().strip())')
[[ "$got" == 2 ]] || { echo "FAIL: HTTP got '$got'" >&2; exit 1; }
echo "PASS"
