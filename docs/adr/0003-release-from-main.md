# Release from main

BuildrHooksCLI uses `main` as its integration and release branch. The former `develop` branch remains for history but is no longer used by CI or releases. A separate sync branch and pull request added work and could pull unreleased changes into `main`; the release workflow now tests the exact version commit on `main` before pushing it, tagging it, and publishing the GitHub Release.

The latest published stable GitHub Release remains the baseline for a new version bump because repository version files have previously lagged behind publication. A release commit records its workflow run ID so rerunning a partially completed release can finish the same version. Changes to application code continue through pull requests to `main`; the workflow writes only the tested version metadata commit directly.
