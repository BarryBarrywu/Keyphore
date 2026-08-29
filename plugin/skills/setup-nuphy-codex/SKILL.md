---
name: setup-nuphy-codex
description: Install, validate, update, diagnose, or remove the NuPhy Air65 V3 Codex status-light integration.
---

# NuPhy Air65 V3 Codex status light

Resolve the plugin root as the directory two levels above this file. Use only the bundled `bin/nuphy-codex` executable.

The first release is verified only on macOS wired USB with stock Air65 V3 firmware. Bluetooth, 2.4 GHz, other NuPhy models, Claude Code, custom firmware, and automatic terminal failure signals are unsupported and must not be claimed.

For a fresh installation, run `lifecycle install --plugin-root <plugin-root> --plugin-id nuphy-codex@<marketplace>`, review and trust the installed Hook definition with `/hooks`, then start a new Codex task before running `lifecycle validate` and `diagnostics`.

For an update, run `lifecycle update --plugin-root <new-plugin-root> --plugin-id nuphy-codex@<marketplace>`, review and trust the changed Hook definition with `/hooks`, then start a new Codex task before running `lifecycle validate` and `diagnostics` using the new bundled executable.

For removal, run `lifecycle uninstall`. Report whether Codex needs to reload before the removed Hooks disappear from the current process.

For installed end-to-end acceptance, use real Codex tasks to observe execution, attention, completion, signal-off, concurrency, and restart recovery. Do not run the direct lighting exercise while the companion is active because it is the sole HID owner.

For an isolated hardware exercise, first ensure the companion is stopped, then run `diagnose --exercise` and observe the blue execution signal, orange attention signal, green completion, and signal-off. Separately verify wired reconnect behavior, normal keyboard input, and an unchanged rhythm light bar on a real Air65 V3. Readback or automated validation alone is not physical acceptance.
