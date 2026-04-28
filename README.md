# BuildrHooksCLI

`BuildrHooksCLI` is a macOS Swift command-line tool that relays Codex hook events into BuildrAI's repository-local raw hook queue.

It reads JSON from standard input, normalizes the payload into a queue event, writes that event under:

`<repo>/.buildrai/inbox/raw-hooks`

and then posts a distributed macOS notification so downstream BuildrAI processes can react.

For the under-the-hood design, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## What It Is For

Use this tool when you want to capture Codex lifecycle hooks from the command line and hand them off to BuildrAI for later processing.

Today it supports:

- agent namespace: `codex`
- hook events: `session-start`, `prompt-submit`, `stop`

## Installation

### Homebrew

```bash
brew tap michaelversus/BuildrHooksCLI https://github.com/michaelversus/BuildrHooksCLI.git
brew install buildrhookscli
```

This installs the executable as:

```bash
buildrhooks
```

## Command Line Usage

### Version and Help

```bash
buildrhooks --version
buildrhooks --help
buildrhooks codex --help
```

### Basic Command Shape

```bash
buildrhooks codex <event>
```

The hook payload must be provided on standard input as JSON.

### Examples

```bash
echo '{"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}' | buildrhooks codex session-start
```

```bash
echo '{"session_id":"session-42","prompt":"Summarize this repo","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}' | buildrhooks codex prompt-submit
```

```bash
echo '{"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}' | buildrhooks codex stop
```

## Supported Payloads

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

## How It Works

For a valid command and valid payload, the CLI will:

1. Read the JSON payload from stdin.
2. Resolve the repository root by walking upward until it finds `.git`.
3. Convert the payload into a normalized `RawHookEvent`.
4. Write that event as JSON into the repository-local queue.
5. Post a distributed macOS notification.

The queue directory is:

```text
<repo>/.buildrai/inbox/raw-hooks
```

The CLI also ensures this archive directory exists:

```text
<repo>/.buildrai/archive/raw-hooks-processed
```

## Output Files

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

## Error Behavior

There are two main categories of failure.

### Usage Errors

These happen when the command itself is invalid, for example:

- unsupported agent
- unsupported event
- wrong argument count

These are treated as command errors.

### Payload or Queueing Errors

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

## Repository Root Rules

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

- Only the `codex` agent is supported.
- Only `session-start`, `prompt-submit`, and `stop` are supported.
- The tool assumes macOS for distributed notifications.
- Queue persistence is filesystem-based and repository-local.

## Contributions

Issues and pull requests are welcome. Please run `swift test` before submitting and include coverage for new behaviors when possible.
