# Claude usage delivery and acceptance handoff

This is the bridge implementation handoff for specification [#32](https://github.com/michaelversus/BuildrHooksCLI/issues/32)
and delivery issues #33–#36. It separates automated bridge evidence from release,
Claude operator, signed sandbox and widget evidence. Parent #32 stays open while
required operator acceptance remains outstanding.

## Compatibility and package evidence

The latest published stable release checked on 2026-10-21 was **1.2.8**, published
2026-10-11. `VERSION` and `Sources/BuildrHooksCLI/Version.swift` still contain 1.2.8.
That published release does **not** contain this Claude integration. A development
build from this branch may therefore report 1.2.8 while advertising the new contract;
its version alone is not evidence that the stable release supports Claude.

The first compatible released version is **pending the normal release**. No release,
Homebrew upgrade, real setup, service installation or model request was performed to
satisfy this delivery. Do not set a downstream minimum compatible version to an
invented next patch/minor version. After the approved PR reaches `main`, the normal
Release workflow selects the bump from the latest published stable release, writes
both version files, tests that exact commit, and publishes its tag/release. Record
the resulting tag and commit on #32 and in downstream compatibility configuration.

The Homebrew formula uses `VERSION` as its Git tag and runs `make install`; the
Makefile builds the release executable and installs it as `buildrhooks`. All new
runner code is in that executable, so no additional package resources or scripting
runtime are required. Setup copies the resolved executable's bytes into private
per-install directories; after an upgrade, explicit `setup --apply` refreshes a
still-owned runner. Updating the main executable alone does not update that copy.

For the operator's later installation/upgrade, after a compatible release exists:

```sh
brew tap michaelversus/BuildrHooksCLI https://github.com/michaelversus/BuildrHooksCLI.git
brew install buildrhookscli
# For an existing installation instead:
brew update
brew upgrade buildrhookscli
buildrhooks --version
buildrhooks capabilities --json
```

Compare the installed version with the actual delivered release, then inspect the
capabilities and contract rather than inferring support from silence. Capability
schema `version: 1` remains additive:

| Capability | Advertised support |
| --- | --- |
| `accountUsageRefreshProviders` | `["codex"]` |
| `accountUsageWatchProviders` | `["codex"]` |
| `accountUsageServiceProviders` | `["codex"]` |
| `accountUsageClearProviders` | `["codex", "claude"]` |
| `accountUsageCaptureProviders` | `["claude"]` |
| `accountUsageSetupProviders` | `["claude"]` |
| `accountUsageSchemaVersions` | `[1, 2]` |

New callback/setup fields decode as empty support when absent in older capabilities.
These declarations expose user-run commands; they do not authorize the sandboxed app
to execute the bridge. A verified incompatible version/contract can drive Claude-only
upgrade guidance. No response proves neither installation nor incompatibility.

## Receiver integration contract

Use the [authoritative wire contract](account-usage-wire.md) and shared public
fixtures under `Tests/Fixtures/usage/`. Codex v1 retains `collectedAt`, percentages
above 100, account continuity and existing clear/recovery behavior. Claude v2 is
`provider=claude`, `scope=provider`, with typed receipt provenance and `receivedAt`;
there is no account attribution, collection-time field or identity metadata.

Both notification names, `object=nil`, JSON-string `userInfo["payload"]`, the 64 KiB
bound and untrusted sender semantics remain unchanged. Snapshot and status ordering
floors are independent and provider-local. Reconcile `latestInvalidationRevision`
and explicit `retainedSnapshotRevision` before exposing gated retained app data.
A malformed report can advance failure status while retaining the old snapshot and
receipt; a valid quota-free report or clear advertises explicit absence/invalidation.

Claude recovery uses `ai.buildrai.account-usage-requested`, `object=nil`, and exactly
`userInfo["replayRequestID"]` containing a bounded opaque token. Replies echo that
current token and declare retained revision or absence. Ignore obsolete correlation
for recovery completion; validate ordinary live updates with the same provider-local
reconciliation. Replay preserves original receipt/status times and revisions.
Legacy nil-userInfo Codex recovery is unchanged.

An already running `usage watch --provider codex` or separately consented Codex
service can answer Claude recovery without polling Claude. Without an available
responder, wait for a new authoritative callback or show waiting/no response. Setup
never installs/starts a responder. The app must not read the CLI cache, run the CLI,
modify Claude settings, write executable scripts, or let a widget own collection.
Publication and clear outcomes describe local state and attempted notification;
they are never receiver acknowledgements.

## Automated evidence and privacy audit

| Slice | Behavioral red | Final affected evidence before its checkpoint |
| --- | --- | --- |
| #33 contracts/persistence | 2 executed tests failed | 47 tests / 8 suites passed; build, lint and format passed |
| #34 capture/reconciliation | 2 executed tests failed | 91 tests / 14 suites passed; independent 85-test selection and build passed |
| #35 setup/delegation | 2 executed tests failed | 48 tests / 11 suites passed after final repair; build, lint and format passed |
| #36 delivery capabilities | 2 executed tests failed; 1 legacy-decode test failed | Final range evidence is recorded below and on #36 |

Local detailed logs are retained under `/tmp/issue33-*.log` through
`/tmp/issue36-*.log`; the issue checkpoint comments and this checked-in summary retain
the behavioral results. Full final package validation follows repository CI's
`swift test --no-parallel --enable-code-coverage`, debug/release builds and configured
format/lint/pre-push checks. Automated evidence does not establish actual Claude
version/plan/platform callback availability, macOS delivery or App Store acceptance.

The audited new paths normalize only documented `five_hour`/`seven_day` quota, reject
invalid whole callbacks, and serialize acceptance, clear and publication through the
existing owner. Tests cover cross-root/session interleaving, active Codex ownership,
strict numeric/reset bounds, unchanged callbacks, absent/partial/zero quota, failure
retention, commit/publication failure, delayed publication, clear fencing, correlated
restart replay, and no-responder behavior. Canonical Codex v1/Claude v2 fixtures and
legacy private-state migration preserve provider isolation and timestamp meaning.

Status-line tests cover exact binary stdin/output/stderr, no trailing newline,
nonzero exits, inherited shell context, cancellation, early exit, large input,
capture failure, missing original helper, quoted paths, immutable ownership records,
unknown settings, absence/null, scopes, idempotence, managed-file refusal,
external/concurrent edits, repair and reversible removal. Installed-runner integration
uses a temporary home and corrupt temporary usage state to prevent real publication.

No Claude network fetch, credential-store access, undocumented endpoint, account
selector/fingerprint/label, telemetry startup or unconsented service enablement was
added. Raw callback stdin is bounded in memory and is neither persisted nor logged;
only normalized quota crosses private coordination. Private setup metadata preserves
the user's original command/options for restoration, while Codex retains its existing
private continuity metadata. Public notifications contain neither. The explicit
user-run delegate can retain its existing behavior; the bridge does not add output
to custom status lines. Package installation and app/widget execution boundaries are
unchanged apart from explicitly user-run status-line setup.

## Final range validation

The final independent validation ran these checks on the resulting source range:

| Check | Result | Retained local evidence |
| --- | --- | --- |
| Focused affected Swift Testing selection | 97 tests / 17 suites passed | `/tmp/issue36-tester-focused.log` |
| `swift test --no-parallel --enable-code-coverage` | 206 tests / 40 suites passed | `/tmp/issue36-tester-full.log` |
| `swift build` | Passed | `/tmp/issue36-tester-build.log` |
| `swift build -c release` | Passed | `/tmp/issue36-tester-release.log` |
| SwiftLint | 0 violations across 89 files | `/tmp/issue36-linter-swiftlint.log` |
| SwiftFormat lint | 0/89 files need formatting | `/tmp/issue36-linter-swiftformat.log` |
| `sh .githooks/pre-push-process.sh` | Passed without modifying files | `/tmp/issue36-parent-hook.log` |
| Release capabilities and setup/remove/capture/clear help | Passed; command/contract agreement checked | `/tmp/issue36-parent-capabilities.json`, `/tmp/issue36-parent-*-help.log` |
| Formula/hook syntax and install recipe preview | Passed without installation | `/tmp/issue36-parent-package.log` |

The coverage export is `.build/out/Products/Debug/codecov/BuildrHooksCLI.json`.
The release binary reports the unchanged development metadata 1.2.8; this does not
change the pending first-compatible-release determination above.

The delivery capability tests recorded behavioral failures before each repair:
two tests failed on missing Claude advertisements, then one legacy decoding test
failed on the newly required fields; all three passed after the additive defaults.
These logs are `/tmp/issue36-red.log`, `/tmp/issue36-legacy-red.log` and
`/tmp/issue36-capabilities-green.log`. All checks above are host automated evidence;
the operator and downstream gates below remain pending.

## Pending one-account operator acceptance

All steps below are **pending**, to be performed deliberately by the operator after
selecting a compatible installed build. Record date, macOS version, `claude --version`,
`buildrhooks --version`, selected scope and result on parent #32. Record only quota
facts/window presence and normalized receipt/revision fields, never raw callback JSON,
prompts, credentials, email/account identity or configuration command secrets.
No two-account test is required.

1. In Terminal, record `sw_vers`, `claude --version`, bridge version and capabilities.
   Keep the current sign-in and populated app data. Select the intended configuration
   root; user scope honors `CLAUDE_CONFIG_DIR`. Make a private backup of the selected
   settings if desired, without printing it. Do not change a managed policy.
2. For a custom line, run `buildrhooks claude statusline setup` to inspect the delegate
   preview, then `buildrhooks claude statusline setup --apply`. Use identical
   `--config-dir '/selected/config'` flags for a custom root, or explicit
   `--project '/selected/project'` for its local settings. During ordinary approved
   Claude activity, compare original text, colors, spacing and footer behavior.
   Confirm no BuildrAI text is appended, stderr/exit behavior remains appropriate,
   and unrelated settings remain present. A user-level installation does not prove
   every session selected it; inspect Claude's effective settings.
3. For a default line, use a selected scope whose original `statusLine` is absent,
   rather than deleting a custom line or replacing a settings file. Preview first;
   confirm the synthetic values and explanation that custom lines suppress most
   default footer keyboard hints. Apply explicitly and confirm five-hour/weekly
   remaining capacity during ordinary approved activity. Observe actual supported
   window presence; missing windows are unavailable, and genuine zero consumption
   is valid. Do not initiate a model request solely through automation.
4. With the downstream receiver explicitly enabled, record the normalized report's
   supported windows and original `receivedAt`/revision. A new callback can report
   cached upstream quota; `Updated`/`Last received` means bridge receipt. Observe an
   available single-window/absent callback without treating absence as a plan,
   version or authentication failure. If that shape cannot be obtained naturally,
   mark it unavailable as live evidence; synthetic fixtures already cover it.
5. If multiple existing sessions/roots are available for this one account, observe
   whole-report replacement in bridge receipt order, including unchanged reports.
   Do not claim account binding or merge windows from different callbacks. If
   multi-session observation is unavailable, record that explicitly.
6. Run `buildrhooks usage clear --provider claude --json`. Confirm `localCleared`
   independently of `publicationAttempted`, check immediate downstream invalidation,
   and confirm Codex values and Claude setup remain intact. A genuinely new callback
   may repopulate; delayed pre-clear data must not. Keep ordinary data and credentials.
7. Restart/re-enable the receiver with an already available responder. Have its
   recovery action issue a new token, then verify matching replies retain the
   original receipt/revision or declare explicit absence. Confirm obsolete replies
   and delayed pre-clear snapshots cannot restore values. To exercise the CLI with
   receiver unavailable, quit the receiver, clear locally, then reopen and request
   recovery; clear must not launch the app. Record responder availability separately.
8. With no responder already running, exercise receiver recovery and verify honest
   waiting/no response until a new accepted callback. Do not enable/install a service
   just to make this check pass. If a watch is intentionally used, explicitly run
   `buildrhooks usage watch --provider codex` in Terminal and stop it with Control-C
   afterward; this consents to Codex collection and is not Claude polling. Preserve
   any pre-existing service's configuration and lifetime.
9. Run `buildrhooks claude statusline remove` to preview, then
   `buildrhooks claude statusline remove --apply` with the original scope flags.
   Confirm complete prior value/absence and unrelated/later keys are preserved;
   retained usage is not cleared. If a later external replacement is present,
   expect detached/repair-needed and preserve it; do not force replacement merely
   to complete acceptance. Stop old sessions before manually removing old private
   runner generations, if cleanup is desired.

## Separate downstream gates

The downstream app must validate signed sandbox notification receipt, authoritative
recovery before showing retained cache, fifteen-minute stale presentation, reset
handling without invented capacity, and provider independence. Record small/medium
native widget appearance, receipt footer, unavailable/zero/failure states, pause icon
and accessibility independently. Closing windows must permit enabled background
receipt; Quit/Command-Q must end the app normally, without a collector launching it.

Disclose the external Terminal integration/dependency and provider attribution
limitation in App Store review material. CLI separation, host tests, simulator runs
and merged source do not prove App Store approval. Missing release/operator/signed
sandbox/widget evidence is reported as pending on #32, not silently converted into
an automated pass.
