#!/usr/bin/env bash
# Tests check-state-file.sh by feeding it a Claude Code PostToolUse payload on
# standard input, as the harness does. Scratch state files live in the test's own
# mktemp folder, which the hook takes as its root through STATE_HOOK_ROOT.
# Prints one line per case, a counts line, and exits 1 on any failure.
# Run: bash bin/hooks/test-state-hook.sh

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${STATE_HOOK:-$HERE/check-state-file.sh}" # STATE_HOOK=<path> tests another copy
REAL_CHECK=C:/work/orch/bin/state-check.sh
# On Linux the check is the state-check.sh beside the hooks folder.
ON_WIN=0
[[ -r /proc/$$/winpid ]] && ON_WIN=1
[[ $ON_WIN -eq 1 ]] || REAL_CHECK="$HERE/../state-check.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM
PASS=0 FAILED=0
MAXMS=0 # a case fails when it takes longer than this many ms, 0 for no limit

ROOT="$WORK/root"
mkdir -p "$ROOT/sub" "$WORK/other"
if [[ $ON_WIN -eq 1 ]]; then
  ROOT_WIN=$(cygpath -w "$ROOT")
  ROOT_MIXED=$(cygpath -m "$ROOT")
else
  # Linux has one form of a path, so both names are the path itself.
  ROOT_WIN=$ROOT
  ROOT_MIXED=$ROOT
fi
[[ -f $REAL_CHECK ]] || echo "test-state-hook.sh: no state-check.sh at $REAL_CHECK, so the cases that run it fail" >&2

good='# State

## Where things stand

## Threads

## Open for the owner

## Recurring problems

## Next move

## Updates

- line
'
broken='# State

## Where things stand

## Threads

## Open for the owner

## Next move

## Updates

- line
'
printf '%s' "$good" >"$ROOT/good-state.md"
mkdir -p "$ROOT/good" "$ROOT/bad" "$WORK/other/bad"
printf '%s' "$good" >"$ROOT/good/state.md"
printf '%s' "$broken" >"$ROOT/bad/state.md"
printf '%s' "$broken" >"$ROOT/sub/notes.md"
printf '%s' "$broken" >"$WORK/other/bad/state.md"
# Linux tells STATE.md from state.md, so the case of a name in another case needs a file of its own there.
[[ $ON_WIN -eq 1 ]] || printf '%s' "$broken" >"$ROOT/bad/STATE.md"

# json_path <path>: JSON is the path as a JSON string with backslashes doubled
json_path() { local s=${1//\\/\\\\}; printf -v JSON '"%s"' "$s"; }

# payload <tool> <path>: PAYLOAD is a PostToolUse payload, with a decoy path in the content
payload() {
  json_path "$2"
  printf -v PAYLOAD '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":%s,"content":"x \\"file_path\\": \\"C:\\\\work\\\\orch\\\\state.md\\""},"tool_response":{"success":true}}' "$1" "$JSON"
}

# run <case> <want exit> <want text in output, or "-" for silence> <payload> [VAR=value ...]
run() {
  local label=$1 want=$2 text=$3 input=$4 out got start ms
  shift 4
  start=${EPOCHREALTIME/[.,]/}
  if [[ $input == @* ]]; then # the payload is in this file
    out=$(env "$@" "$BASH" "$HOOK" 2>&1 <"${input#@}")
  else
    out=$(env "$@" "$BASH" "$HOOK" 2>&1 <<<"$input")
  fi
  got=$?
  ms=$(((${EPOCHREALTIME/[.,]/} - start) / 1000))
  LAST_MS=$ms
  if [[ $got -eq $want && ( ( $text == - && -z $out ) || ( $text != - && $out == *"$text"* ) ) ]] &&
    ((MAXMS == 0 || ms <= MAXMS)); then
    echo "PASS $label (${ms} ms)"
    PASS=$((PASS + 1))
  else
    echo "FAIL $label (exit $got, want $want, ${ms} ms, limit ${MAXMS} ms, output: $out)"
    FAILED=$((FAILED + 1))
  fi
}

env_root=(STATE_HOOK_ROOT="$ROOT_WIN" STATE_CHECK_SCRIPT="$REAL_CHECK")

payload Write "$ROOT_MIXED/sub/notes.md"
run "a file that is not state.md passes silently" 0 - "$PAYLOAD" "${env_root[@]}"

payload Edit "$ROOT_WIN\\sub\\notes.md"
run "an Edit of a file that is not state.md passes silently" 0 - "$PAYLOAD" "${env_root[@]}"

payload Write "$WORK/other/bad/state.md"
run "a broken state.md outside the folder passes silently" 0 - "$PAYLOAD" "${env_root[@]}"

payload Write "$ROOT_MIXED/good/state.md"
run "a good state.md passes silently" 0 - "$PAYLOAD" "${env_root[@]}"

payload Write "$ROOT_MIXED/bad/state.md"
run "a broken state.md prints the rule and exits 2" 2 "'## Recurring problems' is missing" "$PAYLOAD" "${env_root[@]}"
run "the first line names the file" 2 "state-check failed for $ROOT_MIXED/bad/state.md:" "$PAYLOAD" "${env_root[@]}"

payload Edit "$ROOT_WIN\\bad\\state.md"
run "a backslash path is matched" 2 "is missing" "$PAYLOAD" "${env_root[@]}"

if [[ $ON_WIN -eq 1 ]]; then
  payload Edit "${ROOT_MIXED/#?/c}/bad/state.md"
  run "a lower case drive letter is matched" 2 "is missing" "$PAYLOAD" "${env_root[@]}"

  payload Edit "${ROOT_MIXED/#?/C}/bad/state.md"
  run "an upper case drive letter is matched" 2 "is missing" "$PAYLOAD" "${env_root[@]}"
else
  echo "SKIP the two drive letter cases (Linux has no drive letter)"
fi

# STATE_HOOK_ROOT may be a Linux folder, with the check beside the hooks.
payload Write "$ROOT/bad/state.md"
run "Linux: a broken state.md under a Linux root exits 2 and names the file" 2 "state-check failed for $ROOT/bad/state.md:" "$PAYLOAD" STATE_HOOK_ROOT="$ROOT" STATE_CHECK_SCRIPT="$REAL_CHECK"
payload Write "$ROOT/good/state.md"
run "Linux: a good state.md under a Linux root passes silently" 0 - "$PAYLOAD" STATE_HOOK_ROOT="$ROOT" STATE_CHECK_SCRIPT="$REAL_CHECK"
payload Write "$WORK/other/bad/state.md"
run "Linux: a broken state.md outside the Linux root passes silently" 0 - "$PAYLOAD" STATE_HOOK_ROOT="$ROOT" STATE_CHECK_SCRIPT="$REAL_CHECK"

payload Write "$ROOT_MIXED/bad/STATE.md"
run "the name is matched in any case" 2 "is missing" "$PAYLOAD" "${env_root[@]}"

payload Write "$ROOT_MIXED/bad/state.md.bak"
run "state.md.bak is not a state file" 0 - "$PAYLOAD" "${env_root[@]}"

payload Write "$ROOT_MIXED/bad/old-state.md"
run "old-state.md is not a state file" 0 - "$PAYLOAD" "${env_root[@]}"

payload Write "$ROOT_MIXED-two/bad/state.md"
run "a sibling folder with the same prefix is not under the root" 0 - "$PAYLOAD" "${env_root[@]}"

printf '%s\n' '#!/usr/bin/env bash' 'echo "stub rule"' 'exit 1' >"$WORK/stub.sh"
payload Write 'C:\work\orch\change-set-x\state.md'
run "the default root is ORCH_HOME" 2 "stub rule" "$PAYLOAD" ORCH_HOME='C:\work\orch' STATE_CHECK_SCRIPT="$WORK/stub.sh"
payload Write 'C:\work\proj\state.md'
run "a state.md in another folder passes silently" 0 - "$PAYLOAD" ORCH_HOME='C:\work\orch' STATE_CHECK_SCRIPT="$WORK/stub.sh"
run "with no root at all the hook does nothing" 0 - "$PAYLOAD" STATE_CHECK_SCRIPT="$WORK/stub.sh"

payload Write "$ROOT_MIXED/bad/state.md"
run "a missing check script exits 0" 0 - "$PAYLOAD" STATE_HOOK_ROOT="$ROOT_WIN" STATE_CHECK_SCRIPT="$WORK/nope.sh"

printf '%s\n' '#!/usr/bin/env bash' 'exit 3' >"$WORK/crash.sh"
run "a check that crashes exits 0" 0 - "$PAYLOAD" STATE_HOOK_ROOT="$ROOT_WIN" STATE_CHECK_SCRIPT="$WORK/crash.sh"

run "malformed JSON exits 0" 0 - '{"tool_input":{"file_path":' "${env_root[@]}"
run "empty input exits 0" 0 - '' "${env_root[@]}"
run "JSON with no file_path exits 0" 0 - '{"tool_name":"Write","tool_input":{}}' "${env_root[@]}"

# No process for another file: with an empty PATH any attempt to start one prints
# "command not found" or a fork error, and the case fails on any output.
payload Write "$ROOT_MIXED/sub/notes.md"
run "another file starts no process" 0 - "$PAYLOAD" "${env_root[@]}" PATH=/nonexistent
payload Write "$WORK/other/bad/state.md"
run "a state.md outside the folder starts no process" 0 - "$PAYLOAD" "${env_root[@]}" PATH=/nonexistent

# A payload of about 1 MB, file_path first as the harness writes it. The hook must
# decide from the start of it and not read the rest (it runs on every Write).
chunk=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
big=""
for ((i = 0; i < 8192; i++)); do big+=$chunk; done
# big_payload <tool> <path>: PAYLOAD is "@" and the name of a file holding the
# path and then the 1 MB of content, which run reads as standard input
big_payload() {
  json_path "$2"
  printf '{"session_id":"test","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"file_path":%s,"content":"%s"},"tool_response":{"success":true}}' "$1" "$JSON" "${3-$big}" >"$WORK/big.json"
  PAYLOAD=@$WORK/big.json
}

# The limit is relative, so that a loaded machine does not fail a correct hook: three
# times the time of a 1 KB payload in this run, and at least 1.5 s. A hook that reads
# the whole 1 MB took 1.8 to 2.3 s on a quiet machine, against 0.4 to 0.9 s for this one.
big_payload Write "$ROOT_MIXED/sub/notes.md" "${big:0:1024}"
run "a 1 KB Write of another file passes silently (the baseline)" 0 - "$PAYLOAD" "${env_root[@]}"
MAXMS=$((LAST_MS * 3))
((MAXMS < 1500)) && MAXMS=1500
echo "     limit for the 1 MB cases: ${MAXMS} ms (three times ${LAST_MS} ms, at least 1500 ms)"
big_payload Write "$ROOT_MIXED/bad/state.md"
run "a 1 MB Write of a broken state.md still exits 2, within the limit" 2 "is missing" "$PAYLOAD" "${env_root[@]}"
big_payload Write "$ROOT_MIXED/good/state.md"
run "a 1 MB Write of a good state.md is silent, within the limit" 0 - "$PAYLOAD" "${env_root[@]}"
big_payload Write "$ROOT_MIXED/sub/notes.md"
run "a 1 MB Write of another file passes silently, within the limit" 0 - "$PAYLOAD" "${env_root[@]}"
run "a 1 MB Write of another file starts no process, within the limit" 0 - "$PAYLOAD" "${env_root[@]}" PATH=/nonexistent
MAXMS=0

echo "passed $PASS, failed $FAILED"
((FAILED == 0))
