# AirDrop 详细技术分析（中文版）

本文记录 **Mac → iPhone 方向失败** 的真实根因。每条结论都有日志或命令输出支撑，没有推测。

---

## 1. 两个方向的机制完全不同

这是最容易误判的地方：**AirDrop 双向并不对称**。

| 方向 | 谁发起 | 依赖的服务 | 依赖链路 |
|---|---|---|---|
| **iPhone → Mac** | iPhone | Mac 发布的 `_airdrop._tcp`（匿名哈希名） | AWDL + BLE |
| **Mac → iPhone** | Mac | iPhone 发布的 `_appsvcprepair._tcp` / `_applicationservicepairing._tcp`，再用 `_asquic._udp` 传数据 | AWDL + BLE |

**所以「iPhone 能发给 Mac」根本不能证明「Mac 能发给 iPhone」。**
前者只需要 Mac 侧发布服务（`sharingd` / `wifip2pd` 自动完成）；
后者需要 iPhone 侧**主动保持广播状态**。

---

## 2. Mac 侧其实是健康的（实测证据）

```bash
# wifip2pd 发布日志：Mac 确实发布了 _airdrop，但名字是匿名哈希，不是 "iMac"
AWDLAdvertise 0c571d750a9a._airdrop._tcp.local was started        [AWDLDiscoveryEngine.swift:403]
AWDLAdvertise iMac._appsvcprepair._tcp.local was started
AWDLAdvertise iMac._applicationservicepairing._tcp.local was started

# 曾经成功建立到 iPhone 的 AWDL 数据通路
AWDLDatapathInitiator Gavin._appsvcprepair._tcp.local <To: 7e:f1:52:3e:61:9e>
    datapath established with 48616ded-... %56715                  [AWDLDiscoveryEngine.swift:474]

# BLE 层能读到 iPhone 的 AirDrop 能力
SF 0x8000880382 < BLE Personal DuetSync WiFiP2P Owner ApplePay AirDropUsable >
SFRemoteHotspotDevice: name: Gavin, model iPhone18,1, battery 75, network 5G,
    supports companion link: yes
```

**关键坑**：Mac 发布的 `_airdrop._tcp` 服务名是**匿名哈希**（`0c571d750a9a`），
**不是** `iMac`。任何按 `iMac` 去查 `_airdrop._tcp` 的脚本都会得到 0 项，
从而得出「服务没注册」的错误结论。这是本项目第一个踩的坑。

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

**`-65553` = `kDNSServiceErr_Refused`**（定义见 `dns_sd.h`），
意思是服务解析被拒绝——因为那条记录已经不存在了。

---

## 4. 结论：iPhone 必须处于「可被发现」状态

iOS 的 AirDrop 广播是 **按需 + 超时** 的，这是 Apple 的隐私设计：

- 隔空投送面板**关闭** → 停止广播 `_appsvcprepair` / `_applicationservicepairing`
- 「所有人」模式**超时** → 降级回「仅联系人」
  （`sharingd` 里的 `_checkEveryoneModeExpiry`、`_isEveryoneModeExpired`、
  `_expireEveryoneModeAndOnlySetDefault:`、`Everyone mode expired - setting to %@`）
- 锁屏超时 → 同上

**所以在 Mac 上点发送的那一刻，iPhone 必须满足：**

1. 屏幕已解锁
2. 隔空投送面板**打开**（或刚设置过「所有人，10 分钟」）
3. 仍在 Mac 的 AWDL 范围内

三条满足时，Mac → iPhone 可以成功；只要 iPhone 面板关掉几分钟，
`Aging out` 就会发生，之后任何发送都是 `Ask failed Code=7`。

---

## 5. 工具陷阱（会直接导致错误结论）

| 陷阱 | 后果 | 正确做法 |
|---|---|---|
| 用 `dns-sd -B _airdrop._tcp` 判断服务是否存在 | 永远 0 项（CLI 不能传 `kDNSServiceFlagsIncludeAWDL`） | 用 C API + `0x100000` 标志 |
| 按 `iMac` 去查 `_airdrop._tcp` | 永远查不到（真实名字是匿名哈希） | 只查服务类型，不预设实例名 |
| 查 `_airdrop` 得 0 项就断定「未注册」 | 错误结论 | `wifip2pd` 的 `AWDLAdvertise` 日志才是权威 |
| 把 `Advertising Enabled: NO` 当成 AirDrop 故障 | 误判——那是 **Handoff** 子系统 | 看 `com.apple.sharing:AirDrop`，不是 `:Handoff` |
| 把 `AirDrop not ready` 当成持续故障 | 它只是启动瞬间的正常日志 | 判断是否**持续**出现 |
| 用过期 ARP 判断对端在线 | 假死 | ping 活地址；但同网段并非 AirDrop 前提 |

---

## 6. 快速判断表

**出现下面组合 → iPhone 侧没有在广播，不要动 Mac：**

```
Ask failed Error Domain=Sharing.SFAirDropSend.Failure Code=7
NWError Code=-65553            (= kDNSServiceErr_Refused)
wifip2pd: Aging out discovery result [Gavin._applicationservicepairing._tcp.local]
```

**出现下面组合 → Mac 侧蓝牙没起来（本项目最早的故障）：**

```
State: Off / Address: NULL / Firmware v0 c0
nvram bluetoothExternalDongleFailed = %01
→ 检查 OpenCore 的 NVRAM > Delete 是否清掉了这个键
```

---

## 7. 与 AirDrop 无关的因素（已实测排除）

- Wi-Fi 信道是否与 AirDrop 信道一致
- 是否在同一 Wi-Fi / 同一网段（AWDL 是点对点）
- 以太网是否启用
- `NoMulticastAdvertisements` / `DiscoverableMode`（对**已经老化**的对端无效）
- 手动注册 `_airdrop._tcp`（`sharingd` / `wifip2pd` 自己会注册，手动注册反而干扰）

---

*所有日志取自 macOS 26.7.2 (25G332)，iMac20,1，BCM94352Z (14e4:43b1) + OCLP-Mod 3.1.9。*
