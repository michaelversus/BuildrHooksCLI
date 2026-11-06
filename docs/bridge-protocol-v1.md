# Reporting/tracking protocol v1

Contract revision **1.0.0** is the initial compatible source contract for CLI issue
#47 and BuildrAI specification #1023. This is a source revision, not a published
CLI/app release or an assertion that app integration has passed. Pin the delivery
commit containing this document when developing against it; record the published
CLI/library version and tested app revision before shipping integration.

## Independent consumption

Add this Swift package at that pinned revision and depend only on the product
`BuildrBridgeContracts`. The target imports Foundation and has no dependencies on
BuildrHooksCore, the executable, ArgumentParser, app Features, UI or credentials.
`BuildrBridgeContractsTests` is an independent consumer with only this dependency.
SwiftPM carries its compatibility fixture resource bundle into consumers.

```swift
import BuildrBridgeContracts

let results = try BridgeCompatibilityFixtures.verify()
guard !results.isEmpty, results.allSatisfy(\.matched) else {
    throw BridgeValidationError.invalidPayload
}
```

The raw corpus is available at `BridgeCompatibilityFixtures.directory` and in
`Sources/BuildrBridgeContracts/Fixtures`. App tests should run those same files
against the same validator, rather than copy a divergent set of expected results.
Each JSON fixture declares `expectedError` (null means success), its request,
trusted expected scope, optional response, and optional trusted prepared packet.
Malformed typed payloads map to `invalidPayload`. Invalid fixture metadata itself
throws; a missing or empty corpus is never passing evidence. The app has not been
executed by this slice.

## Wire encoding and identity

Use Foundation JSONEncoder/JSONDecoder without custom key/date strategies. Field
names are camelCase. Times are finite nonnegative Unix seconds (Double), not
Foundation Date epochs. Raw enums are strings. Associated-value enums are a
single case key with a payload under `_0`, as fixed by the shared JSON fixtures:

```json
{"resolve":{"_0":{"query":"session-1","source":"codex"}}}
```

Unknown enum cases and missing required fields fail decoding. Additive unknown
object fields are ignored by Codable; they cannot replace typed metric facts.
Breaking shape/meaning changes require a new protocol version. Compatible
additions require a new contract revision and updated shared fixtures.

Every request has version, requestID, scope, createdAt, deadline and a typed body.
The body determines its operation; a second contradictory operation string is
not accepted. Scope includes a canonical repository (lowercase host/owner/name,
without URL syntax or .git), opaque authorized projectID, and normalized absolute
rootPath. Callers resolve canonical repository/project/path identity and provide
the trusted expectedScope; a supplied scope is not its own authorization proof.
Validation performs no filesystem, network or app-launch effects.

PR targets retain distinct baseRepository and sourceRepository, positive PR
number, full head SHA and the complete caller-supplied current commit set.
Both 40-character SHA-1 and 64-character SHA-256 lowercase object IDs are accepted.
The head must occur in the unique nonempty set. The local scope corresponds to
the source repository, including for forks. Contract validation cannot prove
the supplied commit set is remotely complete; the publishing caller must obtain
and recheck it. Source-aware session identity is (codex|claude, sessionID); raw-ID
resolution with no source returns explicit candidate choices when ambiguous.
Header text is display information, never identity.

## Operations and results

| Request body | Successful terminal body | Meaning |
| --- | --- | --- |
| discover(PR) | discovered(candidates, coverage) | Scoped candidate discovery |
| resolve(query, optional source) | resolved(query, choices) | Explicit session resolution; multiple choices remain ambiguous |
| prepare(target, selection, disclosure) | prepared(packet) | Capture immutable sanitized evidence |
| finalize(generated content) | finalized(snapshot, markdown) | App-rendered final content |
| cancel(targetRequestID) | cancelled(targetRequestID) | Cancel only the identified workflow |
| recordCommit(receipt) | recorded(record IDs) | Successful creation association; never a mere SHA observation |
| recordRewrite(record) | recorded(record IDs) | Explicit amend/rebase/transformation mapping |
| acknowledge(record IDs) | acknowledged(record IDs) | Durable ingestion acknowledgement |

Reporting operations may emit progress stages pending/loading/collecting/
preparing/awaitingGeneratedContent/finalizing. All responses carry version,
requestID and scope. `validate(response, for: request)` rejects cross-request,
scope and operation mismatches. A cancellation uses its own envelope request ID
and names the existing workflow in targetRequestID. Progress does not imply
completion. Consumers still enforce cancellation, deadlines, stage order and
late-result fencing in their lifecycle implementation.

Errors have a typed code and nonempty actionable guidance: cancelled, busy,
timeout, incompatibleVersion, unsupported, missingSetup, missingAccess,
unresolved, ambiguous, invalidInput, unusableEvidence, appUnavailable,
launchFailed, staleSnapshot or failed. A resolved result supplies actual choices;
an ambiguous error alone must never be treated as a selected session.

Commit receipt identities bind a stable recordID, repository, source/session
and full successful commit ID. Callers emit receipts only after successful commit
creation. Rewrites retain explicit original/replacement pairs, including
many-to-one mappings. Validation rejects empty/duplicate-original/self mappings,
not repeated replacements. Acknowledgements name exact stable records; queue
owners retain records until durable ingestion is acknowledged. The schema does
not implement recording, rewrite-chain lookup, queues or ingestion.

## Evidence and generated content

Candidate headers are the app's existing disclosed header text. Provenance
distinguishes recordedCommit/rewrite/legacySuccessfulCommit from manual and
memoryProposal. Only the first three carry commit IDs. Parent and child references
retain source-aware identities without inferring contribution or rollup totals.

A snapshot binds snapshotID, originating prepare requestID, scope, complete PR
target, exact selected sessions, evidenceRevision, disclosure policy/options and
capture time. Store the validated packet immutably for the workflow. Finalization
must call `validate(request, expectedScope: scope, preparedPacket: trustedPacket)`
or `validate(generated, against: trustedPacket)`; validating the snapshot shape
alone is insufficient. All bound fields must equal the captured packet.

Packets contain exactly the selected sessions (including unavailable entries),
authoritative per-session and rollup metrics, coverage notes, sanitized ordered
activity/request excerpts, model/reasoning changes and skill evidence.
Available(0) differs from unavailable(reason); token values must be nonnegative
integers, durations nonnegative, and missing facts must not be synthesized.
Rollup arithmetic and overlap semantics remain app-owned. Included session count
is the snapshot selection count, not a fabricated metric. Skills distinguish
explicit/inferred/pending; nil model or effort remains unknown. Partial and
unavailable coverage require explanation. No usable activity is an error, while
an unavailable selected session can coexist with usable sessions.

Evidence IDs are unique within the packet. Generated summaries cover every
selected session exactly once and cite only that session's evidence. Unavailable
entries may have empty references with an explanatory summary. Timeline groups
carry kind/outcome and supported evidence IDs in packet order; validation rejects
stale, cross-session and mismatched kind/outcome references. Generated text
cannot submit replacement metrics. The app owns the remaining semantic checks,
timeline group chronology, compactness and final disclosure/rendering policy.
Reference validity does not establish that prose is semantically true.

Wire values are immutable values; they are not sanitizers or authorization
grants. The app applies sharing policy before constructing headers, excerpts,
optional prompts and packets and again before rendering. Never put raw
transcripts, tool output bodies, secrets or private filesystem paths in text.
The local scope path is transport context, not publishable evidence. No raw
source-body property or credentials model is provided. Individual text values
are bounded to 64 KiB; producers/transport must additionally enforce packet,
selection and final-output budgets. Do not log packets or prompts.

## Capabilities and command validation

Normal `buildrhooks capabilities --json` preserves existing capabilities and adds
`reportingTracking` with protocolVersions [1], contractRevision 1.0.0,
definedOperations and implementedOperations. The executable advertises
**discover and resolve** as implemented operations. The independently consumed
contracts library describes schemas without asserting executable availability.
See [report commands and local exchange](report-discovery.md). Other operations
remain unsupported until implemented.

```sh
buildrhooks capabilities --json --protocol-version 1 --operation prepare
# {"action":"Install a CLI/app pair implementing this operation. Schema support alone is insufficient.","status":"unsupported"}
# exit 31

buildrhooks capabilities --json --protocol-version 2 --operation discover
# actionable status "incompatible", exit 30
```

Use both negotiation flags together; incomplete options fail command validation.
Unknown operations return unsupported. Ready (exit 0) requires both version
compatibility and an actually implemented operation; runtime setup/app access
must still be checked by future command implementations. Historical capabilities
without reportingTracking decode as having no supported protocol or operations.

## Acceptance boundaries

The shared fixture suite covers all request families, partial/zero/unavailable
metrics, fork identities, source ambiguity, progress, success, actionable errors,
acknowledgements, malformed payloads, mismatched scope/identity and stale
snapshot/generated references. Unit tests and staged executable/resource checks
do not establish real app/source/agent/GitHub behavior, semantic summary quality,
installation, background services, accessibility or release acceptance.
Real app integration is not required for #47 and remains pending.
