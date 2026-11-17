#!/usr/bin/env bash
# This hook only warns. Every end, a syntax error or a crash included, exits
# 0 in silence, so it never blocks a prompt.
trap 'exit 0' EXIT; exec 2>/dev/null
#
# UserPromptSubmit hook. Tells an orchestrator session that its context has
# grown, so it can hand itself over by the rule in its brief. Past 300,000 tokens
# it adds one line of context, and again at each further 100,000 (400k, 500k and
# so on), never twice for the same step. A jump over several steps warns once.
# A long-lived orchestrator drew most of its cache reads from that growth.
#
# Context is input_tokens + cache_read_input_tokens + cache_creation_input_tokens
# of the last assistant line in the transcript: the prompt the model read on
# its last call. Sidechain and <synthetic> lines do not count. The hook reads
# only the last 8 MB of the transcript, in one tail and one awk, because a
# transcript reaches tens of megabytes. A single line can reach several
# megabytes, so if 8 MB of later lines follow the last assistant line, that
# prompt gets nothing.
#
# UserPromptSubmit, not PostToolUse: it runs once a prompt and not once a
# tool call, the last turn is in the transcript by then, and the warning reaches
# an orchestrator at the start of a turn, when it can act on it. Messages from
# other sessions arrive as prompts too, so an orchestrator hears it in time.
#
# An orchestrator is the Herdr agent in HERDR_PANE_ID, named dev-orchestrator,
# dev-orchestrator-<n>, orch-<slug> or orch-<slug>-<n>, whose Claude session
# is this one. The session check matters because a claude started inside an
# orchestrator's pane inherits its HERDR_PANE_ID. A session outside Herdr is
# never warned. The folder of the transcript is not the test: an orchestrator
# may run in any project folder.
#
# The hook runs on every prompt of every session on the machine, and each
# process it starts costs seconds under load, so a session that is not an
# orchestrator starts none after its first prompt. The first prompt asks herdr
# once (timeout and herdr, two processes) and writes the verdict, yes or no, to
# ${TMPDIR:-/tmp}/claude-context-warning/<session id>.verdict. A later prompt
# reads the file with a builtin: no ends the hook there, before the transcript
# is touched, and yes goes on to the transcript. A session outside Herdr (no
# HERDR_PANE_ID) ends before even that.
# When herdr fails, or names an orchestrator whose session is not this one (none
# reported yet, or another's, as after a /clear or a resume before the new id is
# reported), no verdict is written and the next prompt asks again. So a session
# started inside an orchestrator's pane costs herdr and timeout on every prompt.
# herdr gets 3 seconds, or CONTEXT_HERDR_TIMEOUT seconds when that is set, which
# the test uses because its fake herdr is a bash script and slow to start under
# load.
#
# What a cached verdict misses. A session that becomes an orchestrator after its
# first prompt, by being renamed into an orchestrator name or by its pane taking
# the name later, stays no for the rest of the session. A session that stops
# being one stays yes and is still checked every prompt. A /clear starts a new
# session id and so a new verdict. A session resumed under the same id, in
# another pane or under another name, keeps the old verdict while the file is
# there. Delete the .verdict file to ask again.
#
# The last step handled lives in ${TMPDIR:-/tmp}/claude-context-warning/<session
# id>, written when a step is warned. After a /compact the context falls but the
# step stays, so the hook warns again only past the highest step already handled.
#
# Test: test-context-warning.sh beside it.

export LC_ALL=C
FIRST_STEP=3 STEP_SIZE=100000

input=""
IFS= read -r -d '' input
input=${input//$'\r'/}
[[ "$input" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9-]+)\" ]] || exit 0
session="${BASH_REMATCH[1]}"

# Outside Herdr there is nothing to ask and nothing to read.
[[ -n "${HERDR_PANE_ID:-}" ]] || exit 0

state_dir="${TMPDIR:-/tmp}/claude-context-warning"
verdict=""
[[ -f "$state_dir/$session.verdict" ]] && read -r verdict < "$state_dir/$session.verdict"
[[ "$verdict" != no ]] || exit 0

[[ "$input" =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"(([^\"\\]|\\.)*)\" ]] || exit 0
transcript="${BASH_REMATCH[1]//\\\\/\\}"
transcript="${transcript//\\//}"
[[ -f "$transcript" && -r "$transcript" ]] || exit 0

# write_state <file> <text>: the text goes to a file of the state folder.
write_state() {
  [[ -d "$state_dir" ]] || mkdir -p "$state_dir" || return 1
  printf '%s\n' "$2" > "$state_dir/$1"
}

# decide: VERDICT is yes when herdr names this session's agent as an
# orchestrator and no when it does not. It fails, with no verdict written, when
# herdr fails or when the agent has an orchestrator name and herdr has not named
# this session as its own, whether it names none or another. herdr learns a new
# session id late, after a /clear or a resume, so that case is not final: the
# next prompt asks again.
decide() {
  local agent name="" owner=""
  agent=$(timeout "${CONTEXT_HERDR_TIMEOUT:-3}" "${HERDR_BIN_PATH:-herdr}" agent get "$HERDR_PANE_ID") || return 1
  [[ "$agent" =~ \"pane_id\" ]] || return 1
  [[ "$agent" =~ \"name\":\"([^\"]*)\" ]] && name="${BASH_REMATCH[1],,}"
  [[ "$agent" =~ \"agent_session\":\{[^}]*\"value\":\"([^\"]*)\" ]] && owner="${BASH_REMATCH[1]}"
  VERDICT=no
  if [[ "$name" =~ ^(dev-orchestrator(-[0-9]+)?|orch-[a-z0-9]+(-[a-z0-9]+)*)$ ]]; then
    [[ "$owner" == "$session" ]] || return 1
    VERDICT=yes
  fi
  write_state "$session.verdict" "$VERDICT" || :
}

if [[ "$verdict" != yes ]]; then
  decide || exit 0
  [[ "$VERDICT" == yes ]] || exit 0
fi

# The last assistant line of the main chain and its sum, in lib/context.awk
# beside the hooks folder. It prints nothing when a figure is missing.
# CONTEXT_AWK names another copy, for a test.
hook_dir="${BASH_SOURCE[0]%/*}"
[[ "$hook_dir" == "${BASH_SOURCE[0]}" ]] && hook_dir=.
tokens=$(tail -c 8388608 -- "$transcript" | awk -f "${CONTEXT_AWK:-$hook_dir/../lib/context.awk}")
[[ "$tokens" =~ ^[0-9]+$ ]] || exit 0
step=$(( tokens / STEP_SIZE ))
(( step >= FIRST_STEP )) || exit 0

handled=0
[[ -f "$state_dir/$session" ]] && read -r handled < "$state_dir/$session"
[[ "$handled" =~ ^[0-9]+$ ]] || handled=0
(( step > handled )) || exit 0

write_state "$session" "$step"

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Context is %d tokens. Follow the hand-over rule in your brief."}}\n' "$tokens"
exit 0
