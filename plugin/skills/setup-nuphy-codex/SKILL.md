---
name: setup-nuphy-codex
description: Install, validate, update, diagnose, or remove the NuPhy Air65 V3 Codex status-light integration.
---

# NuPhy Air65 V3 Codex status light

Resolve the plugin root as the directory two levels above this file. Use only the bundled `bin/nuphy-codex` executable.

For a fresh installation, run `lifecycle install --plugin-root <plugin-root> --plugin-id nuphy-codex@<marketplace>`, then `lifecycle validate` and `diagnostics`.

For an update, run `lifecycle update --plugin-root <new-plugin-root> --plugin-id nuphy-codex@<marketplace>`, then `lifecycle validate` and `diagnostics` using the new bundled executable.

For removal, run `lifecycle uninstall`. Report whether Codex needs to reload before the removed Hooks disappear from the current process.

Do not claim physical acceptance from validation output. The user must separately verify the lighting states, wired reconnect behavior, and unchanged rhythm light bar on a real Air65 V3.
