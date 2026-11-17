#!/usr/bin/env bash
# shellcheck disable=SC2016  # the cases are commands taken literally, $ and all
#
# Tests refuse-kill-by-name.sh, refuse-merge-default-body.sh,
# refuse-python-heredoc.sh, refuse-unsafe-shell.sh and refuse-shell-edits.sh by
# feeding each a Claude Code PreToolUse payload on standard input, as the harness
# does. refuse-dev-vars-print.sh and refuse-dev-vars.sh have a test of their own,
# test-dev-vars.sh, and are only run here as parts of the one-bash file.
# Prints one line per case with its result and time, and exits 1 on any
# failure. Run: bash bin/hooks/test-command-hooks.sh
#
# Run it in the background and wait for it. Every case starts a new bash, and
# starting a process is slow in Git Bash, so the run takes several minutes and a
# foreground call can time out or look like a hang. The cases run one after
# another, in the order of this file.
#
# The last group of cases tests refuse-command-hooks.sh, the one bash that runs
# the six hooks and that settings.json registers in their place.
#
# To prove a case can fail, point the test at a broken copy of a hook with
# KILL_HOOK, MERGE_HOOK, PY_HOOK, UNSAFE_HOOK, EDITS_HOOK, PRINT_HOOK or
# ALL_HOOK. A copy needs lib/ beside it, and a copy of the one-bash file needs
# the six hooks beside it too. NEW_CASES_ONLY=1 skips every group before the
# last, for a quick run against a broken copy of the one-bash file.
# H_CASES_ONLY=1 runs only the cases of the shell edits, python - and the one-bash file, a few minutes against the whole file, for a
# quick run against a broken copy of one of those hooks. H_CASES_ONLY=edits runs
# only the shell edits and python -, and H_CASES_ONLY=onebash only the one-bash
# file. H_FILTER=<text> runs only the checks of the command cases whose label
# holds the text (the one-bash cases of same_as and the loops ignore it).

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A run that skips cases says so, so a stray variable cannot pass for a whole run.
for skipper in NEW_CASES_ONLY H_CASES_ONLY H_FILTER; do
  [[ -z "${!skipper:-}" ]] || echo "test-command-hooks.sh: $skipper is set, so this run skips cases" >&2
done
KILL="${KILL_HOOK:-$HERE/refuse-kill-by-name.sh}"
MERGE="${MERGE_HOOK:-$HERE/refuse-merge-default-body.sh}"
PY="${PY_HOOK:-$HERE/refuse-python-heredoc.sh}"
UNSAFE="${UNSAFE_HOOK:-$HERE/refuse-unsafe-shell.sh}"
EDITS="${EDITS_HOOK:-$HERE/refuse-shell-edits.sh}"
PRINT="${PRINT_HOOK:-$HERE/refuse-dev-vars-print.sh}"
ALL="${ALL_HOOK:-$HERE/refuse-command-hooks.sh}"
# The one-bash file runs refuse-npx.sh too, so the parts below, the timed run
# and the broken copies hold seven hooks. test-linux-hooks.sh beside it holds the
# Linux cases. The library skips sudo, timeout, nice and busybox.
NPX="${NPX_HOOK:-$HERE/refuse-npx.sh}"
# Every hook file the one-bash file runs, in its order.
PARTS=(refuse-kill-by-name.sh refuse-merge-default-body.sh refuse-python-heredoc.sh refuse-npx.sh refuse-unsafe-shell.sh refuse-dev-vars-print.sh refuse-shell-edits.sh)
FAILED=0 COUNT=0
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
trap 'exit 1' INT TERM
BROKEN="$WORK/broken"
ERR="$WORK/err"

# json_string <text>: JSON is the text as a JSON string. No command
# substitution, because each one costs a process.
json_string() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf -v JSON '"%s"' "$s"
}

payload() { # payload <tool> <command>: PAYLOAD is the PreToolUse payload
  json_string "$2"
  printf -v PAYLOAD '{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":%s,"description":"test"}}' \
    "$1" "$JSON"
}

# check <hook> <expected exit> <label> <payload>
check() {
  local hook="$1" want="$2" label="$3" input="$4" got start end ms
  # H_FILTER=<text> runs only the cases whose label holds the text, for a broken
  # copy that should fail one of them.
  [[ -z "${H_FILTER:-}" || "$label" == *"$H_FILTER"* ]] || return 0
  start=${EPOCHREALTIME/[.,]/}
  bash "$hook" 2>"$ERR" >/dev/null <<< "$input"
  got=$?
  end=${EPOCHREALTIME/[.,]/}
  ms=$(( (end - start) / 1000 ))
  COUNT=$((COUNT + 1))
  if [[ "$got" == "$want" ]]; then
    printf 'ok    exit %s  %4sms  %-6s %s\n' "$got" "$ms" "${hook##*/refuse-}" "$label"
  else
    printf 'FAIL  exit %s (want %s)  %4sms  %s  %s\n' "$got" "$want" "$ms" "${hook##*/}" "$label"
    sed 's/^/        /' "$ERR"
    failed
  fi
}

refused() { payload "$2" "$3"; check "$1" 2 "refuse: $3 [$2]" "$PAYLOAD"; }
passes() { payload "$2" "$3"; check "$1" 0 "pass:   $3 [$2]" "$PAYLOAD"; }

# failed: a case failed. STOP_ON_FAIL=1 ends the run there, which is enough to
# show that a broken copy is caught.
failed() {
  FAILED=1
  [[ -z "${STOP_ON_FAIL:-}" ]] || finish
}

finish() {
  echo "$COUNT cases"
  if (( FAILED )); then
    echo "test-command-hooks.sh: FAILED"
    exit 1
  fi
  echo "test-command-hooks.sh: all cases passed"
  exit 0
}

# says <hook> <tool> <command> <text>: the hook refuses with exit 2, and its
# message holds the text.
says() {
  [[ -z "${H_FILTER:-}" || "$3" == *"$H_FILTER"* ]] || return 0
  payload "$2" "$3"
  COUNT=$((COUNT + 1))
  bash "$1" 2>"$ERR" >/dev/null <<< "$PAYLOAD"
  if [[ $? == 2 && "$(< "$ERR")" == *"$4"* ]]; then
    printf 'ok    message names %s  %s\n' "$4" "$3"
  else
    printf 'FAIL  message for %s lacks %s\n' "$3" "$4"
    sed 's/^/        /' "$ERR"
    failed
  fi
}

# median_of_five <array name>: MEDIAN is the middle of the five numbers in the
# array, by a sort in the shell, so no process starts.
median_of_five() {
  local -n arr=$1
  local -a s=("${arr[@]}")
  local i j t
  for (( i = 1; i < ${#s[@]}; i++ )); do
    t=${s[i]}
    for (( j = i - 1; j >= 0 && s[j] > t; j-- )); do s[j + 1]=${s[j]}; done
    s[j + 1]=$t
  done
  MEDIAN=${s[2]}
}

# The one-bash file, refuse-command-hooks.sh: the seven hooks as one registered
# entry. It has to refuse what each hook refuses, with that hook's message and
# exit 2, pass what they pass, and fail open on a broken part.
one_bash_cases() {
  local tool part where dir n half line f got
  local -a cmds

  # Cost. The defect to catch is seven bash starts: the settings used to
  # register the hooks each on its own, and each start costs seconds under
  # load. In each of five rounds the six hooks are run separately, one after
  # another, and then the one file, with the same payload and in the same run,
  # so a slow machine slows both. The median of the five runs of the one file
  # must be under half the median of the five runs of the six. A bare bash -c :
  # is timed too, for the line only. A copy that starts one bash a hook cannot
  # pass it. The payload has a redirect to /dev/null, so the new redirect check
  # runs on it.
  local -a separate_ms=() all_ms=() bare_ms=()
  local start end round
  payload Bash 'cd /c/work/proj && git log --oneline -5 | head -5 && ls -la > /dev/null 2>&1 && echo "done $(date)"'
  for (( round = 0; round < 5; round++ )); do
    start=${EPOCHREALTIME/[.,]/}
    bash -c :
    end=${EPOCHREALTIME/[.,]/}
    bare_ms+=( $(( (end - start) / 1000 )) )
    start=${EPOCHREALTIME/[.,]/}
    for f in "$KILL" "$MERGE" "$PY" "$NPX" "$UNSAFE" "$PRINT" "$EDITS"; do
      bash "$f" > /dev/null 2>&1 <<< "$PAYLOAD"
    done
    end=${EPOCHREALTIME/[.,]/}
    separate_ms+=( $(( (end - start) / 1000 )) )
    start=${EPOCHREALTIME/[.,]/}
    bash "$ALL" > /dev/null 2>&1 <<< "$PAYLOAD"
    end=${EPOCHREALTIME/[.,]/}
    all_ms+=( $(( (end - start) / 1000 )) )
  done
  median_of_five bare_ms; local bare_med=$MEDIAN
  median_of_five separate_ms; local separate_med=$MEDIAN
  median_of_five all_ms; local all_med=$MEDIAN
  COUNT=$((COUNT + 1))
  if (( all_med * 2 < separate_med )); then
    printf 'ok    one bash costs %sms, the six hooks run separately cost %sms, limit half (bare bash -c : %sms)\n' "$all_med" "$separate_med" "$bare_med"
  else
    printf 'FAIL  one bash costs %sms, the six hooks run separately cost %sms, limit half (bare bash -c : %sms)\n' "$all_med" "$separate_med" "$bare_med"
    failed
  fi

  # Each refusal comes through with the message and exit of the hook that makes it.
  same_as() { # same_as <hook> <tool> <command>
    local want got
    payload "$2" "$3"
    COUNT=$((COUNT + 1))
    bash "$1" 2>"$ERR" >/dev/null <<< "$PAYLOAD"
    want=$?
    bash "$ALL" 2>"$ERR.all" >/dev/null <<< "$PAYLOAD"
    got=$?
    if [[ "$want" == 2 && "$got" == 2 && -s "$ERR" && "$(< "$ERR")" == "$(< "$ERR.all")" ]]; then
      printf 'ok    one bash refuses as %s does  %s [%s]\n' "${1##*/}" "$3" "$2"
    else
      printf 'FAIL  one bash: exit %s, %s alone exits %s  %s [%s]\n' "$got" "${1##*/}" "$want" "$3" "$2"
      sed 's/^/        alone:    /' "$ERR"
      sed 's/^/        one bash: /' "$ERR.all"
      failed
    fi
  }
  for tool in Bash PowerShell; do
    same_as "$KILL" $tool 'taskkill /IM node.exe /F'
    same_as "$KILL" $tool 'cd C:/work/proj; taskkill /IM workerd.exe'
    same_as "$MERGE" $tool 'gh pr merge 1 --squash'
    same_as "$MERGE" $tool 'gh pr merge 1 --repo example-org/x --squash --subject x'
    same_as "$UNSAFE" $tool 'git push | tail -3'
  done
  same_as "$KILL" PowerShell 'Stop-Process -Name node -Force'
  same_as "$KILL" PowerShell 'Get-Process node | Stop-Process'
  same_as "$PY" Bash $'python3 - <<EOF\nprint(1)\nEOF'
  same_as "$PY" Bash $'cat <<EOF | python\nprint(1)\nEOF'
  same_as "$PY" PowerShell $'@\'\nprint(1)\n\'@ | python3 -'
  same_as "$UNSAFE" Bash 'rm -rf "$d/build"'
  same_as "$UNSAFE" Bash 'echo x > "$T/out"'
  same_as "$UNSAFE" Bash 'bash -c '\''rm -rf "$d/x"'\'''
  # The shell edits hook and the python - rule: every check is run by the one file.
  for tool in Bash PowerShell; do
    same_as "$EDITS" $tool "sed -i 's/a/b/' C:/work/x/state.md"
    same_as "$EDITS" $tool 'echo x >> C:/work/x/state.md'
    same_as "$EDITS" $tool 'echo x | tee C:/work/x/out.txt'
    same_as "$PRINT" $tool 'cat store/.dev.vars'
    same_as "$PY" $tool 'python -'
  done
  same_as "$EDITS" Bash $'cat > notes.md <<\'EOF\'\nbody\nEOF'
  same_as "$EDITS" Bash "bash -c 'sed -i s/a/b/ C:/work/x/f.sh'"
  same_as "$PRINT" PowerShell 'Get-Content .\.dev.vars'
  same_as "$PRINT" Bash "bash -c 'head -3 .dev.vars'"

  # Each hook's own wording is what the agent reads.
  says "$ALL" Bash 'taskkill /IM node.exe' 'kills by process name'
  says "$ALL" PowerShell 'Stop-Process -Name node' 'by process id'
  says "$ALL" Bash 'gh pr merge 1 --squash' 'without both --subject and --body'
  says "$ALL" Bash $'python - <<\'EOF\'\nprint(1)\nEOF' '120 second'
  says "$ALL" Bash 'rm -rf "$d/build"' '${WORK:?}'
  says "$ALL" Bash 'git push | tail -3' 'PIPESTATUS[0]'
  says "$ALL" Bash "sed -i 's/a/b/' C:/work/x/state.md" 'Use the Edit tool to change a file'
  says "$ALL" Bash 'echo x >> C:/work/x/state.md' 'the Write tool to make a new one'
  says "$ALL" Bash 'python -' 'harness'"'"'s timeout'
  says "$ALL" Bash 'cat .dev.vars' 'grep -c'

  # A clean command passes, and so do other tools and unreadable input.
  for tool in Bash PowerShell; do
    passes "$ALL" $tool 'ls; echo done'
    passes "$ALL" $tool 'git status'
    passes "$ALL" $tool 'taskkill /PID 999999'
    passes "$ALL" $tool 'gh pr merge 1 --squash --subject x --body y'
    passes "$ALL" $tool 'python3 -c "print(1)"'
    passes "$ALL" $tool 'git push 2>&1 | Select-Object -Last 3'
    passes "$ALL" $tool 'git log --oneline | head -5'
  done
  passes "$ALL" Bash 'rm -rf "${WORK:?}/build"'
  passes "$ALL" Bash 'echo hi > "${T:?}/out"'
  passes "$ALL" Bash 'sed -i s/a/b/ /tmp/x'
  passes "$ALL" Bash 'echo x >> /tmp/log 2>&1'
  passes "$ALL" Bash 'echo x | tee /dev/stderr'
  passes "$ALL" Bash 'python - < script.py'
  passes "$ALL" Bash 'cat s.py | python -'
  passes "$ALL" Bash "grep -c '^KEY=' .dev.vars"
  check "$ALL" 0 "pass:   Write of a brief naming every command" \
    '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/brief.md","content":"taskkill /IM node.exe\ngh pr merge 1 --squash\nrm -rf $T/*\ngit push | tail -3\nsed -i s/a/b/ state.md\ncat .dev.vars\npython -\necho x >> state.md"}}'

  # No new process. The one file runs every check with no program on the path,
  # so a call to any program outside bash itself would print an error. A clean
  # command that reaches the new checks passes in silence, and a command a new
  # check refuses is still refused with its own message. (A fork of bash itself
  # is timed by the cost case above.)
  local clean_cmd refused_cmd
  local -a errlines
  clean_cmd=$'sed -i s/a/b/ /tmp/x\necho x >> /tmp/log 2>&1\necho x | tee /dev/stderr\npython - < script.py\ncat s.py | python -\ngrep -c ^KEY= .dev.vars\nls > /dev/null 2>&1'
  payload Bash "$clean_cmd"
  COUNT=$((COUNT + 1))
  PATH='' "$BASH" "$ALL" 2>"$ERR" >/dev/null <<< "$PAYLOAD"
  got=$?
  if [[ "$got" == 0 && ! -s "$ERR" ]]; then
    printf 'ok    with no program on the path, a clean command that reaches every new check exits 0 and says nothing\n'
  else
    printf 'FAIL  with no program on the path: exit %s, standard error holds something\n' "$got"
    sed 's/^/        /' "$ERR"
    failed
  fi
  for refused_cmd in "sed -i s/a/b/ C:/work/x/f.md" 'echo x >> C:/work/x/state.md' 'echo x | tee C:/work/x/out.txt' 'python -' 'cat .dev.vars'; do
    payload Bash "$refused_cmd"
    COUNT=$((COUNT + 1))
    PATH='' "$BASH" "$ALL" 2>"$ERR" >/dev/null <<< "$PAYLOAD"
    got=$?
    mapfile -t errlines < "$ERR"
    if [[ "$got" == 2 && "${errlines[0]:-}" == Refused:* && "$(< "$ERR")" != *"command not found"* ]]; then
      printf 'ok    with no program on the path, %s is refused with its own message\n' "$refused_cmd"
    else
      printf 'FAIL  with no program on the path: %s exits %s\n' "$refused_cmd" "$got"
      sed 's/^/        /' "$ERR"
      failed
    fi
  done
  check "$ALL" 0 "pass:   input that is not JSON" 'not json at all {'
  check "$ALL" 0 "pass:   empty input" ''
  check "$ALL" 0 "pass:   payload with no command" '{"tool_name":"Bash","tool_input":{}}'

  # A broken part fails open, and the parts around it still refuse. Each broken
  # copy is a folder with all seven files and the library, one of them with a
  # syntax error just after its first line that is not a comment or in its
  # middle.
  COUNT=$((COUNT + 1))
  if bash -n "$ALL"; then
    printf 'ok    bash -n parses %s\n' "${ALL#"$HERE"/}"
  else
    printf 'FAIL  bash -n %s\n' "${ALL#"$HERE"/}"
    failed
  fi
  # Each part's own refusal: a command that no other part refuses.
  local -A own=(
    [refuse-kill-by-name.sh]='taskkill /IM node.exe'
    [refuse-merge-default-body.sh]='gh pr merge 1 --squash'
    [refuse-python-heredoc.sh]=$'python3 - <<EOF\nprint(1)\nEOF'
    [refuse-npx.sh]='npx foo'
    [refuse-unsafe-shell.sh]='git push | tail -3'
    [refuse-dev-vars-print.sh]='cat store/.dev.vars'
    [refuse-shell-edits.sh]="sed -i 's/a/b/' C:/work/x/f.md"
  )
  n=0
  for part in refuse-command-hooks.sh "${PARTS[@]}" lib/command-position.sh; do
    for where in middle early tail; do
      # tail: the hook loses its last line, exit 0, so it is skipped whole.
      [[ "$where" == tail && ( "$part" == lib/* || "$part" == refuse-command-hooks.sh ) ]] && continue
      n=$((n + 1))
      dir="$WORK/all-$n"
      mkdir -p "$dir/lib"
      cp "${PARTS[@]/#/$HERE/}" "$dir/"
      cp "$ALL" "$dir/refuse-command-hooks.sh"
      cp "$HERE/lib/command-position.sh" "$dir/lib/"
      half=$(( $(wc -l < "$dir/$part") / 2 ))
      if [[ "$where" == middle ]]; then
        sed -i "${half}a if then fi ((" "$dir/$part"
      elif [[ "$where" == tail ]]; then
        sed -i '$d' "$dir/$part"
      elif [[ "$part" == lib/* ]]; then
        sed -i "2a if then fi ((" "$dir/$part"
      else
        sed -i "/^trap /a if then fi ((" "$dir/$part"
      fi
      # The part's own refusal is lost, and no other part is.
      # A broken library or one-bash file loses every part. A broken part loses
      # its own refusal only.
      cmds=()
      for f in "${PARTS[@]}"; do
        if [[ "$part" == "$f" || "$part" == lib/* || "$part" == refuse-command-hooks.sh ]]; then
          cmds+=("${own[$f]}" 0)
        else
          cmds+=("${own[$f]}" 2)
        fi
      done
      [[ "$part" == refuse-unsafe-shell.sh ]] && cmds+=('rm -rf "$d/x"' 0)
      for (( f = 0; f < ${#cmds[@]}; f += 2 )); do
        payload Bash "${cmds[f]}"
        line="${cmds[f]%%$'\n'*}"
        check "$dir/refuse-command-hooks.sh" "${cmds[f + 1]}" "broken $where ${part}: exit ${cmds[f + 1]} for $line" "$PAYLOAD"
      done
    done
  done

  # A hook the one bash cannot load does not vanish in silence. With no final
  # line of exit 0 (the file saved with CRLF endings, or its last line cut) or
  # no file at all, that part is skipped: one line on standard error names it
  # and says skipped, its command passes with exit 0, and the other parts still
  # refuse. A clean run with every part there says nothing.
  payload Bash 'ls; echo done'
  COUNT=$((COUNT + 1))
  bash "$ALL" 2>"$ERR" >/dev/null <<< "$PAYLOAD"
  if [[ $? == 0 && ! -s "$ERR" ]]; then
    printf 'ok    all seven parts there: a clean command says nothing on standard error\n'
  else
    printf 'FAIL  all seven parts there: a clean command exits non-zero or says something\n'
    sed 's/^/        /' "$ERR"
    failed
  fi
  for part in "${PARTS[@]}"; do
    for where in crlf noexit missing; do
      dir="$WORK/skip-$where-${part%.sh}"
      mkdir -p "$dir/lib"
      cp "${PARTS[@]/#/$HERE/}" "$dir/"
      cp "$ALL" "$dir/refuse-command-hooks.sh"
      cp "$HERE/lib/command-position.sh" "$dir/lib/"
      case "$where" in
        crlf) sed -i 's/$/\r/' "$dir/$part" ;;
        noexit) sed -i '$d' "$dir/$part" ;;
        missing) rm "$dir/$part" ;;
      esac
      payload Bash "${own[$part]}"
      COUNT=$((COUNT + 1))
      bash "$dir/refuse-command-hooks.sh" 2>"$ERR" >/dev/null <<< "$PAYLOAD"
      got=$?
      mapfile -t errlines < "$ERR"
      if [[ "$got" == 0 && ${#errlines[@]} == 1 && "${errlines[0]}" == *"$part skipped"* ]]; then
        printf 'ok    %s %s: exit 0 and one line naming it as skipped\n' "$where" "$part"
      else
        printf 'FAIL  %s %s: exit %s, %s lines on standard error, want exit 0 and one line holding "%s skipped"\n' "$where" "$part" "$got" "${#errlines[@]}" "$part"
        sed 's/^/        /' "$ERR"
        failed
      fi
      if [[ "$part" == refuse-kill-by-name.sh ]]; then
        payload Bash "${own[refuse-merge-default-body.sh]}"
      else
        payload Bash "${own[refuse-kill-by-name.sh]}"
      fi
      check "$dir/refuse-command-hooks.sh" 2 "$where $part: another part still refuses" "$PAYLOAD"
    done
  done
}

# Files changed in place through the shell, and python - with nothing on
# standard input.
# refuse-shell-edits.sh and the python hook are tested alone here. The one-bash
# file runs them, which one_bash_cases shows.
shell_edit_cases() {
  local tool

  # sed -i, in any spelling of the flag, on a literal path outside a scratch folder.
  for tool in Bash PowerShell; do
    refused "$EDITS" $tool "sed -i 's/a/b/' C:/work/x/state.md"
    refused "$EDITS" $tool "sed --in-place=.bak 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed -i.bak 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed -ni 's/a/b/p' file.sh"
    refused "$EDITS" $tool "sed -Ei 's/a|b/c/' file.sh"
    refused "$EDITS" $tool "sed --in-place 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed --in 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed --in-pl=.orig 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed -i -e 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed -i --expression 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed -i --expression='s/a/b/' file.sh"
    refused "$EDITS" $tool "sed -i --file=script.sed file.sh"
    refused "$EDITS" $tool "sed -n -i p file.sh"
    refused "$EDITS" $tool "sed -s -i 's/a/b/' a.sh b.sh"
    refused "$EDITS" $tool "sed -e 's/a/b/' -i file.sh"
    refused "$EDITS" $tool "sed -f script.sed -i file.sh"
    refused "$EDITS" $tool "/usr/bin/sed -i 's/a/b/' file.sh"
    refused "$EDITS" $tool "sed.exe -i 's/a/b/' file.sh"
    refused "$EDITS" $tool "SED -i 's/a/b/' file.sh"
    refused "$EDITS" $tool 'sed -i "s/a/$X/" file.sh'
    refused "$EDITS" $tool "sed -i s/a/b/ \"C:/work/my folder/state.md\""
    refused "$EDITS" $tool "cd C:/work/x && sed -i 's/a/b/' state.md"
    refused "$EDITS" $tool "sed -i 's/a/b/' /tmp/x C:/work/x/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' C:/work/x/tmp/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' ./scratchpad/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' C:/work/x/scratchpad/f.sh"
    # A folder named scratchpad is not a Claude scratchpad unless claude/<project>/<session> is above it.
    refused "$EDITS" $tool "sed -i 's/a/b/' C:/work/claude-x/scratchpad/f.md"
    refused "$EDITS" $tool "sed -i 's/a/b/' C:/work/x/claude/scratchpad/f.md"
    refused "$EDITS" $tool "sed -i 's/a/b/' /srv/u/claude-9/scratchpad/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' /d/Temp/claude/C--work/abc/scratchpad-old/f.md"
    refused "$EDITS" $tool 'echo x > C:/work/claude-x/scratchpad/f.md'
    refused "$EDITS" $tool 'echo x > C:/work/x/claude/scratchpad/f.md'
    refused "$EDITS" $tool 'echo x > "C:\work\x\Claude\Scratchpad\f.md"'
    refused "$EDITS" $tool 'echo x | tee C:/work/x/claude/scratchpad/f.md'
    refused "$EDITS" $tool "sed -i 's/a/b/' C:/Users/user/AppData/Local/Tempfoo/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' /tmpfoo/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' /devx/f.sh"
    refused "$EDITS" $tool "sed -i 's/a/b/' ~/notes.md"
    refused "$EDITS" $tool "sed -i 's/a/b/' /tmp/../c/work/x/state.md"
    refused "$EDITS" $tool "sed -i 's/a/b/' /tmp/.."
    refused "$EDITS" $tool "echo x >> C:/Users/user/AppData/Local/Temp/../../notes.md"
    refused "$EDITS" $tool 'echo x | tee /dev/../c/work/x/out.txt'
    passes "$EDITS" $tool "sed -i s/a/b/ /tmp/a..b"
    passes "$EDITS" $tool "sed -i s/a/b/ /tmp/..foo/x"
  done
  # sed without -i, or with a flag that only looks like it.
  for tool in Bash PowerShell; do
    passes "$EDITS" $tool "sed 's/a/b/' C:/work/x/state.md"
    passes "$EDITS" $tool "sed -n '/i/p' C:/work/x/state.md"
    passes "$EDITS" $tool "sed -e 's/i/j/' C:/work/x/state.md"
    passes "$EDITS" $tool "sed -E 's/a|b/c/' C:/work/x/state.md"
    passes "$EDITS" $tool "sed --expression='s/a/b/' C:/work/x/state.md"
    passes "$EDITS" $tool "sed --silent --regexp-extended 's/a/b/p' C:/work/x/state.md"
    passes "$EDITS" $tool "sed -n -e 's/a/b/p' -s C:/work/x/state.md"
    passes "$EDITS" $tool "sed -l 5 's/a/b/' C:/work/x/state.md"
    passes "$EDITS" $tool "echo 'sed -i s/a/b/ state.md'"
    passes "$EDITS" $tool 'git commit -m "Never sed -i state.md"'
    passes "$EDITS" $tool "grep -n 'sed -i' notes.md"
    passes "$EDITS" $tool "# sed -i s/a/b/ state.md is refused"
  done
  # A scratch folder, or a path that cannot be read, passes.
  for tool in Bash PowerShell; do
    passes "$EDITS" $tool "sed -i 's/a/b/' /tmp/x"
    passes "$EDITS" $tool "sed -i 's/a/b/' /tmp/x /tmp/y"
    passes "$EDITS" $tool "sed -i 's/a/b/' C:/Users/user/AppData/Local/Temp/x.sh"
    passes "$EDITS" $tool "sed -i s/a/b/ c:\\users\\user\\appdata\\local\\temp\\x.sh"
    passes "$EDITS" $tool "sed -i s/a/b/ /c/Users/user/APPDATA/LOCAL/TEMP/x.sh"
    passes "$EDITS" $tool "sed -i s/a/b/ C:/Users/user/AppData/Local/Temp/claude/C--work/abc/scratchpad/f.sh"
    passes "$EDITS" $tool "sed -i s/a/b/ \"C:\\Users\\user\\AppData\\Local\\Temp\\claude\\C--work\\abc\\scratchpad\\f.sh\""
    passes "$EDITS" $tool "sed -i s/a/b/ /d/Temp/claude/C--work/abc/scratchpad/f.sh"
    passes "$EDITS" $tool "sed -i s/a/b/ D:\\Temp\\Claude\\C--work\\abc\\Scratchpad\\f.sh"
    passes "$EDITS" $tool 'echo x > D:/Temp/claude/C--work/abc/scratchpad/out.txt'
    passes "$EDITS" $tool 'echo x > "D:\Temp\Claude\C--work\abc\Scratchpad\out.txt"'
    passes "$EDITS" $tool 'echo x | tee /d/Temp/claude/C--work/abc/scratchpad/out.txt'
    passes "$EDITS" $tool "sed -i s/a/b/ /dev/null"
    passes "$EDITS" $tool "sed -i -e 's/a/b/' /tmp/x"
    passes "$EDITS" $tool "sed -i -e 's/a/b/' -e 's/c/d/' /tmp/x"
    passes "$EDITS" $tool "sed -i -f script.sed /tmp/x"
    passes "$EDITS" $tool "sed -i --expression 's/a/b/' /tmp/x"
    passes "$EDITS" $tool "sed -i --line-length 5 's/a/b/' /tmp/x"
    passes "$EDITS" $tool "sed -i -l 5 's/a/b/' /tmp/x"
    passes "$EDITS" $tool "sed -i s/a/b/ \"\$F\""
    passes "$EDITS" $tool "sed -i s/a/b/ \${F}"
    passes "$EDITS" $tool "sed -i s/a/b/ \$(git ls-files)"
  done

  # A redirect to a literal path outside a scratch folder.
  for tool in Bash PowerShell; do
    refused "$EDITS" $tool "printf 'x\\n' >> C:/work/orch/state.md"
    refused "$EDITS" $tool "echo x > notes.md"
    refused "$EDITS" $tool "echo x >> ./notes.md"
    refused "$EDITS" $tool "echo x>notes.md"
    refused "$EDITS" $tool "echo x >>C:/work/x/log.md"
    refused "$EDITS" $tool 'echo x > "C:/work/x/notes.md"'
    refused "$EDITS" $tool "echo x > 'C:\\work\\x\\notes.md'"
    refused "$EDITS" $tool "echo x > ~/notes.md"
    refused "$EDITS" $tool "cmd 2> err.log"
    refused "$EDITS" $tool "cmd 2>>C:/work/x/err.log"
    refused "$EDITS" $tool "cmd > out.txt 2>&1"
    refused "$EDITS" $tool "cat state.md >> C:\\work\\x\\log.md"
    refused "$EDITS" $tool "cd C:/work/x && echo x >> state.md"
    refused "$EDITS" $tool "echo x > /tmpfoo/y"
    refused "$EDITS" $tool "echo x > C:/work/x/tmp/y"
    refused "$EDITS" $tool 'for f in a b; do echo $f; done > list.txt'
    refused "$EDITS" $tool "echo ok # fine
echo x >> notes.md"
  done
  refused "$EDITS" Bash "cmd &> out.log"
  refused "$EDITS" Bash "cmd >& out.log"
  refused "$EDITS" Bash "cmd 3> fd3.log"
  refused "$EDITS" Bash "> notes.md echo x"
  refused "$EDITS" PowerShell 'Write-Output hi > out.txt'
  refused "$EDITS" PowerShell 'Get-Date >> C:\work\x\log.txt'
  # A target that cannot be read, or sits in a scratch folder, passes.
  for tool in Bash PowerShell; do
    passes "$EDITS" $tool "printf 'x\\n' >> \"\$LOG\""
    passes "$EDITS" $tool 'echo x > "$T"'
    passes "$EDITS" $tool 'echo x >> $LOG'
    passes "$EDITS" $tool 'echo x > "${T:?}/out"'
    passes "$EDITS" $tool 'echo x > $TMPDIR/out'
    passes "$EDITS" $tool 'echo x > "$(mktemp)"'
    passes "$EDITS" $tool 'echo x > $(mktemp)'
    passes "$EDITS" $tool 'echo x >$(mktemp)'
    passes "$EDITS" $tool 'echo x >> /tmp/log'
    passes "$EDITS" $tool 'echo x > /tmp/proj-x.log 2>&1'
    passes "$EDITS" $tool 'echo x > C:/Users/user/AppData/Local/Temp/x.txt'
    passes "$EDITS" $tool 'echo x > "C:\Users\user\appdata\local\temp\x.txt"'
    passes "$EDITS" $tool 'echo x > /c/Users/user/AppData/Local/Temp/claude/C--work/abc/scratchpad/out.txt'
    passes "$EDITS" $tool 'echo x > /dev/stderr'
    passes "$EDITS" $tool 'echo x > "/tmp/proj x.log"'
    passes "$EDITS" $tool 'echo x > %TEMP%/x.log'
    passes "$EDITS" $tool 'echo x > "`mktemp`"'
    passes "$EDITS" $tool 'echo x > nul'
    passes "$EDITS" $tool 'echo ok # writes > notes.md'
    passes "$EDITS" $tool 'echo "a > notes.md"'
    passes "$EDITS" $tool 'git log --format="%h > %s" | head -5'
    passes "$EDITS" $tool 'git commit -m "x > notes.md"'
    passes "$EDITS" $tool 'cat < input.md'
    passes "$EDITS" $tool 'sort < a.txt | uniq'
    passes "$EDITS" $tool 'cmd <<< "$x"'
    passes "$EDITS" $tool 'echo $((1>0))'
  done
  passes "$EDITS" Bash 'echo x > $HOME/y.log'

  # A heredoc into cat, or a cat with no heredoc, onto a literal path.
  refused "$EDITS" Bash $'cat > notes.md <<\'EOF\'\nbody\nEOF'
  refused "$EDITS" Bash $'cat >> C:/work/x/state.md <<EOF\n- line\nEOF'
  refused "$EDITS" Bash $'cat <<\'EOF\' > notes.md\nbody\nEOF'
  refused "$EDITS" Bash $'cat > "C:/work/my folder/notes.md" <<-EOF\n\tbody\n\tEOF'
  refused "$EDITS" Bash 'cat >> notes.md'
  refused "$EDITS" Bash $'echo start\ncat > notes.md <<\'EOF\'\nbody\nEOF\necho done'
  passes "$EDITS" Bash $'cat > /tmp/notes.md <<\'EOF\'\nbody\nEOF'
  passes "$EDITS" Bash $'cat > "C:/Users/user/AppData/Local/Temp/notes.md" <<EOF\nbody\nEOF'
  passes "$EDITS" Bash $'cat > "$T" <<\'EOF\'\nbody\nEOF'
  passes "$EDITS" Bash $'cat > "${T:?}/notes.md" <<\'EOF\'\nbody\nEOF'
  passes "$EDITS" Bash $'cat <<\'EOF\'\nbody\nEOF'
  passes "$EDITS" Bash $'git commit -F - <<\'EOF\'\nsed -i state.md and echo x >> notes.md\nEOF'
  passes "$EDITS" Bash $'cat > /tmp/x <<\'EOF\'\nsed -i s/a/b/ state.md\necho x >> notes.md\nEOF\necho written'
  passes "$EDITS" PowerShell $'$x = @\'\necho x > notes.md\n\'@\nWrite-Output $x'

  # tee, with or without -a.
  for tool in Bash PowerShell; do
    refused "$EDITS" $tool 'echo x | tee C:/work/x/out.txt'
    refused "$EDITS" $tool 'echo x | tee -a C:/work/x/out.txt'
    refused "$EDITS" $tool 'echo x | tee out.log'
    refused "$EDITS" $tool 'echo x | tee --append out.log'
    refused "$EDITS" $tool 'echo x | tee /tmp/a C:/work/x/b'
    refused "$EDITS" $tool 'echo x | tee "C:/work/my folder/out.txt"'
    refused "$EDITS" $tool 'cmd 2>&1 | tee build.log'
    refused "$EDITS" $tool 'echo x | /usr/bin/tee out.log'
    passes "$EDITS" $tool 'echo x | tee /dev/stderr'
    passes "$EDITS" $tool 'echo x | tee /tmp/x'
    passes "$EDITS" $tool 'echo x | tee -a /tmp/x'
    passes "$EDITS" $tool 'echo x | tee /tmp/a /tmp/b'
    passes "$EDITS" $tool 'echo x | tee -a "$LOG"'
    passes "$EDITS" $tool 'cmd 2>&1 | tee "$LOG"'
    passes "$EDITS" $tool 'echo x | tee C:/Users/user/AppData/Local/Temp/x.txt'
    passes "$EDITS" $tool 'echo x | tee /dev/null'
    passes "$EDITS" $tool 'echo x | tee'
    passes "$EDITS" $tool 'echo x | tee -a'
    passes "$EDITS" $tool 'echo "tee out.log"'
  done
  passes "$EDITS" PowerShell 'Get-Date | tee -Variable now'

  # The descriptors and /dev/null still pass.
  for tool in Bash PowerShell; do
    passes "$EDITS" $tool 'cmd 2>/dev/null'
    passes "$EDITS" $tool 'cmd >/dev/null 2>&1'
    passes "$EDITS" $tool 'cmd >&2'
    passes "$EDITS" $tool 'cmd 2>&1'
    passes "$EDITS" $tool 'cmd 2>&1 | tail -3'
    passes "$EDITS" $tool 'cmd 1>&2'
    passes "$EDITS" $tool 'cmd >&-'
    passes "$EDITS" $tool 'cmd 2>&1 >/dev/null'
    passes "$EDITS" $tool 'cmd > /dev/null'
  done
  passes "$EDITS" Bash 'cmd &>/dev/null'
  passes "$EDITS" Bash 'ls -la > /dev/null 2>&1 && echo done'

  # python - with nothing on standard input hangs until the harness's timeout.
  for tool in Bash PowerShell; do
    refused "$PY" $tool 'python -'
    refused "$PY" $tool 'python3 -'
    refused "$PY" $tool 'py -'
    refused "$PY" $tool 'python.exe -'
    refused "$PY" $tool 'python3.13 -'
    refused "$PY" $tool 'cd C:/work/x && python -'
    refused "$PY" $tool 'python - arg1 arg2'
    refused "$PY" $tool 'python -u -'
    refused "$PY" $tool 'py -3 -'
    refused "$PY" $tool 'python -W ignore -'
    refused "$PY" $tool 'python - 2>&1'
    refused "$PY" $tool 'python - | cat'
    refused "$PY" $tool 'echo start; python -'
    refused "$PY" $tool 'C:/Users/user/AppData/Local/Python/bin/python.exe -'
    # Inside a command substitution, after another command word. The $( is not a pipe.
    refused "$PY" $tool 'echo $(python -)'
    refused "$PY" $tool 'echo $(python - )'
    refused "$PY" $tool 'echo x $(python -) y'
    refused "$PY" $tool 'cat $(python -)'
    refused "$PY" $tool 'ls; echo $(python -)'
    refused "$PY" $tool 'echo `python -`'
    refused "$PY" $tool 'x=$(python -)'
    passes "$PY" $tool 'echo $(date) | python -'
    passes "$PY" $tool 'echo $(cat s.py) | python -'
    passes "$PY" $tool 'echo $(python - < s.py)'
    passes "$PY" $tool 'echo $(echo x | python -)'
    passes "$PY" $tool 'echo $(cat s.py | python -)'
    passes "$PY" $tool 'echo $(python -c "print(1)")'
    passes "$PY" $tool 'echo $(python script.py -)'
    passes "$PY" $tool 'cat s.py | python -'
    passes "$PY" $tool 'echo "print(1)" | python3 -'
    passes "$PY" $tool 'cat s.py | tee /tmp/x | python -'
    passes "$PY" $tool 'python -c "print(1)" -'
    passes "$PY" $tool 'python -m json.tool -'
    passes "$PY" $tool 'python -um json.tool -'
    passes "$PY" $tool 'python script.py -'
    passes "$PY" $tool 'python3 script.py arg -'
    passes "$PY" $tool 'python3 --version'
    passes "$PY" $tool 'python3 -V'
    passes "$PY" $tool 'git commit -m "python -"'
    passes "$PY" $tool 'echo "python -"'
    passes "$PY" $tool 'grep -n "python -" notes.md'
    passes "$PY" $tool 'herdr agent prompt x "run python -"'
    passes "$PY" $tool '# python - hangs'
  done
  passes "$PY" Bash 'python - < script.py'
  passes "$PY" Bash 'python3 - < C:/work/x/script.py'
  passes "$PY" Bash 'python - arg < script.py'
  passes "$PY" Bash 'python - 0< script.py'
  passes "$PY" Bash 'python -u - <script.py 2>&1'
  passes "$PY" PowerShell "'print(1)' | python -"
  passes "$PY" PowerShell 'Get-Content x.py | python -'
  # A heredoc is still the heredoc rule's.
  refused "$PY" Bash $'python - <<\'EOF\'\nprint(1)\nEOF'
  says "$PY" Bash 'python -' 'harness'"'"'s timeout'
  says "$PY" Bash 'python3 -' 'python <file>'
  says "$PY" Bash 'py -' 'standard input'

  # A refused command inside a shell's command string is refused the same way.
  for tool in Bash PowerShell; do
    refused "$EDITS" $tool "bash -c \"sed -i 's/a/b/' C:/work/x/f.sh\""
    refused "$EDITS" $tool "bash -c 'sed -i s/a/b/ C:/work/x/f.sh'"
    refused "$EDITS" $tool "sh -c 'cd C:/work/x && sed --in-place=.bak s/a/b/ state.md'"
    refused "$EDITS" $tool "bash -c 'echo x >> C:/work/x/state.md'"
    refused "$EDITS" $tool $'bash -c \'cat > notes.md <<EOF\nbody\nEOF\''
    refused "$EDITS" $tool "bash -c 'echo x | tee out.txt'"
    refused "$EDITS" $tool 'powershell -Command "echo x >> C:/work/x/state.md"'
    refused "$EDITS" $tool 'powershell -NoProfile -Command "Get-Date | tee C:/work/x/out.txt"'
    refused "$EDITS" $tool 'pwsh -c "sed -i s/a/b/ state.md"'
    refused "$EDITS" $tool 'cmd /c "echo x > C:\work\x\out.txt"'
    refused "$PY" $tool "bash -c 'python -'"
    refused "$PY" $tool 'powershell -Command "python -"'
    refused "$PY" $tool 'pwsh -c "py -3 -"'
    passes "$EDITS" $tool "bash -c 'sed -i s/a/b/ /tmp/f.sh'"
    passes "$EDITS" $tool "bash -c 'echo x >> /tmp/log'"
    passes "$EDITS" $tool 'powershell -Command "echo x >> C:/Users/user/AppData/Local/Temp/log"'
    passes "$EDITS" $tool 'powershell -Command "Get-Date | tee /dev/null"'
    passes "$PY" $tool "bash -c 'python - < s.py'"
    passes "$PY" $tool 'powershell -Command "Get-Content s.py | python -"'
  done

  # The messages name the fix.
  says "$EDITS" Bash "sed -i 's/a/b/' C:/work/x/state.md" 'Use the Edit tool to change a file'
  says "$EDITS" Bash "sed -i 's/a/b/' C:/work/x/state.md" 'the Write tool to make a new one'
  says "$EDITS" Bash "sed -i 's/a/b/' C:/work/x/state.md" 'skips the state check'
  says "$EDITS" Bash "sed -i 's/a/b/' C:/work/x/state.md" 'has corrupted files'
  says "$EDITS" Bash "sed -i 's/a/b/' C:/work/x/state.md" 'sed -i on C:/work/x/state.md'
  says "$EDITS" Bash 'echo x >> C:/work/x/log.md' 'a redirect to C:/work/x/log.md'
  says "$EDITS" Bash 'echo x | tee C:/work/x/out.txt' 'tee to C:/work/x/out.txt'
  says "$EDITS" Bash 'echo x >> C:/work/x/log.md' '/tmp, /dev'
  says "$EDITS" Bash 'echo x >> C:/work/x/log.md' 'AppData/Local/Temp'

  # Other tools and unreadable input, through (the hook fails open).
  check "$EDITS" 0 "pass:   Write of a script with sed -i and redirects" \
    '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/run.sh","content":"sed -i s/a/b/ state.md\necho x >> notes.md\necho x | tee out.log"}}'
  check "$EDITS" 0 "pass:   input that is not JSON" 'not json at all {'
  check "$EDITS" 0 "pass:   empty input" ''
  check "$EDITS" 0 "pass:   payload with no command" '{"tool_name":"Bash","tool_input":{}}'
  check "$PY" 0 "pass:   Write of a script with python -" \
    '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/run.sh","content":"python -\necho x | python -"}}'
}

if [[ -n "${NEW_CASES_ONLY:-}" ]]; then
  one_bash_cases
  finish
fi
if [[ -n "${H_CASES_ONLY:-}" ]]; then
  [[ "$H_CASES_ONLY" == onebash ]] || shell_edit_cases
  [[ "$H_CASES_ONLY" == edits ]] || one_bash_cases
  finish
fi

for tool in Bash PowerShell; do
  # Kill by name, refused.
  refused "$KILL" $tool 'taskkill /IM node.exe /F'
  refused "$KILL" $tool 'taskkill /F /im workerd.exe'
  refused "$KILL" $tool 'taskkill -im esbuild.exe -f'
  refused "$KILL" $tool 'TASKKILL.EXE /IM node.exe'
  refused "$KILL" $tool 'C:/Windows/System32/taskkill.exe /IM node.exe'
  refused "$KILL" $tool 'cd C:/work/proj; taskkill /IM node.exe'
  refused "$KILL" $tool $'herdr tab close w1 && taskkill /IM workerd.exe /F'
  refused "$KILL" $tool $'echo start\ntaskkill /IM node.exe'
  refused "$KILL" $tool 'taskkill /IM "node.exe" /F'
  refused "$KILL" $tool 'git status 2>&1; taskkill /IM node.exe'
  refused "$KILL" $tool 'taskkill //IM node.exe //F'
  refused "$KILL" $tool 'MSYS_NO_PATHCONV=1 taskkill /IM node.exe'
  passes "$KILL" $tool 'taskkill //PID 999999'
  # Good forms and look-alikes, through.
  passes "$KILL" $tool 'taskkill /PID 999999'
  passes "$KILL" $tool 'taskkill /F /PID 999999 /T'
  passes "$KILL" $tool 'echo "taskkill /IM node.exe"'
  passes "$KILL" $tool "echo 'taskkill /IM node.exe'"
  passes "$KILL" $tool 'git commit -m "Never taskkill /IM node.exe, and never Stop-Process -Name node"'
  passes "$KILL" $tool 'grep -n "taskkill /IM" C:/work/orch/brief.md'
  passes "$KILL" $tool '# taskkill /IM node.exe is a trap'
  passes "$KILL" $tool 'ls; echo done'
done

# Bash only: a heredoc body that names the commands, and kill -n (a signal).
passes "$KILL" Bash $'cat > brief.md <<\'EOF\'\ntaskkill /IM node.exe\nStop-Process -Name node\nGet-Process node | Stop-Process\nEOF\necho written'
passes "$KILL" Bash $'git commit -F - <<EOF\nDo not taskkill /IM node.exe.\nEOF'
passes "$KILL" Bash 'kill -n 9 999999'
passes "$KILL" Bash 'kill 999999'
refused "$KILL" Bash $'cat > x <<EOF\ntaskkill /IM node.exe\nEOF\ntaskkill /IM node.exe'

# PowerShell only.
refused "$KILL" PowerShell 'Stop-Process -Name node -Force'
refused "$KILL" PowerShell 'stop-process -name workerd'
refused "$KILL" PowerShell 'Stop-Process -N esbuild'
refused "$KILL" PowerShell 'spps -Name node'
refused "$KILL" PowerShell 'kill -Name node'
refused "$KILL" PowerShell 'Get-Process node | Stop-Process'
refused "$KILL" PowerShell 'Get-Process -Name workerd | Stop-Process -Force'
refused "$KILL" PowerShell 'gps esbuild | spps'
refused "$KILL" PowerShell 'Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID } | Stop-Process'
refused "$KILL" PowerShell 'if ($?) { Stop-Process -Name node }'
refused "$KILL" PowerShell $'Write-Output x; `\nStop-Process -Name node'
passes "$KILL" PowerShell 'Stop-Process -Id 999999'
passes "$KILL" PowerShell 'if (Get-Process node -ErrorAction SilentlyContinue) { Stop-Process -Id 999999 }'
refused "$KILL" PowerShell '(Get-Process node) | Stop-Process'
passes "$KILL" PowerShell 'Stop-Process -Id 999999 -Force'
passes "$KILL" PowerShell 'Get-Process -Id 999999 | Stop-Process'
passes "$KILL" PowerShell 'Get-Process node | Select-Object Id, Path'
passes "$KILL" PowerShell 'Get-CimInstance Win32_Process -Filter "Name = \"node.exe\"" | Select-Object ProcessId, CommandLine'
passes "$KILL" PowerShell 'Write-Output "Stop-Process -Name node"'
passes "$KILL" PowerShell $'$brief = @\'\ntaskkill /IM node.exe\nStop-Process -Name node\n\'@\nSet-Content -Path brief.md -Value $brief'
passes "$KILL" PowerShell $'git commit -m @"\nNever taskkill /IM node.exe\n"@'

for tool in Bash PowerShell; do
  # gh pr merge without subject and body, refused.
  refused "$MERGE" $tool 'gh pr merge 1 --squash'
  refused "$MERGE" $tool 'gh pr merge 1 --repo example-org/hook-test-none --squash'
  refused "$MERGE" $tool 'gh -R example-org/proj pr merge 144 --squash --delete-branch'
  refused "$MERGE" $tool 'gh pr merge 1 --squash --subject x'
  refused "$MERGE" $tool 'gh pr merge 1 --squash --body y'
  refused "$MERGE" $tool 'gh pr merge 1 --squash -t "Title (#1)"'
  refused "$MERGE" $tool 'cd C:/work/proj; gh pr merge 1 --squash --body-file -'
  refused "$MERGE" $tool 'gh pr view 1; gh pr merge 1 --squash --auto'
  # Good forms and look-alikes, through.
  passes "$MERGE" $tool 'gh pr merge 1 --squash --subject x --body y'
  passes "$MERGE" $tool 'gh pr merge 144 --squash --subject "Header (#144)" --body "Closes #148. The gate'\''s log is on the pull request."'
  passes "$MERGE" $tool 'gh pr merge 1 --squash -t x -b y'
  passes "$MERGE" $tool 'gh pr merge 1 --squash --subject=x --body-file=body.md'
  passes "$MERGE" $tool 'gh pr merge 1 --squash -t "x" -F body.md'
  passes "$MERGE" $tool 'gh pr merge 1 --disable-auto'
  passes "$MERGE" $tool 'gh pr view 1 --json mergeCommit'
  passes "$MERGE" $tool 'echo "gh pr merge 1 --squash"'
  passes "$MERGE" $tool 'git commit -m "Always pass --subject and --body to gh pr merge 1 --squash"'
  passes "$MERGE" $tool 'herdr agent prompt dev-orchestrator "run gh pr merge 1 --squash"'
done
passes "$MERGE" Bash $'gh pr merge 1 --squash \\\n  --subject x \\\n  --body y'
passes "$MERGE" PowerShell $'gh pr merge 1 --squash `\n  --subject x `\n  --body y'
passes "$MERGE" Bash $'cat >> state.md <<\'EOF\'\n- gh pr merge 1 --squash took the default body\nEOF'
passes "$MERGE" Bash $'gh pr merge 1 --squash --subject x --body-file - <<\'EOF\'\nCloses #1.\nEOF'

# A command inside a shell's command string, image name filters, help and rebase.
for tool in Bash PowerShell; do
  # W1: a command inside a shell's command string is read with the same rules.
  refused "$KILL" $tool 'powershell -Command "Stop-Process -Name node"'
  refused "$KILL" $tool 'powershell -NoProfile -Command "taskkill /IM node.exe"'
  refused "$KILL" $tool 'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command Stop-Process -Name workerd'
  refused "$KILL" $tool 'pwsh -c "Get-Process node | Stop-Process"'
  refused "$KILL" $tool 'cmd /c taskkill /IM node.exe'
  refused "$KILL" $tool 'cmd //c "taskkill /IM node.exe"'
  refused "$KILL" $tool 'cmd.exe /C "taskkill /F /IM workerd.exe"'
  refused "$KILL" $tool 'bash -c "taskkill /IM node.exe"'
  refused "$KILL" $tool "bash -c 'cd /c/work && taskkill //IM esbuild.exe'"
  refused "$KILL" $tool 'cd C:/work; powershell -Command "if ($?) { Stop-Process -Name node }"'
  passes "$KILL" $tool 'powershell -Command "Stop-Process -Id 999999"'
  passes "$KILL" $tool 'powershell -NoProfile -Command "Get-CimInstance Win32_Process | Select-Object ProcessId, CommandLine"'
  passes "$KILL" $tool 'cmd /c taskkill /PID 999999'
  passes "$KILL" $tool "bash -c \"echo 'taskkill /IM node.exe'\""
  passes "$KILL" $tool "powershell -Command \"Write-Output 'Stop-Process -Name node'\""
  passes "$KILL" $tool 'powershell -File C:/work/x/stop-by-id.ps1'
  passes "$KILL" $tool 'git commit -m "powershell -Command Stop-Process -Name node is refused"'
  refused "$MERGE" $tool 'bash -c "gh pr merge 1 --squash"'
  refused "$MERGE" $tool 'powershell -Command "gh pr merge 1 --squash --subject x"'
  refused "$MERGE" $tool 'cmd /c gh pr merge 1 --squash'
  passes "$MERGE" $tool "bash -c \"gh pr merge 1 --squash --subject x --body 'Closes #1.'\""
  passes "$MERGE" $tool 'herdr agent prompt x "bash -c gh pr merge 1 --squash"'
  # N4: taskkill by an image name filter.
  refused "$KILL" $tool 'taskkill /FI "IMAGENAME eq node.exe"'
  refused "$KILL" $tool 'taskkill /F /fi "imagename eq workerd.exe" /T'
  refused "$KILL" $tool "taskkill //FI 'IMAGENAME eq esbuild.exe'"
  passes "$KILL" $tool 'taskkill /FI "PID eq 999999"'
  passes "$KILL" $tool 'tasklist /FI "IMAGENAME eq node.exe"'
  # N1 and N2: help, and a rebase that writes no merge commit.
  passes "$MERGE" $tool 'gh pr merge --help'
  passes "$MERGE" $tool 'gh pr merge -h'
  passes "$MERGE" $tool 'gh pr merge 1 --help'
  passes "$MERGE" $tool 'gh pr merge 1 --rebase'
  passes "$MERGE" $tool 'gh pr merge 1 -r --delete-branch'
  refused "$MERGE" $tool 'gh pr merge 1 --merge'
  refused "$MERGE" $tool 'gh pr merge 1 -m'
  # N3: a flag with no value, and one dash, do not count.
  refused "$MERGE" $tool 'gh pr merge 1 --squash --subject x --body-file'
  refused "$MERGE" $tool 'gh pr merge 1 --squash --subject x --body'
  refused "$MERGE" $tool 'gh pr merge 1 --squash --subject --body y'
  refused "$MERGE" $tool 'gh pr merge 1 --squash --subject x -body y'
  refused "$MERGE" $tool 'gh pr merge 1 --squash -subject x --body y'
  refused "$MERGE" $tool 'gh pr merge 1 --squash --subject= --body y'
  passes "$MERGE" $tool 'gh pr merge 1 --squash --subject "--body" --body y'
done
# W2: other ways PowerShell kills by name.
refused "$KILL" PowerShell 'Stop-Process -ProcessName node'
refused "$KILL" PowerShell 'Stop-Process -pr workerd -Force'
refused "$KILL" PowerShell 'spps -ProcessN esbuild'
refused "$KILL" PowerShell 'Stop-Process -ProcessName:node'
refused "$KILL" PowerShell '(Get-Process node).Kill()'
refused "$KILL" PowerShell 'Get-Process node | ForEach-Object { $_.Kill() }'
refused "$KILL" PowerShell 'Get-Process -Name workerd | % { $_.Kill() }'
refused "$KILL" PowerShell 'powershell -Command "(Get-Process node).Kill()"'
passes "$KILL" PowerShell 'Stop-Process -PassThru -Id 999999'
passes "$KILL" PowerShell '(Get-Process -Id 999999).Kill()'
passes "$KILL" PowerShell 'Write-Output "(Get-Process node).Kill()"'
# The review's look-alikes that passed before the change, and must still pass.
passes "$KILL" PowerShell 'Stop-Process -Id (Get-Process node).Id'
passes "$KILL" Bash "kill \$(ps -W | grep node | awk '{print \$1}')"
passes "$KILL" Bash "echo it's fine; taskkill /PID 5"
passes "$KILL" Bash $'x=$(cat <<\'EOF\'\ntaskkill /IM node.exe\nEOF\n)'
passes "$MERGE" Bash 'gh issue comment 3 --body-file f.md && echo "Stop-Process -Name"'

# Other tools and unreadable input, through (the hook fails open).
check "$KILL" 0 "pass:   Write of a brief naming both commands" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/brief.md","content":"taskkill /IM node.exe\ngh pr merge 1 --squash\nStop-Process -Name node"}}'
check "$MERGE" 0 "pass:   Write of a brief naming both commands" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/brief.md","content":"taskkill /IM node.exe\ngh pr merge 1 --squash\nStop-Process -Name node"}}'
check "$KILL" 0 "pass:   input that is not JSON" 'not json at all {'
check "$MERGE" 0 "pass:   empty input" ''
check "$MERGE" 0 "pass:   payload with no command" '{"tool_name":"Bash","tool_input":{}}'

# A heredoc or here-string fed to
# python3, python or py, whatever its body holds.
for tool in Bash PowerShell; do
  # In a shell's command string, refused. The first is the reviewer's command
  # that hung and held a worktree folder.
  refused "$PY" $tool $'bash -c \'python3 - <<E 2>/dev/null || echo nopython\nimport sys\nprint(sys.version)\nE\''
  refused "$PY" $tool $'bash -c "cd /c/work && python3 - <<\'E\'\nprint(1)\nE\n"'
  refused "$PY" $tool $'bash -c \'echo start\npython3 <<E\nprint(1)\nE\''
  refused "$PY" $tool $'bash -c "python - <<\'E\'\nprint(\'a\\nb\')\nE"'
  refused "$PY" $tool $'powershell -Command "@\'\nprint(1)\n\'@ | python3 -"'
  refused "$PY" $tool $'pwsh -c "@\'\nprint(\'C:\\\\work\')\n\'@ | python -"'
  # Good forms and look-alikes, through.
  passes "$PY" $tool 'python script.py'
  passes "$PY" $tool 'python3 script.py'
  passes "$PY" $tool 'python -c "print(1)"'
  passes "$PY" $tool $'python -c "print(\'a\\nb\')"'
  passes "$PY" $tool 'python3 -m pip --version'
  passes "$PY" $tool 'git commit -m "Never feed a heredoc to python3, it hangs"'
  passes "$PY" $tool 'echo "python3 - <<EOF hangs"'
  passes "$PY" $tool 'grep -rn "python3 <<" C:/work/orch'
  passes "$PY" $tool 'herdr agent prompt x "run python3 - <<EOF"'
  passes "$PY" $tool "bash -c 'python script.py'"
  passes "$PY" $tool 'cmd /c python -c "print(1)"'
done

# Bash only: python3 with any heredoc or here-string, refused.
refused "$PY" Bash $'python3 <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'python3 - <<\'EOF\'\nprint(1)\nEOF'
refused "$PY" Bash $'python3 <<"EOF"\nprint(1)\nEOF'
refused "$PY" Bash $'python3 - <<-EOF\n\tprint(1)\n\tEOF'
refused "$PY" Bash $'python3<<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'python3.exe - <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'/c/Users/user/AppData/Local/Microsoft/WindowsApps/python3 - <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'C:/Users/user/AppData/Local/Python/bin/python3.exe - <<EOF\nprint(1)\nEOF'
refused "$PY" Bash 'python3 <<< "print(1)"'
refused "$PY" Bash "python3<<<'print(1)'"
refused "$PY" Bash $'cat <<\'EOF\' | python3\nprint(1)\nEOF'
refused "$PY" Bash $'cd C:/work && python3 - <<\'EOF\' 2>/dev/null || echo nopython\nprint(1)\nEOF'
refused "$PY" Bash $'python3 -c "import sys; print(sys.stdin.read())" <<EOF\ndata\nEOF'
refused "$PY" Bash $'env python3 - <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'echo start\npython3 - <<EOF\nprint(1)\nEOF\necho done'
# python and py with a heredoc or here-string, refused, with and without a
# backslash in the body.
refused "$PY" Bash $'python - <<\'EOF\'\nprint("hello")\nEOF'
refused "$PY" Bash $'python <<EOF\nimport json\nprint(json.dumps({"a": 1}))\nEOF'
refused "$PY" Bash $'py <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'py - <<\'EOF\'\nprint(1)\nEOF'
refused "$PY" Bash $'python.exe - <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'python3.14 - <<EOF\nprint(1)\nEOF'
refused "$PY" Bash $'cat <<\'EOF\' | python -\nprint(1)\nEOF'
refused "$PY" Bash $'python - <<\'EOF\'\nprint("a\\nb")\nEOF'
refused "$PY" Bash $'python <<EOF\nx = 1 + \\\n    2\nEOF'
refused "$PY" Bash $'python - <<\'EOF\'\nopen("C:\\\\work\\\\x.txt", "w").write("\\u00a3")\nEOF'
refused "$PY" Bash $'py - <<\'EOF\'\nprint("a\\tb")\nEOF'
refused "$PY" Bash $'python.exe - <<EOF\nprint("a\\nb")\nEOF'
refused "$PY" Bash $'C:/Users/user/AppData/Local/Python/bin/python.exe - <<EOF\nimport re; print(re.sub(r"\\s", "", "a b"))\nEOF'
refused "$PY" Bash $'python3.13 - <<EOF\nprint("a\\nb")\nEOF'
refused "$PY" Bash $'python <<< \'print("a\\nb")\''
refused "$PY" Bash $'cat <<\'EOF\' | python -\nprint("a\\nb")\nEOF'
refused "$PY" Bash $'python <<< \'print(1)\''
refused "$PY" Bash 'python <<< "print(1)"'
refused "$PY" Bash $'cd C:/work && python - <<\'EOF\' 2>/dev/null || echo nopython\nprint(1)\nEOF'
# Good forms and look-alikes, through.
passes "$PY" Bash $'python -c "$(cat <<\'EOF\'\nprint(1)\nEOF\n)"'
passes "$PY" Bash $'py -c "$(cat <<EOF\nprint(1)\nEOF\n)"'
passes "$PY" Bash 'echo "print(1)" | python'
passes "$PY" Bash 'echo "print(1)" | py -'
passes "$PY" Bash $'code=$(cat <<\'EOF\'\nprint(1)\nEOF\n)\necho "$code" | python -'
passes "$PY" Bash $'cat <<\'EOF\' | grep x | python x.py\nx\nEOF'
passes "$PY" Bash $'cat > x.txt <<\'EOF\'\nC:\\work\\path\nprint("a\\nb")\nEOF'
passes "$PY" Bash $'cat > "$TMP/x.py" <<\'EOF\'\nprint("a\\nb")\nEOF\npython "$TMP/x.py"'
# A heredoc fed to node is refused too.
refused "$PY" Bash $'node - <<\'EOF\'\nconsole.log("a\\nb")\nEOF'
refused "$PY" Bash $'node <<EOF\n// python3 hangs here, node does not\nconsole.log(1)\nEOF'
passes "$PY" Bash $'git commit -F - <<\'EOF\'\nRefuse python3 - <<EOF in a hook.\nEOF'
passes "$PY" Bash $'python3 -c "$(cat <<\'EOF\'\nprint(1)\nEOF\n)"'
passes "$PY" Bash $'cat <<\'EOF\' | grep x | python3 x.py\nx\nEOF'
passes "$PY" Bash 'echo "print(1)" | python3'

# PowerShell only: a here-string piped in.
refused "$PY" PowerShell $'@\'\nprint(1)\n\'@ | python3 -'
refused "$PY" PowerShell $'@"\nprint(1)\n"@ | python3'
refused "$PY" PowerShell $'$out = @\'\nprint(1)\n\'@ | python3 -'
refused "$PY" PowerShell $'@\'\nprint("a\\nb")\n\'@ | python -'
refused "$PY" PowerShell $'@\'\nprint("C:\\\\work")\n\'@ | py -'
refused "$PY" PowerShell $'@\'\nprint("hello")\n\'@ | python -'
refused "$PY" PowerShell $'@"\nprint(1)\n"@ | py'
passes "$PY" PowerShell $'$code = @\'\nprint("a\\nb")\n\'@\nSet-Content -Path x.py -Value $code\npython x.py'
passes "$PY" PowerShell $'python -c @\'\nprint(1)\n\'@'
passes "$PY" PowerShell 'Get-Content x.py | python -'
passes "$PY" PowerShell 'python3 --version'

# The payload's JSON escapes: \r, \u and \\n read as the text they stand for.
check "$PY" 2 "refuse: python heredoc with CRLF line ends, no backslash" \
  '{"tool_name":"Bash","tool_input":{"command":"python - <<'\''EOF'\''\r\nprint(1)\r\nEOF"}}'
check "$PY" 2 "refuse: python heredoc with a \\u escape, no backslash" \
  '{"tool_name":"Bash","tool_input":{"command":"python - <<'\''EOF'\''\nprint(\"\u00a3\")\nEOF"}}'
check "$PY" 2 "refuse: python heredoc with an escaped backslash before n" \
  '{"tool_name":"Bash","tool_input":{"command":"python - <<'\''EOF'\''\nprint(\"a\\nb\")\nEOF"}}'
check "$PY" 0 "pass:   Write of a script with a python3 heredoc" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/run.sh","content":"python3 - <<EOF\nprint(1)\nEOF"}}'

# The library's changes for here-strings, as the other hooks see them: a here-string's
# end line stays in the pipeline, a command string keeps its lines, and a
# heredoc body that ends in a backslash no longer swallows its end line.
refused "$KILL" PowerShell $'$x = @\'\nnotes\n\'@ | Out-Null; Stop-Process -Name node'
refused "$KILL" Bash $'bash -c "echo start\ntaskkill /IM node.exe"'
refused "$KILL" Bash $'cat > x.txt <<\'EOF\'\nC:\\work\\\nEOF\ntaskkill /IM node.exe'

# R6: rm on a substituted or unguarded path, Bash tool.
# A command substitution, quoted or not.
refused "$UNSAFE" Bash 'rm -rf "$(git rev-parse --show-toplevel)/build"'
refused "$UNSAFE" Bash 'rm -f $(mktemp)'
refused "$UNSAFE" Bash 'rm -rf `pwd`/build'
refused "$UNSAFE" Bash 'rm -rf "`pwd`/build"'
refused "$UNSAFE" Bash 'rm -rf -- "$(dirname "$f")"'
# A variable with no guard, in every spelling.
refused "$UNSAFE" Bash 'rm -rf $T/*'
refused "$UNSAFE" Bash 'rm -rf "$d/build"'
refused "$UNSAFE" Bash 'rm -rf "${d}/build"'
refused "$UNSAFE" Bash 'rm -rf ${d}/build'
refused "$UNSAFE" Bash 'rm "$f"'
refused "$UNSAFE" Bash 'rm -f $f'
refused "$UNSAFE" Bash 'rm -rf "$HOMEDIR/x"'
refused "$UNSAFE" Bash 'rm -rf "$TMPDIRX/x"'
refused "$UNSAFE" Bash 'rm -rf "${HOME:-/tmp}/x"'
refused "$UNSAFE" Bash 'rm -rf "$HOME/x" "$OTHER/y"'
refused "$UNSAFE" Bash 'rm -rf "${T:-/tmp}/x"'
refused "$UNSAFE" Bash 'rm -rf "${T?}/x"'
refused "$UNSAFE" Bash 'rm -rf "${T:=/tmp}/x"'
refused "$UNSAFE" Bash 'rm -rf "${d%/*}/x"'
refused "$UNSAFE" Bash 'rm -rf "$NOPE_UNSET/x"'
refused "$UNSAFE" Bash 'rm -rf "${T:?}/a" "$U/b"'
refused "$UNSAFE" Bash 'rm -r -f -- "$d"'
# Where the rm stands.
refused "$UNSAFE" Bash 'cd /tmp && rm -rf "$d/x"'
refused "$UNSAFE" Bash 'd=$(mktemp -d) && rm -rf "$d/build"'
refused "$UNSAFE" Bash $'echo start\nrm -rf "$d/x"\necho done'
refused "$UNSAFE" Bash '/bin/rm -rf "$d"/x'
refused "$UNSAFE" Bash 'command rm -rf "$d"/x'
refused "$UNSAFE" Bash 'x=1 rm -rf "$d"/x'
refused "$UNSAFE" Bash 'if true; then rm -rf "$d/x"; fi'
refused "$UNSAFE" Bash 'rm -rf "${T:?}/x" 2>"$E/err"'
# A command string is read with the same rules.
refused "$UNSAFE" Bash 'bash -c '\''rm -rf "$x/y"'\'''
refused "$UNSAFE" Bash 'bash -c "rm -rf $x/y"'
refused "$UNSAFE" Bash "sh -c 'cd /tmp && rm -rf \$(pwd)/x'"
# The sanctioned form, and literal paths, through.
passes "$UNSAFE" Bash 'rm "${T:?}/x"'
passes "$UNSAFE" Bash 'rm -rf "${WORK:?}"'
passes "$UNSAFE" Bash 'rm -rf "${T:?}"/*'
passes "$UNSAFE" Bash 'd=$(mktemp -d) && rm -rf "${d:?}"'
passes "$UNSAFE" Bash 'rm -rf "${T:?set T first}/x"'
passes "$UNSAFE" Bash 'rm -rf ${T:?}/x'
passes "$UNSAFE" Bash 'rm -f "${A:?}" "${B:?}/y"'
passes "$UNSAFE" Bash 'rm -rf "${T:?}" && echo done'
passes "$UNSAFE" Bash 'bash -c '\''rm -rf "${x:?}/y"'\'''
passes "$UNSAFE" Bash 'rm -f build/out.txt'
passes "$UNSAFE" Bash 'rm -rf /tmp/proj-test-123'
passes "$UNSAFE" Bash 'rm -rf node_modules/.cache'
passes "$UNSAFE" Bash 'rm -f ~/x.log'
# The always-set variables, by whole name.
passes "$UNSAFE" Bash 'rm -rf "$HOME/x"'
passes "$UNSAFE" Bash 'rm -rf "${HOME}/x"'
passes "$UNSAFE" Bash 'rm -rf $HOME/x'
passes "$UNSAFE" Bash 'rm -f "$TMPDIR/x" "$TEMP/y" "$TMP/z"'
passes "$UNSAFE" Bash 'rm -f "$PWD/x" "$USERPROFILE/y"'
passes "$UNSAFE" Bash 'rm -f x 2>/dev/null'
passes "$UNSAFE" Bash 'rm -f "${T:?}/x" >"$LOG" 2>&1'
passes "$UNSAFE" Bash "rm -rf 'literal \$HOME'"
passes "$UNSAFE" Bash 'rm -rf "\$HOME"'
# Quoted text, a heredoc body, a commit message, a comment, and look-alikes.
passes "$UNSAFE" Bash "echo 'rm -rf \$HOME'"
passes "$UNSAFE" Bash 'echo "rm -rf $(pwd)/x"'
passes "$UNSAFE" Bash 'git commit -m "rm -rf $x"'
passes "$UNSAFE" Bash 'git commit -m "Never rm -rf $(git rev-parse --show-toplevel)/build"'
passes "$UNSAFE" Bash 'grep -n "rm -rf $x" notes.md'
passes "$UNSAFE" Bash 'herdr agent prompt x "run rm -rf $d/build"'
passes "$UNSAFE" Bash $'cat > brief.md <<\'EOF\'\nrm -rf $T/*\nrm -f $(mktemp)\nEOF\necho written'
passes "$UNSAFE" Bash '# rm -rf $T/* is a trap'
passes "$UNSAFE" Bash 'ls "$(pwd)/x" "$d/y"'
passes "$UNSAFE" Bash 'cd "$(git rev-parse --show-toplevel)" && rm -rf build'
passes "$UNSAFE" Bash 'rmdir "$d"'
passes "$UNSAFE" Bash 'mv "$a" "$b"'
passes "$UNSAFE" Bash $'x=$(cat <<\'EOF\'\nrm -rf $T/*\nEOF\n)'
# PowerShell's Remove-Item and its redirects are a known gap, so the PowerShell
# tool passes them.
passes "$UNSAFE" PowerShell 'Remove-Item -Recurse -Force "$d\build"'
passes "$UNSAFE" PowerShell 'rm -r "$env:TEMP\x"'
passes "$UNSAFE" PowerShell 'Write-Output hi > "$T\out.txt"'

# R6: a redirect to a substituted path, or to an unguarded
# variable followed by a slash.
refused "$UNSAFE" Bash 'echo x > "$T/out"'
refused "$UNSAFE" Bash 'echo x >> $T/out.log'
refused "$UNSAFE" Bash 'cmd 2> "$E/err"'
refused "$UNSAFE" Bash 'cmd 2>"$E/err" >"$E/out"'
refused "$UNSAFE" Bash 'echo x &> "$T/log"'
refused "$UNSAFE" Bash 'echo x >&"$T/log"'
refused "$UNSAFE" Bash 'echo x > "${T}/out"'
refused "$UNSAFE" Bash 'echo x > "${T:-/tmp}/out"'
refused "$UNSAFE" Bash 'echo x >$T\out'
refused "$UNSAFE" Bash 'echo x >"$T"/out'
refused "$UNSAFE" Bash 'echo x > $(mktemp)'
refused "$UNSAFE" Bash 'echo x >$(mktemp)'
refused "$UNSAFE" Bash 'echo x > "$(mktemp)"'
refused "$UNSAFE" Bash 'echo x > `mktemp`'
refused "$UNSAFE" Bash 'echo x > $(mktemp -d)/out'
refused "$UNSAFE" Bash 'echo x > "$(git rev-parse --show-toplevel)/out"'
refused "$UNSAFE" Bash '>"$T/out" echo x'
refused "$UNSAFE" Bash 'cmd 2>&1 | tee a.log > "$T/out"'
refused "$UNSAFE" Bash 'cd /tmp && echo x > "$T/out"'
refused "$UNSAFE" Bash $'cat > "$d/x" <<\'EOF\'\nbody\nEOF'
refused "$UNSAFE" Bash 'bash -c '\''echo x > "$T/out"'\'''
refused "$UNSAFE" Bash 'for f in a b; do echo $f; done > "$T/list"'
refused "$UNSAFE" Bash 'echo x > "$TMPDIRX/out"'
refused "$UNSAFE" Bash 'echo x > "$HOMEDIR/out"'
refused "$UNSAFE" Bash 'echo x >> "$PWDX/out"'
refused "$UNSAFE" Bash 'echo x > "${HOME:-/tmp}/out"'
# The common shapes, through.
passes "$UNSAFE" Bash 'echo x > "$TMPDIR/out"'
passes "$UNSAFE" Bash 'echo x > "$PWD/x"'
passes "$UNSAFE" Bash 'echo x >> "${HOME}/.cache/x" 2>"$TEMP/err"'
passes "$UNSAFE" Bash 'echo x > $TMP\out'
passes "$UNSAFE" Bash 'echo x > "$USERPROFILE/x"'
passes "$UNSAFE" Bash 'cmd >"$T" 2>&1'
passes "$UNSAFE" Bash 'cmd > "$T"'
passes "$UNSAFE" Bash 'cmd >> $LOG'
passes "$UNSAFE" Bash 'cmd >>"$LOG" 2>&1'
passes "$UNSAFE" Bash 'cmd 2>/dev/null'
passes "$UNSAFE" Bash 'cmd >&2'
passes "$UNSAFE" Bash 'cmd >/dev/null 2>&1'
passes "$UNSAFE" Bash 'cmd 2>&1 >/dev/null'
passes "$UNSAFE" Bash 'cmd &>/dev/null'
passes "$UNSAFE" Bash 'cmd &>"$LOG"'
passes "$UNSAFE" Bash 'cmd > "${T:?}/out"'
passes "$UNSAFE" Bash 'cmd > "${T:?}/a" 2> "${T:?}/b"'
passes "$UNSAFE" Bash 'cmd > ${T:?}/out'
passes "$UNSAFE" Bash 'cmd > out.txt'
passes "$UNSAFE" Bash 'cmd > /tmp/proj-x.log 2>&1'
passes "$UNSAFE" Bash 'cmd > ./build/out.txt'
passes "$UNSAFE" Bash 'cmd 2>&1 | tee "$LOG"'
passes "$UNSAFE" Bash 'cmd < "$IN"'
passes "$UNSAFE" Bash 'cmd < "$IN/x"'
passes "$UNSAFE" Bash 'cmd <<< "$x"'
passes "$UNSAFE" Bash 'echo "a > $T/b"'
passes "$UNSAFE" Bash "echo x > '\$T/out'"
passes "$UNSAFE" Bash 'echo "$(pwd)/x" > out.txt'
passes "$UNSAFE" Bash 'git log --format="%h > %s" | head -5'
passes "$UNSAFE" Bash $'cat > out.txt <<\'EOF\'\n$T/x > $T/y\nEOF'
passes "$UNSAFE" Bash 'git commit -m "x > $T/y"'
# A comment is not a command.
passes "$UNSAFE" Bash 'echo ok # writes > $T/out'
passes "$UNSAFE" Bash 'rm -f x.txt # not $T/y'
passes "$UNSAFE" Bash $'# keep the log > $T/out\necho ok'
refused "$UNSAFE" Bash 'echo x > "$T/out" # note'
refused "$UNSAFE" Bash $'# remove it\nrm -rf "$d/x"'

# R13: git that changes state, piped to tail or head.
for tool in Bash PowerShell; do
  refused "$UNSAFE" $tool 'git push 2>&1 | tail -3'
  refused "$UNSAFE" $tool 'git -C repo push | head'
  refused "$UNSAFE" $tool 'git push | tee log | tail -1'
  refused "$UNSAFE" $tool 'git commit -m x | tail -1'
  refused "$UNSAFE" $tool 'git revert HEAD | head -5'
  refused "$UNSAFE" $tool 'git merge main 2>&1 | tail'
  refused "$UNSAFE" $tool 'git rebase main | tail -5'
  refused "$UNSAFE" $tool 'git reset --hard origin/main | tail -2'
  refused "$UNSAFE" $tool 'git cherry-pick abc123 | head -3'
  refused "$UNSAFE" $tool 'git -c core.pager=cat push | tail'
  refused "$UNSAFE" $tool 'git --no-pager push | head'
  refused "$UNSAFE" $tool 'git --git-dir=.git --work-tree=. push | tail'
  refused "$UNSAFE" $tool 'git.exe push | tail'
  refused "$UNSAFE" $tool 'cd repo && git push origin HEAD 2>&1 | grep -v hint | tail -1'
  refused "$UNSAFE" $tool 'GIT_TERMINAL_PROMPT=0 git push | tail'
  refused "$UNSAFE" $tool 'git push | tail -3; echo "exit $?"'
  refused "$UNSAFE" $tool 'git push | tail -3; set -o pipefail'
  refused "$UNSAFE" $tool 'echo "$PIPESTATUS"; git push | tail -3'
  refused "$UNSAFE" $tool 'set +o pipefail; git push | tail -3'
  refused "$UNSAFE" $tool 'git status && git push | tail -3'
  refused "$UNSAFE" $tool "git push | tail -3 # set -o pipefail"
  passes "$UNSAFE" $tool 'git log --oneline | head -5'
  passes "$UNSAFE" $tool 'git diff main | head'
  passes "$UNSAFE" $tool 'git status | tail -3'
  passes "$UNSAFE" $tool 'git show HEAD | head -20'
  passes "$UNSAFE" $tool 'git fetch 2>&1 | tail -2'
  passes "$UNSAFE" $tool 'git -C repo log --oneline | head -3'
  passes "$UNSAFE" $tool 'git branch --list | head'
  passes "$UNSAFE" $tool 'git push 2>&1 | cat'
  passes "$UNSAFE" $tool 'git push > "$LOG" 2>&1'
  passes "$UNSAFE" $tool 'git push && git log | head -3'
  passes "$UNSAFE" $tool 'git push; tail -3 push.log'
  passes "$UNSAFE" $tool 'tail -3 push.log | git commit -F -'
  passes "$UNSAFE" $tool 'echo "git push | tail -3"'
  passes "$UNSAFE" $tool 'git commit -m "Never git push | tail, it hides the exit"'
  passes "$UNSAFE" $tool 'grep -n "git push | tail" notes.md'
done
# Bash only: the two ways to keep the exit status.
refused "$UNSAFE" Bash "bash -c 'git push | tail -3'"
passes "$UNSAFE" Bash 'set -o pipefail; git push | tail -3'
passes "$UNSAFE" Bash 'set -euo pipefail; git push 2>&1 | tail -3'
passes "$UNSAFE" Bash 'set -o pipefail && cd repo && git push | tail -3'
passes "$UNSAFE" Bash 'bash -o pipefail -c "git push | tail -3"'
passes "$UNSAFE" Bash "bash -c 'set -o pipefail; git push | tail -3'"
passes "$UNSAFE" Bash 'git push 2>&1 | tail -3; echo "exit ${PIPESTATUS[0]}"'
passes "$UNSAFE" Bash 'git push | tail -3; echo ${PIPESTATUS[0]}'
passes "$UNSAFE" Bash 'git push | tail -3; echo "exit $PIPESTATUS"'
passes "$UNSAFE" Bash 'git push | tail -3; rc=${PIPESTATUS[0]}'
passes "$UNSAFE" Bash 'git push | tail -3; rc="${PIPESTATUS[0]}"; exit $rc'
passes "$UNSAFE" Bash 'git push | tail -3; rc=("${PIPESTATUS[@]}")'
passes "$UNSAFE" Bash 'git push | tail -3; [ "${PIPESTATUS[0]}" -eq 0 ] || exit 1'

# The messages name the fix.
says "$UNSAFE" Bash 'rm -rf "$d/build"' '${WORK:?}'
says "$UNSAFE" Bash 'rm -rf "$d/build"' 'aborts the command'
says "$UNSAFE" Bash 'echo x > "$T/out"' '${T:?}'
says "$UNSAFE" Bash 'git push | tail -3' 'PIPESTATUS[0]'
says "$UNSAFE" Bash 'git push | tail -3' 'mktemp'
says "$PY" Bash $'python - <<\'EOF\'\nprint(1)\nEOF' '120 second'
says "$PY" Bash $'python - <<\'EOF\'\nprint(1)\nEOF' 'python <file>'
says "$PY" Bash $'py <<EOF\nprint(1)\nEOF' 'fed to py'

# The library's changes for R6, as the other hooks see them: an unquoted ${...}
# stays one word, and a $( or backtick still starts a command of its own.
refused "$KILL" Bash 'echo ${x} && taskkill /IM node.exe'
refused "$KILL" Bash 'taskkill /IM ${NAME}'
refused "$KILL" Bash 'cd ${DIR}; taskkill /IM node.exe'
refused "$KILL" Bash 'echo $(date) && taskkill /IM node.exe'
refused "$KILL" Bash 'echo `date`; taskkill /IM node.exe'
refused "$KILL" Bash 'x=$(echo 1) taskkill /IM node.exe'
passes "$KILL" Bash 'taskkill /PID ${PID}'
passes "$KILL" Bash 'taskkill //PID $(cat pid.txt)'
passes "$MERGE" Bash 'gh pr merge 1 --squash --subject x --body ${BODY}'
passes "$MERGE" Bash 'gh pr merge 1 --squash --subject "$(echo x)" --body "${B}"'
refused "$MERGE" Bash 'gh pr merge 1 --squash --subject ${S}'
refused "$PY" Bash $'python3 - <<EOF\nprint(${x})\nEOF'
passes "$PY" Bash 'python -c "print(1)" ${ARGS}'

# Fixes after an independent check.
# F1: a redirect glued to a word is judged like a spaced one.
refused "$UNSAFE" Bash 'echo x>"$T/out"'
refused "$UNSAFE" Bash 'echo x>$T/out'
refused "$UNSAFE" Bash 'echo x>>"$T/out"'
refused "$UNSAFE" Bash 'cmd 2>"$d/err"'
refused "$UNSAFE" Bash 'cmd>"$LOG/x"'
refused "$UNSAFE" Bash 'cmd 2>>$d/err'
refused "$UNSAFE" Bash 'echo x>$(mktemp)'
refused "$UNSAFE" Bash 'echo x>"$TMPDIRX/out"'
refused "$UNSAFE" Bash 'cmd a>b>"$d/c"'
passes "$UNSAFE" Bash 'echo x>"${T:?}/out"'
passes "$UNSAFE" Bash 'echo x>"$T"'
passes "$UNSAFE" Bash 'echo x>out.txt'
passes "$UNSAFE" Bash 'echo x>/dev/null'
passes "$UNSAFE" Bash 'cmd 2>/dev/null'
passes "$UNSAFE" Bash 'cmd a>&2'
passes "$UNSAFE" Bash 'cmd 2>"$TMPDIR/err"'
passes "$UNSAFE" Bash 'echo "x>$T/out"'
passes "$UNSAFE" Bash 'echo $((1>0))'
# F2: a quoted variable glued to text in an rm argument is judged like a bare one.
refused "$UNSAFE" Bash 'rm -rf /tmp/x"$d"'
refused "$UNSAFE" Bash 'rm -rf pre_"$x"'
refused "$UNSAFE" Bash 'rm -rf ".cache""$v"'
refused "$UNSAFE" Bash 'rm -rf x"$(date)"'
refused "$UNSAFE" Bash 'rm -rf /tmp/x"${d}"'
passes "$UNSAFE" Bash 'rm -rf /tmp/x"${d:?}"'
passes "$UNSAFE" Bash "rm -rf pre_'\$x'"
passes "$UNSAFE" Bash 'rm -rf /tmp/x"literal"'
passes "$UNSAFE" Bash 'rm -rf Q1.txt'
passes "$UNSAFE" Bash 'rm -rf Q99'
refused "$UNSAFE" Bash 'rm -rf Q99"$x"'
passes "$UNSAFE" Bash 'rm -rf x"$HOME"'
# F4 of the check: a line that ends in "$@" is not a PowerShell here-string
# opener, so the lines after it are read by every hook.
refused "$UNSAFE" Bash $'exec "$@"\nrm -rf "$d/x"'
refused "$UNSAFE" Bash $'foo "$@"\ngit push | tail -3'
refused "$UNSAFE" Bash 'rm -rf "$@"'
refused "$KILL" Bash $'foo "$@"\ntaskkill /IM node.exe'
refused "$MERGE" Bash $'foo "$@"\ngh pr merge 1 --squash'
refused "$PY" Bash $'foo "$@"\npython - <<\'EOF\'\nprint(1)\nEOF'
refused "$KILL" Bash $'echo \'$@\'\ntaskkill /IM node.exe'
passes "$UNSAFE" Bash $'foo "$@"\ngit log | tail -3'
passes "$KILL" Bash $'foo "$@"\ntaskkill /PID 999999'
passes "$PY" Bash $'foo "$@"\npython script.py'
# A PowerShell here-string still hides its body from the hooks.
passes "$UNSAFE" PowerShell $'$x = @\'\ngit push | tail -3\n\'@\nWrite-Output $x'
refused "$UNSAFE" PowerShell $'foo "$@"\ngit push | tail -3'
refused "$KILL" PowerShell $'$x = @\'\nbody\n\'@\ntaskkill /IM node.exe'

# Other tools and unreadable input, through (the hook fails open).
check "$UNSAFE" 0 "pass:   Write of a script with rm and git push" \
  '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/run.sh","content":"rm -rf $T/*\ngit push | tail -3\necho x > $T/out"}}'
check "$UNSAFE" 0 "pass:   input that is not JSON" 'not json at all {'
check "$UNSAFE" 0 "pass:   empty input" ''
check "$UNSAFE" 0 "pass:   payload with no command" '{"tool_name":"Bash","tool_input":{}}'

# W3: every hook file parses, and a crash never refuses. A broken copy of
# each top-level script, with a syntax error just after its trap line or in
# its middle, must let a bad command through. Only a deliberate refusal exits 2.
for f in "$KILL" "$MERGE" "$PY" "$UNSAFE" "$EDITS" "$PRINT" "$HERE/refuse-dev-vars.sh" "$HERE/lib/command-position.sh" "$HERE/test-command-hooks.sh" "$HERE/test-dev-vars.sh"; do
  COUNT=$((COUNT + 1))
  if bash -n "$f"; then
    printf 'ok    bash -n parses %s\n' "${f#"$HERE"/}"
  else
    printf 'FAIL  bash -n %s\n' "${f#"$HERE"/}"
    FAILED=1
  fi
done
mkdir -p "$BROKEN/lib"
cp "$HERE/lib/command-position.sh" "$BROKEN/lib/"
for hook in "$KILL" "$MERGE" "$PY" "$UNSAFE" "$EDITS" "$PRINT"; do
  name=${hook##*/}
  half=$(( $(wc -l < "$hook") / 2 ))
  sed "${half}a if then fi ((" "$hook" > "$BROKEN/middle-$name"
  sed "/^trap /a if then fi ((" "$hook" > "$BROKEN/early-$name"
done
for broken in "$BROKEN"/middle-* "$BROKEN"/early-*; do
  payload Bash 'taskkill /IM node.exe'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets taskkill /IM through" "$PAYLOAD"
  payload Bash 'gh pr merge 1 --squash'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets gh pr merge through" "$PAYLOAD"
  payload Bash $'python3 - <<EOF\nprint(1)\nEOF'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets a python3 heredoc through" "$PAYLOAD"
  payload Bash 'rm -rf "$NOPE_UNSET/x"'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets rm on an unguarded variable through" "$PAYLOAD"
  payload Bash 'git push | tail -3'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets a piped git push through" "$PAYLOAD"
  payload Bash "sed -i 's/a/b/' C:/work/x/f.md"
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets sed -i through" "$PAYLOAD"
  payload Bash 'cat store/.dev.vars'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets cat of a .dev.vars file through" "$PAYLOAD"
  payload Bash 'python -'
  check "$broken" 0 "pass:   broken copy ${broken##*/} lets python - through" "$PAYLOAD"
done

shell_edit_cases

one_bash_cases

finish
