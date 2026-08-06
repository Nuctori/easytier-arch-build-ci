#!/usr/bin/env bash
# SteamOS smoke test: prove the built easytier binaries actually RUN and form a
# virtual network without root/TUN access (the SteamOS Desktop Mode scenario).
#
# The CI workflow runs this inside an archlinux container pinned to the same
# glibc as SteamOS 3.7 (glibc 2.41), so a pass here means the binaries will
# load and work on a Steam Deck.
#
# Usage:
#   ci/steamos-smoke-test.sh <dir-with-easytier-binaries>
#
# Requirements on the test machine: bash, python3, and a writable loopback.
# No TUN device, no root privileges and no network access are required.
set -euo pipefail

BIN_DIR="${1:?usage: steamos-smoke-test.sh <dir-with-easytier-binaries>}"
CORE="${BIN_DIR}/easytier-core"
CLI="${BIN_DIR}/easytier-cli"

if [[ ! -x "${CORE}" ]]; then
  echo "missing easytier-core: ${CORE}" >&2
  exit 1
fi
if [[ ! -x "${CLI}" ]]; then
  echo "missing easytier-cli: ${CLI}" >&2
  exit 1
fi

NETWORK_NAME="ci-steamos-$(date +%s)-$$"
NETWORK_SECRET="ci-steamos-secret"
A_IP="10.144.144.1"   # node A: listener
B_IP="10.144.144.2"   # node B: peer of A
A_RPC="127.0.0.1:15888"
B_RPC="127.0.0.1:15889"  # avoid clashing with A's default RPC portal

# easytier rejects TUNNELS whose source address is loopback by design
# ("tunnel src host is loopback address") to avoid routing loops in --no-tun
# mode, so two nodes on one host must peer via the host's real IP — the same
# situation as two machines on a LAN.
HOST_IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -n1)"
if [[ -z "${HOST_IP}" ]]; then
  echo "cannot determine non-loopback host IP" >&2
  exit 1
fi
echo "peering via host IP ${HOST_IP}"

workdir="$(mktemp -d)"
A_LOG="${workdir}/node-a.log"
B_LOG="${workdir}/node-b.log"
A_PID=""
B_PID=""

cleanup() {
  if [[ -n "${B_PID}" ]]; then kill "${B_PID}" 2>/dev/null || true; fi
  if [[ -n "${A_PID}" ]]; then kill "${A_PID}" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf "${workdir}"
}
trap cleanup EXIT

echo "== version checks (binaries must load under SteamOS glibc) =="
"${CORE}" --version
"${CLI}" --version
if [[ -x "${BIN_DIR}/easytier-web" ]]; then
  "${BIN_DIR}/easytier-web" --version
fi

echo "== starting node A (listener, RPC ${A_RPC}, virtual IP ${A_IP}) =="
"${CORE}" --no-tun \
  --network-name "${NETWORK_NAME}" --network-secret "${NETWORK_SECRET}" \
  -i "${A_IP}" --rpc-portal "${A_RPC}" --stun-servers "" \
  >"${A_LOG}" 2>&1 &
A_PID=$!

echo "== starting node B (--no-listener, peers tcp://${HOST_IP}:11010, virtual IP ${B_IP}) =="
"${CORE}" --no-tun --no-listener \
  --network-name "${NETWORK_NAME}" --network-secret "${NETWORK_SECRET}" \
  -i "${B_IP}" -p "tcp://${HOST_IP}:11010" --rpc-portal "${B_RPC}" --stun-servers "" \
  >"${B_LOG}" 2>&1 &
B_PID=$!

# The verification itself lives in python3 so the JSON parsing is robust.
python3 - "${CLI}" "${A_RPC}" "${B_RPC}" "${A_IP}" "${B_IP}" "${A_LOG}" "${B_LOG}" "${HOST_IP}" <<'PY'
import json
import subprocess
import sys
import time

CLI, A_RPC, B_RPC, A_IP, B_IP, A_LOG, B_LOG, HOST_IP = sys.argv[1:]

import socket as _socket
import struct


def ipv4_from_proto(v):
    """route.ipv4_addr is a proto common.Ipv4Addr ({'addr': uint32})."""
    if isinstance(v, str):
        return v.split("/", 1)[0]
    if isinstance(v, dict) and v.get("addr") is not None:
        return _socket.inet_ntoa(struct.pack("!I", int(v["addr"])))
    return ""


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=30)


def tail(path, n=30):
    try:
        with open(path) as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return f"(cannot read {path})"


def wait_for(fn, tries=45, delay=1):
    last = None
    for _ in range(tries):
        last = fn()
        if last is True:
            return True
        time.sleep(delay)
    return last


def node_ip(rpc, tries=45):
    """Wait until the node answers RPC, return (NodeInfo, stdout)."""

    def check():
        r = run(CLI, "-p", rpc, "-o", "json", "node", "info")
        if r.returncode == 0:
            return json.loads(r.stdout)
        return False

    return wait_for(check, tries)


def route_ips(rpc):
    r = run(CLI, "-p", rpc, "-v", "route")
    if r.returncode != 0:
        return []
    data = json.loads(r.stdout)
    return [
        ipv4_from_proto(pr.get("route", {}).get("ipv4_addr"))
        for pr in data.get("peer_routes", [])
    ]


print("-- node A must come up and report its virtual IP --")
node_a = node_ip(A_RPC)
if node_a is False:
    sys.exit(f"node A RPC never became ready\nA log tail:\n{tail(A_LOG)}")
ip_a = (node_a.get("ipv4_addr") or "").split("/", 1)[0]  # may be "10.144.144.1/24"
if ip_a != A_IP:
    sys.exit(f"node A reported ipv4_addr={ip_a!r}, expected {A_IP!r}")
print(f"OK node A online, virtual IP {ip_a} (peer_id={node_a.get('peer_id')}, version={node_a.get('version')})")

# Diagnostics: is the TCP listener actually accepting? Probe it directly.
import socket

print("-- listener probe: raw TCP connect to %s:11010 --" % HOST_IP)
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
probe.settimeout(5)
try:
    probe.connect((HOST_IP, 11010))
    print("raw TCP connect to %s:11010: OK" % HOST_IP)
    probe.close()
except OSError as exc:
    print("raw TCP connect to %s:11010 FAILED: %s" % (HOST_IP, exc))

print("-- socket state --")
for line in subprocess.run(
    ["ss", "-tlnp"], capture_output=True, text=True, timeout=10
).stdout.splitlines():
    if "11010" in line or "11011" in line or "11012" in line or "15888" in line:
        print(line)

print("-- network namespaces --")
print(subprocess.run(["ip", "netns", "list"], capture_output=True, text=True).stdout or "(none)")

print(f"-- node A must learn a route to node B ({B_IP}) --")


def wait_for_route_a():
    return B_IP in route_ips(A_RPC)


if not wait_for(wait_for_route_a):
    sys.exit(
        f"node A never saw node B ({B_IP}) in its route table\n"
        f"A log tail:\n{tail(A_LOG)}\nB log tail:\n{tail(B_LOG)}"
    )
print(f"OK node A sees node B: {route_ips(A_RPC)}")

print(f"-- node B must learn a route to node A ({A_IP}) --")


def wait_for_route_b():
    return A_IP in route_ips(B_RPC)


if not wait_for(wait_for_route_b):
    sys.exit(
        f"node B never saw node A ({A_IP}) in its route table\n"
        f"A log tail:\n{tail(A_LOG)}\nB log tail:\n{tail(B_LOG)}"
    )
print(f"OK node B sees node A: {route_ips(B_RPC)}")

print("SMOKE TEST PASSED")
PY
