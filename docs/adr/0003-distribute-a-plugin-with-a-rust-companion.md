# Distribute a plugin with a bundled Rust companion

The project will ship primarily as an independently installable Codex Plugin with one bundled Rust executable that provides Hook handling, setup, diagnostics, background state management, and Air65 V3 control. Direct binary execution remains a development interface, but users will not need Python, Node, `nuphyctl`, or another product at runtime; this keeps installation and updates within one release unit while allowing the hardware work to outlive individual Hook processes.
