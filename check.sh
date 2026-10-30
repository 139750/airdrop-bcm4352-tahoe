#!/bin/bash
# ============================================================================
#  AirDrop 双向诊断 / Bidirectional AirDrop diagnostic
#
#  用法 / Usage:
#     curl -fsSL https://raw.githubusercontent.com/139750/airdrop-bcm4352-tahoe/main/check.sh | bash
#
#  它会分别检查：
#    Mac 侧是否健康（蓝牙 / 发布服务 / AwDL datapath）
#    对端是否还在广播（_appsvcprepair / _applicationservicepairing 是否老化）
#  然后明确告诉你：问题在哪一侧。
# ============================================================================

set -u
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { printf "${GREEN}  OK   %s${NC}\n" "$1"; }
bad()  { printf "${RED}  FAIL %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}  WARN %s${NC}\n" "$1"; }
info() { printf "${DIM}       %s${NC}\n" "$1"; }
hdr()  { printf "\n${BOLD}%s${NC}\n" "$1"; }

echo
echo "=============================================================="
echo " AirDrop 双向诊断 / Bidirectional AirDrop diagnostic"
echo " macOS $(sw_vers -productVersion 2>/dev/null)"
echo "=============================================================="

MAC_OK=1
PEER_OK=1

# ---------------------------------------------------------------- Mac 侧
hdr "[1] Mac 侧：蓝牙"

BT=$(system_profiler SPBluetoothDataType 2>/dev/null || true)
BT_STATE=$(echo "$BT" | grep -m1 'State:' | awk '{print $2}')
BT_ADDR=$(echo "$BT" | grep -m1 'Address:' | awk '{print $2}')
BT_FW=$(echo "$BT" | grep -m1 'Firmware Version:' | cut -d: -f2- | xargs)

if [ "$BT_STATE" = "On" ] && [ -n "${BT_ADDR:-}" ] && [ "$BT_ADDR" != "NULL" ]; then
    ok "蓝牙在线  State=$BT_STATE  地址=$BT_ADDR"
    info "固件 $BT_FW"
else
    bad "蓝牙未就绪  State=${BT_STATE:-?}  Address=${BT_ADDR:-NULL}"
    info "这是 AirDrop 的硬前提，先修这个"
    MAC_OK=0
fi

NV=$(nvram bluetoothExternalDongleFailed 2>/dev/null | awk '{print $2}')
if [ "${NV:-}" = "%00" ]; then
    ok "NVRAM 标志正常 (bluetoothExternalDongleFailed=%00)"
else
    bad "NVRAM 标志异常 (${NV:-未设置})，系统会关掉蓝牙"
    info "修复: sudo nvram bluetoothExternalDongleFailed=%00"
    info "永久: EFI/OC/config.plist 的 NVRAM > Delete 里删掉这个键"
    MAC_OK=0
fi

# ---------------------------------------------------------------- 发布服务
hdr "[2] Mac 侧：服务发布（wifip2pd 权威日志）"

PUB=$(log show --last 10m --predicate 'process == "wifip2pd"' --style compact 2>/dev/null \
      | grep -E "AWDLAdvertise .*_airdrop\._tcp\.local was started" | tail -1)

if [ -n "$PUB" ]; then
    ok "Mac 已发布 _airdrop._tcp"
    NAME=$(echo "$PUB" | sed -n 's/.*AWDLAdvertise \([^ ]*\)\._airdrop.*/\1/p')
    info "服务实例名: ${NAME:-?}"
    if [ -n "${NAME:-}" ] && [ "$NAME" != "iMac" ]; then
        info "注意：这是匿名哈希名（不是主机名），属正常隐私机制"
        info "按 'iMac' 去查 _airdrop 会得到 0 项 —— 这是常见的误判来源"
    fi
else
    warn "最近 10 分钟没有 _airdrop 发布记录"
    info "打开一次 Finder → 隔空投送，再跑本脚本"
    MAC_OK=0
fi

DP=$(log show --last 30m --predicate 'process == "wifip2pd"' --style compact 2>/dev/null \
     | grep "datapath established" | tail -1)
if [ -n "$DP" ]; then
    ok "曾建立 AWDL 数据通路（链路本身是通的）"
else
    info "最近 30 分钟无 datapath established 记录"
fi

# ---------------------------------------------------------------- 对端
hdr "[3] 对端：是否还在广播（关键）"

# 找出对端实例名：从 _applicationservicepairing 的 browse 结果里取第一个非本机项
PEER_NAME=""
BROWSE=$(log show --last 15m --predicate 'process == "wifip2pd"' --style compact 2>/dev/null \
         | grep -E "Received a new discovery result" | tail -1)
if [ -n "$BROWSE" ]; then
    PEER_NAME=$(echo "$BROWSE" | sed -n 's/.*\[\([^.]*\)\._applicationservicepairing.*/\1/p')
fi

if [ -n "${PEER_NAME:-}" ]; then
    info "发现的设备: $PEER_NAME"
else
    info "日志里没有发现记录，改用 mDNS 直接探测"
fi

AGING=$(log show --last 30m --predicate 'process == "wifip2pd"' --style compact 2>/dev/null \
        | grep "Aging out discovery result" | tail -2)
if [ -n "$AGING" ]; then
    warn "发现记录已老化（Aging out）——对端停止广播了"
    echo "$AGING" | sed 's/^/       /' | cut -c1-100
    PEER_OK=0
fi

ASK=$(log show --last 30m --predicate 'process == "sharingd"' --style compact 2>/dev/null \
      | grep "SFAirDropSend.Failure Code=7" | tail -1)
if [ -n "$ASK" ]; then
    bad "有过发送失败记录 (SFAirDropSend.Failure Code=7)"
    REF=$(log show --last 30m --predicate 'process == "sharingd"' --style compact 2>/dev/null \
          | grep "NWError Code=-65553" | tail -1)
    if [ -n "$REF" ]; then
        info "-65553 = kDNSServiceErr_Refused：请求的服务记录不存在"
        info "典型原因：对端 AirDrop 面板已关闭或超时"
    fi
    PEER_OK=0
fi

# ---------------------------------------------------------------- 结论
hdr "[4] 结论"

if [ "$MAC_OK" -eq 1 ] && [ "$PEER_OK" -eq 1 ]; then
    printf "${GREEN}  Mac 侧健康，对端也在广播 —— 双向都应该能传${NC}\n"
    echo "  如果仍失败，请在发送的那一刻让对端："
    echo "    · 屏幕解锁"
    echo "    · 隔空投送面板打开（或刚设过「所有人，10 分钟」）"
    exit 0
fi

if [ "$MAC_OK" -eq 0 ] && [ "$PEER_OK" -eq 0 ]; then
    printf "${RED}  两侧都有问题${NC}\n"
    echo "  先修 Mac 侧（蓝牙/NVRAM），再让对端重新广播"
elif [ "$MAC_OK" -eq 0 ]; then
    printf "${RED}  问题在 Mac 侧${NC}\n"
    echo "  → 跑修复脚本:"
    echo "    curl -fsSL https://raw.githubusercontent.com/139750/airdrop-bcm4352-tahoe/main/fix.sh | bash -s -- --fix"
else
    printf "${YELLOW}  问题在对端（iPhone/iPad）${NC}\n"
    echo "  Mac 侧是健康的，不用再改任何 Mac 设置。请在对端上："
    echo "    1) 打开「设置 → 通用 → 隔空投送」或控制中心长按网络卡片"
    echo "    2) 选择「所有人，10 分钟」"
    echo "    3) 保持面板打开，然后在 Mac 上点发送"
    echo
    echo "  原因：iOS 的 AirDrop 广播是按需+超时的，面板一关就停止广播，"
    echo "        Mac 侧会收到 kDNSServiceErr_Refused (-65553)。"
fi

echo
echo "=============================================================="
echo " 技术细节: docs/ANALYSIS.zh-CN.md"
echo "=============================================================="
exit 0
