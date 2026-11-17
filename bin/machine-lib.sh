#!/usr/bin/env bash
# machine-lib.sh: sourced by slots.sh, orch-wake.sh and run-long.sh. It holds the one parse of machines.conf and the one lookup of a machine's SSH target.
# It runs nothing when sourced and has no exit, so the script that sources it decides what a failure means. A function that fails returns 1 and sets MACHINE_ERR to one line.
# The table is MACHINES_CONF (default machines.conf beside this file). Each line is "<label> <authors> <reviewers> <floor GB>", and a # starts a comment.
# A label holds lower case letters, digits and hyphens only. The floor is a whole number or one decimal place, as slots.sh --floor takes it.
# local is the control machine's own Herdr server and is never passed to herdr as --machine.
# The SSH target of any other label comes from herdr machine list (tab separated: id, label, target, session, enabled), never from the table.
# A machine that is not enabled has no target, so a caller treats it as unreachable.
# Every SSH call is ssh -o BatchMode=yes -o ConnectTimeout=10 <target> <command>, through machine_ssh. No call passes a password, key or token.
# The ssh and herdr commands are whatever comes first on PATH, so a test can put fakes there.
# Functions:
#   machine_is_label <text>    true when the text is a well formed label
#   machines_load              reads the table once. Sets MACHINE_LABELS (in table order) and MACHINE_AUTHORS, MACHINE_REVIEWERS and MACHINE_FLOOR (tenths of a GB), each by label
#   machine_known <label>      true when the table lists the label
#   machine_self               sets MACHINE_SELF to the label of the machine this file runs on, or to "" on the control machine. See "The self label" below
#   machine_target <label>     sets MACHINE_TARGET to the SSH target of a saved, enabled machine, from herdr machine list
#   machine_ssh <target> <command text>   runs the command on the target with the options above. The text is one string, which the remote shell reads
#   machine_quote <text>       sets MACHINE_QUOTED to the text quoted for a remote shell: as it is when it holds only letters, digits and . _ / @ + = , : -, else in single quotes
#   check_remote_path <path> [dirs]   the refusals for a path on a remote machine (in_list and is_secret_part are its helpers). It ends the call through die <text>, which the sourcing script defines

#
# The self label. Whatever copies the tools to a cloud machine writes the file machine-self beside this file on that machine, holding the label alone,
# so a script that runs there (slots.sh) reads its own machine as itself, with no ssh. The control machine has no such file, so MACHINE_SELF is "" there.
# MACHINE_SELF_FILE names another file, for a test. A file that holds anything but one well formed label of the table, other than local, is an error,
# never a guess, since a wrong label would read another machine's limits.

MACHINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHINES_CONF="${MACHINES_CONF:-$MACHINE_LIB_DIR/machines.conf}"
MACHINE_SELF_FILE="${MACHINE_SELF_FILE:-$MACHINE_LIB_DIR/machine-self}"
MACHINE_SELF=""
MACHINE_LABELS=()
# -g, since a caller may source this file from inside a function, where a plain declare would make the tables local to that function.
declare -gA MACHINE_AUTHORS MACHINE_REVIEWERS MACHINE_FLOOR
MACHINES_LOADED=0
MACHINE_ERR=""
MACHINE_TARGET=""
MACHINE_QUOTED=""

machine_is_label() {
  [[ ${1:-} =~ ^[a-z0-9-]+$ ]]
}

machines_load() {
  local line label authors reviewers floor extra n=0
  [ "$MACHINES_LOADED" -eq 0 ] || return 0
  MACHINE_LABELS=()
  if [ ! -f "$MACHINES_CONF" ] || [ ! -r "$MACHINES_CONF" ]; then
    MACHINE_ERR="cannot read the machine table $MACHINES_CONF"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line//$'\r'/}"
    line="${line%%#*}"
    read -r label authors reviewers floor extra <<<"$line"
    [ -n "$label" ] || continue
    if ! machine_is_label "$label" || [[ ! $authors =~ ^[0-9]+$ ]] || [[ ! $reviewers =~ ^[0-9]+$ ]] || [[ ! $floor =~ ^([0-9]+)(\.([0-9]))?$ ]] || [ -n "$extra" ]; then
      MACHINE_ERR="$MACHINES_CONF line $n is not '<label> <authors> <reviewers> <floor GB>'"
      return 1
    fi
    if [ -n "${MACHINE_AUTHORS[$label]+set}" ]; then
      MACHINE_ERR="$MACHINES_CONF line $n repeats the label $label"
      return 1
    fi
    MACHINE_LABELS+=("$label")
    MACHINE_AUTHORS[$label]=$((10#$authors))
    # shellcheck disable=SC2034  # read by slots.sh, which sources this file
    MACHINE_REVIEWERS[$label]=$((10#$reviewers))
    # shellcheck disable=SC2034  # read by slots.sh, which sources this file
    MACHINE_FLOOR[$label]=$((10#${BASH_REMATCH[1]} * 10 + 10#${BASH_REMATCH[3]:-0}))
  done <"$MACHINES_CONF"
  if [ "${#MACHINE_LABELS[@]}" -eq 0 ]; then
    MACHINE_ERR="the machine table $MACHINES_CONF lists no machine"
    return 1
  fi
  MACHINES_LOADED=1
}

machine_known() {
  machines_load || return 1
  [ -n "${MACHINE_AUTHORS[${1:-}]+set}" ]
}

machine_self() {
  local line="" rest=""
  MACHINE_SELF=""
  [ -e "$MACHINE_SELF_FILE" ] || return 0
  if [ ! -f "$MACHINE_SELF_FILE" ] || [ ! -r "$MACHINE_SELF_FILE" ]; then
    MACHINE_ERR="cannot read $MACHINE_SELF_FILE"
    return 1
  fi
  { IFS= read -r line || [ -n "$line" ]; } <"$MACHINE_SELF_FILE"
  { IFS= read -r -d '' rest; } <"$MACHINE_SELF_FILE"
  line="${line//$'\r'/}"
  rest="${rest//$'\r'/}"
  rest="${rest%$'\n'}"
  if [ "$rest" != "$line" ] || ! machine_is_label "$line" || [ "$line" = local ]; then
    MACHINE_ERR="$MACHINE_SELF_FILE must hold one machine label other than local, and nothing else"
    return 1
  fi
  machines_load || return 1
  if [ -z "${MACHINE_AUTHORS[$line]+set}" ]; then
    MACHINE_ERR="$MACHINE_SELF_FILE names $line, which $MACHINES_CONF does not list"
    return 1
  fi
  # shellcheck disable=SC2034  # read by slots.sh, which sources this file
  MACHINE_SELF=$line
}

machine_target() {
  local label=${1:-} out id mlabel target session enabled found=0 sep=$'\x1f'
  MACHINE_TARGET=""
  if ! machine_is_label "$label" || [ "$label" = local ]; then
    MACHINE_ERR="$label is not a remote machine label"
    return 1
  fi
  if ! out="$(herdr machine list 2>&1)"; then
    MACHINE_ERR="herdr machine list failed: ${out%%$'\n'*}"
    return 1
  fi
  # A tab is white space to read, so two tabs in a row (an empty session column) would run together and shift the fields. Another separator keeps them.
  out="${out//$'\t'/$sep}"
  # shellcheck disable=SC2034  # id and session are columns of the list that are read only to keep the others in place
  while IFS=$sep read -r id mlabel target session enabled; do
    enabled="${enabled//$'\r'/}"
    [ "$mlabel" = "$label" ] || continue
    found=1
    case "${enabled,,}" in
      true | yes | enabled | on | 1) ;;
      *)
        MACHINE_ERR="machine $label is not enabled"
        return 1
        ;;
    esac
    # A target that starts with a hyphen would be read by ssh as an option, and one with a space is not one target.
    if [ -z "$target" ] || [[ $target == -* || $target == *[[:space:]]* ]]; then
      MACHINE_ERR="machine $label has no usable SSH target in herdr machine list"
      return 1
    fi
    # shellcheck disable=SC2034  # read by the scripts that source this file
    MACHINE_TARGET="$target"
    return 0
  done <<<"$out"
  # shellcheck disable=SC2034  # read by the scripts that source this file
  [ "$found" -eq 1 ] || MACHINE_ERR="machine $label is not in herdr machine list"
  return 1
}

machine_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$1" "$2"
}

machine_quote() {
  local s=$1
  if [[ $s =~ ^[A-Za-z0-9._/@+=,:-]+$ ]]; then
    MACHINE_QUOTED=$s
  else
    # Single quotes read the same in any login shell. A quote inside the text is closed, escaped and opened again.
    # shellcheck disable=SC2034  # read by the scripts that source this file
    MACHINE_QUOTED="'${s//\'/\'\\\'\'}'"
  fi
}

# The refusals for a path on a remote machine, so that a file copier and orch-wake.sh (a report path) apply the same ones.
# check_remote_path ends the call through die <text>, which the sourcing script defines. orch-wake.sh prints "remote: <text>" on stderr and exits 1.
# REMOTE_HOME is the home folder of the user on the remote machine. It defaults to this machine's HOME and every remote path must sit below it.
REMOTE_HOME="${REMOTE_HOME:-${HOME:-}}"
SECRET_PARTS=(.dev.vars .credentials.json .ssh .env .git-credentials .npmrc .netrc .claude.json)
# A fetch or a put refuses anything under these folders of the remote home, where reports and work folders never sit.
NEVER_UNDER=(.claude .config .ssh)

# in_list <word> <list words...>: true when the word is one of them.
in_list() {
  local w=$1 x
  shift
  for x in "$@"; do
    [ "$x" != "$w" ] || return 0
  done
  return 1
}

# is_secret_part <name>: true for a file or folder name that is never copied or written (SECRET_PARTS, and .env.<anything>).
is_secret_part() {
  in_list "$1" "${SECRET_PARTS[@]}" || [[ $1 == .env.* ]]
}

# check_remote_path <path> [dirs]: ends the call with one line when the path is not one a fetch, a put, a sampler or a wake may use.
# With "dirs" (a fetch, a put and the wake pass it) it also refuses a path under one of NEVER_UNDER, or that folder itself.
check_remote_path() {
  local p=$1 mode=${2:-} part dir
  [[ -n $REMOTE_HOME ]] || die "REMOTE_HOME is not set, so no remote path can be judged"
  # The shape of the path comes first, since a // or a . part would hide a folder from the name tests below.
  [[ $p == *//* ]] && die "the remote path $p has an empty part (a //)"
  [[ $p == */ ]] && die "the remote path $p has an empty part (a / at the end)"
  [[ $p =~ (^|/)\.(/|$) ]] && die "the remote path $p has a . part"
  [[ $p =~ (^|/)\.\.(/|$) ]] && die "the remote path $p has a .. part"
  [[ $p == "$REMOTE_HOME"/?* ]] || die "the remote path $p is not below $REMOTE_HOME/"
  [[ $p =~ ^[A-Za-z0-9._/@+=,-]+$ ]] || die "the remote path $p holds a character outside letters, digits and . _ / @ + = , -"
  local IFS=/
  for part in $p; do
    if is_secret_part "$part"; then
      die "the remote path $p has a part named $part, which is never copied"
    fi
  done
  if [ "$mode" = dirs ]; then
    for dir in "${NEVER_UNDER[@]}"; do
      if [[ $p == "$REMOTE_HOME/$dir" || $p == "$REMOTE_HOME/$dir"/* ]]; then
        die "the remote path $p is under $REMOTE_HOME/$dir, which is never copied"
      fi
    done
  fi
}
