## Agent skills

### Issue tracker

Issues and specs are tracked in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Triage labels use the defaults: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context layout. See `docs/agents/domain.md`.

### Swift CLI tooling

Before Swift builds, tests, quality checks or staged packaging verification, read
`docs/swift-cli.md` and use the `swift-cli-build` skill with the repository's
`scripts/build.sh`, `scripts/test.sh`, `scripts/quality.sh` and `scripts/stage.sh`
wrappers. Installation, Homebrew and release automation remain project-owned.
