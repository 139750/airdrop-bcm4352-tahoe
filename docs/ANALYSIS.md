# AirDrop 详细技术分析 / Detailed Technical Analysis

本文记录 **Mac → iPhone 方向失败** 的真实根因，所有结论均有日志或命令输出支撑。
This document records the *verified* root cause for the failing Mac → iPhone direction.
Every claim is backed by a log line or command output.

---

## 1. 两个方向走的是完全不同的机制

这是最容易误判的地方：**AirDrop 双向并不对称**。

| 方向 | 谁在发起 | 依赖的服务 | 依赖的链路 |
|---|---|---|---|
| **iPhone → Mac** | iPhone | Mac 发布的 `_airdrop._tcp`（匿名哈希名） | AWDL + BLE |
| **Mac → iPhone** | Mac | iPhone 发布的 `_appsvcprepair._tcp` / `_applicationservicepairing._tcp`，然后 `_asquic._udp` 传数据 | AWDL + BLE |

**所以「iPhone 能发给 Mac」完全不能证明「Mac 能发给 iPhone」。** 前者只需要 Mac 侧发布服务（sharingd/wifip2pd 自动完成），后者需要 iPhone 侧**主动保持广播状态**。

---

## 2. Mac 侧其实是健康的（实测证据）

```bash
# wifip2pd 发布日志：Mac 确实发布了 _airdrop（匿名哈希名，不是 "iMac"）
AWDLAdvertise 0c571d750a9a._airdrop._tcp.local was started        [AWDLDiscoveryEngine.swift:403]
AWDLAdvertise iMac._appsvcprepair._tcp.local was started
AWDLAdvertise iMac._applicationservicepairing._tcp.local was started

# 曾成功建立到 iPhone 的 AWDL 数据通路
AWDLDatapathInitiator Gavin._appsvcprepair._tcp.local <To: 7e:f1:52:3e:61:9e>
    datapath established with 48616ded-... %56715                  [AWDLDiscoveryEngine.swift:474]

# BLE 层能读到 iPhone 的 AirDrop 能力
SF 0x8000880382 < BLE Personal DuetSync WiFiP2P Owner ApplePay AirDropUsable >
SFRemoteHotspotDevice: name: Gavin, model iPhone18,1, battery 75, network 5G,
    supports companion link: yes
```

**关键**：Mac 发布的 `_airdrop._tcp` 服务名是 **匿名哈希**（`0c571d750a9a`），
**不是** 主机名 `iMac`。任何按名字 `iMac` 去查 `_airdrop._tcp` 的诊断脚本都会得到
0 项，从而得出「服务没注册」的错误结论 —— 这是本项目的第一个坑。

---

## 3. 真正的断点：iPhone 的发现服务已老化

实测三个服务：

```bash
# _asquic（QUIC 数据通道）—— 可解析
A272E8B2-8B29-4765-9D72-C0A506CED16D._asquic._udp.local.
    can be reached at Gavin.local.:61290 (interface 6)

# 两个「发现类」服务 —— 无响应
Gavin._applicationservicepairing._tcp   → 无响应
Gavin._appsvcprepair._tcp               → 无响应
```

对应日志：

```
wifip2pd: Aging out discovery result 7e:f1:52:3e:61:9e
          [Gavin._applicationservicepairing._tcp.local]        [AWDLDiscoveryEngine.swift:297]
wifip2pd: Aging out discovery result 7e:f1:52:3e:61:9e
          [Gavin._appsvcprepair._tcp.local]                    [AWDLDiscoveryEngine.swift:297]
wifip2pd: AWDLDatapathInitiator Gavin._appsvcprepair._tcp.local
          was terminated because User Requested                [AWDLDiscoveryEngine.swift:493]
```

**`Aging out` = mDNS 记录超时，iPhone 停止广播。**

然后 Mac 发送时：

```
sharingd: Ask failed Error Domain=Sharing.SFAirDropSend.Failure Code=7
sharingd: Waiting for transfer connection Error Domain=Network.NWError Code=-65553
```

**`-65553` = `kDNSServiceErr_Refused`**（见 `dns_sd.h`），即服务解析被拒绝 —— 因为这条记录已经不存在了。

---

## 3.5 The two failure stages of a send (measured)

A Mac → iPhone transfer fails at one of two distinct stages, and the symptom differs.

### Stage A — cannot connect (App Service timeout)

```
09:45:24  Sending ASK request
09:45:24  Creating new AirDrop connection → Connecting to endpoint → Starting connection
09:45:39  Waiting for transfer connection Error Domain=Network...     ← 15 s timeout
09:45:39  Resolve failed → Returning cached AirDropID
09:45:39  Transfer connection invalidated
          [C4.1 app_svc: com.apple.sharingd.AirDrop, service_id: 7D8DD6A1...]
          SFServiceCore Invalidated
```

The endpoint being connected to is `app_svc` — the peer's `_applicationservicepairing._tcp`.

- Service present → connection establishes → the iPhone shows a prompt
- Service absent → 15 s timeout, **no prompt on the iPhone at all**, Mac UI just hangs

Measured at the same moment:

```
_applicationservicepairing._tcp   1 item    ← only iMac (the Mac itself)
_appsvcprepair._tcp               1 item    ← only iMac
_asquic._udp                      5 items   ← the iPhone's QUIC channel IS present
```

The iPhone opened its QUIC data channel but did **not** advertise the "discoverable"
service, so Stage A can only time out.

### Stage B — connected but rejected

```
Ask failed Error Domain=Sharing.SFAirDropSend.Failure Code=7
```

The connection was established and the request delivered, but the peer declined or
timed out waiting for a human to accept (locked screen, "Contacts Only", etc).

### How to tell them apart

| Symptom | Stage | Meaning |
|---|---|---|
| Send spins forever, iPhone shows nothing | A | Peer is not advertising `_applicationservicepairing` |
| iPhone prompts, then declines/times out | B | Stage A worked; the problem is authorisation |

---

## 4. Conclusion: the iPhone must be in a discoverable state

iOS 的 AirDrop 广播是 **按需 + 超时** 的，这是 Apple 的隐私设计：

- 隔空投送面板**关闭** → 停止广播 `_appsvcprepair` / `_applicationservicepairing`
- 「所有人」模式**超时**（`_checkEveryoneModeExpiry` / `_isEveryoneModeExpired` /
  `_expireEveryoneModeAndOnlySetDefault:`）→ 降级回「仅联系人」
- 锁屏超过一定时间 → 同上

**所以在 Mac 上点发送的那一刻，iPhone 必须：**

1. 屏幕解锁
2. 隔空投送面板**打开**（或刚设置过「所有人，10 分钟」）
3. 保持在 Mac 的 AWDL 范围内

符合这三条时，Mac → iPhone 可以成功；只要 iPhone 面板关闭几分钟，
`Aging out` 就会发生，之后任何发送都是 `Ask failed Code=7`。

---

## 5. 工具陷阱（会直接导致错误结论）

| 陷阱 | 后果 | 正确做法 |
|---|---|---|
| 用 `dns-sd -B _airdrop._tcp` 判断服务是否存在 | 永远 0 项（CLI 不能传 `kDNSServiceFlagsIncludeAWDL`） | 用 C API + `0x100000` 标志 |
| 按 `iMac` 去查 `_airdrop._tcp` | 永远查不到（真实名字是匿名哈希） | 只查服务类型，不预设实例名 |
| 用 `resolve_svc.py` 查 `_airdrop` 得 0 项 → 断定「未注册」 | 错误结论 | 查 `wifip2pd` 的 `AWDLAdvertise` 日志才是权威 |
| 把 `Advertising Enabled: NO` 当成 AirDrop 故障 | 误判（那是 **Handoff** 子系统） | 看 `com.apple.sharing:AirDrop` 而非 `:Handoff` |
| 把 `AirDrop not ready` 当成持续故障 | 它只是启动瞬间的正常日志 | 看是否**持续**出现 |
| 用过期 ARP 判断对端在线 | 假死 | ping 活地址；但注意同一网段不是 AirDrop 前提 |

---

## 6. 已验证的失败特征（用于快速判断）

出现下面组合，说明 **iPhone 侧没有在广播**，不需要动 Mac：

```
Ask failed Error Domain=Sharing.SFAirDropSend.Failure Code=7
NWError Code=-65553            (= kDNSServiceErr_Refused)
wifip2pd: Aging out discovery result [Gavin._applicationservicepairing._tcp.local]
```

出现下面组合，说明 **Mac 侧蓝牙没起来**（本项目最早的故障）：

```
State: Off / Address: NULL / Firmware v0 c0
nvram bluetoothExternalDongleFailed = %01
→ 检查 OpenCore NVRAM > Delete 是否清掉了这个键
```

---

## 7. 仍然与 AirDrop 无关的因素（已实测排除）

- Wi-Fi 信道是否与 AirDrop 信道一致
- 是否在同一 Wi-Fi / 同一网段（AWDL 是 P2P）
- 以太网是否启用
- `NoMulticastAdvertisements` / `DiscoverableMode`（对**已老化**的对端无效）
- 手动注册 `_airdrop._tcp`（sharingd/wifip2pd 自己会注册，手动注册反而干扰）

---

*本文所有日志取自 macOS 26.7.2 (25G332)，iMac20,1，BCM94352Z (14e4:43b1) + OCLP-Mod 3.1.9。*
