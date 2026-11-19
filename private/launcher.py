#!/usr/bin/env python3
"""Starts `clickhouse server` for rules_clickhouse.

  launcher.py serve --clickhouse BIN --version V --env-file PATH --state-dir DIR
                    --ready-timeout S --database DB [--password PW]
                    [--migration FILE]... [--seed FILE]...
                    [--config FILE]... [--users FILE]... [-- SETTING_OVERRIDES...]

Every file the server writes is under DIR (`$TEST_TMPDIR/clickhouse-<name>`):

    DIR/config.xml, config.d/, users.xml, users.d/, client.xml   generated config
    DIR/data/            path (metadata, store, preprocessed_configs, ...)
    DIR/tmp/             tmp_path, and TMPDIR for the server and clients
    DIR/user_files/, format_schemas/, user_scripts/, user_defined/, access/
    DIR/log/             clickhouse-server.log, clickhouse-server.err.log, stdout.log
    DIR/clickhouse-server.pid

The server listens on 127.0.0.1 only, on two free ports (HTTP and native
TCP); every other listener (MySQL, PostgreSQL, interserver, gRPC,
Prometheus, Keeper, HTTPS, secure TCP) is off, and crash reports are not
sent. The server runs in DIR with HOME=DIR and no CLICKHOUSE_* variables
from the caller.

Ready means GET /ping answers `Ok.` and the native port accepts
connections. Then the database is created, each migration and seed file
runs through `clickhouse client --multiquery`, and the env file is written
atomically (variables in write_env below). SIGTERM / SIGINT stop the
server, remove the env file and exit 0; if the server exits on its own,
the launcher exits with its status. A control endpoint
(CLICKHOUSE_CONTROL_URL: POST /stop, /start) stops the server and starts it
again on the same ports with the same data.

Failures (the server refuses its config, exits, isn't ready in time, a
migration or seed fails) exit 1, name the cause, and show the server's own
error (the tail of its error log).
"""

import argparse
import errno
import hashlib
import http.client
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape
import re

_STACK_FRAME = re.compile(r"^\s*(\d+\. |\(version \d)")

HOST = "127.0.0.1"
USER = "default"


class Failed(Exception):
    """The server could not start, or a start step failed."""


def _log(msg):
    print(f"[clickhouse] {msg}", file=sys.stderr, flush=True)


def _display(path):
    """A runfiles path as the workspace-relative one users wrote."""
    rf = os.environ.get("RUNFILES_DIR") or os.environ.get("TEST_SRCDIR") or ""
    for root in (os.path.join(rf, "_main") + os.sep, rf.rstrip(os.sep) + os.sep):
        if rf and path.startswith(root):
            return path[len(root):]
    return path


def _free_ports(n):
    socks = []
    try:
        for _ in range(n):
            s = socket.socket()
            s.bind((HOST, 0))
            socks.append(s)
        return [s.getsockname()[1] for s in socks]
    finally:
        for s in socks:
            s.close()


def _bindable(port):
    """Whether the server could listen on HOST:port again (it sets
    SO_REUSEADDR too, so TIME_WAIT connections don't count)."""
    s = socket.socket()
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((HOST, port))
        return True
    except OSError as e:
        if e.errno == errno.EADDRINUSE:
            return False
        raise
    finally:
        s.close()


# ---- config -----------------------------------------------------------------------

# Server settings rules_clickhouse owns (keep in sync with server.bzl's
# FORCED_SETTINGS). Dropped from `config` fragments, which are merged after
# the base config and would otherwise override it.
_FORCED = {
    "path", "tmp_path", "user_files_path", "format_schema_path", "user_scripts_path",
    "user_defined_path", "dictionaries_lib_path", "top_level_domains_path",
    "custom_cached_disks_base_directory", "filesystem_caches_path", "access_control_path",
    "user_directories", "users_config", "include_from",
    "listen_host", "listen_try", "listen_reuse_port",
    "http_port", "tcp_port", "https_port", "tcp_port_secure", "tcp_with_proxy_port",
    "mysql_port", "postgresql_port", "interserver_http_port", "interserver_https_port",
    "interserver_http_host", "interserver_https_host", "grpc_port", "grpc", "prometheus",
    "keeper_server", "arrowflight_port", "send_crash_reports",
}
_FORCED_LOGGER = {"log", "errorlog", "console"}
# The default user's authentication and networks stay ours (the launcher
# and `ch` log in as it).
_FORCED_DEFAULT_USER = {
    "password", "password_sha256_hex", "password_double_sha1_hex", "no_password",
    "ssh_keys", "ldap", "kerberos", "ssl_certificates", "http_authentication",
    "networks", "auth_methods",
}


def stage_fragment(src, dest, kind):
    """Copy a config (kind "config") or users (kind "users") fragment to
    dest, without the settings rules_clickhouse owns. Returns the names of
    what was dropped."""
    try:
        tree = ET.parse(src)
    except ET.ParseError as e:
        raise Failed(f"{kind} file {_display(src)} is not valid XML: {e}")
    root = tree.getroot()
    if root.tag not in ("clickhouse", "yandex"):
        raise Failed(f"{kind} file {_display(src)}: the root element is <{root.tag}>, "
                     "expected <clickhouse>")
    dropped = []
    if kind == "config":
        for child in list(root):
            if child.tag in _FORCED:
                root.remove(child)
                dropped.append(child.tag)
            elif child.tag == "logger":
                for c in list(child):
                    if c.tag in _FORCED_LOGGER:
                        child.remove(c)
                        dropped.append("logger/" + c.tag)
    else:
        for users in root.findall("users"):
            for default in users.findall(USER):
                for c in list(default):
                    if c.tag in _FORCED_DEFAULT_USER:
                        default.remove(c)
                        dropped.append(f"users/{USER}/{c.tag}")
    tree.write(dest, encoding="unicode")
    return dropped


def _base_config(state, http_port, native_port):
    d = {k: escape(os.path.join(state, k) + "/") for k in
         ("data", "tmp", "user_files", "format_schemas", "user_scripts", "user_defined", "access")}
    log = escape(os.path.join(state, "log"))
    return f"""<!-- Generated by rules_clickhouse. Everything the server writes is under
     {escape(state)}. -->
<clickhouse>
    <logger>
        <level>information</level>
        <log>{log}/clickhouse-server.log</log>
        <errorlog>{log}/clickhouse-server.err.log</errorlog>
        <console>0</console>
        <size>100M</size>
        <count>2</count>
    </logger>

    <!-- Loopback only, two free ports; no other listener is configured
         (MySQL, PostgreSQL, interserver, gRPC, Prometheus, Keeper, HTTPS). -->
    <listen_host>{HOST}</listen_host>
    <listen_try>0</listen_try>
    <http_port>{http_port}</http_port>
    <tcp_port>{native_port}</tcp_port>

    <path>{d["data"]}</path>
    <tmp_path>{d["tmp"]}</tmp_path>
    <user_files_path>{d["user_files"]}</user_files_path>
    <format_schema_path>{d["format_schemas"]}</format_schema_path>
    <user_scripts_path>{d["user_scripts"]}</user_scripts_path>
    <user_defined_path>{d["user_defined"]}</user_defined_path>
    <dictionaries_lib_path>{d["data"]}dictionaries_lib/</dictionaries_lib_path>
    <top_level_domains_path>{d["data"]}top_level_domains/</top_level_domains_path>
    <custom_cached_disks_base_directory>{d["data"]}caches/</custom_cached_disks_base_directory>
    <filesystem_caches_path>{d["data"]}filesystem_caches/</filesystem_caches_path>
    <user_directories>
        <users_xml><path>users.xml</path></users_xml>
        <local_directory><path>{d["access"]}</path></local_directory>
    </user_directories>

    <!-- No telemetry: crash reports off (nothing else in the server
         reaches the network unless a query asks it to). -->
    <send_crash_reports><enabled>false</enabled></send_crash_reports>

    <!-- Test-sized defaults; a `config` fragment may change these. -->
    <timezone>UTC</timezone>
    <mark_cache_size>268435456</mark_cache_size>
    <index_mark_cache_size>67108864</index_mark_cache_size>
    <uncompressed_cache_size>67108864</uncompressed_cache_size>
    <max_concurrent_queries>100</max_concurrent_queries>
    <shutdown_wait_unfinished>2</shutdown_wait_unfinished>
</clickhouse>
"""


def _users_config(password):
    return f"""<!-- Generated by rules_clickhouse. -->
<clickhouse>
    <profiles>
        <default/>
    </profiles>
    <quotas>
        <default/>
    </quotas>
    <users>
        <{USER}>
            <password>{escape(password)}</password>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
        </{USER}>
    </users>
</clickhouse>
"""


def _client_config(native_port, password):
    # `clickhouse client -C` reads only this file (not ~/.clickhouse-client
    # or /etc/clickhouse-client).
    return f"""<!-- Generated by rules_clickhouse: clickhouse client -C this file. -->
<config>
    <host>{HOST}</host>
    <port>{native_port}</port>
    <user>{USER}</user>
    <password>{escape(password)}</password>
</config>
"""


class Server:
    """One clickhouse server: its ports, files and process; restartable."""

    def __init__(self, args):
        self.args = args
        self.state = args.state_dir
        self.config = os.path.join(self.state, "config.xml")
        self.client_config = os.path.join(self.state, "client.xml")
        self.log = os.path.join(self.state, "log", "clickhouse-server.log")
        self.err_log = os.path.join(self.state, "log", "clickhouse-server.err.log")
        self.stdout_log = os.path.join(self.state, "log", "stdout.log")
        self.pid_file = os.path.join(self.state, "clickhouse-server.pid")
        self.http_port = self.native_port = None
        self.proc = None
        self.stopped = False   # stopped on request (not a crash)

    # -- files --

    def prepare(self, http_port, native_port):
        """Fresh state dir: generated config, empty data."""
        shutil.rmtree(self.state, ignore_errors=True)
        for d in ("config.d", "users.d", "data", "tmp", "user_files", "format_schemas",
                  "user_scripts", "user_defined", "access", "log"):
            os.makedirs(os.path.join(self.state, d))
        self.http_port, self.native_port = http_port, native_port
        with open(self.config, "w") as f:
            f.write(_base_config(self.state, http_port, native_port))
        with open(os.path.join(self.state, "users.xml"), "w") as f:
            f.write(_users_config(self.args.password))
        with open(self.client_config, "w") as f:
            f.write(_client_config(native_port, self.args.password))
        for kind, files in (("config", self.args.config), ("users", self.args.users)):
            for i, src in enumerate(files):
                name = f"{10 + i:02d}-{os.path.basename(src)}"
                dropped = stage_fragment(src, os.path.join(self.state, kind + ".d", name), kind)
                if dropped and not getattr(self, "_noted", False):
                    _log(f"{_display(src)}: rules_clickhouse sets {', '.join(dropped)}; "
                         "ignoring them there")

    def env(self):
        """The server's and clients' environment: no CLICKHOUSE_* from the
        caller (a sourced env file sets several, and the binary reads some),
        HOME and TMPDIR inside the state dir, no watchdog fork."""
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLICKHOUSE_")}
        env.update(HOME=self.state, TMPDIR=os.path.join(self.state, "tmp"),
                   CLICKHOUSE_WATCHDOG_ENABLE="0")
        return env

    # -- process --

    def argv(self):
        return [self.args.clickhouse, "server", f"--config-file={self.config}",
                f"--pid-file={self.pid_file}", "--"] + self.args.extra

    def start(self, deadline):
        """Start the server; wait for /ping and the native port. Returns
        True when ready, False if it exited or timed out (self.proc tells)."""
        offsets = {p: (os.path.getsize(p) if os.path.exists(p) else 0)
                   for p in (self.err_log, self.stdout_log)}
        self._offsets = offsets
        with open(self.stdout_log, "a") as out:
            self.proc = subprocess.Popen(self.argv(), cwd=self.state, env=self.env(),
                                         stdin=subprocess.DEVNULL, stdout=out,
                                         stderr=subprocess.STDOUT,
                                         # Its own session: `SYSTEM SHUTDOWN` signals the
                                         # server's whole process group, which would
                                         # otherwise be the launcher's and the test's.
                                         start_new_session=True)
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                return False
            if self._ping() and self._native_up():
                self.stopped = False
                return True
            time.sleep(0.05)
        return False

    def _ping(self):
        try:
            c = http.client.HTTPConnection(HOST, self.http_port, timeout=2)
            c.request("GET", "/ping")
            r = c.getresponse()
            ok = r.status == 200 and r.read() == b"Ok.\n"
            c.close()
            return ok
        except OSError:
            return False

    def _native_up(self):
        try:
            socket.create_connection((HOST, self.native_port), timeout=1).close()
            return True
        except OSError:
            return False

    def stop(self):
        """SIGTERM: ClickHouse's graceful shutdown (parts on disk are kept)."""
        self.stopped = True
        p = self.proc
        if p is not None and p.poll() is None:
            p.terminate()
            try:
                p.wait(60)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def kill_now(self):
        p = self.proc
        if p is not None and p.poll() is None:
            p.kill()
            p.wait()

    # -- diagnostics --

    def _since_start(self, path):
        try:
            with open(path, "rb") as f:
                f.seek(getattr(self, "_offsets", {}).get(path, 0))
                return f.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def address_in_use(self):
        return "Address already in use" in (self._since_start(self.err_log) +
                                            self._since_start(self.stdout_log))

    def explain(self):
        """The server's own error: the error and exception lines (without
        stack traces) from this start's error log and output, else their
        tails."""
        shown = []
        for path in (self.err_log, self.stdout_log):
            lines = [l for l in self._since_start(path).splitlines()
                     if l.strip() and not _STACK_FRAME.match(l)]
            errs = [l.split(", Stack trace (when copying", 1)[0] for l in lines
                    if "<Error>" in l or "<Fatal>" in l or "Exception" in l]
            if errs:
                shown += [f"  {path} (errors):"] + ["    " + l for l in errs[-8:]]
            elif lines:
                shown += [f"  {path} (tail):"] + ["    " + l for l in lines[-10:]]
        return "\n".join(shown) or "  (the server wrote no log)"

    # -- queries --

    def http_query(self, sql):
        """Run one statement over HTTP; raise Failed with the server's error."""
        q = urllib.parse.urlencode({"database": "default"})
        c = http.client.HTTPConnection(HOST, self.http_port, timeout=60)
        c.request("POST", "/?" + q, body=sql.encode(),
                  headers={"X-ClickHouse-User": USER, "X-ClickHouse-Key": self.args.password})
        r = c.getresponse()
        body = r.read().decode("utf-8", "replace")
        c.close()
        if r.status != 200:
            raise Failed(f"`{sql}` failed (HTTP {r.status}): {body.strip()}")
        return body

    def client(self, extra, stdin_path):
        cmd = [self.args.clickhouse, "client", "-C", self.client_config,
               "--host", HOST, "--port", str(self.native_port), "--user", USER,
               "--database", self.args.database] + extra
        with open(stdin_path, "rb") as f:
            return subprocess.run(cmd, stdin=f, capture_output=True, cwd=self.state,
                                  env=self.env())


def _where(path, query):
    """The line in `path` where the failing statement starts, if found."""
    if not query:
        return ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return ""
    probe = query.strip().rstrip(";").strip()
    i = text.find(probe) if probe else -1
    if i < 0:
        i = text.find(probe.split("\n", 1)[0]) if probe else -1
    return f", line {text.count(chr(10), 0, i) + 1}" if i >= 0 else ""


def _failed_query(stderr):
    """The statement clickhouse client names in `(query: ...)`."""
    marker = "(query: "
    i = stderr.rfind(marker)
    if i < 0:
        return ""
    q = stderr[i + len(marker):].rstrip()
    return q[:-1] if q.endswith(")") else q


def run_sql_file(server, path, what):
    r = server.client(["--multiquery"], path)
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace").strip()
        query = _failed_query(err)
        where = _where(path, query)
        stmt = ("\n  statement:\n" + "\n".join("    " + l for l in query.splitlines())) if query else ""
        raise Failed(f"{what} {_display(path)} failed{where}:{stmt}\n  error:\n" +
                     "\n".join("    " + l for l in err.splitlines() if not l.startswith("(query: ")))


def load_table_file(server, path):
    base, ext = os.path.splitext(os.path.basename(path))
    fmt = {".csv": "CSVWithNames", ".tsv": "TSVWithNames"}[ext.lower()]
    db = server.args.database
    r = server.client(["--query", f"INSERT INTO `{db}`.`{base}` FORMAT {fmt}"], path)
    if r.returncode != 0:
        raise Failed(f"seed {_display(path)} (into {db}.{base}, {fmt}) failed:\n" +
                     "\n".join("    " + l for l in r.stderr.decode("utf-8", "replace").strip().splitlines()))


def migrate_and_seed(server):
    db = server.args.database
    if db != "default":
        server.http_query(f"CREATE DATABASE IF NOT EXISTS `{db}`")
    n = len(server.args.migration)
    for i, path in enumerate(server.args.migration, 1):
        run_sql_file(server, path, f"migration {i}/{n}")
        _log(f"applied migration {i}/{n}: {_display(path)}")
    for path in server.args.seed:
        if path.lower().endswith(".sql"):
            run_sql_file(server, path, "seed")
        else:
            load_table_file(server, path)
        _log(f"loaded seed {_display(path)}")


def write_env(env_file, values):
    tmp = env_file + ".tmp"
    with open(tmp, "w") as f:
        for k, v in values.items():
            f.write(f"{k}={shlex.quote(str(v))}\n")
    os.replace(tmp, env_file)


def env_values(server, control_port):
    a = server.args
    cred = urllib.parse.quote(USER, safe="")
    if a.password:
        cred += ":" + urllib.parse.quote(a.password, safe="")
    return {
        "CLICKHOUSE_HOST": HOST,
        "CLICKHOUSE_HTTP_PORT": server.http_port,
        "CLICKHOUSE_NATIVE_PORT": server.native_port,
        "CLICKHOUSE_NATIVE_ADDR": f"{HOST}:{server.native_port}",
        "CLICKHOUSE_DATABASE": a.database,
        "CLICKHOUSE_USER": USER,
        "CLICKHOUSE_PASSWORD": a.password,
        "CLICKHOUSE_HTTP_URL": f"http://{HOST}:{server.http_port}",
        "CLICKHOUSE_DSN": f"clickhouse://{cred}@{HOST}:{server.native_port}/{a.database}",
        "CLICKHOUSE_VERSION": a.version,
        "CLICKHOUSE_BIN": a.clickhouse,
        "CLICKHOUSE_CLIENT_CONFIG": server.client_config,
        "CLICKHOUSE_STATE_DIR": server.state,
        "CLICKHOUSE_LOG": server.log,
        "CLICKHOUSE_ERROR_LOG": server.err_log,
        "CLICKHOUSE_CONTROL_URL": f"http://{HOST}:{control_port}",
    }


# ---- start / restart ------------------------------------------------------------

# First start: new free ports on each attempt. Restart: the same ports,
# _RETRY_DELAY apart.
_ATTEMPTS = 5
_RETRY_DELAY = 0.2


def first_start(server):
    a = server.args
    deadline = time.monotonic() + a.ready_timeout
    for attempt in range(1, _ATTEMPTS + 1):
        http_port, native_port = _free_ports(2)
        server.prepare(http_port, native_port)
        server._noted = True
        if server.start(deadline):
            return
        if server.proc.poll() is None:
            server.kill_now()
            raise Failed(f"clickhouse server was not ready (GET /ping -> Ok.) within "
                         f"{a.ready_timeout:g}s on 127.0.0.1:{http_port}:\n{server.explain()}")
        if server.address_in_use() and attempt < _ATTEMPTS:
            _log(f"a port was taken (attempt {attempt}); retrying on new ports")
            continue
        raise Failed(f"clickhouse server exited with status {server.proc.returncode} before "
                     f"it was ready:\n{server.explain()}")
    raise Failed(f"clickhouse server could not get free ports after {_ATTEMPTS} attempts")


def restart(server):
    """Start a stopped server again: same ports, config and data."""
    taken = []
    for attempt in range(1, _ATTEMPTS + 1):
        if attempt > 1:
            time.sleep(_RETRY_DELAY)
        taken = [f"{n} port {p}" for n, p in (("HTTP", server.http_port),
                                               ("native", server.native_port))
                 if not _bindable(p)]
        if taken:
            _log(f"taken: {', '.join(taken)} (attempt {attempt})")
            continue
        if server.start(time.monotonic() + server.args.ready_timeout):
            return
        rc = server.proc.poll()
        if rc is None:
            server.kill_now()
        if server.address_in_use():
            taken = taken or ["a port"]
            _log(f"a port was taken while starting (attempt {attempt})")
            continue
        raise Failed("clickhouse server did not start again: "
                     f"{'not ready in time' if rc is None else f'exit {rc}'}:\n{server.explain()}")
    raise Failed(f"clickhouse server could not listen on its ports again after {_ATTEMPTS} "
                 f"attempts {_RETRY_DELAY:g}s apart: another process holds "
                 f"{', '.join(taken)} (Address already in use)")


class Control:
    """POST /stop, /start."""

    def __init__(self, server, stopping):
        self.server, self.stopping = server, stopping
        self.lock = threading.Lock()

    def handle(self, path):
        u = urllib.parse.urlsplit(path)
        if self.stopping:
            return 503, "shutting down"
        with self.lock:
            if u.path == "/stop":
                self.server.stop()
                _log("stopped (control)")
                return 200, "stopped"
            if u.path == "/start":
                p = self.server.proc
                if p is not None and p.poll() is None:
                    return 200, "running"
                try:
                    t = time.monotonic()
                    restart(self.server)
                except Failed as e:
                    _log(str(e))
                    return 500, str(e)
                _log(f"started again (control) in {time.monotonic() - t:.2f}s")
                return 200, "started"
        return 404, f"unknown control path {u.path}"

    def serve(self):
        control = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                status, text = control.handle(self.path)
                body = (text + "\n").encode()
                self.send_response(status)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        httpd = ThreadingHTTPServer((HOST, 0), Handler)
        httpd.daemon_threads = True
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return httpd


def serve(args):
    os.makedirs(os.path.dirname(os.path.abspath(args.env_file)), exist_ok=True)
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass
    server = Server(args)
    stopping, ready = [], []

    # Installed before the server starts, so a signal during start-up still
    # stops it. Once ready, the handler only asks it to stop (with a kill
    # timer) and the main loop notices.
    def _on_signal(signum, _frame):
        if stopping:
            return
        _log(f"signal {signum}; stopping")
        stopping.append(signum)
        p = server.proc
        if p is not None and p.poll() is None:
            p.terminate()
            killer = threading.Timer(60, p.kill)
            killer.daemon = True
            killer.start()
        if not ready:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    t0 = time.monotonic()
    try:
        first_start(server)
        t_up = time.monotonic()
        migrate_and_seed(server)
    except Failed as e:
        _log(str(e))
        server.stop()
        return 1
    except SystemExit:
        server.stop()
        raise
    t_ready = time.monotonic()

    control = Control(server, stopping)
    httpd = control.serve()
    write_env(args.env_file, env_values(server, httpd.server_address[1]))
    ready.append(True)
    _log(f"ClickHouse {args.version} ready on {HOST}: HTTP {server.http_port}, native "
         f"{server.native_port}, database {args.database}; started in {t_up - t0:.2f}s"
         + (f", migrated and seeded in {t_ready - t_up:.2f}s" if args.migration or args.seed else "")
         + f"; env file {args.env_file}")

    # Run until signalled, or until the server exits without being asked
    # to (clickhouse_stop leaves the launcher running).
    crashed = None
    while not stopping and crashed is None:
        p = server.proc
        if p is not None and p.poll() is not None and not server.stopped:
            with control.lock:  # not mid-restart
                if server.proc is p and not server.stopped:
                    crashed = p
        time.sleep(0.1)
    httpd.shutdown()
    if stopping:
        p = server.proc
        if p is not None:
            try:
                p.wait(60)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
    else:
        server.stop()
    try:
        os.remove(args.env_file)
    except FileNotFoundError:
        pass
    if stopping:
        return 0
    rc = crashed.returncode
    _log(f"clickhouse server exited with status {rc}:\n{server.explain()}")
    return rc if rc and rc > 0 else 1


def main(argv):
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="mode", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--clickhouse", required=True)
    s.add_argument("--version", required=True)
    s.add_argument("--env-file", required=True)
    s.add_argument("--state-dir", required=True)
    s.add_argument("--ready-timeout", type=float, default=60.0)
    s.add_argument("--database", default="test")
    s.add_argument("--password", default="")
    s.add_argument("--migration", action="append", default=[])
    s.add_argument("--seed", action="append", default=[])
    s.add_argument("--config", action="append", default=[])
    s.add_argument("--users", action="append", default=[])
    s.add_argument("extra", nargs="*")
    args = p.parse_args(argv)
    if not 0 < args.ready_timeout < float("inf"):
        _log(f"--ready-timeout must be a positive number of seconds, got {args.ready_timeout}")
        return 1
    args.clickhouse = os.path.abspath(args.clickhouse)
    args.state_dir = os.path.abspath(args.state_dir)
    args.env_file = os.path.abspath(args.env_file)
    for k in ("migration", "seed", "config", "users"):
        setattr(args, k, [os.path.abspath(x) for x in getattr(args, k)])
    return serve(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
