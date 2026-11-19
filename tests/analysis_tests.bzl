"""Analysis-time tests: providers, executables, and the analysis errors for
bad attributes."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load(
    "@rules_clickhouse//:defs.bzl",
    "ClickHouseSchemaInfo",
    "ClickHouseServerInfo",
    "clickhouse_health_check",
    "clickhouse_server",
)
load("@rules_clickhouse//private:versions.bzl", "DEFAULT_VERSION")

def _has_executable_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.true(env, target[DefaultInfo].files_to_run.executable != None, "expected an executable")
    return analysistest.end(env)

_has_executable_test = analysistest.make(_has_executable_impl)

def _server_info_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[ClickHouseServerInfo]
    asserts.equals(env, DEFAULT_VERSION, info.binary.version)
    asserts.equals(env, "events_db", info.database)
    asserts.equals(env, "clickhouse", info.binary.clickhouse.basename)

    # The binary, the launcher and every migration are in the runfiles.
    runfiles = [f.short_path for f in target[DefaultInfo].default_runfiles.files.to_list()]
    for want in ("private/launcher.py", "tests/testdata/migrations/001_events.sql", "tests/testdata/seed.sql"):
        asserts.true(env, want in runfiles, "{} not in runfiles".format(want))
    asserts.true(env, info.binary.clickhouse.short_path in runfiles, "binary not in runfiles")
    return analysistest.end(env)

_server_info_test = analysistest.make(_server_info_impl)

def _schema_order_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[ClickHouseSchemaInfo]
    asserts.equals(
        env,
        ["001_events.sql", "002_value.sql", "003_backfill.sql"],
        [f.basename for f in info.migrations],
    )
    return analysistest.end(env)

_schema_order_test = analysistest.make(_schema_order_impl)

def _bad_schema_order_impl(ctx):
    env = analysistest.begin(ctx)
    info = analysistest.target_under_test(env)[ClickHouseSchemaInfo]
    asserts.equals(env, ["001_events.sql", "002_bad.sql"], [f.basename for f in info.migrations])
    return analysistest.end(env)

_bad_schema_order_test = analysistest.make(_bad_schema_order_impl)

def _fails_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.message)
    return analysistest.end(env)

_fails_test = analysistest.make(
    _fails_impl,
    expect_failure = True,
    attrs = {"message": attr.string()},
)

def analysis_test_suite(name):
    s = name + "_subject"
    clickhouse_server(
        name = s + "_server",
        schema = "//tests/testdata:schema",
        seed = ["//tests/testdata:seed.sql"],
        database = "events_db",
        tags = ["manual"],
    )
    clickhouse_health_check(name = s + "_health", server = ":" + s + "_server", tags = ["manual"])
    clickhouse_server(name = s + "_bad_timeout", ready_timeout = "soon", tags = ["manual"])
    clickhouse_server(name = s + "_zero_timeout", ready_timeout = "0", tags = ["manual"])
    clickhouse_server(name = s + "_bad_db", database = "my-db", tags = ["manual"])
    clickhouse_server(name = s + "_db_digit", database = "1db", tags = ["manual"])
    clickhouse_server(name = s + "_forced_arg", extra_args = ["--http_port=8123"], tags = ["manual"])
    clickhouse_server(name = s + "_forced_logger", extra_args = ["--logger.log=/var/log/x.log"], tags = ["manual"])
    clickhouse_server(name = s + "_forced_path", extra_args = ["--path=/var/lib/clickhouse"], tags = ["manual"])
    clickhouse_server(name = s + "_bare_arg", extra_args = ["--max_concurrent_queries", "5"], tags = ["manual"])
    clickhouse_server(name = s + "_multiline_pw", password = "a\nb", tags = ["manual"])

    tests = {
        "_info": (_server_info_test, s + "_server", None),
        "_schema_order": (_schema_order_test, "//tests/testdata:schema", None),
        "_bad_schema_order": (_bad_schema_order_test, "//tests/testdata:bad_schema", None),
        "_server_executable": (_has_executable_test, s + "_server", None),
        "_health_executable": (_has_executable_test, s + "_health", None),
        "_bad_timeout": (_fails_test, s + "_bad_timeout", "expected a positive number of seconds"),
        "_zero_timeout": (_fails_test, s + "_zero_timeout", "expected a positive number of seconds"),
        "_bad_db": (_fails_test, s + "_bad_db", "expected an identifier"),
        "_db_digit": (_fails_test, s + "_db_digit", "expected an identifier"),
        "_forced_arg": (_fails_test, s + "_forced_arg", "--http_port is set by rules_clickhouse"),
        "_forced_logger": (_fails_test, s + "_forced_logger", "--logger.log is set by rules_clickhouse"),
        "_forced_path": (_fails_test, s + "_forced_path", "--path is set by rules_clickhouse"),
        "_bare_arg": (_fails_test, s + "_bare_arg", "expected a server setting override, --<setting>=<value>"),
        "_multiline_pw": (_fails_test, s + "_multiline_pw", "password must be one line"),
    }
    for suffix, (rule, target, message) in tests.items():
        target_label = target if target.startswith("//") else ":" + target
        if message:
            rule(name = name + suffix, target_under_test = target_label, message = message)
        else:
            rule(name = name + suffix, target_under_test = target_label)
    native.test_suite(name = name, tests = [":" + name + t for t in tests])
