#!/usr/bin/env bash
# tools/update_versions.sh — regenerate private/versions.bzl (the ClickHouse pins).
#
# Usage:
#   tools/update_versions.sh [VERSION...]           # regenerate, downloading and verifying every asset
#   tools/update_versions.sh --check [VERSION...]   # regenerate to a temp file and diff (no big downloads)
#
# VERSION is a release version such as 26.9.32.8 (the tag is looked up:
# v<VERSION>-stable, else v<VERSION>-lts). The first VERSION becomes
# DEFAULT_VERSION. With no VERSION, the versions already in
# private/versions.bzl are refreshed, keeping their DEFAULT_VERSION.
#
# Where the pins come from:
#   linux_amd64 / linux_arm64   clickhouse-common-static-<ver>-{amd64,arm64}.tgz:
#                               SHA-512 from upstream's .sha512 file next to it.
#   darwin_amd64 / darwin_arm64 clickhouse-macos / clickhouse-macos-aarch64: upstream
#                               publishes no checksum file, so SHA-256 from the
#                               GitHub release asset digest (computed by GitHub at upload).
# Without --check every asset is downloaded (about 250 MB per Linux archive and
# 190 MB per macOS binary) and its hash compared with the pin; a mismatch fails.
# --check fetches only the checksum files and the release metadata, then
# fails if private/versions.bzl differs from what it would write.
#
# Set GITHUB_TOKEN to raise the GitHub API rate limit.
set -euo pipefail

CHECK=0
VERSIONS=()
for a in "$@"; do
    case "$a" in
        --check) CHECK=1 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        -*) echo "update_versions: unknown flag $a" >&2; exit 2 ;;
        *) VERSIONS+=("$a") ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS_BZL="$REPO_ROOT/private/versions.bzl"
WORK="$(mktemp -d -t update-clickhouse-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

DEFAULT=""
if [[ ${#VERSIONS[@]} -eq 0 ]]; then
    [[ -f "$VERSIONS_BZL" ]] || { echo "update_versions: no VERSION given and no $VERSIONS_BZL" >&2; exit 2; }
    DEFAULT="$(sed -n 's/^DEFAULT_VERSION = "\(.*\)"$/\1/p' "$VERSIONS_BZL")"
    while IFS= read -r v; do VERSIONS+=("$v"); done \
        < <(sed -n 's/^    "\([0-9][0-9.]*\)": {$/\1/p' "$VERSIONS_BZL")
    [[ ${#VERSIONS[@]} -gt 0 ]] || { echo "update_versions: no versions in $VERSIONS_BZL" >&2; exit 2; }
else
    DEFAULT="${VERSIONS[0]}"
fi

api() {
    local auth=()
    [[ -z "${GITHUB_TOKEN:-}" ]] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    curl -fsSL ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" "$1"
}

log() { echo "[update_versions] $*" >&2; }

entries="$WORK/entries"
: > "$entries"
for v in "${VERSIONS[@]}"; do
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "update_versions: '$v' is not a version like 26.9.32.8" >&2; exit 2; }
    tag=""
    for t in "v$v-stable" "v$v-lts"; do
        if api "https://api.github.com/repos/ClickHouse/ClickHouse/releases/tags/$t" > "$WORK/release.json" 2>/dev/null; then
            tag="$t"; break
        fi
    done
    [[ -n "$tag" ]] || { echo "update_versions: no release v$v-stable or v$v-lts" >&2; exit 1; }
    log "$v: release $tag"
    base="https://github.com/ClickHouse/ClickHouse/releases/download/$tag"
    line="$v $tag"
    for arch in amd64 arm64; do
        asset="clickhouse-common-static-$v-$arch.tgz"
        curl -fsSL "$base/$asset.sha512" -o "$WORK/sum"
        want="$(awk -v a="$asset" '$2 == a || $2 == "*" a {print $1}' "$WORK/sum")"
        [[ "$want" =~ ^[0-9a-f]{128}$ ]] || { echo "update_versions: $asset.sha512 has no SHA-512 for $asset" >&2; exit 1; }
        if (( ! CHECK )); then
            log "$v: downloading $asset"
            curl -fsSL "$base/$asset" -o "$WORK/asset"
            got="$(sha512sum "$WORK/asset" | awk '{print $1}')"
            rm -f "$WORK/asset"
            [[ "$got" == "$want" ]] || { echo "update_versions: $asset: sha512 $got, but $asset.sha512 says $want" >&2; exit 1; }
            log "$v: $asset matches its .sha512"
        fi
        line="$line linux_$arch=sha512:$want"
    done
    for pair in darwin_amd64=clickhouse-macos darwin_arm64=clickhouse-macos-aarch64; do
        plat="${pair%%=*}" asset="${pair#*=}"
        want="$(python3 -I -c '
import json, sys
rel = json.load(open(sys.argv[1]))
for a in rel["assets"]:
    if a["name"] == sys.argv[2]:
        d = a.get("digest") or ""
        print(d.split(":", 1)[1] if d.startswith("sha256:") else "")
        break
' "$WORK/release.json" "$asset")"
        if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
            log "$v: $asset has no GitHub sha256 digest; $plat left unpinned"
            continue
        fi
        if (( ! CHECK )); then
            log "$v: downloading $asset"
            curl -fsSL "$base/$asset" -o "$WORK/asset"
            got="$(sha256sum "$WORK/asset" | awk '{print $1}')"
            rm -f "$WORK/asset"
            [[ "$got" == "$want" ]] || { echo "update_versions: $asset: sha256 $got, but the release digest says $want" >&2; exit 1; }
            log "$v: $asset matches the release digest"
        fi
        line="$line $plat=sha256:$want"
    done
    echo "$line" >> "$entries"
done

out="$WORK/versions.bzl"
python3 -I - "$entries" "$DEFAULT" > "$out" <<'PY'
import sys
entries, default = sys.argv[1], sys.argv[2]
print('''"""ClickHouse pins. Generated by tools/update_versions.sh; do not edit by hand.

    CLICKHOUSE_VERSIONS = {
        "<version>": {
            "release_tag": "v<version>-stable",
            "<platform>": {"sha512" or "sha256": "<hex>"},
        },
    }

linux_*: clickhouse-common-static-<version>-<arch>.tgz, SHA-512 from upstream's
.sha512 file. darwin_*: clickhouse-macos(-aarch64), SHA-256 from the GitHub
release asset digest (upstream publishes no checksum file for them). The
download URLs are in private/platforms.bzl.

Refresh: tools/update_versions.sh [VERSION...]; verify: tools/update_versions.sh --check
"""

DEFAULT_VERSION = "%s"

CLICKHOUSE_VERSIONS = {''' % default)
for line in open(entries):
    words = line.split()
    version, tag, pins = words[0], words[1], words[2:]
    print(f'    "{version}": {{')
    print(f'        "release_tag": "{tag}",')
    for p in sorted(pins):
        plat, rest = p.split("=", 1)
        algo, hexd = rest.split(":", 1)
        print(f'        "{plat}": {{"{algo}": "{hexd}"}},')
    print("    },")
print("}")
PY

if (( CHECK )); then
    if diff -u "$VERSIONS_BZL" "$out"; then
        log "OK: private/versions.bzl matches upstream's checksums for ${VERSIONS[*]}"
    else
        echo "update_versions: private/versions.bzl is out of date; run tools/update_versions.sh ${VERSIONS[*]}" >&2
        exit 1
    fi
else
    cp "$out" "$VERSIONS_BZL"
    log "wrote $VERSIONS_BZL (default $DEFAULT; versions ${VERSIONS[*]})"
fi
