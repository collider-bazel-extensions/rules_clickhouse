#!/usr/bin/env bash
# Every version in private/versions.bzl pins both Linux archives with a
# 128-hex SHA-512 (and the macOS binaries, when pinned, with a 64-hex
# SHA-256), and DEFAULT_VERSION is one of them. No network.
set -euo pipefail
f="${TEST_SRCDIR}/_main/private/versions.bzl"
python3 -I - "$f" <<'PY'
import ast, re, sys
src = open(sys.argv[1]).read()
default = re.search(r'^DEFAULT_VERSION = "([^"]+)"$', src, re.M).group(1)
versions = ast.literal_eval(re.search(r"^CLICKHOUSE_VERSIONS = (\{.*?^\})", src, re.M | re.S).group(1))
bad = []
for v, pins in versions.items():
    if not re.fullmatch(r"v%s-(stable|lts)" % re.escape(v), pins.get("release_tag", "")):
        bad.append(f"{v}: release_tag {pins.get('release_tag')!r}")
    for plat in ("linux_amd64", "linux_arm64"):
        if not re.fullmatch(r"[0-9a-f]{128}", pins.get(plat, {}).get("sha512", "")):
            bad.append(f"{v}: {plat} has no SHA-512")
    for plat in ("darwin_amd64", "darwin_arm64"):
        if plat in pins and not re.fullmatch(r"[0-9a-f]{64}", pins[plat].get("sha256", "")):
            bad.append(f"{v}: {plat} pin malformed")
    print(f"{v}: {', '.join(sorted(k for k in pins if k != 'release_tag'))}")
if default not in versions:
    bad.append(f"DEFAULT_VERSION {default} is not pinned")
if bad:
    sys.exit("FAIL: " + "; ".join(bad) + " (tools/update_versions.sh <version>)")
print(f"PASS: {len(versions)} versions; default {default}")
PY
