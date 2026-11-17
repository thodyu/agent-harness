#!/usr/bin/env bash
# orch-wake.sh [--bound <seconds>] [--every <seconds>] [<agent>[@<state>][=<report path>] | run:<name>]...
# Waits in the foreground until any named Herdr agent changes state or disappears, or any named run ends, or until the bound.
# One call replaces a herdr agent list, agent get and agent wait at an orchestrator wake.
# Flags: --bound is the longest wait (default 540, must be under 600). --every is the poll interval (default 10).
# A remote name (<label>/<name>, below) raises --every to 20 s, and a note on stderr after the output says so.
# An agent argument may carry the state the caller last saw, as name@state or name@state=path.
# A caller uses it by passing back the state the last wake printed for that agent. Use a bare name at the first wait on an agent.
# For an agent given with @state, that state is its baseline. When the first poll already differs from it,
# the script returns at once with wake: change, before any sleep. That covers an agent that finished between two calls.
# An agent given with @state that is gone at the first poll is a change too, since the caller saw it alive.
# For a bare name the baseline is the state at the first poll, so a bare name that does not exist exits 1 at once.
# An empty state (name@ or name@=path), an empty name (@state) and a state that holds @ are usage errors.
# A run:<name> argument waits on a run that run-long.sh started under that name, beside the agents. <name> holds letters, digits and hyphens only.
# The run counts as running while run-long.sh status says so, or says it is waiting for memory, and its ending is a change the same way a vanished agent is one.
# A waiting start that is gone (status says "waiting start is gone") counts as lost. A run that has already ended, or was lost, at the first poll is a change at once, since the caller last saw it running.
# A name with no run at the first poll exits 1. A caller passes a run:<name> only until a wake has told it the run ended.
# It reads the run through bash $ORCH_WAKE_RUN_LONG status (default: run-long.sh beside this script) and the locks folder RUN_LONG_LOCKS, as run-long.sh does.
# Output: a first line "wake: change" or "wake: bound". Then one line per agent: name, state, pane id.
# A changed agent also shows "(was <old state>)". A vanished agent shows "gone gone".
# Then one line per run: "run:<name> running", or "run:<name> ended exit <code> (was running)", or "run:<name> lost (was running)".
# A changed run is followed by its end line (the last line of its log) and "log <path>".
# For each changed agent given as name=path it then prints the first 15 lines of that file.
# If the file is not there yet it prints one line saying so.
# Exit 0 on a change and on the bound. Exit 1 on a usage error, an unknown bare agent name, a run:<name> with no run or a failed herdr agent list.
# With run: arguments only, herdr is not started at all.
# Each poll starts herdr, run-long.sh status for each run, and sleep and nothing else. The JSON is parsed with bash built-ins.
# The last sleep stops at the bound and one last poll follows, so a late change gives wake: change. That call may end after the bound, which the 540 s default allows for.
#
# Remote machines.
# <label>/<name> names an agent on a Herdr machine other than this one, such as cloud/ticket-9, and takes @state and =path as above. A bare name stays local.
# The label must be in machines.conf (see machine-lib.sh) and must not be local. A label that is not, an empty label or name, and a name that holds another / are usage errors. run:<name> stays local only.
# One herdr --machine <label> agent list runs for each distinct label at each poll, and the local list runs only when a local name is given. State and pane are kept under the key <label>/<name>,
# so cloud/x and a local x are two agents.
# A remote list that fails (ssh, herdr, a machine that is not saved or not enabled) marks every agent named on that machine unreachable for that poll, and says why once on stderr after the output, so the first line stays "wake: ...". Only a failed local list exits 1.
# unreachable is not a change, and the agent keeps its baseline. A bare remote name that was unreachable at the first poll takes the first state it shows afterwards as its baseline,
# and so does one given as <label>/<name>@unreachable. If that later list does not hold the name, the call exits 1 as for an unknown bare name.
# A machine that was unreachable at every poll of the call is named once, in a line "machine <label> unreachable" after the agent lines.
# An agent line for a remote agent is "<label>/<name> <state> <pane id>", so the caller knows which --machine to pass to herdr. An unreachable agent shows "unreachable unreachable". A local line is as above.
# For <label>/<name>=<path> the path is on that machine, and the first 15 lines come from ssh <target> head -n 15 -- <path>, with the target from herdr machine list. The same header and lines are printed.
# A file that is not there gives the same one line as a local file. A remote file that cannot be read for another reason, or an ssh that fails, gives one line "--- <path> could not be read: <why>".
# A remote report path gets the refusals of check_remote_path in machine-lib.sh (with dirs) before the first poll, so a wake cannot print a private key or a token into a transcript.
# The shape, the names and the folders are judged first, with no ssh call. Then the machine says where the path resolves to (realpath -m, one ssh call for each path) and the same refusals apply to that path.
# A refused path exits 1 with one line, and nothing more goes to the machine. The report is read from the resolved path. A machine that cannot say gives the "could not be read" line, and the look is made again when the report is wanted.
# The poll interval is at least 20 s when any remote name is given, since each call opens an SSH session. A smaller --every is raised to 20, and one line on stderr after the output says so.
#
# The machine itself. Where the machine-self file beside machine-lib.sh names a label, as it does on a cloud machine that the tools were copied to, a name <that label>/<name>
# is an agent of this machine: its list is the plain herdr agent list, its report path is resolved (realpath -m) and read here with the same refusals, and no ssh call and
# no --machine is made for it. The key and the agent line keep the label, so a caller on that machine can pass back what a wake printed. --every is not raised for that label.
# A list that fails for it marks its names unreachable, as for a remote machine. A machine-self file that cannot be read, or names no label of the table, exits 1 with one line.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_LONG="${ORCH_WAKE_RUN_LONG:-$HERE/run-long.sh}"
BOUND=540
EVERY=10
REMOTE_EVERY=20
NAMES=()
RUNS=()
LABELS=()
NOTES=()
HAVE_LOCAL=0
declare -A REPORT BASELINE KEY_LABEL
declare -A CUR_STATUS CUR_PANE OLD_STATUS BASE PENDING
declare -A POLLS DOWN LOGGED TARGET WAKE_REAL
declare -A RUN_NOW RUN_CODE RUN_LOG
LIST=""
LIST_ERR=""
WAKE_WHY=""
SELF_LABEL=""

usage() {
  echo "usage: orch-wake.sh [--bound <seconds>] [--every <seconds>] [<agent>[@<state>][=<report path>] | run:<name>]..." >&2
  exit 1
}

# check_remote_path of machine-lib.sh ends the call through this, with one line on stderr.
die() {
  echo "remote: $1" >&2
  exit 1
}

# shellcheck disable=SC2329  # run by the EXIT trap below
cleanup() {
  rm -f "$LIST"
  [ "${#NOTES[@]}" -eq 0 ] || printf '%s\n' "${NOTES[@]}" >&2
}
trap cleanup EXIT
trap 'exit 130' INT TERM

whole_seconds() {
  [[ $1 =~ ^[0-9]+$ ]] && (("10#$1" >= 1))
}

# add_label <label>: remembers each remote label once, in the order given, and reads the machine table the first time.
add_label() {
  local l
  if [ "${#LABELS[@]}" -eq 0 ] && [ -z "${MACHINES_LOADED:-}" ]; then
    # shellcheck source=machine-lib.sh
    source "$HERE/machine-lib.sh"
    machines_load || {
      echo "orch-wake: $MACHINE_ERR" >&2
      exit 1
    }
    machine_self || {
      echo "orch-wake: $MACHINE_ERR" >&2
      exit 1
    }
    SELF_LABEL=$MACHINE_SELF
  fi
  for l in "${LABELS[@]}"; do
    [ "$l" != "$1" ] || return 0
  done
  LABELS+=("$1")
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bound)
      whole_seconds "${2:-}" || usage
      BOUND=$((10#$2))
      shift 2
      ;;
    --every)
      whole_seconds "${2:-}" || usage
      EVERY=$((10#$2))
      shift 2
      ;;
    -*) usage ;;
    run:*)
      [[ ${1#run:} =~ ^[A-Za-z0-9-]+$ ]] || usage
      RUNS+=("${1#run:}")
      shift
      ;;
    *)
      name="${1%%=*}"
      state=""
      if [[ $name == *@* ]]; then
        state="${name#*@}"
        name="${name%%@*}"
        [ -n "$name" ] && [ -n "$state" ] && [[ $state != *[[:space:]]* && $state != *@* ]] || usage
      fi
      [ -n "$name" ] || usage
      key="$name"
      if [[ $name == */* ]]; then
        label="${name%%/*}"
        short="${name#*/}"
        [ -n "$short" ] && [[ $short != */* ]] && [[ $label =~ ^[a-z0-9-]+$ ]] && [ "$label" != local ] || usage
        add_label "$label"
        machine_known "$label" || usage
        KEY_LABEL[$key]="$label"
      else
        HAVE_LOCAL=1
      fi
      # A caller that was told "unreachable" had no state to see, so it has no baseline either.
      if [ -n "$state" ] && [ "$state" != unreachable ]; then
        BASELINE[$key]="$state"
      fi
      if [[ $1 == *=* ]]; then
        [ -n "${1#*=}" ] || usage
        REPORT[$key]="${1#*=}"
      fi
      NAMES+=("$key")
      shift
      ;;
  esac
done
[ "${#NAMES[@]}" -gt 0 ] || [ "${#RUNS[@]}" -gt 0 ] || usage
[ "$BOUND" -lt 600 ] || {
  echo "orch-wake: --bound must be under 600, the Bash tool limit" >&2
  exit 1
}
other_label=0
for label in "${LABELS[@]}"; do
  [ "$label" = "$SELF_LABEL" ] || other_label=1
done
if [ "$other_label" -eq 1 ] && [ "$EVERY" -lt "$REMOTE_EVERY" ]; then
  NOTES+=("orch-wake: --every raised from $EVERY to $REMOTE_EVERY s, since a remote machine is named")
  EVERY=$REMOTE_EVERY
fi

# wake_check_path <label> <path>: looks where the machine resolves the report path to (realpath -m, so a link anywhere in it is followed) and applies every refusal of check_remote_path with dirs to that path.
# A refusal ends the call with exit 1 and one line. It sets WAKE_REAL[<label> <path>], which is the path to read, and returns 0. It returns 1 with WAKE_WHY set to one line when the machine cannot say (ssh, herdr machine list, no answer), and the caller reads nothing then.
# The ssh output is both streams, as in remote_head, and the answer is its last line, so a warning from ssh before it cannot become part of the path.
wake_check_path() {
  local label=$1 path=$2 key out real msg
  key="$label $path"
  [ -z "${WAKE_REAL[$key]:-}" ] || return 0
  # The machine itself resolves the path here, with no ssh.
  if [ "$label" = "$SELF_LABEL" ]; then
    real="$(realpath -m -- "$path" 2>/dev/null)"
    if [ -z "$real" ]; then
      WAKE_WHY="$path on $label has no resolved path"
      return 1
    fi
    msg=$(check_remote_path "$real" dirs 2>&1) || die "$path on $label resolves to a refused path: ${msg#remote: }"
    WAKE_REAL[$key]="$real"
    return 0
  fi
  if [ -z "${TARGET[$label]:-}" ]; then
    if ! machine_target "$label"; then
      WAKE_WHY="$MACHINE_ERR"
      return 1
    fi
    TARGET[$label]="$MACHINE_TARGET"
  fi
  machine_quote "$path"
  if ! out="$(machine_ssh "${TARGET[$label]}" "realpath -m -- $MACHINE_QUOTED 2>/dev/null; true" 2>&1)"; then
    WAKE_WHY="${out%%$'\n'*}"
    return 1
  fi
  real="${out##*$'\n'}"
  if [ -z "$real" ]; then
    WAKE_WHY="$path on $label has no resolved path"
    return 1
  fi
  msg=$(check_remote_path "$real" dirs 2>&1) || die "$path on $label resolves to a refused path: ${msg#remote: }"
  WAKE_REAL[$key]="$real"
}

# Every remote report path is refused or allowed before the first poll, and the shape and names are judged for all of them before any ssh call, so a refused path sends nothing to the machine.
for name in "${NAMES[@]}"; do
  [ -n "${KEY_LABEL[$name]:-}" ] && [ -n "${REPORT[$name]:-}" ] || continue
  check_remote_path "${REPORT[$name]}" dirs
done
for name in "${NAMES[@]}"; do
  [ -n "${KEY_LABEL[$name]:-}" ] && [ -n "${REPORT[$name]:-}" ] || continue
  wake_check_path "${KEY_LABEL[$name]}" "${REPORT[$name]}" || :
done

# Adds the agents of the herdr agent list output in $2 to CUR_STATUS and CUR_PANE, each key being the prefix in $1 and the agent's name.
# Objects in the array are separated by "},{"agent"", and the nested agent_session object never is.
RE_NAME=',"name":"([^"]*)"'
RE_STATUS=',"agent_status":"([^"]*)"'
RE_PANE=',"pane_id":"([^"]*)"'
parse_list() {
  local prefix=$1 text="${2//$'\r'/}" chunk name status pane
  text="${text//'},{"agent"'/$'\n'}"
  while IFS= read -r chunk; do
    [[ $chunk =~ $RE_NAME ]] || continue
    name="${BASH_REMATCH[1]}"
    status=unknown
    pane=unknown
    [[ $chunk =~ $RE_STATUS ]] && status="${BASH_REMATCH[1]}"
    [[ $chunk =~ $RE_PANE ]] && pane="${BASH_REMATCH[1]}"
    CUR_STATUS[$prefix$name]="$status"
    CUR_PANE[$prefix$name]="$pane"
  done <<<"$text"
}

# Runs herdr agent list (or herdr --machine <label> agent list for a label in $1) into the LIST file, reads it back with a built-in and parses it.
# Returns 1 with LIST_ERR set when herdr fails or the output has no agent list.
fetch_list() {
  local label=$1 out status=0 what="herdr agent list"
  if [ -n "$label" ] && [ "$label" != "$SELF_LABEL" ]; then
    what="herdr --machine $label agent list"
    herdr --machine "$label" agent list >"$LIST" 2>&1 || status=1
  else
    herdr agent list >"$LIST" 2>&1 || status=1
  fi
  IFS= read -r -d '' out <"$LIST"
  if [ "$status" -ne 0 ]; then
    LIST_ERR="$what failed: ${out%%$'\n'*}"
    return 1
  fi
  if [[ $out != *'"agents":['* ]]; then
    LIST_ERR="$what gave no agent list: ${out:0:200}"
    return 1
  fi
  parse_list "${label:+$label/}" "$out"
}

# Polls every machine that has a name: the local list when a local name is given (returns 1 when it fails), and each remote label once.
# A remote list that fails marks each name of that machine unreachable for this poll and goes on.
poll_agents() {
  local label key
  CUR_STATUS=()
  CUR_PANE=()
  if [ "$HAVE_LOCAL" -eq 1 ]; then
    fetch_list "" || {
      echo "orch-wake: $LIST_ERR" >&2
      return 1
    }
  fi
  for label in "${LABELS[@]}"; do
    POLLS[$label]=$((${POLLS[$label]:-0} + 1))
    if ! fetch_list "$label"; then
      DOWN[$label]=$((${DOWN[$label]:-0} + 1))
      if [ -z "${LOGGED[$label]:-}" ]; then
        LOGGED[$label]=1
        NOTES+=("orch-wake: $label is unreachable: $LIST_ERR")
      fi
      for key in "${NAMES[@]}"; do
        [ "${KEY_LABEL[$key]:-}" != "$label" ] || {
          CUR_STATUS[$key]=unreachable
          CUR_PANE[$key]=unreachable
        }
      done
    fi
  done
}

# Sets RUN_NOW (running, ended, lost or none), RUN_CODE and RUN_LOG for each run from run-long.sh status.
# Returns 1 when the status line is not one run-long.sh prints.
RE_RUN_ENDED='ended with code ([0-9]+), log (.*)$'
RE_RUN_LOST='stopped without an end line, log (.*)$'
poll_runs() {
  local r out
  for r in "${RUNS[@]}"; do
    out="$(bash "$RUN_LONG" status --name "$r" 2>&1)"
    RUN_CODE[$r]=""
    RUN_LOG[$r]=""
    if [[ $out =~ $RE_RUN_ENDED ]]; then
      RUN_NOW[$r]=ended
      RUN_CODE[$r]="${BASH_REMATCH[1]}"
      RUN_LOG[$r]="${BASH_REMATCH[2]}"
    elif [[ $out =~ $RE_RUN_LOST ]]; then
      RUN_NOW[$r]=lost
      RUN_LOG[$r]="${BASH_REMATCH[1]}"
    elif [[ $out == *" running, "* || $out == *" waiting for memory, "* ]]; then
      RUN_NOW[$r]=running
    elif [[ $out == *"waiting start is gone"* ]]; then
      RUN_NOW[$r]=lost
      RUN_LOG[$r]="${out##*, log }"
    elif [[ $out == *" no run" ]]; then
      RUN_NOW[$r]=none
    else
      echo "orch-wake: run-long.sh status gave: ${out%%$'\n'*}" >&2
      return 1
    fi
  done
}

# Polls the agents, if any are named, and then the runs.
poll_all() {
  [ "${#NAMES[@]}" -eq 0 ] || poll_agents || return 1
  poll_runs
}

if [ "${#NAMES[@]}" -gt 0 ]; then
  LIST="$(mktemp)" || {
    echo "orch-wake: mktemp failed" >&2
    exit 1
  }
fi
poll_all || exit 1

missing=0
for name in "${RUNS[@]}"; do
  if [ "${RUN_NOW[$name]}" = none ]; then
    echo "orch-wake: no run named $name" >&2
    missing=1
  fi
done
for name in "${NAMES[@]}"; do
  if [ -n "${BASELINE[$name]+set}" ]; then
    BASE[$name]="${BASELINE[$name]}"
  elif [ "${CUR_STATUS[$name]-}" = unreachable ]; then
    PENDING[$name]=1
  elif [ -z "${CUR_STATUS[$name]+set}" ]; then
    echo "orch-wake: no agent named $name" >&2
    missing=1
  else
    BASE[$name]="${CUR_STATUS[$name]}"
  fi
done
[ "$missing" -eq 0 ] || exit 1

# Sets changed and OLD_STATUS from the last poll against the baselines.
# An unreachable agent is no change and keeps its baseline. An agent with no baseline yet takes the first state it shows as one.
compare_snapshot() {
  local name now
  changed=()
  for name in "${NAMES[@]}"; do
    now="${CUR_STATUS[$name]-gone}"
    [ "$now" != unreachable ] || continue
    if [ -n "${PENDING[$name]+set}" ]; then
      if [ "$now" = gone ]; then
        echo "orch-wake: no agent named $name" >&2
        exit 1
      fi
      unset "PENDING[$name]"
      BASE[$name]="$now"
    elif [ "$now" != "${BASE[$name]}" ]; then
      changed+=("$name")
      OLD_STATUS[$name]="${BASE[$name]}"
    fi
  done
}

# Sets run_changed to the runs that are no longer running. The caller last saw each one running.
compare_runs() {
  run_changed=()
  for name in "${RUNS[@]}"; do
    [ "${RUN_NOW[$name]}" = running ] || run_changed+=("$name")
  done
}

wake=bound
changed=()
run_changed=()
compare_snapshot
compare_runs
if [ "${#changed[@]}" -gt 0 ] || [ "${#run_changed[@]}" -gt 0 ]; then
  wake=change
else
  while :; do
    left=$((BOUND - SECONDS))
    [ "$left" -ge 1 ] || break
    sleep "$((left < EVERY ? left : EVERY))"
    poll_all || exit 1
    compare_snapshot
    compare_runs
    if [ "${#changed[@]}" -gt 0 ] || [ "${#run_changed[@]}" -gt 0 ]; then
      wake=change
      break
    fi
  done
fi

echo "wake: $wake"
for name in "${NAMES[@]}"; do
  line="$name ${CUR_STATUS[$name]-gone} ${CUR_PANE[$name]-gone}"
  [ -n "${OLD_STATUS[$name]+set}" ] && line="$line (was ${OLD_STATUS[$name]})"
  echo "$line"
done
for label in "${LABELS[@]}"; do
  [ "${DOWN[$label]:-0}" -ne "${POLLS[$label]:-0}" ] || echo "machine $label unreachable"
done
for name in "${RUNS[@]}"; do
  case "${RUN_NOW[$name]}" in
    running) echo "run:$name running" ;;
    ended)
      echo "run:$name ended exit ${RUN_CODE[$name]} (was running)"
      if [ -r "${RUN_LOG[$name]}" ] && [ -f "${RUN_LOG[$name]}" ]; then
        tail -n 1 -- "${RUN_LOG[$name]}"
      else
        echo "run-long: end line not readable, the log is gone"
      fi
      echo "log ${RUN_LOG[$name]}"
      ;;
    *)
      echo "run:$name lost (was running)"
      echo "log ${RUN_LOG[$name]}"
      ;;
  esac
done

# remote_head <label> <path>: prints the report of a file on a remote machine in the form of a local one.
remote_head() {
  local label=$1 path=$2 out rc why
  # The look at the path was made before the first poll. It is made again here when it could not be then, and the file read is the path that the machine resolved it to.
  if ! wake_check_path "$label" "$path"; then
    echo "--- $path could not be read: ${WAKE_WHY:-no reason given}"
    return
  fi
  if [ "$label" = "$SELF_LABEL" ]; then
    local_head "$path" "${WAKE_REAL[$label $path]}"
    return
  fi
  machine_quote "${WAKE_REAL[$label $path]}"
  out="$(machine_ssh "${TARGET[$label]}" "LC_ALL=C head -n 15 -- $MACHINE_QUOTED" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "--- $path (first 15 lines)"
    printf '%s\n' "$out"
  elif [ "$rc" -ne 255 ] && [[ $out == *"No such file or directory"* ]]; then
    echo "--- $path does not exist yet"
  else
    why="${out%%$'\n'*}"
    echo "--- $path could not be read: ${why:-exit $rc}"
  fi
}

# local_head <path> <file>: prints the first 15 lines of a file on this machine under the header of the path given, or the does not exist yet line.
local_head() {
  if [ -r "$2" ] && [ -f "$2" ]; then
    mapfile -t -n 15 head_lines <"$2"
    echo "--- $1 (first 15 lines)"
    printf '%s\n' "${head_lines[@]}"
  else
    echo "--- $1 does not exist yet"
  fi
}

for name in "${changed[@]}"; do
  path="${REPORT[$name]-}"
  [ -n "$path" ] || continue
  if [ -n "${KEY_LABEL[$name]:-}" ]; then
    remote_head "${KEY_LABEL[$name]}" "$path"
  else
    local_head "$path" "$path"
  fi
done
exit 0
