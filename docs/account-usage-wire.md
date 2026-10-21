# Account usage wire contracts

Delivered by `usage refresh --provider codex` and the foreground
`usage watch --provider codex` collector under
[PRD #20](https://github.com/michaelversus/BuildrHooksCLI/issues/20). The sender uses
Codex-owned authentication and its full account limits read; see the
[official app-server protocol](https://learn.chatgpt.com/docs/app-server).
Installed schema generation was inspected for initialization, account/read and
account/rateLimits/read; account identity can be absent and is never assumed available.

macOS distributed notifications are untrusted, observable, spoofable broadcasts with
no durable queue or acknowledgement. Both notifications carry a JSON **string** under
`userInfo["payload"]`, not nested JSON objects. No credentials, email, account IDs,
fingerprints, filesystem paths, prompts, transcripts, raw responses/errors, display
labels, plan names or credits are included. No BuildrAI launch or App Group write occurs.

`ai.buildrai.account-usage-updated` contains:

```json
{"schemaVersion":1,"cliVersion":"1.2.7","provider":"codex","revision":2,"collectedAt":1000000,"windows":[{"limitCode":"codex","role":"primary","usedPercent":125,"durationMinutes":17,"resetsAt":2000000}]}
```

`ai.buildrai.account-usage-status-updated` contains:

```json
{"schemaVersion":1,"cliVersion":"1.2.7","provider":"codex","revision":3,"observedAt":1000000,"status":"ready","latestInvalidationRevision":0}
```

Both notifications optionally include `cliVersion` as a JSON String: the semantic
version of the currently publishing collector/executable, from the same build-time
source as `buildrhooks --version`. It is bounded to 128 UTF-8 bytes and uses SemVer
`major.minor.patch` with optional prerelease/build identifiers. Malformed present
versions fail wire validation. Absence (or JSON null) means unknown; receivers must
not substitute a repository hook marker or infer observation freshness from it.
Older v1 consumers ignore this additive field; pre-field retained caches remain readable.

The publisher stamps outgoing copies for refresh, watch (including pending/failure
status), clear and recovery replay. Retained observations are not rewritten. A replay
may carry a newer publisher version with the same revision, original `collectedAt` or
`observedAt`, and latest invalidation marker. This metadata does not establish account
continuity or change ordering, scheduling, request semantics or the schema version.
Receivers may inspect sender metadata independently of observation acceptance; equal
revisions still must not be treated as fresh usage. An absent version is displayed as
unknown. The payload-size and privacy rules still apply to the complete message.

All time fields (`collectedAt`, `observedAt`, `resetsAt`, and optional `retryAt`) are
Unix milliseconds; `durationMinutes` is the provider's actual integer duration.
Optional fields are omitted when unknown. Primary/secondary roles imply no particular
duration. `limitCode` preserves the provider's non-account-specific bucket key (legacy
fallback uses its limitId or `codex`). Codes use ASCII letters/digits, dot, underscore,
and hyphen, with length 1 through 128 bytes. Invalid codes fail the observation rather
than broadcasting potentially identifying text. Missing windows are not synthesized.
Multi-bucket data takes precedence, without duplicating the legacy representation.
Codex usage values are not clamped to 100. Claude v2 has its own bounded percentage contract below.

Status codes are `pending`, `ready`, `authentication_required`, `temporary_failure`,
`throttled`, and `usage_unavailable`. Timeout, executable and parsing failures map to
`temporary_failure` status while retaining distinct CLI outcomes where applicable.
Each provider has a durable monotonically increasing revision shared by emitted
observations; receivers track snapshot and status revision floors **separately**.
The latest invalidation revision is included in status, initially zero. Account changes
durably invalidate earlier snapshots before new-account state is published. Explicit
`usage clear --provider codex` also commits invalidation before publishing status,
with no snapshot retained. A fetch started before clear is discarded; a later fresh
fetch has a revision above the marker and can populate usage again. Clear preserves
private continuity, ordering and retry restrictions and never stops collection.

`UsageWire` validates both encoding and decoding. Payloads are limited to 64 KiB of
UTF-8, Codex schema version must be 1 (Claude uses v2 below), provider/required fields must be well formed, revision
must be positive, windows must be nonempty with unique limit-code/role pairs, percentages must be finite and nonnegative,
durations must be positive when present, and timestamps must be nonnegative.
Observation timestamps can be at most two minutes ahead of the receiver's clock.
Future reset/retry times and arbitrarily old valid observations are accepted. Decoder
revision floors reject duplicates/superseded messages; snapshot decoding also rejects
revisions at or below the latest invalidation. A newer status never by itself rejects
an older retained snapshot. Untrusted payload validation does not authenticate a sender.

The primary test seam is `UsageRuntime`, with injected provider fetcher, parser,
clock, notifier, output and storage. Simulated full responses and fake executable
transports exercise this path without live credentials. The collector
persists minimal state atomically at `~/.codex/buildr-artifacts/account-usage.json`,
with owner-only file permissions. Private Codex metadata contains a random salt
and SHA-256 account fingerprint, never a raw ID or email. These fields are excluded
from notifications and diagnostics. A pending status is best-effort published;
final storage/publication failure is a nonzero CLI outcome. A successful refresh
reports attempted publication only, not receipt.

## Recovery

For legacy Codex recovery, an available foreground collector listens for `ai.buildrai.account-usage-requested`
with **no userInfo**. Requests containing userInfo are ignored. It replays every available
selected provider's valid snapshot and collection status, including known failures and
invalidation when no snapshot remains. Requests do not fetch limits, launch BuildrAI,
or bypass thirty-second fetch spacing/retry restrictions. Replies are coalesced globally
to at most one per second; there is no acknowledgement or durable request queue.

Replay preserves snapshot/status revisions, collection and status observation times,
and retry times. Stale values retain their real age (fifteen minutes marks staleness);
delivery does not refresh them. Snapshot and status ordering remain independent.

Before restart replay the collector uses a bounded account identity read without a
limits fetch. It accepts only the optional `workspaceRouting.chatgptAccountId`
(experimental in the inspected installed schema) matching the stored fingerprint;
email, plan, provider name and authentication mode cannot prove continuity. The full
limits response's nullable `accountId` takes precedence for observation ownership.
Installed protocol versions may supply no routing ID at all: in that case cached usage
is withheld, ready status becomes pending, and known failure status remains available
until a fresh usable scheduled fetch succeeds. An identity-free fresh observation may
be replayed during the same uninterrupted collector session, but cannot establish
continuity for a later restart. Sparse authentication events revoke that session proof
before recovery; they request a throttled full read rather than providing observations.
Connection loss and identity-free failed/unavailable full reads also revoke prior
session proof; independently retained failure status is still replayed.

Detected identity changes discard previous-account snapshots and persist a newer
invalidation before publishing state, even when new limits are unavailable. Salt,
fingerprint, ordering, invalidation, status, and observations are committed together.
Persistence failure withholds unverified usage. This does not guarantee detection of
an external sign-in change that Codex does not report; the next full read/identity check
must supply sufficient identity. Recovery requires both an available collector and a
receiver; a stopped collector cannot answer requests.

Pending manual integration: with BuildrAI's separately implemented receiver running,
verify actual snapshot/status string delivery and retained/widget presentation. Repeat
with BuildrAI fully quit and confirm refresh does not launch it. These checks were not
performed by the simulated-notifier tests. Live account fetch and service installation
are outside this slice's automated validation.

## Separate BuildrAI integration checklist

The CLI's delivered sender/service contract is independent of the BuildrAI receiver.
BuildrAI must validate the bounded schema as untrusted display data, retain separate
snapshot/status revision floors, apply invalidation atomically to widget storage, and
retain stale values at fifteen minutes with their original collection time. The CLI
never owns the app's background setting, Quit behavior, or App Group.

Pending reviewer actions with the actual receiver and distributed notification transport:

1. Receive a fresh snapshot and separate status, then request recovery; verify original
   timestamps/revisions and all available windows in retained/widget presentation.
2. Advance observation age to fifteen minutes; verify stale values remain and a failure
   status does not refresh their age. Deliver an older snapshot after a newer status;
   verify independent ordering and rejection of superseded revisions.
3. Clear while the app is running; verify immediate local invalidation is accepted.
   Quit BuildrAI and stop the collector, clear locally, then start both and request
   recovery. Verify eventual widget clearing and rejection of delayed pre-clear data.
4. Change accounts/restart with missing identity; verify unverified retained values are
   withheld, account change invalidates earlier values, and a later usable fetch can
   populate new observations above the invalidation floor.
5. Close windows and verify background receipt; Quit/Command-Q and verify full app exit.
   The enabled collector continues without launching/activating BuildrAI. Disable removes
   the job, stops its owned children within five seconds, and does not restart it.
6. For approved distribution, verify real userInfo string delivery from the installed
   CLI to the receiver. Simulated publication, startup configuration, and process tests
   do not establish OS delivery, live account compatibility, or App Store approval.

No real receiver check or login-service installation was performed by ordinary tests.

## Claude provider-scoped v2 contract

Specification [#32](https://github.com/michaelversus/BuildrHooksCLI/issues/32) adds
Reported Provider Usage for Claude. Account attribution is unavailable: concurrent
sessions or account changes may report another account. A configuration root is a
setup scope, never an account. Codex keeps the v1 account-continuity behavior above;
Claude is never interpreted as Codex v1 and has no account fingerprint or label.

The existing notification names and `object=nil` remain unchanged. Snapshot/status
notifications still carry one UTF-8 JSON string in `userInfo["payload"]`, bounded to
64 KiB. Provider strings and replay tokens do not authenticate local senders.

A nonempty Claude snapshot uses `ai.buildrai.account-usage-updated`:

```json
{"schemaVersion":2,"cliVersion":"1.2.8","provider":"claude","scope":"provider","revision":5,"receivedAt":900000,"windows":[{"limitCode":"claude","role":"primary","durationMinutes":300,"usedPercent":0}]}
```

A Claude status uses `ai.buildrai.account-usage-status-updated`:

```json
{"schemaVersion":2,"cliVersion":"1.2.8","provider":"claude","scope":"provider","revision":6,"observedAt":950000,"status":"ready","latestInvalidationRevision":0,"retainedSnapshotRevision":5,"receivedAt":900000}
```

These versions are synthetic fixture metadata, not a claim that release 1.2.8
supports Claude. The minimum compatible bridge version is the actual release that
delivers this implementation; release/package evidence must establish it.

`receivedAt` is the bridge's acceptance time in Unix milliseconds. It does **not**
verify when Claude measured quota; even a new callback can contain upstream cached
data. `UsageTimestamp.received` preserves that provenance through persistence/replay;
`collectedAt` is absent for Claude, and the internal optional collection-time accessor
is nil. Codex retains `UsageTimestamp.collected` and its unchanged `collectedAt` wire
field. `observedAt` dates a status event independently of the retained receipt time.
Replay and rendering never redate either observation.

Exactly two window identities are supported for Claude: `limitCode=claude`, role
`primary` with duration 300 minutes, and role `secondary` with duration 10080 minutes.
A snapshot has one or both, without duplicates. `usedPercent` must be a finite JSON
number in 0...100 inclusive; booleans and strings are rejected. Zero is valid.
`resetsAt` is optional/null when unknown, otherwise a nonnegative integral Unix
millisecond value. Callback normalization converts documented integral Unix seconds
with overflow checks; passed resets do not synthesize capacity. Unknown windows are
not fabricated. Every valid callback replaces the entire report, so a missing window
is unavailable rather than copied from an earlier callback.

The accepted pairs are **only** Codex v1 with no scope and Claude v2 with
`scope=provider`. Unknown versions/providers/scopes, mixed collection/receipt fields,
empty snapshots, invalid identities, malformed timestamps and ordering floors are
rejected. Snapshot/status observation times remain bounded to two minutes ahead of
the receiver clock; old observations and future reset/retry times remain valid.
Claude statuses require valid bounded SemVer `cliVersion`; snapshots retain the
optional publisher field. Codex's existing optional version meaning is unchanged.

Claude statuses require `retainedSnapshotRevision` explicitly, either a positive
revision above invalidation and no greater than the status revision, or JSON `null`.
A `ready` status requires a retained revision and its original `receivedAt`.
`temporary_failure` may retain the previous revision/receipt unchanged, advancing
only status ordering. A valid quota-free callback invalidates older usable data and
publishes `usage_unavailable` with explicit absence; it may carry that valid report's
receipt time. Explicit clear also invalidates older/pending work, has no snapshot,
and does not invent a receipt time:

```json
{"schemaVersion":2,"cliVersion":"1.2.8","provider":"claude","scope":"provider","revision":7,"observedAt":950000,"status":"usage_unavailable","latestInvalidationRevision":6,"retainedSnapshotRevision":null}
```

`usage_unavailable` cannot advertise a retained snapshot. Failure without a retained
snapshot cannot advertise a valid receipt. Other established status codes keep their
meaning. Revisions and invalidation are provider-local; snapshot and status receiver
floors remain separate. A newer status can describe an older retained snapshot.
Receivers must reconcile the declared retained revision/invalidation before exposing
a gated cache; snapshot arrival alone is not an authoritative recovery completion.

### Correlated recovery and private persistence

A Claude recovery request extends `ai.buildrai.account-usage-requested` additively,
with `object=nil` and exactly `userInfo["replayRequestID"]` containing an opaque token.
`UsageReplayRequest` validates the token as 1...128 UTF-8 ASCII letters, digits,
hyphen, dot or underscore. Replies echo `replayRequestID` in their JSON payload;
the same bound applies to snapshot/status metadata. This is correlation only.
A nil-userInfo request retains Codex compatibility. Other request shapes are rejected.

An available existing watch/service responder supplies authoritative Claude retained
revision or absence without polling Claude or changing account authentication.
Obsolete/uncorrelated replies cannot complete a current Claude recovery attempt.
Live reports still require provider-local reconciliation before replacing gated
retained data. With no responder, the receiver waits for an authoritative new
callback or reports waiting/no response. Silence proves neither installation nor
incompatibility. No service may be installed/enabled implicitly to obtain replay.
These responder/capture effects are implemented separately from this contract slice.

Private state remains the existing atomic, owner-only, provider-keyed durable store.
Old Codex state decodes directly into typed collected provenance without modifying
values, salts, fingerprints, retry restrictions, revision floors, status or windows.
Claude state has no salt/fingerprint and cannot be saved with one. Its retained
revision must agree with the actual snapshot; a supplied retained receipt must agree
with that snapshot's original receipt. The store validates structural state without
using the wall clock to redate or expire it; publication/receipt checks use their own
clock. A rejected save leaves committed state intact. Capture/clear must commit under
the existing ownership/coordination path before publishing; raw callback bytes,
credentials and account metadata are never persisted or sent.

The shared fixtures in `Tests/Fixtures/usage/` contain canonical sorted-key Codex v1
snapshot/status, Claude v2 snapshot/status/absence with correlation, and a synthetic
legacy private Codex state. `ClaudeUsageContractTests` and
`ClaudeUsagePersistenceTests` exercise exact fixture encodings, incompatible contract
rejection, timestamp provenance, independent floors, explicit absence, private
migration, provider isolation and file permissions. Downstream consumers can copy the
public fixtures; `legacy-codex-state.json` is a private persistence fixture only.
Actual callback shape/version/platform, status-line preservation/setup/removal,
restart/clear/replay with the receiver, signed sandbox delivery, and widget appearance
remain separate parent acceptance gates. No live setup or model request is performed
by these fixture tests.

## Claude capture, clear and responder behavior

The bridge accepts activity-driven status-line reports only. `ClaudeUsageParser`
reads at most 1 MiB of callback JSON and extracts only `rate_limits.five_hour` and
`rate_limits.seven_day`. Missing/null limits or supported windows are valid absence;
a supplied non-null limits/window value must be an object. A supplied window must
have a numeric finite `used_percentage` in 0...100; strings, booleans, missing/null
percentages and invalid supported windows reject the entire callback. Optional/null
`resets_at` is unknown; otherwise it must be a nonnegative integral JSON number of
Unix seconds whose multiplication by 1000 fits `Int64`. Unknown fields, spend,
identity and conversation data are ignored. Original callback bytes are never
written to state or sent through private coordination.

`UsageCoordination.captureClaude(runtime:input:)` samples the persisted explicit-clear
revision **before** invoking its input closure, then normalizes in memory. It sends
only at most two normalized windows (or a sanitized malformed marker) through the
existing bounded, same-user private command socket. With no owner, the invocation
holds the existing exclusive lock itself; with an active Codex watch/service, that
owner serially accepts the request. Both routes commit the provider partition before
attempting notification publication, holding ownership through publication. Distinct
callbacks are never coalesced; adjacent refresh/clear batching distinguishes providers.
Configuration roots and synthetic session metadata do not partition quota or imply
account identity. The last durably accepted whole report wins.

Private Claude state adds optional `latestClearRevision`; its legacy default is zero,
and it may not exceed `latestInvalidationRevision`. Explicit
`buildrhooks usage clear --provider claude` advances both markers and publishes v2
`usage_unavailable` with no retained snapshot or receipt. Pending callbacks that
sampled an earlier clear revision cannot repopulate usage; a later invocation may.
A valid quota-free report advances invalidation and advertises explicit absence,
including that valid report's receipt time. It does **not** advance the explicit-clear
fence: another pending valid callback can still replace it in durable acceptance order.
Malformed capture advances only sanitized failure status and retains any previous
whole snapshot and original receipt. Unchanged valid reports receive a new revision
and receipt. Save failure publishes nothing; publication failure retains committed
state for later recovery. Every outcome describes a local action/publication attempt,
never app or widget acknowledgement.

The existing `usage watch --provider codex` owner (including an explicitly enabled
service) also receives Claude recovery requests with bounded `replayRequestID`.
These triggers do not initiate a Codex or Claude quota read. Claude replies echo the
request token in both retained snapshot and authoritative status, preserving receipt,
status time and revisions. With no previous Claude state, the owner commits an
explicit no-snapshot status before replying. Duplicate tokens are coalesced for one
second; distinct tokens can receive distinct replies within that second (bounded to
64 tokens), so an obsolete recovery request cannot suppress the current one.
Legacy nil-userInfo Codex replay retains its existing behavior.

No callback, clear or recovery path enables a login service, starts provider polling,
changes authentication or reads credential stores. With no available responder,
recovery has no reply until an existing owner or a genuinely new callback supplies
authoritative state; silence is not evidence of incompatibility or installation.
Setup and transparent status-line rendering are delivered separately. Real callback
shape/version/platform and OS/app/widget receipt remain manual parent #32 gates.
