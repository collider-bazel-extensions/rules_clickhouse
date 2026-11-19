# rules_clickhouse

Bazel rules for a hermetic, per-test [ClickHouse](https://clickhouse.com) server. Each test gets its own pinned `clickhouse server`:

- it listens on two free loopback ports, HTTP and native TCP, with every other listener off;
- its data, logs and every other file live in a throwaway directory inside `$TEST_TMPDIR`;
- a schema or ordered migrations, and optional seed data, run before the test starts;
- the test gets the ports, a database name and ready-made DSNs in `CLICKHOUSE_*` variables;
- the server stops when the test ends.

The rules:

- `clickhouse_schema` — ordered SQL migration files.
- `clickhouse_server` — the long-running server. It writes `$TEST_TMPDIR/<name>.env` once ready, and can be stopped and started again mid-test.
- `clickhouse_health_check` — pairs with `clickhouse_server` for `itest_service` ([rules_itest](https://github.com/dzbarsky/rules_itest)).
- `clickhouse_test` — an `sh_test` macro with an auto-launched server and the `ch` helpers.

No host ClickHouse is needed. The binary is upstream's own release build (`clickhouse-common-static`), pinned by version with upstream's SHA-512 and downloaded only for the platform a build needs. It runs offline: the tests in this repo run with the sandbox network blocked. The rules need `python3` on the host.

**Platforms:** Linux x86_64 and arm64 (tested on x86_64). macOS binaries are pinned too, but untested; see [Platforms](#platforms).

## Installation

rules_clickhouse is not in the BCR. Add it to `MODULE.bazel`:

```python
bazel_dep(name = "rules_clickhouse", version = "0.1.0")
archive_override(
    module_name = "rules_clickhouse",
    urls = ["https://github.com/collider-bazel-extensions/rules_clickhouse/archive/refs/tags/v0.1.0.tar.gz"],
    strip_prefix = "rules_clickhouse-0.1.0",
    integrity = "sha256-fmKpkGUOsR0yAaa1Ah+6E8o8Rj+q5653muRQGxwCbqM=",
)
```

That's all the wiring. rules_clickhouse's own `MODULE.bazel` pins ClickHouse 26.10.6.18 and registers the toolchains.

To use another version, set it in your root module, which overrides rules_clickhouse's:

```python
clickhouse = use_extension("@rules_clickhouse//:extensions.bzl", "clickhouse")
clickhouse.version(version = "26.10.6.18")    # pinned in private/versions.bzl
```

A release not pinned in `private/versions.bzl` needs its own hashes, from upstream's `.sha512` files next to each archive. `tools/update_versions.sh <version>` prints them:

```python
clickhouse.version(
    version = "26.8.40.7",
    release_tag = "v26.8.40.7-lts",           # default: v<version>-stable
    sha512 = {
        "linux_amd64": "<hex from clickhouse-common-static-26.8.40.7-amd64.tgz.sha512>",
        "linux_arm64": "<hex from clickhouse-common-static-26.8.40.7-arm64.tgz.sha512>",
    },
    # sha256 = {"darwin_arm64": "<GitHub asset digest>"},   # macOS has no .sha512 file
    # urls = {"linux_amd64": "https://mirror.example/..."},
)
```

- An unpinned version without hashes fails at resolution, naming `clickhouse.version`.
- A platform without a hash fails only when a build needs that platform.
- Only the root module's tags and rules_clickhouse's own are read; other modules' tags are ignored.

The release archive (the tag tarball) leaves out `tests/` and `tools/`, whose packages load dev-only modules, so `bazel query @rules_clickhouse//...` works for consumers.

## Quickstart

```
db/
  001_events.sql
  002_meters.sql
```

```python
load("@rules_clickhouse//:defs.bzl", "clickhouse_schema", "clickhouse_test")

clickhouse_schema(
    name = "schema",
    srcs = glob(["db/*.sql"]),        # applied in this (sorted) order
)

clickhouse_test(
    name = "events_test",
    srcs = ["events_test.sh"],
    schema = ":schema",
    seed = ["fixtures/events.csv"],   # into the table `events`
    data = [":my_service"],
)
```

```sh
# events_test.sh
source "$CLICKHOUSE_TESTLIB"
./my_service --clickhouse "$CLICKHOUSE_DSN" &
ch_wait 3 "SELECT count() FROM events WHERE subject = 'customer-1'"
[[ "$(ch_http "SELECT sum(value) FROM events")" == 42 ]]
```

## `clickhouse_schema`

```python
clickhouse_schema(
    name = "schema",
    srcs = [                          # .sql files, applied in this order
        "db/001_events.sql",
        "db/002_meters.sql",
    ],
)
```

Each file may hold any number of statements, separated by `;`. It runs through `clickhouse client --multiquery` against the server's database, so unqualified table names land there. The database is created first (`CREATE DATABASE IF NOT EXISTS`).

`glob()` sorts by name, so give migrations numeric prefixes, or list them yourself.

**A failing migration fails the start.** The message names the file, its position in the list, the line where the failing statement starts, the statement and ClickHouse's error. The server is stopped, no env file is written and the test body never runs:

```
[clickhouse] applied migration 1/2: tests/testdata/migrations/001_events.sql
[clickhouse] migration 2/2 tests/testdata/bad_migrations/002_bad.sql failed, line 4:
  statement:
    ALTER TABLE events ADD COLUMN value NoSuchType;
  error:
    Received exception from server (version 26.9.32):
    Code: 50. DB::Exception: Received from 127.0.0.1:…. DB::Exception: Unknown data type family: NoSuchType. (UNKNOWN_TYPE)
```

Statements before the failing one have run; ClickHouse DDL isn't transactional.

## `clickhouse_test`

```python
clickhouse_test(
    name = "db_test",
    srcs = ["db_test.sh"],
    schema = ":schema",
    seed = ["fixtures/seed.sql", "fixtures/events.csv"],
    database = "openmeter",
    password = "s3cret",
    config = ["clickhouse/settings.xml"],
    users = ["clickhouse/users.xml"],
)
```

What the test sees, also written to `$TEST_TMPDIR/<server name>.env` (shell-quoted `KEY=value` lines). These names are a stable interface:

| Variable | Example | |
|---|---|---|
| `CLICKHOUSE_HOST` | `127.0.0.1` | always loopback |
| `CLICKHOUSE_HTTP_PORT` | `41237` | HTTP interface |
| `CLICKHOUSE_NATIVE_PORT` | `41239` | native TCP protocol (clickhouse-go, `clickhouse client`) |
| `CLICKHOUSE_NATIVE_ADDR` | `127.0.0.1:41239` | host:port, as clickhouse-go's `Addr` and OpenMeter's `address` take it |
| `CLICKHOUSE_DATABASE` | `test` | the database the migrations ran in |
| `CLICKHOUSE_USER` | `default` | |
| `CLICKHOUSE_PASSWORD` | (empty) | always set; empty unless `password` is |
| `CLICKHOUSE_HTTP_URL` | `http://127.0.0.1:41237` | no path or credentials; send `X-ClickHouse-User` / `X-ClickHouse-Key` (or basic auth) and `?database=` |
| `CLICKHOUSE_DSN` | `clickhouse://default@127.0.0.1:41239/test` | native DSN; with a password `clickhouse://default:<percent-encoded>@…` |
| `CLICKHOUSE_VERSION` | `26.10.6.18` | the server's version |
| `CLICKHOUSE_BIN` | `…/bin/clickhouse` | the multi-call binary (`clickhouse client`, `clickhouse local`); also on `PATH` as `clickhouse` |
| `CLICKHOUSE_CLIENT_CONFIG` | `…/client.xml` | `clickhouse client -C` this file to connect (host, port, user, password) |
| `CLICKHOUSE_STATE_DIR` | `$TEST_TMPDIR/clickhouse-<name>` | everything the server writes |
| `CLICKHOUSE_LOG`, `CLICKHOUSE_ERROR_LOG` | `…/log/clickhouse-server.log`, `….err.log` | the server's logs |
| `CLICKHOUSE_CONTROL_URL` | `http://127.0.0.1:41241` | the launcher's control endpoint (`clickhouse_stop` / `clickhouse_start`) |
| `CLICKHOUSE_TESTLIB` | | shell helpers (`clickhouse_test` only) |

`clickhouse client` itself reads `CLICKHOUSE_HOST`, `CLICKHOUSE_USER` and `CLICKHOUSE_PASSWORD`, but not a port; use `ch`, or pass `--port "$CLICKHOUSE_NATIVE_PORT"`.

| Helper | |
|---|---|
| `ch "SQL"` | runs the SQL (one or more statements) with `clickhouse client` in `$CLICKHOUSE_DATABASE`; prints the result as TabSeparated |
| `ch [client args…]` | `clickhouse client` with these arguments, e.g. `ch --format CSV --query "…"`; with no arguments, reads SQL from stdin: `ch < fixtures.sql` |
| `ch_http "SQL"` | the same over HTTP; reads SQL from stdin when no argument is given; fails with the HTTP status and ClickHouse's error |
| `ch_wait EXPECTED "SQL"` | waits until `ch "SQL"` prints `EXPECTED` (`$CH_WAIT_TIMEOUT`, default 30 s) |
| `clickhouse_stop` | stops the server (SIGTERM, a clean shutdown) |
| `clickhouse_start` | starts it again on the same ports, with the same config, password and data; waits for `/ping`. Migrations and seeds do not run again |

| Argument (`clickhouse_test` and `clickhouse_server`) | Default | |
|---|---|---|
| `schema` | none | a `clickhouse_schema` |
| `seed` | `[]` | loaded after the migrations, in order: `.sql` files (statements), `.csv` / `.tsv` files with a header row (into the table named by the file's basename, in `database`) |
| `database` | `"test"` | created before the migrations; the default database for them, the seeds and `ch` |
| `password` | none | the `default` user's password |
| `config` | `[]` | server config fragments (`<clickhouse>…</clickhouse>`), merged in order over rules_clickhouse's config; see [Config](#config) |
| `users` | `[]` | users config fragments: profiles, quotas, more users |
| `ready_timeout` | `60` | seconds to wait for `/ping` |
| `extra_args` | `[]` | server setting overrides, `--<setting>=<value>`, e.g. `["--max_server_memory_usage=2000000000"]` |
| `args`, `env`, `data`, `deps`, `size` (`"medium"`), `timeout`, `tags`, `shard_count`, … | | as for `sh_test` (`clickhouse_test` only) |

**Readiness.** The server is ready when `GET /ping` answers `Ok.` and the native port accepts connections. Then the database is created and the migrations and seeds run. ClickHouse 26.9 is ready in about 1 s on an idle machine; under parallel load, several seconds. The launcher logs the times:

```
[clickhouse] ClickHouse 26.10.6.18 ready on 127.0.0.1: HTTP 41237, native 41239, database test; started in 0.93s, migrated and seeded in 0.61s; env file …
```

**Failures.** If the server refuses its config, exits or isn't ready within `ready_timeout`, or a migration or seed fails, the start fails. The message names the cause and shows the server's own errors: the `<Error>` lines of its error log without stack traces, or its log's tail. The test body never runs.

If the server exits **while the test runs**, other than through `clickhouse_stop`, the test is stopped at once with everything it started. It fails with the server's exit status and the end of its error log.

**Stopping and starting.** These exercise clients that must fail while the database is down and recover when it returns:

```sh
source "$CLICKHOUSE_TESTLIB"
clickhouse_stop
! ./my_client query              # must fail, not hang
clickhouse_start                 # same ports, same data
```

- **What comes back:** MergeTree tables keep their data; `Memory` tables come back empty.
- **A taken port:** if another process has taken a port meanwhile, `clickhouse_start` retries 5 times, 0.2 s apart. It then fails with `clickhouse_start: 500: … another process holds HTTP port <port> (Address already in use)`.
- **From other languages:** `POST $CLICKHOUSE_CONTROL_URL/stop` and `/start`.

Each test gets its own server, with its own ports and data, so tests are safe under `--jobs=N` and `shard_count`.

## `clickhouse_server` + `clickhouse_health_check` (rules_itest)

```python
load("@rules_clickhouse//:defs.bzl", "clickhouse_health_check", "clickhouse_server")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")

clickhouse_server(name = "clickhouse", schema = ":schema", tags = ["manual"])
clickhouse_health_check(name = "clickhouse_health", server = ":clickhouse", tags = ["manual"])

itest_service(
    name = "clickhouse_svc",
    exe = ":clickhouse",
    health_check = ":clickhouse_health",
)

service_test(
    name = "app_test",
    services = [":clickhouse_svc", ":app_svc"],
    test = ":app_test_bin",
)
```

The server writes `$TEST_TMPDIR/clickhouse.env` (named after the target) with the variables above. A service in any language reads it, or takes `CLICKHOUSE_DSN` from a wrapper that sources it. SIGTERM stops the server, removes the file and exits 0. `//tests:itest_test` is a working composition.

## Isolation

Everything the server writes is under `$TEST_TMPDIR/clickhouse-<name>/`:

```
config.xml  config.d/  users.xml  users.d/  client.xml    generated config
data/            path: metadata, store (parts), preprocessed_configs, …
tmp/             tmp_path; TMPDIR for the server and clients
user_files/  format_schemas/  user_scripts/  user_defined/ (SQL UDFs)  access/ (SQL users)
log/             clickhouse-server.log, clickhouse-server.err.log, stdout.log
clickhouse-server.pid
```

- The server runs with that directory as its working directory and `HOME`. It gets no `CLICKHOUSE_*` variables from the caller, and its watchdog fork is off.
- It listens on `127.0.0.1` only, on the two ports. MySQL, PostgreSQL, interserver HTTP(S), gRPC, Prometheus, Keeper, HTTPS and secure native TCP are not configured, so none of them listen.
- Crash reports are off; ClickHouse has no other telemetry or update check. The server needs no network: every test here runs with `block-network`.
- The server's timezone is UTC unless a config fragment sets one.

`//tests:isolation_test` checks this. The server runs from a read-only working directory with a read-only `HOME` and `TMPDIR`, and the test makes it write everything it can: parts, a merge, a SQL function, a `file()` export, a user, an external sort. It then checks that the server listens on exactly its two loopback ports, and that no file outside `$TEST_TMPDIR` changed.

## Config

`config` takes server config fragments, merged in order over rules_clickhouse's base config (they go into `config.d/`):

```xml
<clickhouse>
    <timezone>Europe/Berlin</timezone>
    <max_table_size_to_drop>0</max_table_size_to_drop>
    <macros><shard>01</shard></macros>
</clickhouse>
```

A production config can be used as is: rules_clickhouse drops the settings it owns from each fragment before staging it, and logs what it dropped. These are:

- paths: `path`, `tmp_path`, `user_files_path`, `format_schema_path`, `user_scripts_path`, `user_defined_path`, `user_directories`, `access_control_path`, …;
- listeners: `listen_host`, `http_port`, `tcp_port`, `mysql_port`, `postgresql_port`, `interserver_http_port`, `grpc_port`, `prometheus`, `keeper_server`, …;
- the log files (`logger/log`, `logger/errorlog`, `logger/console`; the log `level` applies);
- `send_crash_reports`.

`extra_args` may not set them either; that fails at analysis. Everything else applies as written: settings, macros, caches, merge-tree settings. A fragment that isn't XML fails the start, naming the file.

`users` fragments go into `users.d/`: profiles, quotas, more users. The `default` user's password and networks stay rules_clickhouse's, because the launcher and `ch` log in as it.

Not neutralised: disk paths inside `storage_configuration`, and remote servers or ZooKeeper, which the test can't reach offline anyway. Keep those out of test fragments.

## Platforms

| Platform | Asset | Pin | Status |
|---|---|---|---|
| `linux_amd64` | `clickhouse-common-static-<ver>-amd64.tgz` | SHA-512 from upstream's `.sha512` | tested (this repo's suite) |
| `linux_arm64` | `clickhouse-common-static-<ver>-arm64.tgz` | SHA-512 from upstream's `.sha512` | pinned, verified against the download; not run here |
| `darwin_amd64` | `clickhouse-macos` | SHA-256: the GitHub release asset digest (upstream publishes no checksum file) | pinned, verified against the download; **untested** |
| `darwin_arm64` | `clickhouse-macos-aarch64` | as above | pinned, verified against the download; **untested** |

The Linux archive is about 250 MB, and the binary in it about 840 MB. Each platform's binary is its own repository, fetched only when a build resolves the toolchain for that platform, so a Linux build never downloads macOS binaries. With `--repository_cache` (on by default) it's downloaded once per machine.

## Pinned versions

| Version | Release | Default |
|---|---|---|
| 26.10.6.18 | [v26.10.6.18-stable](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.10.6.18-stable) | yes |
| 26.9.32.8 | [v26.9.32.8-stable](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.9.32.8-stable) | |

The hashes are in `private/versions.bzl`, generated by `tools/update_versions.sh`:

```sh
tools/update_versions.sh 26.10.6.18 26.9.32.8   # regenerate: downloads every asset and verifies it
tools/update_versions.sh --check                # regenerate from the checksum files only, and diff
```

The first version given becomes `DEFAULT_VERSION`; also bump `clickhouse.version()` in `MODULE.bazel`. CI runs `--check`.

## Development

```sh
bazel test //tests/...           # the whole suite; linux-sandbox (block-network)
.github/consumer/check.sh /tmp/rc-consumer
```

To find stray servers, use `pgrep -x clickhouse` (an exact process name). Never use `pkill -f` with a pattern: the pattern matches the shell running it.

See [DESIGN.md](DESIGN.md) for the decisions behind these rules.

## License

[Apache License 2.0](LICENSE) (SPDX: `Apache-2.0`).

ClickHouse itself, which these rules download, is under its own Apache 2.0 licence.

---

## Requesting a new rules package

Want Bazel rules for another tool or service?
[Request a rules package](https://github.com/collider-bazel-extensions/.github/issues/new?template=request-a-rules-package.yml).
The [organization page](https://github.com/collider-bazel-extensions) lists every package.
