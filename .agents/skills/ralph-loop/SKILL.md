---
name: ralph-loop
description: Implement an inclusive range of GitHub issues under a parent PRD, one issue at a time, with validation, commits, issue updates, and a final pull request.
---

# Ralph Loop

Use this skill when the user asks for a sequential implementation loop, for example `$ralph-loop prd 123 issues 124...128`. The range includes both endpoints. Ask for any missing or ambiguous issue number, and reject a reversed range.

## Before starting

1. Inspect `git status --short`, the current branch, and the GitHub remote. Preserve unrelated changes; if they make it impossible to isolate commits for each issue, ask the user how to proceed.
2. Read the parent PRD issue, its comments, and all child issues in the range. Follow `AGENTS.md` and `docs/agents/issue-tracker.md`.
3. Record the start time. Stop after a safe checkpoint if five hours elapse, and report the remaining issues.

## For each issue, in order

1. Spawn one fresh repo-local `ralph-worker` agent for that issue and wait for its final report. Do not implement issues in parallel unless the user explicitly requests it.
2. Check the worker's changed files, acceptance criteria, commands, blockers, and pending manual reviewer actions. Review the actual diff.
3. Select every applicable validation mode:
   - **Swift:** Swift source, package manifests, test plans, or generated Swift-facing resources. Run `tester` first, then `linter`, waiting for each. Use the SwiftPM workflow in this repository: focused `swift test` coverage first, then `swift build` when production code or package configuration changes.
   - **Scripts and CLI behavior:** Shell scripts, CLI behavior, CI, fixtures, or executable command documentation. Run focused checks in the parent session or delegate to a fresh validation agent if available.
   - **Docs:** Documentation-only changes need a content review; skip build and lint agents unless the issue identifies another check.
4. Fix blocking failures and confirm all acceptance criteria are satisfied. Manual checks may remain pending if documented precisely; do not claim they were performed.
5. Execute the repo-local `$ralph-committer` skill in the parent session for this issue. Verify its commit, push, issue comment, and closure before starting the next issue.

If an issue remains blocked or open, stop the loop and report its status. Do not create the final PR while any child issue in the requested range remains open.

## Finish

After every issue is shipped and closed, use a repo-local `$create-pr` skill if one is installed; otherwise create the final GitHub pull request with `gh pr create`, referencing the parent spec and completed child range. Report each issue's validation, commit, push and closure result, the PR URL, and pending reviewer actions.

The parent session owns GitHub writes, commits, and pushes. Workers and validation agents do not perform those shipping steps. Keep current sandbox permissions and handle any required approval in the parent session.
