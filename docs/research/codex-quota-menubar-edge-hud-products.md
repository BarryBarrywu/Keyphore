# Codex 额度菜单栏、屏幕边缘 HUD 与可选输出产品调研

调研日期：2026-08-30。本文只采用官方产品网站、Mac App Store、Apple 官方文档和项目自身 GitHub 仓库；开源项目按调研时 `main` 快照核对。产品迭代很快，功能与分发状态应在立项时再次确认。

## 结论先行

1. **“AI 额度菜单栏”已经有强势直接竞品，尤其是 CodexBar。** CodexBar 已覆盖 Codex、Claude、Cursor、Gemini、Copilot 等大量 provider，支持重置倒计时、状态页、费用历史、Widget、CLI、本机 HTTP 服务和外部状态条。因此新产品不适合把“支持更多 provider”当作首要差异化。[CodexBar README](https://github.com/steipete/CodexBar/tree/c5ab145175fab75c23bf5819101235e281ceedd7)
2. **仍有一条清楚的用户切口：为 ChatGPT Plus/Codex 新手解释“我还能用多少、什么时候恢复、现在该不该开始一个大任务”。** 现有工具大多以百分比、窗口和 provider 为中心；可以把产品中心改成行动建议、简明中文、可信度标识，以及“官方个人额度”和“第三方 Surprise Reset Radar”严格分区。
3. **菜单栏应当是默认且永久可用的主入口；屏幕边缘条是可选的 ambient display。** 菜单栏适合常驻查看与打开详情。边缘条只承载一眼能读完的 1–2 个指标，不应复制整个菜单。NemoNotch 已证明 AI 活动可以用可拖动胶囊、边缘闪光和可选 toast 表达；MacEdgeLight 则证明点击穿透、多屏、拖动定位和自动淡出是边缘覆盖层的成熟交互积木。[NemoNotch README](https://github.com/GaoZimeng0425/NemoNotch/tree/2fde76dbda8d9289c612bba4016129368a9bba4b)；[MacEdgeLight README](https://github.com/ChiefInnovator/macedgelight/tree/77c3c986010df9e81e69ff0481b81eda57cf7f18)
4. **键盘、墨水屏和以后可能出现的 Stream Deck，不应定义主产品，而应是同一状态核心的可选输出 adapter。** CodexBar 的 `codexbar serve`、showy-quota 和 Stream Deck 插件证明了“一个进程负责凭据与采集，多个 renderer 只消费归一化本机数据”更容易扩展，也避免每个设备重复读取凭据。[CodexBar CLI](https://github.com/steipete/CodexBar/blob/c5ab145175fab75c23bf5819101235e281ceedd7/docs/cli.md)；[showy-quota](https://github.com/enieuwy/showy-quota/tree/4030dcb1ff414b93200858bb7e3effbbb2123b8f)；[AI Usage Limits for Stream Deck](https://github.com/lenadweb/stream-deck-ai-limits/tree/efd39578785f58387f5d4c802d8013f3c0d1b470)
5. **首版更适合 Developer ID 签名、公证后官网/Homebrew 分发，而不是把 Mac App Store 当唯一渠道。** 当前能力需要启动本地 `codex app-server`、安装 Hook、访问 Codex 本地目录，并可选控制 USB HID；Mac App Store 强制 App Sandbox，而 sandbox 会限制其他进程和任意文件位置访问。可在以后评估一个“纯额度、无 Hook/硬件”的 App Store 版本，但那是另一条能力边界。[Apple App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)；[Apple Developer ID](https://developer.apple.com/support/developer-id/)
6. **iOS 不宜做第一主端。** 当前权威额度和任务/硬件数据位于 Mac 的 Codex 凭据、本地 app-server、Hook 与 USB 环境；iOS 版若没有 Mac companion 或云端账号同步，只能重新设计认证和数据来源。更稳妥的顺序是先验证 Mac 菜单栏需求，再决定是否把 iPhone 做成只读 companion。

## 一、直接竞品：额度与重置时间

| 产品 | 核心用户任务 | 默认展示与交互 | 数据、隐私与权限 | 分发 | 对本项目的启示 |
| --- | --- | --- | --- | --- | --- |
| [CodexBar](https://github.com/steipete/CodexBar/tree/c5ab145175fab75c23bf5819101235e281ceedd7) | 同时查看多个 AI coding provider 的 session/weekly/monthly 配额、重置倒计时、费用和服务故障 | 无 Dock 图标；每个 provider 一个状态项，或合并成一个；图标本身是微型用量表，点击后看倒计时、图表和详情；另有 Widget 与通知 | 默认本机解析；复用 OAuth、CLI、API key、浏览器 cookie 或本地文件；cookie/本地 agent 扫描均为可选；后台不要求录屏和辅助功能权限。[隐私与权限说明](https://github.com/steipete/CodexBar/blob/c5ab145175fab75c23bf5819101235e281ceedd7/README.md#privacy-note) | GitHub Releases、Homebrew Cask；macOS 14+ | 它已占据“provider 数量和高级功能”高地。不要正面对拼清单；应争夺更简单的 Codex Plus 首次体验、雷达解释和新型输出表面 |
| [UsageBar（lucas-barake）](https://github.com/lucas-barake/usagebar/tree/3c7e61fc43a4224ccbeec4c2ea8350ae53770e79) | 只看 Claude Code 与 Codex 已用额度 | 菜单栏显示一个稳定语义的长窗口数字，也可显示“短窗口 / 长窗口”；点击看所有窗口百分比和重置时间；每 5 分钟刷新 | Codex 走 `account/rateLimits/read`；Claude 读取 Keychain token 并只发往 Anthropic；首次会出现 Keychain 授权 | 安装脚本；项目明确说明其 ad-hoc 签名且未公证，浏览器下载会被 Gatekeeper 阻止 | 极简产品能把“一个数字永远表示什么”讲清楚。新手产品不能让菜单栏数字在 5 小时与周额度之间无提示切换 |
| [AgentLimits](https://github.com/Nihondo/AgentLimits/tree/2b8b7e9e7120f8c95eb077adcacfcf9bc7405e2c) | 看 Codex、Claude、Copilot 限额、节奏、token 与费用 | 菜单栏两行 `5h / weekly`；弹出 dashboard；可切已用/剩余；Notification Center 与桌面 Widget；以窗口已过时间做 pacemaker | 内嵌 WebView 登录各 provider，支持清除网站存储与缓存；内部 API 路径较多 | GitHub 下载；README 标注仍在开发 | “额度百分比”可提升为“相对时间进度是否用得太快”。但首版不必做完整成本分析，先验证用户是否理解并依赖节奏提示 |
| [UsageBar（peerb）](https://github.com/peerb/usage-bar/tree/ecd8cfa58da68660194016b1fcc3f25835a1788f) | 极简查看 Claude 5 小时与 7 天限额 | 两根菜单栏竖条；点击看准确百分比、重置时间和最近 session；无 Dock 图标 | 读取 Claude Code 的本地缓存或用其凭据访问 API | Homebrew tap 或源码安装；项目说明未签名时需要绕过 Gatekeeper | 两根细条证明“两个窗口”可以在极小面积保持恒定映射；本项目边缘条也应采用固定 lane，而不是轮播造成语义漂移 |
| [codex-zectrix-dashboard](https://github.com/BarryBarrywu/codex-zectrix-dashboard) | 不打开 Codex 也能抬头看官方额度、任务与独立重置雷达 | 400×300 墨水屏常显；不同数据不同频率；只在可见画面变化时上传 | Mac 本地 app-server 归一化、缓存与渲染；ZECTRIX API key 存 Keychain；任务隐私模式；雷达明确不是 OpenAI 承诺 | Codex 插件 + companion，需要 NOTE4 | 已经具备新产品最独特的领域资产：官方额度、可用重置额度、第三方雷达的边界，以及低打扰常显经验；应抽成通用核心，而非继续锁在 NOTE4 UI 中 |

### CodexBar 当前真正强在哪里

CodexBar 不是一个简单百分比工具。它的 Codex provider 默认优先使用 OAuth，其次是 `codex app-server`；还能读取可用 reset-credit inventory，并把网页 dashboard enrichment 作为可选增强。它也支持多账号、额外模型窗口、历史费用、服务状态和多种刷新策略。[Codex provider 文档](https://github.com/steipete/CodexBar/blob/c5ab145175fab75c23bf5819101235e281ceedd7/docs/codex.md)

它还把后台成本做成了显式产品策略：新安装默认 Adaptive refresh，根据最近菜单交互、低电量、热状态和可选的本地 coding activity，在 2–30 分钟之间调整；失败或陈旧数据会保留在菜单中并弱化图标。[刷新循环](https://github.com/steipete/CodexBar/blob/c5ab145175fab75c23bf5819101235e281ceedd7/docs/refresh-loop.md)

因此，“做一个菜单栏 App”本身不是差异化。可验证的差异应是：

- **更窄的人群**：先只服务 ChatGPT Plus/Codex 用户，不要求理解 API provider 或 token cost。
- **更容易做决定**：除了百分比，直接回答“短窗口/周窗口哪个先成为约束”“距离重置还有多久”“当前消耗速度是否异常”。
- **可信度分层**：官方个人 reset time、可用 reset credit、第三方 Surprise Reset Radar 永远分栏、分色、分文案；雷达不能伪装成账户倒计时。
- **更有辨识度的输出**：同一数据可以出现在菜单栏、屏幕边缘、键盘灯和 NOTE4，而不是只有一个 popover。

## 二、屏幕边缘、悬浮胶囊与 HUD

### 最接近用户设想的参考

| 产品/框架 | 采用的形态 | 有价值的交互 | 不能直接照搬的部分 |
| --- | --- | --- | --- |
| [NemoNotch](https://github.com/GaoZimeng0425/NemoNotch/tree/2fde76dbda8d9289c612bba4016129368a9bba4b) | 刘海面板 + 默认位于主屏右上角、可拖动的 AI 状态胶囊 + 全屏边缘完成闪光 + toast | 工作时出现、点击展开 session；完成闪光和 toast 可关闭；快速完成会合并而非重复轰炸；自定义 `NSWindow` 支持 click-through 与多屏定位 | 功能面过宽，且以刘海为视觉中心；本产品只需要其中的 AI status capsule/edge signal 模式 |
| [NotchLand](https://github.com/scienceLabwork/NotchLand/tree/81305ce7bb7de04f863c539489b121bfe2fce0fd) | 跨 Space 的无边框 `NSPanel`，附着 MacBook 刘海；菜单栏作为 companion 入口 | 事件值得出现时扩张，结束后收起；controller 发布 presentation，再由优先级 switch 选择唯一表面；首次权限逐项解释且可跳过 | 依赖有刘海 MacBook；左/右屏幕边缘需要另一套几何与碰撞策略 |
| [OpenNook](https://github.com/twinkling-reality/opennook/tree/03e1acd37e28548475d76b2fee5a430f03c9378d) | 有刘海时融合刘海，无刘海时退化为 floating capsule；hover 展开，支持锁定常开与全局快捷键 | 把 surface、app chrome 和可选 components 分层；活动队列有优先级、去重，并在用户交互时让出表面 | 它是框架而非成熟终端产品；用户设想是屏幕侧边，不是顶部模拟刘海 |
| [MacEdgeLight](https://github.com/ChiefInnovator/macedgelight/tree/77c3c986010df9e81e69ff0481b81eda57cf7f18) | 全屏点击穿透边缘 overlay + 可拖动控制 HUD | 多显示器、拖动 reposition、3 秒无操作自动淡出、hover 恢复、可选择是否被录屏、无 Dock 图标 | 主要是补光而非状态；持续高亮会干扰工作，额度条应比它更克制 |
| [SupaSidebar](https://docs.supasidebar.com/features/sidebar) | 隐藏在左或右屏幕边缘的 floating sidebar | 用户明确选择左/右侧；从边缘即时唤出、不占常规窗口 | 它承载完整工作区；额度条只需常显少量状态，不能变成第二个 sidebar |

### 建议的边缘条产品规则

屏幕边缘条可以成为明显的品牌特征，但应该默认关闭，并遵循以下边界：

- 初次只让用户选择“关闭 / 左侧 / 右侧”，高级设置再选择显示器、垂直位置、宽度和不透明度。
- 收起态只显示固定语义的两条 lane：5 小时额度与每周额度；不要自动轮播。雷达有活跃预测时才出现第三个短暂标记。
- 默认点击穿透，hover 或快捷键后才进入可交互态；防止一条常驻 UI 抢走拖拽和窗口缩放。
- 允许拖动，但拖动结束后吸附屏幕边缘，并避开 Dock、菜单栏和安全区；多屏拔插后回到可见屏幕，而不是保留失效坐标。
- 在全屏视频、屏幕共享、录屏和勿扰/专注模式下提供独立开关；“从录屏隐藏”必须明确告知，不能造成用户误以为观众可见。
- 状态变化采用短暂动画，稳定额度保持静态。完成、等待、额度危险和雷达预测需要不同节奏，而不是只换颜色；这也提高色觉障碍下的可读性。
- 菜单栏必须始终能关闭边缘条和进入设置。Apple 将 `MenuBarExtra` 定义为即使 App 非活动也可访问常用功能的持久控制，这与该兜底入口一致。[Apple `MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)

## 三、插件与外设输出

三个一手案例指向相同结构：

1. CodexBar 的 CLI 可以启动只监听 `127.0.0.1` 的 HTTP 服务，提供 `/health`、`/usage` 与 `/cost`；服务端统一处理凭据、抓取和缓存。[CodexBar CLI](https://github.com/steipete/CodexBar/blob/c5ab145175fab75c23bf5819101235e281ceedd7/docs/cli.md)
2. showy-quota 不再接触 provider 凭据，而是从 CodexBar 的本机服务取数据，再绘制到 SketchyBar、tmux、Zellij 和 agent status line；不同表面共享缓存与 last-known-good。[showy-quota README](https://github.com/enieuwy/showy-quota/tree/4030dcb1ff414b93200858bb7e3effbbb2123b8f)
3. AI Usage Limits for Stream Deck 同样把 CodexBar 本机服务作为数据源，把 provider/account/metric 映射到按键和旋钮。[Stream Deck 插件](https://github.com/lenadweb/stream-deck-ai-limits/tree/efd39578785f58387f5d4c802d8013f3c0d1b470)

适合本项目的产品边界是：

```text
Codex/账户/雷达/Hook
          ↓
   本机状态核心（唯一采集者）
          ↓
 menu bar · edge HUD · NuPhy · ZECTRIX · future adapters
```

- 核心输出稳定、版本化的状态模型，不暴露原始 token、cookie、任务正文或硬件密钥。
- adapter 声明能力，例如 `quota.percent`、`quota.reset_at`、`radar.active`、`agent.aggregate_state`；缺少能力时明确 unavailable，不自行猜测。
- 硬件 adapter 默认不安装、不启动；用户连接对应设备后再进入逐项 setup。
- 只允许一个进程拥有同一硬件 transport；UI、Hook 与第三方 adapter 都通过核心通信，不能同时打开 HID。
- 本机 API 默认只绑定 loopback，不开启局域网访问；若以后支持 iPhone，应单独设计配对、认证、加密与撤销，而不是把 localhost 端口直接暴露出去。

xbar 也验证了“主应用 + 用户安装脚本插件”的扩展性：用户把脚本放入指定插件目录，应用负责发现与渲染。[xbar README](https://github.com/matryer/xbar/tree/d624239058997c80118eaebe2e7f8331b3c765e0) 但对新手产品，不建议首版开放任意脚本执行；先提供签名内置 adapter，等状态协议稳定后再考虑第三方 SDK。

## 四、权限、隐私与分发

### 建议的权限节奏

- 首次启动只展示菜单栏额度；能通过已有 Codex 登录取得数据时，不要求用户再次粘贴 token。
- Hook、键盘、墨水屏和 agent activity 都是独立开关，进入对应功能时才解释并申请。
- 明确显示每个数据的来源与新鲜度：`官方账户额度`、`第三方雷达`、`本机任务 Hook`、`设备离线`。
- 设置中提供“清除凭据/缓存”“卸载 Hook”“停用 companion”“恢复键盘原状态”等可逆动作。
- 不把 Full Disk Access、Accessibility 或 Screen Recording 作为基础额度功能的前置条件。CodexBar 的做法说明浏览器 cookie enrichment 可以是 opt-in，后台基础路径无需录屏或辅助功能权限。[CodexBar 权限说明](https://github.com/steipete/CodexBar/blob/c5ab145175fab75c23bf5819101235e281ceedd7/README.md#macos-permissions-why-theyre-needed)

### 分发判断

Apple 说明，Mac App Store 应用必须启用 App Sandbox；sandbox 默认把应用限制在自己的 container，访问用户选择的任意位置通常要通过系统文件选择器与 security-scoped bookmark，嵌入的命令行工具也继承宿主 sandbox。[配置 App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)；[访问 sandbox 外文件](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

据此推断，包含 `codex app-server` 子进程、Codex Hook 安装、LaunchAgent 与 Raw HID 的完整版本，走 Mac App Store 会显著增加能力冲突和审核不确定性。首版更适合：

- Developer ID 签名；
- Hardened Runtime；
- Apple 公证并 staple ticket；
- 官网 DMG + Homebrew Cask；
- 应用内更新或明确的手动更新渠道。

Apple 官方说明 Developer ID + 公证可让 Gatekeeper 验证应用未被篡改且不属于已知恶意软件；Mac App Store 自带等价安全检查。[Developer ID](https://developer.apple.com/support/developer-id/)；[公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

“先用未签名 ZIP/安装脚本验证需求”会把新手最敏感的安全警告放在第一步。UsageBar 两个项目都需要解释 Gatekeeper 或移除 quarantine，这正是面向新手时应避免的安装体验。[lucas-barake/usagebar 安装说明](https://github.com/lucas-barake/usagebar/tree/3c7e61fc43a4224ccbeec4c2ea8350ae53770e79#install)；[peerb/usage-bar 安装说明](https://github.com/peerb/usage-bar/tree/ecd8cfa58da68660194016b1fcc3f25835a1788f#install)

## 五、产品组合建议

### 推荐：一个品牌、一个 Mac App、多个可选 surface

| 层级 | 对外产品角色 | 首版是否默认 |
| --- | --- | --- |
| Codex 额度与 reset credits | 面向所有 ChatGPT Plus/Codex 用户的核心价值 | 默认开启 |
| Surprise Reset Radar | 与官方额度明确分离的特色能力 | 默认展示，但持续标注第三方预测 |
| 菜单栏 | 最低摩擦、始终可用的主入口 | 默认开启 |
| 屏幕边缘条 | 高辨识度、适合视频演示的 ambient display | 默认关闭，用户主动开启 |
| Codex 任务状态 | 需要 Hook 的增强能力 | 用户主动开启 |
| NuPhy 灯光 | 小众但有传播力的实体输出 | 检测到兼容设备后推荐安装 |
| ZECTRIX NOTE4 | 小众但成熟的低打扰常显输出 | 独立 setup，复用既有设备能力 |
| iPhone/iPad | 远程只读 companion | 不进入首版，待 Mac 留存验证后再决定 |

这不是把三个产品揉成一个巨型设置面板，而是把已经存在的共同数据核心产品化。用户只装 Mac App 就能获得完整价值；有键盘或墨水屏的人再打开相应输出。

### 不建议的路线

- **不建议分别维护三个完全独立的采集 companion。** 会重复读取 app-server、重复保存状态、增加电量与睡眠风险，并让数据定义漂移。
- **不建议首版复制 CodexBar 的多 provider 广度。** 先把 Codex Plus 新手体验与雷达做深，Claude/Gemini 只有在用户验证后再加。
- **不建议把边缘条默认打开。** 常驻覆盖屏幕的容忍度远低于菜单栏；它更适合成为用户主动选择的 signature feature。
- **不建议把硬件放进产品名或首次 onboarding 主线。** 否则绝大多数没有 NuPhy/NOTE4 的用户会误以为软件对自己无用。
- **不建议先做 iOS 独立版。** 在没有可信同步与认证方案时，它无法复用 Mac 本地最可靠的数据源。

## 六、建议的验证顺序

1. 做一个只包含菜单栏、官方额度/重置时间/reset credits、第三方雷达的签名公证 Mac MVP；验证安装成功率、7 日留存和菜单打开频率。
2. 用设置开关加入边缘条，先只支持单屏左/右固定 lane；验证实际开启率、用户是否长期保留，以及它是否干扰全屏/录屏。
3. 将当前 Keyphore 与 ZECTRIX companion 接到同一版本化状态协议；保持各自 setup 与卸载独立。
4. 根据用户反馈决定第二 provider，而不是预先追求 provider 数量。
5. 只有当用户明确提出离开 Mac 查看额度的需求，再评估 iPhone companion、局域网配对或端到端加密云同步。

最值得先做的设计原型不是完整设置窗口，而是三张对比稿：菜单栏单数字、菜单栏双 lane，以及右侧屏幕边缘双 lane。用同一份真实额度数据测试用户能否在 3 秒内回答“哪个额度先成为限制、何时恢复、雷达是不是官方信息”。
