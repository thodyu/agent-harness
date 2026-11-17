#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Runs the seven command
# hooks in one bash, in this order: refuse-kill-by-name.sh,
# refuse-merge-default-body.sh, refuse-python-heredoc.sh, refuse-npx.sh,
# refuse-unsafe-shell.sh, refuse-dev-vars-print.sh and refuse-shell-edits.sh.
# The agent settings register this file in place of the seven, because each
# registered hook starts its own bash on every call, and on a loaded machine
# (or under Git Bash on Windows) that start costs seconds. A hook that passes
# its timeout lets the call through, so a slow start loses a refusal. A
# subshell does not help: a fork costs about as much as a bash start, so
# nothing below forks.
#
# This file holds no check of its own. It sources the library and parses the
# payload once, and sets COMMAND_HOOK_PARSED, so that each hook's own source of
# the library and its read_simple_commands do nothing. It then runs each hook's
# text in this shell, minus the hook's final line, exit 0, which would end this
# shell before the next hook ran. Every other end of a hook is a refusal, which
# sets HOOK_REFUSED and exits 2 here as it does there, with the hook's own
# message. The first refusal ends the run, so a command that two hooks would
# refuse shows only the first message until it is fixed.
#
# A hook whose text does not end in a line of exit 0 (a CRLF save, a cut last
# line) or whose file is missing is skipped, not run, so the strip can never cut
# a hook in the middle. One line on standard error names the hook and says it
# was skipped, and the run goes on with the next hook. A syntax error in a hook
# is reported on standard error, as it is when the hook runs alone, and the run
# goes on with the next hook. A crash that ends the shell in one part also drops
# the parts after it, which a hook alone never did, and the entry still exits 0.
# Only a deliberate refusal exits 2.
#
# The seven hooks stay as scripts of their own, so each runs and is tested alone
# (test-command-hooks.sh beside this file tests each one and this one,
# test-dev-vars.sh tests refuse-dev-vars-print.sh, and test-linux-hooks.sh
# tests refuse-npx.sh and the Linux forms of the others).

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0
COMMAND_HOOK_PARSED=1

for hook in refuse-kill-by-name refuse-merge-default-body refuse-python-heredoc refuse-npx refuse-unsafe-shell refuse-dev-vars-print refuse-shell-edits; do
  src=""
  IFS= read -r -d '' src 2>/dev/null < "$HOOK_DIR/$hook.sh"
  if [[ "$src" != *$'\nexit 0\n' ]]; then
    printf '%s\n' "refuse-command-hooks.sh: $hook.sh skipped, it is missing or does not end in a line of exit 0" >&2
    continue
  fi
  # shellcheck disable=SC2294  # the text is the hook, run as written
  eval "${src%exit 0*}"
done
exit 0
