"""Bzlmod extension: `clickhouse.version()` -> the hub `@<name>` (toolchains)
and lazy per-platform binary repos `@<name>_<platform>`.

rules_clickhouse's own MODULE.bazel sets `clickhouse.version(version =
DEFAULT_VERSION)` for the hub `@clickhouse` and registers
`@clickhouse//:all`, so consumers need no extension wiring. A root module's
tag overrides it by name:

    clickhouse = use_extension("@rules_clickhouse//:extensions.bzl", "clickhouse")
    clickhouse.version(version = "26.10.6.18")            # pinned in private/versions.bzl

    clickhouse.version(                                   # any other release:
        version = "26.8.40.7",                            # pin it yourself
        release_tag = "v26.8.40.7-lts",
        sha512 = {"linux_amd64": "<hex>", "linux_arm64": "<hex>"},
    )
"""

load("//private:platforms.bzl", "PLATFORMS")
load("//private:repositories.bzl", "clickhouse_version_repository")
load("//private:versions.bzl", "CLICKHOUSE_VERSIONS", "DEFAULT_VERSION")

_version_tag = tag_class(attrs = {
    "name": attr.string(
        default = "clickhouse",
        doc = "The hub repo's name. `clickhouse` (the default) is the one " +
              "rules_clickhouse registers; another name makes a second hub " +
              "you register yourself.",
    ),
    "version": attr.string(mandatory = True, doc = "A release version, e.g. 26.9.32.8."),
    "release_tag": attr.string(
        doc = "The GitHub release tag; default: the pinned one, else v<version>-stable.",
    ),
    "sha512": attr.string_dict(
        doc = "Platform -> SHA-512 (hex) of its release asset, from upstream's " +
              ".sha512 files. Replaces the pins in private/versions.bzl.",
    ),
    "sha256": attr.string_dict(
        doc = "Platform -> SHA-256 (hex), for assets without a .sha512 file " +
              "(the macOS binaries: the GitHub release asset digest).",
    ),
    "urls": attr.string_dict(doc = "Platform -> download URL (a mirror)."),
})

def _pins(tag):
    return struct(
        version = tag.version,
        release_tag = tag.release_tag,
        sha512 = dict(tag.sha512),
        sha256 = dict(tag.sha256),
        urls = dict(tag.urls),
    )

def _tags_by_name(mod):
    repos = {}
    for tag in mod.tags.version:
        pins = _pins(tag)
        prev = repos.get(tag.name)
        if prev != None and prev != pins:
            fail("rules_clickhouse: {} sets clickhouse.version(name = \"{}\") twice, differently ({} and {}); set one.".format(
                "the root module" if mod.is_root else mod.name,
                tag.name,
                prev.version,
                pins.version,
            ))
        repos[tag.name] = pins
    return repos

def _impl(mctx):
    # The extension runs once for the whole build and sees every module's
    # tags; the repos it creates are global to it, so each name is created
    # once. rules_clickhouse's MODULE.bazel imports `@clickhouse` and
    # registers its toolchains for every consumer, so its own tags are the
    # base and the root module's override them by name (or add names).
    # Other modules' tags are ignored. A root without clickhouse.version()
    # gets DEFAULT_VERSION.
    own, root = {}, {}
    for mod in mctx.modules:
        if mod.is_root:
            root = _tags_by_name(mod)
        elif mod.name == "rules_clickhouse":
            own = _tags_by_name(mod)
    repos = {"clickhouse": struct(version = DEFAULT_VERSION, release_tag = "", sha512 = {}, sha256 = {}, urls = {})}
    repos.update(own)
    repos.update(root)
    for name, pins in repos.items():
        if pins.version not in CLICKHOUSE_VERSIONS and not (pins.sha512 or pins.sha256):
            fail(("rules_clickhouse: clickhouse.version(version = \"{}\") is not supported. Supported: {}. " +
                  "For another release, pin it yourself: clickhouse.version(version = ..., " +
                  "release_tag = \"v<version>-stable\", sha512 = {{<platform>: <hex from the .sha512 file>}}); " +
                  "platforms: {}.").format(
                pins.version,
                ", ".join(sorted(CLICKHOUSE_VERSIONS.keys())),
                ", ".join(sorted(PLATFORMS.keys())),
            ))
        clickhouse_version_repository(
            name = name,
            version = pins.version,
            release_tag = pins.release_tag,
            sha512 = pins.sha512,
            sha256 = pins.sha256,
            urls = pins.urls,
        )
    return mctx.extension_metadata(reproducible = True)

clickhouse = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
