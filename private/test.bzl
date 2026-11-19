"""clickhouse_test: an sh_test with an auto-launched ClickHouse server.

Each target gets its own clickhouse_server (own ports, own data under its
$TEST_TMPDIR), so tests are safe under `--jobs=N`.

The trampoline (clickhouse_test_trampoline.sh) starts the server, waits for
its env file, sources it (the CLICKHOUSE_* variables), puts `clickhouse` on
PATH, exports CLICKHOUSE_TESTLIB and runs the test with the target's args.
It runs the test rather than exec'ing it, so it can stop the server when
the test ends, and stops the test if the server dies under it.
"""

load("@rules_shell//shell:sh_binary.bzl", "sh_binary")
load("@rules_shell//shell:sh_test.bzl", "sh_test")
load(":server.bzl", "clickhouse_server")

def clickhouse_test(
        name,
        srcs,
        schema = None,
        seed = None,
        database = "test",
        password = None,
        config = None,
        users = None,
        ready_timeout = 60,
        extra_args = None,
        deps = None,
        data = None,
        args = None,
        size = "medium",
        timeout = None,
        tags = None,
        **kwargs):
    """sh_test against an auto-launched ClickHouse server.

    Args:
      name: target name.
      srcs: the test script (one file).
      schema: a clickhouse_schema; its migrations run, in order, before the test.
      seed: .sql / .csv / .tsv files loaded after the migrations.
      database: the database to create and use (CLICKHOUSE_DATABASE).
      password: password for the `default` user.
      config: server config fragments (.xml), merged over rules_clickhouse's.
      users: users config fragments (.xml).
      ready_timeout: seconds to wait for /ping.
      extra_args: server setting overrides, `--<setting>=<value>`.
      deps: forwarded to the inner sh_binary.
      data: runfiles for the test (on the inner sh_binary and the sh_test,
        so `args` may use $(rootpath) on them).
      args: arguments for the test script.
      size: sh_test size. Default "medium" (ClickHouse starts in about a
        second, slower on a loaded machine).
      timeout: sh_test timeout.
      tags: tags for the sh_test (helper targets also get "manual").
      **kwargs: forwarded to sh_test (env, env_inherit, flaky, shard_count, ...).
    """
    tags = tags or []
    server_name = name + "_clickhouse"
    clickhouse_server(
        name = server_name,
        schema = schema,
        seed = seed or [],
        database = database,
        password = password or "",
        config = config or [],
        users = users or [],
        ready_timeout = str(ready_timeout),
        extra_args = extra_args or [],
        tags = tags + ["manual"],
        testonly = True,
    )

    inner_name = name + "_inner"
    sh_binary(
        name = inner_name,
        srcs = srcs,
        deps = deps,
        data = data,
        tags = tags + ["manual"],
        testonly = True,
    )

    sh_test(
        name = name,
        srcs = [Label("//private:clickhouse_test_trampoline.sh")],
        args = [
            "$(rootpath :{})".format(server_name),
            "$(rootpath :{})".format(inner_name),
            server_name,
            "$(rootpath {})".format(Label("//private:testlib.sh")),
        ] + (args or []),
        # `data` here too, so `args` can use $(rootpath) on it.
        data = [
            ":" + server_name,
            ":" + inner_name,
            Label("//private:testlib.sh"),
        ] + (data or []),
        size = size,
        timeout = timeout,
        tags = tags,
        **kwargs
    )
