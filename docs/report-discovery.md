# Reporting workflow lifecycle

These commands are part of the normal `buildrhooks` executable:

```sh
buildrhooks report cancel --scope authorized-scope.json --request PREPARATION_OR_ACTIVE_REQUEST_ID
buildrhooks report finalize --scope authorized-scope.json --generated generated-content.json --timeout 100
buildrhooks report prepare --scope authorized-scope.json --preparation confirmed-selection.json --timeout 100
buildrhooks report discover --scope authorized-scope.json --target current-pr.json --timeout 30
buildrhooks report resolve --scope authorized-scope.json --query 'older feature work'
buildrhooks report resolve --scope authorized-scope.json --query 'raw-session-id' --source codex
buildrhooks report resolve --scope authorized-scope.json --query 'buildrai://session/codex/session-id'
```

The query is opaque and passed to BuildrAI unchanged. The app interprets its own
references and broader manual search, applies granted project access and returns
choices. Without `--source`, the CLI preserves source ambiguity; it never chooses
a result. Headers, source identities, parent/child relationships, provenance and
coverage remain the app's validated v1 values.

The publishing caller supplies a trusted, explicitly authorized `BridgeScope`:

```json
{"repository":{"host":"github.com","owner":"owner","name":"repo"},"projectID":"app-project-id","rootPath":"/absolute/canonical/project"}
```

This file is caller authorization context, not an app access grant. The app must
independently enforce its enabled projects and granted access before responding.
The CLI never reads GitHub credentials, app caches or transcripts. Root paths
must be normalized and canonical, with no symlink traversal.

Discovery takes a `BridgePullRequest` JSON file:

```json
{"baseRepository":{"host":"github.com","owner":"owner","name":"repo"},"sourceRepository":{"host":"github.com","owner":"fork-owner","name":"repo"},"number":42,"head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","commits":["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]}
```

For forks, the authorized scope repository equals the source repository. The
caller obtains the full current commit set and rechecks head freshness. The CLI
validates canonical lowercase identity, full SHA values and head membership; it
cannot prove remote completeness.

Stdout contains one terminal `BridgeResponse` JSON envelope. Successful empty
discovery is distinct from silence. Operational errors return an actionable v1
error and exit 32. Malformed or unreadable JSON input also returns sanitized
`invalidInput` with exit 32; decoder descriptions and input bodies are never
printed. If the scope cannot be decoded and validated, the local error envelope
has `version`, `requestID` and `body.error`, with no `scope`: it is an unbound
input failure, not an app `BridgeResponse` or authorization claim. Parser errors
(such as missing command options) still use the normal argument diagnostic path.
Human progress goes to stderr and
contains stage names only, never app message bodies. Waits default to 30 seconds
and accept 0.1–300 seconds. A deadline fences late responses. App setup/access
errors pass through unchanged. No response is a timeout, including when launch
succeeded but the app never became ready.

The injected native launch effect checks the installed bundle
`app.nsbuilder.BuildrAI`, leaves a running app in place, or asks NSWorkspace to
open it. An absent app and a rejected launch are distinct actionable errors.
App readiness requires a validated progress or terminal response; launch success
alone never proves readiness.

For an externally managed app/responder, `--no-launch` skips native app lookup
and launch while retaining all transport, scope validation and deadline behavior.
It does not assert app readiness; silence still returns timeout. For development
or alternate BuildrAI installations, `--app-bundle-identifier IDENTIFIER` selects
the native lookup target instead of `app.nsbuilder.BuildrAI`. `--no-launch` takes
precedence when both are supplied. These options do not grant project access.

## App-side local transport adapter

The transport is separate from Prompt Gate. Under the authorized root:

```text
.buildrai/reporting/v1/
  inflight.lock                    # persistent collection flock inode
  lifecycle.lock                   # brief completion/cancellation mutation lock
  ended/<requestID>.json           # content-free BridgeWorkflowTermination v1
  requests/<requestID>/
    request.json                   # atomically published BridgeRequest v1
    response.json                  # app atomically replaces BridgeResponse v1
```

The CLI publishes before launch. The app observes authorized project directories
and scans pending requests on startup. The app must use the shared contract
validator with its own trusted expected scope, enforce deadlines, retain the
request ID and respond in the same owned directory. Atomic response replacement
prevents partial JSON reads. A progress response is replaced by subsequent
progress or the terminal result. No HTTP/XPC/MCP listener or notification payload
is introduced.

One nonblocking flock owner per root prevents concurrent reports in that
repository; other roots proceed independently. Request directories and newly
created parents use mode 0700. Files must be owned regular files, without
symlinks, and are limited to 4 MiB. Directory ownership and symlink checks reject
unsafe existing handoffs. The lock inode remains after release to prevent two
owners from locking different inodes. A failed ownership attempt never removes
another request's files. Terminal success/failure/timeout removes only the
current request directory, except successful preparation as described below.
The lifecycle recovery and cancellation rules below also apply. Neither lock
inode may be unlinked by the app or cleanup tooling.

## Preparing confirmed sessions

`report prepare --preparation` accepts one `BridgePreparation` JSON file. It
contains `target` (the same complete PR object used for discovery), `selection`
(an ordered array of `{"source":"codex","sessionID":"session-1"}` identities),
and `disclosure` (for example
`{"policyRevision":"sharing-v1","includeOriginalPrompts":false}`).
The author confirms these values before invocation. The CLI forwards them
unchanged; it neither searches for substitute sessions nor expands scope.

A successful result is the app's validated `prepared` response. Snapshot
identity, evidence revision, selection order, disclosure, metrics, model and
reasoning settings, skill provenance, ordered evidence IDs, and coverage remain
the app's values. Missing metrics remain unavailable and zero remains zero.
Running sessions, omitted/truncated evidence and unavailable selected sessions
are represented by the app's coverage notes. At least one usable evidence record
is required; an all-unavailable packet fails with `unusableEvidence`.
The typed contract excludes raw transcript/source/tool-output fields; the app
owns sanitization of evidence text and disclosure enforcement.

Preparation ends collection while keeping its workflow alive. The CLI retains
`requests/<requestID>/request.json`, the response slot, and a separate
`packet.json` containing the validated `BridgeEvidencePacket`. The
`snapshot.requestID` is the workflow identifier for subsequent generated-content
submission. The packet is captured before returning success; later replacement
of `response.json` does not change it. The request ID cannot be reused or
overwrite an existing workflow. The collection lock is released, allowing a new
request with a fresh ID. Errors and timeouts remove only their own request
directory; they never remove another prepared workflow.

## Finalizing generated content

`report finalize --generated` accepts a v1 `BridgeGeneratedContent` JSON file
containing `snapshot`, `summaries` and `groups`. Each summary identifies
its source-aware `session`, `text` and supporting `evidenceIDs`. Each
group also carries `kind` and `outcome` matching its referenced records.
Use the exact snapshot returned by prepare, including workflow request ID,
target/head/full commit set, selection order, disclosure and evidence revision.
Every selected session needs a summary; unavailable sessions can have empty
supporting IDs as permitted by the shared contract.

Finalization acquires the repository lock, loads the retained preparation and
packet from that workflow's owned directory, validates scope/snapshot/references/
outcomes, and publishes a **fresh request ID** with a `finalize` body.
The snapshot's original `requestID` continues to identify the preparation;
the outer envelope ID identifies this finalization attempt. The app must validate
against its own captured evidence and current access, head and disclosure state.
The CLI does not generate text or supply replacement metrics. Unknown JSON
fields, including metrics added to generated input, are rejected before app
launch and return the same sanitized `invalidInput` result.

A successful terminal response contains `body.finalized._0.markdown` and
`snapshot`. Decoding that Markdown string preserves the exact app artifact,
including Unicode, line endings and trailing whitespace. The CLI emits the v1
JSON envelope and performs no Markdown rendering or rewriting. The caller can
preview and publish that same string after its own approval flow. Progress goes
only to stderr as stage names. App error codes and actionable text, including
stale snapshot, content rejection or size/narrow-selection instructions, pass
through unchanged with exit 32.

The preparation remains available during finalization and after recoverable
input, launch or app rejection, so a corrected submission can retry with a fresh
transport request. Validated final success, a validated app timeout/cancellation,
or this attempt's bounded timeout removes only the identified prepared workflow
and its finalization handoff. Mismatched/intermediate preparation responses never
complete finalization or delete its packet. Other workflows and durable tracking
records remain untouched. A workflow cannot be finalized again after terminal
cleanup. Explicit cancellation and abandoned-workflow recovery follow the rules below.

Capabilities advertise `discover`, `resolve`, `prepare`, `finalize` and `cancel` as
implemented CLI operations. The independent contracts library describes schemas
without claiming executable capabilities. Capability readiness does not prove a
compatible app adapter is installed.

## Cancellation, deadlines and recovery

`report cancel --request ID` names exactly one active request or retained
preparation in the supplied repository/project scope. It publishes a terminal
receipt without taking the collection lock, so a waiting collector can observe
it. It never launches the app. Success is a local cancellation acknowledgement:
a `cancelled` v1 response bound to the cancellation command's own fresh request
ID and target ID. It does not assert that an unavailable app has acknowledged it.
Unknown, foreign, unsafe or already ended identities are rejected.

An active finalization also checks its preparation's cancellation receipt.
Cancellation is checked before and after response reads and before completion;
a late packet/report cannot replace the cancelled result. Completion and explicit
cancellation serialize on the brief lifecycle lock. A command that loses that
lock can return busy and be retried. Closing the app's progress view does not
publish a receipt and is not CLI cancellation.

The app adapter must consume `ended/ID.json` as the shared
`BridgeWorkflowTermination` type. The receipt contains `version: 1`,
`requestID`, full `scope`, original `createdAt`/`deadline`, and `code`
(`completed`, `cancelled` or `timeout`). Validate it against the exact
original request using `BridgeValidator.validate(_:for:)` before changing
collection/preview state. Enforce the request deadline independently, including
while the CLI is absent. Scan receipts on startup and check them before emitting
a result or installing a preview. Keep the app's current preview/workflow identity
guard: a receipt for an older workflow cannot cancel or replace a newer preview.
These rules are required app integration, not behavior established by CLI fixtures.

Receipts contain no query, prompt, evidence or Markdown. They remain after packet
cleanup to prevent request-ID reuse and fence late responders; IDs must always
be fresh. The adapter must not recreate a deleted request directory. The CLI
keeps compact receipts and lock inodes; it removes temporary request/response/
packet directories after terminal completion, cancellation or timeout.

Before each new collection, recovery runs under the repository collection lock.
Only owned, non-symlink request directories with matching v1 scope/identity and
valid times are eligible. Active collectors retain that lock and cannot be
swept by competitors. Matching terminal receipts cause immediate cleanup,
including recovery from a crash after receipt publication but before deletion.
Unfinished requests expire at their collection deadline. A validated interrupted
finalization also ends its identified preparation; a malformed finalization
cannot cause another preparation to be deleted.

Prepared evidence has a **24-hour workflow lease from request creation**, separate
from its short collection deadline. The caller can generate content and retry
recoverable failures during that lease; preparation remains immutable. After the
lease expires, the next collection removes the abandoned packet and records
timeout. Recovery is demand-driven, not a background janitor. Unknown, malformed,
foreign-scope or unidentifiable crash fragments are preserved for operator repair.
Tracking queues and durable associations are outside this cleanup namespace and
are never removed by report recovery.

Contract-compatible responder tests establish command behavior, isolation and
validation. Real app/CLI pairing, source access, native app launch and agent/GitHub
acceptance remain manual gates. This change does not install, merge or release
the app or CLI.
