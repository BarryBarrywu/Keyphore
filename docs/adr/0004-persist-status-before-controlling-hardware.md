# Persist status before controlling hardware

Each Hook invocation will parse its privacy-allowlisted lifecycle event, update durable status under a short bounded lock, and exit without opening the keyboard. The long-lived companion exclusively owns HID access, observes durable status, applies timers and aggregate priority, and drives the NuPhyIO adapter; this prevents keyboard availability or daemon restarts from blocking Codex and avoids losing state through an ephemeral local socket.
