# Claude Desktop reported quota mod

Issue #39 adds an opt-in mod, `buildr-usage` version 0.1.0. This source change is
unreleased. BuildrHooksCLI 1.2.9 does not include it. Check the actual executable's
`capabilities --json` for `claudeModUsageCapture: true` before installing. The first
released bridge version and actual Desktop acceptance remain release gates.

The mod observes `session.measure`, forwarding only documented `five_hour` and
`seven_day` entries through `claude mod capture --json`. It uses the same capture,
clear, coordination, recovery, persistence and schema-v2 publication owner as the
terminal integration. It exports no prompts, context fill, cost, transcript, identity,
credentials or raw events. It has no durable store, network/model requests, timers,
service or authentication setup. BuildrAI receipt preferences remain independent.

## Preview and prepare

Choose a dedicated directory beneath an existing parent, outside live Claude
settings. These commands prepare files without enabling a plugin:

```sh
buildrhooks capabilities --json
buildrhooks claude mod setup --directory "$HOME/buildr-usage-mod"
buildrhooks claude mod setup --directory "$HOME/buildr-usage-mod" --apply
```

Review the preview first. The installed bridge's resolved absolute path is encoded
as a JavaScript string. Quota travels on stdin through an argv process call, without
shell interpolation. `--executable /absolute/path/buildrhooks` explicitly selects
another compatible executable; keep it installed at that path. Terminal status lines
and unrelated plugins/settings are preserved. Preparation does not prove session use.

The directory includes a local marketplace. Using the intended Claude configuration,
the operator can explicitly validate and install it at user or local scope:

```sh
claude plugin validate "$HOME/buildr-usage-mod" --strict
claude plugin marketplace add "$HOME/buildr-usage-mod"
claude plugin install buildr-usage@buildrhooks --scope user
```

Bridge setup never executes these installer commands. Local Desktop Code sessions
read the same user plugin settings as the terminal. In Desktop's Code tab, inspect
the plugin through **+ → Add plugins**, or **Plugins → Browse plugins**. Honor Claude's
reload, trust, permission and managed-policy instructions. Remote sessions need a
bridge on their host; this integration is for local macOS execution.

## Upgrade and remove

After upgrading the bridge, repeat the preview and `--apply` against the same
directory. Setup checks hashes, atomically exchanges owned directories and serializes
its writers. Edited files, symlinks or extra files/directories cause refusal; choose
a fresh directory to retain them. Keep development/type-generation copies separate:
generated types count as extra files. The sibling setup lock remains as an inert file.

Then explicitly update the marketplace and installed plugin in Claude's plugin
manager. Inspect the installed version and reload/restart as instructed. Claude may
cache plugins; updating prepared source alone does not establish active-session use.

Uninstall in Claude before previewing/removing the prepared directory:

```sh
claude plugin uninstall buildr-usage@buildrhooks
claude plugin marketplace remove buildrhooks
buildrhooks claude mod remove --directory "$HOME/buildr-usage-mod"
buildrhooks claude mod remove --directory "$HOME/buildr-usage-mod" --apply
```

Removal leaves retained quota and terminal integration intact. Clear independently
with `buildrhooks usage clear --provider claude --json`. Clear fences pending bridge
input/publication; a later callback can legitimately contain upstream cached quota.
It does not reset provider limits. Terminal/mod callbacks share provider state across
configurations without account attribution or measurement-freshness guarantees.

## Data and failure behavior

Percentages must be finite numbers in 0...100, including zero. Missing supported
windows stay absent; an empty supported set invalidates the prior whole snapshot.
Unknown kinds such as `spend_limit` never become plan quota. Duplicate supported
kinds or malformed supported fields reject the whole report, retaining quota/receipt.
Processing is bounded to 64 input entries and two output windows.

The pinned API uses ISO 8601 reset strings, never numeric epochs. Dates must be valid,
nonnegative, four-digit-year timestamps with an explicit zone. Conversion to existing
capture's integer Unix seconds discards only subsecond reset precision. The bridge
retains 300/10080-minute durations. Public schemas/notification names are unchanged;
provider-level messages do not claim terminal-only provenance.

Each loaded mod permits one bridge invocation, with a 1500 ms process timeout and
no pending queue. Already abandoned callbacks are skipped. Claude owns process
execution/event cancellation; the bridge honors termination signals and samples clear
before reading stdin. Normal events pass unchanged after normalization/execution
failure. Failure never substitutes zero quota.

For missing quota, inspect executable capabilities, prepared/installed plugin versions,
host/configuration/scope, Claude's plugin Errors tab, trust/managed execution policy,
and whether ordinary activity has supplied plan windows. Silence does not establish
incompatibility or a widget defect. Publication is attempted, not acknowledged.
Enable Claude receipt separately in BuildrAI; widget provider choice does not enable
receipt. Replay preserves original receipt/status timestamps and revisions.

## Evidence and operator gates

Fixture tests/strict validation use the installed Desktop embedded Claude Code 2.1.304
and its official `plugin test`/`plugin validate --strict` commands with an isolated
`CLAUDE_CONFIG_DIR`. Source-shape provenance is Anthropic's published declarations,
writer version 2.1.277, SHA-256
`e51e637fbbebb2a6a49c4bdc3860a251c2ca2295884822dff0f4c3e3ec802163`:
`SessionMeasureInput.rateLimits`, `SessionRateLimit.kind/percentUsed/resetsAt`, and
`ProcessRunInit.stdin/timeoutMs`. The older snapshot describes execution as CLI-only;
the current reference covers Desktop. Installed generated declarations take precedence.
Fixture tests do not establish live Desktop execution permission, live host-process
cancellation, signed sandbox receipt or native widget appearance.

Before closure, record actual Desktop/embedded-engine versions, mod/released-bridge
versions and the installed plugin source. The operator must deliberately install and
remove it, observe a real callback during approved single-account activity, and verify
signed sandbox receipt plus small/medium native widgets. No unattended live setup,
model, UI or two-account tests are run. #38's first repaired release and installed
standalone terminal runner remain separate acceptance gates.

Primary sources: [mods reference](https://code.claude.com/docs/en/plugins/mods/reference),
[published types](https://github.com/anthropics/claude-code/blob/main/mods/types/claude-code.d.ts),
[mod tests](https://code.claude.com/docs/en/plugins/mods/test),
[plugin installation](https://code.claude.com/docs/en/discover-plugins).
