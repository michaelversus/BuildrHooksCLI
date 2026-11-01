# Shared Swift CLI tooling

Select the MySkills `swift` and `swift-cli` bundles saved in `.skill-bundles.json`.
The former provides concurrency, Swift Testing and Foundation Models expertise;
the latter provides `swift-cli-build`. Repository-owned Ralph skills remain local.

Merge the dependent MySkills PR first, update a durable reviewed MySkills checkout,
then run its `scripts/install-swift-cli-project.sh` and `myskills sync` in this repo.
Keep that checkout available. Generated Codex/Claude links are ignored; commit the
portable manifest and ignore rules. No machine paths belong in configuration.
For pre-merge validation, set `MYSKILLS_SWIFT_CLI_RUNTIME` locally to the candidate
checkout's `runtime/swift_cli` directory. This override does not install a launcher.

| Command | Policy |
| --- | --- |
| `scripts/doctor.sh` | Check Swift and list capabilities without installing tools. |
| `scripts/build.sh` | Debug by default; `--configuration release` preserves release builds. |
| `scripts/test.sh` | Swift Testing only, serial, coverage enabled; focused `--filter`, exact `--test`, `--suite`, `--module`, discovery-only `--list`. |
| `scripts/quality.sh --check` | Existing SwiftFormat and strict SwiftLint rules; read-only default. |
| `scripts/quality.sh --fix` | Explicit corrections followed by final checks; review the diff. |
| `scripts/stage.sh` | Release build, renamed `buildrhooks`, adjacent SwiftPM resource bundle and temporary smoke checks. |

`make build` retains its direct release command with `--disable-sandbox`, so
Homebrew/source installation does not require the development launcher.
`make install`/`uninstall`, Homebrew, hooks and release automation
remain project-owned. The CI test command retains its existing serial/coverage
policy. The scratch path stays `.build` because some existing tests use its debug
binary. Select the project's intended Xcode environment before execution; the
runtime records actual versions rather than changing Xcode selection.

Stage runs `--version`, `--help` and exports the Claude mod into `smoke-mod` inside
its unique temporary staging layout. The export reads bundled assets; it does not
enable/install the plugin or contact providers. Stage inherits the caller's
environment and is not an OS sandbox. Live collectors, notifications, services,
BuildrAI integration and release acceptance remain separate.

Every invocation retains logs and a summary under `.build/swift-cli-evidence`;
`--artifacts` chooses another parent. Tests retain audited xUnit results and
coverage. Discovery, empty/skipped-only results and stale reports are not passes.
