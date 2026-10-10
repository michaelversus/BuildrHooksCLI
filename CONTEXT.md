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

**Account usage collector**:
An explicitly enabled account-level monitor, managed by BuildrHooksCLI, that gathers usage for a provider's currently authenticated account independently of project hooks. The first release supports Codex, with other providers reserved in the design.
_Avoid_: hook monitor, project usage collector

**Background usage monitoring**:
BuildrAI's continued receipt of account usage while its windows are closed. Quitting BuildrAI ends this monitoring, independently of the account usage collector's lifetime.
_Avoid_: quit-to-background, widget collector

**Account usage snapshot**:
A provider-specific observation of account usage at its original collection time. Replaying a snapshot preserves that time and does not make it a fresh observation.
_Avoid_: live usage, replay collection

**Collection time**:
The time of a successful fresh account usage fetch, including a fetch whose usage values have not changed. It is distinct from the time a snapshot is delivered or replayed.
_Avoid_: delivery time, last changed time

**Collection status**:
A provider-specific report of the collector's condition, separate from its last successful account usage snapshot. Authentication required, temporary failure, and throttling do not replace observed usage with zero or refresh its collection time.
_Avoid_: usage value, raw provider error

**Stale usage snapshot**:
An account usage snapshot whose collection time is at least fifteen minutes old. Its observed values and original collection time remain available despite its age.
_Avoid_: empty usage, zero usage

**Account continuity**:
Confirmation that retained account usage belongs to the provider's currently authenticated account. Without that confirmation, retained usage is withheld until a fresh observation is available.
_Avoid_: unchanged authentication mode, same provider

**Clear retained usage**:
Discarding previous account usage observations held by the collector and BuildrAI without disabling collection. A later successful fetch may provide new observations.
_Avoid_: disable collection, reset account limits

**Usage invalidation**:
A durable declaration that earlier account usage observations must no longer be displayed, including after an account change or explicit clear. An unavailable BuildrAI reconciles it at the next recovery exchange with an available collector.
_Avoid_: zero usage, successful delivery

**Usage recovery exchange**:
BuildrAI's request for retained provider snapshots and collection status, including any usage invalidation. Recovery preserves original observation times and does not itself trigger fresh collection.
_Avoid_: refresh, new observation
