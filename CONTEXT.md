# BuildrHooksCLI

BuildrHooksCLI relays supported coding-agent lifecycle hooks into BuildrAI's repository-local event queue. It is an event bridge, while the BuildrAI host owns project selection and hook configuration.

## Language

**Claude Code Desktop Companion session**:
A Claude Code session whose declared transcript records the current `claude-desktop` entrypoint for that same session. Claude Desktop is its visual execution surface, not the session identity itself.
_Avoid_: Claude Desktop session, Claude Desktop window

**Declared execution surface**:
The optional, agent-specific surface attached to a hook event only after it is resolved from the hook-declared transcript. It is unavailable when transcript evidence is missing, malformed, mismatched, or unsupported.
_Avoid_: inferred surface, active app

**Tool-start event**:
A versioned, content-free event reporting an observed agent tool-start attempt, including attempts later denied or failed. It identifies the source, session, tool name, and timestamp, with optional declared execution surface, invocation identity, and subagent attribution; it excludes tool input, command text, arguments, and output.
_Avoid_: tool completion event, tool payload

**Invocation identity**:
A stable source-provided identifier for one tool invocation, used to reconcile repeated hook delivery with transcript evidence. It may be absent when the hook does not provide one.
_Avoid_: event ID, session ID

**Subagent identity**:
An optional source-provided identifier for the subagent responsible for a tool invocation, distinct from the parent session identity. When the source provides no per-invocation subagent identity, attribution uses the session identity supplied by that source.
_Avoid_: subagent session ID

**Managed Claude hook entry**:
A named BuildrAI command handler in a selected project's `.claude/settings.local.json`. The BuildrAI host, rather than this event bridge, owns its lifecycle.
_Avoid_: global Claude hook, shared hook
