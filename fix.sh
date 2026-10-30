#!/bin/bash
# ============================================================================
#  黑苹果 AirDrop 一键修复 / Hackintosh AirDrop one-shot fix
#  适用: Broadcom BCM4352 (14e4:43b1) 及同类卡 + macOS 26 Tahoe
#
#  用法 / Usage:
#      curl -fsSL https://raw.githubusercontent.com/139750/airdrop-bcm4352-tahoe/main/fix.sh | bash
#  或 / or:
#      bash fix.sh          # 只检查，不改动 / check only
#      bash fix.sh --fix    # 检查并修复 / check and fix
# ============================================================================

set -u

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; DIM='\033[2m'; NC='\033[0m'
ok()   { printf "${GREEN}  ✓ %s${NC}\n" "$1"; }
bad()  { printf "${RED}  ✗ %s${NC}\n" "$1"; }
warn() { printf "${YELLOW}  ! %s${NC}\n" "$1"; }
info() { printf "${DIM}    %s${NC}\n" "$1"; }

DO_FIX=0
[ "${1:-}" = "--fix" ] && DO_FIX=1

echo
echo "============================================================"
echo " 黑苹果 AirDrop 诊断 / Hackintosh AirDrop diagnostic"
echo "============================================================"
echo

PROBLEMS=0

# ---------------------------------------------------------------- 1. 系统检查
echo "[1] 系统版本"
OSVER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
MAJOR=$(echo "$OSVER" | cut -d. -f1)
info "macOS $OSVER"
if [ "${MAJOR:-0}" -ge 26 ]; then
    ok "macOS 26 (Tahoe) — 本脚本的目标系统"
else
    warn "非 macOS 26；脚本仍可运行，但结论针对 Tahoe 验证"
fi
echo

# ---------------------------------------------------------------- 2. 网卡识别
echo "[2] 无线网卡"
ARPT=$(ioreg -rn ARPT 2>/dev/null | grep -m1 '"IOName"' | sed 's/.*"pci\(.*\)".*/\1/' || true)
if [ -n "${ARPT:-}" ]; then
    info "PCI: $ARPT"
    case "$ARPT" in
        14e4,*)
            ok "Broadcom 网卡（型号 ${ARPT}）"
            ;;
        *)
            info "非 Broadcom，脚本里的蓝牙修复可能不适用"
            ;;
    esac
else
    warn "未检测到 ARPT 节点（可能不是黑苹果，或 Wi-Fi 未加载）"
fi
echo

# ---------------------------------------------------------------- 3. 蓝牙状态
echo "[3] 蓝牙控制器  ← 最关键的一项"
BT=$(system_profiler SPBluetoothDataType 2>/dev/null || true)
BT_STATE=$(echo "$BT" | grep -m1 'State:' | awk '{print $2}')
BT_ADDR=$(echo "$BT" | grep -m1 'Address:' | awk '{print $2}')
BT_FW=$(echo "$BT" | grep -m1 'Firmware Version:' | cut -d: -f2- | xargs)
info "State=$BT_STATE  Address=$BT_ADDR  Firmware=$BT_FW"

if [ "$BT_STATE" = "On" ] && [ "$BT_ADDR" != "NULL" ] && [ -n "$BT_ADDR" ]; then
    ok "蓝牙正常（这是 AirDrop 的前提）"
    BT_OK=1
else
    bad "蓝牙没起来 —— 这就是 AirDrop 不通的根因"
    PROBLEMS=$((PROBLEMS+1))
    BT_OK=0
fi

NV=$(nvram bluetoothExternalDongleFailed 2>/dev/null | awk '{print $2}')
info "bluetoothExternalDongleFailed = ${NV:-<未设置>}"
if [ "${NV:-}" = "%00" ]; then
    ok "NVRAM 标志正常"
else
    bad "NVRAM 标志异常（${NV:-未设置}）→ 系统会关掉蓝牙"
    PROBLEMS=$((PROBLEMS+1))
    NVRAM_BAD=1
fi
echo

# ---------------------------------------------------------------- 4. AirDrop 服务
echo "[4] AirDrop 服务注册"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -f "$SCRIPT_DIR/scripts/awdl_browse.py" ] && command -v python3 >/dev/null 2>&1; then
    OUT=$(python3 "$SCRIPT_DIR/scripts/awdl_browse.py" _airdrop._tcp 2>/dev/null || true)
    if echo "$OUT" | grep -q "iMac\|port:"; then
        ok "sharingd 已注册 _airdrop._tcp"
        echo "$OUT" | grep -E "port:|TXT" | head -3 | while read -r l; do info "$l"; done
    else
        warn "没查到 _airdrop._tcp（AirDrop 窗口没开时正常）"
    fi
else
    info "跳过（需要同目录下的 scripts/awdl_browse.py）"
fi
echo

# ---------------------------------------------------------------- 5. 汇总
echo "============================================================"
if [ "$PROBLEMS" -eq 0 ]; then
    printf "${GREEN} 本机检查全部通过${NC}\n"
    echo " 如果 AirDrop 仍然不通，问题在对端："
    echo "   → 把 iPhone/iPad 的 Wi-Fi 关掉再打开一次"
    echo "   → 对端设「所有人（10 分钟）」并保持隔空投送界面打开"
    echo "============================================================"
    exit 0
fi

printf "${YELLOW} 发现 %d 个问题${NC}\n" "$PROBLEMS"
echo "============================================================"
echo

if [ "$DO_FIX" -ne 1 ]; then
    echo "当前是【只检查】模式，没有改动任何东西。"
    echo
    echo "要修复，重新运行并加 --fix："
    echo "  curl -fsSL https://raw.githubusercontent.com/139750/airdrop-bcm4352-tahoe/main/fix.sh | bash -s -- --fix"
    echo
    exit 1
fi

# ---------------------------------------------------------------- 修复
echo "开始修复（需要 sudo 权限）"
echo

if [ "${NVRAM_BAD:-0}" -eq 1 ]; then
    echo "→ 修复 NVRAM 蓝牙标志"
    sudo nvram bluetoothExternalDongleFailed=%00
    sudo nvram bluetoothInternalControllerInfo=%00%00%00%00%00%00%00%00%00%00%00%00%00%00
    echo "  已写入 %00"
    echo

    echo "→ 重启蓝牙服务"
    sudo pkill -9 bluetoothd 2>/dev/null || true
    sleep 6
    echo

    echo "→ 验证"
    BT2=$(system_profiler SPBluetoothDataType 2>/dev/null || true)
    S2=$(echo "$BT2" | grep -m1 'State:' | awk '{print $2}')
    A2=$(echo "$BT2" | grep -m1 'Address:' | awk '{print $2}')
    F2=$(echo "$BT2" | grep -m1 'Firmware Version:' | cut -d: -f2- | xargs)
    info "State=$S2  Address=$A2  Firmware=$F2"
    if [ "$S2" = "On" ] && [ "$A2" != "NULL" ]; then
        ok "蓝牙已恢复"
    else
        bad "蓝牙仍未起来，请重启一次再跑本脚本"
    fi
    echo
fi

cat <<'EOF'
============================================================
 修复完成。接下来做两件事：

 1) 让修复永久生效（否则每次开机可能复发）
    挂载 EFI，编辑 EFI/OC/config.plist：
      NVRAM > Delete > 7C436110-... 里删掉 bluetoothExternalDongleFailed
      NVRAM > Add    > 7C436110-... 里保留 bluetoothExternalDongleFailed = 00
    保存后重启。

 2) 对端（iPhone/iPad）把 Wi-Fi 关掉再打开一次
    这一步是让 iOS 重新注册 Continuity 服务，
    很多人卡在「Mac 发不出去」，实际是这一步没做。

 然后双向各传一次文件验证。
============================================================
EOF
