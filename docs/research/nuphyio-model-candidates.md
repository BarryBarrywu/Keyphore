# NuPhyIO 型号扩展候选（未验证）

调研日期：2026-09-03。

本文记录潜在适配对象与证据强弱，不是 Keyphore 兼容列表、发布计划或购买建议。本轮只读资料和代码，没有连接、安装或实测候选键盘。

## 当前支持边界

Keyphore 当前仅支持原厂固件 Air65 V3 的已验证有线 USB 路径。[设备选择器](../../app/Sources/KeyphoreCore/Air65Device.swift)限定 `19f5:102b`、产品名 `Air65 V3`、接口 `3`、usage page `0x0001` / usage `0x0000`，且遇到多个匹配设备时拒绝写入。

“出现在 NuPhyIO 官方支持列表”只证明官方工具支持该型号，不证明它与 Air65 V3 使用相同的会话协议、灯光地址、效果编号或响应格式。以下候选均未通过 Keyphore 验收。

## 候选与证据

| 型号／版本 | 已找到的证据 | 适配判断与待验证项 |
| --- | --- | --- |
| Air75 V3 | 官方列表收录；上游 nuphyctl 记录了 Air75 V3 主背光效果映射以及同类 64 字节会话协议 [1][2] | 优先研究主背光；确认精确设备标识、灯态布局、读回和原厂固件表现。上游资料不是 Keyphore 真机验收。 |
| Kick75 IO | 官方列表收录；独立项目声明验证了 macOS + Kick75 IO `19f5:1026` 的 USB 侧灯控制；也是本项目协议参考来源 [1][3][4] | 协议复用依据较强，但已知对象是五颗侧灯，不能把侧灯验证扩大为主背光支持；需先明确 signal surface。 |
| Air100 V3 | 官方列表及产品页明确支持 NuPhyIO [1][5] | 与现有型号同属 Air V3，作为近邻候选；协议复用可能性是推断，尚无本轮确认的型号专属报文证据。 |
| Halo65 / Halo75 / Halo96 V2 **IO 版** | 官方列表明确标为 IO；产品页也区分 NuPhyIO driver version [1][6] | 候选；分别核对主背光与外圈通道，不能照搬 Air65 灯态地址，也不能与 QMK/VIA 版混用。 |
| Node75 / Node100，HP / LP 版 | 官方列表收录上述型号 [1] | 候选；当前只有官方工具兼容性证据，布局、设备标识与灯光通道仍需验证。 |
| Air60 HE、Air75 HE、Halo65 HE、Field75 HE / HE V2 | 官方列表收录上述型号 [1] | 较低优先级研究对象；不能从同一个 NuPhyIO 前端推定底层协议一致，更不能复用机械轴型号的地址进行试写。 |

这是面向本次讨论的候选清单，不是 NuPhyIO 官方设备目录的完整镜像。

## 不可跨越的边界

- **版本**：Kick75 与 Halo V2 必须区分 IO 和 QMK/VIA。后者属于另一条驱动路线，不在此清单的协议复用判断内。
- **布局**：官方将 Air V3 和 Node 的部分 ANSI / ISO / JIS 变体分开列出；不默认设备 ID、固件或灯态布局一致。现有 Air65 V3 验收不覆盖所有同名布局变体。
- **连接**：先研究有线 USB。产品具备蓝牙／2.4 GHz，不代表这些连接开放相同的灯光控制通道。
- **灯区**：主背光、侧灯、外圈分别验证。上游已记录装饰灯地址随型号变化，不能套用固定偏移 [2]。
- **产品语义**：保留独立状态核心、持久状态和 Companion 唯一 HID owner；无任务时 signal-off。不因参考项目的默认行为而改为恢复原灯效。

## 研究顺序与升级为支持的条件

建议先选 Air75 V3 验证现有主背光路线；随后按目标选择 Air100 V3 扩展同系列，或 Kick75 IO 探索侧灯。这个顺序是研究建议，不代表承诺实现。

候选升级为支持前，必须完成：

1. 核对具体型号、IO 固件版本、布局、USB 身份与接口；未知或歧义设备保持拒绝写入。
2. 验证会话与响应匹配、灯态读取和目标灯区字段；准备型号专属协议夹具，不直接放宽现有设备白名单。
3. 在用户授权的实体测试中确认 execution、attention、completion、signal-off 的可见表现，以及非目标灯区、键位和持久配置未被改变。
4. 验证断连／重连、睡眠唤醒、退出与重新打开的行为；通过 App 引导、诊断与人工视觉确认后，再更新公开支持声明。

## 来源

[1] [NuPhyIO 官方 Device Support](https://www.nuphy.io/)：2026-09-03 读取的动态设备目录。目录收录不是第三方协议兼容性保证。

[2] [fldc/nuphyctl 协议记录，974ca698](https://github.com/fldc/nuphyctl/blob/974ca698605ae7d5258dcf21777330a6df6867b1/docs/reverse-engineering.md)：64 字节报文、会话交换、Air75 V3 主背光效果，以及型号相关的装饰灯偏移。

[3] [Pixelmoss/codex-kick75-status-lights，e32648ee](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/README.md)：README 声明仅验证 macOS + Kick75 IO USB 侧灯控制。

[4] [Keyphore NuPhyIO 协议来源声明](../../LICENSES/NUPHYIO-NOTICE.txt)：记录本项目参考的 nuphyctl 和 Kick75 协议快照。

[5] [NuPhy Air100 V3 官方产品页](https://nuphy.com/products/nuphy-air-100-v3)。

[6] [NuPhy Halo IO 系列官方产品页](https://pay.nuphy.com/products/nuphy-halo-v2-io)。
