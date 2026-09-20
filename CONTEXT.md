# BuildrHooksCLI

BuildrHooksCLI relays supported coding-agent lifecycle hooks into BuildrAI's repository-local event queue. It is an event bridge, while the BuildrAI host owns project selection and hook configuration.

## Language

**Claude Code Desktop Companion session**:
A Claude Code session whose declared transcript records the current `claude-desktop` entrypoint for that same session. Claude Desktop is its visual execution surface, not the session identity itself.
_Avoid_: Claude Desktop session, Claude Desktop window

**Declared execution surface**:
The optional, agent-specific surface attached to a raw hook event only after it is resolved from the hook-declared transcript. It is unavailable when transcript evidence is missing, malformed, mismatched, or unsupported.
_Avoid_: inferred surface, active app

**Managed Claude hook entry**:
A named BuildrAI command handler in a selected project's `.claude/settings.local.json`. The BuildrAI host, rather than this event bridge, owns its lifecycle.
_Avoid_: global Claude hook, shared hook
