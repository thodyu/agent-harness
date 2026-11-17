#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Refuses a heredoc or
# here-string fed to python3, python or py, whatever its body holds, because it
# can hang until the harness's 120 second timeout. A backslash in the body also
# loses a level of escaping on the way to the shell and damages what the script
# writes.
#
# The names are python3 and python3.exe, python, python.exe, py, and the
# versioned names python3.13, python3.14 and python3-64, by any path. python -
# is python. Fed means a heredoc (<<, <<-, <<'EOF',
# <<"EOF") or a Bash here-string (<<<) on the python command itself, whatever
# its other arguments, or on cat piped straight into it, or a PowerShell
# here-string (@'...'@ or @"..."@) piped straight into it. A shell's command
# string (bash -c, powershell -Command, cmd /c) is read with the same rules.
# A python3 - <<E ... 2>/dev/null || echo nopython in a bash -c string once hung
# and held a worktree folder until its tab was closed. cmd has no heredoc, so a
# cmd /c string with one is broken anyway.
#
# It also refuses python -, python3 - and py - with nothing on standard input,
# which wait for a script that never comes and hang until the harness's timeout.
# Input is a pipe into it (echo x | python -), a redirect from a file
# (python - < script.py) or a heredoc or here-string (refused above). The -
# counts only as the script, so python -c "..." - and python script.py - pass.
# Not seen: a wrapper such as uv run or timeout, and a python - in a command
# substitution inside double quotes or backticks (echo "$(python -)"), because
# the library replaces a quoted string by a token before it looks for $( . This
# is a known gap of lib/command-position.sh.
#
# A false refusal costs a turn, so these pass: a here-string kept in a
# variable and piped later ($code | python), a heredoc passed as an argument
# (python3 -c "$(cat <<EOF ...)", python -c @'...'@), another command between
# the heredoc and python in the pipeline, echo or Get-Content piped into
# python, a quoted interpreter name (& "C:\...\python3.exe"), PowerShell's
# & python (the library splits at &), and a wrapper such as uv run, timeout or
# winpty. The library's known gaps hold here too.
#
# It also refuses a heredoc or here-string fed to node or nodejs, by the same
# rules, since a backslash in the body loses a level of escaping the same way.
# node - with nothing on standard input is not refused (node reads a pipe or
# a terminal, and a call has neither). node <file> and node -e "..." pass.
#
# Tests: test-command-hooks.sh and test-linux-hooks.sh beside it.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

FIX="Write the script to a file in your scratchpad (or a mktemp file) and run python <file>, or make the edit with the Edit tool."

refuse() {
  local fix=$FIX
  [[ "$name" == node* ]] && fix=${FIX/python <file>/$name <file>}
  printf '%s\n' "$@" "$fix" >&2
  HOOK_REFUSED=1
  exit 2
}

heredoc_token='^<<%[Hh]([0-9]+)$'
here_string_token='^@%[Hh]([0-9]+)$'
# A redirect from a file: < or 0< and then a word, but not << or <<<.
redirect_from='^[0-9]*[<]([^<]|$)'

# fed <words>: FED is 1 when the words hold a heredoc or a Bash here-string.
fed() {
  local w
  FED=0
  for w in "$@"; do
    [[ "$w" =~ $heredoc_token || "$w" == "<<<" ]] && FED=1
  done
}

# piped_into <i>: true when a pipe feeds command i. The library keeps the command
# in a $( ) or a backtick in the pipeline of the command before it, and marks that
# one in SUBST, so a substitution start is not a pipe.
piped_into() {
  (( $1 > 0 )) && [[ "${PIPE_ID[$1 - 1]}" == "${PIPE_ID[$1]}" && "${SUBST[$1 - 1]}" != 1 ]]
}

for i in "${!SIMPLE[@]}"; do
  name="${SIMPLE[$i]%% *}"
  case "$name" in
    python3|python|py|python3.[0-9]*|python3-64) ;;
    node|nodejs) ;;
    *) continue ;;
  esac
  read -r -a words <<< "${SIMPLE[$i]#* }"
  fed "${words[@]}"
  # The command before it in its pipeline: cat with a heredoc or here-string,
  # or a PowerShell here-string.
  if (( ! FED && i > 0 )) && [[ "${PIPE_ID[i - 1]}" == "${PIPE_ID[i]}" ]]; then
    read -r -a words <<< "${SIMPLE[i - 1]}"
    if [[ "${words[0]}" == "cat" ]]; then
      fed "${words[@]:1}"
    elif [[ "${words[-1]}" =~ $here_string_token ]]; then
      FED=1
    fi
  fi
  if [[ "$name" == node || "$name" == nodejs ]]; then
    (( FED )) && refuse \
      "Refused: a heredoc or here-string fed to $name. The brief bans it, and a backslash in the body loses a level of escaping on the way to the shell."
    continue
  fi
  (( FED )) && refuse \
    "Refused: a heredoc or here-string fed to $name. It hangs on this machine until the 120 second timeout, and a backslash in the body loses a level of escaping on the way to the shell."
  # The script is read from standard input only when a bare - comes before the
  # script file, the code of -c and the module of -m, which are the first word
  # that is not an option.
  read -r -a words <<< "${SIMPLE[$i]#* }"
  stdin_script=0
  for (( k = 0; k < ${#words[@]}; k++ )); do
    case "${words[k]}" in
      -) stdin_script=1; break ;;
      -W|-X) k=$((k + 1)) ;;
      -*) ;;
      *) break ;;
    esac
  done
  (( stdin_script )) || continue
  # Input: a pipe into it, or a redirect from a file on the python command.
  piped_into "$i" && continue
  read -r -a words <<< "${RAW[$i]}"
  from_file=0
  for word in "${words[@]}"; do
    [[ "$word" =~ $redirect_from ]] && from_file=1
  done
  (( from_file )) && continue
  refuse "Refused: $name - with nothing on standard input. It waits for a script that never comes, so the call hangs until the harness's timeout."
done
exit 0
