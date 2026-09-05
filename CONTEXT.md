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
An indication that a Codex turn completed successfully, shown for the configured completion display duration before the aggregate state is recomputed.
_Avoid_: Idle state, success mode

**Completion display duration**:
The user-selected time from one through sixty seconds for which a completion signal remains visible before the aggregate state is recomputed. It defaults to five seconds and does not time-limit execution or attention signals.
_Avoid_: Signal timeout, task timeout, stale-owner limit

**Signal-off state**:
The unlit main key backlight shown when no Codex task signal is active; it does not restore or depend on the user's other lighting effects.
_Avoid_: Baseline lighting, default lighting, idle lighting

**Codex lighting profile**:
The independent set of task-signal effects owned by this integration, separate from the keyboard's other lighting effects.
_Avoid_: Keyboard profile, RGB preset

**Hook owner**:
The component installed and managed by this project to receive privacy-allowlisted Codex lifecycle events for the keyboard status light. It is independent of Hook handlers owned by other products.
_Avoid_: ZECTRIX Hook, shared Hook

**Hook consent**:
The explicit user approval given after Guided setup presents the eight owned Codex lifecycle Hooks and their privacy-allowlisted fields. The Keyphore App does not silently trust Hooks, and consent applies only to definitions that match the reviewed release.
_Avoid_: Installation consent, automatic trust, Codex permission

**Codex host**:
An installed Codex desktop app or Codex CLI environment into which the Keyphore App integrates its Plugin and Hooks. First-release users need either host, not both, and Keyphore does not distribute Codex itself.
_Avoid_: Keyphore App, Plugin, bundled Codex

**Status core**:
The source-independent model that reduces normalized Codex lifecycle events into per-owner states and the aggregate state displayed by the keyboard.
_Avoid_: ZECTRIX adapter, keyboard driver

**Signal owner**:
The Codex session or agent responsible for an active attention signal; every owner must be released independently before the aggregate state can leave attention.
_Avoid_: Active task, light owner

**Aggregate state**:
The single visible state displayed across the main backlight after excluding signals disabled by signal visibility and then combining all tracked Codex tasks with the priority attention, execution, completion, then signal-off. A disabled higher-priority signal reveals the next enabled active signal rather than forcing signal-off.
_Avoid_: Current task state, latest state

**Signal summary**:
A compact explanation of the current aggregate state that helps a person understand why the keyboard shows that signal, counting each Codex session once and grouping its main agent and subagents together. Each session contributes to only one state category; the summary does not identify individual tasks, display task names or a task list, or provide navigation to a task.
_Avoid_: Task panel, task navigator, task list

**Signal summary availability**:
Whether current task state can be reliably read while the background component is running, independently of whether the keyboard is connected. A disconnected keyboard retains readable summary counts with a separate connection warning; a stopped background component or failed state read makes the summary unavailable rather than displaying stale counts or zero tasks, and only a successful read with no unexpired signals means no active signals.
_Avoid_: Keyboard readiness, zero tasks on error, last-known counts as current state

**Session summary state**:
The single state category assigned to a Codex session in the signal summary, with attention taking priority over execution and execution over completion among its unexpired signals, regardless of signal visibility. A subagent requiring attention places the whole session in attention rather than adding another task or counting the session in execution as well.
_Avoid_: Agent count, owner count, parallel task count

**Recent completion count**:
The number of sessions classified as completion in the signal summary, presented as just completed only while their completion signals remain within the configured completion display duration. It follows that duration, five seconds by default, excludes sessions with active attention or execution, and is neither a daily total nor task history.
_Avoid_: Completed task total, daily completion count, completion history

**Hidden summary signal**:
A state category retained in the signal summary even though its lighting presentation is disabled by signal visibility, explicitly marked as hidden from the keyboard lights. Hiding a signal does not remove its sessions from the summary or reclassify them as executing.
_Avoid_: Hidden task, inactive task, ignored signal

**Signal surface**:
The Air65 V3 main key backlight used by the first version to display notification signals; the rhythm light bar remains outside the signal surface.
_Avoid_: Lighting zone, status LEDs

**Signal color**:
The solid main-backlight color a person assigns independently to each visible Codex task signal in the Keyphore App.
_Avoid_: Keyboard theme, RGB profile, lighting effect

**Signal pattern**:
The steady or slow-flashing presentation a person assigns independently to each visible Codex task signal in the Keyphore App, independently of its signal color. Slow flashing uses a fixed cycle of about one second lit and one second unlit rather than a user-selected speed or a breathing fade.
_Avoid_: Signal color, keyboard effect, animation theme, breathing effect

**Signal brightness**:
The main-backlight intensity from 1% through 100% that a person assigns independently to each visible Codex task signal in the Keyphore App. Zero intensity is reserved for the signal-off state rather than used to disable a signal.
_Avoid_: Global brightness, keyboard brightness, signal color

**Signal visibility**:
The per-signal setting that determines whether a task signal may be presented on the signal surface. Execution, attention, and completion signals are visible by default.
_Avoid_: Zero brightness, signal-off state

**Default signal profile**:
The initial visible settings reproduced from the verified implementation: execution is steady `#0000FF` at 100%, attention is steady `#FF8400` at 100%, and completion is steady `#00FF00` at 100% for five seconds. Slow flashing remains optional rather than a default.
_Avoid_: User profile, keyboard preset, recommended profile

**Verified transport**:
The wired USB HID connection to exactly one Air65 V3 on macOS, which is the only device-control path claimed by the first release. When multiple supported keyboards are connected, Keyphore refuses an ambiguous write and asks the person to leave only the target connected; a 2.4 GHz receiver remains an unverified future transport, while Bluetooth control is outside the first-release scope.
_Avoid_: Wireless support, all NuPhyIO devices

**Verified platform**:
The Apple Silicon Mac running macOS 13 or later on which the first Keyphore App release is supported and accepted. Intel Macs and earlier macOS releases are outside the first-release scope.
_Avoid_: Universal Mac app, Intel support, verified transport

**NuPhyIO adapter**:
The minimal in-process hardware boundary that translates lighting states into the verified Air65 V3 USB HID protocol. It is not a general replacement for NuPhyIO or `nuphyctl`.
_Avoid_: nuphyctl process, keyboard SDK

**Keyphore App**:
The primary product and distribution unit through which a person installs, configures, validates, updates, and removes Keyphore.
_Avoid_: Plugin, Companion, settings wrapper

**Menu bar control**:
The persistent user-facing Keyphore App entry point that shows current signal and keyboard connection status and opens settings, diagnostics, and quit actions without occupying the Dock during normal use.
_Avoid_: Companion, Dock app, settings window

**Quit Keyphore**:
The explicit action that disables Keyphore's owned Hooks, stops the Companion, clears managed runtime state, and leaves the signal surface in the signal-off state. Opening Keyphore re-enables unchanged trusted Hooks without renewed Hook consent, while changed definitions still require consent; closing the settings window is not quitting Keyphore.
_Avoid_: Close settings, hide app

**Login launch**:
The user-approved setting that starts the Keyphore App when the person logs in to the Mac. Guided setup presents it explicitly and enables it by default, and settings can disable it later.
_Avoid_: Silent startup, Companion startup, reopen settings

**Managed update**:
The user-approved installation of a signed and notarized Keyphore App release found by automatic update checks. Changed Hook definitions require separate renewed Hook consent after the App update.
_Avoid_: Silent update, Hook consent, Plugin-only update

**Managed removal**:
The user-confirmed in-App process that turns the signal surface off and removes only Keyphore's Plugin, Hooks, background registration, Local profile, and managed state before the person trashes the App.
_Avoid_: Delete App, remove Codex, reset settings

**Local profile**:
The on-Mac record of a person's signal settings and Keyphore runtime state. Keyphore has no product account or cloud synchronization and sends no telemetry or diagnostics automatically.
_Avoid_: User account, cloud profile, Codex history

**Free distribution**:
The no-charge release of the compiled Keyphore App to end users while its first-party source code and repository remain private.
_Avoid_: Open source, paid license, public repository

**Release channel**:
The public product page, notarized DMG download, and signed read-only update feed through which people obtain the free Keyphore App without repository access or a GitHub account.
_Avoid_: Public repository, private GitHub Release, Mac App Store

**App language**:
The complete Simplified Chinese or English localization selected from the macOS system language, with English as the fallback. Both languages cover Guided setup, status, errors, diagnostics, Managed removal, and Hook consent rather than settings alone.
_Avoid_: Partial translation, manual language profile, Chinese-only interface

**Plugin**:
The Codex integration component managed internally by the Keyphore App that owns the project's Hooks.
_Avoid_: Keyphore App, Companion, standalone product

**Companion**:
The Keyphore App's background component that maintains the status core and applies aggregate states through the NuPhyIO adapter. It never depends on ZECTRIX at runtime.
_Avoid_: Plugin, Hook handler

**Durable status**:
The atomically persisted per-owner state written by Hook handlers and consumed by the companion as the local source of truth across process restarts.
_Avoid_: Event log, diagnostic log, keyboard state

**Guided setup**:
The normal-user experience for installing, configuring, validating, updating, and removing Keyphore without using Terminal or entering commands.
_Avoid_: Mac App Store installation, command-line setup, one-click install

**User-scoped installation**:
The installation boundary in which the Keyphore App, background registration, Plugin, Hooks, Local profile, and managed state belong only to the current macOS user and require no administrator authorization.
_Avoid_: System-wide install, privileged helper, device driver

**Legacy migration**:
The user-confirmed replacement of the earlier Rust Plugin installation with the Swift Keyphore App. It stops and removes the old Companion, Plugin, Hooks, background registration, and runtime state before installing the new components, renewing Hook consent, and running Signal preview; the two runtimes never coexist.
_Avoid_: App update, silent migration, parallel installation

**Configured state**:
The installation state in which the Keyphore App, Codex host integration, Hook consent, and Companion are configured even if the supported keyboard is not currently connected.
_Avoid_: Ready state, partial failure, keyboard ready

**Ready state**:
The end-to-end state in which Keyphore is configured and the supported Air65 V3, wired USB transport, and lighting protocol are all healthy. Configured state alone must not be presented as ready.
_Avoid_: Configured state, installed state, keyboard connected

**Settings appearance preview**:
The on-screen keyboard illustration of the signal appearance currently being edited, independent of the live aggregate state and without taking over the physical signal surface. Settings still take effect immediately, so editing the appearance of the currently displayed signal also updates the physical keyboard; only an explicitly requested signal preview temporarily takes over the signal surface for testing.
_Avoid_: Signal preview, physical test, unsaved settings draft

**Signal preview**:
The user-initiated test that presents each configured task signal on the connected keyboard, verifies protocol readback, and asks the person to confirm the visible result; connecting a keyboard never starts it automatically. New task signals do not interrupt the lighting test: the signal summary continues to reflect real task states with an explicit lighting-test indicator, excludes demonstration colors from its counts, and the physical signal surface returns to the latest aggregate state when the presentation ends rather than restoring a pre-test snapshot.
_Avoid_: Automatic exercise, protocol diagnostics, ready state

**Diagnostic report**:
The user-reviewed ZIP export containing Keyphore, macOS, Codex host, Hook, Companion, keyboard, protocol, and redacted error health fields. It excludes Codex content, usernames, and full local paths and is never uploaded automatically.
_Avoid_: Telemetry, crash upload, Hook audit
