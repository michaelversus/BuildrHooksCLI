#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${MYSKILLS_SWIFT_CLI_RUNTIME:-}" ]]; then
  exec python3 -B "$MYSKILLS_SWIFT_CLI_RUNTIME/../../scripts/swift-cli-project.py" --repo "$repo_root" quality "$@"
fi
if ! command -v swift-cli-project >/dev/null 2>&1; then
  echo "Install swift-cli-project from a reviewed MySkills checkout; see docs/swift-cli.md." >&2
  exit 2
fi
exec swift-cli-project --repo "$repo_root" quality "$@"
