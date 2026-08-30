<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="NuPhy Codex turns Codex lifecycle events into status lights on a NuPhy Air65 V3 keyboard">
</p>

NuPhy Codex is a macOS Codex Plugin that shows aggregate task state on the main backlight of a stock NuPhy Air65 V3. It keeps Hook handling fast, persists state locally, and gives the keyboard to one long-lived companion process instead of opening HID from every event.

## Status at a glance

| Keyboard signal | Codex state | Behavior |
| --- | --- | --- |
| Blue | Working | A task or subagent is executing |
| Orange | Attention | A permission request needs a response |
| Green | Complete | The most recent task completed; clears after five seconds |
| Off | Idle | No active status remains |

Attention wins over completion from another concurrent task, and each main task or subagent keeps an independent owner in durable state. If the keyboard disconnects or the companion restarts, the current aggregate state is replayed when the device becomes available again.

## How it works

```text
Codex lifecycle event
        │
        ▼
privacy-allowlisted Hook ──► durable status.json
                                  │
                                  ▼
                        background companion
                                  │
                                  ▼
                      verified NuPhyIO adapter
                                  │
                                  ▼
                    Air65 V3 main backlight
```

- Hooks record only event, session, agent, turn, and receipt-time fields. They never open the keyboard.
- The companion is the sole HID owner and reduces all active owners to one visible state.
- Protocol readback verifies the intended main-backlight state while leaving the rhythm light bar unchanged.
- Sleep, restart, reconnect, concurrent sessions, and real subagents are covered by automated contracts and real-device acceptance.

See the [Air65 V3 acceptance record](./docs/acceptance/issue-9.md) for the observed hardware evidence.

## Requirements

- Apple Silicon Mac running macOS
- Codex with Plugin and Hook support
- NuPhy Air65 V3 with stock firmware
- Wired USB connection

Bluetooth, 2.4 GHz, other NuPhy models, custom firmware, Claude Code, and automatic terminal-failure signals are not supported in this release.

## Install

Add this repository as a Codex marketplace and install the Plugin:

```bash
codex plugin marketplace add BarryBarrywu/Nuphy
codex plugin add nuphy-codex@nuphy-codex
```

Start a new Codex task and ask it to use the bundled setup Skill:

```text
Use $setup-nuphy-codex to install and validate my NuPhy Air65 V3 status lights.
```

The setup flow installs the companion, asks you to review the eight bundled Hook definitions, and requires a separate trust step before those Hooks can run. Start another new Codex task after trusting the Hooks so the current process reloads them.

## Verify

Start a new Codex task and ask the installed setup Skill to run diagnostics:

```text
Use $setup-nuphy-codex to run diagnostics for my NuPhy Air65 V3 status lights.
```

A ready installation reports these surfaces independently:

```text
hook_ownership=owned
hook_trust=trusted
durable_status=healthy
companion=running
keyboard_discovery=air65-v3
verified_transport=wired-usb
protocol_health=healthy
```

From a repository checkout, the same read-only report is available as `./plugin/bin/nuphy-codex diagnostics`. For an isolated physical lighting exercise, stop the companion first, then run `diagnose --exercise`. Do not run the exercise while the companion owns HID.

## Develop

The project is a Rust binary and library with a bundled Codex Plugin:

```bash
cargo fmt --check
cargo check --all-targets
cargo clippy --all-targets -- -D warnings
cargo test
```

The main boundaries are documented in the [Hook lifecycle ADR](./docs/adr/0001-own-an-independent-codex-hook-lifecycle.md), [Plugin distribution ADR](./docs/adr/0003-distribute-a-plugin-with-a-rust-companion.md), and [durable-status ADR](./docs/adr/0004-persist-status-before-controlling-hardware.md).

## License

NuPhy Codex is available under the [MIT License](./LICENSE). The minimal NuPhyIO protocol implementation retains its required notice in [LICENSES/NUPHYIO-NOTICE.txt](./LICENSES/NUPHYIO-NOTICE.txt).
