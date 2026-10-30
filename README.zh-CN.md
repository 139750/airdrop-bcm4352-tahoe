# 黑苹果 AirDrop 实战 — Broadcom BCM4352（`14e4:43b1`）+ macOS 26 Tahoe

**状态：已可用 — 双向隔空投送实测通过（Mac → iPhone、iPhone → Mac）**

这是一份折腾了几个小时之后的复盘。结论很短，**「看起来像原因但其实不是」的清单很长**——而那才是最有用的部分，因为绝大多数教程都在往那些坑里带你。

---

## 一句话结论：真正起作用的只有两件事

| 哪一侧 | 做什么 |
|---|---|
| **Mac** | 修掉 `bluetoothExternalDongleFailed` 被 OpenCore 从 NVRAM 删掉的问题 |
| **对端（iPhone）** | 把 Wi-Fi 关掉再打开一次（强制 iOS 重新注册 Continuity 服务） |

就这两件。做完，一块「社区都说必须换掉」的网卡，双向隔空投送就通了。

---

## 唯一真实的技术故障：蓝牙从头到尾就没起来

系统信息里的表现：

```
状态：关闭        地址：NULL
芯片组：BCM_4350C2    固件版本：v0 c0
```

看 NVRAM 里的实际值：

```bash
nvram bluetoothExternalDongleFailed
# %01 = 坏的（蓝牙会一直是「关闭」）
# %00 = 正常
```

**根因**：很多 OpenCore 配置会在
`NVRAM > Delete > 7C436110-AB2A-4BBB-A880-FE41995C9F82` 里列出
`bluetoothExternalDongleFailed`。每次开机 OpenCore 把它删掉，macOS 随后写入
`1`（「外部蓝牙设备失败」），直接把控制器关掉——它压根没机会上传固件。

**修复：**

1. 从 `NVRAM > Delete` 里移除 `bluetoothExternalDongleFailed`
2. 保留在 `NVRAM > Add` 里，值设为 `b'\x00'`
3. 不重启直接生效：

```bash
sudo nvram bluetoothExternalDongleFailed=%00
sudo nvram bluetoothInternalControllerInfo=%00%00%00%00%00%00%00%00%00%00%00%00%00%00
sudo pkill -9 bluetoothd
sleep 6
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: On / Address: <真实 MAC> / Firmware Version: v8718 c5747
```

**这附近的几个「假线索」：**

- `ioreg -r -c BrcmPatchRAM3` 显示 `!registered, !matched` 是**正常的**——
  那个节点是 personality 匹配器，不是驱动实例。
- `0x0489:0xE07A`（富士康封装的 BCM20702）**本来就在** BrcmPatchRAM3 内置的
  personality 表里（`0489_e07a`，固件
  `BCM20702A1_001.002.014.1483.1651_v5747`）。不需要自制 kext，也不需要改 VID/PID 表。
  **如果你在纠结「做一个 kext」，方向就已经错了。**

---

## 第二件事：对端的共享服务状态是死的

Mac 这一侧检查都通过之后（蓝牙在线、`_airdrop._tcp` 能解析），发送方向仍然失败：

```
wifip2pd: Cannot resolve iMac because peer not discovered with _airdrop._tcp.local
sharingd: Ask failed Error Domain=Sharing.SFAirDropSend.Failure Code=7
```

把 iPhone 的 **Wi-Fi 关掉再打开**，立刻就好了——iOS 重新注册了 Continuity 服务，
AWDL 的对端状态也重建了。

---

## 被证伪的说法（全部实测，别再浪费时间）

下面每一条都在这次排查中被当成过原因，后来都被推翻了。

| 说法 | 实际情况 |
|---|---|
| 两台设备必须在同一个 Wi-Fi | **错。** AWDL 是点对点链路，跨网络也能用。用户实测确认：不在一个 Wi-Fi 里也可以。 |
| Wi-Fi 信道必须和 AirDrop 信道一致（149） | **错。** 换成完全不同的网络/信道之后照样能用。 |
| 必须关掉以太网，让 Wi-Fi 成为主接口 | **错。** 以太网全程开着也正常。 |
| `NoMulticastAdvertisements` 必须是 false | 不是必要条件。 |
| `DiscoverableMode` 必须是「所有人」 | 不是必要条件。「仅联系人」也可以。 |
| `sharingd` 不注册 `_airdrop._tcp`，要自己注册 | **错，而且有害。** `sharingd` 自己会注册，用的是**动态端口**（实测 `16930`）。手动注册指向 `8770` 是发布了一个死端口——8770 是另一个监听器，不是这个记录的端口。 |
| `14e4:43b1` 做不了 AirDrop，得换 `14e4:43ba` 网卡 | **错。** 完全不需要换硬件。 |

---

## 诊断工具本身的坑（这次时间全烧在这上面）

如果你要自己写 DNS-SD 探针，下面几条搞错了，所有结论都是废的：

### 1. `kDNSServiceFlagsIncludeAWDL` 是 `0x100000`，不是 `0x1000`

```c
kDNSServiceFlagsIncludeAWDL        = 0x100000   // 正确
kDNSServiceFlagsReturnIntermediates = 0x1000    // 凭记忆瞎猜就是这个
kDNSServiceFlagsIncludeP2P         = 0x20000
```

别凭记忆，去翻 Apple 的头文件：

```bash
curl -sL https://raw.githubusercontent.com/apple-oss-distributions/mDNSResponder/main/mDNSShared/dns_sd.h \
  | grep -nE 'IncludeAWDL|IncludeP2P'
```

### 2. Browse 必须绑定 awdl0 的接口索引

AWDL 上独有的记录，用 `kDNSServiceInterfaceIndexAny`（0）浏览是**看不见**的。
同一条记录，ifIndex 7 能返回 1 项，Any 返回 0 项。

### 3. `DNSServiceResolve` 的参数是 name / regtype / domain 三个分开的

```c
DNSServiceResolve(sdRef, flags, ifIndex,
                  const char *name,      // 不是一个拼好的 fullname
                  const char *regtype,
                  const char *domain,
                  callback, context);
```

传一个拼接好的 `fullname` 会让后面所有参数错位，返回 `-65540`
（`kDNSServiceErr_BadParam`）。这次排查里因此冒出一堆「resolve 失败」的假结论，
跟被测系统一点关系都没有。

### 4. `dns-sd` 命令行永远看不到 AWDL 服务

它没法传 `kDNSServiceFlagsIncludeAWDL`。`dns-sd -B _airdrop._tcp` 返回 0 项
**什么都不能说明**。要用 C API（见 `scripts/awdl_browse.py`）。

### 5. 先确认对端真的在线，再开始推理

DHCP 租约会骗人。这次 iPhone 悄悄漫游到了另一个 WLAN，留下两条死掉的 ARP 记录，
每条都能造出一次 100% 丢包和一个全新的错误方向。
先 `arp -a | grep -i iphone`，再 ping 活地址——但记住：**同一网段并不是 AirDrop 的前提条件**。

---

## 验证方法

```bash
# 蓝牙必须是真的起来了
system_profiler SPBluetoothDataType | grep -E "State|Address|Firmware"
# State: On / Address: 48:e2:44:e1:f1:7a / Firmware Version: v8718 c5747

# sharingd 自己注册的记录，动态端口
python3 scripts/awdl_browse.py _airdrop._tcp
# iMac  ifIndex 7  port 16930  host iMac.local.  TXT: flags=1

# 对端的 Continuity 服务
python3 scripts/awdl_browse.py _companion-link._tcp
# iPhone 的实例会出现在 Wi-Fi 接口上
```

然后双向各传一次。

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `scripts/awdl_browse.py` | 带**正确** `IncludeAWDL` 标志、绑定 awdl0 的 DNS-SD 浏览 |
| `scripts/resolve_svc.py` | 用**正确** `DNSServiceResolve` 签名做的解析 + TXT 输出 |
| `scripts/airdrop_register.py` | 历史遗留 — **不要用**。它把 `_airdrop._tcp` 注册到 8770，这个端口是错的。留着只是为了把这个错误记录下来。 |
| `diagnose.sh` | 蓝牙 / NVRAM 一侧的体检脚本 |

---

## 为什么「直接换 43ba 网卡」这个建议不完整

`43ba` 的证据是真的，换卡确实能解决。但在 `14e4:43b1` 上，**这次的故障跟网卡毫无关系**：
蓝牙被一行 NVRAM 冲突从管理层面关掉了，对端的共享状态又是死的。Wi-Fi 自始至终工作得好好的。

如果你也是 `43b1`、Wi-Fi 正常但 AirDrop 不通，**先看蓝牙的
`State` 和 `Firmware`**，再考虑花钱。

---

## 许可

MIT。拿去用、拿去改、拿去完善。如果它帮你省下了一张网卡的钱，或者省下了一个追着 AWDL 鬼影跑的夜晚，这份文档就没白写。
