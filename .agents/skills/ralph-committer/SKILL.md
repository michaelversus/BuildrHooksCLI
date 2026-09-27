---
name: ralph-committer
description: Ship one completed BuildrHooksCLI Ralph Loop issue after implementation and validation, from the parent session.
---

# Ralph Committer

Use in the parent session only after the issue's worker has reported and all required validation has passed or any remaining manual reviewer action has been recorded. Do not spawn a committer agent.

1. Inspect `git status --short` and the diff. Identify only files for the current issue and preserve unrelated changes.
2. Confirm every acceptance criterion is satisfied or identify why the issue must remain open. Review validation results and pending manual checks.
3. Comment on the GitHub issue with the implemented behavior, validation performed, and pending manual reviewer actions (or “None”).
4. Stage only the current issue's files. Create a focused Conventional Commit mentioning the issue number, then push the branch.
5. Close the issue only when implementation and blocking validation are complete.
6. Record the commit SHA, push result, closure status, and pending manual actions for the loop summary.

Do not create the final PR here; `$ralph-loop` creates it after every requested child issue is closed.
