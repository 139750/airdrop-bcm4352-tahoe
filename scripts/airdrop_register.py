#!/usr/bin/env python3
"""Register _airdrop._tcp on AWDL pointing at sharingd's native 8770 port.

sharingd publishes its own record (an opaque hash name) but SRV/TXT resolution
fails on this hardware, so iOS can never turn it into a usable endpoint. This
registrar publishes a complete record set (SRV + TXT + AAAA) that resolves,
while still pointing at macOS's own receiver on 8770.

This is the python-zeroconf variant — the configuration that was verified
working end-to-end (Mac -> iPhone and iPhone -> Mac). An earlier C API rewrite
returned DNSServiceRegister -65549 (BadParam) and is not used.
"""
import socket
import subprocess
import sys
import time

from zeroconf import IPVersion, ServiceInfo, Zeroconf


def awdl_ipv6():
    out = subprocess.run(["ifconfig", "awdl0"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("inet6") and "fe80" in line:
            return line.split()[1].split("%")[0]
    return None


def listener_alive():
    out = subprocess.run(
        ["lsof", "-nP", "-iTCP:8770", "-sTCP:LISTEN"], capture_output=True, text=True
    ).stdout
    return "sharingd" in out


ip = awdl_ipv6()
if not ip:
    print("ERROR: awdl0 has no IPv6 address", flush=True)
    sys.exit(1)

print(f"awdl0 IPv6: {ip}", flush=True)
if not listener_alive():
    print("warn: 8770 not bound yet (AirDrop window closed)", flush=True)

name = "iMac"
zc = Zeroconf(interfaces=[ip], ip_version=IPVersion.V6Only, apple_p2p=True)

info = ServiceInfo(
    "_airdrop._tcp.local.",
    f"{name}._airdrop._tcp.local.",
    addresses=[socket.inet_pton(socket.AF_INET6, ip)],
    port=8770,
    properties={b"flags": b"1"},
    server="iMac.local.",
)

print(f"registering {name}._airdrop._tcp.local. -> [{ip}]:8770 (flags=1)", flush=True)
zc.register_service(info)
print("REGISTERED", flush=True)

warned = False
try:
    while True:
        time.sleep(10)
        alive = listener_alive()
        if not alive and not warned:
            print("note: 8770 not bound (AirDrop window closed)", flush=True)
            warned = True
        elif alive and warned:
            print("note: 8770 bound again (AirDrop window open)", flush=True)
            warned = False
except KeyboardInterrupt:
    print("unregistering...", flush=True)
finally:
    try:
        zc.unregister_service(info)
        zc.close()
    except Exception:
        pass
