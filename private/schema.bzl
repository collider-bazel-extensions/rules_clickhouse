"""clickhouse_schema: an ordered list of SQL migration files."""

load(":providers.bzl", "ClickHouseSchemaInfo")

def _clickhouse_schema_impl(ctx):
    migrations = ctx.files.srcs
    return [
        DefaultInfo(files = depset(migrations, order = "preorder")),
        ClickHouseSchemaInfo(migrations = migrations),
    ]

clickhouse_schema = rule(
    implementation = _clickhouse_schema_impl,
    doc = """\
SQL migration files, applied in the order of `srcs` to the server's
database (`clickhouse client --multiquery`, one file at a time) before
the server counts as ready. A file may hold any number of statements.
Use numeric prefixes so a glob sorts into application order:

    clickhouse_schema(
        name = "schema",
        srcs = glob(["migrations/*.sql"]),   # 001_events.sql, 002_meters.sql, ...
    )
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".sql"],
            mandatory = True,
            doc = "SQL migration files, in application order.",
        ),
    },
)
