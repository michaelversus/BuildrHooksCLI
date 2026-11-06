# Offline commit recording (protocol v1)

The CLI records successful agent commit completion without starting or locating
BuildrAI. BuildrAI owns opt-in installation, project authorization and ingestion.
This command does not install hooks, change agent instructions, parse transcripts,
or execute Git.

```sh
buildrhooks tracking record-commit --scope authorized-scope.json --execution completion.json
buildrhooks tracking replay --scope authorized-scope.json
buildrhooks tracking acknowledge --scope authorized-scope.json --acknowledgement ack.json
```

Retain the successful command's JSON result in the agent session evidence.
`records[0].receipt` binds the canonical repository, source/session, full commit
and stable event ID. The result is `queued` only after the queue write succeeds,
or when the identical event is already retained. `acknowledged` means the
app previously acknowledged that event. It does not mean a new record was queued.

## Successful completion evidence

The managed instruction must call recording only after a successful creating Git
tool invocation. Its producer supplies one explicit `TrackingCommitExecution`:

```json
{
  "invocationID": "source-provided-tool-invocation-id",
  "session": {"source": "codex", "sessionID": "source-session-id"},
  "repository": {"host": "github.com", "owner": "owner", "name": "repo"},
  "rootPath": "/canonical/authorized/project",
  "argv": ["git", "commit", "-m", "change"],
  "exitCode": 0,
  "headBefore": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "headAfter": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
}
```

Use `claude` for Claude Code. The tool completion producer must correlate the
same invocation's successful exit and resulting commit with its pre-invocation
HEAD. Use null `headBefore` only for an unborn repository. Bare `git commit`
and `/usr/bin/git commit` argv are supported; shell strings, other Git commands,
dry runs, failed exits, unchanged HEAD, abbreviated IDs and scope mismatches are
rejected. An attempted command, observed starting HEAD or SHA appearing in text
is not completion evidence. No output-text matching or opportunistic transcript
fallback is performed.

This is producer-supplied evidence, not cryptographic authentication or independent
proof that the producer ran Git. Producers must use actual successful tool results;
they must not fabricate completion input from observed hashes. The full submitted
completion evidence is retained with the receipt for app validation. Supply only
the necessary invocation argv; do not put credentials in it.

The stable record ID is `commit-` plus SHA-256 of the JSON array
`[host, owner, repository, source, sessionID, invocationID]`. Changing the commit
for an existing event is a conflict, not replacement evidence. A fresh successful
invocation needs its own invocation ID. Rewrite mapping is a separate capability.

## App-owned authorization and exchange

The app installs an owned regular `.buildrai/tracking/v1/config.json`:

```json
{
  "version": 1,
  "scope": {
    "repository": {"host": "github.com", "owner": "owner", "name": "repo"},
    "projectID": "app-project-id",
    "rootPath": "/canonical/authorized/project"
  },
  "enabled": true
}
```

The supplied `--scope` must exactly match this configuration. Repository names
use the shared canonical lower-case identity rules. Configuration and parent
directories must belong to the current user; symlinks are rejected. The CLI never
creates authorization or modifies unrelated configuration. App and CLI coordinate
configuration changes using the same nonblocking `tracking.lock` in that directory.

Shared `BuildrBridgeContracts` types define configuration, explicit completion
evidence, records and results; `BridgeValidator.validate(_:scope:)` validates
completion evidence identically for both consumers.

The CLI owns `records.json`, an atomic v1 ledger of entries, each containing a
`TrackingRecord` and `acknowledged` Boolean. The app should use replay and
acknowledge commands rather than mutating this ledger. Readers/writers serialize
under the repository lock. Replay does not launch the app, refresh event times,
remove records or acknowledge ingestion.

For each replayed record, the app must validate version, expected scope and
completion provenance, then commit an idempotent ingestion transaction keyed by
scope and stable receipt ID. Only after that transaction commits should it submit:

```json
{"recordIDs":["commit-<stable-digest>"]}
```

If ingestion commits and the app stops before acknowledgement, replay returns the
same record. Idempotent app ingestion prevents a duplicate association. If
acknowledgement publication is interrupted, the atomic ledger is either old or
new; retrying the same acknowledgement is safe in both cases. Unknown IDs and
cross-scope acknowledgements are rejected as a whole.

Acknowledged entries remain as deduplication markers and are omitted from replay.
Neither temporary report cleanup nor cancellation touches this tracking directory.
No automatic expiry deletes pending records. Storage is bounded to 4096 entries
and 4 MiB, including acknowledgement markers; reaching that budget produces an
actionable failure, without overwriting retained state. This version does not
compact/archive markers; preserve the ledger when planning a storage upgrade.

## Status and Git success

Every result is JSON with `version`, `status`, `action` and `records`.
Failures exit 33: disabled, missingSetup, incompatibleVersion, invalidInput, busy
or failed. Diagnostic actions do not echo raw input or filesystem exceptions.
A failed write never returns a successful capture receipt. Retry with the same
completion identity after repairing permissions/disk space. A full ledger requires
a storage upgrade; deleting pending records or deduplication markers is unsafe.

App-installed Git integration must keep recording best effort and preserve the
original successful Git exit. For example, a post-success wrapper can invoke:

```sh
if ! buildrhooks tracking record-commit --scope "$scope" --execution "$completion"; then
  printf '%s\n' 'BuildrAI commit recording failed; inspect its JSON status and retry.' >&2
fi
# The original successful Git operation remains successful.
exit 0
```

The command uses bounded input/storage and a nonblocking lock, with no app wait or
network dependency. The app owns wrapper installation and must also apply its own
process deadline when invoking optional integration. This slice does not install
or modify any Git hook.

## Acceptance limits

Public command tests exercise local authorization, success receipts, closed-app
replay, invalid/non-creating evidence, identity collisions, write failures,
duplicate ingestion/acknowledgement interruption, report cleanup separation and
symlink rejection. These adapters do not establish installed BuildrAI ingestion,
real Codex/Claude completion capture, Git hook installation or GitHub acceptance.
Those require a compatible real app/CLI/library pair. No release or merge is
performed by this implementation.
