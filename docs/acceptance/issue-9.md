# Issue #9 acceptance record

Date: 2026-08-29

Environment observed by the acceptance commands: macOS, NuPhy Air65 V3 USB `19f5:102b`, interface 3, wired USB. The protocol does not expose a firmware-version query, so stock-firmware status still requires operator confirmation.

## Completed evidence

- The repository installed as the `nuphy-codex@nuphy-codex` Plugin from its local marketplace, updated to the Codex cache release unit, validated as owned, removed cleanly, and reinstalled. The existing `codex-zectrix-dashboard` Plugin remained enabled after removal and reinstall.
- With the companion stopped, `diagnose --exercise` applied and read back execution, attention, completion, and signal-off on the connected Air65 V3. The rhythm light bar remained byte-for-byte unchanged at `[04, 3c, 02, 01, 00, ff, 00, 00]`.
- Through the installed Hook, durable-status, companion, and real HID path, diagnostics observed `Execution`, `Attention`, `Completion`, then `SignalOff`, with `keyboard_discovery=air65-v3`, `verified_transport=wired-usb`, and `protocol_health=healthy` at every stage.
- Two simultaneous sessions preserved attention over another session's completion. Automated contracts separately cover subagent owner isolation and aggregate priority.
- A forced companion restart replayed `Execution` from durable status. `SessionEnd` returned the aggregate to `SignalOff`.
- Hook writes completed in 0.00-0.01 seconds. With the companion stopped, a Hook write still completed in 0.00 seconds and replayed after the companion restarted.
- `cargo fmt --check`, `cargo check --all-targets`, Clippy with warnings denied, all 58 tests, the marketplace parser, and strict bundled-binary signature validation passed.

## Required human gates still open

- Confirm the keyboard is on stock Air65 V3 firmware.
- Visually confirm the blue execution signal, orange attention pulse, green completion, signal-off, and unchanged rhythm light bar.
- Confirm normal typing remains usable while the companion owns the lighting interface.
- Perform physical USB unplug/replug and keyboard-reset checks, then verify the current aggregate state is replayed.
- Run concurrent real Codex tasks with a live subagent and confirm the visible aggregate priority.
- Physically disconnect the keyboard and confirm Hook latency remains non-blocking; automated tests cover this boundary, but hardware-disconnected timing has not been observed in this run.

Until these gates are recorded, automated checks and HID readback do not constitute full real-device acceptance.
