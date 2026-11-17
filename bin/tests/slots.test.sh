#!/usr/bin/env bash
# shellcheck disable=SC2034  # cases.sh reads CASE_NAMES
#
# Tests slots.sh with a fake herdr, a fake meminfo file and a throwaway machines.conf. Each case is its own function, run by cases.sh.
#   start_when_free        free memory above the floor and slots to spare gives "verdict: start" and exit 0
#   wait_under_floor       free memory under the floor gives a wait that names the floor, exit 2
#   wait_authors_full      working and blocked authors fill the author slots, idle and done ones hold none
#   reviewer_names         review-<x> and <x>-check count as reviewers and every other name as an author
#   orchestrator_free      an orchestrator name holds no slot in either role
#   flags_override         --floor, --authors and --reviewers override the defaults
#   usage_errors           a bad role, a bad floor and a repeated --machine are usage errors, exit 1
#   herdr_fails            a failing herdr agent list exits 1 with a line on stderr
#   self_machine           with a machine-self file the machine reads MemAvailable and its own table line
#   self_refuses_local     --machine local on a machine with a machine-self file is an error
#   owner_share            --owner shares a machine's slots between sub-orchestrators, and --take writes a claim
#   take_claim_in_flight   a claim for an agent not yet listed counts for 300 s, as "starting"
#   machine_any_self       --machine any on a machine with a machine-self file asks that machine alone

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASES_SH="${CASES_SH:-$HERE/cases.sh}"
# shellcheck source=cases.sh
source "$CASES_SH"
BIN=$(cd "$HERE/.." && pwd)
TOOL="$BIN/slots.sh"

CASE_NAMES=(start_when_free wait_under_floor wait_authors_full reviewer_names orchestrator_free flags_override usage_errors herdr_fails
  self_machine self_refuses_local owner_share take_claim_in_flight machine_any_self)
cases_init "$@"

WORK=$(mktemp -d)
trap 'cases_stop; rm -rf "${WORK:?}"' EXIT
trap 'exit 1' INT TERM
mkdir -p "$WORK/bin" "$WORK/locks"
cat >"$WORK/bin/herdr" <<'EOF'
#!/usr/bin/env bash
# The fake herdr prints the list in the file FAKE_LIST, or fails when FAKE_FAIL is set.
[[ -z "${FAKE_FAIL:-}" ]] || { echo "herdr: no server" >&2; exit 1; }
cat "$FAKE_LIST"
EOF
chmod +x "$WORK/bin/herdr"
export PATH="$WORK/bin:$PATH"
export FAKE_LIST="$WORK/list"
export SLOTS_LOCKS="$WORK/locks"
export MACHINES_CONF="$WORK/machines.conf"
export MACHINE_SELF_FILE="$WORK/no-such-machine-self"
printf '%s\n' 'local 2 1 1.5' 'cloud 4 2 2' >"$MACHINES_CONF"

# meminfo <MemFree kB> [MemAvailable kB]: writes the fake meminfo file.
meminfo() {
  printf 'MemTotal: 99999999 kB\nMemFree: %s kB\nMemAvailable: %s kB\n' "$1" "${2:-$1}" >"$WORK/meminfo"
  export SLOTS_MEMINFO="$WORK/meminfo"
}

# agents <name:state>...: writes a compact herdr agent list with agent as the first key of each object.
agents() {
  local out='{"id":"cli:agent:list","result":{"agents":[' sep="" a name state
  for a in "$@"; do
    name=${a%%:*}
    state=${a##*:}
    out+="$sep"'{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"s"},"agent_status":"'"$state"'","cwd":"/work","name":"'"$name"'","pane_id":"p-'"$name"'","type":"agent_info"}'
    sep=,
  done
  printf '%s]}}\n' "$out" >"$FAKE_LIST"
}

# run <args...>: OUT is stdout, ERRTEXT stderr, RC the exit status.
run() {
  OUT=$(bash "$TOOL" "$@" 2>"$WORK/err")
  RC=$?
  ERRTEXT=$(<"$WORK/err")
}

expect() { # expect <rc> <text in stdout>
  [[ "$RC" == "$1" ]] || WHY+=("exit $RC, want $1: $OUT $ERRTEXT")
  [[ "$OUT" == *"$2"* ]] || WHY+=("stdout lacks '$2': $OUT")
}

case_start_when_free() {
  meminfo 4000000
  agents a1:working
  run author
  expect 0 "verdict: start"
  [[ "$OUT" == *"authors: 1 of 2 held: a1 working"* ]] || WHY+=("the author line is wrong: $OUT")
  [[ "$OUT" == "free: 3.81 GB (floor 1.5 GB)"* ]] || WHY+=("the free line is wrong: $OUT")
}

case_wait_under_floor() {
  meminfo 1000000
  agents
  run author
  expect 2 "verdict: wait (free memory under the floor)"
}

case_wait_authors_full() {
  meminfo 4000000
  agents a1:working a2:blocked a3:idle a4:done a5:unknown
  run author
  expect 2 "verdict: wait (author slots full)"
  [[ "$OUT" == *"authors: 2 of 2 held: a1 working, a2 blocked"* ]] || WHY+=("holders wrong: $OUT")
  agents a1:working a3:idle a4:done
  run author
  expect 0 "verdict: start"
}

case_reviewer_names() {
  meminfo 4000000
  agents review-x:working y-check:working a1:working
  run reviewer
  expect 2 "reviewer slots full"
  [[ "$OUT" == *"reviewers: 2 of 1 held: review-x working, y-check working"* ]] || WHY+=("reviewers wrong: $OUT")
  [[ "$OUT" == *"authors: 1 of 2 held: a1 working"* ]] || WHY+=("authors wrong: $OUT")
}

case_orchestrator_free() {
  meminfo 4000000
  agents orch-site:working dev-orchestrator:working dev-orchestrator-2:blocked
  run author
  expect 0 "authors: 0 of 2 held:"
}

case_flags_override() {
  meminfo 4000000
  agents a1:working a2:working
  run --authors 3 author
  expect 0 "authors: 2 of 3 held"
  run --floor 5 author
  expect 2 "floor 5.0 GB"
  run --reviewers 0 reviewer
  expect 2 "reviewer slots full"
}

case_usage_errors() {
  meminfo 4000000
  agents
  run nobody
  [[ "$RC" == 1 ]] || WHY+=("a bad role exits $RC, want 1")
  run --floor 2. author
  [[ "$RC" == 1 ]] || WHY+=("floor 2. exits $RC, want 1")
  run --floor .5 author
  [[ "$RC" == 1 ]] || WHY+=("floor .5 exits $RC, want 1")
  run --machine local --machine cloud author
  [[ "$RC" == 1 ]] || WHY+=("two --machine exits $RC, want 1")
  run --machine nowhere author
  [[ "$RC" == 1 ]] || WHY+=("an unknown machine exits $RC, want 1")
}

case_herdr_fails() {
  meminfo 4000000
  agents
  FAKE_FAIL=1 run author
  [[ "$RC" == 1 ]] || WHY+=("a failing herdr exits $RC, want 1")
  [[ "$ERRTEXT" == *"herdr agent list failed"* ]] || WHY+=("no herdr line on stderr: $ERRTEXT")
}

case_self_machine() {
  # On a machine whose machine-self file names a label, memory is MemAvailable and the limits are that label's line.
  printf 'cloud\n' >"$WORK/self"
  meminfo 100000 6000000
  agents a1:working a2:working a3:working
  MACHINE_SELF_FILE="$WORK/self" run author
  expect 0 "free: 5.72 GB available (floor 2.0 GB)"
  [[ "$OUT" == *"authors: 3 of 4 held"* ]] || WHY+=("limits are not cloud's: $OUT")
  printf 'nowhere\n' >"$WORK/self-bad"
  MACHINE_SELF_FILE="$WORK/self-bad" run author
  [[ "$RC" == 1 && "$ERRTEXT" == *"does not list"* ]] || WHY+=("a machine-self file naming no label is not an error: $RC $ERRTEXT")
}

case_self_refuses_local() {
  printf 'cloud\n' >"$WORK/self"
  meminfo 4000000
  agents
  MACHINE_SELF_FILE="$WORK/self" run --machine local author
  [[ "$RC" == 1 && "$ERRTEXT" == *"local is the control machine"* ]] || WHY+=("--machine local was not refused: $RC $ERRTEXT")
  run --owner orch-site author
  [[ "$RC" == 1 && "$ERRTEXT" == *"only on the machine itself"* ]] || WHY+=("--owner on the control machine was not refused: $RC $ERRTEXT")
}

case_owner_share() {
  printf 'cloud\n' >"$WORK/self"
  meminfo 4000000
  # Two owners and 4 authors give 2 each. orch-site holds two, so it is full, and orch-docs holds none.
  agents orch-site:working orch-docs:working s1:working s2:working
  mkdir -p "$WORK/locks/slots-claims"
  printf 'owner=site\nsince=1\n' >"$WORK/locks/slots-claims/s1"
  printf 'owner=site\nsince=1\n' >"$WORK/locks/slots-claims/s2"
  MACHINE_SELF_FILE="$WORK/self" run --owner orch-site author
  expect 2 "owner: site holds 2 of 2 authors, 2 owners"
  [[ "$OUT" == *"owner share full (2 of 2)"* ]] || WHY+=("a full share was not named: $OUT")
  MACHINE_SELF_FILE="$WORK/self" run --owner orch-docs-3 author
  [[ "$OUT" == *"owner: docs holds 0 of 2 authors, 2 owners"* ]] || WHY+=("a successor is not the same owner: $OUT")
}

case_take_claim_in_flight() {
  printf 'cloud\n' >"$WORK/self"
  meminfo 4000000
  agents orch-site:working
  rm -rf "$WORK/locks/slots-claims"
  MACHINE_SELF_FILE="$WORK/self" run --owner orch-site --take t1 author
  expect 0 "verdict: start"
  [[ "$ERRTEXT" == *"slots: claimed t1 for site"* ]] || WHY+=("no claim line: $ERRTEXT")
  [[ -f "$WORK/locks/slots-claims/t1" ]] || WHY+=("no claim file")
  # t1 is not in the list yet, and its claim is young, so it holds a slot as "starting".
  MACHINE_SELF_FILE="$WORK/self" run --owner orch-site author
  [[ "$OUT" == *"t1 starting"* ]] || WHY+=("a claim in flight is not counted: $OUT")
  # A take of a name that is already an agent is refused.
  agents orch-site:working t1:working
  MACHINE_SELF_FILE="$WORK/self" run --owner orch-site --take t1 author
  [[ "$RC" == 1 && "$ERRTEXT" == *"already an agent"* ]] || WHY+=("a take of a listed agent was not refused: $RC $ERRTEXT")
  MACHINE_SELF_FILE="$WORK/self" run --owner orch-site --take orch-x author
  [[ "$RC" == 1 && "$ERRTEXT" == *"orchestrator's name"* ]] || WHY+=("a take of an orchestrator name was not refused: $RC $ERRTEXT")
}

case_machine_any_self() {
  printf 'cloud\n' >"$WORK/self"
  meminfo 4000000
  agents
  MACHINE_SELF_FILE="$WORK/self" run --machine any author
  expect 0 "machine: cloud"
}

cases_run
