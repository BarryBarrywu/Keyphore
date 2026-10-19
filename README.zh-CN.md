<p align="center"><a href="./README.md">English</a> · <strong>简体中文</strong></p>

<p align="center">
  <img src="./assets/readme/hero-zh-CN.svg" width="100%" alt="Keyphore — 用 NuPhy 键盘灯光看见 Codex 任务状态：蓝色执行中，橙色需要回应，绿色已完成，无活动时熄灯。">
</p>

# Keyphore

**用键盘灯光，看见 Codex 正在执行、需要回应，还是已经完成。**

Keyphore（读作“key-for”）是一款原生 macOS 菜单栏应用，把 Codex 的任务事件转换为 NuPhy 键盘背光。你可以在 App 中设置灯光信号，然后继续手头的工作，让键盘显示当前任务状态。

[开始使用](#开始使用) · [兼容性](#兼容性) · [从源码构建](#从源码构建) · [GPL v3 许可](#许可证)

<p align="center">
  <img src="./assets/readme/app-zh-CN.png" width="460" alt="Keyphore App 显示 Codex 任务状态与已连接的 NuPhy Air65 V3。">
</p>

## 一眼看懂三种信号

| 默认灯光 | 含义 |
| --- | --- |
| **蓝色 · 执行中** | Codex 任务或子代理正在执行。 |
| **橙色 · 需要回应** | Codex 需要你审批或输入。 |
| **绿色 · 已完成** | 一轮任务结束，默认显示五秒。 |
| **熄灯或空闲灯效** | 当前没有需要显示的任务信号，默认熄灯。 |

多个任务共用一个键盘信号，显示优先级为：**需要回应 → 执行中 → 已完成 → 空闲**。某一轮任务完成，不会盖过其他仍在执行或等待回应的任务。关闭某类信号后，会显示下一个符合条件的状态；没有活动信号时，使用你选择的空闲设置。

*上图是信号示意，并非实机灯光照片。实际效果取决于键盘和你的设置。*

## 按你的习惯设置灯光

- **分别调整每种信号。** 自选颜色、1–100% 的亮度、常亮或慢闪，以及是否显示。
- **设置完成提示时长。** 可选 1–60 秒；执行和等待回应信号则跟随任务活动。
- **选择空闲时的灯光。** 在「设置 → 灯效 → 空闲」选择「关闭灯光」或「使用空闲灯效」，并分别设置受控背光和条形灯。退出 Keyphore 时仍会熄灭受控灯光。
- **从菜单栏查看键盘。** 查看当前信号、连接状态和键盘示意图，并直接打开设置，无需常驻 Dock 窗口。
- **在真实键盘上预览。** 点击状态标签可预览六秒，修改颜色或灯效后会重新预览，结束后恢复当前任务信号。设备检查可测试三种任务信号，并确认你实际看到的效果。
- **选择外观和语言。** 支持浅色、深色或跟随系统外观；可选英文、简体中文或跟随系统语言。

## 兼容性

| 项目 | 当前支持范围 |
| --- | --- |
| Mac | Apple Silicon · macOS 13 或更高版本 |
| Codex | 支持 Plugin 和 Hook 的桌面 App 或 CLI |
| 键盘 | **NuPhy Air65 V3 和 Air75 V3**，原厂固件，符合受支持的 USB 设备标识 |
| 连接 | USB 有线连接 · 多种型号可同时连接，一次选择一把控制 |

Air65 V3 的 USB ID 为 `19f5:102b`，Air75 V3 为 `19f5:1028`。当前不支持 ISO/JIS 变体、蓝牙、2.4 GHz 接收器、Intel Mac 和自定义固件。除 Codex 外，可在「设置 → Agent」接入 Claude Code、Pi、OpenCode、Qoder CLI 和 Grok，并分别审查和启用。

**Air75 V2** 驱动（`19f5:3246`、VIA 协议 12）提供用户 VIA 定义中的全部 41 项主背光选项：关闭及 40 种原生效果，包括渐变、循环、彩虹、雨滴、热力图、按键响应和涟漪等。非关闭选项提供 VIA 的颜色与速度参数；具体视觉表现由原生效果决定，按键响应类需要实际敲键。[验证记录](./docs/research/air75-v2-via.md) 分别记录软件检查、设备回读和人工目视结果。侧灯保持键盘自身控制，App 中的条形灯控件会标明暂不可用，驱动不发送 VIA 保存命令。每款受支持型号分别保存灯效，切换到 V2 不会沿用或覆盖 V3 的设置。

在菜单栏弹窗、右键菜单或 **设置 → 设备** 的「当前控制的键盘」中选择已连接型号。「自动」会接管唯一在线的受支持有线键盘。手动选择的型号在线时会保留选择；该型号断开且检测到其他键盘后，会恢复自动模式。多把同时在线且没有有效手动选择时，从菜单指定一把。旧键盘仍在线时，切换会先关闭其受控灯区并验证；已断开的旧目标会停止由 Keyphore 管理，但不代表它的灯光已关闭。同型号连接多把仍视为歧义。「键盘型号与外观」目录只用于切换示意图。

App 能识别并展示更多 NuPhy 型号。**能够识别，不代表支持灯光控制**：当前实验性灯光控制的允许列表为空。[内置型号目录](./app/Sources/KeyphoreCore/Resources/candidate-keyboards.json) 记录了可识别的设备标识和布局。

## 开始使用

本仓库包含 App 源码，目前尚未提供公开安装包的下载链接。开发使用请参考下方的[源码构建说明](#从源码构建)。

获得 Keyphore App 构建后：

1. **打开 Keyphore，完成设置引导。** App 会为当前 macOS 用户管理 Codex 插件和后台组件。
2. **审阅并授权 Hook。** 设置引导会在启用前展示八种任务事件的 Hook 定义。如 App 提示需要 macOS 权限，请按提示操作。
3. **通过 USB 连接一把受支持键盘。** 运行信号预览，确认实际灯光效果。
4. **启动一个新的 Codex 任务。** 之后可随时从 Keyphore 设置中调整三种信号。

关闭设置窗口后，Keyphore 仍会运行。**退出 Keyphore** 会停止后台组件、禁用它的 Hook，并熄灭信号灯。卸载时，请先使用 App 内的移除功能，再将 App 移到废纸篓。

## 不想使用 App？也可以构建 Rust 插件

开发者可以从 [`src/`](./src) 和 [`Cargo.toml`](./Cargo.toml) 构建独立的 Rust Codex 插件，不使用 macOS App。它通过后台 Companion 控制灯光，没有菜单栏界面。Swift App 是独立的原生实现，并不是这个 Rust 二进制的界面包装。

**Rust 方案的功能范围更小：** Apple Silicon Mac、原厂固件 NuPhy Air65 V3、USB 有线连接，以及固定的蓝／橙／绿信号和五秒完成提示。不要将 App 的 Air75 V3 支持、信号设置、预览和自动更新能力套用到 Rust 插件上。不使用 App，也不意味着支持 Windows 或 Linux。

准备支持 edition 2024 的 Rust 工具链、Xcode Command Line Tools，以及支持 Plugin／Hook 的 Codex，然后在仓库根目录运行以下命令。它们会用本地构建替换随附的 Rust 二进制，进行本地使用的 ad-hoc 签名，再从当前检出目录安装插件：

```bash
cargo build --release --target-dir /private/tmp/codex-builds/keyphore-rust
install -m 755 /private/tmp/codex-builds/keyphore-rust/release/keyphore plugin/bin/keyphore
codesign --force --sign - --identifier keyphore plugin/bin/keyphore
codex plugin marketplace add .
codex plugin add keyphore@keyphore
```

启动一个新的 Codex 任务并输入：

```text
使用 $setup-keyphore 安装并验证我的 NuPhy Air65 V3 状态灯。
```

[随附的设置 Skill](./plugin/skills/setup-keyphore/SKILL.md) 负责 Companion 安装、八个 Hook 的显式审阅与授权，以及诊断、更新和移除。授权后按提示重新加载 Codex；仅编译可执行文件不会完成集成配置。

**同一把键盘只选择一套运行时。** 不要同时运行 Rust Companion 和 Swift App。切换前先使用当前安装方案的移除功能；Companion 持有 HID 时，不要手动运行灯光测试。

Rust 测试也用于对照 Swift 实现的行为。[`tools/keyphore-rewrite-acceptance`](./tools/keyphore-rewrite-acceptance) 会比较两者的行为并审计 App 构建产物；自动化一致性测试不能替代实际灯光确认。

## 数据留在本机

Keyphore 无需产品账户，不提供云同步，也不会自动上传遥测或诊断。Hook 处理程序仅保留允许范围内的事件和任务标识字段，不保留提示词、对话正文或工具内容。诊断报告由你审阅并导出到本地。

```text
Codex 任务事件 → 本地任务状态 → Companion → 键盘背光
```

Companion 是唯一会打开键盘 HID 连接的组件。它汇总活动任务信号，应用你的设置，并通过协议回读验证灯光写入。未选择由 Keyphore 控制的灯光区域保留键盘自身设置。空闲时，Keyphore 按你的选择熄灯或显示独立的空闲灯效，不会恢复此前的键盘配置。

## 从源码构建

App 及其 Hook 运行时和 Companion 均使用 **Swift 6** 编写。可独立构建的 Rust 插件也作为行为对照，但不会嵌入 App。

核心测试需要 Swift 6 工具链：

```bash
swift test --package-path app --scratch-path /private/tmp/codex-builds/keyphore-core
```

在 Apple Silicon Mac 上使用 Xcode 构建 App：

```bash
xcodebuild -project Keyphore.xcodeproj -scheme Keyphore \
  -configuration Debug \
  -derivedDataPath /private/tmp/codex-builds/keyphore-app \
  build
```

维护者打开开发版本或进行真实键盘测试时，请使用仓库提供的固定安装流程：

```bash
tools/keyphore-development-app build-open
```

该流程使用 `/private/tmp/codex-builds` 下的临时构建目录，并要求有效签名。默认使用维护者的 Developer ID；本地开发可显式设置 `KEYPHORE_DEVELOPMENT_TEAM` 和 `KEYPHORE_SIGNING_IDENTITY`，指定匹配的团队及完整 Apple Development 证书名称。App、辅助程序和 Companion 均须通过相同身份的严格验签。流程会正常退出正在运行的 App，拒绝残留 Companion，再安装到 `~/Applications/Keyphore.app`。不要直接从 DerivedData 启动开发版本。硬件测试结束后，请通过 App 退出，让它完成熄灯并停止 Companion。

<details>
<summary>代码目录与验证范围</summary>

| 路径 | 用途 |
| --- | --- |
| [`app/Sources/KeyphoreApp`](./app/Sources/KeyphoreApp) | 菜单栏、设置、首次设置引导、诊断和更新 |
| [`app/Sources/KeyphoreCore`](./app/Sources/KeyphoreCore) | 任务状态、信号配置、生命周期和 USB 协议 |
| [`runtime/Sources`](./runtime/Sources) | Swift Hook 处理程序及 Companion 入口 |
| [`app/Tests`](./app/Tests) | 核心模块和 App 的行为测试 |
| [`src`](./src) | 独立 Rust 插件及行为对照实现 |

[`tools/keyphore-rewrite-acceptance`](./tools/keyphore-rewrite-acceptance) 用于收集软件验证和行为一致性证据。自动化测试与协议回读不能替代对实际灯光的目视确认。[最初的 Air65 V3 验收记录](./docs/acceptance/issue-9.md) 描述了当时的硬件检查，不是 Air75 V3 的验收报告。

</details>

## 更新

App 使用 [`updates/appcast.xml`](./updates/appcast.xml) 中的 Sparkle 签名更新列表。各版本安装包放在 GitHub Releases，中英文更新说明保存在 [`updates/notes`](./updates/notes)。签名、公证的安装包准备好之前，初始列表不包含任何版本。在线更新需要仓库与 Release 附件均可公开访问。

维护者：`tools/keyphore-release build` 从 [`release/Updates.xcconfig`](./release/Updates.xcconfig) 读取更新地址和公钥，也可分别通过 `--feed-url` 和 `--download-url` 覆盖。`stage` 接收 `--notes-en` 和 `--notes-zh-hans`，签名更新列表，并生成用于仓库的 `public/updates` 和用于 GitHub Releases 的 `public/release-assets`，后者包含对应源码。请从已提交的源码构建，先发布版本附件，再更新列表；保留旧附件，每次发布递增版本号和构建号。签名使用钥匙串中的 `com.barrywu.keyphore` 条目，私钥不得提交到仓库。

## 许可证

Keyphore 的自有代码，包括 Swift App、Companion 和随附插件，采用 [GNU 通用公共许可证第 3 版，仅限此版本](./LICENSE)（`GPL-3.0-only`）。分发许可证覆盖的二进制程序时，需要按许可条款提供对应源码。

第三方组件保留原有许可证与署名：[NuPhyIO 协议声明](./LICENSES/NUPHYIO-NOTICE.txt) · [Sparkle 及其随附依赖](./app/Sources/KeyphoreCore/Resources/SPARKLE-NOTICE.txt)。
