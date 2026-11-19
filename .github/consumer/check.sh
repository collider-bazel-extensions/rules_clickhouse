#!/usr/bin/env bash
# Consumer checks against the commit's release archive (git archive honours
# .gitattributes export-ignore, as GitHub's tag tarballs do):
#   1. no clickhouse.version() in the root resolves, and a clickhouse_test
#      (schema, ch, ch_http) runs the default version
#   2. the root's clickhouse.version() overrides it: the same test runs the
#      other pinned version
#   3. the same version set twice in the root resolves; set twice
#      differently fails
#   4. an unsupported version without pins fails, naming clickhouse.version
#   5. @rules_clickhouse//... loads (tests/ and tools/ are not shipped)
# Usage: .github/consumer/check.sh <scratch dir>
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$1"
src="$work/rules_clickhouse"
rm -rf "$work"; mkdir -p "$src"
git -C "$repo" archive HEAD | tar -x -C "$src"
for d in tests tools; do
    if [[ -e "$src/$d" ]]; then echo "FAIL: archive contains $d/" >&2; exit 1; fi
done
default_version="$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"$/\1/p' "$src/private/versions.bzl")"
other_version="$(sed -n 's/^    "\([0-9][0-9.]*\)": {$/\1/p' "$src/private/versions.bzl" | grep -vxF "$default_version" | head -1)"

consumer() { # <name> <expected version> <extra MODULE.bazel lines>
    local c="$work/$1"
    mkdir -p "$c/db"
    if [[ -f "$repo/.bazelversion" ]]; then cp "$repo/.bazelversion" "$c/"; fi
    cat > "$c/MODULE.bazel" <<MOD
module(name = "consumer")
bazel_dep(name = "rules_clickhouse")
local_path_override(module_name = "rules_clickhouse", path = "$src")
$3
MOD
    cat > "$c/db/001_events.sql" <<'SQL'
CREATE TABLE events (subject String, value Float64) ENGINE = MergeTree ORDER BY subject;
INSERT INTO events VALUES ('a', 1), ('a', 2);
SQL
    cat > "$c/db_test.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "\$CLICKHOUSE_TESTLIB"
[[ "\$(ch "SELECT version()")" == "$2" ]]
[[ "\$CLICKHOUSE_VERSION" == "$2" ]]
[[ "\$(ch "SELECT sum(value) FROM events")" == 3 ]]
[[ "\$(ch_http "SELECT count() FROM events")" == 2 ]]
[[ "\$CLICKHOUSE_DSN" == "clickhouse://default@127.0.0.1:\$CLICKHOUSE_NATIVE_PORT/test" ]]
SH
    chmod +x "$c/db_test.sh"
    cat > "$c/BUILD.bazel" <<'BUILD'
load("@rules_clickhouse//:defs.bzl", "clickhouse_schema", "clickhouse_test")

clickhouse_schema(
    name = "schema",
    srcs = glob(["db/*.sql"]),
)

clickhouse_test(
    name = "db_test",
    srcs = ["db_test.sh"],
    schema = ":schema",
    tags = ["block-network"],
)
BUILD
    echo "$c"
}

# 1. No clickhouse.version(): resolves; a clickhouse_test runs the default.
c="$(consumer untagged "$default_version" "")"
(cd "$c" && bazel mod deps >/dev/null)
(cd "$c" && bazel test //:db_test --test_output=errors)
echo "PASS: untagged root resolves, ClickHouse $default_version runs"

# 2. The root overrides the version.
if [[ -n "$other_version" ]]; then
    c="$(consumer override "$other_version" "clickhouse = use_extension(\"@rules_clickhouse//:extensions.bzl\", \"clickhouse\")
clickhouse.version(version = \"$other_version\")")"
    (cd "$c" && bazel test //:db_test --test_output=errors)
    echo "PASS: clickhouse.version(version = \"$other_version\") in the root runs ClickHouse $other_version"
else
    echo "SKIP: only one version pinned; no override to check"
fi

# 3. The same version twice resolves; two different ones for one name fail.
c="$(consumer twice "$default_version" "clickhouse = use_extension(\"@rules_clickhouse//:extensions.bzl\", \"clickhouse\")
clickhouse.version(version = \"$default_version\")
clickhouse.version(version = \"$default_version\")")"
(cd "$c" && bazel mod deps >/dev/null)
echo "PASS: repeated identical clickhouse.version resolves"
c="$(consumer conflict "$default_version" "clickhouse = use_extension(\"@rules_clickhouse//:extensions.bzl\", \"clickhouse\")
clickhouse.version(version = \"$default_version\")
clickhouse.version(version = \"0.0.0.1\", sha512 = {\"linux_amd64\": \"00\"})")"
if (cd "$c" && bazel build //:db_test) > "$work/conflict.out" 2>&1; then
    echo "FAIL: conflicting clickhouse.version tags resolved" >&2; exit 1
fi
grep -q 'sets clickhouse.version(name = "clickhouse") twice, differently' "$work/conflict.out" || {
    cat "$work/conflict.out" >&2; echo "FAIL: conflicting tags: wrong error" >&2; exit 1; }
echo "PASS: conflicting clickhouse.version tags fail clearly"

# 4. An unsupported version without pins fails with a message naming clickhouse.version.
c="$(consumer unsupported "$default_version" 'clickhouse = use_extension("@rules_clickhouse//:extensions.bzl", "clickhouse")
clickhouse.version(version = "0.0.0.1")')"
if (cd "$c" && bazel build //:db_test) > "$work/unsupported.out" 2>&1; then
    echo "FAIL: unsupported version resolved" >&2; exit 1
fi
grep -q 'clickhouse.version(version = "0.0.0.1") is not supported' "$work/unsupported.out" || {
    cat "$work/unsupported.out" >&2; echo "FAIL: unsupported version: wrong error" >&2; exit 1; }
echo "PASS: unsupported version fails clearly"

# 5. //... loads.
(cd "$work/untagged" && bazel query @rules_clickhouse//... >/dev/null)
echo "PASS: @rules_clickhouse//... loads"
