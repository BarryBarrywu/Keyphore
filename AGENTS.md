## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. See `docs/agents/domain.md`.

### Keyphore development acceptance

Before opening a development build or running physical keyboard acceptance, use
`tools/keyphore-development-app build-open`. It installs the current build at the stable
user-scoped development App path and refuses to continue while a legacy or current Companion
could still own HID. Do not open Keyphore directly from DerivedData or another temporary path.

Build-only and automated test runs still use the global temporary-build rules. After physical
acceptance, quit Keyphore through the App so it can complete signal-off acknowledgement and stop
its Companion.
