# Codex / Claude Code 状态灯项目源码调研

调研日期：2026-08-29。以下结论以各仓库当时 `main` 分支的固定提交、OpenAI Codex 官方手册和 Anthropic Claude Code 官方 Hook 文档为准。Hook 能力变化很快，仓库 README 中的旧结论不能自动视为当前平台能力。

## 结论先行

1. **Codex 当前没有失败专用 Hook。** 官方事件包含 `SessionStart`、`SessionEnd`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`SubagentStart`、`SubagentStop`、`Stop` 等，但没有 `StopFailure` 或 `PostToolUseFailure`。因此仅靠稳定 Hook API，可以可靠表示执行、等待批准、结束和清理，不能可靠断言“本轮失败”。[Codex Hooks 官方文档](https://learn.chatgpt.com/docs/hooks.md)
2. **Claude Code 当前有真实失败 Hook。** `PostToolUseFailure` 表示工具调用失败；`StopFailure` 只在本轮因 API 错误结束时触发，带结构化 `error` 类型。它并不等于测试失败、命令非零退出或模型回答质量不合格。[Claude Code Hook 事件表](https://code.claude.com/docs/en/hooks#hook-lifecycle)；[StopFailure](https://code.claude.com/docs/en/hooks#stopfailure)
3. **最成熟的多会话做法不是“最后一个事件覆盖全局颜色”，而是 owner 集合或每会话记录后再归约。** `kbd-signal`、`claude-status`、`OpenControl` 都证明了这一点。多数参考项目采用 `error > waiting`，但本项目应维持已确定的 `waiting > error > executing > completed > idle/off`：等待是需要用户立即处理的可靠事件，而 Codex 当前没有可靠的终局失败 Hook。完成态应短暂显示，等待态需要 owner 级释放和过期回收。
4. **对本项目最值得复用的是状态机，而不是硬件代码。** 推荐组合：`kbd-signal` 的 owner/锁/基线恢复、`OpenControl` 的 CLI 退出码错误边界和硬件心跳、`claude-status` 的优先级聚合与“延迟 Notification 不得重抬等待”、`CC Lights` 的每会话持久文件，以及 `Microbridge` 的状态总线/设备单一所有者思想。
5. **Codex 红灯首版不应由文本或 rollout 推断。** 若以后选择“必须通过本项目 wrapper 启动 Codex”，可以把子进程非零退出作为“进程失败”；否则应保留红色状态但不宣称代表 Codex 任务失败。内部 rollout 轮询适合实验或诊断，不适合独立维护的稳定协议。

## 官方事件能力基线

### Codex

Codex Hook 的公共输入包含 `session_id`；子代理 Hook 继续使用父 `session_id`，并额外给 `agent_id`。`SubagentStop` 可用于删除子 owner，避免子代理结束导致整个主任务闪绿。官方同时明确 `transcript_path` 的格式不是稳定 Hook 接口，可能随版本变化。[Codex common fields 与子代理事件](https://learn.chatgpt.com/docs/hooks.md#common-input-fields)

当前可直接用于灯态的边界：

| 语义 | 稳定事件 | 注意点 |
| --- | --- | --- |
| executing | `UserPromptSubmit`；必要时 `PostToolUse` 表示工具完成后模型继续执行 | `PostToolUse` 不是整轮完成 |
| waiting | `PermissionRequest` | 是即将显示审批的强信号 |
| completed | 主代理 `Stop` | `Stop` 表示本轮停止，不是业务验收成功 |
| cleanup | `SessionEnd`；子代理 `SubagentStop` | `SessionEnd` 只用于主线程 |
| error | **无失败专用 Hook** | 失败命令仍会触发 `PostToolUse`，可从结构化 `tool_response` 判断“这一次工具失败”，但不能据此断言整轮或任务终止失败 |

需要特别指出：部分 2026 年 8 月中旬前的仓库仍写着“Codex 没有 `SessionEnd`”；当前官方文档已经列出并说明它会在正常关闭、归档/删除或长时间无人连接后执行。因此这些仓库的安装模板是历史快照，不是当前能力全集。

### Claude Code

Claude Code 的用户/项目/Plugin Hooks 也会在子代理内运行；子代理事件带 `agent_id`、`agent_type`，并有专门的 `SubagentStart` / `SubagentStop`。官方还提醒 transcript 异步写入，当前 Stop 的最终文本应读 `last_assistant_message`，而不是抢读 transcript。[公共字段与子代理字段](https://code.claude.com/docs/en/hooks#common-input-fields)；[SubagentStop](https://code.claude.com/docs/en/hooks#subagentstop)

| 语义 | 稳定事件 | 注意点 |
| --- | --- | --- |
| executing | `UserPromptSubmit`、`PreToolUse`、`PostToolUse` | `PostToolUse` 仅代表一次工具成功结束 |
| waiting | `PermissionRequest`；特定 `Notification` 类型；`Elicitation` | 优先使用专用事件，避免所有 Notification 都变等待 |
| completed | 主代理 `Stop` | 用户中断不会触发；有后台任务时不一定是真正静止 |
| error | `StopFailure`；可选 `PostToolUseFailure` | `StopFailure` 是 API 级终止；工具失败经常会被代理自行恢复 |
| cleanup | `SessionEnd`、`SubagentStop` | `SessionEnd` 有结构化退出原因 |

## 已知四个参考仓库

### 1. `Sora-bluesky/kbd-signal`

固定快照：[`e064221`](https://github.com/Sora-bluesky/kbd-signal/tree/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7)。

- 状态识别：没有常驻 executing 灯；正常键盘基线就是“非信号状态”。`PermissionRequest -> waiting`，主代理 `Stop -> done`，5 秒后恢复原灯效；`PostToolUse` 只释放对应 owner 的等待；`SubagentStop` 只清理子代理，不闪全局完成绿。[Hook reducer](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/kbd_signal/hooks.py)；[Codex Hook 模板](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/examples/codex-hooks.json)
- 失败来源：`error` 只是手动 `kbd-signal set error`，Claude/Codex 自动 Hook 都不会触发红灯。这一点在 README 中写得很明确。[状态表](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/README.md#what-each-signal-looks-like-states-in-configjson)
- 多会话/子代理：owner key 是 `product:session_id:agent_id|main`；等待 owner 是集合而不是单值。状态读改写由有界跨进程锁串行化，主会话完成只释放同一 session scope，其他会话或子代理仍可保持橙灯。[owner 身份与生命周期](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/kbd_signal/hooks.py)；[状态与锁](https://github.com/Sora-bluesky/kbd-signal/blob/e064221a7a7750c5fe4cd4b9e4674b7ed2e54bb7/kbd_signal/states.py)
- 异常恢复：waiting owner 采用墙钟和单调钟双重校验的一小时 TTL，并主动安排延迟唤醒；done 使用 generation token，旧计时器不能覆盖新状态。Hook 始终吞掉硬件故障，避免拖垮 agent。
- 硬件路径：每次状态切换由 Hook 进程直接通过 HIDAPI 打开 QMK/VIA Raw HID，先快照当前灯效，再写 RGB Matrix 值，最终恢复基线；不写 EEPROM。
- 可复用点：owner 集合、`generation` 防旧定时器、原子 `state.json`、短锁、基线快照/污染防护、等待 TTL。
- 局限：Hook 进程本身持有硬件，频繁打开 HID；没有 executing；仓库快照未配置 Codex `SessionEnd`，已落后于当前官方文档。

### 2. `geareab/OpenControl`

固定快照：[`1f94044`](https://github.com/geareab/OpenControl/tree/1f940442875f784f3df788a3be84e9d0a7433fa7)。

- 状态识别：Codex `UserPromptSubmit` / `PostToolUse -> executing`，`PermissionRequest -> waiting`，`Stop -> complete`；Claude 还把 `AskUserQuestion` 的 `PreToolUse` 和普通 `Notification` 视作 waiting。[Codex mapping](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/src/harness/codex.ts)；[Claude mapping](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/src/harness/claude.ts)
- 失败来源分三类：Claude `PostToolUseFailure` / `StopFailure` 是真实 Hook；Claude Notification 中包含 `error|failed|denied` 是明确标注的文本启发式；Codex 红灯来自 OpenControl **包装启动的 Codex 子进程非零退出**，wrapper 合成内部 `ProcessFailure`，不是 Codex Hook。[CLI 退出处理](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/src/cli.ts)；[内部事件处理](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/src/server.ts)
- 多会话：每个被 wrapper 启动的 agent process 占一个 task slot，最多六个硬件槽，更多进程可运行但无硬件键。每个 wrapper 当前只绑定一个 session；完成态带 `unread`，选择该槽后清为 idle。[TaskRegistry](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/src/state.ts)
- 子代理：没有安装 `SubagentStart` / `SubagentStop`，也没有按 `agent_id` 建 owner，因此不能独立显示同一主会话内的子代理。它的“六任务”是六个 wrapper 进程，不是六个 subagent。
- 硬件路径：常驻 host 独占硬件；Hook 通过带随机 bearer token 的 loopback HTTP 报状态。增强 QMK 固件使用 32-byte Raw HID 自定义协议覆盖六个 Agent key；也支持 DualSense 灯条/玩家灯。固件 5 秒收不到 heartbeat 会移除 overlay，恢复用户 RGB 动画。[架构](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/docs/architecture.md)；[QMK feedback](https://github.com/geareab/OpenControl/blob/1f940442875f784f3df788a3be84e9d0a7433fa7/firmware/modules/opencontrol/opencontrol.c)
- 可复用点：常驻 companion 单一硬件所有者、wrapper exit code 作为独立错误域、完成未读态、设备 heartbeat fail-safe、能力握手而不是只认 VID/PID。
- 局限：必须通过 wrapper 启动 agent 才能得到 Codex 进程失败和 slot；Claude Notification 文本红灯不是事实事件；需要自定义 QMK 固件才能做逐键 overlay。

### 3. `latent-spaces/cled`

固定快照：[`7f70388`](https://github.com/latent-spaces/cled/tree/7f7038802cccc50dca030c1a454c70a3ae1e3d8d)。

- 状态识别：完全不用 Hooks。Claude 轮询 `~/.claude/sessions/<pid>.json`，只有 `status == busy` 算 busy，`idle` 或 `waiting` 等其余状态一律映射为 idle；因此 README 所说“waiting on you”在源码里没有独立颜色。Codex 通过 iTerm 前台 PID、`lsof`、`state_5.sqlite` 和 rollout JSONL 定位活动会话；倒序扫描尾部，用户消息/函数调用/函数输出/reasoning 算 mid-turn，assistant message 算 idle。[tab/status provider](https://github.com/latent-spaces/cled/blob/7f7038802cccc50dca030c1a454c70a3ae1e3d8d/src/cled/agent_tabs.py)
- completed/error：都没有。20 分钟文件未更新显示 stale yellow；它只是“文件旧”，不是失败。
- 多会话：显示当前聚焦 iTerm2 窗口最多十个 tab，各 tab 独立；不是跨终端的全局会话注册表。没有子代理显示。
- 失败来源：无红色错误语义。Codex busy/idle 完全来自内部 rollout 内容形状，官方已明确 transcript/rollout 不是稳定 Hook 接口。
- 硬件路径：常驻 daemon 以 10 FPS 向本机 OpenRGB server 推整帧键位颜色；数字行显示 agent tabs，数字键盘/功能键另显示 CPU/RAM。[renderer](https://github.com/latent-spaces/cled/blob/7f7038802cccc50dca030c1a454c70a3ae1e3d8d/src/cled/cled.py)；[OpenRGB transport](https://github.com/latent-spaces/cled/blob/7f7038802cccc50dca030c1a454c70a3ae1e3d8d/src/cled/rgb.py)
- 可复用点：polling provider 隔离、按 terminal tab 展示多个会话、OpenRGB 常驻连接与睡眠后重连。
- 局限：强耦合 iTerm2、macOS、Codex 私有数据库/rollout、Claude 私有 session 文件；不能可靠表示 waiting/completed/error。

### 4. `caique-lima/claude-keyboard-notification`

固定快照：[`e74b19a`](https://github.com/caique-lima/claude-keyboard-notification/tree/e74b19a3f934b4c2a1e0c420457fdcc14a8d544b)。

- 状态识别：只实现“需要你”与“无信号”。所有 `Notification` 都创建对应 session 的等待文件并启动闪烁；`PreToolUse`、`PostToolUse`、`UserPromptSubmit`、`Stop`、`SessionEnd` 删除该 session 的等待文件，无剩余 owner 才熄灯。[README 状态表](https://github.com/caique-lima/claude-keyboard-notification/blob/e74b19a3f934b4c2a1e0c420457fdcc14a8d544b/README.md#how-it-works)；[安装模板](https://github.com/caique-lima/claude-keyboard-notification/blob/e74b19a3f934b4c2a1e0c420457fdcc14a8d544b/setup.sh)
- executing/completed/error：均不表达。Notification 没按 `permission_prompt` 过滤，可能把非交互通知误判为等待。
- 多会话：每个 `session_id` 一个文件；文件记录父 Claude PID，死 PID 立即清理，否则 15 分钟过期。这个 refcount 思路有效，但文件写入和枚举没有跨进程锁，存在并发窗口。[状态文件与 HID](https://github.com/caique-lima/claude-keyboard-notification/blob/e74b19a3f934b4c2a1e0c420457fdcc14a8d544b/via_hid.py)
- 子代理：没有读取 `agent_id`，同一父 session 的多个子代理会折叠到一个文件。
- 硬件路径：后台 `flash` 进程长期独占 Keychron QMK/VIA Raw HID；Hook 通过 `pgrep` / `pkill` 管理它。写整键盘 RGB Matrix effect/color/brightness，不能逐键。
- 可复用点：最小化 per-session refcount、PID liveness + TTL 清理、持续动画由常驻进程承担。
- 局限：通过进程名杀 flasher、无锁、硬编码 Keychron VID/通道、Hook 和硬件进程边界较脆弱。

## 其他相关开源项目

### 5. `andyiac/cc-lights`：macOS 菜单栏多会话灯

固定快照：[`c27a1a6`](https://github.com/andyiac/cc-lights/tree/c27a1a615b7051683a620bf2e43f3d141605f2de)。

- Claude：`UserPromptSubmit` / tool hooks -> working，限定为 `permission_prompt` / `elicitation_dialog` 的 Notification -> waiting，`Stop -> idle`，真实 `StopFailure -> error`，`SessionEnd -> remove`。[Claude 安装器](https://github.com/andyiac/cc-lights/blob/c27a1a615b7051683a620bf2e43f3d141605f2de/Sources/ClaudeCodeStatusLight/main.swift)
- Codex：working/waiting/idle/remove 都来自真实 Hook；安装器没有 Codex error 映射，与当前官方能力一致。同一个 CLI 帮助文字提到 `StopFailure`，但实际 Codex 配置没有注册它。[Codex 安装器](https://github.com/andyiac/cc-lights/blob/c27a1a615b7051683a620bf2e43f3d141605f2de/Sources/ClaudeCodeStatusLight/main.swift)
- 多会话：每个 `session_id` 一个 JSON 文件，菜单栏逐会话展示；24 小时清理幽灵会话。没有使用 `agent_id`，因此不独立显示子代理。[状态模型](https://github.com/andyiac/cc-lights/blob/c27a1a615b7051683a620bf2e43f3d141605f2de/Sources/StatusLightCore/StatusPayload.swift)；[文件存储](https://github.com/andyiac/cc-lights/blob/c27a1a615b7051683a620bf2e43f3d141605f2de/Sources/StatusLightCore/StatusFileStore.swift)
- 输出路径：Hook CLI 原子更新状态文件，App 用目录 watcher 更新多个 NSStatusItem；不控制实体硬件。
- 可复用点：Hook 只写文件、UI 只监听文件；Claude/Codex 能力分开配置；等待 Notification 使用精确 matcher。

### 6. `DGPRoman/claude-status`：ESP32-C3 OLED + 单色灯

固定快照：[`4e9976d`](https://github.com/DGPRoman/claude-status/tree/4e9976d439b210352859b692e624d346bed93033)。

- 状态：`UserPromptSubmit` / `PreToolUse` / `PostToolUse -> work`，`PermissionRequest -> perm`，`Stop -> off`；故意不显示完成或错误。[Hook 模板](https://github.com/DGPRoman/claude-status/blob/4e9976d439b210352859b692e624d346bed93033/claude-hooks.snippet.json)
- 等待信号质量很高：`PermissionRequest` 是唯一 CONFIRM 真源；延迟 5–7 秒到达的 permission Notification 被忽略，其他 Notification 才转 off，避免旧通知把已经批准的等待重新点亮。[聚合脚本](https://github.com/DGPRoman/claude-status/blob/4e9976d439b210352859b692e624d346bed93033/hooks/claude-status.sh)
- 多会话：每个 `session_id` 文件，`flock` 下按 `perm > work > off` 归约，并显示最高状态的 session 数；`SessionEnd` 删除，默认一小时 TTL 回收。没有 `agent_id`，子代理折叠进父会话。
- 硬件路径：Hook 直接在锁内向 USB serial 写 `state|count`，或经带 token 的本地 Wi-Fi HTTP 发到 ESP32；所有 I/O 有一秒上限。固件用 OLED 显示 WORK/CONFIRM，单色 LED 用呼吸/快闪，BOOT 键可确认提醒。[固件](https://github.com/DGPRoman/claude-status/blob/4e9976d439b210352859b692e624d346bed93033/src/main.cpp)
- 可复用点：共享灯优先级、精确等待真源、重复相同 CONFIRM 不重新报警、物理确认只消音不篡改业务状态。

### 7. `dpf202507/Codex-Light`：RP2040 三灯 + host daemon

固定快照：[`4dda2f6`](https://github.com/dpf202507/Codex-Light/tree/4dda2f68074eacbc68bf713d441499b83a252ee7)。

- 状态：`UserPromptSubmit` / tool / SessionStart -> busy；Permission/Notification -> waiting；Stop/SessionEnd -> done；StopFailure/PostToolUseFailure/Error -> error；其他 payload 还会按连接/API/超时词组做文本启发式。[Hook mapper](https://github.com/dpf202507/Codex-Light/blob/4dda2f68074eacbc68bf713d441499b83a252ee7/software/host/agent_light/hooks.py)
- Codex 红灯有配置与事实冲突：模板注册了 Codex `StopFailure`，但同仓库 Codex 指南又写“错误不单独亮灯，查看日志”；当前官方 Codex 也没有该事件。因此不能把它算作已实现的真实 Codex 失败信号。[Codex 模板](https://github.com/dpf202507/Codex-Light/blob/4dda2f68074eacbc68bf713d441499b83a252ee7/integrations/codex/hooks.json)；[集成说明](https://github.com/dpf202507/Codex-Light/blob/4dda2f68074eacbc68bf713d441499b83a252ee7/docs/codex-integration.md)
- 多会话：daemon 内保存 session map，按 `error > waiting > busy > done > idle` 归约并设 TTL。但 `_clear_stale_states_for_source` 会在同一来源新阶段到来时删除该来源其他 session 的旧阶段，因此它不是严格的独立多会话 owner 模型。[聚合器](https://github.com/dpf202507/Codex-Light/blob/4dda2f68074eacbc68bf713d441499b83a252ee7/software/host/agent_light/state.py)
- 子代理：session id 可聚合，但不读取 `agent_id`。
- 硬件路径：Hook -> loopback TCP daemon -> 长连 USB serial -> RP2040-Zero + 三颗 SK6812 RGBW。固件自身执行 TTL；协议保留 error，但固件故意不为 error 点灯。[daemon](https://github.com/dpf202507/Codex-Light/blob/4dda2f68074eacbc68bf713d441499b83a252ee7/software/host/agent_light/daemon.py)；[固件](https://github.com/dpf202507/Codex-Light/blob/4dda2f68074eacbc68bf713d441499b83a252ee7/firmware/rp2040-zero/src/main.cpp)
- 可复用点：Hook/daemon/firmware 三层协议、host 与设备双 TTL、最短 busy 可见时间、相同活跃状态刷新硬件租约。

### 8. `eternityspring/agent-light`：Arduino 交通灯

固定快照：[`348d8bd`](https://github.com/eternityspring/agent-light/tree/348d8bdba44740f44069ea156e712dae3093024e)。

- 状态：`UserPromptSubmit -> thinking`，`PreToolUse -> running`，`PostToolUse -> thinking`，`Stop -> idle`。没有 waiting、completed 或 error。[Hook 模板](https://github.com/eternityspring/agent-light/blob/348d8bdba44740f44069ea156e712dae3093024e/claude-settings-snippet.json)
- 多会话/子代理：Hook client 完全不读 stdin，最后事件覆盖全局灯，均不支持。
- 硬件路径：短命 Hook client 经 loopback TCP 发一个命令，常驻 Node bridge 保持 serial 并转给 Arduino；另有轮询 `/tmp/claude-traffic-light` 的软件交通灯。[Hook client](https://github.com/eternityspring/agent-light/blob/348d8bdba44740f44069ea156e712dae3093024e/hook-client.mjs)；[serial bridge](https://github.com/eternityspring/agent-light/blob/348d8bdba44740f44069ea156e712dae3093024e/serial-bridge.mjs)
- 可复用点：Hook fire-and-forget、bridge 单一串口所有者；状态机本身不适合多会话产品。

### 9. `reshadat/claude-glow`：Tuya/Halonix 环境灯

固定快照：[`a6d4f54`](https://github.com/reshadat/claude-glow/tree/a6d4f54da6f1a314cf327ac3665a18491c747f1a)。

- 状态：PreToolUse thinking、PostToolUse tool-done、所有 Notification waiting、Stop idle；error 仅手动或自行接线。[Hook 模板](https://github.com/reshadat/claude-glow/blob/a6d4f54da6f1a314cf327ac3665a18491c747f1a/hooks.example.json)
- 失败来源：README 说 Claude Code 没有错误 Hook，这已被当前官方 `StopFailure` / `PostToolUseFailure` 文档淘汰，说明此类 README 结论必须按版本复核。[README](https://github.com/reshadat/claude-glow/blob/a6d4f54da6f1a314cf327ac3665a18491c747f1a/README.md#wiring-into-claude-code)
- 多会话/子代理：不读 session 或 agent id，最后 Hook 覆盖全局灯；单一 `.pulser.pid`。
- 硬件路径：每个 Hook 直接通过 TinyTuya 本地 LAN 控灯；waiting 另起 detached pulser，最多 300 秒后保持常亮。没有云控制闭环，但首次需获取 local key。[控制实现](https://github.com/reshadat/claude-glow/blob/a6d4f54da6f1a314cf327ac3665a18491c747f1a/glow.py)
- 可复用点：硬件错误始终 exit 0、动画交给后台进程、有上限的闪烁；状态聚合不适合复用。

### 10. `DevVig/microbridge`：Codex Micro 状态总线

固定快照：[`fcd0aba`](https://github.com/DevVig/microbridge/tree/fcd0aba7a4fa360ca8690681bd7b049fa3682f10)。

- 状态识别不是 Codex Hook：常驻 adapter 监听 `~/.codex/sessions` rollout JSONL；`task_started -> working`、`task_complete -> done`、`turn_aborted -> error`，事件名包含 approval/permission -> awaiting approval，agent reasoning -> thinking。[Codex watcher](https://github.com/DevVig/microbridge/blob/fcd0aba7a4fa360ca8690681bd7b049fa3682f10/crates/mb-adapters/src/codex.rs)
- Claude 也监听 `~/.claude/projects` 日志并读取 `status/state` 文本；其 PermissionRequest Hook 主要用于把硬件 Approve/Reject 动作回送 Claude，而非完整状态来源。[Claude watcher](https://github.com/DevVig/microbridge/blob/fcd0aba7a4fa360ca8690681bd7b049fa3682f10/crates/mb-adapters/src/claude.rs)；[Permission bridge](https://github.com/DevVig/microbridge/blob/fcd0aba7a4fa360ca8690681bd7b049fa3682f10/adapters/claude/hooks/microbridge-permission.mjs)
- 失败来源：Codex `turn_aborted` 和 Claude `status=error/failed` 来自私有日志结构，不是稳定公开 Hook；比自然语言搜索强，但仍有版本耦合。
- 多会话：daemon 有统一 registry、焦点和六个 agent key；等待可抢占焦点。Codex/Claude watcher明确跳过 subagent 日志，因此只展示顶层会话，不支持独立子代理灯。[registry](https://github.com/DevVig/microbridge/blob/fcd0aba7a4fa360ca8690681bd7b049fa3682f10/crates/microbridged/src/registry.rs)
- 硬件路径：daemon 独占 Work Louder Codex Micro，发送 `v.oai.thstatus` JSON-RPC over 64-byte vendor HID，实现六键逐状态 RGB/动画；这是逆向的专用设备协议，不是通用 VIA。[LED mapping](https://github.com/DevVig/microbridge/blob/fcd0aba7a4fa360ca8690681bd7b049fa3682f10/crates/mb-device/src/lighting.rs)；[HID notes](https://github.com/DevVig/microbridge/blob/fcd0aba7a4fa360ca8690681bd7b049fa3682f10/docs/device-hid.md)
- 可复用点：agent integration 只发布语义状态、焦点策略统一裁决、device layer 单一写入者、六槽状态独立；不应复用其私有 rollout 解析作为 Keyphore 首版真源。

### 11. `yzhao062/vibesignal`：Busylight 多会话聚合

固定快照：[`da5e44e`](https://github.com/yzhao062/vibesignal/tree/da5e44e355251f639d3221696a707855dc62fad7)。

- 状态路径：Claude/Codex Hook 为每个 `(agent, session)` 写原子状态文件，resolver 再按 `idle < working < done < error < blocked` 聚合，常驻进程通过 `busylight-core` 控制兼容设备。[Claude Hook 模板](https://github.com/yzhao062/vibesignal/blob/da5e44e355251f639d3221696a707855dc62fad7/hooks/claude-settings.snippet.json)；[Codex Hook 模板](https://github.com/yzhao062/vibesignal/blob/da5e44e355251f639d3221696a707855dc62fad7/hooks/codex-hooks.snippet.json)；[store](https://github.com/yzhao062/vibesignal/blob/da5e44e355251f639d3221696a707855dc62fad7/vibesignal/store.py)；[resolver](https://github.com/yzhao062/vibesignal/blob/da5e44e355251f639d3221696a707855dc62fad7/vibesignal/resolve.py)
- 多会话：短锁、原子替换、按状态 TTL 和 session 粒度是强项；但没有把 `agent_id` 纳入 owner，子代理仍折叠。
- 失败语义：模型和优先级虽有 error，当前模板却把 Claude `StopFailure` 映成 done，Codex 也没有失败 Hook，所以不能把自动红灯当作已经兑现。
- 可复用点：状态文件 schema、分状态 TTL、纯 reducer 与硬件 adapter 解耦；应补上 `agent_id` 和准确的 Claude failure mapping。

### 12. `PG408/codex-status-bar`：Codex 菜单栏并发状态机

固定快照：[`232beee`](https://github.com/PG408/codex-status-bar/tree/232beee62968d91a7fd0905836aef73f31fbcd82)。

- 状态路径：Hook writer 把事件归入每 session 的 `state.d`，Swift App 维护主代理和子代理 facts，再跨会话按 `permission > needs_input > active > done` 归约。[事件状态机文档](https://github.com/PG408/codex-status-bar/blob/232beee62968d91a7fd0905836aef73f31fbcd82/docs/hook-events.md)；[writer](https://github.com/PG408/codex-status-bar/blob/232beee62968d91a7fd0905836aef73f31fbcd82/scripts/codex-status-writer.js)；[终态/liveness 规则](https://github.com/PG408/codex-status-bar/blob/232beee62968d91a7fd0905836aef73f31fbcd82/Sources/SessionStateRules.swift)
- 多会话/子代理：以 `agent_id`、`turn_id` 区分 facts；同 session 的 turn guard 会拒绝迟到事件，`SubagentStop` 只完成对应 child。这是所查项目中最完整的 Codex 并发 reducer 参考之一。
- 失败语义：没有注册失败事件，也没有红灯；符合 Codex 当前公开 Hook 的边界。
- 输出路径：Hook -> per-session 文件 -> macOS 菜单栏，不控制硬件。可直接借状态层，但设备连接仍应由 Keyphore companion 自己实现。

### 13. `Pixelmoss/codex-kick75-status-lights`：NuPhyIO 原厂固件 + macOS USB HID

固定快照：[`e32648e`](https://github.com/Pixelmoss/codex-kick75-status-lights/tree/e32648ee86a8a729734060ac09bd7f8a1213876f)。同名的 [`zhangzw16/codex-kick75-status-lights`](https://github.com/zhangzw16/codex-kick75-status-lights) 是继续开发的分支，已经加入三任务槽、番茄钟和实验性蓝牙固件；以下先以侵入性较低、无需刷固件的 Pixelmoss 版本为主。

- 状态路径：安装器合并 `UserPromptSubmit`、`PermissionRequest`、`PostToolUse`、`Stop`、`SessionEnd` 五个官方 Codex Hook；短命 Python Hook 只保留事件名、`session_id`、`turn_id` 和工具失败布尔值，再通过 250 ms 超时的 Unix socket 发给用户级 LaunchAgent。[Hook client](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/src/codex_kick75_hook.py)；[安装器](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/scripts/install.py)
- 状态语义：`UserPromptSubmit -> running`，`PermissionRequest -> permission`，`Stop -> completed`，`SessionEnd` 删除会话。`PostToolUse.tool_response` 中明确的非零退出码、`isError`、`failed`、`success=false` 等会变成粘性 `tool_failure`；后续成功的 `PostToolUse` 才恢复 running。全局归约为 `tool failure > permission > running > completed > idle`。[结构化失败识别](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/src/codex_kick75_common.py)；[聚合器](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/src/codex_kick75_daemon.py)
- 失败边界：它的红灯表示“最近一次明确工具调用失败或等待权限”，不是 Codex 终局任务失败。这个结构化判断比扫描 `last_assistant_message` 可靠，但仍不能直接兑现本项目的 failure signal；代理可能在一次失败后自行恢复，`Stop` 也没有成功/失败字段。
- 多会话/子代理：按 `session_id` 保存多任务，避免最后事件覆盖全部状态；但是没有注册 `SubagentStart` / `SubagentStop`，没有把 `agent_id` 纳入 owner。虽然保存了 `turn_id`，reducer 没用它拒绝迟到事件，因此仍应采用 `codex-status-bar` 的 turn guard，而不是原样复制。
- 硬件路径：LaunchAgent 是唯一 HID owner。原生 C helper 直接使用 IOKit 打开 Kick75 IO 的 64-byte Raw HID 接口，执行 NuPhyIO `0xee` 临时会话、`0xd5` 读取灯态、`0xd6` 局部写灯态；只改 17-byte 灯态中地址 9、长度 8 的侧灯片段。它在第一次接管时保存原始 8 字节，空闲时原样恢复，并通过周期回读修复 USB 重连或键盘复位后的状态丢失。[协议说明](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/docs/PROTOCOL.md)；[IOKit helper](https://github.com/Pixelmoss/codex-kick75-status-lights/blob/e32648ee86a8a729734060ac09bd7f8a1213876f/src/kick75_ledctl.c)
- 对 Air65 V3 的价值：这是与本项目最接近的 **NuPhyIO 传输和进程生命周期参考**。64-byte 帧、临时会话、读后局部写、ACK 校验、单一 HID owner 和重连重放都值得复用；Kick75 的 `19f5:1026`、侧灯地址 9/长度 8 和五灯效果不能照搬。Air65 V3 必须使用已经实测的设备选择与主键区命令，而且 signal-off state 仍应熄灭主键区，不恢复用户原灯效。
- 无线分支：zhangzw16 版本证实原厂固件即使在蓝牙档且 USB 线仍连接，`0xd6` ACK 和回读都可能成功，但无线渲染层会覆盖实际 LED；它通过逆向并修改指定 Kick75 固件，让标准蓝牙 LED output report 携带状态，再由固件本地渲染。[固件研究记录](https://github.com/zhangzw16/codex-kick75-status-lights/blob/7485341c70e997f33121e9f0081207a2e0334aa7/docs/FIRMWARE_RESEARCH.md) 这条路线需要型号专用固件、完整刷写与实机回归，不适合 Air65 V3 首版，也不能把 Kick75 镜像或地址移植到 Air65。

### 14. `royzjq/agent-status-lights`：QMK/VIA 能力探测 + 动作语义

固定快照：[`83595b7`](https://github.com/royzjq/agent-status-lights/tree/83595b7f062e9c7d453f6ece25756477e886be68)。项目实测目标是 macOS + NuPhy Halo75 V2 QMK/VIA，不是 Air65 V3 的 NuPhyIO 固件线。

- 状态路径：Claude Code 注册七个 Hook，其中 `PostToolUseFailure` / `StopFailure -> failure`；Codex 只注册 `UserPromptSubmit`、`PermissionRequest`、`PostToolUse`、`Stop`、`SessionEnd` 五个事件，明确不显示红灯。C Hook 把 stdin 原始 JSON 以 250 ms 上限发给 Unix socket；daemon 只保留 `hook_event_name` 与 `session_id`。[Hook client](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/src/halo75_hook.c)；[安装器与 Codex 事件表](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/scripts/install.py)
- 状态语义：每 session 跟踪后按 `failure > permission > running > completed > idle` 归约。Claude 工具失败只红闪 4 秒，因为非零 Bash、`grep` 无匹配等常见事件并不代表任务终止；completed 保持 10 秒，活跃状态 30 分钟无事件丢弃，其他会话 12 小时回收。Codex 没有专用失败事件，因此永不自动红。[聚合器](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/src/claude_halo75_daemon.py)；[多会话和 Agent 边界](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/docs/AGENTS.md)
- 视觉设计：状态主要由运动而不是颜色区分：执行彗星/色带、等待整区脉冲、失败快闪、完成扫动填满。这个原则适合 Air65 V3 主键区，可落成“蓝色流动或呼吸、橙色整体脉冲、红色快闪、绿色短时静态/呼吸”；具体可用效果必须以 Air65 V3 NuPhyIO 已验证 effect 表为准，不能照搬 QMK effect id。
- 多会话/子代理：只有 `session_id`，没有 `agent_id`、`turn_id` 和子代理 Hook，因此不如 `kbd-signal` / `codex-status-bar` 的 owner 模型。它的 Unix socket 是唯一事件通路；daemon 不在线时事件直接丢失，也不满足本项目先写 durable status 的决定。
- 硬件路径：默认只控制原厂 VIA 可访问的 RGB Matrix；Halo 外圈必须刷 QMK 补丁增加 vendor channel `0x10`。它不写死 VID/PID，而是按 VIA usage page `0xFF60` / usage `0x61` 枚举并安全扫 lighting channel；这套发现方式不能直接用于 NuPhyIO，但“按能力探测、未知设备拒绝写入”值得保留。[只读能力扫描](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/src/via_scan.c)；[固件边界](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/firmware/README.md)
- 最重要的 HID 经验：macOS 在非独占打开 VIA Raw HID 时，会把输入报告送给所有打开该设备的进程。该项目实测 12 个并发 reader 时 11 个结果不同、没有一个正确；修复方式是按命令、channel、value id 的回显前缀筛选自己的 response。[并发响应匹配记录](https://github.com/royzjq/agent-status-lights/blob/83595b7f062e9c7d453f6ece25756477e886be68/docs/PROTOCOL.md) Air65 V3 的 NuPhyIO adapter 同样应校验方向、命令、地址/长度和校验和，不能只读取“下一帧”。
- 远程会话：可选 Orca bridge 轮询终端标题/预览，能粗略得到执行、等待、完成，无法得到失败。它默认关闭且会读取终端预览；本项目追求独立、稳定、隐私收敛的本机 Codex Hook，因此不应把这条路径纳入首版。

## 横向对比

| 项目 | 状态来源 | executing | waiting | completed | error 真源 | 多会话 | 子代理 | 输出路径 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| kbd-signal | Hooks | 基线/不显示 | `PermissionRequest` | `Stop`，5 秒 | 手动，无自动失败 | owner 集合 | 按 `agent_id` 清理 | Hook -> VIA Raw HID |
| OpenControl | Hooks + wrapper | prompt/tool | permission/question | `Stop` unread | Claude failure Hook；CLI 非零退出；部分文本启发 | 六 wrapper 槽 | 否 | Hook -> HTTP host -> QMK/DualSense |
| cled | 私有 session/rollout 轮询 | busy/mid-turn | 不独立 | idle 推断 | 无 | 当前 iTerm 窗口十 tab | 否 | daemon -> OpenRGB |
| claude-keyboard-notification | Hooks | 不显示 | 所有 Notification | 熄灯 | 无 | per-session 文件 | 折叠 | Hook/background flasher -> VIA HID |
| CC Lights | Hooks | working | 精确 Notification / Permission | `Stop` idle | Claude `StopFailure`；Codex 无 | per-session 文件/UI | 折叠 | Hook -> JSON -> 菜单栏 |
| claude-status | Hooks | work | `PermissionRequest` | 熄灯 | 无 | 锁下优先级聚合 | 折叠 | Hook -> serial/Wi-Fi -> ESP32 |
| Codex-Light | Hooks + 文本 | busy | Permission/Notification | Stop done | Claude Hook；Codex 模板无效；文本启发 | 有聚合但同来源互清 | 折叠 | Hook -> TCP daemon -> serial RP2040 |
| agent-light | Hooks | thinking/running | 无 | idle | 无 | 否 | 否 | Hook -> TCP bridge -> Arduino |
| claude-glow | Hooks | thinking/tool-done | 所有 Notification | idle | 手动；README 已过时 | 否 | 否 | Hook -> Tuya LAN |
| Microbridge | 私有日志 watcher | task/status | approval 名称/状态 | task_complete | 私有 `turn_aborted`/status | registry 六键 | 明确排除 | daemon -> Codex Micro vendor HID |
| VibeSignal | Hooks | working | blocked | done | schema 有、模板未可靠接入 | per-session 原子文件 | 折叠 | Hook -> resolver -> busylight |
| codex-status-bar | Hooks | active | permission/needs_input | done | 无 | per-session facts | 按 `agent_id` | Hook -> state.d -> 菜单栏 |
| Codex Kick75 Status Lights | Hooks | running | permission | completed | 结构化单次工具失败，非终局失败 | per-session daemon | 折叠 | Hook -> Unix socket -> LaunchAgent -> NuPhyIO Raw HID |
| agent-status-lights | Hooks + 可选 Orca 轮询 | running | permission/预览启发 | completed | Claude failure Hook；Codex 无 | per-session daemon | 折叠 | Hook -> Unix socket -> LaunchAgent -> VIA；可选自定义 QMK |

## 对 Keyphore 独立项目的建议

### 状态真源

- Hook reducer 只接受结构化事件名和结构化字段，不读取 `last_assistant_message`、Notification message 或 rollout 文本来判断成功/失败。Codex `PostToolUse.tool_response` 可形成短暂的 `tool_error` 诊断信号，但不能升级为 terminal `error`。
- Codex：首版发布 `executing -> waiting -> completed -> off`。红色保留为协议/配置状态，但只用于 companion/硬件故障诊断；若未来官方增加失败 Hook再接入。
- Claude Code 若以后支持：`StopFailure` 可可靠映射 terminal error；`PostToolUseFailure` 更适合短暂诊断事件，不建议直接变成粘性“任务失败”，因为代理通常会继续修复。
- 若产品以后提供显式 `keyphore run codex -- ...` wrapper，可以增加独立的 `process_error`：仅当被包装进程非零退出时红灯。UI/文档必须称“进程失败”，不能称“任务失败”。

### reducer 与聚合

owner key 建议固定为：

```text
{product}:{session_id}:{agent_id || main}
```

状态归约建议：

```text
waiting(any owner) > error > executing(any owner) > completed(recent) > off
```

关键转移：

| 事件 | owner 操作 | 聚合效果 |
| --- | --- | --- |
| `SessionStart` / `UserPromptSubmit` | 清同 session 的陈旧 owner，main=executing | 蓝 |
| `SubagentStart` | child=executing | 仍蓝，不改变任务完成语义 |
| `PermissionRequest` | 对精确 owner 加 waiting | 任一 owner 等待即橙 |
| `PostToolUse` | 只释放该 owner 的 waiting；仍 executing | 其他 owner 等待则继续橙 |
| `SubagentStop` | 删除该 child owner | 不闪全局绿 |
| main `Stop` | 删除同 session 子 owner，main=completed | 没有其他 waiting/executing 才绿 |
| `SessionEnd` | 删除整个 session scope | 重新归约或熄灭 |
| Claude `StopFailure` / wrapper 非零退出 | 精确 session=error | 红色粘性或限时，需明确错误域 |

### 持久化与硬件边界

- Hook 在短锁内原子更新 `state.json` 后立即退出；Hook 永远不直接打开 Air65 V3。
- companion 是唯一 HID owner，监听状态文件并驱动键盘；硬件断开不能反向让 Hook 失败。
- 每次写入增加 `generation`；5 秒完成恢复和一小时等待过期都携带 generation，旧 timer 不得覆盖新状态。
- waiting owner 同时记录 wall-clock 与 monotonic time，避免调时或睡眠造成误过期。
- companion 对硬件输出维持 heartbeat/lease；进程死亡或心跳超时时恢复用户原灯效，而不是把最后一个状态永久留在键盘上。
- 保留 signal 之前的完整基线，并防止崩溃后把残留信号误采为新基线。这个细节 `kbd-signal` 已经用真实设备问题验证过。
- NuPhyIO response 必须按方向、命令、地址/长度和校验和匹配当前 request；不能假设读到的下一帧就是自己的 ACK。即使 companion 是设计上的唯一 owner，也要防止 NuPhyIO 网页或诊断工具同时打开设备。

## 取舍结论

最合适的首版不是复制某一个仓库，而是采用以下组合：

- **事件语义**：官方 Codex Hooks；不轮询 rollout。
- **并发模型**：`kbd-signal` 式 `{session, agent}` owner 集合，加 `codex-status-bar` 的 `turn_id` 陈旧事件防护。
- **进程分工**：`CC Lights` 式 Hook 只写持久状态，`OpenControl` 式 companion 独占硬件。
- **优先级与去抖**：`claude-status` 的等待优先、精确信号和迟到事件抑制。
- **设备安全**：`OpenControl` 的 heartbeat fail-safe，加 `kbd-signal` 的用户灯效基线恢复。
- **NuPhyIO 实现**：以 `codex-kick75-status-lights` 交叉验证 macOS IOKit 帧、ACK、局部写和重连重放，但只移植协议模式，不照搬 Kick75 PID、侧灯偏移或恢复语义。
- **视觉语义**：采用 `agent-status-lights` 的“运动优先、颜色强化”，但只选择 Air65 V3 原厂 NuPhyIO 已验证的主键区效果，不为首版刷固件。
- **红灯**：Codex 首版不自动表示任务失败；只在有结构化失败事件或明确 wrapper 退出码后启用。
