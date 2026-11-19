"""clickhouse_server + clickhouse_health_check: hermetic ClickHouse test fixtures.

`clickhouse_server` is a long-running executable (see launcher.py): one
`clickhouse server` on two free 127.0.0.1 ports (HTTP and native TCP; every
other listener off), with all of its files under
`$TEST_TMPDIR/clickhouse-<name>/`. Once `/ping` answers `Ok.` and the
migrations and seeds have run, it writes `$TEST_TMPDIR/<name>.env` (the
CLICKHOUSE_* variables, see the README) and runs until SIGTERM.
`clickhouse_health_check` exits 0 iff that file exists; it drops into
`itest_service.health_check`.
"""

load(":providers.bzl", "ClickHouseSchemaInfo")

_TOOLCHAIN = "//toolchain:clickhouse"

ClickHouseServerInfo = provider(
    doc = "A clickhouse_server target.",
    fields = {
        "binary": "ClickHouseBinaryInfo: the toolchain's binary.",
        "database": "string: the database the server creates and exports.",
    },
)

# Server settings rules_clickhouse owns: paths, listeners, logging and
# telemetry. `extra_args` may not set them, and the launcher drops them from
# `config` files (keep in sync with launcher.py's _FORCED).
FORCED_SETTINGS = [
    "path",
    "tmp_path",
    "user_files_path",
    "format_schema_path",
    "user_scripts_path",
    "user_defined_path",
    "dictionaries_lib_path",
    "top_level_domains_path",
    "custom_cached_disks_base_directory",
    "filesystem_caches_path",
    "access_control_path",
    "user_directories",
    "users_config",
    "include_from",
    "listen_host",
    "listen_try",
    "listen_reuse_port",
    "http_port",
    "tcp_port",
    "https_port",
    "tcp_port_secure",
    "tcp_with_proxy_port",
    "mysql_port",
    "postgresql_port",
    "interserver_http_port",
    "interserver_https_port",
    "interserver_http_host",
    "interserver_https_host",
    "grpc_port",
    "grpc",
    "prometheus",
    "keeper_server",
    "arrowflight_port",
    "send_crash_reports",
    "logger.log",
    "logger.errorlog",
    "logger.console",
]

_IDENT_FIRST = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_"
_IDENT = _IDENT_FIRST + "0123456789"

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

def check_timeout(label, value):
    """Validate a timeout attribute: a positive number of seconds."""
    raw = value.strip()
    digits = raw.replace(".", "", 1)
    if not raw or not digits.isdigit() or not digits.replace("0", ""):
        fail("{}: ready_timeout = {}: expected a positive number of seconds.".format(
            label,
            repr(value),
        ))
    return raw

def check_database(label, db):
    if not db or db[0] not in _IDENT_FIRST.elems() or [c for c in db.elems() if c not in _IDENT.elems()]:
        fail("{}: database = {}: expected an identifier ([A-Za-z_][A-Za-z0-9_]*).".format(label, repr(db)))

def check_extra_args(label, extra_args):
    for a in extra_args:
        if not a.startswith("--") or "=" not in a:
            fail("{}: extra_args: {}: expected a server setting override, --<setting>=<value> (e.g. --max_server_memory_usage=2000000000).".format(
                label,
                repr(a),
            ))
        key = a[2:].split("=", 1)[0]
        top = key.split(".")[0]
        if key in FORCED_SETTINGS or top in FORCED_SETTINGS:
            fail("{}: extra_args: --{} is set by rules_clickhouse (paths, listeners, logging and telemetry stay inside $TEST_TMPDIR and on free loopback ports).".format(
                label,
                key,
            ))

def _resolved(flag, path):
    # Resolved into a variable first: a failing $(resolve) inside an
    # argument list would not stop the script under `set -e`.
    return "p=\"$(resolve {})\"; opts+=({} \"$p\")".format(_shell_quote(path), flag)

def _clickhouse_server_impl(ctx):
    ch = ctx.toolchains[_TOOLCHAIN].clickhouse
    check_database(ctx.label, ctx.attr.database)
    check_extra_args(ctx.label, ctx.attr.extra_args)
    if "\n" in ctx.attr.password:
        fail("{}: password must be one line.".format(ctx.label))

    lines = []
    files = []
    if ctx.attr.schema:
        for f in ctx.attr.schema[ClickHouseSchemaInfo].migrations:
            lines.append(_resolved("--migration", f.short_path))
            files.append(f)
    for f in ctx.files.seed:
        lines.append(_resolved("--seed", f.short_path))
        files.append(f)
    for f in ctx.files.config:
        lines.append(_resolved("--config", f.short_path))
        files.append(f)
    for f in ctx.files.users:
        lines.append(_resolved("--users", f.short_path))
        files.append(f)
    opts = ["--database", ctx.attr.database]
    if ctx.attr.password:
        opts += ["--password", ctx.attr.password]

    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {
            "__NAME__": ctx.label.name,
            "__LAUNCHER__": ctx.file._launcher.short_path,
            "__CLICKHOUSE__": ch.clickhouse.short_path,
            "__VERSION__": ch.version,
            "__READY_TIMEOUT__": check_timeout(ctx.label, ctx.attr.ready_timeout),
            "__FILES__": "\n".join(lines),
            "__OPTS__": " ".join([_shell_quote(o) for o in opts]),
            "__EXTRA_ARGS__": " ".join([_shell_quote(a) for a in ctx.attr.extra_args]),
        },
        is_executable = True,
    )
    runfiles = ctx.runfiles(files = [wrapper, ctx.file._launcher] + files, transitive_files = ch.files)
    return [
        DefaultInfo(executable = wrapper, runfiles = runfiles),
        ClickHouseServerInfo(binary = ch, database = ctx.attr.database),
    ]

clickhouse_server = rule(
    implementation = _clickhouse_server_impl,
    executable = True,
    doc = """\
Long-running `clickhouse server` for tests and rules_itest compositions.
Writes `$TEST_TMPDIR/<name>.env` once `/ping` answers `Ok.` and the
schema's migrations and the seed files have run. If the server refuses its
config, exits, isn't ready within `ready_timeout`, or a migration or seed
fails, it exits non-zero naming the cause (and the file and statement),
with the tail of the server's error log.
""",
    attrs = {
        "schema": attr.label(
            providers = [ClickHouseSchemaInfo],
            doc = "A clickhouse_schema: migrations applied, in order, to `database`.",
        ),
        "seed": attr.label_list(
            allow_files = [".sql", ".csv", ".tsv"],
            doc = "Seed files loaded after the migrations, in order: `.sql` " +
                  "(statements), `.csv` / `.tsv` (with a header row, into the " +
                  "table named by the file's basename in `database`).",
        ),
        "database": attr.string(
            default = "test",
            doc = "Database created before the migrations, the default database " +
                  "for migrations, seeds and `ch`, exported as CLICKHOUSE_DATABASE.",
        ),
        "password": attr.string(
            doc = "Password for the `default` user (none by default). Exported " +
                  "as CLICKHOUSE_PASSWORD and in CLICKHOUSE_DSN.",
        ),
        "config": attr.label_list(
            allow_files = [".xml"],
            doc = "Server config fragments (`<clickhouse>...</clickhouse>`), " +
                  "merged in order over rules_clickhouse's config (config.d). " +
                  "Settings rules_clickhouse owns (paths, listeners, logging " +
                  "files, crash reports) are dropped from them, with a note.",
        ),
        "users": attr.label_list(
            allow_files = [".xml"],
            doc = "Users config fragments (users.d): profiles, quotas, more " +
                  "users. The `default` user's password and networks stay " +
                  "rules_clickhouse's.",
        ),
        "ready_timeout": attr.string(
            default = "60",
            doc = "Seconds to wait for /ping (the migrations and seeds then " +
                  "run without a deadline of their own).",
        ),
        "extra_args": attr.string_list(
            doc = "Server setting overrides, `--<setting>=<value>`, passed " +
                  "after `--` (e.g. `--max_server_memory_usage=2000000000`).",
        ),
        "_launcher": attr.label(default = "//private:launcher.py", allow_single_file = True),
        "_tmpl": attr.label(default = "//private:server.sh.tmpl", allow_single_file = True),
    },
    toolchains = [_TOOLCHAIN],
)

# ---- clickhouse_health_check -------------------------------------------------

def _clickhouse_health_check_impl(ctx):
    wrapper = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._tmpl,
        output = wrapper,
        substitutions = {"__ENV_FILE_NAME__": ctx.attr.server.label.name + ".env"},
        is_executable = True,
    )
    return [DefaultInfo(executable = wrapper)]

clickhouse_health_check = rule(
    implementation = _clickhouse_health_check_impl,
    executable = True,
    doc = "Exits 0 iff the paired clickhouse_server's env file exists (it is " +
          "written once the server is ready, migrated and seeded).",
    attrs = {
        "server": attr.label(
            mandatory = True,
            providers = [ClickHouseServerInfo],
            doc = "The clickhouse_server this check pairs with.",
        ),
        "_tmpl": attr.label(default = "//private:health_check.sh.tmpl", allow_single_file = True),
    },
)
