#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the cases are commands taken literally, $ and all, and cases.sh reads CASE_NAMES
#
# Tests refuse-dev-vars.sh (the Read, Write and Edit tools) and the command half,
# refuse-dev-vars-print.sh (the Bash and PowerShell tools), by feeding each a
# Claude Code PreToolUse payload on standard input, as the harness does. No
# real .dev.vars file is read or written: every
# path below is a name only, and the hooks look at the name alone.
#
# The case runner, the CASES filter, --list, the time limit and the counts line
# are in cases.sh (CASES_SH, the tests/cases.sh beside the hooks folder by default).
# DEV_VARS_HOOK and PRINT_HOOK point the test at other copies of the two hooks.
# A copy of the print hook needs lib/ beside it.
# Cases, each its own function. The first group is refuse-dev-vars.sh:
#   windows_path          Read, Write and Edit of C:\work\x\store\.dev.vars are refused
#   posix_path            store/.dev.vars and /c/work/x/.dev.vars are refused
#   upper_case            .DEV.VARS and C:\X\.Dev.Vars are refused
#   dot_suffix            .dev.vars.local, .dev.vars.production and .dev.vars.example.bak are refused
#   quoted_path           a path in double or single quotes is refused
#   raw_backslashes       a path with unescaped backslashes is refused
#   stream_and_space      .dev.vars:Zone.Identifier and .dev.vars with a trailing space are refused
#   example_passes        .dev.vars.example passes, in any case, for the three tools
#   lookalikes_pass       dev.vars.md, my.dev.vars, .dev.varsx and a file inside a folder named .dev.vars pass
#   message               the message names the secrets, the example file and the grep -c check
#   fails_open            other input passes, and a hook with a syntax error exits 0
#   big_payload           file_path first is refused at any size, 2 KB before it is refused, 20 KB before it
#                         passes with one line on standard error, and a short payload stays silent
# The second group is refuse-dev-vars-print.sh:
#   print_cat             cat of a .dev.vars file is refused, in both tools
#   print_get_content     Get-Content, gc and -Path forms are refused
#   print_type            type is refused
#   print_readers         head, tail, less, more and bat are refused, by path and with flags
#   print_suffix          .dev.vars.local is refused
#   print_grep_passes     grep -c and grep -q on the file pass
#   print_example_passes  .dev.vars.example passes
#   print_quoted          a quoted path is refused
#   print_glob            a glob that reaches .dev.vars or .dev.vars.local is refused
#   print_redirect_from   a redirect from the file, spaced or glued, is refused
#   print_command_string  bash -c and powershell -Command strings are read
#   print_case_and_slash  any case, either slash, a stream suffix and a trailing space are refused
#   print_lookalikes_pass names that only look like the file, and quoted or heredoc text, pass
#   print_message         the message names the secrets, the example file and the grep -c check
#   print_fails_open      other input passes, and a hook with a syntax error exits 0
#   names_agree           both hooks give the same verdict on one list of names
# Linux paths:
#   linux_path            Linux paths: Read, Write and Edit of /srv/work/x/.dev.vars, and cat and head of it, are refused,
#                         and /srv/work/x/.dev.vars.example passes

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASES_SH="${CASES_SH:-$HERE/../tests/cases.sh}"
if [[ ! -f "$CASES_SH" ]]; then
  echo "test-dev-vars.sh: cases.sh is not at $CASES_SH, so no case ran. Set CASES_SH to its path." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$CASES_SH"
DEV_VARS="${DEV_VARS_HOOK:-$HERE/refuse-dev-vars.sh}"
PRINT="${PRINT_HOOK:-$HERE/refuse-dev-vars-print.sh}"

CASE_NAMES=(
  windows_path posix_path upper_case dot_suffix quoted_path raw_backslashes stream_and_space
  example_passes lookalikes_pass message fails_open big_payload
  print_cat print_get_content print_type print_readers print_suffix print_grep_passes
  print_example_passes print_quoted print_glob print_redirect_from print_command_string
  print_case_and_slash print_lookalikes_pass print_message print_fails_open names_agree
  linux_path
)
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

# file_payload <tool> <path>: PAYLOAD is a Read, Write or Edit payload.
file_payload() {
  json_string "$2"
  printf -v PAYLOAD '{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":%s,"content":"x"}}' "$1" "$JSON"
}

# cmd_payload <tool> <command>: PAYLOAD is a Bash or PowerShell payload.
cmd_payload() {
  json_string "$2"
  printf -v PAYLOAD '{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"command":%s,"description":"test"}}' "$1" "$JSON"
}

# run_hook <hook> <payload>: RC is the exit status, ERRTEXT what the hook wrote to standard error.
run_hook() {
  bash "$1" 2>"$ERR" >/dev/null <<< "$2"
  RC=$?
  ERRTEXT=$(< "$ERR")
}

# For the three file tools: the path must be refused (or must pass) in each.
refuse_path() { # refuse_path <path>
  local tool
  for tool in Read Write Edit; do
    file_payload "$tool" "$1"
    run_hook "$DEV_VARS" "$PAYLOAD"
    [[ "$RC" == 2 ]] || WHY+=("$tool of $1 exits $RC, want 2")
  done
}
pass_path() { # pass_path <path>
  local tool
  for tool in Read Write Edit; do
    file_payload "$tool" "$1"
    run_hook "$DEV_VARS" "$PAYLOAD"
    [[ "$RC" == 0 ]] || WHY+=("$tool of $1 exits $RC, want 0")
  done
}

# For the command tool: the command must be refused (or must pass), in the tools named.
refuse_cmd() { # refuse_cmd <command> [tool]...
  local cmd="$1" tool
  shift
  for tool in "${@:-Bash}"; do
    cmd_payload "$tool" "$cmd"
    run_hook "$PRINT" "$PAYLOAD"
    [[ "$RC" == 2 ]] || WHY+=("[$tool] $cmd exits $RC, want 2")
  done
}
pass_cmd() { # pass_cmd <command> [tool]...
  local cmd="$1" tool
  shift
  for tool in "${@:-Bash}"; do
    cmd_payload "$tool" "$cmd"
    run_hook "$PRINT" "$PAYLOAD"
    [[ "$RC" == 0 ]] || WHY+=("[$tool] $cmd exits $RC, want 0")
  done
}

# mention <text>...: the last hook's message must hold each text.
mention() {
  local text
  for text in "$@"; do
    [[ "$ERRTEXT" == *"$text"* ]] || WHY+=("message lacks: $text")
  done
}

# broken_copy <hook> <out dir>: OUT is a copy of the hook, with lib/ beside it,
# and a syntax error on the line after its trap line.
broken_copy() {
  mkdir -p "$2/lib"
  cp "${1%/*}"/lib/*.sh "$2/lib/" 2>/dev/null
  sed '/^trap /a if then fi ((' "$1" > "$2/${1##*/}"
  OUT="$2/${1##*/}"
}

# The names both hooks must agree on, refused first and passed after.
REFUSED_NAMES=(
  '.dev.vars' 'store/.dev.vars' 'C:/work/x/store/.dev.vars' '.DEV.VARS' '.Dev.Vars'
  '.dev.vars.local' '.dev.vars.production' '.dev.vars.example.bak' '.dev.vars.' '.dev.vars:Zone.Identifier'
)
PASSED_NAMES=(
  '.dev.vars.example' '.DEV.VARS.EXAMPLE' 'store/.dev.vars.example' 'dev.vars.md' 'my.dev.vars'
  '.dev.varsx' '.dev.var' 'notes.md' 'C:/work/.dev.vars/notes.txt' 'dev.vars'
)

case_windows_path() {
  refuse_path 'C:\work\x\store\.dev.vars'
  refuse_path 'c:\work\x\.dev.vars'
}

case_posix_path() {
  refuse_path 'store/.dev.vars'
  refuse_path '/c/work/x/.dev.vars'
  refuse_path 'C:/work/x/store/.dev.vars'
}

case_upper_case() {
  refuse_path '.DEV.VARS'
  refuse_path 'C:\X\.Dev.Vars'
}

case_dot_suffix() {
  refuse_path '.dev.vars.local'
  refuse_path 'C:\work\x\.dev.vars.production'
  refuse_path '.dev.vars.example.bak'
}

case_quoted_path() {
  refuse_path '"C:\work\x\.dev.vars"'
  refuse_path "'store/.dev.vars'"
}

case_raw_backslashes() {
  # Not valid JSON: the backslashes are not doubled. The hook reads them as slashes.
  local tool
  for tool in Read Write Edit; do
    run_hook "$DEV_VARS" '{"tool_name":"'"$tool"'","tool_input":{"file_path":"C:\work\x\store\.dev.vars"}}'
    [[ "$RC" == 2 ]] || WHY+=("$tool of a path with raw backslashes exits $RC, want 2")
  done
}

case_stream_and_space() {
  refuse_path 'C:\work\x\.dev.vars:Zone.Identifier'
  refuse_path '.dev.vars  '
}

case_example_passes() {
  pass_path 'C:\work\x\store\.dev.vars.example'
  pass_path 'store/.dev.vars.example'
  pass_path '.DEV.VARS.EXAMPLE'
}

case_lookalikes_pass() {
  pass_path 'C:\work\x\dev.vars.md'
  pass_path 'my.dev.vars'
  pass_path '.dev.varsx'
  pass_path '.dev.var'
  pass_path 'C:\work\.dev.vars\notes.txt'
  pass_path 'dev.vars'
}

case_message() {
  file_payload Read 'C:\work\x\.dev.vars'
  run_hook "$DEV_VARS" "$PAYLOAD"
  [[ "$RC" == 2 ]] || WHY+=("exit $RC, want 2")
  mention 'holds secrets' 'copies .dev.vars.example to .dev.vars and types the keys' \
    "grep -c '^EXAMPLE_API_KEY=abc_' .dev.vars"
}

case_fails_open() {
  local d="$WORK/open-dev-vars" input
  # Other tools and unreadable input.
  run_hook "$DEV_VARS" 'not json at all {'
  [[ "$RC" == 0 ]] || WHY+=("input that is not JSON exits $RC")
  run_hook "$DEV_VARS" ''
  [[ "$RC" == 0 ]] || WHY+=("empty input exits $RC")
  run_hook "$DEV_VARS" '{"tool_name":"Read","tool_input":{}}'
  [[ "$RC" == 0 ]] || WHY+=("a payload with no file_path exits $RC")
  # The content may name the file. Only file_path counts.
  run_hook "$DEV_VARS" '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/README.md","content":"copy .dev.vars and \"file_path\": \".dev.vars\""}}'
  [[ "$RC" == 0 ]] || WHY+=("a Write of README.md that names .dev.vars exits $RC")
  # A crash in the hook lets the call through.
  broken_copy "$DEV_VARS" "$d"
  for input in 'C:\work\x\.dev.vars' '.dev.vars'; do
    file_payload Read "$input"
    run_hook "$OUT" "$PAYLOAD"
    [[ "$RC" == 0 ]] || WHY+=("a copy with a syntax error exits $RC for $input, want 0")
  done
}

case_big_payload() {
  local pad head_small="" tool='{"session_id":"test","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":'
  printf -v pad '%*s' 20480 ''
  pad=${pad// /x}
  head_small=${pad:0:2048}
  # file_path first, as the harness writes it: refused however long the content is.
  run_hook "$DEV_VARS" "$tool"'{"file_path":"C:\\work\\x\\.dev.vars","content":"'"$pad"'"}}'
  [[ "$RC" == 2 ]] || WHY+=("a 20 KB Write of .dev.vars, file_path first, exits $RC, want 2")
  run_hook "$DEV_VARS" "$tool"'{"file_path":"C:\\work\\x\\README.md","content":"'"$pad"'"}}'
  [[ "$RC" == 0 && -z "$ERRTEXT" ]] || WHY+=("a 20 KB Write of README.md, file_path first, exits $RC with text on standard error")
  # 2 KB of content before file_path is still inside the 16 KB that is read.
  run_hook "$DEV_VARS" "$tool"'{"content":"'"$head_small"'","file_path":"C:\\work\\x\\.dev.vars"}}'
  [[ "$RC" == 2 ]] || WHY+=("2 KB of content before file_path exits $RC, want 2")
  # 20 KB before file_path is not seen. The call passes and the hook says so.
  run_hook "$DEV_VARS" "$tool"'{"content":"'"$pad"'","file_path":"C:\\work\\x\\.dev.vars"}}'
  [[ "$RC" == 0 ]] || WHY+=("20 KB of content before file_path exits $RC, want 0")
  mention 'refuse-dev-vars.sh' '16 KB' 'file_path' 'not checked'
  [[ "$ERRTEXT" != *$'\n'* ]] || WHY+=("the skipped-check notice is more than one line")
  # A short payload with no file_path is not a skipped check, so it stays silent.
  run_hook "$DEV_VARS" '{"tool_name":"Read","tool_input":{}}'
  [[ "$RC" == 0 && -z "$ERRTEXT" ]] || WHY+=("a short payload with no file_path exits $RC with text on standard error")
}

case_print_cat() {
  refuse_cmd 'cat store/.dev.vars' Bash PowerShell
  refuse_cmd 'cat .dev.vars' Bash PowerShell
  refuse_cmd 'cd C:/work/x && cat .dev.vars' Bash
}

case_print_get_content() {
  refuse_cmd 'Get-Content .\.dev.vars' PowerShell Bash
  refuse_cmd 'gc .dev.vars' PowerShell
  refuse_cmd 'Get-Content -Path .\.dev.vars -Raw' PowerShell
  refuse_cmd 'Get-Content -Path:.\.dev.vars' PowerShell
  refuse_cmd 'Get-Content -Path:.dev.vars' PowerShell
  refuse_cmd 'Get-Content C:\work\x\store\.dev.vars' PowerShell
}

case_print_type() {
  refuse_cmd 'type .dev.vars' Bash PowerShell
  refuse_cmd 'type C:\work\x\.dev.vars' PowerShell
}

case_print_readers() {
  refuse_cmd 'head .dev.vars'
  refuse_cmd 'head -n 5 store/.dev.vars'
  refuse_cmd 'tail .dev.vars'
  refuse_cmd 'tail -f .dev.vars'
  refuse_cmd 'less .dev.vars'
  refuse_cmd 'more .dev.vars'
  refuse_cmd 'bat .dev.vars'
  refuse_cmd 'bat --plain store/.dev.vars'
  refuse_cmd '/usr/bin/cat .dev.vars'
  refuse_cmd 'cat.exe .dev.vars'
  refuse_cmd 'cat README.md .dev.vars'
  refuse_cmd 'cat .dev.vars | grep -c KEY'
}

case_print_suffix() {
  refuse_cmd 'cat .dev.vars.local'
  refuse_cmd 'cat store/.dev.vars.production'
}

case_print_grep_passes() {
  pass_cmd "grep -c '^KEY=' .dev.vars" Bash PowerShell
  pass_cmd "grep -c '^EXAMPLE_API_KEY=abc_' store/.dev.vars"
  pass_cmd "grep -q '^KEY=sk_test_' .dev.vars && echo set"
  pass_cmd 'grep -c "^KEY=" C:/work/x/.dev.vars'
}

case_print_example_passes() {
  pass_cmd 'cat .dev.vars.example' Bash PowerShell
  pass_cmd 'cat store/.dev.vars.example'
  pass_cmd 'Get-Content .\.dev.vars.example' PowerShell
  pass_cmd 'head -5 .DEV.VARS.EXAMPLE'
}

case_print_quoted() {
  refuse_cmd 'cat "store/.dev.vars"'
  refuse_cmd "cat '.dev.vars'"
  refuse_cmd 'Get-Content "C:\work\x folder\.dev.vars"' PowerShell
}

case_print_glob() {
  refuse_cmd 'cat .dev.v*'
  refuse_cmd 'cat .dev.var?'
  refuse_cmd 'cat .dev.[v]ars'
  refuse_cmd 'cat .dev.v*.local'
  refuse_cmd 'head -3 store/.dev.vars*'
}

case_print_redirect_from() {
  refuse_cmd 'cat < .dev.vars'
  refuse_cmd 'head -3 <.dev.vars'
  refuse_cmd 'tail -2 <store/.dev.vars'
}

case_print_command_string() {
  refuse_cmd "bash -c 'cat .dev.vars'" Bash PowerShell
  refuse_cmd 'bash -c "head -3 store/.dev.vars"'
  refuse_cmd 'powershell -Command "Get-Content .\.dev.vars"' Bash PowerShell
  refuse_cmd 'pwsh -c "gc .dev.vars"' Bash
  refuse_cmd 'cmd /c type .dev.vars' Bash
  pass_cmd "bash -c 'grep -c ^KEY= .dev.vars'"
  pass_cmd 'powershell -Command "Get-Content .\.dev.vars.example"'
}

case_print_case_and_slash() {
  refuse_cmd 'CAT .DEV.VARS' Bash
  refuse_cmd 'Get-Content C:\WORK\X\.Dev.Vars' PowerShell
  refuse_cmd 'cat C:/work/x/.dev.vars:Zone.Identifier'
  refuse_cmd 'cat ".dev.vars "'
  refuse_cmd 'cat C:\work\x\.dev.vars'
}

case_print_lookalikes_pass() {
  pass_cmd 'cat dev.vars.md' Bash PowerShell
  pass_cmd 'cat notes.md .dev.varsx'
  pass_cmd 'cat my.dev.vars'
  pass_cmd 'cat C:/work/.dev.vars/notes.txt'
  pass_cmd 'echo .dev.vars'
  pass_cmd 'ls -la .dev.vars'
  pass_cmd 'cp .dev.vars.example .dev.vars'
  pass_cmd 'cat README.md # .dev.vars'
  pass_cmd 'git commit -m "never cat .dev.vars"'
  pass_cmd 'echo "cat .dev.vars"'
  pass_cmd $'cat > notes.md <<\'EOF\'\ncat .dev.vars\nEOF'
  pass_cmd 'cat *'
  pass_cmd 'cat .gitignore'
  pass_cmd 'cat -n README.md'
}

case_print_message() {
  cmd_payload Bash 'cat store/.dev.vars'
  run_hook "$PRINT" "$PAYLOAD"
  [[ "$RC" == 2 ]] || WHY+=("exit $RC, want 2")
  mention 'cat prints a .dev.vars file whole' 'holds secrets' 'copies .dev.vars.example to .dev.vars and types the keys' \
    "grep -c '^EXAMPLE_API_KEY=abc_' .dev.vars" 'grep -c and grep -q on the file are not refused'
}

case_print_fails_open() {
  local d="$WORK/open-print"
  run_hook "$PRINT" 'not json at all {'
  [[ "$RC" == 0 ]] || WHY+=("input that is not JSON exits $RC")
  run_hook "$PRINT" ''
  [[ "$RC" == 0 ]] || WHY+=("empty input exits $RC")
  run_hook "$PRINT" '{"tool_name":"Bash","tool_input":{}}'
  [[ "$RC" == 0 ]] || WHY+=("a payload with no command exits $RC")
  run_hook "$PRINT" '{"tool_name":"Write","tool_input":{"file_path":"C:/work/x/brief.md","content":"cat .dev.vars\nGet-Content .dev.vars"}}'
  [[ "$RC" == 0 ]] || WHY+=("a Write of a brief naming the command exits $RC")
  broken_copy "$PRINT" "$d"
  cmd_payload Bash 'cat .dev.vars'
  run_hook "$OUT" "$PAYLOAD"
  [[ "$RC" == 0 ]] || WHY+=("a copy with a syntax error exits $RC for cat .dev.vars, want 0")
}

case_names_agree() {
  local name
  for name in "${REFUSED_NAMES[@]}"; do
    file_payload Read "$name"
    run_hook "$DEV_VARS" "$PAYLOAD"
    [[ "$RC" == 2 ]] || WHY+=("file hook passes $name")
    cmd_payload Bash "cat \"$name\""
    run_hook "$PRINT" "$PAYLOAD"
    [[ "$RC" == 2 ]] || WHY+=("print hook passes cat $name")
  done
  for name in "${PASSED_NAMES[@]}"; do
    file_payload Read "$name"
    run_hook "$DEV_VARS" "$PAYLOAD"
    [[ "$RC" == 0 ]] || WHY+=("file hook refuses $name")
    cmd_payload Bash "cat \"$name\""
    run_hook "$PRINT" "$PAYLOAD"
    [[ "$RC" == 0 ]] || WHY+=("print hook refuses cat $name")
  done
}

case_linux_path() {
  refuse_path '/srv/work/proj/.dev.vars'
  pass_path '/srv/work/proj/.dev.vars.example'
  refuse_cmd 'cat /srv/work/proj/.dev.vars'
  refuse_cmd 'head -3 /srv/work/proj/.dev.vars'
  pass_cmd 'grep -c . /srv/work/proj/.dev.vars'
}

cases_run
