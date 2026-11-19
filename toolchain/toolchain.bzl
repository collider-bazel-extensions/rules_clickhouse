"""clickhouse_toolchain exposes the platform's ClickHouse binary as a
`ToolchainInfo`, so rules resolve it through
`ctx.toolchains["@rules_clickhouse//toolchain:clickhouse"]`.

`current_clickhouse_toolchain` forwards it as a plain target (files and
runfiles), for `data = [...]` in tests.
"""

load("//private:providers.bzl", "ClickHouseBinaryInfo")

CLICKHOUSE_TOOLCHAIN_TYPE = Label("//toolchain:clickhouse")

def _toolchain_impl(ctx):
    files = depset([ctx.file.clickhouse])
    info = ClickHouseBinaryInfo(
        version = ctx.attr.version,
        clickhouse = ctx.file.clickhouse,
        files = files,
    )
    return [
        platform_common.ToolchainInfo(clickhouse = info),
        DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files)),
    ]

clickhouse_toolchain = rule(
    implementation = _toolchain_impl,
    attrs = {
        "version": attr.string(mandatory = True),
        "clickhouse": attr.label(allow_single_file = True, mandatory = True),
    },
)

def _current_impl(ctx):
    info = ctx.toolchains[CLICKHOUSE_TOOLCHAIN_TYPE].clickhouse
    return [
        info,
        DefaultInfo(files = info.files, runfiles = ctx.runfiles(transitive_files = info.files)),
    ]

current_clickhouse_toolchain = rule(
    implementation = _current_impl,
    toolchains = [CLICKHOUSE_TOOLCHAIN_TYPE],
    doc = "The resolved ClickHouse binary, as files and runfiles.",
)
