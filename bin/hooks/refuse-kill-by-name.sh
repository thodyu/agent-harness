#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Refuses killing a process
# by its name: taskkill with /IM or with an IMAGENAME filter, Stop-Process,
# spps or kill with -Name or -ProcessName, Get-Process <name> piped to
# Stop-Process, and .Kill() on a process found by name. A shell's command
# string (powershell -Command, cmd /c, bash -c) is read with the same rules.
# Closing a tab can leave a dev server alive and lock a worktree, and killing
# by name also kills the node, esbuild and workerd processes of every other
# agent on the machine.
#
# The Linux forms are refused too: pkill and killall with any argument, kill
# fed the ids of pgrep or pidof through $( ), a backtick or "$( )", and pgrep
# or pidof piped into xargs kill (or xargs pkill or killall). kill <id> passes,
# and so do pgrep and pidof alone, which only list. Not seen: ids kept in a
# variable first (ids=$(pgrep x); kill $ids), ids read in a loop
# (pgrep x | while read p; do kill $p; done), and the library's known gaps.
# sudo, timeout, nice and busybox in front are seen (lib/command-position.sh).
#
# Tests: test-command-hooks.sh and test-linux-hooks.sh beside it.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

refuse() {
  printf '%s\n' \
    "Refused: $1 kills by process name, which also stops every other agent's processes of that name." \
    "Stop node, esbuild or workerd by process id, found by its command line. In PowerShell:" \
    "  Get-CimInstance Win32_Process | Where-Object { \$_.CommandLine -like '*<your worktree>*' } | Select-Object ProcessId, Name, CommandLine" \
    "  Stop-Process -Id <id>      (from Git Bash: taskkill //PID <id>, since Git Bash rewrites /PID as a path)" >&2
  HOOK_REFUSED=1
  exit 2
}

# refuse_linux <what>: the Linux form's message, with the Linux way to the id.
refuse_linux() {
  printf '%s\n' \
    "Refused: $1 kills by process name, which also stops every other agent's processes of that name." \
    "Stop node, esbuild or workerd by process id, found by its command line:" \
    "  grep -l -a -- '<your worktree>' /proc/[0-9]*/cmdline      (or pgrep -af '<your worktree>', which only lists)" \
    "  kill <id>" >&2
  HOOK_REFUSED=1
  exit 2
}

# The Linux finders of ids by name, and a $( ) or backtick that opens with one.
finder='^(pgrep|pidof)$'
# shellcheck disable=SC2016  # the $( and backtick are text to match
finder_subst='(\$\(|`)[[:space:]]*(pgrep|pidof)([[:space:]]|\)|`|$)'

# -Name and -ProcessName, and any prefix PowerShell accepts for them. -p alone
# also abbreviates -PassThru, so -ProcessName needs at least -pr.
process_name='pr(o(c(e(s(s(n(a(m(e)?)?)?)?)?)?)?)?)?'
name_flag="(^|[[:space:]])-(n(a(m(e)?)?)?|$process_name)([[:space:]:]|\$)"
# For kill, -n alone is Bash's signal number, so it needs -na in Bash.
kill_name_flag="(^|[[:space:]])-(na(m(e)?)?|$process_name)([[:space:]:]|\$)"
[[ "$TOOL_NAME" == "PowerShell" ]] && kill_name_flag="$name_flag"
id_flag='(^|[[:space:]])-(i(d)?|inputobject)([[:space:]:]|$)'

# Get-Process with a name, positional or -Name, and no -Id: the index of the
# first one in each pipeline. Only a kill after it in its pipeline counts.
declare -A named_getter=()
any_named_getter=0
for i in "${!SIMPLE[@]}"; do
  word="${SIMPLE[$i]%% *}"
  lower=" ${SIMPLE[$i]#* }"
  lower="${lower,,}"
  case "$word" in
    get-process|gps|ps)
      if [[ -n "${lower// /}" && ! "$lower" =~ $id_flag ]]; then
        [[ -n "${named_getter[${PIPE_ID[$i]}]:-}" ]] || named_getter[${PIPE_ID[$i]}]=$i
        any_named_getter=1
      fi ;;
  esac
done

for i in "${!SIMPLE[@]}"; do
  word="${SIMPLE[$i]%% *}"
  lower=" ${SIMPLE[$i]#* }"
  lower="${lower,,}"
  case "$word" in
    taskkill)
      [[ "$lower" =~ (^|[[:space:]])(//?|-)im([[:space:]:]|$) ]] && refuse "taskkill /IM"
      read -r -a args <<< "${SIMPLE[$i]#* }"
      for (( j = 0; j + 1 < ${#args[@]}; j++ )); do
        [[ "${args[j],,}" =~ ^(//?|-)fi$ ]] || continue
        unquote "${args[j + 1]}"
        [[ "${UNQUOTED,,}" =~ ^[[:space:]]*imagename ]] && refuse "taskkill /FI \"IMAGENAME eq ...\""
      done ;;
    stop-process|spps)
      [[ "$lower" =~ $name_flag ]] && refuse "Stop-Process -Name or -ProcessName"
      (( ${named_getter[${PIPE_ID[$i]}]:-$i} < i )) && refuse "Get-Process <name> | Stop-Process" ;;
    kill)
      [[ "$lower" =~ $kill_name_flag ]] && refuse "kill -Name or -ProcessName"
      (( ${named_getter[${PIPE_ID[$i]}]:-$i} < i )) && refuse "Get-Process <name> | kill"
      # The library puts the command of a $( ) or backtick after kill's own entry, in its pipeline, and marks kill in SUBST.
      if [[ "${SUBST[$i]:-}" == 1 && "${PIPE_ID[i + 1]:-}" == "${PIPE_ID[$i]}" && "${SIMPLE[i + 1]%% *}" =~ $finder ]]; then
        refuse_linux "kill \$(${SIMPLE[i + 1]%% *} ...)"
      fi
      # Inside double quotes the substitution is in the quoted text.
      read -r -a args <<< "${SIMPLE[$i]#* }"
      for arg in "${args[@]}"; do
        [[ "$arg" =~ ^Q([0-9]+)$ && "${QUOTE_DQ[${BASH_REMATCH[1]}]:-}" == 1 ]] || continue
        [[ "${QUOTED[${BASH_REMATCH[1]}]}" =~ $finder_subst ]] && refuse_linux "kill \"\$(${BASH_REMATCH[2]} ...)\""
      done ;;
    pkill|killall)
      refuse_linux "$word" ;;
    xargs)
      # pgrep or pidof before it in its pipeline, and kill, pkill or killall among its words.
      read -r -a args <<< "${SIMPLE[$i]#* }"
      for arg in "${args[@]}"; do
        [[ "$arg" == kill || "$arg" == pkill || "$arg" == killall ]] || continue
        for (( j = 0; j < i; j++ )); do
          [[ "${PIPE_ID[j]}" == "${PIPE_ID[$i]}" && "${SIMPLE[j]%% *}" =~ $finder ]] && refuse_linux "${SIMPLE[j]%% *} | xargs $arg"
        done
      done ;;
  esac
done
(( KILL_METHOD && any_named_getter )) && refuse "Get-Process <name> with .Kill()"
exit 0
