#!/usr/bin/env bash
# slots.sh [--machine <label>|any] [--floor <GB>] [--authors <n>] [--reviewers <n>] author|reviewer
# Says whether an orchestrator may start one more agent of the role named. It reads free memory once and herdr agent list once, for each machine it asks.
# Each machine's limits and floor come from machines.conf, and --authors, --reviewers and --floor override them. A limit counts across every orchestrator on that machine.
# An agent holds a slot only while its agent_status is working or blocked. Idle, done and unknown hold none, though their memory is in the free figure.
# Only named agents count. An agent with no name is a person's own session and holds no slot.
# A name that starts dev-orchestrator or orch- is an orchestrator and holds no slot.
# A name that starts review- or ends -check is a reviewer. Every other named agent is an author. These rules apply to each machine's own list.
# Flags: --floor is the free memory floor in GB, a whole number or one decimal place (default 1.5). So .5, 2. and 1.50 are usage errors. --authors and --reviewers are the slot limits (default 2 and 1).
# Free memory of the control machine is the MemFree line of /proc/meminfo (Git Bash on Windows maps it to the free figure Windows reports). SLOTS_MEMINFO points at another file for a test.
# The herdr command is whatever comes first on PATH, so a test can put a fake one there. Sizes are whole megabytes inside the script.
# Output: "free: <x.xx> GB (floor <y.y> GB)", then "authors: <held> of <limit> held:" and "reviewers: <held> of <limit> held:" each followed by the holders as "name state" separated by commas.
# The last line is "verdict: start" or "verdict: wait (<reasons>)". The reasons are free memory under the floor, author slots full and reviewer slots full, joined by " and ".
# Exit 0 on start, 2 on wait. Exit 1 on a usage error, a failed or unreadable herdr agent list, or no free memory figure.
# It starts herdr, and ssh for a remote machine, and nothing else. The JSON is parsed with bash built-ins.
# The parse needs herdr's compact JSON with agent as the first key of each agent object. Pretty-printed output, or a key before agent, would merge two agents into one and undercount.
#
# Machines. With no --machine, every line, exit code and limit is as above, and neither machines.conf nor ssh is touched.
# --machine <label> reads that machine alone. The label must be in machines.conf (see machine-lib.sh), which holds each machine's authors, reviewers and floor, and a flag overrides them.
#   local is the control machine's own Herdr, read as above. Any other label is a saved Herdr machine: its agent list is herdr --machine <label> agent list,
#   and its memory is the MemAvailable line of ssh <target> cat /proc/meminfo (target from herdr machine list), since Linux keeps reclaimable cache out of MemFree.
#   The first line is then "free: <x.xx> GB available (floor <y.y> GB)". The rest is as above.
#   A machine that cannot be read (ssh fails, herdr fails, the machine is not enabled or not saved) is not a wait. Alone, it exits 1 with one line, "slots: <label> unreachable: <first line of the error>".
# --machine any asks local first, then each other label in table order, and stops at the first that says start. It prints "machine: <label>" and that machine's full block, and exits 0.
#   When no machine says start it prints one line for each, in that order, and exits 2: "<label>: verdict: <the verdict line without its prefix>", or "<label>: skipped, unreachable".
#   It exits 1 instead, with "slots: no machine answered" on stderr after the skipped lines, when every machine was unreachable.
#   A machine that was skipped before the one that started is named on stderr after the block, so the first line of stdout stays "machine: <label>". The reason a machine was skipped is not printed: ask it alone with --machine <label>.
#   Machines after the first start are not asked, so a local start costs no ssh.
# A flag applies to every machine it asks. --machine twice, a label that is not well formed and one that the table does not list are usage errors (exit 1).
#
# The machine itself. On a machine whose machine-self file (see machine-lib.sh) names a label, such as a cloud machine:
#   --machine <that label> reads that machine as this one: the MemAvailable line of /proc/meminfo (SLOTS_MEMINFO for a test) and the plain herdr agent list, with no ssh.
#   Its first line is "free: <x.xx> GB available (floor <y.y> GB)", as for a remote machine. The limits are that label's line of machines.conf.
#   No --machine means --machine <that label>. --machine any asks that label alone, in the output form of any.
#   --machine local is an error there (exit 1), since local is the control machine, which that machine cannot read. A machine-self file that cannot be read,
#   or that names no label of the table, is an error (exit 1), never a guess. The control machine has no machine-self file, so nothing above changes there.
#
# Owners and claims: the sub-orchestrators on one machine share its slots with no central grant. On the machine itself only:
#   --owner <name> names the orchestrator asking: orch-<slug>, orch-<slug>-<n>, dev-orchestrator or dev-orchestrator-<n>.
#     Its slug is the name without orch- and without one trailing -<digits>, so a successor is the same owner as its predecessor.
#   --take <agent name> (only with --owner) asks for one slot for the agent about to start, and on "verdict: start" records a claim for it.
#   The share: an owner may hold ceil(limit / owners) of each role, where the owners are the distinct slugs of the orch-* agents in the list (any state)
#     and the asker's own. Two owners and 6 authors give 3 each, three give 2. No owner borrows an idle owner's share. The machine's limits and floor still bind.
#     A full share adds the reason "owner share full (<held> of <share>)". With --owner a line "owner: <slug> holds <held> of <share> <role>s, <n> owners" comes before the verdict.
#   A claim is the file <locks>/slots-claims/<agent name> (the folder is $ORCH_HOME/locks, or SLOTS_LOCKS for a test), holding owner=<slug> and since=<epoch seconds>.
#     It counts toward its owner while its agent is listed working or blocked, and for 300 s after it was made whatever the list says of its agent:
#     not listed yet, or listed idle, done or unknown, since a new agent shows idle before its brief arrives. So a start in flight holds its slot.
#     Such an agent counts toward the machine's limit too, shown as "<name> starting". After 300 s a claim whose agent is listed in another state holds nothing,
#     and a claim whose agent is not in the list is removed by the next --take. An agent with no claim counts toward the machine's limit only.
#     A since that is not a whole number reads as 0, so its text is never run as arithmetic.
#   --take reads, decides and writes its claim under a flock on <locks>/slots.lock, waiting at most 30 s, so two takes at once never both get the last slot.
#     That file is only ever a flock target and stays empty. herdr is started with that descriptor closed, so nothing it leaves behind holds the flock.
#     On start the call prints "slots: claimed <name> for <slug>" on stderr after the block.
#     The claim is written to a temporary file and moved into place, so a reader never sees half a claim.
#   --take refuses with exit 1 a name already in the list and an orchestrator's name. --owner or --take where there is no machine-self file (the control machine),
#     or with a --machine label other than the machine itself, is an error (exit 1), since the claims live on that machine.
#
# A reviewer in its own copy may work while its author works. Each holds its own slot by its own state, as above.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMINFO="${SLOTS_MEMINFO:-/proc/meminfo}"
FLOOR_TENTHS=15
AUTHOR_LIMIT=2
REVIEWER_LIMIT=1
FLOOR_FLAG=""
AUTHORS_FLAG=""
REVIEWERS_FLAG=""
MACHINE=""
ROLE=""
OWNER=""
TAKE=""
TAKE_FD=""
ORCH_HOME="${ORCH_HOME:-$(cd "$HERE/.." && pwd)}"
LOCKS="${SLOTS_LOCKS:-$ORCH_HOME/locks}"
CLAIMS="$LOCKS/slots-claims"
CLAIM_TTL=300
declare -A LISTED ORCH_SLUGS
STALE_CLAIMS=()
OWNER_SLUG=""
OWNER_HELD=0
SHARE=0

usage() {
  echo "usage: slots.sh [--machine <label>|any] [--floor <GB>] [--authors <n>] [--reviewers <n>] [--owner <orch name> [--take <agent name>]] author|reviewer" >&2
  exit 1
}

fail() {
  echo "slots: $1" >&2
  exit 1
}

whole_number() {
  [[ $1 =~ ^[0-9]+$ ]]
}

while [ $# -gt 0 ]; do
  case "$1" in
    --machine)
      [ -z "$MACHINE" ] || usage
      [[ ${2:-} =~ ^[a-z0-9-]+$ ]] || usage
      MACHINE="$2"
      shift 2
      ;;
    --floor)
      [[ ${2:-} =~ ^([0-9]+)(\.([0-9]))?$ ]] || usage
      FLOOR_TENTHS=$((10#${BASH_REMATCH[1]} * 10 + 10#${BASH_REMATCH[3]:-0}))
      FLOOR_FLAG=$FLOOR_TENTHS
      shift 2
      ;;
    --authors)
      whole_number "${2:-}" || usage
      AUTHOR_LIMIT=$((10#$2))
      AUTHORS_FLAG=$AUTHOR_LIMIT
      shift 2
      ;;
    --reviewers)
      whole_number "${2:-}" || usage
      REVIEWER_LIMIT=$((10#$2))
      REVIEWERS_FLAG=$REVIEWER_LIMIT
      shift 2
      ;;
    --owner)
      [ -z "$OWNER" ] || usage
      [[ ${2:-} =~ ^(orch-[a-z0-9]+(-[a-z0-9]+)*|dev-orchestrator(-[0-9]+)?)$ ]] || usage
      OWNER="$2"
      shift 2
      ;;
    --take)
      [ -z "$TAKE" ] || usage
      [[ ${2:-} =~ ^[A-Za-z0-9._-]+$ ]] || usage
      TAKE="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$ROLE" ] || usage
      ROLE="$1"
      shift
      ;;
  esac
done
case "$ROLE" in
  author | reviewer) ;;
  *) usage ;;
esac
[ -z "$TAKE" ] || [ -n "$OWNER" ] || usage
if [[ $TAKE == dev-orchestrator* || $TAKE == orch-* ]]; then
  fail "--take $TAKE is an orchestrator's name, and an orchestrator holds no slot"
fi

# Sets FREE_MB from the line of the meminfo text in $2 that starts with the key in $1 (MemFree or MemAvailable). Fails when there is no number there.
free_from() {
  local key value rest found=""
  while read -r key value rest; do
    if [ "$key" = "$1:" ]; then
      found="$value"
      break
    fi
  done <<<"$2"
  whole_number "$found" || return 1
  FREE_MB=$((10#$found / 1024))
}

# slug_of <orchestrator name>: sets SLUG to the name without orch- and without one trailing -<digits>, so orch-court-bundler-15 and orch-court-bundler are court-bundler.
slug_of() {
  SLUG=${1#orch-}
  [[ $SLUG =~ ^(.+)-[0-9]+$ ]] && SLUG=${BASH_REMATCH[1]}
}

# is_reviewer <name>: the name rule for a reviewer.
is_reviewer() {
  [[ $1 == review-* || $1 == *-check ]]
}

# Sets HELD_AUTHORS, HELD_REVIEWERS, N_AUTHORS and N_REVIEWERS from the herdr agent list output in $1.
# Also sets LISTED (each named agent's state, any state) and ORCH_SLUGS (the slug of each orch-* agent), which the owners and claims read.
# Objects in the array are separated by "},{"agent"", and the nested agent_session object never is.
RE_NAME=',"name":"([^"]*)"'
RE_STATUS=',"agent_status":"([^"]*)"'
parse_list() {
  local text="${1//$'\r'/}" chunk name status
  HELD_AUTHORS=""
  HELD_REVIEWERS=""
  N_AUTHORS=0
  N_REVIEWERS=0
  LISTED=()
  ORCH_SLUGS=()
  text="${text//'},{"agent"'/$'\n'}"
  while IFS= read -r chunk; do
    [[ $chunk =~ $RE_NAME ]] || continue
    name="${BASH_REMATCH[1]}"
    [ -n "$name" ] || continue
    status=unknown
    [[ $chunk =~ $RE_STATUS ]] && status="${BASH_REMATCH[1]}"
    LISTED[$name]=$status
    if [[ $name == orch-* ]]; then
      slug_of "$name"
      ORCH_SLUGS[$SLUG]=1
    fi
    case "$status" in
      working | blocked) ;;
      *) continue ;;
    esac
    if [[ $name == dev-orchestrator* || $name == orch-* ]]; then
      continue
    elif is_reviewer "$name"; then
      N_REVIEWERS=$((N_REVIEWERS + 1))
      HELD_REVIEWERS="${HELD_REVIEWERS:+$HELD_REVIEWERS, }$name $status"
    else
      N_AUTHORS=$((N_AUTHORS + 1))
      HELD_AUTHORS="${HELD_AUTHORS:+$HELD_AUTHORS, }$name $status"
    fi
  done <<<"$text"
}

# self_list: the plain herdr agent list. During a --take the descriptor of the flock is closed for herdr, which bash does not do on its own,
# so a process herdr leaves running never holds locks/slots.lock.
self_list() {
  if [ -n "${TAKE_FD:-}" ]; then
    herdr agent list {TAKE_FD}>&-
  else
    herdr agent list
  fi
}

# check_machine <label>: reads one machine with the limits in AUTHOR_LIMIT, REVIEWER_LIMIT and FLOOR_TENTHS.
# An empty label is the call with no --machine, and local is the same read. Any other label is a remote machine.
# Sets CM_BLOCK (the four lines) , CM_VERDICT (the text after "verdict: ") and CM_RC (0 start, 2 wait), and returns 0.
# Returns 1 with ERR set to one line when the machine cannot be read.
check_machine() {
  local label=$1 target mem list unit="" text reasons="" floor_mb free_centi free_text
  ERR=""
  if [ -n "$label" ] && [ "$label" = "${MACHINE_SELF:-}" ]; then
    # The machine itself: its own meminfo and its own herdr, with no ssh, and MemAvailable as for any Linux machine.
    unit=' available'
    if ! { [ -f "$MEMINFO" ] && [ -r "$MEMINFO" ]; }; then
      ERR="cannot read $MEMINFO"
      return 1
    fi
    IFS= read -r -d '' mem <"$MEMINFO"
    free_from MemAvailable "$mem" || {
      ERR="no MemAvailable figure in $MEMINFO"
      return 1
    }
    if ! list="$(self_list 2>&1)"; then
      ERR="herdr agent list failed: ${list%%$'\n'*}"
      return 1
    fi
  elif [ -z "$label" ] || [ "$label" = local ]; then
    if ! { [ -f "$MEMINFO" ] && [ -r "$MEMINFO" ]; }; then
      ERR="cannot read $MEMINFO"
      return 1
    fi
    IFS= read -r -d '' mem <"$MEMINFO"
    free_from MemFree "$mem" || {
      ERR="no MemFree figure in $MEMINFO"
      return 1
    }
    if ! list="$(herdr agent list 2>&1)"; then
      ERR="herdr agent list failed: ${list%%$'\n'*}"
      return 1
    fi
  else
    unit=" available"
    machine_target "$label" || {
      ERR=$MACHINE_ERR
      return 1
    }
    target=$MACHINE_TARGET
    if ! mem="$(machine_ssh "$target" "cat /proc/meminfo" 2>&1)"; then
      ERR="${mem%%$'\n'*}"
      return 1
    fi
    free_from MemAvailable "$mem" || {
      ERR="no MemAvailable figure in the meminfo of $label"
      return 1
    }
    if ! list="$(herdr --machine "$label" agent list 2>&1)"; then
      ERR="${list%%$'\n'*}"
      return 1
    fi
  fi
  if [[ $list != *'"agents":['* ]]; then
    ERR="herdr agent list gave no agent list: ${list:0:200}"
    return 1
  fi
  parse_list "$list"
  [ -z "$OWNER" ] || owner_apply

  floor_mb=$((FLOOR_TENTHS * 1024 / 10))
  free_centi=$((FREE_MB * 100 / 1024))
  printf -v free_text '%d.%02d' $((free_centi / 100)) $((free_centi % 100))
  [ "$FREE_MB" -ge "$floor_mb" ] || reasons="free memory under the floor"
  if [ "$ROLE" = author ]; then
    [ "$N_AUTHORS" -lt "$AUTHOR_LIMIT" ] || reasons="${reasons:+$reasons and }author slots full"
  else
    [ "$N_REVIEWERS" -lt "$REVIEWER_LIMIT" ] || reasons="${reasons:+$reasons and }reviewer slots full"
  fi
  if [ -n "$OWNER" ] && [ "$OWNER_HELD" -ge "$SHARE" ]; then
    reasons="${reasons:+$reasons and }owner share full ($OWNER_HELD of $SHARE)"
  fi
  if [ -z "$reasons" ]; then
    CM_VERDICT="start"
    CM_RC=0
  else
    CM_VERDICT="wait ($reasons)"
    CM_RC=2
  fi
  text="free: $free_text GB$unit (floor $((FLOOR_TENTHS / 10)).$((FLOOR_TENTHS % 10)) GB)"
  text="$text"$'\n'"authors: $N_AUTHORS of $AUTHOR_LIMIT held:${HELD_AUTHORS:+ $HELD_AUTHORS}"
  text="$text"$'\n'"reviewers: $N_REVIEWERS of $REVIEWER_LIMIT held:${HELD_REVIEWERS:+ $HELD_REVIEWERS}"
  [ -z "$OWNER" ] || text="$text"$'\n'"owner: $OWNER_SLUG holds $OWNER_HELD of $SHARE ${ROLE}s, $OWNER_COUNT owners"
  CM_BLOCK="$text"$'\n'"verdict: $CM_VERDICT"
}

# owner_apply: with --owner, reads the claims (see "Owners and claims" above). Adds each claim in flight to N_AUTHORS or N_REVIEWERS and the held list,
# sets OWNER_SLUG, OWNER_COUNT, OWNER_HELD (the asker's claims of ROLE that hold a slot) and SHARE, and lists in STALE_CLAIMS the claims a --take removes.
# It reads the claim files with bash built-ins only. Claims in flight are added after the list's own, since the list did not count their agents.
owner_apply() {
  local f name owner since key value now limit state
  printf -v now '%(%s)T' -1
  OWNER_HELD=0
  STALE_CLAIMS=()
  slug_of "$OWNER"
  OWNER_SLUG=$SLUG
  ORCH_SLUGS[$OWNER_SLUG]=1
  OWNER_COUNT=${#ORCH_SLUGS[@]}
  for f in "$CLAIMS"/*; do
    [ -f "$f" ] || continue
    name=${f##*/}
    # A take of a name that already has a claim (a retry of the same start) takes that claim's place, so the old one is not counted.
    [ "$name" != "$TAKE" ] || continue
    owner=""
    since=""
    while IFS='=' read -r key value; do
      case $key in
        owner) owner=$value ;;
        since) since=$value ;;
      esac
    done <"$f"
    [[ $since =~ ^[0-9]+$ ]] || since=0
    state=${LISTED[$name]-}
    if [ "$state" = working ] || [ "$state" = blocked ]; then
      # Listed working or blocked: the list has already counted it on the machine.
      :
    elif [ $((now - since)) -lt "$CLAIM_TTL" ]; then
      # In flight: started, or about to be, and not listed yet, or listed in another state, since a new agent shows idle before its brief arrives.
      if is_reviewer "$name"; then
        N_REVIEWERS=$((N_REVIEWERS + 1))
        HELD_REVIEWERS="${HELD_REVIEWERS:+$HELD_REVIEWERS, }$name starting"
      else
        N_AUTHORS=$((N_AUTHORS + 1))
        HELD_AUTHORS="${HELD_AUTHORS:+$HELD_AUTHORS, }$name starting"
      fi
    elif [ -n "$state" ]; then
      # Older, and listed in another state: it holds nothing, and it stays while its agent is listed.
      continue
    else
      STALE_CLAIMS+=("$f")
      continue
    fi
    [ "$owner" = "$OWNER_SLUG" ] || continue
    if is_reviewer "$name"; then
      [ "$ROLE" = reviewer ] && OWNER_HELD=$((OWNER_HELD + 1))
    else
      [ "$ROLE" = author ] && OWNER_HELD=$((OWNER_HELD + 1))
    fi
  done
  if [ "$ROLE" = author ]; then
    limit=$AUTHOR_LIMIT
  else
    limit=$REVIEWER_LIMIT
  fi
  SHARE=$(((limit + OWNER_COUNT - 1) / OWNER_COUNT))
}

# take_lock: with --take, holds a flock on locks/slots.lock for the rest of this call, so a second take waits until this one has written its claim.
take_lock() {
  [ -n "$TAKE" ] || return 0
  mkdir -p -- "$CLAIMS" 2>/dev/null || fail "cannot make $CLAIMS"
  exec {TAKE_FD}>>"$LOCKS/slots.lock" || fail "cannot open $LOCKS/slots.lock"
  flock -w 30 "$TAKE_FD" || fail "could not take the flock on $LOCKS/slots.lock within 30 s"
}

# take_finish <label>: with --take, after check_machine of the machine itself. Refuses a name already in the list, removes the stale claims,
# and on start writes the claim, by a temporary file moved into place, so a reader never sees half a claim.
take_finish() {
  local now tmp
  [ -n "$TAKE" ] || return 0
  [ -z "${LISTED[$TAKE]+set}" ] || fail "$TAKE is already an agent on $1, so it needs no new slot"
  [ "${#STALE_CLAIMS[@]}" -eq 0 ] || rm -f -- "${STALE_CLAIMS[@]}"
  [ "$CM_RC" -eq 0 ] || return 0
  printf -v now '%(%s)T' -1
  tmp="${CLAIMS:?}/.$TAKE.$$"
  if ! { printf 'owner=%s\nsince=%s\n' "$OWNER_SLUG" "$now" >"$tmp" && mv -f -- "$tmp" "${CLAIMS:?}/$TAKE"; }; then
    rm -f -- "$tmp"
    fail "could not write the claim ${CLAIMS:?}/$TAKE"
  fi
  CLAIMED="slots: claimed $TAKE for $OWNER_SLUG"
}

# use_limits <label>: sets the limits of that machine from the table, and then the flags over them.
use_limits() {
  AUTHOR_LIMIT=${AUTHORS_FLAG:-${MACHINE_AUTHORS[$1]}}
  REVIEWER_LIMIT=${REVIEWERS_FLAG:-${MACHINE_REVIEWERS[$1]}}
  FLOOR_TENTHS=${FLOOR_FLAG:-${MACHINE_FLOOR[$1]}}
}

# The control machine: no --machine and no machine-self file is the plain read, which touches neither the table nor ssh.
if [ -z "$MACHINE" ] && [ ! -e "${MACHINE_SELF_FILE:-$HERE/machine-self}" ]; then
  [ -z "$OWNER" ] || fail "--owner and --take work only on the machine itself, whose machine-self file names it, since the claims live there"
  check_machine "" || fail "$ERR"
  echo "$CM_BLOCK"
  exit "$CM_RC"
fi

# shellcheck source=machine-lib.sh
source "$HERE/machine-lib.sh"
machines_load || fail "$MACHINE_ERR"
machine_self || fail "$MACHINE_ERR"
[ -n "$MACHINE" ] || MACHINE=$MACHINE_SELF
if [ -n "$MACHINE_SELF" ] && [ "$MACHINE" = local ]; then
  fail "local is the control machine, which $MACHINE_SELF cannot read, so ask --machine $MACHINE_SELF"
fi
if [ -n "$OWNER" ] && { [ -z "$MACHINE_SELF" ] || { [ "$MACHINE" != any ] && [ "$MACHINE" != "$MACHINE_SELF" ]; }; }; then
  fail "--owner and --take work only on the machine itself, whose machine-self file names it, since the claims live there"
fi
CLAIMED=""

if [ "$MACHINE" != any ]; then
  machine_known "$MACHINE" || fail "unknown machine $MACHINE (it is not in $MACHINES_CONF)"
  use_limits "$MACHINE"
  take_lock
  if ! check_machine "$MACHINE"; then
    echo "slots: $MACHINE unreachable: ${ERR%%$'\n'*}" >&2
    exit 1
  fi
  take_finish "$MACHINE"
  echo "$CM_BLOCK"
  [ -z "$CLAIMED" ] || echo "$CLAIMED" >&2
  exit "$CM_RC"
fi

# any: on the machine itself, that machine alone. Elsewhere local first when the table has it, then every other label in table order.
order=()
if [ -n "$MACHINE_SELF" ]; then
  order=("$MACHINE_SELF")
else
  for label in "${MACHINE_LABELS[@]}"; do
    [ "$label" != local ] || order+=("$label")
  done
  for label in "${MACHINE_LABELS[@]}"; do
    [ "$label" = local ] || order+=("$label")
  done
fi
take_lock
lines=()
skipped=()
answered=0
for label in "${order[@]}"; do
  use_limits "$label"
  if ! check_machine "$label"; then
    lines+=("$label: skipped, unreachable")
    skipped+=("$label: skipped, unreachable")
    continue
  fi
  answered=1
  take_finish "$label"
  if [ "$CM_RC" -eq 0 ]; then
    echo "machine: $label"
    echo "$CM_BLOCK"
    [ "${#skipped[@]}" -eq 0 ] || printf '%s\n' "${skipped[@]}" >&2
    [ -z "$CLAIMED" ] || echo "$CLAIMED" >&2
    exit 0
  fi
  lines+=("$label: verdict: $CM_VERDICT")
done
printf '%s\n' "${lines[@]}"
if [ "$answered" -eq 0 ]; then
  echo "slots: no machine answered" >&2
  exit 1
fi
exit 2
