#!/usr/bin/env python3
"""Resolve DNS-SD services on awdl0 and print host / port / TXT.

Correct API shape: DNSServiceResolve takes name / regtype / domain separately,
NOT a single fullname (passing fullname shifts every later argument and returns
-65540 BadParam, which is what broke the earlier diagnostics).
"""
import ctypes
import select
import sys
import time
from ctypes import (CFUNCTYPE, POINTER, byref, c_char_p, c_int32, c_uint16,
                    c_uint32, c_void_p)

lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
AWDL = 7
FLAGS = 0x100000 | 0x20000  # kDNSServiceFlagsIncludeAWDL | IncludeP2P

BrowseCB = CFUNCTYPE(None, c_void_p, c_uint32, c_uint32, c_int32,
                     c_char_p, c_char_p, c_char_p, c_void_p)
ResolveCB = CFUNCTYPE(None, c_void_p, c_uint32, c_uint32, c_int32,
                      c_char_p, c_char_p, c_uint16, c_uint16,
                      POINTER(c_char_p), c_void_p)

found = {}


def on_browse(ref, flags, ifidx, err, name, rtype, domain, ctx):
    if err:
        return
    n = name.decode(errors="replace") if name else ""
    r = rtype.decode(errors="replace") if rtype else ""
    d = domain.decode(errors="replace") if domain else ""
    found[f"{n}.{r}{d}"] = {"name": n, "regtype": r, "domain": d,
                            "ifidx": ifidx, "port": None, "host": None,
                            "txt": None, "err": None}


def resolve(entry):
    def make_cb(e):
        def on_resolve(ref2, flags2, ifidx2, err2, name2, host, port,
                       txtlen, txt, ctx):
            if err2:
                e["err"] = err2
                return
            e["port"] = port
            e["host"] = host.decode(errors="replace") if host else None
            if txt and txtlen:
                buf = ctypes.string_at(txt, txtlen)
                pairs, i = [], 0
                while i < len(buf):
                    ln = buf[i]
                    i += 1
                    if ln == 0 or i + ln > len(buf):
                        break
                    pairs.append(buf[i:i + ln].decode(errors="replace"))
                    i += ln
                e["txt"] = pairs
        return ResolveCB(on_resolve)

    rcb = make_cb(entry)
    rref = c_void_p()
    # name / regtype / domain passed separately — the correct signature
    rret = lib.DNSServiceResolve(
        byref(rref), c_uint32(0), c_uint32(entry["ifidx"]),
        entry["name"].encode(), entry["regtype"].encode(),
        entry["domain"].encode(), rcb, None,
    )
    if rret != 0:
        entry["err"] = rret
        return
    rfd = lib.DNSServiceRefSockFD(rref)
    dl = time.time() + 3
    while time.time() < dl:
        r, _, _ = select.select([rfd], [], [], 0.3)
        if rfd in r:
            lib.DNSServiceProcessResult(rref)
    lib.DNSServiceRefDeallocate(rref)


def browse_service(svc):
    print(f"\n=== {svc} ===")
    found.clear()
    ref = c_void_p()
    cb = BrowseCB(on_browse)
    ret = lib.DNSServiceBrowse(byref(ref), c_uint32(FLAGS), c_uint32(AWDL),
                               svc.encode(), b"local.", cb, None)
    if ret != 0:
        print(f"  browse failed ret={ret}")
        return
    fd = lib.DNSServiceRefSockFD(ref)
    dl = time.time() + 6
    while time.time() < dl:
        r, _, _ = select.select([fd], [], [], 0.3)
        if fd in r:
            lib.DNSServiceProcessResult(ref)
    lib.DNSServiceRefDeallocate(ref)

    if not found:
        print("  0 items")
        return

    for e in found.values():
        resolve(e)
        print(f"  {e['name']}")
        print(f"    ifIndex: {e['ifidx']}")
        print(f"    port:    {e['port']}")
        print(f"    host:    {e['host']}")
        if e.get("err"):
            print(f"    ERROR:   {e['err']}")
        if e["txt"]:
            print(f"    TXT ({len(e['txt'])}):")
            for kv in e["txt"]:
                print(f"      {kv}")
        else:
            print("    TXT:     <none>")


for svc in (sys.argv[1:] or ["_airdrop._tcp", "_applicationservicepairing._tcp"]):
    browse_service(svc)
