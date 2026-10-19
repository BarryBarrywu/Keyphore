# NuPhy Air75 V2 VIA 灯光协议研究

## 结论

Air75 V2 的有线 USB `19f5:3246` 已完成 VIA 12 主背光驱动及 App 接入，并通过软件回归。2026-10-15 已在用户设备上验证版本查询、RGB Matrix GET，以及蓝色呼吸、橙色呼吸、绿色常亮、关灯的 SET 与独立 GET；四个灯光步骤全部回读成功。签名开发版也已实测拒绝 V2/V3 混接。人工目视确认与真实运行中的拔插/睡眠恢复验收仍未完成。官方源码的 RGB Matrix SET 使用 `noeeprom` API，本身不标记持久化写入；协议版本相同仍不能证明用户固件与此源码完全一致。

## 固定来源

研究日期：2026-10-14；实现与验证更新于 2026-10-15。隔离分支 `feat/air75-v2-via`，实现基线 `aa62c3e`。NuPhy 官方仓库 `nuphy-air75` 分支源码快照：[`0f6d5f7`](https://github.com/nuphy-src/qmk_firmware/tree/0f6d5f7ed6211949de7105aee518cd5635465b3e)。它不是从用户键盘读取的固件版本，也不代表所有官方发行固件。

- [keyboard.json](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/keyboards/nuphy/air75_v2/ansi/keyboard.json)：设备身份、RGB Matrix、效果列表。
- [VIA rules.mk](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/keyboards/nuphy/air75_v2/ansi/keymaps/via/rules.mk)：`VIA_ENABLE = yes`。
- [usb_descriptor_common.h](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/tmk_core/protocol/usb_descriptor_common.h)、[usb_descriptor.h](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/tmk_core/protocol/usb_descriptor.h)、[usb_descriptor.c](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/tmk_core/protocol/usb_descriptor.c)：RAW HID usage 与 report 大小。
- [via.h](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/quantum/via.h)、[via.c](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/quantum/via.c)：VIA 命令和 RGB Matrix 实现。
- [side.c](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/keyboards/nuphy/air75_v2/ansi/side.c)：侧灯独立状态及 EEPROM 写入。

## HID 与报文

`keyboard.json:2-18` 声明 NuPhy Air75 V2，VID `0x19F5`、PID `0x3246`，启用 `rgb_matrix`。`usb_descriptor_common.h:28-33` 定义 RAW HID usage page `0xFF60`、usage `0x61`；`usb_descriptor.h:291` 定义 `RAW_EPSIZE 32`；`usb_descriptor.c:387-408` 描述 32 字节 input/output。该 descriptor 段没有 `HID_RI_REPORT_ID`，所以源码推断 RAW 报告无 report ID，发送缓冲区长度为 32 字节。

VIA 报文中的第一个字节是 command ID，后续字节为 command data；QMK 源码在 `via.c:279-281` 将其解释为 `data[0]` 和 `data[1...]`。以下均指 32 字节设备报告，未列出的字节填 0。macOS IOHID 的 report ID 参数为 0；如果改用 HIDAPI，其 API 要求的前置 report-ID 占位字节不属于这 32 字节协议正文，不能混入解析。

### 1. 查询 VIA 协议版本（只读）

请求：

```text
01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

响应：字节 0 保持 `01`；字节 1-2 为大端协议整数版本 `00 0C`（12，并非 VIA 应用版本）；其余字节保持原缓冲区。证据：`quantum/via.h:60-62`、`quantum/via.c:289-293`。

### 2. 读取 RGB Matrix 值（只读）

命令 `0x08`（`id_custom_get_value`），channel `0x03`（RGB Matrix），value ID：

```text
08 03 01 00 ...   # brightness，响应字节 3 = 0..255
08 03 02 00 ...   # effect，响应字节 3 = mode；关闭时为 0
08 03 03 00 ...   # effect speed，响应字节 3 = speed
08 03 04 00 ...   # color，响应字节 3 = hue，字节 4 = saturation
```

证据：`quantum/via.h:107-133`、`quantum/via.c:637-685`。brightness 是把固件内部最大值 128 映射到 0..255；SET 使用 `scale8`、GET 使用整数除法，存在量化，回读不能简单要求等于原请求字节。effect 是 RGB Matrix mode 编号；color 是 HSV 的 hue/saturation，不是 RGB 三元组。每次查询须校验报告长度及 command/channel/value；`FF` 表示未处理，不能当作成功。

### 3. 写入 RGB Matrix（SET 本身不请求保存）

命令 `0x07`（`id_custom_set_value`），字段与读取相同：

```text
07 03 01 VV ...   # brightness = VV
07 03 02 NN ...   # effect = NN；NN=0 关闭
07 03 03 SS ...   # effect speed = SS
07 03 04 HH TT ...# hue = HH，saturation = TT
```

证据：`quantum/via.c:688-715`。实现调用 `rgb_matrix_sethsv_noeeprom`、`rgb_matrix_enable_noeeprom`、`rgb_matrix_mode_noeeprom`、`rgb_matrix_set_speed_noeeprom`，故每次 set 不直接写 EEPROM。请求布局是 command/channel/value/value-data，响应通常为同一缓冲区回显。

### 4. 保存命令（本研究路径禁止发送）

命令 `09 03 ...`（`id_custom_save` + RGB Matrix channel）会进入 `via_qmk_rgb_matrix_save()`，其 `quantum/via.c:717-719` 调用 `eeconfig_update_rgb_matrix()`。这会持久化主 RGB Matrix 状态；本轮不得发送 `09`，以避免改变用户设置。源码能证明显式 save 的写入点，但不能据此保证所有固件版本不存在额外的延迟保存或厂商覆盖。

此快照也存在具体的延迟保存边界：[eeconfig.h:171-205](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/quantum/eeconfig.h#L171-L205) 的 dirty 标记采用 `dirty |= v`，`noeeprom` 不会清除其他操作留下的 dirty；[rgb_matrix.c:261-263](https://github.com/nuphy-src/qmk_firmware/blob/0f6d5f7ed6211949de7105aee518cd5635465b3e/quantum/rgb_matrix/rgb_matrix.c#L261-L263) 会刷新已有 dirty 状态。因此只能断言这组 SET 本身不申请保存；用户同时操作会保存 RGB 的快捷键或其他软件发出 SAVE，仍可能持久化当前 RAM 灯态。协议 SET 回显也不等于实际应用成功，必须另外 GET 验证。

## 原厂效果与侧灯

`keyboard.json:35-81` 列出该 NuPhy 分支编译时启用的 RGB Matrix 效果，包括 gradient、breathing、cycle、rainbow、reactive、splash 等；其整数编号由 QMK RGB Matrix effect enum 决定，不能只凭 JSON 名称断言某个原厂固件版本的最终编号。只读 `08 03 02 00` 仅能观察当前 mode，不能验证整个效果枚举；准备写入的 steady 等目标 mode 必须匹配固件源码并受控验证。

侧灯在 `side.c:23-69` 是独立的 12 LED、模式、亮度、速度、颜色状态；`side.c:109-145`、`:147-207` 的控制函数写入 `kb_config` 并调用 `eeconfig_update_kb_datablock`。这与 VIA RGB Matrix 主区的 `*_noeeprom` 路径不同。当前没有证据表明 `08/07` 的 RGB Matrix channel 能读取或修改侧灯；不能用空侧灯数组冒充隔离保护证据。

## Keyphore 实现

新增 [VIAProtocol](../../app/Sources/KeyphoreCore/VIAProtocol.swift) 和 [VIALightingAdapter](../../app/Sources/KeyphoreCore/VIALightingAdapter.swift)，由现有 NuPhyIOAdapter 统一选择设备和持有 HID。V2 只接受精确身份、32 字节 descriptor 与协议 12，排除 `19f5:3247` dongle。新增目标选择后，V2/V3 可同时连接，显式指定一个型号控制；自动模式下多设备、或同一所选型号连接多把时仍拒绝歧义。V3 保留原 64/65 字节接收处理。V2 支持主背光常亮、呼吸、自定义颜色、亮度、呼吸速度和关灯，不支持侧灯、多色及方向。界面限制可选项，已有 V3 profile 不被静默改写。

接入点为 [runtime/Sources/main.swift](../../runtime/Sources/main.swift) 创建的灯光 adapter，复用 [SignalRuntime.swift](../../app/Sources/KeyphoreCore/SignalRuntime.swift) 的 apply/displays/recovery 接口和 [SignalPreview.swift](../../app/Sources/KeyphoreCore/SignalPreview.swift) 的预览调度。当前基线使用键盘原生呼吸效果，不按帧反复调节亮度。无任务时沿用用户配置的 idle（默认关灯）；退出时关闭已接管主背光。初次从 disabled 启用须先 enable 才能设置 HSV，无法保证完全没有旧色瞬闪。

常亮 mode 1、呼吸 mode 4 的编号由该快照的动画编译顺序和 keyboard.json 核实；呼吸速度五档映射 51/102/153/204/255。引用源码未定义 `FASTLED_SCALE8_FIXED`，其亮度 SET 换算为 `(request * 128) >> 8`，GET 再乘 255 除 128。该公式不能证明用户所装固件的最大亮度也是 128；后续 30% 实测发现严格使用此预测会误判失败，见文末。每次设置后独立 GET 验证；设置回显不能代替回读。预览记录区分 `.readback` 与 `.untouchedProtocolChannel`，V2 侧灯只声明未向其协议通道发指令。

能力检查先于新灯区 ownership 登记；离线仍继续清理过期/中断任务，并按请求 ID 结束旧预览，避免覆盖新请求。目标切换现在由 Companion 清偿原键盘实际接管的灯区后完成；若旧 V3 侧灯 ownership 尚未清偿，V2 不会假装将它关闭，需重连原 V3 完成清理。

开发版 App 启动和物理灯光验收须先完成仓库规定的 `build-open` 流程，并保持单一 HID 所有权。独立只读诊断不启动开发版 App、不宣称灯光验收，可在正常退出已安装 App、确认 Companion 退出并取得同一 `companion.lock` 后，精确查询 V2 的 `01` 与四项 `08 03 xx`。先前把 `build-open` 扩展为所有只读诊断的前置条件过于宽泛，已按 AGENTS 的实际适用范围更正。正式验收再验证 `07` 写入、独立 GET 回读、人工目视、signal-off、重连与睡眠唤醒；即使未发送 `09`，也不能把持久化行为写成无条件保证。

## 2026-10-15 真机只读结果

完整请求、响应和诊断程序 SHA-256 已保存为 [实机记录](evidence/air75-v2-read-only-2026-10-15.json)。[原生诊断脚本](../../tools/keyphore-via-inspect.swift) 已编译，`--self-test` 通过；自测不打开 HID。现场程序只发送以下五条查询，所有响应长度、命令和字段校验均通过，退出码为 0。

| 查询 | 响应值 |
| --- | --- |
| 协议版本 `01` | `00 0c`，整数版本 12 |
| 亮度 `08 03 01` | `ff`，255/255 |
| 当前灯效 `08 03 02` | `04`，仅记录编号，不推断名称 |
| 速度 `08 03 03` | `8b`，139 |
| 颜色 `08 03 04` | Hue `7a`/122，Saturation `fe`/254 |

设备为 `NuPhy Air75 V2`，USB `19f5:3246`，usage `FF60:0061`；实机 descriptor 确认无 report ID，输入/输出均为 32 字节。USB VersionNumber 为十进制 288（`0x0120`），仅记录设备描述字段，不据此认定固件发行版本。V3 与其接收器同时在线，诊断程序只匹配唯一 V2 配置接口，未向 V3 发送报文。

查询前通过 App 正常退出 Keyphore 0.3.0 build 21，确认 App/Companion 退出后再持有同一进程锁；查询完成后重新打开原 `/Applications/Keyphore.app`。未发送 `07`/`09`，未改 V2 灯态、键位或固件，未安装新 App 或依赖。

## 2026-10-15 实现验证

[实现验证摘要](evidence/air75-v2-implementation-2026-10-15.json) 记录命令日志与 SHA-256：最终核心测试 222 项通过；完整 App 测试 93 项通过；文案更新后的 8 项布局测试通过；开发构建流程 6 项隔离测试通过。独立审查发现的“硬件验证失败跳过任务清理和预览失败处理”已先用失败测试复现，再修复并通过全量回归。

已通过 [AGENTS.md](../../AGENTS.md) 规定的 `tools/keyphore-development-app build-open` 构建、验签并安装到 `~/Applications/Keyphore.app`。脚本改用原生临时目录，显式支持本机已有 Apple Development 身份；仍严格验证 App/helper/Companion 同一身份与团队，正常退出旧 App 并拒绝残留 Companion。没有改变凭证、系统权限或发行签名设置，原 `/Applications/Keyphore.app` 保留。

[实机混接测试](evidence/air75-v2-mixed-device-2026-10-15.json)：当前 V2 与 V3 同时有线连接，签名 helper 的 `companion --preview-air75-v2` 在选择阶段返回 `ambiguous`，没有进入任何灯光步骤。原 profile 字节未变，开发版 App 和 Companion 已通过正常退出停止。原生 UI 的 CUA 读取超时，未把自动化 App 测试算作现场目视确认。

## V2 单设备实机写入与回读

用户拔下 V3 后重新枚举，只剩有线 `NuPhy Air75 V2`。正常退出重新启动过的原安装版，确认 Companion 释放，再由稳定安装的签名 helper 执行 `companion --preview-air75-v2`。[完整记录](evidence/air75-v2-lighting-2026-10-15.json) 的退出码为 0，stderr 为空，主区状态按 `[brightness, effect, speed, hue, saturation]` 记录：

| 步骤 | 独立 GET 回读 |
| --- | --- |
| 蓝色呼吸 | `[253, 4, 153, 170, 255]` |
| 橙色呼吸 | `[253, 4, 153, 22, 255]` |
| 绿色常亮 | `[253, 1, 153, 85, 255]` |
| 关灯 | `[253, 0, 153, 85, 255]`；effect 0 表示关闭 |

四步均返回 `protocolReadbackSucceeded=true`。测试通过不发送保存命令的 VIA SET 完成，结束时主背光已关闭，未向侧灯通道发送指令。人工视觉确认已向用户询问，仍等待反馈；不把回读等同于人眼观察。真实运行中拔插重连、睡眠唤醒仍未执行，相关软件恢复测试已通过。

## 当前控制键盘选择

设备页新增「当前控制的键盘」，与仅用于示意图的型号目录分开。App 读取 Companion 发布的已连接型号和数量，写入本机选择偏好；App 不打开 HID。当时自动模式仅接受唯一目标，显式选择只匹配该型号的唯一控制接口，掉线不回退到其他型号；2026-10-18 的自动接管调整见末节。

[KeyboardSelection.swift](../../app/Sources/KeyphoreCore/KeyboardSelection.swift) 定义偏好、库存、实际目标和切换结果。ownership 按 `{model,zones}` 持久化；旧目标关闭与回读成功、旧 journal 清空落盘后，才获取新目标。切换失败保留原 owner，退出使用实际 owner，而不是刚提交的请求。切换中再次选择会在旧目标清理后重新读取最新请求。

预览记录绑定目标型号，消费时再次匹配实际目标；过时目标的预览不会在别的键盘执行，也不会永久阻塞当前目标。诊断中的历史预览明确列出其目标型号。快照变化即时发布，无变化时最多每秒写一次，超过 3 秒的数据不会用于启用实体预览。

[验证摘要](evidence/keyboard-selection-implementation-2026-10-15.json)：243 项核心测试、98 项 App 测试通过，签名开发版已安装。[双设备现场记录](evidence/keyboard-selection-live-2026-10-15.json)：V2/V3 同时连接，显式 V3 与随后 V2 的选择均进入 applied；V3 协议健康、接管主背光与侧灯；转到 V2 后旧灯区已清理，V2 保留目标但拒绝原有 V3 双灯区配置，未静默改写 profile。测试后恢复原「自动」选择，profile 字节未变。

上述现场切换通过正在运行的签名 Companion 所消费的偏好文件接口验证；原生 Picker 的交互由 App 自动测试覆盖，当时 CUA 无法稳定聚焦菜单栏窗口，因此没有声称现场点击验证通过。当时共用 profile 导致 V2 仍需手动调整，后续修复见下节。

## 型号独立配置与 V2 条形灯提示

用户报告切换 V2 后无灯效、条形灯入口消失。现场快照确认目标已是 Air75 V2，但共用 profile 仍选择 `both`，且执行/完成分别使用 V3 的 ripple/diagonal。V2 能力校验在登记灯区和写入前拒绝此配置；这不是设备选择失败。

[KeyboardProfileStore](../../app/Sources/KeyphoreCore/KeyboardProfileStore.swift) 现在为 Air65 V3、Air75 V3、Air75 V2 分别保存文件。Companion 清偿旧目标后才读取新实际目标的配置，不再读取全局 `profile.json`。UI 把显示的配置和型号一起更新，保存时绑定该型号并检查最新选择快照；切换中的旧回调不能覆盖新型号的文件。协议异常不会反过来禁止用户修正配置，损坏的配置以明确目标及默认编辑基线呈现并保留错误提示。

V2 的条形灯入口显示为不可用，并说明仍由键盘自身控制；不新增未经证实的侧灯命令。V2 示意图的辅助功能标签已更正。再次打开 App 会直接显示设置窗口。

本机旧 App 正常退出、ownership 清空后，精确备份用户最新配置；V3 文件逐字节保留，V2 副本保留颜色、亮度、显示开关和完成时长，仅将灯区改为背光、执行 ripple 改为呼吸、完成 diagonal 改为常亮。产品没有旧全局文件回退或自动转换逻辑。[本轮记录](evidence/keyboard-model-profiles-2026-10-15.json) 包含原始失败快照、配置哈希、备份位置及转换差异。

第一轮安装后的现场 UI 验证还发现：键盘协议已正常，但物理预览仍受 Agent 整体 `menuState == ready` 限制，点击状态标签只切换页面，不会创建预览。已用失败测试复现并改为统一的物理预览条件：实际目标及健康快照新鲜、一致，且不处于启动、配置、移除等操作中；开始预览前重新读取状态。设备页按钮和灯效页使用相同条件，不改变 Hook 的授权或启用状态。

最终回归结果：248 项 Core 测试、102 项 App 测试、11 项开发安装流程测试通过。覆盖不同型号文件隔离、旧页面回调、过期快照、损坏配置修复、按实际 owner 取完成时长、退出清理、设置窗口重新打开，以及 Agent 未就绪时仍可测试健康键盘。

最终签名版现场验证：从灯效页点击「注意」产生绑定 Air75 V2 的预览并完成回读；设备页三段测试完成 execution、attention、completion，`protocolReadbackSucceeded=true`。V2 健康状态为 connected/true，ownership 仅主背光。已检查实际页面截图，条形灯限制可见；关闭设置后从访达双击 App 可再次打开设置。人工目视确认尚未收到，不把协议回读等同于人眼结果。验收后通过 App 正常退出，确认 App/Companion 停止、ownership 清空，再重新打开供用户测试。V3 与 V2 的配置文件在现场测试期间均未改变。

## 闪烁对照与编辑后的预览恢复

后续用户报告「一闪一闪，还无法控制」。当前执行配置是呼吸效果；在 App 中仅将执行切为静态后，用户明确回复「稳定了」。因此保留执行静态，未据此修改 USB 驱动或把自然呼吸当作重复写入故障。此确认仅覆盖静态灯效稳定性，不追溯为此前三段测试的完整目视通过。

另一个问题通过真实 UI 复现：完成状态预览六秒结束后，将完成颜色由绿色改成橙色，文件已保存，但 `signal-preview.json` 仍是原请求的 completed，当前任务 execution 继续显示。原因是 `updateAppearance` 只会为 idle 的编辑重新创建预览。现在所有状态的成功编辑都重启对应的六秒预览，CodexSignal 和重置颜色入口使用同一路径；保存失败或目标已变化时不生成预览。真实 AppState 与 Companion 的回归覆盖「预览到期→编辑→新目标绑定请求→临时显示编辑结果→恢复任务灯效」。[本轮证据](evidence/air75-v2-edit-preview-2026-10-15.json) 分别记录静态目视确认与编辑失效的现场复现。

## 2026-10-16：定义文件核对与低亮度失败根因

用户提供 `nuphy-air75-v2-via3.zip`，内含同名键盘定义 JSON。USB `19f5:3246`、主背光 channel 3、brightness/effect/speed/color 的 value ID 1/2/3/4，以及 static 1、breathing 4 均与驱动一致。41 个效果条目是 UI 定义，并不代表每项已在本驱动验证；侧灯仅列出 custom keycodes，没有侧灯 USB 菜单。定义不是当前设置导出，也没有标识已安装的固件版本。[对照记录](evidence/air75-v2-via-definition-2026-10-16.json) 保存原文件哈希和映射。

官方 VIA 客户端的 [menusSlice](https://github.com/the-via/app/blob/935106a990af39bdd1ade881c02366eac486240d/src/store/menusSlice.ts#L99-L127) 会在 SET 后排队 SAVE；引用的 NuPhy QMK 源码中 SAVE 仅负责 EEPROM 持久化，渲染读取 SET 已更新的 RAM，未发现渲染依赖 SAVE 的证据，因此本修复没有增加保存命令。

重新检查用户失败时的记录，发现 idle 预览实际为 failed，参数为绿色 `#00FFAE`、呼吸、30% 亮度、速度 4；随后实时执行信号恢复成功，把整体 health 又写成 true。此前只看后来的健康状态，遗漏了这次预览失败。

在 App/Companion 已正常退出、quit gate 有效、ownership 为空时，诊断程序持有同一 Companion 锁并绑定唯一 V2，写前登记主背光 ownership，结束经关灯回读后清账。[修复前真实报文](evidence/air75-v2-brightness-before-2026-10-16.json)：100% 回读 `[253,4,255,114,255]` 成功；30% 请求亮度 77，设备回读 `[76,4,255,114,255]`，驱动按源码最大亮度 128 推算为 75，错误抛出 readbackMismatch。颜色、效果和速度都一致。`255→253` 本身不能证明设备内部最大亮度是 128。

驱动现按 0…255 归一化请求值核对亮度，最多允许 3/255（一个经过整数舍入的 UI 百分比步长）的误差；不再预测未知固件的精确内部上限。effect、hue、saturation、breathing speed 及 off 仍严格比较。使用字面实机回包的回归先失败再通过，同时验证容差边界外拒绝、其他字段偏差拒绝及重复健康检查不再写灯。

251 项 Core 测试（含 23 项 VIA 测试）通过，App 编译通过。[修复后同一实机对照](evidence/air75-v2-brightness-after-2026-10-16.json) 中 100% 和 30% 都成功，30% 的实际回读仍是 76；结束 effect 0 回读通过、ownership 清空。两个对照仅发送 `01`、`07`、`08`，未发送 SAVE、键位或侧灯指令。

最新签名版 UI 验收进一步覆盖：原绿色 idle 30% 预览完成；预览结束后改橙色生成新请求并完整通过；改为静态再次生成新请求并完整通过；最后恢复用户原绿色、呼吸、30%、速度 4，配置与测试前完全相同，最终预览也完成。验收后通过 App 正常关灯退出并确认 ownership 清空。此结果证明本次低亮度误判和预览撤销路径已修复。用户随后明确回复「可以了」，确认最新安装版的 V2 主背光颜色与灯效控制可用；该验收不包含尚未支持的 V2 侧灯 USB 控制。

## VIA 全部效果

按用户后续要求，V2 已扩展为定义文件的完整 0…40 列表：关闭及 40 种原生效果。`NativeLightingEffect.viaCatalog` 独立映射 VIA 编号，已有静态、呼吸配置保留；其余效果使用 VIA 专用标识，V3 在打开控制传输前拒绝这些标识。非关闭效果按定义提供颜色、速度参数；颜色的视觉作用取决于原生算法，按键响应类需要物理键盘输入。

界面使用 V2 专属滚动网格、完整本地化标签和英文提示，对全部关闭的参数、示意图和实际受控灯区状态一致处理。V3 的效果目录、网格尺寸和协议编号保持原有行为。仍保留主区限定、亮度量化容差、严格 effect/HSV/speed 校验及不发送 SAVE 的约束。

[本轮验证记录](evidence/air75-v2-full-effects-2026-10-16.json)：259 项 Core 测试和 106 项 App 测试通过，包含原样 VIA JSON fixture、全部编号映射、独立回读、重复应用不写入、低亮度、关闭和 V3 边界。签名版已通过 build-open 安装并打开设置，现场可见扩展列表及英文提示，用户各型号 profile 字节未变。41 模式的实机探针已编译，但当时 USB 现场只有 Air75 V3 和 V3 接收器，没有 V2；因此全 41 项物理回读暂未执行，不能把软件测试算作实体模式验收。当时保留了 V2 的 ownership；随后用户显式切换到 V3 暴露的阻塞及处理方式见下节。V2 独占探针仍要求设备在线、初始灯效关闭和空 ownership。

## 显式切换离线旧键盘

用户选择 V3 后，UI 仍显示 V2 的侧灯限制。现场请求已是 V3，但 Companion 快照为 `activeModel=V2`、`desiredModel=V3`、`blocked/oldTargetUnavailable`；旧 V2 已不在 USB 库存中，关灯前置条件使真实控制目标一直停在 V2。UI 此时没有缓存错误，而是跟随被阻塞的实际目标。

此轮修复仅在用户显式选择另一型号、且本轮成功发现的库存确认旧型号 count 为 0 时，结束对旧离线控制接口的管理。该释放不发送旧设备关灯命令，也不宣称旧灯已关闭；原 profile 保留。仍先原子清空旧控制记录，再重新读取最新选择、绑定新目标并加载其独立配置。自动模式、退出、旧设备仍在或同型号歧义、发现失败、关灯或记录写入失败均保留原有保护。新目标缺席仍是 blocked，不能误标 applied。

[本轮记录](evidence/keyboard-disconnected-switch-2026-10-16.json) 保存原始故障快照与配置哈希。265 项 Core 测试通过，App 编译通过；覆盖离线 V2→显式 V3、V3 双灯区 profile、旧目标不再收到命令、两个 profile 保留、V2 重连不抢回目标，以及在线旧设备失败、自动模式、退出和切换期间请求变化。

## 自动接管与菜单快捷选择（2026-10-18）

用户反馈替换 V2/V3 后不能自动接管，菜单也没有当前控制键盘的选择入口。旧实现有两个独立阻塞：保存的手选型号断开后仍固定匹配该型号；Auto 切换仍等待离线旧目标的关灯回读。

现在成功发现非空库存后，若手选型号已不存在，通过同一文件锁内的比较后清除回到 Auto，并重新读取最新偏好，避免覆盖同时提交的新选择。唯一在线型号自动接管；多把在线时保留仍有效的手选，否则等待选择。同型号多把仍拒绝歧义。空库存或发现失败不清除偏好。新库存确认旧控制接口离线时，Auto 也可释放它；此操作不向离线设备发送关灯命令，不宣称灯已关闭，仍需先清空旧 ownership 才绑定新目标。在线旧设备关灯验证、退出和记录写入失败的保护保留。

菜单栏左键弹窗与右键菜单均增加当前控制键盘的入口，与设置页复用选择状态和动作校验。App 重新读取偏好以显示 Companion 的自动重选结果；点击时再次校验新鲜库存，拒绝掉线型号、同型号多把和过期快照。切换不依赖 Agent 配置已完成，各型号 profile 仍独立保存。

[本轮证据](evidence/keyboard-auto-menu-2026-10-18.json) 区分自动测试、签名安装和现场硬件验证。

271 项 Core、114 项 App 全量测试通过，最后新增文案的 5 项本地化检查通过。真实 NSMenu 动作、双设备选项和过期点击拒绝由自动测试覆盖；[双设备面板渲染](evidence/keyboard-auto-menu-multiple-2026-10-18.png) 已检查，旧的拔掉其他型号提示已移除。签名版已安装至固定 App 路径。现场只有 V2：通过生产选择锁写入已缺席 V3 的偏好后，后台恢复 Auto 并保持 V2 applied；设备页同步显示正确目标，实际点击 Picker 恢复原 V2 选择成功，两份 profile 字节未变。验收后正常退出，再打开最终版供用户测试。没有把这次单设备现场检查算作 V2/V3 双实体热插拔验收。

签名版安装后的真实快照已为 desired/active 都是 Air75 V3、phase applied、protocolHealthy true，ownership 为 V3 背光与条形灯。安装前后两份 profile 哈希一致；随后用户在界面自行调整了 V3 空闲亮度。现场 UI 已显示 Air75 V3 示意图和可操作的「条形灯、由 Keyphore 控制」，不再出现 V2 条形灯禁用提示。此时没有向离线 V2 发送或宣称关灯确认，当前 App 保持打开供用户使用。
