# OpenAI API 用量竞品与代码复用边界

调研日期：2026-08-30。本文只采用项目官方仓库、产品官网、Mac App Store 页面与 OpenAI 官方资料；开源仓库按文中固定 commit 核对。

## 结论先行

1. **有同类产品提供真实 OpenAI API Platform 用量和美元成本。** CodexBar 的公开源码明确调用 `GET /v1/organization/usage/completions` 与 `GET /v1/organization/costs`；MeterTab、VibeCheck、AI Limits & Reset Tracker 的官方产品页面也宣称支持 OpenAI API spend/cost tracking。[OpenAI Usage API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage)；[CodexBar OpenAI fetcher](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/Sources/CodexBarCore/Providers/OpenAI/OpenAIAPIUsageFetcher.swift)；[MeterTab](https://metertab.app/)；[VibeCheck App Store](https://apps.apple.com/us/app/vibecheck-your-ai-usage/id6759608723?mt=12)；[AI Limits 官网](https://aiusage.inovantis.pt/)
2. **这不是 ChatGPT Plus/Codex 订阅额度的附加字段。** OpenAI API 的 organization usage/cost endpoints 属于 API Platform Admin API；官方 CLI 和 SDK 均把它们标为需要 `OPENAI_ADMIN_KEY`，且 OpenAI 说明只有 API Platform Organization Owner 能创建 Admin API key。[OpenAI CLI](https://github.com/openai/openai-cli#usage)；[OpenAI Node SDK usage resource](https://github.com/openai/openai-node/blob/main/src/resources/admin/organization/usage.ts)；[OpenAI Admin API 帮助](https://help.openai.com/en/articles/9687866-admin-and-audit-logs-api-for-the-api-platform/)
3. **“有就直接拿来用”只在有限意义上成立。** 我们可以直接使用 OpenAI 官方 API；也可以在保留 MIT 版权和许可声明的前提下复用 CodexBar 的 Swift fetch/parse 代码。但不能复制 MeterTab、VibeCheck、AI Limits、CodexHUD 等未公开源码产品的实现；CodexBar 模块也不是单文件即插即用，需要替换 transport、凭据存储和内部模型依赖。
4. **建议首版不纳入 OpenAI API 用量。** 首版目标用户是对 ChatGPT Plus/Codex 订阅额度敏感的新手，而真实 API 账单只对另有 API Platform 组织、并能提供 Admin Key 的用户有价值。现在加入会增加第二套账户概念、密钥管理与 onboarding，却不会改善主用户的核心任务。
5. **架构上应预留独立 provider，后续作为可选能力加入。** 产品中必须把 `ChatGPT/Codex 订阅额度` 与 `OpenAI API 用量与账单` 做成两个独立入口；绝不能把本地 session 的 token 估算美元值标成真实账单。

## 三类数据必须分开

| 类别 | 回答的问题 | 常见数据源 | 是否是真实 API 账单 |
| --- | --- | --- | --- |
| A. ChatGPT/Codex subscription quota | Plus/Pro 的 5 小时、每周窗口还剩多少，何时重置 | Codex app-server、ChatGPT/Codex account usage、受授权的本地快照 | 否；这是订阅限额 |
| B. Codex 本地 session token/activity estimate | 这台 Mac 上的 Codex session 产生了多少 token、按 API 单价折算值是多少 | `~/.codex/sessions` / archived session JSONL、ccusage、本地日志 | 否；可能漏掉其他设备或网页活动，美元值通常只是 API-equivalent estimate |
| C. OpenAI API Platform organization/project usage and dollar cost | API 组织/项目实际调用了多少 token、请求和美元成本 | `/v1/organization/usage/*`、`/v1/organization/costs` | 是；需要相应 API Platform 管理凭据 |

OpenAI 官方文档将 completions usage 和 costs 分别定义为 `GET /organization/usage/completions` 与 `GET /organization/costs`，结果可按 project、API key、user 或 model 等维度聚合；官方 SDK把这组调用标为 Admin API key auth。[OpenAI API Reference](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage)；[OpenAI Node SDK](https://github.com/openai/openai-node/blob/main/src/resources/admin/organization/usage.ts)

## 竞品逐项核对

| 产品 | A 订阅额度 | B 本地 token/activity | C 真实 OpenAI API billing | 数据源与认证 | 源码/复用状态 |
| --- | --- | --- | --- | --- | --- |
| [CodexBar](https://github.com/steipete/CodexBar/tree/e0d2fd90be45cdc2aa656021836f413cbdcdfa23) | 有 | 有 | **有，已从源码验证** | A：Codex OAuth/app-server/CLI；B：扫描 Codex session JSONL 并按模型价格计算；C：OpenAI Admin API key 调 organization costs + completions usage，可按 project 过滤 | MIT；可复用，但必须保留许可与版权声明 |
| [AgentLimits](https://github.com/Nihondo/AgentLimits/tree/2b8b7e9e7120f8c95eb077adcacfcf9bc7405e2c) | 有 | 有 | **没有** | A：内嵌 WebView 登录后请求 ChatGPT 内部 `wham/usage`；B：运行 `npx -y ccusage@latest codex daily` 得到本地 token 与折算成本 | MIT；本地 ccusage 层可参考，但不是 C，也不适合冒充账单 |
| [AI Session Meter](https://apps.apple.com/us/app/ai-session-meter/id6784566115?platform=mac) | 有 | 有 | **没有 OpenAI API billing** | 当前官方页面称 Codex 数据来自用户授权的本地 Codex CLI 文件，并可选连接 Codex app-server；公开 v1.5 源码里的 Admin spend client 是 Anthropic，不是 OpenAI | 公开 v1.5 为 MIT，但官方说明 v2+ 源码不再发布；不能把旧仓库当作当前 App 的完整源码 |
| [MeterTab](https://metertab.app/) | 有/可估算并标来源 | 有 | **有，产品官方宣称** | B：读本地工具日志，订阅美元值明确标 `API-equivalent`；C：用户自带 provider key，真实 billing key 存本机 Keychain，只发给 OpenAI 等 provider | 未发现官方公开源码或复用许可；只能借鉴产品边界，不能复制实现 |
| [VibeCheck](https://apps.apple.com/us/app/vibecheck-your-ai-usage/id6759608723?mt=12) | 有 | 有 | **有，产品官方宣称** | 官方页面称 Mac 直接连接 provider API/CLI、读取本地 session；OpenAI API 支持 spend tracking，API keys 存 Keychain | 未发现官方公开源码或复用许可；具体 OpenAI endpoint/key 类型不可从一手公开材料审计 |
| [AI Limits & Reset Tracker](https://apps.apple.com/us/app/ai-limits-reset-tracker/id6758946226) | 有 | 有历史与 token 展示 | **有，产品官方宣称** | 官网称 OpenAI API accounts 可显示 token、cost 和 billing period；凭据存系统 Keychain，设备直接连接 provider | 未发现官方公开源码或复用许可；公开页面未说明具体 endpoint 与所需 key 类型 |
| [CodexHUD](https://apps.apple.com/us/app/codexhud-codex-bar-for-usage/id6761268038?mt=12) | 有 | 有“今日 token estimate” | **没有** | 从用户授权的本地 Codex session snapshots 读取 5h/7d/reset，并从本地数据估算 token | 未发现官方公开源码或复用许可 |
| [UsageBar（lucas-barake）](https://github.com/lucas-barake/usagebar/tree/3c7e61fc43a4224ccbeec4c2ea8350ae53770e79) | 有 | 没有成本模块 | **没有** | Codex 调本机 `codex app-server` 的 `account/rateLimits/read`；Claude 才读取其 CLI OAuth token | MIT；没有可直接取得 OpenAI API billing 的模块 |

### 1. CodexBar

CodexBar 是唯一同时满足“公开源码、真实 OpenAI API billing、Swift 实现”的直接参考。其 provider 文档明确区分：

- Codex provider：订阅额度来自 OAuth/app-server/CLI；本地 cost usage 扫描 Codex session JSONL。
- OpenAI provider：Admin API key 获取 organization spend/usage；普通 API key 只尝试 legacy credit-balance fallback，不能等同于完整 organization cost history。[CodexBar provider docs](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/docs/providers.md)

其 OpenAI fetcher 实际请求：

- `/v1/organization/costs?group_by=line_item`
- `/v1/organization/usage/completions?group_by=model`
- 可用 `project_ids` 过滤
- 处理 1–365 天窗口、31 日 bucket 分片、分页 cursor、HTTP/解析错误

源码证据：[OpenAIAPIUsageFetcher.swift](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/Sources/CodexBarCore/Providers/OpenAI/OpenAIAPIUsageFetcher.swift)、[OpenAIAPIUsageResponses.swift](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/Sources/CodexBarCore/Providers/OpenAI/OpenAIAPIUsageResponses.swift)、[OpenAIAPIUsageFetcherTests.swift](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/Tests/CodexBarTests/OpenAIAPIUsageFetcherTests.swift)。

CodexBar 的“本地 Codex 成本”则由 `CostUsageFetcher`/scanner 读取本地历史并套用 pricing；它属于 B，不能和上面的 C 合并成同一数字。[CostUsageFetcher.swift](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/Sources/CodexBarCore/CostUsageFetcher.swift)

### 2. AgentLimits

AgentLimits README 明确称 token/cost 来自 `ccusage` CLI：Codex 路径是 `npx -y ccusage@latest codex daily`。这能产生本机活动统计和按价估算，但没有调用 OpenAI organization usage/cost API，因此属于 B，不是 C。[AgentLimits README](https://github.com/Nihondo/AgentLimits/blob/2b8b7e9e7120f8c95eb077adcacfcf9bc7405e2c/README.md)

### 3. AI Session Meter

当前官方页面把 Codex activity、token totals 与 heatmap 描述为读取本地 Codex CLI 文件，并明确说明 Codex 数据不是来自 public usage API。其公开仓库只保留 v1.5，README 明确表示 v2+ App Store 版本不再发布源码；v1.5 的 API spend 是 Claude Admin key，对 OpenAI API billing 没有可复用实现。[AI Session Meter 官网](https://software.cblh.us/ai_session_meter/)；[v1.5 README](https://github.com/yotake/claude-meter/tree/7f8d6b25d6f4daa349e9839d92adf39ce70ae8f2)

### 4. MeterTab

MeterTab 对产品语义处理得最清楚：订阅 token 的美元值必须标为 `API-equivalent`，只有用户连接自己的 API key 后才显示不带该限定词的真实 billed dollars。其隐私页称 key 存在 this-device-only Keychain，且可选请求 Anthropic、OpenAI、OpenRouter billing APIs。[MeterTab 产品页](https://metertab.app/)；[MeterTab 隐私页](https://metertab.app/privacy/)

这套标签语义值得采用，但没有官方公开源码许可证，因此不能把界面或实现“直接拿来”。

### 5. VibeCheck

VibeCheck 的 App Store 页面明确列出 `OpenAI API — spend tracking and rate limits`，并称 30 日 cost history 来自 Mac 直接连接 provider API/CLI；凭据保存在 Mac Keychain。隐私政策进一步说明 provider credentials 留在 Mac，只向用户连接的 provider 发请求。[VibeCheck App Store](https://apps.apple.com/us/app/vibecheck-your-ai-usage/id6759608723?mt=12)；[VibeCheck Privacy](https://appyaccidents.com/apps/vibecheck/privacy/)

但没有公开实现，因此无法从一手材料确认它具体调用哪些 OpenAI endpoint、是否要求 Admin Key，以及如何处理分页/项目过滤。

### 6. AI Limits & Reset Tracker

官方产品页明确把 `ChatGPT and Codex` 与 `OpenAI API` 列为不同 provider，并称后者显示 token usage、costs、billing periods；App Store 版本记录还提到修复跨 project 的 OpenAI API partial fetch。隐私政策称凭据在 Keychain，App 从设备直接调用 provider。[官方产品页](https://aiusage.inovantis.pt/)；[App Store](https://apps.apple.com/us/app/ai-limits-reset-tracker/id6758946226)；[隐私政策](https://inovantis.pt/politica-de-privacidade-ai-usage-tracker/)

这证明 App Store 产品可以提供 C，但不能证明其私有代码可复用，也不能绕过 OpenAI 对 Admin API 凭据的要求。

### 7. CodexHUD

CodexHUD 官方商店页只描述读取用户授权的本地 `~/.codex` session snapshots，并在版本记录中加入“Today's token estimate”。它没有宣称 OpenAI API Platform organization cost，故属于 A+B，不是 C。[CodexHUD App Store](https://apps.apple.com/us/app/codexhud-codex-bar-for-usage/id6761268038?mt=12)

### 8. UsageBar

UsageBar 只做 Claude/Codex subscription windows。Codex 通过本地 `codex app-server` 读取 `account/rateLimits/read`；README 没有 OpenAI API Platform usage/cost provider。[UsageBar README](https://github.com/lucas-barake/usagebar/blob/3c7e61fc43a4224ccbeec4c2ea8350ae53770e79/README.md)

## 代码可以复用到什么程度

### 可复用的 MIT 组件

最有价值的候选来自 CodexBar：

| 文件/模块 | 可复用价值 | 需要重做或解耦的部分 |
| --- | --- | --- |
| `OpenAIAPIUsageFetcher.swift` | 官方 costs/completions 请求、日期分片、分页、project filter、错误分类 | 依赖 CodexBar 的 `ProviderHTTPTransport`、retry policy 和内部 snapshot 类型 |
| `OpenAIAPIUsageResponses.swift` | 官方 response decoding、numeric string 容错 | 可较独立采用，但应随 OpenAI schema 更新 |
| `OpenAIAPIUsageSnapshot.swift` | 日汇总、model/line-item breakdown、Today/7d/N-day summaries | 依赖 CodexBar 内部 `UsageSnapshot`、cost provenance 与格式模型 |
| `OpenAIAPIUsageFetcherTests.swift` | costs/usage fixtures、分页、31 日分片、project filter、错误路径 | 测试框架和 transport stub 需适配本项目 |

CodexBar 使用 MIT License。若复制或改写其 substantial portions，发布的 App/源代码分发物必须包含原 copyright notice 与 MIT permission notice；闭源商业 App 也可以使用 MIT 代码，但不能删除这些声明。[CodexBar LICENSE](https://github.com/steipete/CodexBar/blob/e0d2fd90be45cdc2aa656021836f413cbdcdfa23/LICENSE)

AgentLimits、AI Session Meter v1.5、UsageBar 也采用 MIT，但它们没有 OpenAI C 模块可直接解决本问题：AgentLimits 的 ccusage 仅适合 B；AI Session Meter 的 Admin spend client 是 Anthropic；UsageBar 只处理 A。[AgentLimits LICENSE](https://github.com/Nihondo/AgentLimits/blob/2b8b7e9e7120f8c95eb077adcacfcf9bc7405e2c/LICENSE)；[AI Session Meter LICENSE](https://github.com/yotake/claude-meter/blob/7f8d6b25d6f4daa349e9839d92adf39ce70ae8f2/LICENSE)；[UsageBar LICENSE](https://github.com/lucas-barake/usagebar/blob/3c7e61fc43a4224ccbeec4c2ea8350ae53770e79/LICENSE)

若不是把 AgentLimits 的解析模型移植进 App，而是直接打包或派生 `ccusage`，还要单独遵守 ccusage 自身的 MIT notice（`Copyright (c) 2025 ryoppippi`）。同时，AgentLimits 当前以 `npx -y ccusage@latest` 在运行时下载并执行 CLI；这条路径不适合作为 Mac App Store Sandbox 内的实现，只能参考其数据模型或自行实现本地只读 parser。[ccusage LICENSE](https://github.com/ccusage/ccusage/blob/main/LICENSE)

### 不能直接复用的部分

- MeterTab、VibeCheck、AI Limits & Reset Tracker、CodexHUD 没有在其官方页面提供可复用源码许可证。能在 App Store 下载或看到功能，不等于获得复制代码或界面表达的权利。
- 不能抓取竞品后端或转用竞品保存的凭据；应直接调用 OpenAI 官方 endpoint。
- 不能把 CodexBar 的 `~/.codexbar/config.json` 密钥保存方式照搬进面向新手的 App Store App。若以后加入，应把 Admin Key 存在本 App 的 Keychain，并提供清除/撤销指引；CodexBar 的网络与解析逻辑可以复用，凭据层应重新实现。
- 不能把 B 的本地估算命名为“API 花费”或“本月账单”。MeterTab 的 `API-equivalent`/`real billed dollars` 区分应成为强制数据语义。

## 对首版范围的建议

### 建议：首版不做，保留后续独立 provider

理由不是“没有现成实现”，而是产品用户不同：

- ChatGPT Plus/Codex 订阅用户只需要 ChatGPT 登录；API usage 需要另一个 API Platform organization 和 Admin Key。
- OpenAI 说明只有 Organization Owner 可以创建 Admin API key，因此大量 Plus 新手无法完成该配置。[OpenAI Admin API 帮助](https://help.openai.com/en/articles/9687866-admin-and-audit-logs-api-for-the-api-platform/)
- API key onboarding 会引入高敏感凭据、Keychain、project 过滤、UTC billing bucket、分页、撤销与权限错误等支持成本。
- 把它放进首屏，会模糊本产品已经确定的“ChatGPT Codex 订阅额度与重置雷达”定位。

推荐产品顺序：

1. 首版完成 `ChatGPT/Codex`：官方订阅额度、重置时间、reset credits、第三方雷达、菜单栏、贴边条与克制通知。
2. 数据层预留独立 `OpenAI API` provider，不复用 ChatGPT 登录态，不把 API 数据混入 subscription cards。
3. 用户需求成立后，再基于 OpenAI 官方 endpoint 实现；可评估复用 CodexBar 上述 MIT Swift 模块。
4. 后续页面明确标注：`实际 API 账单`、组织/项目范围、UTC 账期、更新时间和凭据权限；本地 Codex activity 则标注 `本机活动` 或 `API-equivalent estimate`。

如果为了传播内容希望尽早展示 API 能力，更合适的是做一个独立原型或隐藏实验开关，而不是把它纳入首版默认 onboarding。
