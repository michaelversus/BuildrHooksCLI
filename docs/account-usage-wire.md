# Account usage wire version 1

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
No usage values are clamped to 100.

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
UTF-8, schema version must be 1, provider/required fields must be well formed, revision
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
with owner-only file permissions. Private metadata contains a random per-provider salt
and SHA-256 account fingerprint, never a raw ID or email. These fields are excluded
from notifications and diagnostics. A pending status is best-effort published;
final storage/publication failure is a nonzero CLI outcome. A successful refresh
reports attempted publication only, not receipt.

## Recovery

An available foreground collector listens for `ai.buildrai.account-usage-requested`
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
