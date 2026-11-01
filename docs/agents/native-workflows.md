# Native issue workflows

Use the shared MySkills `native-ticket` skill for one selected GitHub issue and
`native-spec` for a parent spec's direct child dependency graph. Read the selected
skill's operator route before acting. The shared Python controller owns worktrees,
validation, bounded repairs and delivery; native chats perform implementation,
independent review and proposal-only retrospective phases. Repository-local agent
roles are not required. Shared skills may delegate review according to their own
instructions.

## Repository policy

`workflow.config.json` targets `main`, consistent with ADR-0003. Ticket checks run
on each member locally and after integration; spec checks run after all members
are integrated. Standalone ticket delivery runs both scopes. Workers should also
run focused tests during implementation using the Swift CLI wrappers.

The wrappers retain serial Swift Testing, coverage, formatting/lint policy and
staged executable/resource smoke checks. See [Swift CLI tooling](../swift-cli.md)
for prerequisites and evidence. Install `swift-cli-project` from the reviewed,
durable MySkills checkout and expose it on the controller's PATH before launch;
the local `MYSKILLS_SWIFT_CLI_RUNTIME` override is also supported. Keep machine
paths out of the portable workflow configuration. Checks run as literal argv
from the assigned worktree with host permissions.

Computer acceptance is explicitly disabled. Unit tests and staging do not establish
BuildrAI integration, live collectors, background services, notifications,
device/provider behavior or release acceptance. Record applicable pending manual
criteria in each run's evidence. The runner never merges, deploys or releases.

For a spec, use native GitHub sub-issues and blocking edges as documented in
[the tracker guide](issue-tracker.md). The runner also supports its documented
`Part of #PARENT` and `Blocked by:` fallbacks. Accepted integration unblocks the
next member without closing its issue. One shared draft PR becomes ready after
the final gates; parent and implemented children remain open until owner merge.
Standalone native-ticket delivery instead closes its selected issue before merge.
Use the appropriate controller's closure policy rather than generic tracker
resolve instructions for these runs.

## Host setup and verification

1. Make `native-ticket`, `native-spec`, `ticket-tdd`, `code-review`, `ticket-pr`,
   `retro` and `writing-for-agents` available from the shared common skills.
   Preserve the Swift bundle selection in `.skill-bundles.json`. Reload a fresh
   chat after changing the skill or agent catalog.
2. Verify Git/GitHub authentication, build/check tools and the native saved project
   matching this repository's exact path. Native dispatch must use the controller's
   exact prompt, model and reasoning settings in that project.
3. Follow native-ticket's managed-runtime setup procedure. Use its returned,
   verified absolute Python interpreter for normal commands. Setup preserves
   unrelated BuildrHooksCLI event hooks while adding the runner's Interrupt,
   UserPromptSubmit, Stop and PreToolUse handlers. Generated hook commands contain
   host-specific paths; rerun supported setup when provisioning another host.
4. Review new or changed hook definitions through `/hooks` in the bundled native
   CLI, then use fresh worker chats. Setup never substitutes for hook trust.
   Before relying on phone control, explicitly request the disposable acceptance
   flow to verify Stop and same-worker Continue. Hook installation alone does not
   establish live transport acceptance.

## Operation and recovery

Planning a spec saves its contract without implementation, worktrees, PRs or issue
mutations. Inspect the plan and verify its exact run ID before explicitly launching.
Starting a ticket or launching a spec requires a request to execute that workflow;
repository setup does not authorize a run.

Keep the launcher chat active for native phase dispatch. Answer questions and
continue stopped work in the assigned worker chat. Reopening or asking for status
does not authorize continuation. After controller loss, use the selected skill's
exact saved-run recovery procedure and reconcile uncertain effects before sending
another job. Read recorded state/results for status; an idle chat or completed
worker response does not prove readiness.
