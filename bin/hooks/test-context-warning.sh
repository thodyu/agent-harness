#!/usr/bin/env bash
#
# Tests warn-orchestrator-context.sh by feeding it a Claude Code
# UserPromptSubmit payload on standard input, as the harness does, with a fake
# transcript and a fake herdr. Prints one line per case with its result and
# time, and exits 1 on any failure. Run: bash bin/hooks/test-context-warning.sh
#
# Run it in the background and wait for it. Every case starts a new bash, and
# starting a process is slow in Git Bash, so the run takes about a minute and a
# foreground call can time out or look like a hang. The cases run one after
# another, in the order of this file. Most are independent, but some read what
# the one before left, so keep these in order: the group of process cases,
# where a session's second prompt reads the verdict its first one wrote, the
# first group of the rest, where one session's context grows and each case
# reads its state file, the pair where herdr fails and then works again, and
# the group of odd input, where each case reads the herdr environment the first
# one set.
#
# The process cases prove "starts no process" by result. The hook runs with a
# PATH that holds only shims of tail, awk, timeout, herdr, mkdir and the other
# usual tools, each of which writes its name to a marks file, and the case
# passes only when the file stays empty. A canary case first shows that a shim
# does leave a mark. NEW_CASES_ONLY=1 stops after the process cases, for a quick
# run against a broken copy. HOOK_UNDER_TEST=<file> runs the cases against that
# copy of the hook.

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/warn-orchestrator-context.sh"
FAILED=0 COUNT=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

# A fake herdr: `agent get <pane>` prints the agent that FAKE_NAME and
# FAKE_SESSION describe, or fails when FAKE_FAIL is set. Each call is counted.
cat > "$WORK/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
[[ -n "${FAKE_FAIL:-}" ]] && exit 1
printf '{"id":"cli:agent:get","result":{"agent":{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"},"agent_status":"working","cwd":"C:\\\\work","name":"%s","pane_id":"%s","type":"agent_info"}}}\n' \
  "$FAKE_SESSION" "$FAKE_NAME" "$2"
EOF
chmod +x "$WORK/herdr"
export HERDR_BIN_PATH="$WORK/herdr" FAKE_CALLS="$WORK/calls" CONTEXT_HERDR_TIMEOUT=60

# An assistant line of the main chain whose context is the given total.
assistant() { # assistant <tokens>
  printf '{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-fable-5-1","id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":%d,"output_tokens":50,"iterations":[{"input_tokens":2,"cache_read_input_tokens":1}]}},"requestId":"req_1","type":"assistant","uuid":"u"}\n' \
    "$(( $1 - 1002 ))"
}
user() { printf '{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":"%s"}}\n' "$1"; }
meta() { printf '{"type":"last-prompt","lastPrompt":"go"}\n{"type":"ai-title","title":"x"}\n'; }

# TDIR is the folder of the transcripts and CWD_JSON the session's cwd as JSON
# holds it. A case that moves a session out of the dev-orchestrator folder sets
# both and puts them back.
DEFAULT_TDIR="$WORK/projects/C--work-orch"
TDIR="$DEFAULT_TDIR" CWD_JSON='C:\\work'

# transcript <session> <lines...>: writes the session's transcript, one
# argument a line, after the mode line that opens every real transcript.
transcript() {
  local file="$TDIR/$1.jsonl"
  shift
  mkdir -p "$TDIR"
  printf '%s\n' '{"type":"permission-mode","permissionMode":"auto"}' "$@" > "$file"
}

# payload <session>: a UserPromptSubmit payload whose transcript_path is a
# Windows path, escaped as Claude Code escapes it.
payload() {
  local path
  path=$(cygpath -w "$TDIR/$1.jsonl" 2>/dev/null || printf '%s' "$TDIR/$1.jsonl")
  path=${path//\\/\\\\}
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","permission_mode":"auto","hook_event_name":"UserPromptSubmit","prompt":"go"}' "$1" "$path" "$CWD_JSON"
}

warning() { printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"Context is %d tokens. Follow the hand-over rule in your brief."}}' "$1"; }

# check <label> <expected stdout> <input>, with the environment as set.
check() {
  local label="$1" want="$2" input="$3" out="$WORK/out" got start end ms
  start=${EPOCHREALTIME/[.,]/}
  bash "${HOOK_UNDER_TEST:-$HOOK}" > "$out" 2>&1 <<< "$input"
  got=$?
  end=${EPOCHREALTIME/[.,]/}
  ms=$(( (end - start) / 1000 ))
  COUNT=$((COUNT + 1))
  if [[ "$got" == 0 && "$(< "$out")" == "$want" ]]; then
    printf 'ok    exit %s  %4sms  %s\n' "$got" "$ms" "$label"
  else
    printf 'FAIL  exit %s  %4sms  %s\n        want: %s\n        got:  %s\n' "$got" "$ms" "$label" "${want:-<nothing>}" "$(< "$out")"
    FAILED=1
  fi
}
warns() { check "warn:   $1" "$(warning "$2")" "$3"; }
silent() { check "quiet:  $1" "" "$2"; }

orchestrator() { export HERDR_PANE_ID="w1:p1" FAKE_NAME="$1" FAKE_SESSION="$2"; unset FAKE_FAIL; }

# summary: the counts lines, and the exit status.
summary() {
  echo "$COUNT cases"
  if (( FAILED )); then
    echo "test-context-warning.sh: FAILED"
    exit 1
  fi
  echo "test-context-warning.sh: all cases passed"
  exit 0
}

# calls_are <n> <label>: herdr was asked n times since FAKE_CALLS was emptied.
calls_are() {
  local n=0
  while IFS= read -r _; do n=$((n + 1)); done < "$FAKE_CALLS"
  COUNT=$((COUNT + 1))
  if (( n == $1 )); then
    printf 'ok    %s herdr calls  %s\n' "$n" "$2"
  else
    printf 'FAIL  %s herdr calls, want %s  %s\n' "$n" "$1" "$2"
    FAILED=1
  fi
}

# The shims for the process cases. Each writes its name to $MARKS and fails, so
# a hook that starts one leaves a mark whatever it does with the result.
SHIMS="$WORK/shims" MARKS="$WORK/marks"
export MARKS
mkdir -p "$SHIMS"
for tool in tail awk timeout herdr mkdir cat sed grep head date wc tr sort cygpath rm; do
  # shellcheck disable=SC2016  # the shim holds a literal $MARKS
  printf '#!/usr/bin/bash\nprintf "%%s\\n" %s >> "$MARKS"\nexit 1\n' "$tool" > "$SHIMS/$tool"
  chmod +x "$SHIMS/$tool"
done

# marked <label> <input>: runs the hook with PATH holding only the shims. It
# passes when the hook exits 0, says nothing and no shim ran.
marked() {
  local label="$1" input="$2" got seen
  : > "$MARKS"
  PATH="$SHIMS" HERDR_BIN_PATH="$SHIMS/herdr" "$BASH" "${HOOK_UNDER_TEST:-$HOOK}" > "$WORK/out" 2>&1 <<< "$input"
  got=$?
  mapfile -t seen < "$MARKS"
  COUNT=$((COUNT + 1))
  if [[ "$got" == 0 && ! -s "$WORK/out" && ${#seen[@]} == 0 ]]; then
    printf 'ok    exit %s  no process  %s\n' "$got" "$label"
  else
    printf 'FAIL  exit %s  %s\n        started: %s\n        said:    %s\n' "$got" "$label" "${seen[*]:-<nothing>}" "$(< "$WORK/out")"
    FAILED=1
  fi
}

# The canary: a shim does leave a mark, so an empty marks file means something.
: > "$MARKS"
PATH="$SHIMS" "$BASH" -c 'tail x; awk x; herdr x' > /dev/null 2>&1
mapfile -t seen < "$MARKS"
COUNT=$((COUNT + 1))
if [[ "${seen[*]}" == "tail awk herdr" ]]; then
  printf 'ok    the shims leave a mark when a process starts\n'
else
  printf 'FAIL  the shims left: %s\n' "${seen[*]:-<nothing>}"
  FAILED=1
fi

# A session that is not an orchestrator: its first prompt asks herdr once and
# writes the verdict, and its later prompts start no process at all.
S=g0000000-0000-0000-0000-000000000001
orchestrator m1-hook $S
: > "$FAKE_CALLS"
transcript $S "$(user go)" "$(assistant 305000)" "$(meta)"
silent "worker, first prompt" "$(payload $S)"
calls_are 1 "a worker's first prompt asks herdr once"
marked "worker, second prompt" "$(payload $S)"
marked "worker, third prompt" "$(payload $S)"
orchestrator orch-renamed-later $S
silent "worker renamed into an orchestrator name after its first prompt stays quiet, the verdict is cached" "$(payload $S)"
calls_are 1 "and herdr was not asked again"

# A claude started inside an orchestrator's pane: herdr names the pane's agent
# with another session, which is no verdict yet. herdr learns a new session id
# late, after a /clear or a resume (the SessionStart hook reports it), so the
# next prompt asks again and the session is warned once herdr names it.
S=g0000000-0000-0000-0000-000000000006
orchestrator orch-retro-fixes 00000000-0000-4000-8000-000000000001
: > "$FAKE_CALLS"
transcript $S "$(assistant 305000)"
silent "orchestrator's pane, another session, first prompt" "$(payload $S)"
silent "orchestrator's pane, another session, second prompt" "$(payload $S)"
calls_are 2 "a pane whose agent has an orchestrator name asks herdr on each prompt"
orchestrator orch-retro-fixes $S
warns "herdr reports this session late, after two prompts that named another" 305000 "$(payload $S)"
silent "and the same step again" "$(payload $S)"
calls_are 3 "herdr is not asked again once it has named this session"

# A session outside Herdr: no transcript is read and no process starts, on the
# first prompt or any other.
S=g0000000-0000-0000-0000-000000000002
transcript $S "$(assistant 305000)" "$(meta)"
unset HERDR_PANE_ID
marked "outside Herdr, first prompt" "$(payload $S)"
marked "outside Herdr, second prompt" "$(payload $S)"

# An orchestrator whose transcript is outside the dev-orchestrator folder is
# still warned, so the folder is not the test.
S=g0000000-0000-0000-0000-000000000003
TDIR="$WORK/projects/C--work-apps-docs-site" CWD_JSON='C:\\work\\apps\\docs-site'
orchestrator orch-docs-3 $S
transcript $S "$(assistant 305000)" "$(meta)"
warns "orch-docs-3 in C:\\work\\apps\\docs-site" 305000 "$(payload $S)"
silent "orch-docs-3 again, same step" "$(payload $S)"
TDIR="$DEFAULT_TDIR" CWD_JSON='C:\\work'

# A sub-orchestrator whose transcript and cwd are Linux paths is warned the same way.
S=g0000000-0000-0000-0000-000000000011
TDIR="$WORK/projects/-srv-work-proj" CWD_JSON='/srv/work/proj'
orchestrator orch-proj-15 $S
transcript $S "$(assistant 305000)" "$(meta)"
warns "Linux: orch-proj-15 in /srv/work/proj" 305000 "$(payload $S)"
silent "Linux: orch-proj-15 again, same step" "$(payload $S)"
TDIR="$DEFAULT_TDIR" CWD_JSON='C:\\work'

# A warning fires once per step, and herdr is asked once for the whole session.
S=g0000000-0000-0000-0000-000000000004
orchestrator orch-retro-fixes $S
: > "$FAKE_CALLS"
transcript $S "$(assistant 250000)" "$(meta)"
silent "step: 250,000 tokens, under the line" "$(payload $S)"
transcript $S "$(assistant 250000)" "$(user more)" "$(assistant 305000)" "$(meta)"
warns "step: 305,000 tokens, past 300,000" 305000 "$(payload $S)"
silent "step: 305,000 tokens again" "$(payload $S)"
transcript $S "$(assistant 305000)" "$(user more)" "$(assistant 399999)" "$(meta)"
silent "step: 399,999 tokens, same step" "$(payload $S)"
transcript $S "$(assistant 399999)" "$(user more)" "$(assistant 400100)" "$(meta)"
warns "step: 400,100 tokens, the next step" 400100 "$(payload $S)"
silent "step: 400,100 tokens again" "$(payload $S)"
calls_are 1 "an orchestrator's session asks herdr once across six prompts"

# An orchestrator name whose session herdr has not reported yet gets no verdict,
# so the next prompt asks again.
S=g0000000-0000-0000-0000-000000000005
orchestrator orch-retro-fixes ""
: > "$FAKE_CALLS"
transcript $S "$(assistant 305000)" "$(meta)"
silent "orchestrator name, session not reported yet" "$(payload $S)"
orchestrator orch-retro-fixes $S
warns "the next prompt asks again and warns" 305000 "$(payload $S)"
calls_are 2 "asked on both prompts"

[[ -n "${NEW_CASES_ONLY:-}" ]] && summary

# One orchestrator session as its context grows. Its first prompt asks herdr
# once and the rest read the verdict.
S=a0000000-0000-0000-0000-000000000001
orchestrator dev-orchestrator-7 $S
: > "$FAKE_CALLS"
transcript $S "$(user go)" "$(assistant 250000)" "$(meta)"
silent "250,000 tokens, under the line" "$(payload $S)"
transcript $S "$(user go)" "$(assistant 250000)" "$(user more)" "$(assistant 299999)" "$(meta)"
silent "299,999 tokens, under the line" "$(payload $S)"
calls_are 1 "herdr asked on the first prompt only, none under the line after it"
transcript $S "$(user go)" "$(assistant 299999)" "$(user more)" "$(assistant 312457)" "$(meta)"
warns "312,457 tokens, past 300,000" 312457 "$(payload $S)"
silent "312,457 tokens again, same step" "$(payload $S)"
transcript $S "$(assistant 312457)" "$(user more)" "$(assistant 399999)" "$(meta)"
silent "399,999 tokens, same step" "$(payload $S)"
transcript $S "$(assistant 399999)" "$(user more)" "$(assistant 400001)" "$(meta)"
warns "400,001 tokens, the next step" 400001 "$(payload $S)"
silent "400,001 tokens again" "$(payload $S)"
transcript $S "$(assistant 400001)" "$(user more)" "$(assistant 712000)" "$(meta)"
warns "712,000 tokens, a jump over two steps warns once" 712000 "$(payload $S)"
transcript $S "$(assistant 712000)" "$(user more)" "$(assistant 799000)" "$(meta)"
silent "799,000 tokens, same step as 712,000" "$(payload $S)"
transcript $S "$(assistant 799000)" "$(user compacted)" "$(assistant 120000)" "$(meta)"
silent "120,000 tokens after a compact" "$(payload $S)"
transcript $S "$(assistant 120000)" "$(user more)" "$(assistant 512000)" "$(meta)"
silent "512,000 tokens after a compact, under the highest step handled" "$(payload $S)"

# Each orchestrator name, and look-alikes that are workers.
n=10
for name in dev-orchestrator dev-orchestrator-12 orch-retro-fixes orch-example-round1 orch-example-round1-2 Orch-Retro-Fixes; do
  S=b00000$n-0000-0000-0000-000000000000
  orchestrator "$name" $S
  transcript $S "$(assistant 305000)"
  warns "named $name" 305000 "$(payload $S)"
  n=$((n + 1))
done
for name in m1-hook rev-m1 worker-11 dev-orchestrator-x my-dev-orchestrator orchestrator orch- "" ; do
  S=c00000$n-0000-0000-0000-000000000000
  orchestrator "$name" $S
  transcript $S "$(assistant 305000)"
  silent "named '${name}', not an orchestrator" "$(payload $S)"
  n=$((n + 1))
done

# Not this pane's session: a claude started inside an orchestrator's pane.
S=d0000000-0000-0000-0000-000000000001
orchestrator orch-retro-fixes 00000000-0000-4000-8000-000000000001
transcript $S "$(assistant 305000)"
silent "orchestrator's pane, another session" "$(payload $S)"

# Outside Herdr.
S=d0000000-0000-0000-0000-000000000002
transcript $S "$(assistant 305000)"
unset HERDR_PANE_ID
silent "no HERDR_PANE_ID" "$(payload $S)"

# herdr fails: nothing, nothing remembered, and the next prompt asks again.
S=d0000000-0000-0000-0000-000000000003
orchestrator orch-retro-fixes $S
transcript $S "$(assistant 305000)"
export FAKE_FAIL=1
silent "herdr fails" "$(payload $S)"
unset FAKE_FAIL
warns "herdr works again on the next prompt" 305000 "$(payload $S)"

# Lines that must not count.
S=e0000000-0000-0000-0000-000000000001
orchestrator orch-retro-fixes $S
transcript $S "$(assistant 250000)" "$(assistant 900000 | sed 's/"isSidechain":false/"isSidechain":true/')" "$(meta)"
silent "a sidechain line past the line" "$(payload $S)"
transcript $S "$(assistant 250000)" "$(assistant 900000 | sed 's/claude-fable-5-1/<synthetic>/')" "$(meta)"
silent "a <synthetic> line past the line" "$(payload $S)"
transcript $S "$(assistant 250000)" '{"type":"attachment","attachment":{"usage":{"input_tokens":900000,"cache_read_input_tokens":900000,"cache_creation_input_tokens":0}}}' "$(meta)"
silent "an attachment with usage past the line" "$(payload $S)"
transcript $S "$(assistant 250000)" "$(user 'the model wrote \"type\":\"assistant\",\"requestId\":\"req_9\",\"input_tokens\":900000')" "$(meta)"
silent "a user line quoting an assistant line" "$(payload $S)"

# Big transcripts: a 3 MB line after the last assistant line is read past, and
# 9 MB is past the window.
S=e0000000-0000-0000-0000-000000000002
orchestrator orch-retro-fixes $S
big=$(head -c 3000000 /dev/zero | tr '\0' x)
transcript $S "$(assistant 305000)" "$(user "$big")" "$(meta)"
warns "305,000 tokens behind a 3 MB tool result" 305000 "$(payload $S)"
S=e0000000-0000-0000-0000-000000000003
orchestrator orch-retro-fixes $S
big=$(head -c 9000000 /dev/zero | tr '\0' x)
transcript $S "$(assistant 305000)" "$(user "$big")" "$(meta)"
silent "305,000 tokens behind a 9 MB tool result, past the window" "$(payload $S)"
big=""

# Missing, unreadable and odd input.
S=f0000000-0000-0000-0000-000000000001
orchestrator orch-retro-fixes $S
silent "missing transcript" "$(payload $S)"
mkdir -p "$TDIR/$S.jsonl"
silent "transcript path is a folder" "$(payload $S)"
S=f0000000-0000-0000-0000-000000000002
orchestrator orch-retro-fixes $S
transcript $S 'not json at all {'$'\n' "$(meta)"
silent "transcript with no assistant line" "$(payload $S)"
S=f0000000-0000-0000-0000-000000000003
transcript $S "$(assistant 305000 | sed 's/"cache_creation_input_tokens":1000,//')"
silent "assistant line missing a usage field" "$(payload $S)"
silent "empty input" ""
silent "input that is not JSON" "not json at all {"
silent "payload with no transcript_path" '{"session_id":"f0000000-0000-0000-0000-000000000004","hook_event_name":"UserPromptSubmit"}'
transcript "f0000000-0000-0000-0000-000000000005" "$(assistant 305000)"
silent "session id that is a path" "$(payload f0000000-0000-0000-0000-000000000005 | sed 's/"session_id":"[^"]*"/"session_id":"..\/..\/x"/')"

# A state file that holds rubbish counts as no step handled.
S=f0000000-0000-0000-0000-000000000006
orchestrator orch-retro-fixes $S
transcript $S "$(assistant 305000)"
mkdir -p "$TMPDIR/claude-context-warning"
printf 'rubbish\n' > "$TMPDIR/claude-context-warning/$S"
warns "a state file of rubbish" 305000 "$(payload $S)"

# The file parses, and a broken copy, with a syntax error just after its trap
# line or in its middle, exits 0 with nothing on standard output.
COUNT=$((COUNT + 1))
if bash -n "$HOOK" && bash -n "${BASH_SOURCE[0]}"; then
  printf 'ok    bash -n parses the hook and this test\n'
else
  printf 'FAIL  bash -n\n'
  FAILED=1
fi
S=f0000000-0000-0000-0000-000000000007
orchestrator orch-retro-fixes $S
transcript $S "$(assistant 305000)"
half=$(( $(wc -l < "$HOOK") / 2 ))
sed "${half}a if then fi ((" "$HOOK" > "$WORK/middle.sh"
sed "4a if then fi ((" "$HOOK" > "$WORK/early.sh"
for broken in "$WORK/middle.sh" "$WORK/early.sh"; do
  HOOK_UNDER_TEST="$broken" silent "broken copy ${broken##*/} says nothing and exits 0" "$(payload $S)"
done

summary
