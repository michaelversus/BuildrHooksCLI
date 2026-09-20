# Keep Claude hook management in the host

BuildrHooksCLI remains an event bridge: it ingests Claude Code lifecycle events, resolves a declared execution surface from the declared transcript, and reports capabilities. The BuildrAI host owns selected-project consent, security-scoped access, and the safe merge, adoption, repair, and removal of its named entries in `.claude/settings.local.json`, preventing the bridge from gaining configuration authority over user and third-party Claude settings.
