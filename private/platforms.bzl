"""Supported platforms and where each one's ClickHouse comes from. The
pins themselves (one hash per platform and version) are generated into
versions.bzl by tools/update_versions.sh."""

PLATFORMS = {
    "linux_amd64": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "linux_arm64": ["@platforms//os:linux", "@platforms//cpu:arm64"],
    "darwin_amd64": ["@platforms//os:osx", "@platforms//cpu:x86_64"],
    "darwin_arm64": ["@platforms//os:osx", "@platforms//cpu:arm64"],
}

# Release asset per platform. {version} is e.g. 26.9.32.8. The Linux ones
# are archives holding clickhouse-common-static-{version}/usr/bin/clickhouse;
# the macOS ones are the bare binary.
ASSETS = {
    "linux_amd64": "clickhouse-common-static-{version}-amd64.tgz",
    "linux_arm64": "clickhouse-common-static-{version}-arm64.tgz",
    "darwin_amd64": "clickhouse-macos",
    "darwin_arm64": "clickhouse-macos-aarch64",
}

# {release_tag} is e.g. v26.9.32.8-stable; {asset} one of ASSETS.
RELEASE_URL = "https://github.com/ClickHouse/ClickHouse/releases/download/{release_tag}/{asset}"
