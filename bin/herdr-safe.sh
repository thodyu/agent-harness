#!/usr/bin/env bash
# herdr-safe.sh <herdr arguments>
# Runs herdr with the same arguments after removing four traps of driving Herdr from an agent.
# Trap 1: a tab or pane id printed by Python on Windows ends in a carriage return.
# Herdr then reports the tab as not found, so the close fails and the worktree stays locked.
# This script strips one trailing carriage return from every argument.
# Trap 2: Git Bash rewrites an argument that starts with a slash into a Windows path.
# "/retro" then arrives as "C:/Program Files/Git/retro".
# This script sets MSYS_NO_PATHCONV=1 for herdr.
# Trap 3: Remote Control names a Claude session on its own, so a phone does not show the Herdr name.
# On "agent start <name> --kind claude" this script passes "--name <name> --remote-control <name>" to Claude,
# unless the Claude arguments after "--" already set either one.
# Trap 3 also holds after a leading "--session <name>" or "--session=<name>", and after a leading "--machine <label>" or "--machine=<label>" (a Herdr machine, such as a cloud machine).
# This script keeps those pairs first, in the order given, applies Trap 3 to the arguments after them, and passes them to herdr unchanged.
# Either pair may come first, and at most one of each is skipped. Herdr refuses --machine together with --session, and this script still passes both through, so Herdr's own error is the answer.
# Any other leading option leaves Trap 3 alone, and so does "--session" or "--machine" with no value, which herdr reports as an error.
# A second "--session" or a second "--machine" after the first leaves Trap 3 off with no message, though herdr then takes the last one.
# Trap 4: a Claude author or reviewer needs none of the claude.ai connectors (mail, drive, browser, docs), which add tool names to every turn.
# Claude Code turns them off with the setting disableClaudeAiConnectors, and herdr agent start has no way to set an environment variable, so this script passes "--settings <path>" to Claude.
# The file claude-agent-settings.json beside this script holds that setting, and a --settings file overrides only the keys it names.
# It applies on "agent start <name> --kind claude" or "--kind=claude", after any leading --session and --machine pairs, with or without Trap 3's pair.
# A name that starts with orch- or dev-orchestrator keeps its connectors and gets no --settings. Every other name gets the file.
# Nothing is added when the Claude arguments after "--" already hold "--settings" or "--settings=<value>".
# The caller's own is kept, no second is added and nothing is printed. A caller that passes --name or --remote-control still gets it.
# The argument goes straight after "--", or after Trap 3's "--name <name> --remote-control <name>" when Trap 3 added them, and before the caller's own arguments.
# With no "--" in the call, the "--" Trap 3 adds comes first.
# With a leading --machine the path is $ORCH_REMOTE_BIN/claude-agent-settings.json, the folder where the tools were synced on that machine, and this script does not check it there.
# With none, the path is the file beside this script, as cygpath -m prints it when cygpath is on PATH (Git Bash on Windows), else as it is.
# When that file is missing or not readable, or ORCH_REMOTE_BIN is unset for a --machine start, no --settings is added, one line on stderr says so, and the start goes on.
# Claude reads --settings when it starts, so a session already running keeps the settings it started with.
# Stdout, stderr and the exit status are herdr's own, apart from that one line.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || HERE=""
cr=$'\r'
args=()
for arg in "$@"; do
  args+=("${arg%"$cr"}")
done

# Moves a leading "<option> <value>" or "<option>=<value>" from args to lead, once per option.
# It fails when the first argument is neither, or when that option was taken already.
lead=()
taken=" "
on_machine=0
take_lead() {
  local opt=$1
  [[ $taken != *" $opt "* ]] || return 1
  if [ "${args[0]:-}" = "$opt" ] && [ -n "${args[1]:-}" ]; then
    lead+=("${args[@]:0:2}")
    args=("${args[@]:2}")
  elif [[ "${args[0]:-}" == "$opt"=?* ]]; then
    lead+=("${args[0]}")
    args=("${args[@]:1}")
  else
    return 1
  fi
  taken="$taken$opt "
  [ "$opt" != --machine ] || on_machine=1
}
while take_lead --session || take_lead --machine; do :; done

if [ "${args[0]:-}" = agent ] && [ "${args[1]:-}" = start ] && [ -n "${args[2]:-}" ]; then
  name="${args[2]}"
  kind=""
  sep=-1
  named=0
  given=0
  for i in "${!args[@]}"; do
    if [ "$sep" -lt 0 ]; then
      case "${args[$i]}" in
        --) sep=$i ;;
        --kind) kind="${args[$((i + 1))]:-}" ;;
        --kind=*) kind="${args[$i]#--kind=}" ;;
      esac
    else
      case "${args[$i]}" in
        -n | --name | --name=* | --remote-control | --remote-control=*) named=1 ;;
        --settings | --settings=*) given=1 ;;
      esac
    fi
  done
  if [ "$kind" = claude ] && [ "$named" -eq 0 ]; then
    if [ "$sep" -lt 0 ]; then
      sep=${#args[@]}
      args+=(-- --name "$name" --remote-control "$name")
    else
      args=("${args[@]:0:$((sep + 1))}" --name "$name" --remote-control "$name" "${args[@]:$((sep + 1))}")
    fi
  fi
  # Trap 4. A Claude start has a "--" by now: the caller's, or the one Trap 3 added (a name or a --settings is only read after a "--", so a start with neither always got Trap 3's).
  if [ "$given" -eq 0 ] && [ "$kind" = claude ]; then
    # An orchestrator keeps its connectors, so it gets no file. Every other name gets the one file.
    settings=""
    case "$name" in
      orch-* | dev-orchestrator*) ;;
      *)
        if [ "$on_machine" -eq 1 ]; then
          if [ -n "${ORCH_REMOTE_BIN:-}" ]; then
            settings="${ORCH_REMOTE_BIN%/}/claude-agent-settings.json"
          else
            echo "herdr-safe: ORCH_REMOTE_BIN is unset, so this Claude start on a --machine passes no --settings" >&2
          fi
        else
          settings="$HERE/claude-agent-settings.json"
          if [ ! -r "$settings" ]; then
            echo "herdr-safe: $settings is missing or not readable, so this Claude start passes no --settings" >&2
            settings=""
          elif command -v cygpath >/dev/null 2>&1; then
            settings="$(cygpath -m "$settings")"
          fi
        fi
        ;;
    esac
    if [ -n "$settings" ]; then
      pos=$((sep + 1))
      [ "$named" -ne 0 ] || pos=$((pos + 4))
      args=("${args[@]:0:$pos}" --settings "$settings" "${args[@]:$pos}")
    fi
  fi
fi

export MSYS_NO_PATHCONV=1


exec herdr "${lead[@]}" "${args[@]}"
