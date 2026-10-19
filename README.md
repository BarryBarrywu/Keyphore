<p align="center"><strong>English</strong> · <a href="./README.zh-CN.md">简体中文</a></p>

<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="Keyphore — Codex task status on your NuPhy keyboard. Blue for working, orange for attention, green for complete, and lights off when idle.">
</p>

# Keyphore

**See when Codex is working, needs you, or has finished—right on your keyboard.**

Keyphore (pronounced “key-for”) is a native macOS menu bar app that turns Codex task events into NuPhy keyboard backlighting. Configure your signals in the App, then keep working while the keyboard shows the current state.

[Get started](#get-started) · [Compatibility](#compatibility) · [Build from source](#build-from-source) · [GPL v3](#license)

<p align="center">
  <img src="./assets/readme/app-en.png" width="460" alt="Keyphore App showing Codex task status and the connected NuPhy Air65 V3.">
</p>

## One glance, three signals

| Default light | What it means |
| --- | --- |
| **Blue breathing · Working** | A coding-agent task or subagent is executing. |
| **Orange breathing · Attention** | A coding agent needs your approval or input. |
| **Green · Complete** | A turn finished. The signal lasts five seconds by default. |
| **Off or idle lighting** | No visible task signal is active. Lights are off by default. |

Concurrent tasks share one keyboard signal: **attention → working → complete → idle**. A completed turn cannot hide another task that is still working or waiting for you. Disabling a signal reveals the next eligible state. When no task remains, the selected idle setting applies.

*The illustration shows signal states, not a photograph of physical lighting. Actual appearance depends on your keyboard and settings.*

## Make the signals yours

- **Configure backlight and strip light separately.** Each task state has independent settings for both zones. Choose whether Keyphore controls the backlight, strip light, or both; unselected zones keep their keyboard settings.
- **Use the keyboard's native effects.** Air V3 backlight offers 20 effects and its strip light offers five, matching NuPhyIO. Air75 V2 offers all 41 choices in its VIA definition, including All Off. Brightness, speed, direction, and custom-color controls appear where the keyboard and selected effect support them.
- **Match colors precisely.** Use NuPhyIO's 12 preset colors, a saturation/value picker, HEX or RGB input, and recent colors. Native multicolor mode is separate from the custom color selection.
- **See the appearance while editing.** The settings illustration works without a connected keyboard. The physical keyboard renders native effects; the illustration is an appearance guide, not an exact simulation of per-key animation.
- **Choose how long completion stays visible.** Set it from 1–60 seconds; working and attention follow task activity.
- **Choose what happens when idle.** In **Settings → Lighting → Idle**, select lights off or configure an independent idle effect for each controlled zone. Quitting Keyphore still turns the controlled lights off.
- **Check the keyboard from the menu bar.** See the current signal, connection state, and a keyboard illustration; open settings without a Dock window.
- **Preview on the actual keyboard.** Click a task-state or idle tab in lighting settings for a six-second preview. Editing its color or effect restarts that preview; afterward, the keyboard returns to the current task signal. Device check tests all three task signals.
- **Use the appearance and language you prefer.** Light, dark, or system appearance; English, Simplified Chinese, or system language.

## Compatibility

| Component | Current support |
| --- | --- |
| Mac | Apple Silicon · macOS 13 or later |
| Coding tools | Codex desktop/CLI, Claude Code, Pi, OpenCode, Qoder CLI, Grok Build |
| Keyboards | **NuPhy Air65 V3 and Air75 V3**, stock firmware, supported USB identities |
| Connection | Wired USB · one controlled keyboard at a time, selectable when several models are connected |

Air65 V3 uses USB ID `19f5:102b`; Air75 V3 uses `19f5:1028`. ISO/JIS variants, Bluetooth, 2.4 GHz receivers, Intel Macs, and custom firmware are outside current support.

The **Air75 V2** driver (`19f5:3246`, VIA protocol 12) provides all 41 main-backlight choices in the supplied VIA definition: All Off plus 40 native effects, including gradients, cycles, rainbows, raindrops, heatmaps, reactive effects, and splashes. Non-Off choices expose VIA's color and speed parameters; the effect determines their visible influence, and reactive effects need physical key presses. Its [verification record](./docs/research/air75-v2-via.md) distinguishes software checks, device readback, and visual confirmation. Side lights remain controlled by the keyboard; their App controls are shown as unavailable. The driver never sends VIA Save commands. Each supported model saves its own lighting settings, so switching to V2 does not reuse or overwrite V3 effects.

Use **Current keyboard** in the menu bar popover, the right-click menu, or **Settings → Device** to select a connected model. Automatic selects the only supported wired keyboard. A manual choice stays active while that model is connected; when it is absent and another keyboard is detected, Keyphore returns to Automatic. With multiple keyboards and no valid manual choice, select one from the menu. Switching first turns off and verifies the previous keyboard’s controlled zones if it is still connected. A disconnected previous target is released without claiming its lights were turned off. Multiple keyboards of the same selected model remain ambiguous. The model illustration list only changes the illustration.

In **Settings → Agents**, review and enable each additional coding tool separately. Claude Code, Qoder CLI, and Grok use native plugins; Pi uses a native extension; OpenCode uses a local plugin. An approved native integration can run without Codex installed. Restart the coding tool or reload its extensions after installation. Removing one integration preserves other integrations and their active task signals.

Pi provides execution, completion, and cancellation events, but no general waiting-for-user event. Claude Code and Qoder hooks without a native turn identifier follow the host's delivery order; an uncorrelated late event cannot be assigned reliably to an older turn. Grok child events without a stable agent identifier are ignored. Errors and cancellations clear signals when the host emits the corresponding supported event; arbitrary terminal failures are not inferred from transcripts or process output.

Keyphore retains only lifecycle names and session, agent, turn, or permission-request identifiers. Native Hook payloads are filtered by the local helper; Pi/OpenCode extensions send only those fields. Prompts, answers, tool arguments, and transcript contents are never persisted or uploaded. Each source has independent approval, and a shared quit gate suppresses all sources after an explicit Quit. Grok-imported Claude/Qoder hooks cannot reuse those sources' approval.

The App can recognize and illustrate additional NuPhy models. **Recognition is not lighting support**: the current experimental lighting allowlist is empty. The [bundled model catalog](./app/Sources/KeyphoreCore/Resources/candidate-keyboards.json) records the recognized identities and layouts.

## Get started

This repository contains the App source. A packaged public download is not linked here yet; use [the source build below](#build-from-source) for development.

Once you have a Keyphore App build:

1. **Open Keyphore and choose your coding tools.** Use Guided setup for Codex or **Settings → Agents** for the other sources. The App manages its integrations and shared background component for your macOS user.
2. **Review and approve each integration.** Setup presents its events and owned files before enabling it. Follow any macOS permission prompts shown by the App.
3. **Connect one supported keyboard over USB.** Run Signal preview and confirm the visible lighting result.
4. **Start a new task in an enabled coding tool.** Adjust the three signals from Keyphore’s settings whenever you like.

Closing settings leaves Keyphore running. **Quit Keyphore** stops its background component, suppresses owned lifecycle events, and turns the signal lights off. For removal, use the in-App removal action before trashing the App.

## Prefer a Rust Plugin without the App?

Developers who do not want the macOS App can build the standalone Rust Codex Plugin from [`src/`](./src) and [`Cargo.toml`](./Cargo.toml). It runs a background Companion without a menu bar interface. The Swift App is a separate native implementation, not a wrapper around this Rust binary.

**The Rust route has a narrower scope:** macOS on Apple Silicon, a stock NuPhy Air65 V3 over wired USB, and fixed blue/orange/green signals with a five-second completion window. Do not assume the App’s Air75 V3 support, signal settings, previews, or updater are available in the Rust Plugin. Not using the App does not imply Windows or Linux support.

With a Rust toolchain supporting edition 2024, Xcode Command Line Tools, and a Codex installation with Plugin/Hook support, run these commands from the repository root. They replace the bundled Rust binary with your local build, ad-hoc sign it for local use, and install the Plugin from this checkout:

```bash
cargo build --release --target-dir /private/tmp/codex-builds/keyphore-rust
install -m 755 /private/tmp/codex-builds/keyphore-rust/release/keyphore plugin/bin/keyphore
codesign --force --sign - --identifier keyphore plugin/bin/keyphore
codex plugin marketplace add .
codex plugin add keyphore@keyphore
```

Start a new Codex task and ask:

```text
Use $setup-keyphore to install and validate my NuPhy Air65 V3 status lights.
```

The [bundled setup Skill](./plugin/skills/setup-keyphore/SKILL.md) handles Companion installation, explicit review/trust of the eight Hooks, diagnostics, updates, and removal. Reload Codex as prompted after Hook approval. Building the executable alone does not configure the integration.

**Choose one runtime for the keyboard.** Do not run the Rust Companion and Swift App together. Use the active installation’s removal action before switching; do not manually run a lighting exercise while a Companion owns HID.

The Rust tests also serve as a reference for the Swift implementation. [`tools/keyphore-rewrite-acceptance`](./tools/keyphore-rewrite-acceptance) compares their behavior and audits the App artifact; automated parity is not a substitute for physical lighting confirmation.

## Local by design

Keyphore has no product account or cloud sync and does not automatically upload telemetry or diagnostics. Its Hook handlers retain only allowlisted event and task-identity fields, not prompts, conversation text, or tool content. Diagnostic exports are reviewed and saved locally by you.

```text
Codex task events → local task state → Companion → keyboard backlight
```

The Companion is the only component that opens the keyboard’s HID connection. It combines active task signals, applies your settings, and verifies lighting writes through protocol readback. The supported lighting profiles preserve the separate side/rhythm-light state. Keyphore’s idle state turns its main-backlight signal off; it does not restore a previous lighting effect.

## Build from source

The App, its Hook runtime, and its Companion are written in **Swift 6**. The separately buildable Rust Plugin also serves as a behavioral reference; it is not embedded in the App.

Core tests require a Swift 6 toolchain:

```bash
swift test --package-path app --scratch-path /private/tmp/codex-builds/keyphore-core
```

Build the App with Xcode on Apple Silicon:

```bash
xcodebuild -project Keyphore.xcodeproj -scheme Keyphore \
  -configuration Debug \
  -derivedDataPath /private/tmp/codex-builds/keyphore-app \
  build
```

For maintainers opening a development build or testing a physical keyboard, use the repository’s stable installation workflow:

```bash
tools/keyphore-development-app build-open
```

That workflow uses a temporary build directory under `/private/tmp/codex-builds` and requires a valid signing identity. It defaults to the maintainer's Developer ID; local development can explicitly set `KEYPHORE_DEVELOPMENT_TEAM` and `KEYPHORE_SIGNING_IDENTITY` to a matching team and full Apple Development certificate name. The App, helper, and Companion must all pass strict signature checks with that identity. The workflow quits the running App normally and refuses a remaining Companion before installing in `~/Applications/Keyphore.app`. Do not launch a development App directly from DerivedData. After hardware testing, quit through the App so it can turn the signal off and stop the Companion.

<details>
<summary>Code map and validation boundaries</summary>

| Path | Purpose |
| --- | --- |
| [`app/Sources/KeyphoreApp`](./app/Sources/KeyphoreApp) | Menu bar, settings, Guided setup, diagnostics, updates |
| [`app/Sources/KeyphoreCore`](./app/Sources/KeyphoreCore) | Task state, signal profiles, lifecycle, USB protocol |
| [`runtime/Sources`](./runtime/Sources) | Swift Hook handler and Companion entry points |
| [`app/Tests`](./app/Tests) | Core and App contracts |
| [`src`](./src) | Standalone Rust Plugin and behavioral reference |

[`tools/keyphore-rewrite-acceptance`](./tools/keyphore-rewrite-acceptance) collects software and parity evidence. Automated tests and protocol readback do not replace physical lighting confirmation. The [original Air65 V3 acceptance record](./docs/acceptance/issue-9.md) describes that earlier hardware check; it is not an Air75 V3 acceptance report.

</details>

## Updates

The App uses a signed Sparkle feed in [`updates/appcast.xml`](./updates/appcast.xml). Versioned installers belong in GitHub Releases; English and Simplified Chinese notes live in [`updates/notes`](./updates/notes). The initial feed contains no release until a signed, notarized installer is ready. Online updates require the repository and Release assets to be publicly accessible.

Maintainers: `tools/keyphore-release build` reads the feed URL and public key from [`release/Updates.xcconfig`](./release/Updates.xcconfig), with separate `--feed-url` and `--download-url` overrides. `stage` takes `--notes-en` and `--notes-zh-hans`, signs the feed, and prepares `public/updates` for the repository and `public/release-assets` for GitHub Releases, including corresponding source. Build from committed source. Publish the versioned assets before updating the feed; retain old assets and increase the version and build numbers for each release. Signing uses the `com.barrywu.keyphore` Keychain account; never commit its private key.

## License

Keyphore’s first-party code, including the Swift App, Companion, and bundled Plugin, is licensed under the [GNU General Public License v3.0 only](./LICENSE) (`GPL-3.0-only`). When distributing covered binaries, provide their corresponding source under the license terms.

Third-party components retain their original licenses and attribution: [NuPhyIO protocol notice](./LICENSES/NUPHYIO-NOTICE.txt) · [Sparkle and bundled dependencies](./app/Sources/KeyphoreCore/Resources/SPARKLE-NOTICE.txt).
