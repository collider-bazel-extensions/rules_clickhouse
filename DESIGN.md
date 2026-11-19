# rules_clickhouse — design notes

rules_clickhouse follows rules_valkey's shape: a toolchain, a Python launcher behind a long-running `clickhouse_server` executable, a health check for rules_itest, and an `sh_test` macro whose trampoline watches the server. Migrations follow rules_pg's `postgres_schema`, and version pins follow rules_argocd's extension. These notes cover what is specific to ClickHouse.

## Decisions

| Decision | Chosen | Instead of | Why |
|---|---|---|---|
| Binary | upstream's `clickhouse-common-static-<ver>-{amd64,arm64}.tgz` release archives | Docker images; distro packages; `builds.clickhouse.com` master builds | Official, versioned and checksummed (`.sha512` next to each archive). The binary links only glibc. |
| Hash | SHA-512 from upstream's `.sha512` file, passed to Bazel as an SRI `integrity` | computing our own SHA-256 | The pin is upstream's own; `tools/update_versions.sh` still downloads each archive and checks it. |
| macOS | pinned: `clickhouse-macos` / `clickhouse-macos-aarch64` release assets, SHA-256 from the GitHub asset digest | builds.clickhouse.com (no version pin) | The release carries macOS binaries but no checksum files. GitHub's digest is computed at upload, and the update script checks it against the download. **Not tested**: no macOS machine or CI job here. |
| Laziness | one repo per platform (`@clickhouse_<plat>`), referenced only from that platform's toolchain in the hub `@clickhouse` | one repo with every platform | The archive is about 250 MB and the binary in it about 840 MB. Toolchain resolution analyses only the selected toolchain, so a build fetches one platform. |
| Versions | `clickhouse.version()`: rules_clickhouse's tag is the base, the root's overrides by `name`; the tag takes `sha512` / `sha256` / `urls` for releases not in `private/versions.bzl` | rules_valkey's version-named repos; a fixed version | rules_argocd's pattern, as requested: a consumer moves to any release without a new rules_clickhouse. |
| Default version | 26.10.6.18 (`v26.10.6.18-stable`, the newest stable line on 2026-11-18); 26.9.32.8 pinned too | 26.9.32.8 as default | GitHub marks v26.9.32.8-stable "Latest" only because it was published last; 26.10 is the newer stable line. 26.9.32.8, the version the request named, stays pinned for `clickhouse.version()`. |
| Config | generate `config.xml`, `users.xml` and `client.xml` in the state dir | `--` overrides on upstream's default config | No default config ships in the archive. A full generated config states every path and listener explicitly, so nothing falls back to `/var/lib/clickhouse`. |
| User config | `config` / `users` XML fragments, staged into `config.d/` / `users.d/` with the settings rules_clickhouse owns removed | merging our overrides last (`replace="replace"`, `remove="1"`) | Tried first: ClickHouse merges repeated elements (`listen_host`) by position, so a user's second `listen_host` survived a `replace`. Dropping the owned elements before staging is exact, and mirrors rules_valkey's commented-out host directives. |
| `extra_args` | `--<setting>=<value>` only; owned settings fail at analysis | free-form server flags | They go after `--` and would override everything, including the isolation. |
| Listeners | `127.0.0.1`, HTTP and native on free ports; nothing else configured | free ports for MySQL / PostgreSQL / interserver / gRPC / Prometheus | Not configuring a listener turns it off. Fewer ports, fewer collisions, and the env contract stays two ports. `//tests:isolation_test` and `config_test` read `/proc` to check that exactly two loopback sockets listen. |
| Port races | pick two free ports, start with `listen_try=0`; on "Address already in use" retry with new ports (5 attempts) | `--socket-fd` style handoff | ClickHouse can't take an inherited socket. With `listen_try=0` a lost race fails fast and is retried. |
| Readiness | `GET /ping` returns `Ok.` and the native port accepts a connection | a `SELECT 1` through `clickhouse client` | Spawning the 840 MB client costs about 0.3 s on every poll; `/ping` is the documented health endpoint. The migrations then exercise the native port for real. |
| Migrations | one `clickhouse client --multiquery` per file, in `srcs` order; the database is created first over HTTP | splitting statements ourselves | ClickHouse's own parser handles comments, strings and multi-line statements. The client names the failing statement (`(query: …)`), and the launcher finds its line in the file. |
| Seeds | `.sql` like migrations; `.csv` / `.tsv` with a header row into the table named by the basename (`CSVWithNames` / `TSVWithNames`) | a separate `pg_seed_data`-style rule | Lists of files are enough. The basename-is-the-table rule is rules_pg's. |
| Environment of the server | cwd, `HOME` and `TMPDIR` inside the state dir; all `CLICKHOUSE_*` variables from the caller removed; `CLICKHOUSE_WATCHDOG_ENABLE=0` | inheriting the test's environment | The binary reads several `CLICKHOUSE_*` variables (client credentials, `CLICKHOUSE_CONFIG`, the watchdog), and a sourced env file sets some. Without the watchdog fork, the pid is the server itself. |
| Process group | the server runs in its own session | sharing the launcher's process group | `SYSTEM SHUTDOWN` signals the server's whole process group. In the first run of `server_died_test` it killed the launcher and the test along with it. |
| Telemetry | `send_crash_reports` off | | ClickHouse has no other phone-home or update check. Every test runs with `block-network`, and `network_blocked_test` checks the sandbox really blocks. |
| Timezone | UTC by default | the host's `/etc/localtime` | Test results shouldn't depend on the machine; a fragment can set another. |
| Password | plain `<password>` (XML-escaped) for `default`; `CLICKHOUSE_PASSWORD` always exported (empty without one) | omitting the variable | Consumers like rules_openmeter can pass it through unconditionally under `set -u`. The DSN percent-encodes it. |
| Env names | `CLICKHOUSE_HOST`, `_HTTP_PORT`, `_NATIVE_PORT`, `_NATIVE_ADDR`, `_DATABASE`, `_USER`, `_PASSWORD`, `_HTTP_URL`, `_DSN`, plus tooling ones | `CLICKHOUSE_PORT`; `CLICKHOUSE_DB` | `PORT` is ambiguous between the two protocols. `CLICKHOUSE_DB` and `CLICKHOUSE_DATA_DIR` are names the official Docker entrypoint gives other meanings. `CLICKHOUSE_HOST` / `_USER` / `_PASSWORD` match what `clickhouse client` reads. |
| Stop / start | control endpoint `POST /stop` and `/start` (rules_valkey's) | signals | `/start` must report whether the server came back. Restart reuses the same argv, ports and data dir, after a bind check with 5 retries 0.2 s apart. |
| Test macro | `sh_test` + trampoline that watches the server (rules_valkey's) | `exec` into the test | The trampoline's EXIT trap stops the server. If the server dies mid-test, the test is stopped at once with the server's status and log. |
| Python | required on the host for the launcher and `ch_http` | a compiled launcher | As in rules_valkey and rules_pg. |

## Isolation

The launcher writes a complete config with absolute paths under `$TEST_TMPDIR/clickhouse-<name>/`:
- `path`, `tmp_path`, `user_files_path`, `format_schema_path`, `user_scripts_path`, `user_defined_path`;
- `dictionaries_lib_path`, `top_level_domains_path`, `custom_cached_disks_base_directory`, `filesystem_caches_path`;
- `user_directories`: `users.xml`, plus a `local_directory` for SQL-created users;
- the log files, via `--pid-file` the pid file.

ClickHouse writes `preprocessed_configs/` under `path`. `//tests:isolation_test` runs the server from a read-only working directory with a read-only `HOME` and `TMPDIR`, and makes it write in every way a test plausibly would: MergeTree parts and a merge, a SQL function, a `file()` export, a temporary table, an SQL user, an external sort. It then fails if any file outside `$TEST_TMPDIR` is newer than its start marker:
- under the working directory or the runfiles tree;
- under `/tmp`, which is the sandbox's own with hermetic tmp;
- under `/var/tmp` or `/dev/shm`, matched by name, since these are shared with the host.

A probe file planted in `/tmp` and in the runfiles tree made it fail, as it should.

## Offline

All tests carry `block-network`, so the linux-sandbox gives them only loopback. `//tests:network_blocked_test` fails if connections to public addresses get through, which would mean the sandbox fell back to one that can't block. CI therefore lifts Ubuntu 24.04's AppArmor restriction on unprivileged user namespaces first. The server, the migrations and the clients all ran this way, so nothing in a start needs the network.

## Failure messages

A failed start prints the cause, then the server's own errors. These are the `<Error>`/`<Fatal>`/`Exception` lines of the error log and of its stdout, where errors land before the logger is configured. Stack-trace frames are stripped, and a log's tail is the fallback. For example, a bad timezone in `extra_args` gives:

```
[clickhouse] clickhouse server exited with status 36 before it was ready:
  …/log/stdout.log (errors):
    Code: 36. DB::Exception: Cannot load time zone Not/AZone. (BAD_ARGUMENTS)
```

The test-sized defaults were first tried with smaller background pools. ClickHouse refused to start with `background_pool_size` 4, because a merge-tree setting requires pool × ratio ≥ 20. The pool sizes are now upstream's defaults.

## Open questions

- **"Latest stable."** On 2026-11-18, `gh release list` marks v26.9.32.8-stable as Latest (published 15:33Z). But v26.10.6.18-stable (12:47Z) is a higher version on a newer stable line. Both are pinned, and the default is the newer line, 26.10.6.18; switching is one line in `MODULE.bazel` and `DEFAULT_VERSION`.
- **macOS** is pinned and its downloads verified, but the server has never been run on macOS by this repo.
- **linux_arm64** is pinned and verified, but not run here (x86_64 machine, x86_64 CI).
