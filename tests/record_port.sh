#!/usr/bin/env bash
# Inner test for server_cleanup_test: records the server's ports.
echo "$CLICKHOUSE_HTTP_PORT $CLICKHOUSE_NATIVE_PORT" > "$RECORD_FILE"
