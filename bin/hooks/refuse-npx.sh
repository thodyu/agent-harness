#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash tool. Refuses npx and npm exec (and its alias
# npm x), which run a package that may not be in the project and fetch it from
# the registry if it is missing. A brief can ban them, and this hook enforces
# the ban. A shell's command string (bash -c, sh -c) is read with the same
# rules. npm ci, npm install, npm test and npm run <script> pass, and so does a
# command that only names npx (an echo, a quoted argument, a heredoc body).
#
# npm's subcommand is its first word that is not an option. Not seen: an
# option that takes a value before the subcommand (npm --prefix x exec y,
# whose first such word is x), and the library's known gaps. sudo, timeout,
# nice and busybox in front are seen (lib/command-position.sh).
#
# Test: test-linux-hooks.sh beside it. refuse-command-hooks.sh runs it as one
# of its parts.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

refuse() {
  printf '%s\n' \
    "Refused: $1 runs a package that may not be in the project, and fetches it from the registry if it is missing. The brief bans it." \
    "Run the project's own script (npm run <script>, npm test), or its installed binary (node_modules/.bin/<name>)." >&2
  HOOK_REFUSED=1
  exit 2
}

for i in "${!SIMPLE[@]}"; do
  name="${SIMPLE[$i]%% *}"
  case "$name" in
    npx) refuse npx ;;
    npm)
      read -r -a npm_words <<< "${SIMPLE[$i]#* }"
      for npm_word in "${npm_words[@]}"; do
        [[ "$npm_word" == -* ]] && continue
        [[ "$npm_word" == exec || "$npm_word" == x ]] && refuse "npm $npm_word"
        break
      done ;;
  esac
done
exit 0
