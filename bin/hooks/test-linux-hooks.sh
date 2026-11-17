#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases are commands taken literally, $ and all, and cases.sh reads CASE_NAMES
#
# Tests the Linux cases of the command hooks: the Linux forms of
# refuse-kill-by-name.sh, refuse-npx.sh, the node heredoc of refuse-python-heredoc.sh, and the write rule of
# refuse-shell-edits.sh on Linux paths. Each command goes to the hook alone and to refuse-command-hooks.sh, the
# one bash that the agent settings register, as a Claude Code PreToolUse payload on standard input, as the harness
# sends it. A refusal must exit 2 from both, with the same message. A pass must exit 0 from both.
#
# LINUX_HOOKS=<folder> points the test at another copy of the hooks folder, with its lib/. The case runner, the
# CASES filter, --list, the time limit and the counts line are in cases.sh (CASES_SH, or the tests/cases.sh beside
# the hooks folder).
# Cases, each its own function:
#   kill_linux_refused     pkill, killall, kill $(pgrep ...), kill `pidof ...`, kill "$(pgrep ...)" and pgrep | xargs kill
#                          are refused, also in bash -c, and the message names kill <id> and /proc/<id>/cmdline
#   kill_linux_passes      kill <id>, pgrep and pidof alone, xargs kill fed ids from a file, and pkill named in text pass
#   npx_refused            npx, npm exec, npm x and npm --yes exec are refused, also in bash -c and sh -c, and the message names npm run
#   npx_passes             npm ci, install, test, run <script> and run exec, and npx named in text pass
#   node_heredoc_refused   a heredoc or here-string fed to node or nodejs, or cat with a heredoc piped into node, is refused,
#                          and the message says to run it from a file with node (or nodejs)
#   node_passes            node <file>, node -e, node --test, a pipe into node -, and node - alone pass
#   shell_edits_refused    writes through cat, awk, a brace group, sed -i and tee onto Linux paths are refused
#   shell_edits_passes     the same writes into a scratchpad, /tmp, /dev/null or a path held in a variable pass
#   npm_short_option       npm -y exec foo is refused: a short option before the subcommand is skipped too
#   xargs_killall          pgrep node | xargs killall is refused
#   xargs_pkill            pgrep node | xargs pkill -9 is refused
#   nodejs_message         nodejs fed a heredoc gets node's reason (the brief bans it), never python's
#   npx_message_tail       the second line of refuse-npx.sh's message names the installed binary, node_modules/.bin/<name>
#   prefix_sudo            sudo before npx, pkill or killall is seen, as env is, also with its own options
#   prefix_timeout         timeout and its duration before them are seen, also with its own options
#   prefix_nice            nice before them is seen, also with -n and its value
#   prefix_busybox         busybox before them is seen

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASES_SH="${CASES_SH:-$HERE/../tests/cases.sh}"
if [[ ! -f "$CASES_SH" ]]; then
  echo "test-linux-hooks.sh: cases.sh is not at $CASES_SH, so no case ran. Set CASES_SH to its path." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CASES_SH"
HOOKS="${LINUX_HOOKS:-$HERE}"
KILL="$HOOKS/refuse-kill-by-name.sh"
PY="$HOOKS/refuse-python-heredoc.sh"
NPX="$HOOKS/refuse-npx.sh"
EDITS="$HOOKS/refuse-shell-edits.sh"
ALL="$HOOKS/refuse-command-hooks.sh"

CASE_NAMES=(kill_linux_refused kill_linux_passes npx_refused npx_passes node_heredoc_refused node_passes shell_edits_refused shell_edits_passes
  npm_short_option xargs_killall xargs_pkill nodejs_message npx_message_tail prefix_sudo prefix_timeout prefix_nice prefix_busybox)
cases_init "$@"

WORK=$(mktemp -d)
trap 'cases_stop; rm -rf "${WORK:?}"' EXIT
trap 'exit 1' INT TERM
ERR="$WORK/err"

# json_string <text>: JSON is the text as a JSON string.
json_string() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf -v JSON '"%s"' "$s"
}

# run_hook <hook> <command>: RC is the exit status of the hook on a Bash payload of the command, ERRTEXT its standard error.
run_hook() {
  json_string "$2"
  bash "$1" 2>"$ERR" >/dev/null <<<"{\"session_id\":\"test\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$JSON,\"description\":\"test\"}}"
  RC=$?
  ERRTEXT=$(<"$ERR")
}

# refused <hook> <command> [text]: the hook alone and the one bash each exit 2, with the same message, which holds the text.
refused() {
  local alone
  run_hook "$1" "$2"
  [[ "$RC" == 2 ]] || WHY+=("${1##*/} on $2 exits $RC, want 2")
  [[ -z "${3:-}" || "$ERRTEXT" == *"$3"* ]] || WHY+=("${1##*/} on $2: the message lacks '$3': $ERRTEXT")
  alone=$ERRTEXT
  run_hook "$ALL" "$2"
  [[ "$RC" == 2 ]] || WHY+=("the one bash on $2 exits $RC, want 2")
  [[ "$ERRTEXT" == "$alone" ]] || WHY+=("the one bash on $2 gives another message than ${1##*/}: $ERRTEXT")
}

# passes <hook> <command>: the hook alone and the one bash each exit 0.
passes() {
  run_hook "$1" "$2"
  [[ "$RC" == 0 ]] || WHY+=("${1##*/} on $2 exits $RC, want 0: $ERRTEXT")
  run_hook "$ALL" "$2"
  [[ "$RC" == 0 ]] || WHY+=("the one bash on $2 exits $RC, want 0: $ERRTEXT")
}

case_kill_linux_refused() {
  local c
  for c in 'pkill node' 'pkill -f wrangler' 'killall node' '/usr/bin/killall -9 node' 'kill $(pgrep -f wrangler)' \
    'kill -9 `pidof node`' 'kill "$(pgrep -f wrangler)"' 'pgrep -f wrangler | xargs kill' 'pidof node | xargs -r kill -9' \
    "bash -c 'pkill node'" 'cd /srv/work/x && kill $(pidof workerd)' 'kill "$(pidof node)"' 'kill "`pgrep -f wrangler`"'; do
    refused "$KILL" "$c" 'kill <id>'
  done
  run_hook "$KILL" 'pkill node'
  [[ "$ERRTEXT" == *'/proc/[0-9]*/cmdline'* ]] || WHY+=("the message does not name /proc/[0-9]*/cmdline: $ERRTEXT")
}

case_kill_linux_passes() {
  local c
  for c in 'kill 1234' 'kill -9 1234 5678' 'pgrep -af wrangler' 'pidof node' 'xargs kill < /tmp/x/pids' \
    'echo pkill node' 'git commit -m "pkill node is refused"' 'kill $(cat /tmp/x/pid)'; do
    passes "$KILL" "$c"
  done
}

case_npx_refused() {
  local c
  for c in 'npx foo' 'npx -y create-thing' 'npm exec foo' 'npm x foo' 'npm --yes exec foo' "bash -c 'npx foo'" \
    'sh -c "npm exec -- foo"' 'cd /srv/work/x && npx tsc'; do
    refused "$NPX" "$c" 'npm run <script>'
  done
}

case_npx_passes() {
  local c
  for c in 'npm ci' 'npm install' 'npm test' 'npm run check' 'npm run exec' 'echo npx foo' 'git commit -m "no npx here"' 'npm'; do
    passes "$NPX" "$c"
  done
}

case_node_heredoc_refused() {
  local c
  for c in $'node - <<\'EOF\'\nconsole.log(1)\nEOF' $'node <<EOF\nconsole.log(1)\nEOF' $'nodejs <<EOF\nconsole.log(1)\nEOF' \
    $'cat <<EOF | node\nconsole.log(1)\nEOF' "node <<< 'console.log(1)'" $'bash -c \'node <<E\nconsole.log(1)\nE\''; do
    refused "$PY" "$c" 'and run node'
  done
  # The refusal of python stays.
  refused "$PY" $'python3 - <<EOF\nprint(1)\nEOF' 'python <file>'
}

case_node_passes() {
  local c
  # node - with nothing on standard input is python's refusal only, so it passes for node.
  for c in 'node x.js' 'node -e "console.log(1)"' 'node --test test/' 'echo "console.log(1)" | node -' 'cat x.js | node' 'node -' \
    $'cat > /tmp/x.js <<EOF\nconsole.log(1)\nEOF'; do
    passes "$PY" "$c"
  done
}

case_shell_edits_refused() {
  local c
  for c in $'cat > /srv/reports/x.md <<EOF\nline\nEOF' "awk '{print}' f > /srv/work/x/new.js" '{ echo a; echo b; } > /srv/work/x/f' \
    $'cat >> /srv/reports/x.md <<\'EOF\'\nline\nEOF' "sed -i 's/a/b/' /srv/work/x/f.md" 'echo x | tee /srv/work/x/f'; do
    refused "$EDITS" "$c"
  done
}

case_shell_edits_passes() {
  local c
  for c in $'cat >> /tmp/claude-uid/p/s/scratchpad/x.md <<\'EOF\'\nline\nEOF' $'cat >> "$T" <<\'EOF\'\nline\nEOF' 'echo x > /tmp/x' \
    'ls > /dev/null' 'grep -c x /srv/work/x/f'; do
    passes "$EDITS" "$c"
  done
}

case_npm_short_option() {
  refused "$NPX" 'npm -y exec foo' 'npm run <script>'
}

case_xargs_killall() {
  refused "$KILL" 'pgrep node | xargs killall' 'kill <id>'
}

case_xargs_pkill() {
  refused "$KILL" 'pgrep node | xargs pkill -9' 'kill <id>'
}

case_nodejs_message() {
  refused "$PY" $'nodejs <<EOF\nconsole.log(1)\nEOF' 'and run nodejs <file>'
  [[ "${ERRTEXT%%$'\n'*}" == *'fed to nodejs. The brief bans it'* ]] || WHY+=("the first line does not give node's reason for nodejs: ${ERRTEXT%%$'\n'*}")
}

case_npx_message_tail() {
  refused "$NPX" 'npx foo' 'or its installed binary (node_modules/.bin/<name>).'
}

# prefixed <prefix>...: each prefix form before npx, pkill and killall is refused by its hook and by the one bash.
prefixed() {
  local p
  for p in "$@"; do
    refused "$NPX" "$p npx foo" 'npm run <script>'
    refused "$KILL" "$p pkill node" 'kill <id>'
    refused "$KILL" "$p killall node" 'kill <id>'
  done
}

case_prefix_sudo() {
  prefixed sudo 'sudo -u agent' 'sudo -E' 'sudo --user=agent'
}

case_prefix_timeout() {
  prefixed 'timeout 5' 'timeout 590' 'timeout 1.5m' 'timeout -s KILL 5' 'timeout -k 10 5' 'timeout --signal=TERM 5' 'timeout --preserve-status 5'
}

case_prefix_nice() {
  prefixed nice 'nice -n 10' 'nice -n10' 'nice --adjustment=5'
}

case_prefix_busybox() {
  prefixed busybox '/usr/bin/busybox'
}

cases_run
