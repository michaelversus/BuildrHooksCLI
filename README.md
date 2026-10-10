<p align="center">
    <img src="https://img.shields.io/badge/Swift-6.0-red.svg" />
    <img src="https://codecov.io/gh/michaelversus/BuildrHooksCLI/graph/badge.svg?token=BHX4CK5VOG"/>
</p>

# 🪝 BuildrHooksCLI

`BuildrHooksCLI` is a macOS Swift command-line tool that relays Codex and Claude Code hook events into BuildrAI's repository-local raw hook queue.

It reads JSON from standard input, normalizes the payload into a queue event, writes that event under:

`<repo>/.buildrai/inbox/raw-hooks`

and then posts a distributed macOS notification so downstream BuildrAI processes can react.

For Codex `prompt-submit` hooks, the CLI also supports a strict Prompt Gate path. Prompts are relayed normally unless the submitted prompt contains a standalone `#BuildrAI-Eval` control line. Tagged prompts pause for a repo-local BuildrAI allow/deny response before Codex continues.

For the under-the-hood design, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## 🎯 What It Is For

Use this tool when you want to capture supported coding-agent lifecycle hooks and hand them off to BuildrAI for later processing.

Today it supports:

- agent namespaces: `codex`, `claude`
- lifecycle hook events: `session-start`, `prompt-submit`, `stop`
- tool-start events: `codex tool-start`, `claude tool-start`

Codex and Claude Code `PreToolUse` hooks can emit content-free tool-start
events beginning with BuildrHooksCLI 1.3.0. Configure the hook command as
`buildrhooks codex tool-start` or `buildrhooks claude tool-start`; register each
as observational telemetry so it does not decide whether a tool may run. Older
CLI installations do not emit this event, so BuildrAI should continue using
transcript evidence or report tool activity as unavailable.

The event contains `schema_version`, `event_type`, `source`, `session_id`,
`tool_name`, and the CLI receipt `timestamp`, plus `execution_surface`,
`invocation_id`, and `subagent_id` when supported by the hook evidence. Codex
supplies its parent session ID to subagent tool hooks, so the CLI preserves
that ID and does not infer a subagent identity. Claude supplies `agent_id` for
subagent tool calls; the CLI relays it as `subagent_id`. Tool input and output
are never copied into this event.

### BuildrAI Companion Monitoring execution-surface producer

BuildrHooksCLI 1.2.0 and later supports BuildrAI's terminal Companion Monitoring
producer capability through a compatibility adapter for Codex transcript
metadata. When the hook's explicit `transcript_path` contains a matching
`session_meta` record with `originator: codex_cli_rs` and `source: cli`, each
emitted event includes:

```json
"execution_surface": {
  "kind": "terminal",
  "instanceID": "codex-session:<session_id>"
}
```

For any other nonempty, session-matched `originator`, the event instead
declares `"kind": "desktop"` with the same session-scoped ID. This includes
`Codex Desktop` with `vscode` or `subagent` sources and the
`codex_work_desktop` variant. Missing, malformed, unreadable, or mismatched
metadata emits no surface; normal durable inbox behavior remains unchanged.
This mapping is intentionally limited to known observed Codex metadata, so
future schema changes are isolated to the adapter.

Claude Code Desktop uses the hook-declared transcript only. A matching JSONL
record whose latest `entrypoint` is `claude-desktop` emits:

```json
"execution_surface": {
  "kind": "desktop",
  "instanceID": "claude-session:<session_id>"
}
```

Missing, malformed, mismatched, or non-Desktop transcript evidence emits no
surface. A session later resumed in a terminal likewise emits no Desktop
surface. BuildrAI's host app owns project selection and the safe management of
its named `.claude/settings.local.json` entries; this CLI does not edit Claude
settings.

## 🛠️ Installation

### 🍺 Homebrew

```bash
brew tap michaelversus/BuildrHooksCLI https://github.com/michaelversus/BuildrHooksCLI.git
brew install buildrhookscli
```

This installs the executable as:

```bash
buildrhooks
```

### 🔨 Build From Source

```bash
swift build -c release
```

Run the built executable directly:

```bash
.build/release/BuildrHooksCLI --version
```

Or install it under `buildrhooks` using the provided `Makefile`:

```bash
make install
```

## 🧪 Development

This project uses SwiftFormat and SwiftLint in strict mode. Install both tools
and enable the tracked git hook before pushing changes:

```sh
brew install swiftformat swiftlint
git config core.hooksPath .githooks
```

The pre-push hook validates formatting and lint rules, attempts auto-fix when
possible, then stops the push if those fixes changed files so you can review
and commit them first:

```sh
swiftformat --lint --config .swiftformat .
swiftlint lint --strict --config .swiftlint.yml
```

To apply formatting locally, run:

```sh
swiftformat --config .swiftformat .
```

## 💻 Command Line Usage

### ℹ️ Version and Help

```bash
buildrhooks --version
buildrhooks --help
buildrhooks codex --help
buildrhooks claude --help
buildrhooks capabilities --json
```

### ⌨️ Basic Command Shape

```bash
buildrhooks codex <event>
buildrhooks claude <event>
```

The hook payload must be provided on standard input as JSON.

### 🚀 Examples

```bash
echo '{"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}' | buildrhooks codex session-start
```

```bash
echo '{"session_id":"session-42","prompt":"Summarize this repo","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}' | buildrhooks codex prompt-submit
```

```bash
echo '{"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}' | buildrhooks codex stop
```

Claude Code hooks use the same normalized event names:

```bash
echo '{"session_id":"session-42","prompt":"Summarize this repo","transcript_path":"/tmp/session-42.jsonl","model":"claude-opus"}' | buildrhooks claude prompt-submit
```

Use `buildrhooks capabilities --json` for a versioned, machine-readable list
of supported agents, lifecycle events, and Claude Desktop transcript-surface
support. BuildrAI should block Claude setup when this document does not declare
the required capability.

## 📦 Supported Payloads

### `session-start`

Expected JSON fields:

- `session_id` required
- `transcript_path` optional
- `model` optional

Example:

```json
{
  "session_id": "session-42",
  "transcript_path": "/tmp/session-42.jsonl",
  "model": "gpt-5"
}
```

### `prompt-submit`

Expected JSON fields:

- `session_id` required
- `prompt` required
- `transcript_path` optional
- `model` optional

Example:

```json
{
  "session_id": "session-42",
  "prompt": "Summarize this repo",
  "transcript_path": "/tmp/session-42.jsonl",
  "model": "gpt-5"
}
```

### Prompt Gate Control Tag

For `prompt-submit`, a standalone control line opts into strict Prompt Gate evaluation:

```text
#BuildrAI-Eval
Refactor the parser and update its tests.
```

The tag must be on its own line, with optional surrounding whitespace. Mentions inside prose or fenced code blocks are ignored. When the tag is recognized, the CLI writes both the exact `original_prompt` and an `evaluation_prompt` with control-tag lines removed.

Tagged prompts require this repo-local marker:

```text
<repo>/.buildrai/hooks/prompt-gate.json
```

The marker contains local setup state only, such as `version`, `enabled`, and optional project metadata. It must not contain evaluator instructions or policy text.

Transient evaluation files live under:

```text
<repo>/.buildrai/hooks/prompt-eval/
```

The CLI writes `inflight.lock` and `request.json`, waits for BuildrAI to write `response.json`, then cleans files owned by the request. Untagged prompts ignore Prompt Gate marker state and keep the normal best-effort relay behavior.

### `stop`

Expected JSON fields:

- `session_id` required
- `transcript_path` optional
- `model` optional

Example:

```json
{
  "session_id": "session-42",
  "transcript_path": "/tmp/session-42.jsonl",
  "model": "gpt-5"
}
```

## ⚙️ How It Works

For a valid command and valid payload, the CLI will:

1. Read the JSON payload from stdin.
2. Resolve the repository root by walking upward until it finds `.git`.
3. Convert the payload into a normalized `RawHookEvent`.
4. Write that event as JSON into the repository-local queue.
5. Post a distributed macOS notification.

For `codex prompt-submit` payloads that contain a recognized `#BuildrAI-Eval` control tag, the CLI first validates Prompt Gate setup, writes a request under `.buildrai/hooks/prompt-eval`, and waits up to 24 seconds for BuildrAI's response. Allowed prompts continue into the raw hook queue. Denied prompts and Prompt Gate errors do not create normal raw hook events.

The queue directory is:

```text
<repo>/.buildrai/inbox/raw-hooks
```

The CLI also ensures this archive directory exists:

```text
<repo>/.buildrai/archive/raw-hooks-processed
```

## 🗂️ Output Files

Each queued event is written as a JSON file with a name like:

```text
20260428T102530123Z-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.json
```

The file contains normalized metadata such as:

- `agentKind`
- `eventKind`
- `createdAt`
- `currentWorkingDirectory`
- `repositoryRootPath`
- `sessionID`
- `transcriptPath`
- `model`
- `rawPayload`

## ⚠️ Error Behavior

There are two main categories of failure.

### 🚫 Usage Errors

These happen when the command itself is invalid, for example:

- unsupported agent
- unsupported event
- wrong argument count

These are treated as command errors.

### 📭 Payload or Queueing Errors

These happen after the command is recognized, for example:

- malformed JSON
- missing required JSON fields
- wrong JSON field types
- filesystem write failures

These are logged as warnings to stderr and do not crash the command flow intentionally.

Example warning:

```text
BuildrHooksCLI warning: Invalid Codex hook payload.
```

### 🚦 Prompt Gate Exit Codes

Tagged prompts fail closed with stable exit codes:

- `0`: allow or untagged bypass
- `10`: denied by evaluator
- `11`: another Prompt Gate request is already in flight
- `12`: evaluator response timed out
- `13`: Prompt Gate unavailable or not enabled for the repo
- `14`: invalid Prompt Gate configuration
- `15`: evaluation prompt is over 6000 characters
- `16`: protocol error or malformed response

## 📁 Repository Root Rules

The CLI writes into the nearest ancestor directory containing `.git`.

That means if you run the command from:

```text
/path/to/repo/subdir/deeper
```

and `/path/to/repo/.git` exists, the event is written under:

```text
/path/to/repo/.buildrai/inbox/raw-hooks
```

If no `.git` marker is found, the current working directory is used as the root.

## Typical Integration Pattern

A hook producer usually does something like this:

1. Detect a Codex lifecycle event.
2. Build the matching JSON payload.
3. Pipe that payload into `buildrhooks codex <event>`.
4. Let another BuildrAI component watch the raw queue and process the file.

## Testing

Run the test suite with:

```bash
swift test
```

The package uses the Swift Testing framework and includes coverage for CLI entrypoint behavior, repository-root discovery, queue writing, payload validation, and version configuration.

## Current Limitations

- Claude settings installation and repair are owned by the BuildrAI host app.
- Only `session-start`, `prompt-submit`, and `stop` are supported.
- The tool assumes macOS for distributed notifications.
- Queue persistence is filesystem-based and repository-local.

## Contributions

Issues and pull requests are welcome. Please run `swift test` before submitting and include coverage for new behaviors when possible.

# Hook version marker

After a hook event is successfully queued, BuildrHooksCLI atomically writes
`.buildrai/bridge-cli-version.json` with the CLI version that handled that hook:

```json
{ "version": "1.2.3" }
```

This records the version that most recently handled a hook in that repository.
It does not report every `buildrhooks` executable installed on the machine. After
a Homebrew upgrade, the marker remains at the older version until the next
successful hook invocation in that repository.

## Account usage

```sh
buildrhooks usage refresh --provider codex
buildrhooks usage watch --provider codex
buildrhooks usage clear --provider codex --json
buildrhooks usage refresh --provider codex --json --codex-path /absolute/path/to/codex
```

The provider selection is explicit and repeatable; repeating `codex` collects it once.
Only Codex is currently supported. Install Codex separately and sign in using its own
commands. The collector finds an executable on `PATH`, or uses the absolute
`--codex-path` override. It never forces login or reads authentication files.

Without a running collector, a refresh initializes an owned Codex app-server stdio connection, reads account
state, then requests full `account/rateLimits/read` data within a shared thirty-second
deadline. All available primary and secondary windows are normalized, preferring
multi-bucket data over the legacy single bucket. Window roles do not imply durations.
Missing duration/reset stays absent, missing windows stay absent, and percentages
above 100 are retained. Credits and identifying details are excluded.

Every successful fresh usable fetch, including unchanged values, persists a new
observation and attempts macOS distributed publication. Notifications do not launch
BuildrAI, write its App Group, or acknowledge receipt. Actual receipt/widget behavior
requires the separate BuildrAI integration check.

Minimal state and per-provider revisions are atomically retained with owner-only file
permissions at `~/.codex/buildr-artifacts/account-usage.json`. Failure preserves a
previous observation's time and values. One-shot refresh publishes only fresh usage;
foreground watch also answers verified recovery requests with original timestamps and
revisions. Private salted fingerprints establish account continuity when sufficient
identity exists; otherwise retained usage is withheld until a fresh usable fetch.
Account changes durably invalidate previous-account snapshots, even with unavailable
new limits.
The existing hook commands and prompt-gate exits retain
their behavior.

JSON output contains `provider`, `outcome`, optional `retryAt`, `localCleared`, `freshSnapshot`, and
`publicationAttempted`. A fresh snapshot plus attempted publication is required for
success. `publicationAttempted` does not mean confirmed delivery. On a reported
publication error the command returns failure even if an earlier notification was
attempted. Error diagnostics contain only fixed outcome codes, never raw Codex errors.

| Outcome | Exit code |
| --- | --- |
| `refreshed`, `cleared` | 0 |
| `authentication_required` | 10 |
| `temporary_failure` | 11 |
| `throttled` | 12 |
| `timeout` | 13 |
| `usage_unavailable` | 14 |
| `persistence_failure` | 15 |
| `publication_failure` | 16 |
| `executable_unavailable` | 17 |
| `cancelled` | 18 |
| `unsupported_provider` | 19 |
| `collector_running` | 20 |
| `coordination_unavailable` | 21 |
| `invalidated` (fetch superseded by clear) | 22 |

Authentication failure, timeout, temporary failure, throttling, and absent usable limits
never become zero usage or refresh the old observation. A provider retry restriction,
when supplied, is persisted and returned as `retryAt`. Argument validation uses the CLI parser's
standard errors. The additive capabilities fields `accountUsageRefreshProviders`, `accountUsageWatchProviders`, `accountUsageClearProviders`, and
`accountUsageSchemaVersions` advertise refresh/watch/clear support and schema 1.

The shared notification contract is documented in [account usage wire](docs/account-usage-wire.md).

Foreground watch owns one persistent Codex app-server connection, reconnecting on
bounded temporary-failure retries. It fetches at startup, after macOS wake, and every
five minutes. Account/authentication and limit events request coalesced full reads;
sparse event values never become observations. Starts are spaced by at least thirty
seconds per provider, with a thirty-second total fetch timeout. Temporary failures
retry exponentially from thirty seconds to five minutes with up to 20% jitter,
capped at five minutes. Longer provider restrictions take precedence and survive
restart, including for one-shot refresh. Authentication failures wait for an account
or login event or the next scheduled poll. Wake also requests a scheduled check.
Interrupting watch with Control-C or SIGTERM closes its owned connection and cancels
pending work; incomplete results are not published. Exit code 18 denotes cancellation
of a refresh. A watch does not imply that the BuildrAI receiver is running.
Values are stale once at least fifteen minutes old, using their original collection
time; failures never change that time. Independent provider state is reserved for
future implementations; selecting Claude currently returns a validation error.

Foreground watch answers `ai.buildrai.account-usage-requested` notifications with no
userInfo, replaying selected available providers at most once per second globally.
Recovery includes retained status and invalidation even without a snapshot, triggers
no limits fetch, and cannot acknowledge delivery. Both collector and receiver must be
available. Restart verification uses optional routing identity; protocol versions
without it report pending collection (or a known failure) and withhold cached usage.

Watch and one-shot commands share an exclusive per-user lock at
`~/.codex/buildr-artifacts/account-usage.lock`. A second watch exits with
`collector_running` and a redacted diagnostic. Refresh delegates to the running
collector through `account-usage.sock` beside the cache, with owner-only permissions
and peer-user checks on both ends. The collector serializes commands with polling,
recovery, and provider events. Requests available together share one actual result;
requests arriving during collection receive the next actual result, usually a
`throttled` outcome with `retryAt` (Unix milliseconds), rather than bypassing spacing.

Refresh waits at most forty seconds, including coordination and the thirty-second
fetch deadline, and responds to interruption. The private channel accepts
version 1 refresh, clear, and status-ping requests for Codex, bounds frames to 4 KiB, caps queued clients,
and drops incomplete requests after two seconds once accepted. Disconnected clients
do not stop the shared collector. Endpoint recovery requires holding the lock;
commands never remove a live collector's endpoint or lock file. Distributed recovery
notifications remain display replay requests and cannot invoke state-changing commands.
A delegated `--codex-path` does not replace the running collector's executable.

### Clear retained usage

`buildrhooks usage clear --provider codex --json` discards Codex observations and
atomically commits a newer invalidation before attempting status publication. It
uses the running collector's private socket, or the same exclusive lock without a
collector. It preserves revisions, account fingerprints and scheduling restrictions;
a pre-clear fetch cannot recommit its discarded observation. Other providers' state
is untouched. No Codex limits fetch or authentication is needed to clear locally.

Clear is distinct from disabling collection: it does not reset account limits or
stop polling. A later fresh usable fetch can populate usage again. The service disable command stops
collection and automatic startup while preserving recovery metadata. Replayed
observations keep their original collection times; publication never refreshes age.

JSON reports `localCleared` and `publicationAttempted` independently, with `cleared`
only after the marker is committed and publication attempted. Publication failure
returns a nonzero outcome with `localCleared: true`. Persistence failure can occur
after atomic replacement: read-back reports `localCleared: true` only when the expected
invalidation and absent snapshot are verified; otherwise it reports false. Publication
is not attempted after persistence failure, and durability is not confirmed. Neither result confirms
BuildrAI or widget clearing. Distributed notifications have no acknowledgement or
queue. Clear never launches or activates BuildrAI. With BuildrAI quit and the service
disabled, reconciliation waits until both receiver and collector are available for
a recovery exchange, which includes the invalidation even without a snapshot.

Pending manual receiver check: deliver a snapshot to BuildrAI, clear while it is
running, and verify its retained/widget values disappear. Repeat with BuildrAI quit
and collector stopped: verify no app launch, then restart both, request recovery,
and deliver the saved pre-clear snapshot late; verify it cannot restore values.
Confirm a later fresh fetch repopulates values with its actual collection time.
These are separate integration checks, not performed by the simulated tests.

### Opt-in usage login service

Installing `buildrhooks` does not enable background collection. To explicitly consent
for the selected provider, run:

```sh
buildrhooks usage service enable --provider codex
buildrhooks usage service status --json
buildrhooks usage service disable --json
```

`--provider codex` is required and repeatable. Duplicate selections collect once;
future providers will require explicit selection. Enable validates the installed CLI
and Codex executables before changing configuration. Codex must be installed and
signed in separately; it is never installed or signed in automatically. For a custom
installation or a changed executable location, use absolute overrides:

```sh
buildrhooks usage service enable --provider codex \
  --cli-path /absolute/stable/buildrhooks --codex-path /absolute/stable/codex --json
```

The user LaunchAgent `~/Library/LaunchAgents/ai.buildrai.account-usage.plist` directly
executes `buildrhooks usage watch` without a shell, immediately on enable and at future
logins. It uses the collector's persistent Codex app-server connection. Prefer stable
installation paths, including stable package-manager symlinks. Re-enabling retains
configured executable paths across upgrades unless an explicit override replaces them;
it validates paths again before restarting. Missing executables produce an actionable
redacted stderr diagnostic and a machine-readable error with `--json`. Inspect
`executablesValid` in service status, repair the installation or pass overrides, and
re-enable. Re-enabling updates configuration without creating another collector.
Stop a foreground `usage watch` first; the same user-global lock prevents duplicate
ownership, and service commands never terminate an unrelated foreground collector.

Status separates `configured` (saved LaunchAgent), `installed` (loaded in launchd),
`processRunning` (launchd reports a running service), and `collectorAvailable` (the
private control endpoint answered a bounded ping). A running process may be temporarily
unavailable while a fetch is in progress. `retainedCollectionStatus` contains historical,
committed status with its original observation time; even retained `ready` does not
prove the process is running or data is fresh. Status pings never trigger a usage fetch.
JSON stdout contains no executable paths, fingerprints, or account details. Diagnostics
go to stderr.

Disable requests cancellation through launchd and removes automatic startup while
retaining committed observations and durable invalidation/recovery metadata. A pending
shutdown is reported explicitly after a bounded wait. Service lifetime is independent
of BuildrAI: opening, closing, or quitting BuildrAI does not manage it. BuildrAI quitting
ends the app's receiver, while the independently enabled collector continues. The
service never writes BuildrAI's App Group. Use `usage clear --provider codex` separately
to discard retained usage. Capability `accountUsageServiceProviders` advertises the
supported opt-in service providers.

### Crash recovery and bounded shutdown

An enabled LaunchAgent uses `KeepAlive` and a thirty-second `ThrottleInterval` so
collector exits restart with at least thirty seconds between launchd spawn attempts. Codex connection failures separately
use the persisted exponential fetch retry policy. Restart reacquires exclusive
ownership, verifies account continuity before cached replay, and preserves explicit
provider/path configuration, revisions, invalidation and retry restrictions. Atomic
cache commits survive interrupted fetch/clear/publication; incomplete temporary files
are ignored and corrupt ordering fails closed rather than resetting revisions.

`usage service status --json` adds `processHealth`: `configured` for saved but unloaded
configuration, `enabled` for a running answering service, `restarting` for a loaded
restart-managed job waiting to run, `unavailable` for invalid executables or a running
service whose endpoint cannot answer, and `stopped` after successful disable. These
management diagnostics never add notification status codes. A busy fetch may make the
endpoint temporarily unavailable; historical `ready` does not mean fresh/current usage.

Disable removes startup configuration before booting out the job and its restart policy.
Inspection, bootout and ownership waiting share a five-second deadline. Cancellation
withholds late fetch/recovery results and closes the owned Codex connection. The owned
child gets up to four seconds of graceful termination, then direct forced termination
if necessary, reserving one second within the parent deadline. Launchd additionally
retains job process-group cleanup; Foundation children need not share that group. Only owned processes
are terminated. Committed cache/metadata remain. A failed bootout returns an error and
may leave a loaded job running/restarting despite removal of future-login configuration;
retry disable and inspect status. A pending ownership release reports `shutdown_pending`.

The real BuildrAI receiver remains a separate integration task: validate untrusted
messages, atomically retain widget data, show observations stale at fifteen minutes,
and reconcile offline invalidation at the next available recovery exchange. See the
[precise pending receiver checklist](docs/account-usage-wire.md#separate-buildrai-integration-checklist).
Ordinary tests simulate service/process/provider adapters and notification publication;
they do not install a real login service, use live credentials, probe delivery, or claim
actual macOS receipt or guaranteed App Store approval.
