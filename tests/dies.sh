#!/usr/bin/env bash
# Inner test for server_died_test: shuts the server down (not via
# clickhouse_stop), then would carry on.
source "$CLICKHOUSE_TESTLIB"
ch "SYSTEM SHUTDOWN" >/dev/null 2>&1 || true
sleep 60
echo "BODY FINISHED"
