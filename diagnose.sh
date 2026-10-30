#!/bin/bash
# AirDrop health check for Broadcom BCM4352 (14e4:43b1) on macOS 26 Tahoe
# Checks all five known faults and reports PASS / FAIL for each.

set +e
PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
dim()   { printf "\033[2m%s\033[0m\n" "$1"; }

check() {
    local name="$1"; local ok="$2"; local detail="$3"
    if [ "$ok" = "1" ]; then
        green "  [PASS] $name"
        PASS=$((PASS+1))
    else
        red   "  [FAIL] $name"
        FAIL=$((FAIL+1))
    fi
    [ -n "$detail" ] && dim "         $detail"
}

echo "=============================================="
echo " AirDrop health check — BCM4352 / macOS 26"
echo "=============================================="
echo

# ---- 1. Bluetooth controller alive ----
echo "1. Bluetooth controller"
BT_STATE=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -m1 "State:" | awk '{print $2}')
BT_ADDR=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -m1 "Address:" | awk '{print $2}')
BT_FW=$(system_profiler SPBluetoothDataType 2>/dev/null | grep -m1 "Firmware Version:" | cut -d: -f2- | xargs)
if [ "$BT_STATE" = "On" ] && [ "$BT_ADDR" != "NULL" ]; then
    check "Bluetooth State: On, Address present" 1 "addr=$BT_ADDR fw=$BT_FW"
else
    check "Bluetooth State: On, Address present" 0 "state=$BT_STATE addr=$BT_ADDR fw=$BT_FW — see Fault 1 (NVRAM)"
fi

NVRAM_BT=$(nvram bluetoothExternalDongleFailed 2>/dev/null | awk '{print $2}')
echo "   bluetoothExternalDongleFailed = ${NVRAM_BT:-<unset>}"
echo

# ---- 2. NoMulticastAdvertisements ----
echo "2. mDNS multicast advertising"
NMA=$(defaults read /Library/Preferences/com.apple.mDNSResponder.plist NoMulticastAdvertisements 2>/dev/null)
if [ "$NMA" = "0" ]; then
    check "NoMulticastAdvertisements = false" 1 "value=$NMA"
else
    check "NoMulticastAdvertisements = false" 0 "value=${NMA:-<unset, defaults to true>} — see Fault 2"
fi
echo

# ---- 3. Discoverable mode ----
echo "3. Discoverable mode"
DM=$(defaults read com.apple.sharingd DiscoverableMode 2>/dev/null)
if [ "$DM" = "Everyone" ]; then
    check "DiscoverableMode = Everyone" 1 ""
else
    check "DiscoverableMode = Everyone" 0 "value='$DM' — see Fault 3"
fi
echo

# ---- 4. Channel match ----
echo "4. AWDL channel vs Wi-Fi channel"
AWDL_CH=$(system_profiler SPAirPortDataType 2>/dev/null | grep -m1 "AirDrop Channel" | awk '{print $3}')
WIFI_CH=$(/usr/bin/python3 -c "
import objc
objc.loadBundle('CoreWLAN', globals(), bundle_path='/System/Library/Frameworks/CoreWLAN.framework')
i = CWInterface.interface()
c = i.wlanChannel()
print(c.channelNumber() if c else '')
" 2>/dev/null)
if [ -n "$AWDL_CH" ] && [ "$AWDL_CH" = "$WIFI_CH" ]; then
    check "AirDrop channel == Wi-Fi channel ($AWDL_CH)" 1 ""
else
    check "AirDrop channel == Wi-Fi channel" 0 "airdrop=$AWDL_CH wifi=$WIFI_CH — see Fault 4"
fi
echo

# ---- 5. _airdrop._tcp registration ----
echo "5. _airdrop._tcp service registration"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/scripts/awdl_browse.py" ]; then
    OUT=$(/usr/bin/python3 "$SCRIPT_DIR/scripts/awdl_browse.py" 2>/dev/null)
    if echo "$OUT" | grep -q "_airdrop._tcp.*iMac\|iMac.*_airdrop"; then
        check "_airdrop._tcp registered on AWDL" 1 ""
    else
        check "_airdrop._tcp registered on AWDL" 0 "not advertised — see Fault 5 (run scripts/airdrop_register.py)"
    fi
    if echo "$OUT" | grep -q "_rdlink._tcp"; then
        dim "         iPhone visible via _rdlink:_tcp (good)"
    else
        dim "         no _rdlink._tcp peer (iPhone AirDrop may be closed)"
    fi
else
    check "_airdrop._tcp registered on AWDL" 0 "scripts/awdl_browse.py not found"
fi
echo

# ---- Receiver port ----
echo "6. Receiver port 8770 (on-demand)"
if sudo -n lsof -nP -iTCP:8770 -sTCP:LISTEN 2>/dev/null | grep -q sharingd || \
   lsof -nP -iTCP:8770 -sTCP:LISTEN 2>/dev/null | grep -q sharingd; then
    dim "         sharingd listening on 8770 (AirDrop window open)"
else
    dim "         8770 not bound — normal when the AirDrop window is closed"
fi
echo

echo "=============================================="
echo " PASS: $PASS   FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    green " All checks passed — AirDrop should work."
else
    red " $FAIL check(s) failed — see README for the matching fault."
fi
echo "=============================================="
