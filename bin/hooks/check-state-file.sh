#!/usr/bin/env bash
# Only a state file that breaks a rule exits 2. Any other end, a syntax error or a
# crash included, exits 0 and lets the session carry on.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PostToolUse hook for the Write and Edit tools. When the file written is a
# state.md under the orchestrator folder (either slash style, any case), it runs
# state-check.sh on it. A failure goes to stderr under a first line naming the
# file, with exit 2, so the session sees which rule broke. A pass is silent.
#
# This hook runs on every Write and Edit of every Claude session on the machine.
# For any other file it reads standard input, takes file_path and compares strings
# with bash built-ins, and exits 0 before it starts a process.
#
# It reads only the first 16 KB of the payload, which holds file_path because the
# harness writes it first in tool_input. Bash reads about 10 microseconds a byte,
# so reading a 1 MB Write whole took seconds and one past about 1 MB passed the
# timeout. If file_path is not in that start, the hook exits 0. The rest of the
# payload is left unread.
#
# STATE_HOOK_ROOT is the folder searched, ORCH_HOME by default. With neither set
# the hook does nothing. STATE_CHECK_SCRIPT is the check, state-check.sh in
# ORCH_BIN (else the folder above this one) by default. Both exist for the test.
#
# Test: test-state-hook.sh beside it.

input=""
IFS= read -r -N 16384 input
[[ "$input" =~ \"file_path\"[[:space:]]*:[[:space:]]*\"(([^\"\\]|\\.)*)\" ]] || exit 0
file="${BASH_REMATCH[1]//\\\\/\\}"
file="${file//\\\//\/}"
file="${file//\\//}"

root="${STATE_HOOK_ROOT:-${ORCH_HOME:-}}"
[[ -n "$root" ]] || exit 0
root="${root//\\//}"
root="${root%/}"

lower="${file,,}"
[[ "$lower" == "${root,,}"/* && "${lower##*/}" == "state.md" ]] || exit 0

script="${STATE_CHECK_SCRIPT:-${ORCH_BIN:-${BASH_SOURCE[0]%/*}/..}/state-check.sh}"
[[ -f "$script" ]] || exit 0

out=$("$BASH" "$script" "$file") && exit 0
[[ $? -eq 1 && -n "$out" ]] || exit 0

printf 'state-check failed for %s:\n%s\n' "$file" "$out" >&2
HOOK_REFUSED=1
exit 2
