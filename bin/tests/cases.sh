#!/usr/bin/env bash
# cases.sh: the one runner of named cases for every bin/tests/*.test.sh. A test sources it and holds no counters, filter, list or limit of its own.
# Written for Git Bash, and it also runs on Linux: a case that runs past its limit is stopped by the ids of its processes, and taskkill is used only where it exists.
# A test uses it so:
#   source "$HERE/cases.sh"
#   CASE_NAMES=(first second third)       the case names, in the order they run. Each has a function case_<name>.
#   cases_init "$@"                       first, before any setup. It answers --list, rejects other arguments and unknown names in CASES.
#   ...setup, helpers, the case_<name> functions...
#   cases_run                             the last command. It runs the chosen cases and prints the counts line, and its status is the test's exit status.
# CASES is a list of exact case names separated by spaces or tabs. Unset or empty runs every case in order.
# A list runs those cases in the order given, each once. An unknown name prints one line naming it and exits 2, and no case runs.
# <test> --list prints the case names one per line and runs none. Any other argument is a usage error, exit 2.
# Each case runs in a subshell of its own, so a case that calls exit or is killed fails alone and the run goes on. A case cannot change another case's variables.
# A case fails when it ends with a reason in the array WHY, when it ends without finishing (exit, signal) or when it passes its limit.
# need <label> <command> [args]... adds <label> to WHY when the command fails. A case may also add to WHY by hand.
# CASES_CURRENT holds the name of the case under way, from before cases_before until the case ends.
# Two optional functions the test may define: cases_before runs in the case's subshell before each case, and cases_detail prints one line
# that is added to the reason of a failing case, for state that helps to read the failure (an exit status, captured output).
# The limit: each case has a limit in whole seconds, read from the clock ($SECONDS), never counted in sleeps.
#   The default is CASES_DEFAULT_LIMIT below. A test may set that variable itself before it sources this file.
#   A case raises its own limit with one call at its start: cases_limit <seconds>.
#   CASES_LIMIT in the environment sets the limit of every case for the whole run, and cases_limit then has no effect. It is a whole number of seconds, or the run is a usage error.
#   A case past its limit is stopped with its whole process tree and counts as FAIL <name> (timed out after <n> s).
#   The tree is found by the parent ids in /proc (the ppid file on Git Bash, the stat file on Linux), and each process in it is stopped by its own id (kill -9, then taskkill /PID <Windows id> /T /F). Nothing is stopped by name.
#   A process a case double-forks, such as a daemon started with ( cmd & ), escapes the stop, since its parent id no longer leads to the case. A case that starts a daemon stops it itself.
# Output, one line per case, in the order run, then the counts line:
#   PASS <name>
#   PASS <name> (skipped: <reason>)   a case that called cases_skip <reason> because it cannot run here, and counts as passed
#   FAIL <name> (<reason>)      the reasons from WHY joined by a comma, then the detail line, with newlines turned into " | "
#   passed <n> failed <n>
# After a FAIL line the last 20 lines the case printed follow, each indented by two spaces. They are not result lines.
# Exit 0 only when every case run passed, 1 when any failed or the runner could not make its folder, 2 on a usage error.
# CASES_TIMES=1 prints "time <name> <n> s" to stderr after each case, for measuring a limit.
# A test with an EXIT trap calls cases_stop in it, so a case still running when the test is stopped does not outlive it.
# The runner waits on a fifo in its folder, which it opens once on a descriptor (CASES_NAPFD) in cases_run and closes in cases_stop. A case does not inherit the descriptor.

# 800 s is a generous default for a case that keeps it. A slower case raises its own limit with cases_limit.
CASES_DEFAULT_LIMIT=${CASES_DEFAULT_LIMIT:-800}
CASES_DIR=""
CASES_PID=""
CASES_NAP=""
CASES_NAPFD=""
CASES_PASSED=0
CASES_FAILED=0
CASES_TODO=()
WHY=()

# Reads CASES and the argument list. Exits at once for --list, a usage error or an unknown name.
cases_init() {
  local words=() word name known todo=" " bad=0
  if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = --list ]; then
      printf '%s\n' "${CASE_NAMES[@]}"
      exit 0
    fi
    echo "usage: ${0##*/} [--list]" >&2
    exit 2
  fi
  if ! [[ ${CASES_LIMIT:-1} =~ ^[1-9][0-9]*$ ]]; then
    echo "${0##*/}: CASES_LIMIT must be a whole number of seconds above 0, not '$CASES_LIMIT'" >&2
    exit 2
  fi
  IFS=$' \t\n' read -r -d '' -a words <<<"${CASES:-}"
  for word in "${words[@]}"; do
    known=0
    for name in "${CASE_NAMES[@]}"; do
      [ "$name" = "$word" ] && known=1
    done
    if [ "$known" -eq 0 ]; then
      echo "${0##*/}: no case named $word" >&2
      bad=1
    elif [[ $todo != *" $word "* ]]; then
      todo+="$word "
      CASES_TODO+=("$word")
    fi
  done
  [ "$bad" -eq 0 ] || exit 2
  [ "${#CASES_TODO[@]}" -gt 0 ] || CASES_TODO=("${CASE_NAMES[@]}")
}

# A case calls this once at its start to raise its own limit.
cases_limit() {
  case ${1:-} in
    '' | *[!0-9]* | 0*)
      echo "cases_limit: want a whole number of seconds above 0, got '${1:-}'" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$1" >"${CASES_DIR:?}/limit"
}

need() {
  "${@:2}" || WHY+=("$1")
}

# A case that cannot run here (a tool is missing) calls this with the reason and returns. It passes, and its line says it proved nothing.
cases_skip() {
  printf '%s\n' "$*" >"${CASES_DIR:?}/skip"
}

# Waits a fifth of a second with no process started, from the clock's point of view a nap.
cases__nap() {
  if [ -n "$CASES_NAPFD" ]; then
    # The fifo is opened once per runner, for reading and writing, so it never reaches end of file and read waits for its timeout.
    read -r -t 0.2 -u "$CASES_NAPFD" _ || true
  elif [ -p "$CASES_NAP" ]; then
    # A runner that sets CASES_NAP without opening it (mutant-run.sh) opens it on every nap.
    read -r -t 0.2 _ <>"$CASES_NAP" || true
  else
    sleep 0.2
  fi
}

# Prints the id of a process and of every process below it, found by the parent ids in /proc.
# Windows does not keep the same parent links (a child of a Git Bash subshell can name another process as its parent), so taskkill /T alone misses children.
cases__tree() {
  local -A kids=()
  local f id parent line todo=("$1") i=0
  for f in /proc/[0-9]*; do
    id=${f#/proc/}
    if [ -r "$f/ppid" ]; then
      { read -r parent <"$f/ppid"; } 2>/dev/null || continue
    else
      # Linux has no ppid file. The parent id is the second word after the last ")" in stat, since the process name before it may hold spaces.
      { read -r line <"$f/stat"; } 2>/dev/null || continue
      line=${line##*) }
      read -r _ parent _ <<<"$line"
    fi
    kids[$parent]+="$id "
  done
  while [ "$i" -lt "${#todo[@]}" ]; do
    echo "${todo[$i]}"
    # shellcheck disable=SC2206  # the ids hold digits only
    todo+=(${kids[${todo[$i]}]:-})
    i=$((i + 1))
  done
}

# Stops the process tree of the case under way, by the ids of its own processes. Never by name.
cases__kill_tree() {
  local ids=() id win wins=() i
  mapfile -t ids < <(cases__tree "$1")
  for id in "${ids[@]}"; do
    win=""
    [ ! -r "/proc/$id/winpid" ] || read -r win <"/proc/$id/winpid"
    [ -z "$win" ] || wins+=(/PID "$win")
  done
  kill -9 "${ids[@]}" 2>/dev/null
  if [ "${#wins[@]}" -gt 0 ] && command -v taskkill >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 taskkill "${wins[@]}" /T /F >/dev/null 2>&1
  fi
  for ((i = 0; i < 25; i++)); do
    kill -0 "$1" 2>/dev/null || break
    cases__nap
  done
}

# For the test's own EXIT trap.
cases_stop() {
  [ -z "$CASES_PID" ] || cases__kill_tree "$CASES_PID"
  CASES_PID=""
  if [ -n "$CASES_NAPFD" ]; then
    exec {CASES_NAPFD}>&-
    CASES_NAPFD=""
  fi
  [ -z "$CASES_DIR" ] || rm -rf "$CASES_DIR"
  CASES_DIR=""
}

# The body of one case, run in a subshell. It writes its result file only when the case function returns.
cases__body() {
  local text detail=""
  # shellcheck disable=SC2034  # read by the test's own functions
  CASES_CURRENT=$1
  WHY=()
  if declare -F cases_before >/dev/null; then cases_before; fi
  "case_$1"
  if [ "${#WHY[@]}" -eq 0 ]; then
    if [ -s "${CASES_DIR:?}/skip" ]; then
      read -r text <"$CASES_DIR/skip"
      echo "ok skipped: $text" >"$CASES_DIR/result"
    else
      echo ok >"$CASES_DIR/result"
    fi
    return
  fi
  text=$(printf '%s, ' "${WHY[@]}")
  text=${text%, }
  if declare -F cases_detail >/dev/null; then detail=$(cases_detail 2>&1); fi
  [ -z "$detail" ] || text="$text, $detail"
  printf 'fail %s\n' "${text//$'\n'/ | }" >"${CASES_DIR:?}/result"
}

# The limit in force now: CASES_LIMIT, else what the case asked for, else the default.
cases__limit_now() {
  local asked=""
  if [ -n "${CASES_LIMIT:-}" ]; then
    echo "$CASES_LIMIT"
    return
  fi
  if [ -f "${CASES_DIR:?}/limit" ]; then read -r asked <"$CASES_DIR/limit"; fi
  case $asked in
    '' | *[!0-9]*) echo "$CASES_DEFAULT_LIMIT" ;;
    *) echo "$asked" ;;
  esac
}

# Runs one case and prints its result line.
cases__one() {
  local name=$1 start=$SECONDS code limit="" timed_out=0 line="" i lines=()
  rm -f "$CASES_DIR/result" "$CASES_DIR/limit" "$CASES_DIR/skip"
  : >"$CASES_DIR/out"
  (
    # The case and its children do not hold the runner's nap fifo.
    [ -z "$CASES_NAPFD" ] || exec {CASES_NAPFD}>&-
    cases__body "$name"
  ) >"$CASES_DIR/out" 2>&1 </dev/null &
  CASES_PID=$!
  while kill -0 "$CASES_PID" 2>/dev/null; do
    limit=$(cases__limit_now)
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      timed_out=1
      cases__kill_tree "$CASES_PID"
      break
    fi
    cases__nap
  done
  if kill -0 "$CASES_PID" 2>/dev/null; then
    code=unknown
  else
    wait "$CASES_PID" 2>/dev/null
    code=$?
  fi
  CASES_PID=""
  [ -z "${CASES_TIMES:-}" ] || echo "time $name $((SECONDS - start)) s" >&2
  if [ "$timed_out" -eq 1 ]; then
    line="FAIL $name (timed out after $limit s)"
  elif [ ! -f "$CASES_DIR/result" ]; then
    line="FAIL $name (ended with exit $code before the case finished)"
  else
    read -r line <"$CASES_DIR/result"
    case $line in
      ok) line="PASS $name" ;;
      "ok skipped: "*) line="PASS $name (${line#ok })" ;;
      "fail "*) line="FAIL $name (${line#fail })" ;;
      *) line="FAIL $name (unreadable result)" ;;
    esac
  fi
  echo "$line"
  if [ "${line:0:4}" = PASS ]; then
    CASES_PASSED=$((CASES_PASSED + 1))
  else
    CASES_FAILED=$((CASES_FAILED + 1))
    mapfile -t lines <"$CASES_DIR/out"
    for ((i = ${#lines[@]} > 20 ? ${#lines[@]} - 20 : 0; i < ${#lines[@]}; i++)); do
      printf '  %s\n' "${lines[$i]%$'\r'}"
    done
  fi
}

# Runs the cases chosen by cases_init and prints the counts line. Its status is 0 when every case passed and 1 otherwise,
# so a test whose last command is cases_run exits with it. (An exit inside the function makes shellcheck flag every unquoted variable of the test.)
cases_run() {
  local name
  CASES_DIR=$(mktemp -d) || {
    echo "${0##*/}: mktemp failed" >&2
    exit 1
  }
  if mkfifo "$CASES_DIR/nap" 2>/dev/null; then
    CASES_NAP=$CASES_DIR/nap
    { exec {CASES_NAPFD}<>"${CASES_NAP:?}"; } 2>/dev/null || CASES_NAPFD=""
  fi
  for name in "${CASES_TODO[@]}"; do
    cases__one "$name"
  done
  echo "passed $CASES_PASSED failed $CASES_FAILED"
  cases_stop
  [ "$CASES_FAILED" -eq 0 ]
}
