# Keyphore

Keyphore maps Codex task signals onto a dedicated NuPhy Air65 V3 lighting profile that stays off when no Codex signal is active.

## Language

**Codex status light model**:
A global model in which the keyboard shows the current aggregate Codex task state and turns the signal surface off when no task state is active.
_Avoid_: Notification light model, task panel

**Execution signal**:
A task state indicating that at least one Codex task is actively executing; it remains active until a later lifecycle event changes that task's state.
_Avoid_: Working state, busy mode

**Attention signal**:
A task state that currently requires the user to approve or provide input; each signal owner releases independently, with a one-hour stale-owner limit.
_Avoid_: Waiting task, blocked state

**Completion signal**:
A five-second indication that a Codex turn completed successfully before the aggregate state is recomputed.
_Avoid_: Idle state, success mode

**Failure signal**:
A persistent indication that a task failed or was interrupted, cleared when that task starts again or by an explicit restore.
_Avoid_: Error light, warning mode

**Signal-off state**:
The unlit main key backlight shown when no Codex task signal is active; it does not restore or depend on the user's other lighting effects.
_Avoid_: Baseline lighting, default lighting, idle lighting

**Codex lighting profile**:
The independent set of task-signal effects owned by this integration, separate from the keyboard's other lighting effects.
_Avoid_: Keyboard profile, RGB preset

**Hook owner**:
The component installed and managed by this project to receive privacy-allowlisted Codex lifecycle events for the keyboard status light. It is independent of Hook handlers owned by other products.
_Avoid_: ZECTRIX Hook, shared Hook

**Status core**:
The source-independent model that reduces normalized Codex lifecycle events into per-owner states and the aggregate state displayed by the keyboard.
_Avoid_: ZECTRIX adapter, keyboard driver

**Signal owner**:
The Codex session or agent responsible for an active attention signal; every owner must be released independently before the aggregate state can leave attention.
_Avoid_: Active task, light owner

**Aggregate state**:
The single state displayed across the main backlight after combining all tracked Codex tasks with the priority attention, failure, execution, completion, then signal-off.
_Avoid_: Current task state, latest state

**Signal surface**:
The Air65 V3 main key backlight used by the first version to display notification signals; the rhythm light bar remains outside the signal surface.
_Avoid_: Lighting zone, status LEDs

**Verified transport**:
The wired USB HID connection to an Air65 V3 on macOS, which is the only device-control path claimed by the first release. A 2.4 GHz receiver remains an unverified future transport, while Bluetooth control is outside the first-release scope.
_Avoid_: Wireless support, all NuPhyIO devices

**NuPhyIO adapter**:
The minimal in-process hardware boundary that translates lighting states into the verified Air65 V3 USB HID protocol. It is not a general replacement for NuPhyIO or `nuphyctl`.
_Avoid_: nuphyctl process, keyboard SDK

**Plugin**:
The independently installed Codex distribution unit that owns setup, updates, diagnostics, Hooks, and the bundled companion.
_Avoid_: Companion, standalone script

**Companion**:
The plugin's background process that maintains the status core and applies aggregate states through the NuPhyIO adapter. It never depends on ZECTRIX at runtime.
_Avoid_: Plugin, Hook handler

**Durable status**:
The atomically persisted per-owner state written by Hook handlers and consumed by the companion as the local source of truth across process restarts.
_Avoid_: Event log, diagnostic log, keyboard state
