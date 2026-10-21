# Claude reported usage: explicit status-line integration

This command surface implements specification #32. It is not a released-version
claim: the first compatible release is the release that ships this work. Codex
continues to use its existing account-aware v1 collector; Claude reports provider
usage in v2 without account attribution. Switching accounts or concurrent sessions
may report another account. `Updated` means bridge receipt, not when Claude measured
quota; diagnostic wording is `Last received`.

Run installation and upgrade yourself in Terminal using the repository's Homebrew
instructions. The sandboxed app does not install, invoke, update or configure this
bridge. This feature does not enable telemetry, read credentials, request a model,
fetch Claude quota over the network, or start/install a usage service.

## Frozen commands

```sh
buildrhooks claude statusline setup
buildrhooks claude statusline setup --apply
buildrhooks claude statusline status
buildrhooks claude statusline remove
buildrhooks claude statusline remove --apply
buildrhooks usage clear --provider claude --json
```

`setup` previews before changing anything. With an existing custom status line it
shows the exact delegated command and preserves all other `statusLine` options,
including unknown options. It appends no BuildrAI text. Without one, the synthetic
preview shows `Claude 5h: 75% remaining | weekly: 50% remaining` and explains that
configuring a custom line suppresses most of Claude's default footer keyboard hints.
An actual default line uses only the current callback: absent/invalid windows are
`unavailable`; genuine zero consumption yields `100% remaining`. Past resets do not
synthesize capacity. Preview neither executes the delegate nor obtains quota.

Review the preview and repeat with `--apply`. Setup does not prove any particular
session uses the selected settings or that any usable quota has been received.
`status` describes local ownership only. Clear reports local persistence and attempted
publication, never receiver acknowledgement; it leaves setup and collection enabled.

The selected user root defaults to `CLAUDE_CONFIG_DIR`, otherwise `~/.claude`:

```sh
buildrhooks claude statusline setup --config-dir '/path/to/selected Claude config'
buildrhooks claude statusline setup --config-dir '/path/to/selected Claude config' --apply
```

An explicit project targets `.claude/settings.local.json`, avoiding shared team settings:

```sh
buildrhooks claude statusline setup --project '/path/to/project'
buildrhooks claude statusline setup --project '/path/to/project' --apply
```

Use the same scope flags for `status` and `remove`. `--config-dir` and `--project`
are mutually exclusive. User setup does not override project/managed policy. Setup
refuses detected managed `statusLine` values in local managed files; organization
MDM/server policy and effective session settings still require operator verification.
Configuration roots are setup scopes, not accounts. Host-owned Claude lifecycle hook
management remains separate from this CLI-owned, explicitly invoked status-line setup.

## Ownership, repair and rendering

Setup retains the complete prior `statusLine` value or absence in owner-only private
metadata. A private standalone copy of the executable performs rendering, so removing
or moving the original installed collector does not remove the delegate. It copies
symlink target bytes, not a link to the original executable. Repeating `setup --apply`
for a still-owned setting is idempotent and explicitly refreshes that standalone
runner after an upgrade. Preview alone does not refresh it.

Every new installation/adoption gets an immutable callback metadata generation.
Existing callbacks continue to read their original delegate even if a repair aborts.
Setup serializes its own writers and rechecks settings bytes immediately before the
atomic replacement. It preserves unrelated settings keys. This recheck detects
observed external edits; unrelated editors do not participate in its lock.

Removal restores the prior value/absence only while the current `statusLine` still
matches the exact installed value. External replacements or later edits produce a
`detached`/`repair-needed` report instead of being overwritten. An intentional adoption
requires an explicit repair preview, then apply:

```sh
buildrhooks claude statusline setup --repair
buildrhooks claude statusline setup --repair --apply
```

Removal leaves retained usage intact. Private old runner/metadata generations remain
for already launched callbacks and reversibility; they contain prior command/settings
values, never raw callback stdin. They can be removed manually after Claude sessions
using them have stopped, without deleting the separate usage cache.

The private `run --metadata <path>` command is setup-owned. It passes the exact original
command to `/bin/sh -c` with inherited working directory/environment, streams original
stdin bytes without string conversion, and routes delegate stdout/stderr directly.
Exit status and signals propagate. A bounded one-MiB memory copy feeds capture; larger
or malformed input cannot change custom output/exit behavior. Capture failure,
unavailable/corrupt usage state and missing original collector never suppress custom
rendering. Cancellation terminates only the owned delegate process group and skips
late acceptance. Default rendering/capture stdin reads have a two-second bound.
If a custom delegate closes stdin or exits early, capture drains independently for
at most 100 ms to obtain EOF. A still-open upstream pipe or incomplete/oversized
callback yields unavailable capture without changing delegate output or exit status.
This repairs #38 in source; the first repaired release is still a release gate.

After installing that release, preview `buildrhooks claude statusline setup` using
the original scope flags, then repeat with `--apply` to refresh the standalone
runner. Upgrading the main executable alone leaves existing setup-owned copies
unchanged. Use `--repair` only for an intentionally adopted external replacement,
previewing before applying. No live settings are changed automatically.

Desktop capture through a separate opt-in mod is described in
[Claude Desktop reported quota mod](claude-mod.md); terminal delegate repair alone
does not make Desktop invoke a status line.

`buildrhooks claude statusline capture [--json]` separately accepts bounded stdin
without rendering. It performs no network provider read. Normal sessions should use
the setup-created runner, which samples the explicit-clear fence before reading input.
The runner publishes only normalized five-hour/seven-day quota via existing private
coordination; it never stores/logs original stdin, credentials or conversation content.

## Recovery and manual acceptance

An already available foreground `usage watch --provider codex` or separately consented
usage service can answer correlated Claude recovery without Claude polling. Setup
does not start either. Without a responder, wait for an authoritative new callback
or report waiting/no response. Silence proves neither missing installation nor
incompatible version. Publication attempts are not app/widget acknowledgements.

Separate operator evidence remains on parent #32: record one-account Claude version,
platform and actual supported callback fields; verify custom/default preview, terminal
output, available multi-session behavior, clear/restart/replay and removal preserving
settings/data. Signed sandbox receipt, small/medium native widget visuals/accessibility
and App Store review evidence belong to the downstream app acceptance. Synthetic host
tests prove none of those live gates. No unattended configuration/model/authentication
changes are authorized by these instructions.

Primary references: [Claude status-line data and behavior](https://code.claude.com/docs/en/statusline)
and [settings scopes/precedence](https://code.claude.com/docs/en/settings).
