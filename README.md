# agent-harness

An agent multiplexer and a hybrid cloud harness for running coding agents.

This repository holds the working parts of a system that lets one orchestrating agent run many coding agents at once. The orchestrator splits work into tickets. Each ticket's agent gets its own terminal tab and its own git worktree. Every change goes through an independent review gate before it merges. Agents spread over a local machine and a cloud machine, and each machine has its own limits on how many agents it will carry.

The parts are shell scripts, hooks and tests. They have no build step and need only bash, git and a few standard tools. They drive Herdr, a terminal multiplexer for coding agents, and the `claude` command line.

## Start here

`docs/how-it-works.md` explains the method: the gate, the wake routine, the hand-over, the slot limits and the traps the tools exist to avoid. The tools make most sense once you have read it.

## What each part does

### Agents and tabs

- `bin/herdr-safe.sh` wraps the multiplexer's command line. It strips a stray carriage return from every argument, stops the shell rewriting a slash command into a path, names each new agent's session and remote-control handle after its tab, and starts every agent with a settings file that turns off connectors it does not need. It also carries a `--machine` option for an agent on the cloud machine.
- `bin/claude-agent-settings.json` is the one settings file that wrapper passes to an agent.
- `bin/orch-wake.sh` is the wake routine. One blocking call waits on named agents, and on long runs, until one changes state or vanishes, then prints what changed and the head of each report file. It replaces three separate multiplexer calls and runs cheaply.

### Slots and long runs

- `bin/slots.sh` says whether one more author or reviewer may start. It reads free memory and the agent list on each machine, and counts a slot only for an agent that is working or blocked. With `--machine any` it asks each machine in order and stops at the first that has room.
- `bin/machine-lib.sh` is the shared parse of the machine table and the lookup of a cloud machine's SSH target.
- `bin/machines.conf` is a sample of that table: a label, a limit for authors, a limit for reviewers and a free-memory floor, for each machine.
- `bin/run-long.sh` runs one long command under a name. It refuses to start under the memory floor, allows one run per name, detaches the command from the shell, and ends its log with a line carrying the exit code.

### Worktrees

- `bin/worktree-new.sh` makes a ticket's worktree the same way every time, from a per-repository manifest, under a machine-wide lock so two calls never collide. With `--detach` it makes a reviewer's own copy at a given commit. On a cloud machine it refuses a manifest that copies files, so a secret of the control machine is never copied there.
- `bin/worktree-remove.sh` closes a ticket in an order that does not lock the worktree. It closes the tab, lists any process holding the folder, removes the worktree, and deletes the branch only once the host shows its pull request merged at the branch's tip.
- `bin/worktree-manifests/example-service.conf` is a sample manifest.

### Checkers

- `bin/prose-check.sh` fails a file that holds dashes, stray control characters or, in Markdown, semicolons outside code.
- `bin/report-check.sh` checks that a report opens with a short `## For the orchestrator` section that an orchestrator can read with `head -40`.
- `bin/state-check.sh` checks the shape and size of an orchestrator's state file.
- `bin/mutant.sh` makes a deliberately broken copy of a script, to prove that a test can fail.

### Hooks

The hooks in `bin/hooks/` run before or after an agent's tool call and refuse what the method forbids. Only a deliberate refusal blocks a call. A hook that crashes lets the call through.

- `refuse-command-hooks.sh` runs the seven command hooks below in one shell, so each call costs one shell start and not seven.
- `refuse-kill-by-name.sh` refuses killing processes by name.
- `refuse-merge-default-body.sh` refuses a pull request merge with no explicit subject, body and head-commit match.
- `refuse-python-heredoc.sh` refuses a heredoc fed to an interpreter.
- `refuse-npx.sh` refuses running a package that may not be in the project.
- `refuse-unsafe-shell.sh` refuses `rm` and redirects whose path comes from an unguarded variable or a command substitution.
- `refuse-shell-edits.sh` refuses editing a file in place through the shell.
- `refuse-dev-vars-print.sh` and `refuse-dev-vars.sh` refuse printing or reading a secrets file by its conventional name.
- `check-state-file.sh` runs the state check after a state file is written.
- `warn-orchestrator-context.sh` adds one line of context to a prompt when a session has grown past a threshold, so the orchestrator can hand itself over.
- `lib/command-position.sh` is the shared parser the command hooks use to find the command word of each simple command, through `sudo`, `timeout` and shell strings.

### Tests

Each hook has a test file in `bin/hooks/`, and the scripts above have test files in `bin/tests/`. All of them use the case runner `bin/tests/cases.sh`, which lists, filters and times cases and prints a counts line. Tests use fakes for the multiplexer and for ssh, and they touch no network. Run one with `bash bin/hooks/test-command-hooks.sh` or `bash bin/tests/slots.test.sh`. Pass `--list` to see its cases, and set `CASES="name ..."` to run some of them.

## Setting up

Set `ORCH_HOME` to the folder for the orchestrator's working files (locks, state, reports). Set `ORCH_BIN` to the folder that holds these tools. Edit `bin/machines.conf` to name your machines and limits. Add one manifest to `bin/worktree-manifests/` for each repository you will work on, named for the last part of its origin URL. To register the hooks, point your agent settings at `bin/hooks/refuse-command-hooks.sh` for shell tool calls, `bin/hooks/check-state-file.sh` after file writes, and `bin/hooks/warn-orchestrator-context.sh` on prompt submit.

## Notes

- The names `.dev.vars` in the hooks and their tests are a file name convention for a local secrets file, not a secret. The repository holds no such file and no key. The hooks stay as examples of refusing a read by name.
- The names `orch-`, `dev-orchestrator`, `review-` and `-check` are role conventions that `slots.sh` and the hooks read. They name roles, not people.
- The scripts were written for Linux and for Git Bash on Windows. Where a tool behaves differently on Windows, its header says so.
- `run-long.sh` has no test file here. Treat it as untested in this repository.

## Licence

MIT. See `LICENSE`.
