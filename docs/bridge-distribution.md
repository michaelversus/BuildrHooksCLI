# Bridge distribution and app compatibility

The normal `buildrhooks` executable contains report discovery, resolution,
preparation, finalization and cancellation, plus offline commit/rewrite recording,
replay and acknowledgement. There is no second installed executable. Both
`BuildrHooksCLI_BuildrHooksCLI.bundle` (Claude assets) and
`BuildrHooksCLI_BuildrBridgeContracts.bundle` (common fixtures) travel beside it
through staging and `make install`; Homebrew uses that same install target.

## Supported installation and upgrade

Use the existing tap and formula:

```sh
brew tap michaelversus/BuildrHooksCLI https://github.com/michaelversus/BuildrHooksCLI.git
brew install buildrhookscli
# Existing installation:
brew update
brew upgrade buildrhookscli
command -v buildrhooks
buildrhooks --version
buildrhooks capabilities --json
buildrhooks capabilities --json --protocol-version 1 --operation discover
buildrhooks capabilities --json --protocol-version 1 --operation recordRewrite
```

Check all required operations, including prepare/finalize/cancel and
recordCommit/acknowledge, during app setup. `ready` here establishes only the
installed CLI's operation support. Report responses and tracking configuration
still enforce app availability, authorized project scope and access. Exit 30
means incompatible protocol; exit 31 means unsupported operation. An absent
`reportingTracking` field in an older installation means incompatible, not ready.
A shell may select an older executable earlier on PATH; compare the resolved
path with the installation being upgraded.

Source installs use `make install prefix=/chosen/prefix` with Xcode supporting
Swift 6.2+ and macOS 26+. Run `/chosen/prefix/bin/buildrhooks` explicitly when
verifying that prefix. `make uninstall prefix=/chosen/prefix` removes the
executable and both resource bundles. Prefixes with spaces are supported.
Installation does not enable tracking, install project hooks/skills, authorize
projects, or migrate/delete queued records. BuildrAI owns that setup.

## Release gate and pinned inputs

The latest published GitHub release observed during this audit is **1.2.11**
(2026-10-22). The source VERSION and executable also report 1.2.11; that version
alone is **not proof that the published release includes these capabilities**.
No new version is published by this ticket.

This slice starts at package/CLI source commit
`c94579ee0d9f880b2f648991cd91ddd2fb8302b4`; protocol version is **1** and contract
revision is **1.0.0**. The implementation commit and final complete-diff HEAD
are recorded in the native ticket report. Pin the final accepted delivery SHA
when consuming the package, then record its eventual published tag and exact
release SHA in BuildrAI#1033 before shipping. The app must require that compatible
published CLI/library pair, not infer compatibility from today's source VERSION.
The independently tested package is this repository at the audited source tree;
no real BuildrAI revision was tested.

`Verification/ContractConsumer` is a separate Swift package. Its only target
dependency is the `BuildrBridgeContracts` product; it imports no CLI/core,
ArgumentParser or app types. Its test runs the bundled 55 common valid/invalid v1
fixtures and validates generated content against the shared prepared packet,
including missing-versus-zero metrics. BuildrAI must execute the same corpus
using its pinned package revision; this consumer check does not establish that
the app has done so.

## Reproduce the audit

Use the shared Swift CLI runtime described in [Swift CLI tooling](swift-cli.md):

```sh
scripts/test.sh --suite DistributionInstallTests
scripts/verify-contract-consumer.sh
scripts/build.sh
scripts/test.sh --filter 'Report|Tracking|Bridge|DistributionInstall|BuildrHooksCLI'
scripts/test.sh
scripts/quality.sh --check
scripts/stage.sh
# Use the exact stage directory returned by that invocation:
python3 scripts/verify-staged-bridge.py /absolute/stage/buildrhooks \
  --output .build/staged-bridge-evidence.json
```

The installation test exercises the public make targets in a temporary prefix
with synthetic build artifacts; it does not modify the user's installation.
The external consumer uses the same runtime's serial Swift Testing and coverage
policy, retaining discovery, selection, actual xUnit results, source/runtime
fingerprints and logs under `.build/contract-consumer-evidence`.
Main wrappers retain evidence under `.build/swift-cli-evidence`.
Counts are logical test identities; parameter invocations and the 55 fixtures
inside one consumer assertion are not 55 separately audited tests.

The implementation audit recorded: installation red **1 failed / 1 requested**
(missing contracts bundle), then green **1 passed / 1 requested**; affected
selection **104 passed / 104 matched** out of **294 discovered**; full regression
**294 passed / 294 matched**; independent consumer **1 passed / 1 matched**,
internally verifying **55 fixtures**; staged audit **24 command checks passed**.
All successful test audits had zero missing, unexpected, skipped or failed logical
results. Build, read-only quality and release stage wrappers exited zero; stage
ran six configured smoke commands. The runner report retains exact final evidence
paths and the implementation HEAD. Shared runtime revision:
`08346288773410b821cfe033cc294d9416aa1cca`; runtime fingerprint:
`e6b5391e004b786899cc37091a61d61519fe834efab719a3f15eda8670056337`.
These runs used Apple Swift 6.4.2; consumer and CLI each retain coverage and xUnit
logs with their own source fingerprints.

The staged audit checks actual version/capability negotiation and command
registration, both resource bundles, offline commit/rewrite recording, replay,
failed completion rejection, acknowledgement, retained report workflow
cancellation and structured errors. Synthetic records are explicitly fixtures,
not proof of real commit creation. All files are isolated in a temporary project.
It never starts BuildrAI or installs hooks. Positive discovery/resolve,
prepare/finalize responder behavior and missing-app/launch failures are tested
through the agreed injected Swift command seam; they are not positive staged
binary app-launch acceptance. Real app integration remains a separate gate.

## Pending acceptance and risks

Coordinate these distinct manual gates with BuildrAI#1033:

- A compatible published CLI/library release with exact tag/SHA, and a pinned
  tested BuildrAI revision running the common fixtures.
- Actual clean installation and upgrade usability, PATH repair and app setup
  recognition on supported systems. Temporary-prefix make and staging checks
  do not establish Homebrew/network or user-machine update acceptance.
- Real Codex and Claude Code app/skill flows: visible collection, discovery,
  selection, prepare/finalize, exact Markdown preview, cancellation, offline
  ingestion/replay, rewrite capture, project access and managed opt-in setup.
- User-approved GitHub publication/acceptance with a real PR; no fixture run
  authorizes publication or validates report semantics.
- Owner merge, release authorization and publication. Passing this audit is
  packaging readiness evidence, not a release, merge or closure of manual gates.

Existing account usage, Prompt Gate, Codex/Claude hooks and output contracts
remain covered by the full command regression suite. Deterministic responders
do not establish live collectors, services, notifications or provider behavior.
No UI automation, real app launch or GitHub write is performed by these checks.
