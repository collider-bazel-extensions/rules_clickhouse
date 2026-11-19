#!/usr/bin/env bash
# One shard of a sharded clickhouse_test: the shards run at once, each with
# its own server; each sees only its own data.
set -euo pipefail
fail() { echo "FAIL: $*" >&2; exit 1; }
source "$CLICKHOUSE_TESTLIB"
touch "${TEST_SHARD_STATUS_FILE:-/dev/null}"
shard="${TEST_SHARD_INDEX:-0}"
ch "CREATE TABLE shard (i UInt8) ENGINE = MergeTree ORDER BY i; INSERT INTO shard VALUES ($shard);"
[[ "$(ch "SELECT groupArray(i) FROM shard")" == "[$shard]" ]] || fail "shard $shard sees: $(ch "SELECT * FROM shard")"
echo "PASS: shard $shard on $CLICKHOUSE_HTTP_PORT/$CLICKHOUSE_NATIVE_PORT"
