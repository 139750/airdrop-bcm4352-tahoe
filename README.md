# AirDrop Fix — Broadcom BCM4352 (`14e4:43b1`) on macOS 26 Tahoe

**Status: WORKING — bidirectional AirDrop verified (Mac → iPhone and iPhone → Mac)**

This documents a fully working fix for AirDrop on Hackintosh systems using the
**BCM94352Z / BCM4352 (`14e4:43b1`)** Wi-Fi+BT combo card under macOS 26 (Tahoe),
where Wi-Fi works via OCLP patches but AirDrop silently fails.

The common community verdict for this card is *"buy a BCM943602CDP"*. **That is not
required.** The failure here was not a hardware limitation — it was five independent
software faults stacked on top of each other, one of which (the NVRAM variable) was
invisible because macOS 26 removed the log mode that would have shown it.

---

## Tested environment

| Component | Value |
|---|---|
| macOS | 26.7.2 (25G332) |
| SMBIOS | `iMac20,1` |
| CPU | Intel i9-9900 ES |
| Wi-Fi/BT card | BCM94352Z — `14e4:43b1` (BCM4352), Bluetooth `0x0489:0xE07A` (Foxconn-packaged BCM20702) |
| Wireless stack | OCLP-Mod 3.1.9 root patch → `IO80211FamilyLegacy 1200.12.2b1` + `AirPort.BrcmNIC 1400.1.1` |
| SIP | `csr-active-config = 0x803` |
| Boot args | `keepsyms=1 igfxonln=1 alcid=3 -amfipassbeta -lilubetaall -brcmfxbeta brcmfx-country=#a` |

---

## Symptom

- Wi-Fi connects and works normally
- Bluetooth appears in System Information but `State: Off`, `Address: NULL`,
  `Chipset: BCM_4350C2`, `Firmware Version: v0 c0`
- AirDrop: iPhone never appears in the Mac's list (or appears but sends fail with
  `SFAirDropSend.Failure Code=7`), and the Mac never appears on the iPhone
- `sharingd` logs `AirDrop not ready: wifi=… bluetooth=… carplay=… receivingEnabled=… isVirtualMachine=… isMulticastAdvertisementsDisabled=…`
  with **every value redacted as `<private>`**

```bash
log show --last 5m --predicate 'process == "sharingd"' | grep "not ready"
```

### Why the values are hidden

`log config --mode "private_data:on"` **no longer exists in macOS 26**:

```
log: Invalid Modes 'private_data:on'
```

The valid modes are only `level`, `persist`, `stream`, `signpost-*`. Do not waste
time trying to unlock the redacted fields — you cannot.

You must reason about the six conditions from the outside. That is what the
diagnostic section below does.

---

## The five faults

Every one of these had to be fixed. Fixing any subset leaves AirDrop broken, and
because fault #1 kills Bluetooth outright, *nothing else you tweak will appear to
work* until it is fixed.

### Fault 1 — `bluetoothExternalDongleFailed` is wiped by OpenCore every boot

**This is the decisive one.**

Many OpenCore configs list `bluetoothExternalDongleFailed` under
`NVRAM > Delete > 7C436110-AB2A-4BBB-A880-FE41995C9F82`. Every boot OpenCore deletes
it; macOS then writes `1` ("external dongle failed") and **shuts the Bluetooth
controller down**.

Check the live value:

```bash
nvram bluetoothExternalDongleFailed
# %01  = broken  (Bluetooth will be State: Off)
# %00  = healthy
```

Confirm the shutdown in System Information:

```bash
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: Off / Address: NULL / Firmware Version: v0 c0   ← controller never came up
```

**Fix**

1. Remove `bluetoothExternalDongleFailed` from `NVRAM > Delete`.
2. Keep it in `NVRAM > Add` with the value `b'\x00'`.
3. Apply immediately without rebooting:

```bash
sudo nvram bluetoothExternalDongleFailed=%00
sudo nvram bluetoothInternalControllerInfo=%00%00%00%00%00%00%00%00%00%00%00%00%00%00
sudo pkill -9 bluetoothd
sleep 6
```

Verify:

```bash
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: On / Address: 48:E2:44:E1:F1:7A / Firmware Version: v8718 c5747
```

> **Red herring warning.** `ioreg -r -c BrcmPatchRAM3` shows
> `!registered, !matched` even when everything is fine — that node is the
> personality *matcher*, not a driver instance. Likewise, `0x0489:0xE07A` **is**
> present in BrcmPatchRAM3's 100 built-in personalities (`0489_e07a`, firmware
> `BCM20702A1_001.002.014.1483.1651_v5747`). No custom kext, no edited VID/PID
> table is needed. If you are tempted to "make a kext" here, you are solving the
> wrong problem.

### Fault 2 — `NoMulticastAdvertisements` blocks mDNS advertising

`isMulticastAdvertisementsDisabled` in the `not ready` line maps to this plist key.

```bash
defaults read /Library/Preferences/com.apple.mDNSResponder.plist NoMulticastAdvertisements
```

**Fix**

```bash
sudo defaults write /Library/Preferences/com.apple.mDNSResponder.plist NoMulticastAdvertisements -bool false
sudo killall -HUP mDNSResponder
sleep 3
sudo killall -9 sharingd
```

Effect: `Advertising Enabled: NO` → `YES`.

### Fault 3 — `DiscoverableMode` silently reverts to `Contacts Only`

```bash
defaults read com.apple.sharingd DiscoverableMode
# "Contacts Only"  ← wrong, must be Everyone
```

This reverts silently whenever the IdentityServices / Sharing state is reset.

**Fix**

```bash
defaults write com.apple.sharingd DiscoverableMode -string "Everyone"
```

### Fault 4 — Wi-Fi channel must equal the AirDrop channel

AWDL timeshares the radio with the associated Wi-Fi channel. If Wi-Fi sits on
channel 1 (2.4 GHz) or 64 while AWDL wants 149, the time-multiplexing cost is too
high and macOS **drops the AWDL time allocation entirely**. The visible result is:

```
DNS Error: Refused          (kDNSServiceErr_Refused, -65553)
airdrop.send.resolve-failure
```

on an `app_svc: com.apple.sharingd.AirDrop` connection bound to `en0`/`en1`.

```bash
system_profiler SPAirPortDataType | grep "AirDrop Channel"   # e.g. 149
```

Verify the **actual** associated channel with CoreWLAN — `system_profiler`
frequently reports a stale channel:

```python
import objc
objc.loadBundle("CoreWLAN", globals(), bundle_path="/System/Library/Frameworks/CoreWLAN.framework")
i = CWInterface.interface()
print(i.wlanChannel().channelNumber())
```

**Fix**: put the Wi-Fi SSID on the same channel the system picked for AWDL
(149 here). Note that some Xiaomi/regional firmware only exposes channels
36–64 and silently refuses 149 — check `available_channels` before assuming
the change took effect.

### Fault 5 — `sharingd` binds port 8770 but never registers `_airdrop._tcp`

This is the last gap, and it is a macOS-side omission (at least on this
configuration). The receiver is alive:

```bash
sudo lsof -nP -p $(pgrep -x sharingd) | grep LISTEN
# sharingd  22u  IPv6  ...  TCP *:8770 (LISTEN)
```

...but nothing is advertised:

```bash
dns-sd -B _airdrop._tcp local.     # 0 items — but this is a FALSE NEGATIVE
```

**`dns-sd` cannot pass `kDNSServiceFlagsIncludeAWDL`**, so it will never see AWDL
services. You must call the C API with the flag:

```c
DNSServiceBrowse(&ref,
                 kDNSServiceFlagsIncludeAWDL | kDNSServiceFlagsIncludeP2P,
                 kDNSServiceInterfaceIndexAny,
                 "_airdrop._tcp", "local.", callback, NULL);
```

`scripts/awdl_browse.py` is a ctypes implementation of exactly this. Run it and
you will see the iPhone's real records:

```
[FOUND] name='Gavin'  type='_rdlink._tcp.'  ifIndex=14     ← the iPhone
[FOUND] name='iMac'   type='_companion-link._tcp.'  ifIndex=1
```

`_airdrop._tcp` stays at **0 items** — confirming the Mac is not advertising.

**Fix**: register the service yourself, pointed at `sharingd`'s native 8770.
The transfer is still handled by macOS's own receiver; this only supplies the
announcement `sharingd` forgets to publish.

```python
from zeroconf import IPVersion, ServiceInfo, Zeroconf
import socket

zc = Zeroconf(interfaces=[awdl_ipv6], ip_version=IPVersion.V6Only, apple_p2p=True)
info = ServiceInfo(
    "_airdrop._tcp.local.",
    "iMac._airdrop._tcp.local.",
    addresses=[socket.inet_pton(socket.AF_INET6, awdl_ipv6)],
    port=8770,
    properties={b"flags": b"1"},
    server="iMac.local.",
)
zc.register_service(info)
```

`apple_p2p=True` is required — it is the python-zeroconf flag that enables AWDL
on Darwin. `scripts/airdrop_register.py` is the ready-to-run version, including a
LaunchAgent plist for boot persistence.

> **Expected behaviour**: port 8770 is bound **on demand**. When the AirDrop
> window is closed, `sharingd` releases it and the register script logs
> `8770 已无监听`. This is normal. Open the AirDrop window and it comes back.

---

## Diagnostic flow (do it in this order)

1. **Bluetooth first.** `system_profiler SPBluetoothDataType` must show `State: On`
   and a real firmware version. If it shows `v0 c0`, stop — fix Fault 1 before
   anything else. No BLE means no AirDrop handshake, ever.
2. **Channel match.** Compare `AirDrop Channel` with the real associated channel.
3. **mDNS advertising.** Check `Advertising Enabled: YES`.
4. **Service registration.** Use `awdl_browse.py` (not `dns-sd`) to confirm that
   `_airdrop._tcp` exists.
5. **Only then** look at `sharingd`'s `not ready` line.

Skipping to step 5 with a dead controller is the most common way to lose hours.

---

## What does NOT fix it

- **`AirportBrcmFixup` parameters** (`brcmfx-driver`, `brcmfx-country`, `brcmfx-aspm`)
  — they affect the Wi-Fi link only, never AWDL/AppService.
- **Patching `AppleBCMWLANCoreMac` / `BrcmPatchRAM3` personalities** — every Wi-Fi
  kext on macOS 26 is **codeless**. The actual binaries live in the signed
  `BootKernelExtensions.kc`. There is no file to edit; the chip-support check is
  compiled into a kernel collection you cannot modify without breaking the seal.
- **OCLP 3.0.0-rc.5 root patch** — fails with `kmutil` **Return Code 71**:
  `AppleCentauriManager` → `AppleEmbeddedPCIE` → `AppleARMPlatform` (ARM-only,
  unsatisfiable on Intel).
- **Patching SIP to enable `task_for_pid`** (`csr-active-config 0x803 → 0x807`) to
  attach a debugger to `sharingd` — it works (`Debugging Restrictions: disabled`)
  but is useless, because the interesting log values are redacted at the source
  and frida still cannot read them meaningfully. Revert it afterwards; the extra
  bit buys nothing for this problem.
- **Buying a BCM943602CDP (`14e4:43ba`)** — not required. It is the standard
  community answer, and it does work, but on `14e4:43b1` the five fixes above are
  sufficient.

---

## Why the "just replace the card" advice is incomplete

The community-visible evidence for `43ba` is real (bidirectional AirDrop verified
on macOS Tahoe 26.x with OCLP-Mod 3.1.3+). What is missed is *why* `43b1` fails:

- It is **not** in `AirPortBrcmNIC`'s native device list (`43ba`, `43e3`, `43a0` are).
  `AirportBrcmFixup` only patches it enough for the **Wi-Fi link**.
- That patch never extended to the AWDL/AppService path, so the failure surfaces
  as an AirDrop-only problem while Wi-Fi looks perfectly healthy.

Which is exactly why a working BLE stack plus an explicit `_airdrop._tcp`
registration closes the gap — the receiver was always functional.

---

## Files

| File | Purpose |
|---|---|
| `scripts/airdrop_register.py` | Registers `_airdrop._tcp` on awdl0 → `sharingd:8770` |
| `scripts/awdl_browse.py` | DNS-SD browse with `kDNSServiceFlagsIncludeAWDL` (the flag `dns-sd` can't pass) |
| `launchd/com.gavin.airdrop-register.plist` | LaunchAgent for boot persistence |
| `diagnose.sh` | One-shot health check for all five faults |

---

## Verification

```bash
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: On / Address: 48:E2:44:E1:F1:7A / Firmware Version: v8718 c5747

sudo lsof -nP -iTCP:8770 -sTCP:LISTEN
# sharingd ... TCP *:8770 (LISTEN)      (only while the AirDrop window is open)

/usr/bin/python3 scripts/awdl_browse.py | grep -E "_airdrop|_rdlink"
# ('Gavin', '_rdlink._tcp.', 'local.', 14)    ← iPhone visible
# ('iMac',  '_airdrop._tcp.', 'local.', 7)    ← Mac registered
```

Bidirectional transfer confirmed: Mac → iPhone and iPhone → Mac.

---

## License

MIT. Use it, fork it, improve it. If this saves you from buying a card, that is
the point.
