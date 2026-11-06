# Reporting discovery, preparation and finalization

These commands are part of the normal `buildrhooks` executable:

```sh
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
error and exit 32. Argument or malformed input errors use the normal parser/error
diagnostic path and may have no JSON result. Human progress goes to stderr and
contains stage names only, never app message bodies. Waits default to 30 seconds
and accept 0.1–300 seconds. A deadline fences late responses. App setup/access
errors pass through unchanged. No response is a timeout, including when launch
succeeded but the app never became ready.

The injected native launch effect checks the installed bundle
`app.nsbuilder.BuildrAI`, leaves a running app in place, or asks NSWorkspace to
open it. An absent app and a rejected launch are distinct actionable errors.
App readiness requires a validated progress or terminal response; launch success
alone never proves readiness.

## App-side local transport adapter

The transport is separate from Prompt Gate. Under the authorized root:

```text
.buildrai/reporting/v1/
  inflight.lock                    # persistent flock inode, not a request
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
Recovery of abandoned requests and explicit cancellation commands belong to
later lifecycle work. Finalization cleanup is described below.

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
launch; malformed input may have no JSON result.

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
cleanup. Explicit cancellation and abandoned-workflow recovery remain separate
lifecycle work.

Capabilities advertise `discover`, `resolve`, `prepare` and `finalize` as
implemented CLI operations. The independent contracts library describes schemas
without claiming executable capabilities. Capability readiness does not prove a
compatible app adapter is installed.

Contract-compatible responder tests establish command behavior, isolation and
validation. Real app/CLI pairing, source access, native app launch and agent/GitHub
acceptance remain manual gates. This change does not install, merge or release
the app or CLI.
