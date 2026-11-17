#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Refuses a command that
# prints a .dev.vars file whole: cat, head, tail, less, more, type, Get-Content,
# gc and bat with a .dev.vars file among their words. The file holds secrets, and
# a command's output goes into the transcript. A shell's command string (bash
# -c, powershell -Command, cmd /c) is read with the same rules. This is the
# command half of refuse-dev-vars.sh.
#
# The name is the last part of the word, matched as refuse-dev-vars.sh matches
# it: .dev.vars, or .dev.vars. and more except .dev.vars.example, in any case,
# with either slash, in quotes or not, and a word after -Path: counts. A word
# with a glob character that starts with a dot and could match .dev.vars (.dev.v*,
# .*) counts too, because the shell would expand it. A redirect from the file
# (cat < .dev.vars) counts. These pass: grep -c and grep -q on the file, which
# print a count or nothing, and .dev.vars.example, which holds no secrets.
#
# Known gaps. These are not seen: any other reader (grep without -c, sed, awk,
# xxd, base64, cp, source), a wrapper (xargs cat), a name built in a variable,
# and a cat in a pipe to a command that prints less (cat .dev.vars | grep -c is
# refused too, since the hook cannot tell what the next command does).
# A command substitution inside double quotes or backticks is not read either
# (x="$(cat .dev.vars)"), because the library replaces a quoted string by a token
# before it looks for $( . This is a known gap of lib/command-position.sh.
#
# Test: test-dev-vars.sh beside this file.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

refuse() {
  printf '%s\n' \
    "Refused: $1 prints a .dev.vars file whole. The file holds secrets, and a command's output goes into the transcript." \
    "A human copies .dev.vars.example to .dev.vars and types the keys. A check reads a key by name and shape only, for example:" \
    "  grep -c '^EXAMPLE_API_KEY=abc_' .dev.vars" \
    "grep -c and grep -q on the file are not refused." >&2
  HOOK_REFUSED=1
  exit 2
}

# names_dev_vars <word>: succeeds when the word names a .dev.vars file.
names_dev_vars() {
  local cand="$1" base
  cand=${cand//\\//}
  cand=${cand#<}
  base=${cand##*/}
  base=${base,,}
  base=${base%%:*}
  while [[ "$base" == *" " ]]; do base=${base% }; done
  [[ "$base" == .dev.vars || ( "$base" == .dev.vars.* && "$base" != .dev.vars.example ) ]] && return 0
  # A glob the shell would expand to the file. A leading dot has to be written.
  if [[ "$base" == .*[\*\?\[]* ]]; then
    # shellcheck disable=SC2053  # the right side is a glob on purpose
    [[ .dev.vars == $base || .dev.vars.local == $base ]] && return 0
  fi
  return 1
}

for i in "${!SIMPLE[@]}"; do
  name="${SIMPLE[i]%% *}"
  case "$name" in
    cat|head|tail|less|more|type|get-content|gc|bat) ;;
    *) continue ;;
  esac
  read -r -a words <<< "${SIMPLE[i]#* }"
  for word in "${words[@]}"; do
    # A word that starts with # begins a comment, to the end of the command.
    [[ "$word" == \#* ]] && break
    restore_quotes "$word"
    arg="$RESTORED"
    if [[ "$arg" == -* ]]; then
      # -Path:file carries its value. Any other flag is not a file.
      [[ "$arg" == -*:* ]] || continue
      arg="${arg#*:}"
    fi
    names_dev_vars "$arg" && refuse "$name"
  done
done
exit 0
