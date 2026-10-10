# Account usage wire version 1

Delivered by the one-shot `usage refresh --provider codex` command (issue #21 under
[PRD #20](https://github.com/michaelversus/BuildrHooksCLI/issues/20)). The sender uses
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
{"schemaVersion":1,"provider":"codex","revision":2,"collectedAt":1000000,"windows":[{"limitCode":"codex","role":"primary","usedPercent":125,"durationMinutes":17,"resetsAt":2000000}]}
```

`ai.buildrai.account-usage-status-updated` contains:

```json
{"schemaVersion":1,"provider":"codex","revision":3,"observedAt":1000000,"status":"ready","latestInvalidationRevision":0}
```

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
The latest invalidation revision is included in status, initially zero. Actual clear
and account-change invalidation will be implemented by the later recovery slice.

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
transports exercise this path without live credentials. The one-shot implementation
persists minimal state atomically at `~/.codex/buildr-artifacts/account-usage.json`,
with owner-only file permissions, and never replays cache. No account identity or
fingerprint is persisted in this slice. A pending status is best-effort published;
final storage/publication failure is a nonzero CLI outcome. A successful refresh
reports attempted publication only, not receipt.

Pending manual integration: with BuildrAI's separately implemented receiver running,
verify actual snapshot/status string delivery and retained/widget presentation. Repeat
with BuildrAI fully quit and confirm refresh does not launch it. These checks were not
performed by the simulated-notifier tests. Live account fetch and service installation
are outside this slice's automated validation.
