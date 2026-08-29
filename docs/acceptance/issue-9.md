# Issue #9 acceptance record

Date: 2026-08-29

Environment observed by the acceptance commands: macOS, NuPhy Air65 V3 USB `19f5:102b`, interface 3, wired USB. The operator confirmed that the keyboard uses stock firmware.

## Completed evidence

- The repository installed as the `nuphy-codex@nuphy-codex` Plugin from its local marketplace, updated to the Codex cache release unit, validated as owned, removed cleanly, and reinstalled. The existing `codex-zectrix-dashboard` Plugin remained enabled after removal and reinstall.
- With the companion stopped, `diagnose --exercise` applied and read back execution, attention, completion, and signal-off on the connected Air65 V3. The rhythm light bar remained byte-for-byte unchanged at `[04, 3c, 02, 01, 00, ff, 00, 00]`.
- The operator visually confirmed the blue execution signal, static orange attention signal, green completion signal, signal-off, and an unchanged rhythm light bar on the stock-firmware keyboard.
- While the installed companion owned the lighting interface and displayed `Execution`, the operator typed `air65 v3 abcdef 123456` on the Air65 V3 and the text arrived byte-for-byte unchanged.
- Through the installed Hook, durable-status, companion, and real HID path, diagnostics observed `Execution`, `Attention`, `Completion`, then `SignalOff`, with `keyboard_discovery=air65-v3`, `verified_transport=wired-usb`, and `protocol_health=healthy` at every stage.
- Two simultaneous sessions preserved attention over another session's completion. Automated contracts separately cover subagent owner isolation and aggregate priority.
- A forced companion restart replayed `Execution` from durable status. `SessionEnd` returned the aggregate to `SignalOff`.
- A fresh Codex CLI task using the automation-only trust bypass for the vetted local Hook definition drove the installed Plugin through `Execution` and cleanup. On Codex CLI 0.146.1, a real held-open Agent subagent completed successfully, but configured `SubagentStart` and `SubagentStop` events did not reach the Plugin; only the parent tool lifecycle was observed, so live subagent aggregation remains an open gate.
- Hook writes completed in 0.00-0.01 seconds. With the companion stopped, a Hook write still completed in 0.00 seconds and replayed after the companion restarted.
- With the Air65 V3 physically unplugged, five Hook writes completed in 0.00-0.01 seconds while diagnostics reported the keyboard and protocol as unavailable. Reconnecting the keyboard in wired mode automatically replayed the persisted blue `Execution` state, after which session cleanup returned the aggregate to `SignalOff`.
- After an operator-authorized factory reset, the installed companion automatically replayed the persisted blue `Execution` state; the operator then confirmed normal Air65 V3 input before session cleanup returned the aggregate to `SignalOff`.
- `cargo fmt --check`, `cargo check --all-targets`, Clippy with warnings denied, all 58 tests, the marketplace parser, and strict bundled-binary signature validation passed.

## Required human gates still open

- Run concurrent real Codex tasks with a live subagent and confirm the visible aggregate priority.

Until these gates are recorded, automated checks and HID readback do not constitute full real-device acceptance.
