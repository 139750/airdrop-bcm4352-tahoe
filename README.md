# AirDrop on Hackintosh — Broadcom BCM4352 (`14e4:43b1`) + macOS 26 Tahoe

**English** | [简体中文](README.zh-CN.md)

**Status: WORKING — bidirectional AirDrop verified (Mac → iPhone and iPhone → Mac)**

This is a post-mortem after several hours of debugging. The conclusion is short;
the list of things that *looked* like the cause but were not is long. That list
is the useful part, because most guides send you down those paths.

---

## TL;DR — what actually fixed it

Two things. That's all.

| Side | Action |
|---|---|
| **Mac** | Fix `bluetoothExternalDongleFailed` being wiped from NVRAM by OpenCore |
| **Peer (iPhone)** | Power-cycle its Wi-Fi once (forces iOS to re-register continuity services) |

Do those two, and AirDrop works in both directions on a card the community says
you must replace.

---

## The one real technical fault: Bluetooth was never running

Symptom in System Information:

```
State: Off        Address: NULL
Chipset: BCM_4350C2    Firmware Version: v0 c0
```

Check the live NVRAM value:

```bash
nvram bluetoothExternalDongleFailed
# %01 = broken (Bluetooth will stay Off)
# %00 = healthy
```

**Root cause:** many OpenCore configs list `bluetoothExternalDongleFailed` under
`NVRAM > Delete > 7C436110-AB2A-4BBB-A880-FE41995C9F82`. Every boot OpenCore
deletes it, macOS writes `1` ("external dongle failed"), and the controller is
shut down. It never gets a chance to upload firmware.

**Fix:**

1. Remove `bluetoothExternalDongleFailed` from `NVRAM > Delete`.
2. Keep it in `NVRAM > Add` as `b'\x00'`.
3. Apply live without rebooting:

```bash
sudo nvram bluetoothExternalDongleFailed=%00
sudo nvram bluetoothInternalControllerInfo=%00%00%00%00%00%00%00%00%00%00%00%00%00%00
sudo pkill -9 bluetoothd
sleep 6
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: On / Address: <real MAC> / Firmware Version: v8718 c5747
```

**Red herrings around this:** `ioreg -r -c BrcmPatchRAM3` showing
`!registered, !matched` is normal — that node is the personality matcher, not a
driver instance. And `0x0489:0xE07A` (Foxconn-packaged BCM20702) **is** already in
BrcmPatchRAM3's built-in personality table (`0489_e07a`, firmware
`BCM20702A1_001.002.014.1483.1651_v5747`). No custom kext, no edited VID/PID
table. If you're building a kext here, you're solving the wrong problem.

---

## The second fix: the peer's sharing stack was stale

After the Mac side checked out (Bluetooth live, `_airdrop._tcp` resolving), the
send direction still failed:

```
wifip2pd: Cannot resolve iMac because peer not discovered with _airdrop._tcp.local
sharingd: Ask failed Error Domain=Sharing.SFAirDropSend.Failure Code=7
```

Toggling the iPhone's **Wi-Fi off and back on** cleared it immediately. iOS
re-registered its Continuity services and rebuilt the AWDL peer state.

---

## Things that were NOT the cause (all tested and disproven)

Every item below was believed at some point during this debugging session and
later disproven. Do not spend time on them.

| Claim | Reality |
|---|---|
| Both devices must be on the same Wi-Fi | **False.** AWDL is peer-to-peer and crosses networks. User-confirmed: it works on different Wi-Fi networks. |
| Wi-Fi channel must match the AirDrop channel (149) | **False.** Works after switching to a different network/channel entirely. |
| Ethernet must be disabled so Wi-Fi becomes primary | **False.** Works with Ethernet connected the whole time. |
| `NoMulticastAdvertisements` must be false | Not load-bearing. |
| `DiscoverableMode` must be `Everyone` | Not load-bearing. `Contacts Only` works too. |
| `sharingd` doesn't register `_airdrop._tcp`, register it yourself | **False and harmful.** `sharingd` registers it on a **dynamic port** (observed `16930`). A hand-rolled registrar pointing at `8770` advertises a dead port — 8770 is a separate listener. |
| `14e4:43b1` can't do AirDrop, buy a `14e4:43ba` card | **False.** No hardware replacement needed. |

---

## Diagnostic tooling pitfalls (this burned the most time)

If you write your own DNS-SD probe, get these right or every result is void:

### 1. `kDNSServiceFlagsIncludeAWDL` is `0x100000`, not `0x1000`

```c
kDNSServiceFlagsIncludeAWDL        = 0x100000   // correct
kDNSServiceFlagsReturnIntermediates = 0x1000    // what you get if you guess
kDNSServiceFlagsIncludeP2P         = 0x20000
```

Verify against Apple's header rather than memory:

```bash
curl -sL https://raw.githubusercontent.com/apple-oss-distributions/mDNSResponder/main/mDNSShared/dns_sd.h \
  | grep -nE 'IncludeAWDL|IncludeP2P'
```

### 2. Browse must bind the awdl0 interface index

An AWDL-only record is **invisible** to a browse on `kDNSServiceInterfaceIndexAny`
(0). The same record returns 1 item on ifIndex 7 and 0 items on Any.

### 3. `DNSServiceResolve` takes name / regtype / domain separately

```c
DNSServiceResolve(sdRef, flags, ifIndex,
                  const char *name,      // NOT a single fullname
                  const char *regtype,
                  const char *domain,
                  callback, context);
```

Passing a concatenated `fullname` shifts every later argument and returns
`-65540` (`kDNSServiceErr_BadParam`). This produced a session full of fake
"resolve failed" findings that had nothing to do with the system under test.

### 4. `dns-sd` CLI always returns 0 for AWDL services

It cannot pass `kDNSServiceFlagsIncludeAWDL`. `dns-sd -B _airdrop._tcp` returning
0 items means **nothing**. Use the C API (see `scripts/awdl_browse.py`).

### 5. Verify the peer is reachable before theorising

Stale DHCP leases lie. An iPhone that had roamed to another WLAN left two dead
ARP entries behind, each producing 100% packet loss and a fresh wrong theory.
Check `arp -a | grep -i iphone` and ping the live address — but remember that a
common subnet is not a requirement for AirDrop.

---

## Verification

```bash
# Bluetooth must be genuinely up
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: On / Address: 48:e2:44:e1:f1:7a / Firmware Version: v8718 c5747

# sharingd's own record, on a dynamic port
python3 scripts/awdl_browse.py _airdrop._tcp
# iMac  ifIndex 7  port 16930  host iMac.local.  TXT: flags=1

# peer's continuity service
python3 scripts/awdl_browse.py _companion-link._tcp
# iPhone instance appears on the Wi-Fi interface
```

Then transfer in both directions.

---

## Files

| File | Purpose |
|---|---|
| `scripts/awdl_browse.py` | DNS-SD browse with the **correct** `IncludeAWDL` flag, bound to awdl0 |
| `scripts/resolve_svc.py` | Resolve + TXT dump with the **correct** `DNSServiceResolve` signature |
| `scripts/airdrop_register.py` | Historical — **do not use.** Registers `_airdrop._tcp` on port 8770, which is wrong. Kept only so the mistake is documented. |
| `diagnose.sh` | Health check for the Bluetooth/NVRAM side |

---

## Why the "just buy a 43ba card" advice is incomplete

The `43ba` evidence is real, and swapping works. But on `14e4:43b1` the failure
here was not the card at all: Bluetooth was administratively shut down by a
one-line NVRAM conflict, and the peer's sharing state was stale. Wi-Fi itself
worked perfectly the entire time.

If you're on `43b1` and Wi-Fi works but AirDrop doesn't, check Bluetooth's
`State` and `Firmware` first — before spending money.

---

## License

MIT. Fork it, correct it, improve it. If this saves you from buying a card, or
from a night of chasing AWDL ghosts, that's the point.
