#!/bin/sh

set -eu

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: SwiftLint is not installed. Install it with: brew install swiftlint" >&2
  exit 1
fi

if ! command -v swiftformat >/dev/null 2>&1; then
  echo "error: SwiftFormat is not installed. Install it with: brew install swiftformat" >&2
  exit 1
fi

before_status="$(git status --porcelain)"
autofixed=0

echo "Running SwiftFormat validation..."
if ! swiftformat --quiet --lint --config .swiftformat .; then
  echo "SwiftFormat validation failed. Attempting auto-fix..."
  swiftformat --quiet --config .swiftformat .
  autofixed=1
  echo "Re-running SwiftFormat validation..."
  swiftformat --quiet --lint --config .swiftformat .
fi

echo "Running SwiftLint validation..."
if ! swiftlint lint --quiet --strict --config .swiftlint.yml; then
  echo "SwiftLint validation failed. Attempting auto-fix..."
  swiftlint --fix --quiet --config .swiftlint.yml
  autofixed=1
  echo "Re-running SwiftLint validation..."
  swiftlint lint --quiet --strict --config .swiftlint.yml
fi

after_status="$(git status --porcelain)"
if [ "$autofixed" -eq 1 ] && [ "$before_status" != "$after_status" ]; then
  echo "error: Auto-fix updated files. Commit the fixes, then push again." >&2
  git status --short
  exit 1
fi
