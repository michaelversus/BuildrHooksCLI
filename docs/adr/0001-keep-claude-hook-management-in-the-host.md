# Keep Claude hook management in the host

BuildrHooksCLI remains an event bridge: it ingests Claude Code lifecycle events, resolves a declared execution surface from the declared transcript, and reports capabilities. The BuildrAI host owns selected-project consent, security-scoped access, and the safe merge, adoption, repair, and removal of its named entries in `.claude/settings.local.json`, preventing the bridge from gaining configuration authority over user and third-party Claude settings.

Specification #32 adds a separate, explicitly user-invoked CLI status-line integration.
Its reversible setup owns only the selected `statusLine` value and private runner
metadata; it does not manage lifecycle hook entries. The sandboxed BuildrAI app
provides guidance and receives reports, but does not execute setup or modify Claude
settings. This approved exception narrows the configuration-authority statement
above while preserving host ownership of hooks.
