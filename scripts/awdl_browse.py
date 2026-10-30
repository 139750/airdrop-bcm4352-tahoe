#!/usr/bin/env python3
"""DNS-SD browse with kDNSServiceFlagsIncludeAWDL.

Why this exists: the `dns-sd` CLI cannot pass kDNSServiceFlagsIncludeAWDL, so
`dns-sd -B _airdrop._tcp` always returns 0 items even when the service IS
registered. This wrapper calls the C API directly.

Critical detail discovered the hard way: AWDL-only records are only visible when
the browse is bound to the awdl0 interface index (7). Browsing with
kDNSServiceInterfaceIndexAny returns 0 even though the record exists. So we query
both and label which interface answered.

Usage:  python3 awdl_browse.py [service ...]
"""
import ctypes
import select
import sys
import time
from ctypes import CFUNCTYPE, byref, c_char_p, c_int32, c_uint32, c_void_p

lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

kDNSServiceFlagsIncludeAWDL = 0x100000
kDNSServiceFlagsIncludeP2P = 0x20000
kDNSServiceInterfaceIndexAny = 0
AWDL_IFINDEX = 7

DEFAULT_SERVICES = [
    "_airdrop._tcp",
    "_rdlink._tcp",
    "_applicationservicepairing._tcp",
    "_appsvcprepair._tcp",
    "_companion-link._tcp",
]

CB = CFUNCTYPE(None, c_void_p, c_uint32, c_uint32, c_int32,
               c_char_p, c_char_p, c_char_p, c_void_p)


def browse(service, ifindex, timeout=7):
    """Return (results, ret) where results is [(name, regtype, ifIndex), ...]."""
    results = []

    def _cb(sdRef, flags, ifIndex, errorCode, name, regtype, domain, context):
        if errorCode == 0:
            results.append((
                name.decode(errors="replace") if name else "",
                regtype.decode(errors="replace") if regtype else "",
                ifIndex,
            ))

    cb = CB(_cb)
    ref = c_void_p()
    ret = lib.DNSServiceBrowse(
        byref(ref),
        c_uint32(kDNSServiceFlagsIncludeAWDL | kDNSServiceFlagsIncludeP2P),
        c_uint32(ifindex),
        service.encode(),
        b"local.",
        cb,
        None,
    )
    if ret != 0:
        return results, ret

    fd = lib.DNSServiceRefSockFD(ref)
    if fd < 0:
        lib.DNSServiceRefDeallocate(ref)
        return results, -1

    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.4)
        if fd in r:
            lib.DNSServiceProcessResult(ref)

    lib.DNSServiceRefDeallocate(ref)
    return results, 0


def main():
    services = sys.argv[1:] or DEFAULT_SERVICES
    print(f"Browsing {len(services)} service types (awdl0 ifIndex {AWDL_IFINDEX} + Any)\n")

    total_hits = 0
    for svc in services:
        awdl_hits, err = browse(svc, AWDL_IFINDEX)
        any_hits, _ = browse(svc, kDNSServiceInterfaceIndexAny, timeout=3)

        if err != 0:
            print(f"{svc:34s} browse error ret={err}")
            continue

        merged = awdl_hits + [h for h in any_hits if h not in awdl_hits]
        if not merged:
            print(f"{svc:34s} 0 items")
            continue

        total_hits += len(merged)
        print(f"{svc:34s} {len(merged)} items")
        for name, regtype, ifidx in merged:
            tag = "awdl0" if ifidx == AWDL_IFINDEX else f"if{ifidx}"
            print(f"    {name:22s} {regtype:34s} [{tag}]")

    print(f"\n=== {total_hits} item(s) total ===")
    return 0 if total_hits else 1


if __name__ == "__main__":
    sys.exit(main())
