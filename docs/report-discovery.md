# Reporting discovery and resolution

These commands are part of the normal `buildrhooks` executable:

```sh
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
current request directory. Recovery of abandoned requests and multi-step
prepare/finalize/cancellation workflows belong to later lifecycle work.

Capabilities advertise only `discover` and `resolve` as implemented CLI
operations. The independent contracts library continues to describe schemas
without claiming executable capabilities. Capability readiness does not prove a
compatible app adapter is installed.

Contract-compatible responder tests establish command behavior, isolation and
validation. Real app/CLI pairing, source access, native app launch and agent/GitHub
acceptance remain manual gates. This change does not install, merge or release
the app or CLI.
