#!/usr/bin/env bash
# The tests in this package are tagged block-network: the sandbox gives
# them loopback only. This checks that holds (a connection to public
# addresses fails), so the ClickHouse tests beside it really ran offline.
# Fails if any connection gets through, e.g. when the spawn strategy isn't
# a sandbox that can block the network.
set -euo pipefail
python3 -I - <<'PY'
import socket, sys
targets = [("8.8.8.8", 53), ("1.1.1.1", 443), ("140.82.112.3", 443)]
try:
    for info in socket.getaddrinfo("github.com", 443, proto=socket.IPPROTO_TCP):
        targets.append((info[4][0], 443))
    print("note: github.com resolves (host resolver); connecting must still fail")
except OSError as e:
    print("ok: name resolution blocked too (%s)" % e)
leaks = []
for host, port in targets:
    try:
        socket.create_connection((host, port), timeout=5).close()
        leaks.append("%s:%d" % (host, port))
    except OSError as e:
        print("ok: %s:%d unreachable (%s)" % (host, port, e))
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
socket.create_connection(s.getsockname(), timeout=5).close()
print("ok: loopback works")
if leaks:
    sys.exit("FAIL: connected from a block-network test to " + ", ".join(leaks))
print("PASS: no network in the test sandbox")
PY
