#!/usr/bin/env bash
# shellcheck disable=SC2034  # cases.sh reads CASE_NAMES
#
# Tests orch-wake.sh with a fake herdr that serves one agent list file after another, and a fake run-long.sh. Each case is its own function, run by cases.sh.
#   unknown_bare_name      a bare name that is not in the list exits 1 at once
#   baseline_differs       name@state with a different current state returns at once with wake: change and "(was <state>)"
#   gone_agent             name@state for an agent that is not listed shows "gone gone (was <state>)"
#   bound_no_change        no change until the bound gives wake: bound and exit 0
#   change_while_waiting   an agent that changes between polls ends the wait with wake: change
#   report_head            name=path prints the first 15 lines of a changed agent's report, or one line when it is not there yet
#   usage_errors           a bound of 600 or more, an empty state, an empty name and no argument are usage errors, exit 1
#   remote_unreachable     a remote agent whose machine cannot be read is unreachable, not a change, and the poll interval is raised to 20 s
#   remote_path_refused    a remote report path under .ssh, or outside the remote home, is refused with exit 1 before any ssh call
#   run_ended              run:<name> returns at once when the run has ended, with its end line and log path
#   run_no_such            run:<name> with no run exits 1

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASES_SH="${CASES_SH:-$HERE/cases.sh}"
# shellcheck source=cases.sh
source "$CASES_SH"
BIN=$(cd "$HERE/.." && pwd)
TOOL="$BIN/orch-wake.sh"

CASE_NAMES=(unknown_bare_name baseline_differs gone_agent bound_no_change change_while_waiting report_head usage_errors remote_unreachable
  remote_path_refused run_ended run_no_such)
cases_init "$@"

WORK=$(mktemp -d)
trap 'cases_stop; rm -rf "${WORK:?}"' EXIT
trap 'exit 1' INT TERM
mkdir -p "$WORK/bin" "$WORK/lists"
# The fake herdr serves lists/<n> for its n-th call (the last one again after that), and fails for a --machine call when FAKE_MACHINE_FAIL is set.
cat >"$WORK/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --machine ]]; then
  [[ -z "${FAKE_MACHINE_FAIL:-}" ]] || { echo "ssh: could not resolve host" >&2; exit 1; }
  shift 2
fi
n=0
[[ ! -f "$FAKE_DIR/count" ]] || read -r n <"$FAKE_DIR/count"
n=$((n + 1))
printf '%s\n' "$n" >"$FAKE_DIR/count"
f="$FAKE_DIR/lists/$n"
[[ -f "$f" ]] || f=$(ls "$FAKE_DIR"/lists/* | sort -V | tail -n 1)
cat "$f"
EOF
chmod +x "$WORK/bin/herdr"
cat >"$WORK/fake-run-long.sh" <<'EOF'
#!/usr/bin/env bash
# Fake run-long.sh status --name <name>: the answers are in files named after the run.
name=$3
if [[ -f "$FAKE_DIR/answer-$name" ]]; then cat "$FAKE_DIR/answer-$name"; else echo "run-long: $name no run"; fi
EOF
export PATH="$WORK/bin:$PATH" FAKE_DIR="$WORK"
export ORCH_WAKE_RUN_LONG="$WORK/fake-run-long.sh"
export MACHINES_CONF="$WORK/machines.conf" MACHINE_SELF_FILE="$WORK/no-machine-self"
printf '%s\n' 'local 2 1 1.5' 'cloud 4 2 2' >"$MACHINES_CONF"

# list <n> <name:state>...: writes the n-th list.
list() {
  local n=$1 out='{"id":"cli:agent:list","result":{"agents":[' sep="" a
  shift
  for a in "$@"; do
    out+="$sep"'{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s"},"agent_status":"'"${a##*:}"'","cwd":"/work","name":"'"${a%%:*}"'","pane_id":"p-'"${a%%:*}"'","type":"agent_info"}'
    sep=,
  done
  printf '%s]}}\n' "$out" >"$WORK/lists/$n"
}
reset() { rm -f "$WORK/count" "$WORK/lists"/* "$WORK"/answer-*; }

# run <args...>: OUT is stdout, ERRTEXT stderr, RC the exit status.
run() {
  OUT=$(bash "$TOOL" "$@" 2>"$WORK/err")
  RC=$?
  ERRTEXT=$(<"$WORK/err")
}
rc_is() { [[ "$RC" == "$1" ]] || WHY+=("exit $RC, want $1: $OUT $ERRTEXT"); }
out_has() { [[ "$OUT" == *"$1"* ]] || WHY+=("stdout lacks '$1': $OUT"); }

case_unknown_bare_name() {
  reset
  list 1 a:working
  run --bound 2 --every 1 nobody
  rc_is 1
  [[ "$ERRTEXT" == *"no agent named nobody"* ]] || WHY+=("no 'no agent named' line: $ERRTEXT")
}

case_baseline_differs() {
  reset
  list 1 a:working
  run --bound 5 a@idle
  rc_is 0
  [[ "${OUT%%$'\n'*}" == "wake: change" ]] || WHY+=("first line is not 'wake: change': $OUT")
  out_has "a working p-a (was idle)"
}

case_gone_agent() {
  reset
  list 1 b:working
  run --bound 5 a@working
  rc_is 0
  out_has "a gone gone (was working)"
}

case_bound_no_change() {
  reset
  list 1 a:working
  run --bound 2 --every 1 a
  rc_is 0
  [[ "${OUT%%$'\n'*}" == "wake: bound" ]] || WHY+=("first line is not 'wake: bound': $OUT")
  out_has "a working p-a"
  [[ "$OUT" != *"(was"* ]] || WHY+=("an unchanged agent shows a was: $OUT")
}

case_change_while_waiting() {
  reset
  list 1 a:working
  list 2 a:working
  list 3 a:idle
  run --bound 20 --every 1 a
  rc_is 0
  [[ "${OUT%%$'\n'*}" == "wake: change" ]] || WHY+=("first line is not 'wake: change': $OUT")
  out_has "a idle p-a (was working)"
}

case_report_head() {
  reset
  list 1 a:idle
  local n
  for n in $(seq 1 20); do printf 'line %s\n' "$n"; done >"$WORK/report.md"
  run --bound 5 "a@working=$WORK/report.md"
  rc_is 0
  out_has "--- $WORK/report.md (first 15 lines)"
  out_has "line 15"
  [[ "$OUT" != *"line 16"* ]] || WHY+=("more than 15 lines printed")
  run --bound 5 "a@working=$WORK/not-yet.md"
  out_has "$WORK/not-yet.md does not exist yet"
}

case_usage_errors() {
  reset
  list 1 a:working
  run --bound 600 a
  rc_is 1
  run a@
  rc_is 1
  run @idle
  rc_is 1
  run
  rc_is 1
  run --bound 0 a
  rc_is 1
  run a@idle@x
  rc_is 1
  run local/a
  rc_is 1
  run nowhere/a
  rc_is 1
}

case_remote_unreachable() {
  reset
  list 1 a:working
  FAKE_MACHINE_FAIL=1 run --bound 2 --every 1 cloud/a
  rc_is 0
  out_has "wake: bound"
  out_has "cloud/a unreachable unreachable"
  out_has "machine cloud unreachable"
  [[ "$ERRTEXT" == *"--every raised from 1 to 20"* ]] || WHY+=("no --every note: $ERRTEXT")
  [[ "$ERRTEXT" == *"cloud is unreachable"* ]] || WHY+=("no unreachable note: $ERRTEXT")
}

case_remote_path_refused() {
  reset
  list 1 a:working
  local home="$WORK/remote-home"
  REMOTE_HOME="$home" run --bound 2 "cloud/a=$home/.ssh/id_key"
  rc_is 1
  [[ "$ERRTEXT" == *"has a part named .ssh"* ]] || WHY+=("a .ssh path was not refused: $ERRTEXT")
  REMOTE_HOME="$home" run --bound 2 "cloud/a=/etc/passwd"
  rc_is 1
  [[ "$ERRTEXT" == *"is not below $home/"* ]] || WHY+=("a path outside the home was not refused: $ERRTEXT")
  REMOTE_HOME="$home" run --bound 2 "cloud/a=$home/x/../y"
  rc_is 1
  [[ "$ERRTEXT" == *"has a .. part"* ]] || WHY+=("a .. path was not refused: $ERRTEXT")
}

case_run_ended() {
  reset
  printf 'one\ntwo\nrun-long: end exit 0 2000-01-01T00:00:00+00:00\n' >"$WORK/job.log"
  printf 'run-long: job ended with code 0, log %s\n' "$WORK/job.log" >"$WORK/answer-job"
  run --bound 5 run:job
  rc_is 0
  [[ "${OUT%%$'\n'*}" == "wake: change" ]] || WHY+=("first line is not 'wake: change': $OUT")
  out_has "run:job ended exit 0 (was running)"
  out_has "run-long: end exit 0"
  out_has "log $WORK/job.log"
}

case_run_no_such() {
  reset
  run --bound 5 run:ghost
  rc_is 1
  [[ "$ERRTEXT" == *"no run named ghost"* ]] || WHY+=("no 'no run named' line: $ERRTEXT")
}

cases_run
