# Issue #9 Codex Hook 投递与参考实现复核

调研日期：2026-08-29。本机 PATH 中的 CLI 是 0.146.1；本次 Desktop 真实子代理测试 rollout 的 `cli_version` 和 App bundled binary 则是 `0.150.0-alpha.12.2`。本文只使用官方 Codex 文档、OpenAI `codex` 官方仓库源码，以及具体开源项目源码。

## 结论

这次“没有 `status.json`、所有状态保持 `SignalOff`”首先是 **Hook 尚未被信任**，当前证据不足以证明 Codex Desktop 没有投递 `SubagentStart` / `SubagentStop`。

本机通过官方 app-server 的 `hooks/list` 读取 `/Volumes/990 EP/Dev/Nuphy` 的有效配置，结果是：

- `nuphy-codex@nuphy-codex` 的 8 个 Hook 全部已发现，`enabled=true`，命令也已把 `${PLUGIN_ROOT}` 正确展开为插件缓存中的绝对路径；
- 这 8 个 Hook 的 `trustStatus` 全部是 `untrusted`；
- 同一次读取中，已知正常工作的 `codex-zectrix-dashboard@codex-zectrix-dashboard` 4 个 Hook 全部是 `enabled=true`、`trustStatus=trusted`；
- `~/.codex/config.toml` 的 `[hooks.state]` 中有 ZECTRIX 的精确 `trusted_hash`，没有任何 NuPhy Hook 条目。

Codex 官方文档明确说明：非 managed Hook 必须按当前定义 hash 完成 review/trust；安装或启用插件不会自动信任其 Hook，未信任的插件 Hook 会被跳过。[Codex Hooks：review and trust](https://learn.chatgpt.com/docs/hooks.md#review-and-trust-hooks) [Codex Hooks：plugin-bundled hooks](https://learn.chatgpt.com/docs/hooks.md#plugin-bundled-hooks)

官方 0.146.1 源码也直接证明：Hook 可以出现在发现列表且 `enabled=true`，但只有 `Managed` / `Trusted`，或显式启用自动化 trust bypass 的 handler 才会加入实际执行列表。[OpenAI Codex 0.146.1 `discovery.rs`](https://github.com/openai/codex/blob/79b4f03d35962b005b007a015113b38930711665/codex-rs/hooks/src/engine/discovery.rs#L540-L587)

因此，`status.json` 没有生成与 8 个 Hook 全部未信任完全一致。此前使用 `--dangerously-bypass-hook-trust` 的 CLI 测试能够驱动 NuPhy 状态，也与这个结论相互印证。

## 当前 NuPhy 实现的误判点

NuPhy 的 Hook 定义本身符合官方插件布局：`plugin/hooks/hooks.json` 注册 8 个事件，命令使用官方保证的 `${PLUGIN_ROOT}`，并由同一个短命 binary 接收 stdin。[官方插件 Hook 环境变量](https://learn.chatgpt.com/docs/hooks.md#plugin-bundled-hooks)

当前生命周期检查存在两个不同层次：

1. `validate_plugin_bundle` 只验证仓库内 JSON 的事件集合、命令形式和 bundled binary；
2. diagnostics 的 `hook_ownership=owned` 只表示 `codex plugin list --json` 中插件处于 enabled 状态。

这两项都没有调用 `hooks/list`，也没有检查每个 Hook 的 `currentHash`、`enabled` 和 `trustStatus`。因此“归插件所有”并不等于“Codex 会执行”。

官方 app-server 已提供稳定的只读检查面：`hooks/list` 会按指定 cwd 返回有效 Hook，并在 `HookMetadata` 中公开 `enabled`、`pluginId`、`currentHash` 与 `trustStatus`。[app-server `hooks/list`](https://github.com/openai/codex/blob/79b4f03d35962b005b007a015113b38930711665/codex-rs/app-server/README.md#L2182-L2223) [官方 `HookMetadata`](https://github.com/openai/codex/blob/79b4f03d35962b005b007a015113b38930711665/codex-rs/app-server-protocol/src/protocol/v2/plugin.rs#L523-L542)

## 主要正常对照：codex-zectrix-dashboard

固定快照：[`db1dc65`](https://github.com/BarryBarrywu/codex-zectrix-dashboard/tree/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c)。

ZECTRIX 的 Hook 文件本身更简单，只注册 `UserPromptSubmit`、`PreToolUse`、`PostToolUse` 和 `Stop`，并不支持 `SubagentStart` / `SubagentStop`。[ZECTRIX `hooks.json`](https://github.com/BarryBarrywu/codex-zectrix-dashboard/blob/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c/plugin/hooks/hooks.json)

它能正常工作的关键不在事件集合，而在安装生命周期：

- 通过 app-server `hooks/list` 获取 Codex 实际发现的 Hook metadata；
- 只接受属于精确 plugin id、事件集合完全相等、命令/路径/timeout 完全相等且 `currentHash` 命中预审 allowlist 的定义；
- 通过官方 `config/batchWrite` 将每个 Hook 的 `enabled` 和 `trusted_hash=currentHash` 写入 `hooks.state`；
- reload 配置后再次 `hooks/list`，只有全部返回 `enabled=true`、`trustStatus=trusted` 且 hash 未变才继续启动 companion。

对应源码：[app-server client 与 trust 写入](https://github.com/BarryBarrywu/codex-zectrix-dashboard/blob/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c/src/app_server.rs#L96-L147) [安装时复核、配置并读回](https://github.com/BarryBarrywu/codex-zectrix-dashboard/blob/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c/src/plugin_lifecycle.rs#L212-L251) [Hook 定义 allowlist](https://github.com/BarryBarrywu/codex-zectrix-dashboard/blob/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c/src/plugin_lifecycle.rs#L50-L100)

事件到达后，ZECTRIX 的短命 Hook 只解析 allowlisted 字段并追加到 `hook-events.jsonl`；这与 NuPhy “Hook 先写 durable state、companion 再控制硬件”的边界相同。[ZECTRIX Hook 落盘入口](https://github.com/BarryBarrywu/codex-zectrix-dashboard/blob/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c/src/main.rs#L285-L313) [事件解析与追加写](https://github.com/BarryBarrywu/codex-zectrix-dashboard/blob/db1dc650e4b79ecbd0b7634407f1d7d7bc49867c/src/activity_sources.rs#L145-L192)

可直接复用的是它的 **发现 → 精确复核 → 信任 → 再读回** 生命周期，不是它的四事件状态模型。

## 其他开源项目的佐证

### PG408/codex-status-bar

固定快照：[`232beee`](https://github.com/PG408/codex-status-bar/tree/232beee62968d91a7fd0905836aef73f31fbcd82)。

该项目同时注册 `SubagentStart` 和 `SubagentStop`，按 `agent_id` / `turn_id` 维护同一 session 内的子代理事实；这与 NuPhy 的 owner reducer 方向一致。[Hook 注册表](https://github.com/PG408/codex-status-bar/blob/232beee62968d91a7fd0905836aef73f31fbcd82/scripts/lib/hook-manager.js#L10-L24) [子代理状态规则](https://github.com/PG408/codex-status-bar/blob/232beee62968d91a7fd0905836aef73f31fbcd82/docs/hook-events.md#L68-L103)

但它明确承认安装器不能绕过 Codex 的 Hook review 流程；安装了 `hooks.json` 不代表 Hook 已运行。[Hook Trust 说明](https://github.com/PG408/codex-status-bar/blob/232beee62968d91a7fd0905836aef73f31fbcd82/PRIVACY.md#L53-L59) 仓库里的 subagent fixtures 能证明 reducer，不足以替代当前机器上的 runtime trust 验证。

### Sora-bluesky/kbd-signal

固定快照：[`e064221`](https://github.com/Sora-bluesky/kbd-signal/tree/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7)。

该项目的 Codex 模板使用 `SubagentStop` 清理子 owner，并在安装说明中把 `/hooks` review/trust 列为必需步骤，特别注明定义变化后需要按新 hash 再次确认。[Codex Hook 模板](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/examples/codex-hooks.json) [Codex 安装与 trust 步骤](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/README.md#L137-L166)

它再次说明：不能用“配置文件里有事件”推断“事件已到达 Hook”。

## Codex 0.146.1 / Desktop 0.150 的真实子代理边界

官方 0.146.1 并非只有 schema 而没有实现。源码在 session start 时把 `SessionSource::SubAgent(SubAgentSource::ThreadSpawn)` 转成 `SubagentStart`，并携带 `agent_id` / `agent_type`；对应子线程结束时用 `SubagentStop` 取代普通 `Stop`。[`SubagentStart` 派发](https://github.com/openai/codex/blob/79b4f03d35962b005b007a015113b38930711665/codex-rs/core/src/hook_runtime.rs#L102-L155) [`SubagentStop` 派发](https://github.com/openai/codex/blob/79b4f03d35962b005b007a015113b38930711665/codex-rs/core/src/hook_runtime.rs#L297-L365)

官方集成测试也让模型实际调用 `multi_agent_v1.spawn_agent`，验证 `SubagentStart`、子代理 scoped 的 `UserPromptSubmit` 以及 `agent_id`。[0.146.1 subagent Hook 集成测试](https://github.com/openai/codex/blob/79b4f03d35962b005b007a015113b38930711665/codex-rs/core/tests/suite/subagent_notifications.rs#L527-L649)

本次 Desktop 测试的 child rollout 明确记录为 `subagent.thread_spawn`，而不是 internal/synthetic subagent；Desktop bundled 版本 `0.150.0-alpha.12.2` 对应源码也保留了同一派发路径。因此，在 trust 修复并新建任务后，预期应该收到这两个事件。官方仓库中确有其他平台报告“已配置但 handler 0 launches”，以及 interrupt 路径缺少 `SubagentStop` 的相邻问题，但它们只能作为修复 trust 后仍复现时的上游对照，不能覆盖本次已经确认的 untrusted 原因。[openai/codex #33097](https://github.com/openai/codex/issues/33097) [openai/codex #38142](https://github.com/openai/codex/issues/38142)

仍有明确的上游限制：源码只对 `ThreadSpawn` 子线程暴露用户 Hook，review、compact 等 internal/synthetic subagent 会被跳过。因此未来即使 trust 正常，也不能承诺每一种 Codex 内部子任务都产生 `SubagentStart` / `SubagentStop`。

## 建议修复

### P0：修复生命周期与 diagnostics

参考 ZECTRIX，把官方 app-server client 的最小能力移入 NuPhy：

1. `lifecycle install/update` 完成 `plugin add` 后调用 `hooks/list`；
2. 只选择精确 plugin id 的 8 个 Hook，校验事件全集、resolved command、source path、timeout、handler type 与预审 `currentHash`；
3. 默认停在明确的 review gate，要求用户在 `/hooks` 检查并 trust 当前 8 个定义；若产品要复用 ZECTRIX 的 `config/batchWrite` 自动配置方式，应把它做成单独、显式的 trust 动作，并在执行前展示已 allowlist 的完整事件集合，而不是在普通 install 中静默扩大信任；
4. reload user config 后再次 `hooks/list`；若任一 Hook 不是 `trusted` 或 hash 变化，安装应失败且不得报告 runtime ready；
5. diagnostics 增加 `reviewed_hooks=8`、`hook_trust=trusted|untrusted|modified`、`hook_runtime_ready=true|false`。现有 `hook_ownership` 只能保留为“插件已安装/启用”，不能替代 trust 状态。

无论选择人工 `/hooks` 还是显式 trust 动作，都必须在未 trusted 时让 validation 明确失败；不能继续只打印提示后返回健康。

### P0：不要用环境变量 fallback 处理本次故障

官方文档保证插件 Hook 有 `${PLUGIN_ROOT}`，本机 `hooks/list` 也已把它正确展开成缓存绝对路径。改成 `${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}` 不会解决未信任问题，反而会改变 8 个 Hook hash，使旧 trust 失效。应维持原定义，除非有独立证据证明目标 Codex 版本缺少 `PLUGIN_ROOT`。

### P1：重新做真实子代理验收

完成 P0 后必须新建 Codex 任务，再按以下顺序验证：

1. 任务开始后先确认主 `UserPromptSubmit` 已生成 durable state；
2. 启动真实 `spawn_agent`，确认出现带独立 `agent_id` 的 owner；
3. 子代理结束后确认只移除 child owner，主任务仍按聚合优先级显示；
4. 保留原有键盘目视、输入、拔插和 reset 验收。

只有“主 Hook 已 trusted 且能正常到达，但 native `ThreadSpawn` 的 start/stop 仍缺失”时，才应把问题重新归为 Codex 上游事件投递。届时证据包至少应包含：Codex 版本、`hooks/list` 中 8 个 Hook 的 trusted 状态、父任务 Hook 日志、子 thread 的 session source，以及缺失的两个事件。

## 不建议的兼容方案

- 不要从父任务 `PostToolUse(spawn_agent)` 合成 child owner：父事件没有可靠的 child stop 生命周期，容易留下永久蓝灯。
- 不要轮询 rollout JSONL 推断子代理：官方没有把 transcript/rollout 格式承诺为稳定 Hook API。
- 不要因为 `hooks.json` 中存在 `SubagentStart` / `SubagentStop` 就宣布支持已经验收；必须同时验证 trust 和真实事件落盘。
- 不要把 ZECTRIX 的四事件 reducer 直接复制到 NuPhy；它不处理子代理，只应复用其 Hook 生命周期与 trust 校验方式。

## 修复后的预期判断

按现有证据，这个问题 **可以在本项目内修复**。最可能的完整修复是补齐 ZECTRIX 已验证的 Hook trust 生命周期，然后重新验收；NuPhy 的硬件协议、companion、durable store 和子代理 owner reducer 目前不需要为此重写。仍属上游限制的只有非 `ThreadSpawn` internal/synthetic subagent，以及在全部 Hook 已 trusted 后仍可复现的真实 `ThreadSpawn` 漏事件。
