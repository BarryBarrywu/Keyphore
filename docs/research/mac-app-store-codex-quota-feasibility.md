# Codex 额度与硬件扩展 Mac App Store 可行性

调研日期：2026-08-30。本文只采用 Apple 官方文档与 App Review Guidelines、OpenAI Codex 官方仓库、Mac App Store 官方产品页，以及相关产品自己的官网或仓库。App Store 上已有产品只能证明某种产品形态曾获准上架，不能替代本项目自己的审核；所有“审核不确定”项都需要以 Sandbox 原型和实际 App Review 为准。

## 结论先行

1. **基础 Mac 菜单栏额度 App 可以把 Mac App Store 作为主要分发渠道。** 菜单栏、无 Dock 图标、详细窗口、屏幕边缘 HUD、网络雷达和系统通知均有公开 API 或正式 entitlement。Mac App Store 里也已经存在多款明确支持 Codex 的额度工具，包括展示 Codex reset credits 的产品。
2. **主要风险不是 UI，而是“官方额度”的数据来源。** Mac App Store 强制 App Sandbox。Sandbox App 不能直接执行用户已经安装在 Homebrew、ChatGPT/Codex App 或其他任意目录中的 `codex`，也不能直接复用 Codex 所属 Keychain access group。让用户选择 `~/.codex` 可以读取日志，但日志估算不能天然替代 `account/rateLimits/read` 的权威百分比、重置时间和 reset-credit inventory。
3. **最值得先验证的 App Store 数据路径，是把固定版本的官方 `codex app-server` 作为签名 helper 内嵌进 App。** Apple 明确支持在 Sandbox App 内嵌命令行 helper；OpenAI 官方 app-server 支持在 stdio 上进行 ChatGPT 登录并读取 `account/read`、`account/rateLimits/read` 和 `account/usage/read`。helper 必须继承 Sandbox、随 App 一起审核和更新，且使用 App 自己的容器与凭据，因此用户大概率需要在本 App 内单独登录一次 OpenAI。这条路径技术上合理，但在真正做过 Sandbox 登录与 App Review 之前仍属于**审核不确定**。
4. **现有 NuPhy/ZECTRIX Codex 插件不能由 App Store App 直接下载和安装。** 当前插件包含 executable、Hook、Codex 插件目录写入和 LaunchAgent；Apple 禁止 Mac App Store App 把新增代码或资源安装到共享位置，也禁止下载并执行会新增或改变功能的代码。App Review Guidelines 虽允许 Mac App Store App “承载”由 App Store 之外机制启用的 plug-in，但这不等于允许主 App 自行下载、写入和启动任意插件二进制。
5. **推荐“一个 App Store 主 App + 用户独立安装的 Developer ID Hardware Bridge”，而不是两套完整 App。** 主 App 独立提供官方额度、重置时间、reset credits、第三方雷达、菜单栏、详情页、通知和可选边缘 HUD；外部 Bridge 免费、签名、公证，只负责 Codex Hook、NuPhy HID、ZECTRIX/Kindle adapter，并通过最小化的本机 IPC 向主 App提供归一化状态。主 App 不负责下载或安装 Bridge，且没有 Bridge 时仍完整可用。

## 判断标签

- **规则明确允许**：Apple 有公开 API、entitlement 或明确指南支持。
- **规则明确禁止**：App Review Guidelines 或 App Sandbox 文档直接排除。
- **技术可行、审核不确定**：有公开技术路径，但用途、第三方服务授权、权限组合或审核呈现仍可能被拒。

## 能力逐项判断

| 能力 | 判断 | 结论 |
| --- | --- | --- |
| 基础菜单栏额度 App | 规则明确允许 | `MenuBarExtra` 是官方菜单栏 Scene，`LSUIElement=true` 可隐藏 Dock 与应用切换器图标。[Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra) |
| 启动用户本机 `codex app-server --stdio` | 规则明确禁止该直接路径 | Sandbox App 不能运行 App bundle、自己容器或 App Group 之外的程序；用户选择文件的 entitlement 也不授予执行外部程序的能力。[访问 Sandbox 外文件](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) |
| 内嵌 `codex app-server` helper | 技术可行、审核不确定 | Apple 提供正式的 embedded command-line helper 路径；helper 必须签名并继承宿主 Sandbox，不能在发布后另行下载替换。[内嵌 helper](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)；[Foundation `Process`](https://developer.apple.com/documentation/foundation/process) |
| 读取已有 Codex Keychain | 规则明确禁止跨 access group | Keychain sharing 限于同一开发团队配置的 access group；本 App 不能加入 OpenAI 的 group。应把本 App 自己的登录凭据写入自己的 Keychain/container。[Keychain sharing](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) |
| 读取 `~/.codex` 日志 | 规则明确允许用户授权后的只读访问 | 必须通过 `NSOpenPanel`/文件导入器让用户选择目录，并保存 security-scoped bookmark；不能静默扫整个 home。[Sandbox 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) |
| 第三方 reset radar | 规则明确允许 | 开启 outgoing network client entitlement 后可访问 HTTPS API；必须在隐私政策与 UI 中说明数据源，并始终标记为第三方预测。[配置 App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox) |
| 菜单栏、无 Dock 图标 | 规则明确允许 | `MenuBarExtra` 文档明确支持纯菜单栏 utility，并说明以 `LSUIElement` 隐藏 Dock/应用切换器图标。[Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra) |
| 屏幕边缘 NSPanel/HUD | 规则明确允许 API，审核呈现不确定 | `NSPanel`、`nonactivatingPanel`、`floating` 和点击穿透均是公开 API。应默认关闭、可立即退出、不伪装系统 UI、不遮挡关键内容，并使用普通 floating level 而非保留给系统的高 window level。[Apple `NSPanel`](https://developer.apple.com/documentation/appkit/nspanel)；[`nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)；[`isFloatingPanel`](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel) |
| 本地与雷达通知 | 规则明确允许 | 使用 `UNUserNotificationCenter`，在有上下文时请求用户授权；用户可拒绝或随时关闭。[通知授权](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications) |
| bundle 内登录项/LaunchAgent | 规则明确允许 | `SMAppService` 可注册位于 App bundle 内的 Login Item 或 LaunchAgent，并受用户批准与系统设置控制。[Apple `SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice) |
| App 写入传统 `~/Library/LaunchAgents` | 不应采用 | Mac App Store App 必须自包含，不能把代码或资源安装到共享位置；应使用 bundle 内 helper + `SMAppService`。[App Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/) |
| App 下载/安装 Codex plugin、Hook 或 adapter binary | 规则明确禁止该直接路径 | 2.4.5 和 2.5.2 禁止下载、安装或执行会新增/改变功能的代码，也禁止第三方 installer 和共享位置安装。[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) |
| NuPhy raw USB HID | 技术路径明确，需实机 Sandbox 原型 | `com.apple.security.device.usb` 明确允许 Sandbox App 使用 USB device access API，旧版 Apple entitlement 指南还明确包括 HID devices。但具体 Air65 V3 的 feature report、exclusive open、睡眠恢复需实测。[USB entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb) |
| ZECTRIX 网络 adapter | 规则明确允许做成内置功能 | 它只需网络访问、自己的 API Key 和图像上传，均可留在 App Sandbox/Keychain 内。若坚持外部插件形态，则由外部 Bridge 承担。[codex-zectrix-dashboard](https://github.com/BarryBarrywu/codex-zectrix-dashboard) |
| Kindle adapter | 取决于未来 transport | 走官方网络 API 或用户选择文件通常可行；若需要安装脚本、驱动、Hook 或外部 executable，则应归入外部 Bridge，不应由商店 App 安装。

## 一、基础额度 App 是否能上架

答案是**能，而且已有直接先例**。基础形态本身符合 App Store：

- Apple 正式提供 `MenuBarExtra`，并明确描述纯菜单栏 utility 与无 Dock 图标配置。
- App Sandbox 提供 outgoing network、USB、文件选择、App Group 等 entitlement。
- `NSPanel` 是公开 AppKit API，可实现默认关闭的屏幕左/右边缘状态条。
- `UNUserNotificationCenter` 支持本地阈值、重置和雷达通知。
- 若需要随登录启动，主 App 或 bundle 内 helper 可经 `SMAppService` 注册，且必须让用户知情、可关闭。

审核时还需要注意三点：

1. App 必须即使没有 NuPhy、ZECTRIX 或 Kindle 也能完整提供基础价值；硬件不能成为审核者无法体验的隐性前置条件。
2. Review Notes 应提供可完整展示额度、雷达、通知和边缘 HUD 的 demo mode。Apple 要求无法提供真实测试账号时，需事先说明并提供充分 demo；非明显功能也要在审核说明中写清。[App Review Guidelines 2.1、2.3](https://developer.apple.com/app-store/review/guidelines/)
3. 产品名、截图与文案只能说明“兼容 Codex/OpenAI”，不能暗示 OpenAI 官方背书。Apple 还可能依据 5.2.2 要求证明有权访问或展示第三方服务数据；OpenAI Codex 代码的 Apache-2.0 许可允许再分发 object code，但不授予 OpenAI 商标权。[OpenAI Codex LICENSE](https://github.com/openai/codex/blob/main/LICENSE)；[App Review Guidelines 5.2](https://developer.apple.com/app-store/review/guidelines/)

## 二、官方额度数据路径

### 路径 A：调用用户现有 Codex executable

**不适合 Mac App Store。**

`Process` 在 Sandbox 中创建的子进程继承父进程 Sandbox。更关键的是，Apple 的 Sandbox 文件文档明确说，App 不能用 user-selected file entitlements 运行位于自己 App bundle、Sandbox container 或 App Group container 之外的程序。因此不能靠让用户选择 `/opt/homebrew/bin/codex`、ChatGPT App 内的 binary 或其他现存 `codex`，再启动 `codex app-server --stdio` 来过审。[Foundation `Process`](https://developer.apple.com/documentation/foundation/process)；[Sandbox 文件访问](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

用户手工先启动一个 websocket/unix-socket app-server，再让 App 作为 client 连接，技术上可能成立。OpenAI 官方 app-server 支持 stdio、experimental websocket 和 unix socket，但让新手在 Terminal 保持服务运行不符合基础产品定位，websocket 还是官方标注的 experimental/unsupported transport。[OpenAI app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)

### 路径 B：内嵌官方 app-server helper

这是目前最值得做原型的路径：

```text
Mac App Store App
├── SwiftUI/AppKit UI
├── signed sandbox-inheriting codex helper
└── App 自有 container / Keychain
       └── 独立 ChatGPT 登录状态
```

Apple 明确允许把 command-line tool 放进 App bundle，Code Sign On Copy 后由 Sandbox App 运行；也建议复杂场景使用 XPC Service。该 helper 必须继承 Sandbox，并随 App 一起提交审核和更新，不能使用 Sparkle 或运行时下载新 binary。[内嵌 Sandbox helper](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)；[App Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/)

OpenAI 官方 app-server 的 ChatGPT-managed 登录可从 `account/login/start` 发起 browser/device-code flow，并由 Codex 持久化与刷新 token；`account/rateLimits/read` 返回官方 quota windows、`usedPercent`、`resetsAt`、计划信息、reset-credit 数量与可用明细，`account/usage/read` 返回账户 token activity。因此它比解析本地日志更贴近首版目标。[OpenAI app-server auth/rate limits](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)

限制与待验证项：

- 登录凭据属于本 App 自己，而不是复用 Codex Desktop/CLI 的登录；首次使用大概率需要重新登录一次。
- 必须验证 browser OAuth callback/device-code flow 在 Sandbox 与 App Review 环境能完成。
- helper 的依赖、动态库、证书、架构和 Sandbox inheritance 必须在 Archive 后验证；不能假设现成 Homebrew binary 能直接塞入 bundle。
- 每次 OpenAI app-server 协议或 backend 变化都可能要求走新的 App Store 审核更新。
- 虽然代码是 Apache-2.0，但第三方服务访问、名称与品牌仍受 OpenAI 条款及 Apple 5.2.2 审查；提交前应准备 attribution、免责声明和授权解释。

### 路径 C：用户选择 `~/.codex` 后读取日志

**这是已经被同类 App 验证的 Sandbox 路径，但不应作为唯一权威额度源。** Apple 允许用户通过 `NSOpenPanel` 选择目录，再用 security-scoped bookmark 延续只读访问。日志可用于本地活动、模型/token 历史和降级显示，却未必包含当前服务端所有 quota windows、准确 reset times 与 reset-credit inventory。

AI Session Meter 的官方页面明确称其“fully sandboxed”，Codex 数据从用户明确授权的 `~/.codex/sessions` 读取；它把读数标为 app-server live、local activity 或 last known，说明同类产品也需要区分来源与新鲜度。[AI Session Meter 官网](https://software.cblh.us/ai_session_meter/)；[用户指南](https://software.cblh.us/ai_session_meter/guide.html)

### 路径 D：直接调用私有 ChatGPT backend

技术上已有同类产品采用网页登录、session key 或 cookie 后直连 provider；但这不是本项目首选。它会把凭据生命周期、私有 endpoint 漂移、服务条款与 Apple 5.2.2 授权都压到本 App 上。OpenAI 已经提供 app-server 的受支持 `account/rateLimits/read`，应优先使用该层，而不是依赖未公开 HTTP endpoint。

## 三、Codex 本地凭据与 Keychain

- App 可以创建和读取**自己的** Keychain item，也可以让同一开发团队、同一 access group 的主 App 与外部 Bridge 共享 item。
- App 不能加入 OpenAI/Codex 的 Keychain access group。Apple 的 access group 由 Team ID 和代码签名保护，跨团队查询不会得到已有 item。[Apple Keychain sharing](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- 如果 Codex 凭据以文件形式存在 `~/.codex`，用户授权目录后主 App 技术上可读取，但复制第三方 OAuth token 会扩大风险，也可能触发 Apple 5.1/5.2 审查；不建议把它作为新手默认路径。
- 最干净的商店方案是由内嵌 app-server 完成独立登录，把 token 存在本 App 的 container/Keychain，并在设置中提供退出与删除。

## 四、第三方 Surprise Reset Radar

Radar 本身没有 Sandbox 障碍。App 使用 `com.apple.security.network.client` 访问公开 HTTPS API即可。当前上游 Codex Resets 官方页面公开提供 API，并明确说明其数据来自对公开 X 帖子的机器分类，且不隶属 OpenAI。[Codex Resets](https://codex-resets.com/)；[API docs](https://codex-resets.com/api/docs)

审核和产品文案应做到：

- “官方个人额度/计划重置时间”与“第三方 Surprise Reset Radar”使用不同分区和来源标签。
- `strong` 预测通知也必须写“第三方预测”，不能写成 OpenAI 已承诺或当前账户必然重置。
- 隐私政策列出请求域名、发送字段和缓存期限。若只请求公开状态且不附带账户标识，明确说明不会把用户的额度或身份发送给 radar。
- 若以后改成自有 backend 推送，需更新 App Privacy 和隐私政策；远程通知则要走 APNs。

## 五、菜单栏、边缘 HUD 与通知

这些功能均可留在 App Store 主 App：

- `MenuBarExtra(.window)` 负责常驻百分比与 popover；详情和设置使用普通 Scene/window。
- `LSUIElement` 隐藏 Dock 图标，但设置、退出和恢复边缘 HUD 的入口必须始终可找到。
- 边缘条使用 borderless、non-activating `NSPanel`，普通 `.floating` level，默认点击穿透、默认关闭，并允许选择显示器、左右边、垂直位置与退出。Apple 对 floating panel 的设计说明强调它应足够小、不遮挡背后内容，并以鼠标交互为主。[`isFloatingPanel`](https://developer.apple.com/documentation/appkit/nspanel/isfloatingpanel)
- 阈值、重置、reset-credit 与 radar 通知使用本地 UserNotifications；第一次在用户启用通知或完成 onboarding 时说明用途并请求授权，不应绕过用户设置。[Apple 通知授权](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)

## 六、Codex plugin、Hook、LaunchAgent 与硬件 adapter

### App Store 主 App不能做的事

当前 NuPhy/ZECTRIX 插件的安装模型会把插件资源写入 Codex 目录，安装 Hook，并运行 companion/LaunchAgent。对于 Mac App Store 主 App：

- 不能用自定义 installer 把 executable 或资源写到共享位置；
- 不能下载新的 adapter binary 后执行；
- 不能用 Sparkle 或 Homebrew 更新自身；
- 不能在用户退出主 App 后留下未经同意的进程；
- 不能静默修改其他 App 的配置或凭据。

这些限制来自 App Review Guidelines 2.4.5 和 2.5.2。[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### 仍然存在的插件空间

Guideline 3.1.1 明确写明 Mac App Store App 可以 host 由 App Store 之外机制启用的 plug-ins/extensions。但这条是对商业启用机制的许可，不会覆盖 2.4.5/2.5.2 的下载、安装和执行新增代码限制。稳妥解释是：

- 外部插件由用户从官网独立下载、安装、签名与公证；
- 商店主 App 只检测并连接，不替用户安装；
- 没有插件时主 App仍完整工作；
- 外部插件不把未审核代码注入主 App进程，而是作为独立 Bridge，通过受限 IPC 交换版本化状态。

### 各硬件的边界

**NuPhy：** Apple 的 USB entitlement 为直接在 Sandbox 内集成 HID 提供了正式技术路径，因此未来也可以把某几款键盘支持编译进主 App。不过这不符合当前“硬件以插件提供”的产品结构，而且会把设备枚举、睡眠、电源恢复与审核测试都带进主 App。首版更适合外部 Bridge；若以后需求足够大，再做单独 Sandbox HID prototype。

**ZECTRIX：** 当前 NOTE4 路径通过 ZECTRIX Cloud API 上传画面，技术上完全可以作为主 App内置网络 adapter；API Key 存本 App自己的 Keychain 即可。但任务 Hook 和现有 Codex plugin 仍属于外部 Bridge。可以让商店主 App负责额度/雷达画面，让 Bridge 只补充任务状态。

**Kindle：** 先定义 transport 再决定归属。纯网络/文件导出可进主 App；涉及脚本安装、USB 工具、常驻 agent 或 Hook 则放 Bridge。

## 七、Mac App Store 同类产品

| 产品 | 已核验的商店能力 | 官方页面披露的数据路径 | 对本项目的意义 |
| --- | --- | --- | --- |
| [AI Session Meter](https://apps.apple.com/us/app/ai-session-meter/id6784566115?platform=mac) | Mac 菜单栏、Codex session/weekly/named limits、reset time、通知、历史、iCloud；官方页面称 fully sandboxed | 用户明确授权 `~/.codex/sessions` 后读本地日志；页面区分 app-server live、local activity、last known；不直接读取 Codex Keychain | 证明 Sandbox + 文件选择 + 菜单栏 + Codex 展示可以上架，但本地日志需要清楚标记来源，不能冒充实时权威值 |
| [MeterTab](https://apps.apple.com/us/app/metertab-ai-usage/id6786290063?platform=mac) | 菜单栏 5h/weekly、倒计时、通知、本机 MCP server、iCloud/Watch | 默认读工具本地日志并估算/校准；连接账户时把自己的 session key 存本 App Keychain | 证明 incoming local server、日志估算和自有 Keychain 可以存在于商店 App；也说明“估算”和“官方”必须分标签 |
| [VibeCheck](https://apps.apple.com/us/app/vibecheck-your-ai-usage/id6759608723?mt=12) | 仅 Mac 的多 provider 菜单栏工具，明确列出 Codex CLI rate limits/reset | 商店页称连接 provider API/CLI、读取本地 session data、Keychain 存自己的 API keys，但未公开具体 Sandbox 实现 | 证明产品类别不是审核禁区；不能据此推断可任意执行外部 CLI |
| [AI Limits & Reset Tracker](https://apps.apple.com/us/app/ai-limits-reset-tracker/id6758946226) | ChatGPT/Codex、菜单栏、widgets、通知、历史；版本记录明确加入 Codex reset credits 及 expiry | 商店页称凭据存 Apple Keychain，但未公开具体 Codex endpoint/执行路径 | 最强的产品先例：商店已允许展示 reset-credit count/expiry；仍需本项目自己的受支持数据源与服务授权 |
| [Usage for Claude](https://apps.apple.com/us/app/usage-for-claude/id6755173244?platform=mac) | 菜单栏、实时限额、详细 dashboard、通知、Widget、iCloud | 用户在 App 内登录 Claude；凭据仅发往 Claude，使用数据本地保存 | 证明“第三方订阅额度客户端 + 自己的登录凭据 + 菜单栏/通知”总体可上架 |
| [CodexBar iOS companion](https://apps.apple.com/us/app/codexbar-usage-of-ai/id6760216772) | iOS 端上架，但 Mac 端仍从官网/GitHub 安装 | 官方开发者回复称 Mac 端因凭据问题难以上架；iOS 只消费 Mac 经 iCloud 同步的数据 | 提醒我们：竞品上架不代表“复用本机凭据”已解决；把 Mac companion 放官网仍是常见退路 |

上述产品说明两件事可以同时成立：**Codex 额度工具可以上 Mac App Store；复用现有 CLI/Keychain 凭据仍是最棘手的边界。**

## 八、推荐架构

推荐采用一个品牌、一个 App Store 主 App、一个可选外部 Bridge：

```text
┌──────────────── Mac App Store 主 App ────────────────┐
│ MenuBarExtra · 详情页 · Edge HUD · 通知             │
│                                                     │
│ bundled sandboxed app-server prototype              │
│   ├─ 独立 OpenAI 登录                               │
│   ├─ 官方额度 / reset time / reset credits          │
│   └─ account usage history                          │
│                                                     │
│ direct HTTPS                                        │
│   └─ third-party Surprise Reset Radar               │
│                                                     │
│ optional normalized IPC client                      │
└──────────────────────┬──────────────────────────────┘
                       │ only normalized state
┌──────────────────────▼──────────────────────────────┐
│ Developer ID Hardware Bridge（官网独立安装）         │
│ Codex Hook · task state · NuPhy HID                 │
│ ZECTRIX task adapter · future Kindle adapter        │
└─────────────────────────────────────────────────────┘
```

主 App 与 Bridge 的契约应只传归一化状态，例如 quota snapshot version、task aggregate state、device health 和 adapter capabilities；不要传 OAuth token、ZECTRIX API Key、prompt、回复或项目路径。IPC 可选择：

1. **同团队 App Group + XPC/Unix socket**：Apple 文档明确支持同一 App Group 内 Sandbox 与非 Sandbox App 的 IPC；最适合两者均由同一开发团队签名。[Apple App Groups](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups)
2. **仅 loopback 的本机 HTTP/WebSocket + 首次配对 secret**：实现更通用，但需主 App的 network client、Bridge 的 localhost server，以及明确的鉴权、版本协商和端口劫持防护。

不推荐做“App Store Basic”和“官网 Full”两套完整 App：这会产生不同 bundle ID、设置迁移、购买状态、自动更新和支持文档的分裂。除非内嵌 app-server 原型彻底失败，否则优先保持一个主 App，只把必须越过 Sandbox 的硬件/Hook 能力放入外部 Bridge。

## 九、进入实现前的最小验证

在决定 App Store 为唯一主渠道前，先做一个不含产品 UI 的 Sandbox spike，只验证：

1. Archive 一个包含签名、sandbox-inheriting `codex app-server` helper 的 Mac App Store build。
2. 在完全不访问外部 `/opt/homebrew/bin/codex`、不读取 OpenAI Keychain、也不要求 `~/.codex` 权限的情况下完成 ChatGPT browser/device-code login。
3. 连续读取 `account/read` 与 `account/rateLimits/read`，确认 Plus 账户的当前窗口、`resetsAt`、plan 和 reset credits。
4. 退出、重启、睡眠/唤醒后验证 token refresh、断线恢复与低频轮询。
5. 用 TestFlight/App Store Review build 而非仅 Debug entitlement 验证；在 Review Notes 提供 demo mode、完整数据流图、Apache attribution、第三方预测免责声明和隐私政策。
6. 单独做一个 Air65 V3 Sandbox USB entitlement probe；结果只决定未来是否能把 NuPhy 集成编译进主 App，不阻塞首版商店上架。

如果第 1–4 项通过，推荐正式采用 **Mac App Store 主 App + 可选 Developer ID Bridge**。如果内嵌 app-server 登录失败或 App Review 明确拒绝，则退回 **App Store UI/radar/local-log 版 + 官网 Bridge 提供实时官方额度与硬件能力**，并在 UI 中明确标注 live、local estimate 和 last known，不能把估算值包装成官方实时额度。
