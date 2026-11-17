#!/usr/bin/env bash
# shellcheck disable=SC2034  # cases.sh reads CASE_NAMES
#
# Tests herdr-safe.sh with a fake herdr that records the arguments it gets. Each case is its own function, run by cases.sh
# (run it with --list for the names, or CASES="<name> ..." for some). The fake herdr is first on PATH, so no real Herdr is touched.
#   strips_cr              a trailing carriage return is removed from every argument
#   no_path_conversion     herdr runs with MSYS_NO_PATHCONV=1
#   exit_status            herdr's own exit status is the script's
#   trap3_names            a Claude start gets --name and --remote-control after the --
#   trap3_caller_name      a caller's own --name or --remote-control is kept and none is added
#   trap4_settings         a Claude start gets --settings with the file beside the script
#   trap4_given            a caller's own --settings is kept and none is added
#   orchestrator_no_file   an orchestrator name gets no --settings
#   other_kind_untouched   a start of another kind is passed through unchanged
#   leading_pairs          a leading --machine or --session pair stays first and Trap 3 still applies after it
#   machine_settings       a start on a --machine takes the settings path from ORCH_REMOTE_BIN, and says so when it is unset

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASES_SH="${CASES_SH:-$HERE/cases.sh}"
# shellcheck source=cases.sh
source "$CASES_SH"
BIN=$(cd "$HERE/.." && pwd)
TOOL="$BIN/herdr-safe.sh"
SETTINGS="$BIN/claude-agent-settings.json"

CASE_NAMES=(strips_cr no_path_conversion exit_status trap3_names trap3_caller_name trap4_settings trap4_given orchestrator_no_file
  other_kind_untouched leading_pairs machine_settings)
cases_init "$@"

WORK=$(mktemp -d)
trap 'cases_stop; rm -rf "${WORK:?}"' EXIT
trap 'exit 1' INT TERM
mkdir -p "$WORK/bin"
cat >"$WORK/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_ARGS"
printf '%s\n' "${MSYS_NO_PATHCONV:-unset}" >"$FAKE_ARGS.env"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$WORK/bin/herdr"
export FAKE_ARGS="$WORK/args"
export PATH="$WORK/bin:$PATH"

# run <args...>: runs the tool. GOT is the arguments herdr saw, joined by a single space, and RC the exit status.
run() {
  bash "$TOOL" "$@" 2>"$WORK/err" >/dev/null
  RC=$?
  GOT=$(tr '\n' ' ' <"$FAKE_ARGS")
  GOT=${GOT% }
  ERRTEXT=$(<"$WORK/err")
}

want() { # want <text>: GOT must be exactly the text
  [[ "$GOT" == "$1" ]] || WHY+=("herdr got '$GOT', want '$1'")
}

case_strips_cr() {
  run tab close $'w1:1\r'
  want "tab close w1:1"
}

case_no_path_conversion() {
  run agent prompt x /retro
  want "agent prompt x /retro"
  [[ "$(<"$FAKE_ARGS.env")" == 1 ]] || WHY+=("MSYS_NO_PATHCONV was not 1")
}

case_exit_status() {
  FAKE_RC=3 run tab close w1
  [[ "$RC" == 3 ]] || WHY+=("exit $RC, want 3")
}

case_trap3_names() {
  run agent start ticket-1 --kind claude -- --model x
  want "agent start ticket-1 --kind claude -- --name ticket-1 --remote-control ticket-1 --settings $SETTINGS --model x"
  run agent start ticket-2 --kind=claude
  want "agent start ticket-2 --kind=claude -- --name ticket-2 --remote-control ticket-2 --settings $SETTINGS"
}

case_trap3_caller_name() {
  run agent start ticket-1 --kind claude -- --name mine
  want "agent start ticket-1 --kind claude -- --settings $SETTINGS --name mine"
  run agent start ticket-1 --kind claude -- --remote-control mine
  want "agent start ticket-1 --kind claude -- --settings $SETTINGS --remote-control mine"
}

case_trap4_settings() {
  [[ -r "$SETTINGS" ]] || WHY+=("the settings file $SETTINGS is missing")
  run agent start review-1 --kind claude
  [[ "$GOT" == *"--settings $SETTINGS"* ]] || WHY+=("no --settings in: $GOT")
}

case_trap4_given() {
  run agent start ticket-1 --kind claude -- --settings /tmp/mine.json
  want "agent start ticket-1 --kind claude -- --name ticket-1 --remote-control ticket-1 --settings /tmp/mine.json"
  run agent start ticket-1 --kind claude -- --settings=/tmp/mine.json
  want "agent start ticket-1 --kind claude -- --name ticket-1 --remote-control ticket-1 --settings=/tmp/mine.json"
}

case_orchestrator_no_file() {
  run agent start orch-site --kind claude
  want "agent start orch-site --kind claude -- --name orch-site --remote-control orch-site"
  run agent start dev-orchestrator-2 --kind claude
  want "agent start dev-orchestrator-2 --kind claude -- --name dev-orchestrator-2 --remote-control dev-orchestrator-2"
}

case_other_kind_untouched() {
  run agent start ticket-1 --kind codex -- --sandbox workspace-write
  want "agent start ticket-1 --kind codex -- --sandbox workspace-write"
  run agent list
  want "agent list"
}

case_leading_pairs() {
  run --session s1 agent start ticket-1 --kind claude
  want "--session s1 agent start ticket-1 --kind claude -- --name ticket-1 --remote-control ticket-1 --settings $SETTINGS"
  run --session=s1 --machine=cloud agent list
  want "--session=s1 --machine=cloud agent list"
  # A second --machine is not skipped, so Trap 3 stays off and herdr reports it.
  run --machine a --machine b agent start ticket-1 --kind claude
  want "--machine a --machine b agent start ticket-1 --kind claude"
}

case_machine_settings() {
  ORCH_REMOTE_BIN=/opt/orch/bin run --machine cloud agent start ticket-1 --kind claude
  want "--machine cloud agent start ticket-1 --kind claude -- --name ticket-1 --remote-control ticket-1 --settings /opt/orch/bin/claude-agent-settings.json"
  (unset ORCH_REMOTE_BIN; run --machine cloud agent start ticket-1 --kind claude
   [[ "$GOT" != *"--settings"* ]] || echo "settings added with no ORCH_REMOTE_BIN: $GOT" >"$WORK/why"
   [[ "$ERRTEXT" == *"ORCH_REMOTE_BIN is unset"* ]] || echo "no stderr line: $ERRTEXT" >>"$WORK/why")
  [[ ! -s "$WORK/why" ]] || WHY+=("$(<"$WORK/why")")
}

cases_run
