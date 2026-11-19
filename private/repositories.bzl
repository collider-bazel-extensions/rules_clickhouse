"""Repositories for one ClickHouse version.

`clickhouse_version_repository(name, ...)` creates:

  @<name>               the hub: one `toolchain` per platform (register
                        `@<name>//:all`), each pointing at its platform repo.
  @<name>_<platform>    the binary for one platform. It is fetched only when
                        a build resolves the toolchain for that platform (the
                        Linux archives are about 250 MB, the binary inside
                        about 840 MB), so a Linux build never downloads macOS
                        binaries, and the reverse.
"""

load(":platforms.bzl", "ASSETS", "PLATFORMS", "RELEASE_URL")
load(":versions.bzl", "CLICKHOUSE_VERSIONS")

_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
_HEX = "0123456789abcdef"

def _hex_to_base64(h):
    """Hex digest -> standard base64 (for a Subresource Integrity string)."""
    h = h.lower()
    data = [_HEX.index(h[i]) * 16 + _HEX.index(h[i + 1]) for i in range(0, len(h), 2)]
    out = []
    for i in range(0, len(data), 3):
        chunk = data[i:i + 3]
        n = len(chunk)
        b = chunk + [0] * (3 - n)
        v = b[0] * 65536 + b[1] * 256 + b[2]
        out.append(_B64[(v // 262144) % 64])
        out.append(_B64[(v // 4096) % 64])
        out.append(_B64[(v // 64) % 64] if n > 1 else "=")
        out.append(_B64[v % 64] if n > 2 else "=")
    return "".join(out)

def _check_hex(what, value, length):
    if len(value) != length or [c for c in value.lower().elems() if c not in _HEX.elems()]:
        fail("rules_clickhouse: {} must be {} hex digits, got {}".format(what, length, repr(value)))

def sha512_integrity(hexdigest):
    _check_hex("sha512", hexdigest, 128)
    return "sha512-" + _hex_to_base64(hexdigest)

# ---- per-platform binary ---------------------------------------------------------

_PLATFORM_BUILD = """\
package(default_visibility = ["//visibility:public"])

# The multi-call ClickHouse binary: `clickhouse server`, `clickhouse client`,
# `clickhouse local`, ...
filegroup(name = "clickhouse", srcs = ["bin/clickhouse"])
"""

def _platform_repo_impl(rctx):
    plat, version = rctx.attr.platform, rctx.attr.version
    if not rctx.attr.sha512 and not rctx.attr.sha256:
        fail(("rules_clickhouse: no pin for ClickHouse {v} on {p}. Pin it in your root module: " +
              "clickhouse.version(version = \"{v}\", sha512 = {{\"{p}\": \"<hex>\"}}) " +
              "(or sha256 = {{...}}); tools/update_versions.sh {v} prints the pins.").format(v = version, p = plat))
    kwargs = {}
    if rctx.attr.sha512:
        kwargs["integrity"] = sha512_integrity(rctx.attr.sha512)
    else:
        _check_hex("sha256", rctx.attr.sha256, 64)
        kwargs["sha256"] = rctx.attr.sha256
    url = rctx.attr.url
    if plat.startswith("linux_"):
        rctx.download_and_extract(
            url = url,
            output = "_archive",
            strip_prefix = "clickhouse-common-static-{}".format(version),
            type = "tar.gz",
            **kwargs
        )
        src = rctx.path("_archive/usr/bin/clickhouse")
        if not src.exists:
            fail("rules_clickhouse: {} has no clickhouse-common-static-{}/usr/bin/clickhouse".format(url, version))
        rctx.execute(["mkdir", "-p", "bin"])
        res = rctx.execute(["mv", str(src), "bin/clickhouse"])
        if res.return_code != 0:
            fail("rules_clickhouse: moving the clickhouse binary failed: " + res.stderr)
        rctx.delete("_archive")
    else:
        rctx.download(url = url, output = "bin/clickhouse", executable = True, **kwargs)
    rctx.file("BUILD.bazel", _PLATFORM_BUILD)

_clickhouse_platform_repository = repository_rule(
    implementation = _platform_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "platform": attr.string(mandatory = True),
        "url": attr.string(mandatory = True),
        # One of the two; neither: fetching fails, naming the tag to set
        # (only when a build needs this platform).
        "sha512": attr.string(),
        "sha256": attr.string(),
    },
)

# ---- hub -------------------------------------------------------------------------

_HUB_TC = """\
clickhouse_toolchain(
    name = "{plat}_impl",
    version = "{version}",
    clickhouse = "@{hub}_{plat}//:clickhouse",
)

toolchain(
    name = "{plat}",
    exec_compatible_with = {compat},
    target_compatible_with = {compat},
    toolchain = ":{plat}_impl",
    toolchain_type = "@rules_clickhouse//toolchain:clickhouse",
)
"""

def _hub_repo_impl(rctx):
    chunks = [
        'load("@rules_clickhouse//toolchain:toolchain.bzl", "clickhouse_toolchain")\n',
        'package(default_visibility = ["//visibility:public"])\n',
        "# ClickHouse {} toolchains; register with `register_toolchains(\"@{}//:all\")`.\n".format(
            rctx.attr.version,
            rctx.attr.hub,
        ),
    ]
    for plat, compat in PLATFORMS.items():
        chunks.append(_HUB_TC.format(plat = plat, version = rctx.attr.version, hub = rctx.attr.hub, compat = repr(compat)))
    rctx.file("BUILD.bazel", "\n".join(chunks))

_clickhouse_hub_repository = repository_rule(
    implementation = _hub_repo_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        # The hub's apparent name, which prefixes its platform repos' names.
        "hub": attr.string(mandatory = True),
    },
)

def clickhouse_version_repository(name, version, release_tag = "", sha512 = {}, sha256 = {}, urls = {}):
    """The hub `@<name>` and the lazy `@<name>_<platform>` binary repos.

    Pins default to CLICKHOUSE_VERSIONS[version]; `sha512` / `sha256` (by
    platform) replace them, and `urls` (by platform) the download URLs.
    """
    known = CLICKHOUSE_VERSIONS.get(version, {})
    for what, d in (("sha512", sha512), ("sha256", sha256), ("urls", urls)):
        for plat in d:
            if plat not in PLATFORMS:
                fail("rules_clickhouse: clickhouse.version({} = ...) has unknown platform '{}'. Platforms: {}".format(
                    what,
                    plat,
                    ", ".join(sorted(PLATFORMS.keys())),
                ))
    tag = release_tag or known.get("release_tag") or "v{}-stable".format(version)
    _clickhouse_hub_repository(name = name, version = version, hub = name)
    for plat in PLATFORMS.keys():
        pin = known.get(plat, {})
        if plat in sha512 or plat in sha256:
            pin = {"sha512": sha512.get(plat, ""), "sha256": sha256.get(plat, "")}
        _clickhouse_platform_repository(
            name = "{}_{}".format(name, plat),
            version = version,
            platform = plat,
            url = urls.get(plat) or RELEASE_URL.format(
                release_tag = tag,
                asset = ASSETS[plat].format(version = version),
            ),
            sha512 = pin.get("sha512", ""),
            sha256 = pin.get("sha256", ""),
        )
