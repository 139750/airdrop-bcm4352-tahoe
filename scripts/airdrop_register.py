#!/usr/bin/env python3
"""Register _airdrop._tcp on awdl0 pointing at sharingd's native 8770 port.

sharingd binds 8770 but never publishes the mDNS service on this hardware,
so iPhone cannot discover the Mac. We supply only the announcement; the
transfer itself is still handled by macOS's own receiver.

Implementation note: python-zeroconf's apple_p2p path was tried first and
proved unreliable for long-lived AWDL registrations on macOS 26 (it reports
success but the record stops being visible to browsers after a while).
This uses the raw DNSService C API with an explicit DNSServiceProcessResult
loop instead, which is what Apple's own stack does.
"""
import ctypes
import select
import signal
import subprocess
import sys
import time
from ctypes import CFUNCTYPE, byref, c_char_p, c_int32, c_uint16, c_uint32, c_void_p

lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")

kDNSServiceFlagsIncludeAWDL = 0x1000
kDNSServiceFlagsIncludeP2P = 0x20000
kDNSServiceErr_NoError = 0

SERVICE_NAME = "iMac"
SERVICE_TYPE = "_airdrop._tcp"
SERVICE_PORT = 8770


def awdl_index():
    out = subprocess.run(["ifconfig", "awdl0"], capture_output=True, text=True).stdout
    return 7 if "inet6" in out else None


def sharingd_listening():
    out = subprocess.run(
        ["lsof", "-nP", "-iTCP:8770", "-sTCP:LISTEN"], capture_output=True, text=True
    ).stdout
    return "sharingd" in out


state = {"registered": False, "error": None, "ref": None}


def _reg_cb(sdRef, flags, errorCode, name, regtype, domain, context):
    if errorCode == kDNSServiceErr_NoError:
        state["registered"] = True
        nm = name.decode(errors="replace") if name else ""
        rt = regtype.decode(errors="replace") if regtype else ""
        dm = domain.decode(errors="replace") if domain else ""
        print(f"[REGISTER OK] {nm} {rt} {dm}", flush=True)
    else:
        state["error"] = errorCode
        print(f"[REGISTER FAIL] errorCode={errorCode}", flush=True)


CALLBACK = CFUNCTYPE(
    None, c_void_p, c_uint32, c_int32, c_char_p, c_char_p, c_char_p, c_void_p
)
cb = CALLBACK(_reg_cb)


def register():
    ifidx = awdl_index()
    if ifidx is None:
        print("ERROR: awdl0 not available", flush=True)
        return False

    sdRef = c_void_p()
    ret = lib.DNSServiceRegister(
        byref(sdRef),
        c_uint32(kDNSServiceFlagsIncludeAWDL | kDNSServiceFlagsIncludeP2P),
        c_uint32(ifidx),
        SERVICE_NAME.encode(),
        SERVICE_TYPE.encode(),
        b"local.",
        b"iMac.local.",
        c_uint16(SERVICE_PORT),
        c_uint16(0),
        None,
        cb,
        None,
    )
    if ret != kDNSServiceErr_NoError:
        print(f"DNSServiceRegister failed ret={ret}", flush=True)
        return False

    state["ref"] = sdRef
    fd = lib.DNSServiceRefSockFD(sdRef)
    if fd < 0:
        print("DNSServiceRefSockFD failed", flush=True)
        return False

    deadline = time.time() + 5
    while time.time() < deadline and not state["registered"] and state["error"] is None:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            lib.DNSServiceProcessResult(sdRef)

    if state["registered"]:
        print(
            f"Registered {SERVICE_NAME}.{SERVICE_TYPE} on awdl0 (ifIndex {ifidx}) "
            f"-> port {SERVICE_PORT}",
            flush=True,
        )
        return True
    print("Registration did not confirm; retrying", flush=True)
    return False


def main():
    warned = False
    while True:
        if state["ref"] is None:
            if not register():
                time.sleep(10)
                continue
            warned = False

        sdRef = state["ref"]
        fd = lib.DNSServiceRefSockFD(sdRef)
        if fd >= 0:
            r, _, _ = select.select([fd], [], [], 1.0)
            if fd in r:
                lib.DNSServiceProcessResult(sdRef)

        alive = sharingd_listening()
        if not alive and not warned:
            print("note: 8770 not bound (AirDrop window closed) — registration kept",
                  flush=True)
            warned = True
        elif alive and warned:
            print("note: 8770 bound again (AirDrop window open)", flush=True)
            warned = False


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    try:
        main()
    except KeyboardInterrupt:
        pass
    finally:
        if state.get("ref"):
            try:
                lib.DNSServiceRefDeallocate(state["ref"])
            except Exception:
                pass
