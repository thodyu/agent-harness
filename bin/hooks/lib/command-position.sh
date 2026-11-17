# shellcheck shell=bash
# shellcheck disable=SC2034  # the arrays and flags below are read by the hooks
#
# Shared by the PreToolUse command hooks refuse-kill-by-name.sh,
# refuse-merge-default-body.sh, refuse-python-heredoc.sh, refuse-npx.sh,
# refuse-unsafe-shell.sh, refuse-dev-vars-print.sh and refuse-shell-edits.sh.
# Sourced, never run. Besides read_simple_commands it defines unquote,
# restore_quotes and split_words, which the hooks call on the arrays below.
#
# refuse-command-hooks.sh runs those seven in one bash. It sources this file and
# calls read_simple_commands once, then sets COMMAND_HOOK_PARSED. While that is
# set, sourcing this file again defines nothing and read_simple_commands returns
# 0 without reading standard input, so each hook finds the arrays already
# filled. A hook run alone never sets it and works as before.
[[ -n "${COMMAND_HOOK_PARSED:-}" ]] && return 0
#
# read_simple_commands reads a Claude Code PreToolUse payload on standard
# input, sets TOOL_NAME, and fills these:
#   SIMPLE       one entry per simple command, "<word> <args>", where <word> is
#                the command's name in lower case with any path and .exe
#                removed, and <args> keep their case, with each quoted string
#                replaced by the token Q<n>, each heredoc operator by <<%H<n>,
#                each PowerShell here-string by @%H<n>, each unquoted ${...} by
#                $%V<n>, and <<< a word of its own
#   PIPE_ID      for each entry, a number shared by the commands of one pipeline
#   RAW          for each entry, its words as written, with the first word's
#                case and path kept, so a redirect that opens a command shows
#   SUBST        for each entry, 1 when an unquoted $( or backtick follows its
#                last word, which the split into commands would otherwise hide
#   ASSIGNED     each VAR=value word skipped before a command, as "<n> <word>",
#                where n is the number of entries in SIMPLE before it
#   QUOTED       QUOTED[n] is the text inside the quotes that Q<n> replaced
#   QUOTE_DQ     QUOTE_DQ[n] is 1 when those quotes were double quotes, so the
#                text expands, and 0 when they were single quotes
#   EXPANSIONS   EXPANSIONS[n] is the text inside the braces that $%V<n> replaced
#   HEREDOC      HEREDOC[n] is the body that <<%H<n> or @%H<n> replaced
#   KILL_METHOD  1 when the command calls a .Kill() method outside quotes
# It returns 1 when there is nothing to check, so the hook lets the call
# through.
#
# The approach: heredoc bodies go first, quoted text becomes a placeholder, and
# only a word in command position counts. A command that only names another, in a heredoc, a quoted
# argument, an echo or a commit message, is never matched. Added here: Bash and
# PowerShell line continuations, PowerShell here-strings, a split into
# pipelines and simple commands, and one more step. When the command is a
# shell given a command string (powershell or pwsh with -Command or -c, cmd
# with /c or /k, bash or sh with -c), that string is parsed again with the same
# rules, up to three levels deep, so `powershell -Command "Stop-Process -Name
# node"` counts as Stop-Process. It runs no external command at all, because
# each fork costs 100 to 200 ms under Git Bash.
#
# The hooks guide an agent. They are not a security boundary. Known gaps: a quoted command name ("taskkill" /IM x, or
# & "C:\Windows\System32\taskkill.exe" /IM x), Start-Process taskkill
# -ArgumentList "/IM x", wmic and Win32_Process Terminate calls,
# Get-Process | Where-Object Name -eq x | Stop-Process, an encoded command
# (powershell -EncodedCommand), and anything typed into a pane through Herdr.
#
# It also skips sudo, timeout, nice and busybox in front of a command, as it
# skips env, with their options, the value of an
# option that takes one as the next word (sudo -u x, timeout -s KILL, nice -n
# 10), and timeout's duration. So timeout 5 pkill node counts as pkill, for
# every hook. Not seen: an option with a value that the list does not name.

# strip_heredoc_bodies: CMD with every heredoc's body and end line removed
# (<<WORD, <<'WORD', <<"WORD", <<-WORD), and every PowerShell here-string's
# body and end line (a line ending in @' or @" up to a line that starts with
# '@ or "@). The opening line stays, so a command on it counts. Each body goes
# into HEREDOC, and the operator that opened it becomes a token on the opening
# line: <<%H<n> for a heredoc and @%H<n> for a here-string, where n is the
# body's index in HEREDOC. Whatever follows '@ or "@ on the end line joins the
# opening line, so `'@ | python -` stays in the pipeline. A heredoc opened in
# a command string (bash -c '... <<E') may end on a line of WORD and the quote
# that closes the string (E'), and that quote and the rest of the line stay.
# Continued lines join here, outside the bodies, so a body keeps its
# backslashes: backslash-newline in Bash, and backtick-newline in PowerShell.
strip_heredoc_bodies() {
  local line rest end n ps_n held="" ps_open="" opener="(^|[^<])<<(-?)[[:space:]]*[\"'\\\\]?([A-Za-z_][A-Za-z0-9_]*)[\"']?"
  local ends=() tabbed=() bodies=() out="" ps_end="" lines=()
  IFS=$'\n' read -r -d '' -a lines <<< "$CMD"
  for line in "${lines[@]}"; do
    if [[ -n "$ps_end" ]]; then
      if [[ "$line" == "$ps_end"* ]]; then
        out+="$ps_open${line#"$ps_end"}"$'\n'
        ps_end=""
      else
        HEREDOC[ps_n]+="$line"$'\n'
      fi
      continue
    fi
    if (( ${#ends[@]} > 0 )); then
      end="$line"
      if [[ "${tabbed[0]}" == "-" ]]; then end="${line#"${line%%[!$'\t']*}"}"; fi
      if [[ "$end" == "${ends[0]}" || "$end" == "${ends[0]}"[\"\']* ]]; then
        [[ "$end" == "${ends[0]}" ]] || out+="${end#"${ends[0]}"}"$'\n'
        ends=("${ends[@]:1}")
        tabbed=("${tabbed[@]:1}")
        bodies=("${bodies[@]:1}")
      else
        HEREDOC[bodies[0]]+="$line"$'\n'
      fi
      continue
    fi
    if [[ "$line" == *[\\\`] ]]; then
      held+="${line%?} "
      continue
    fi
    line="$held$line"
    held=""
    # A $@ before the quote is Bash's "$@", not a here-string opener.
    if [[ "$line" =~ (^|[^$])(@([\"\']))[[:space:]]*$ ]]; then
      ps_end="${BASH_REMATCH[3]}@"
      ps_n=${#HEREDOC[@]}
      HEREDOC+=("")
      rest="${BASH_REMATCH[2]}${line##*"${BASH_REMATCH[2]}"}"
      ps_open="${line%"$rest"} @%H$ps_n "
      continue
    fi
    rest="$line"
    line=""
    while [[ "$rest" =~ $opener ]]; do
      n=${#HEREDOC[@]}
      HEREDOC+=("")
      bodies+=("$n")
      tabbed+=("${BASH_REMATCH[2]}")
      ends+=("${BASH_REMATCH[3]}")
      line+="${rest%%"${BASH_REMATCH[0]}"*}${BASH_REMATCH[1]} <<%H$n "
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
    out+="$line$rest"$'\n'
  done
  [[ -n "$held" ]] && out+="$held"$'\n'
  [[ -n "$ps_end" ]] && out+="$ps_open"$'\n'
  CMD="$out"
}

# replace_quoted: CMD with each quoted string replaced by the token Q<n>, and
# its text kept in QUOTED[n]. Double-quoted strings go first, so an apostrophe
# inside one is never read as a quote.
replace_quoted() {
  local dq='"([^"\\]|\\.)*"' sq="'[^']*'" text n
  while [[ "$CMD" =~ $dq ]]; do
    text=${BASH_REMATCH[0]:1:${#BASH_REMATCH[0]}-2}
    text=${text//$'\037'/$'\n'}
    n=${#QUOTED[@]}
    QUOTED+=("${text//\\\"/\"}")
    QUOTE_DQ+=(1)
    CMD=${CMD/"${BASH_REMATCH[0]}"/Q$n}
  done
  while [[ "$CMD" =~ $sq ]]; do
    text=${BASH_REMATCH[0]:1:${#BASH_REMATCH[0]}-2}
    n=${#QUOTED[@]}
    QUOTED+=("${text//$'\037'/$'\n'}")
    QUOTE_DQ+=(0)
    CMD=${CMD/"${BASH_REMATCH[0]}"/Q$n}
  done
}

# unquote <word>: the text a Q<n> token stands for, or the word itself.
unquote() {
  if [[ "$1" =~ ^Q([0-9]+)$ && -n "${QUOTED[${BASH_REMATCH[1]}]+set}" ]]; then
    printf -v UNQUOTED '%s' "${QUOTED[${BASH_REMATCH[1]}]}"
  else
    UNQUOTED="$1"
  fi
}

# restore_quotes <text>: RESTORED is the text with each Q<n> put back as the
# text inside its quotes, single quotes and double quotes alike, so a quoted
# path reads as the path. A Q<n> with no such quote is plain text and is kept.
# The loop is bounded, so odd input cannot spin.
restore_quotes() {
  local text="$1" i n token
  local quote='Q([0-9]+)'
  for (( i = 0; i < 20; i++ )); do
    [[ "$text" =~ $quote ]] || break
    token="${BASH_REMATCH[0]}" n="${BASH_REMATCH[1]}"
    if [[ -n "${QUOTED[n]+set}" ]]; then
      text=${text/"$token"/"${QUOTED[n]}"}
    else
      text=${text/"$token"/$'\003'"$n"}
    fi
  done
  RESTORED=${text//$'\003'/Q}
}

# split_words <index>: ARGS holds the words of RAW[<index>] that are not part
# of a redirect, and TARGETS holds the target of each output redirect, empty
# when the operator had nothing after it (a substitution came next). An
# operator may stand inside a word (echo x>"$T/out"), so each word is cut at
# its operators: the text before the first is an argument unless it is only a
# file descriptor number (2>), and the text after each is its target.
split_words() {
  local -a w
  local j op pre rest word redirect='^([^<>]*)([<>]+)(.*)$' next='^([^<>]*)(.*)$'
  ARGS=() TARGETS=()
  read -r -a w <<< "${RAW[$1]}"
  for (( j = 0; j < ${#w[@]}; j++ )); do
    word="${w[j]}"
    # A word that starts with # begins a comment, to the end of the command.
    [[ "$word" == \#* ]] && break
    if [[ ! "$word" =~ $redirect ]]; then
      ARGS+=("$word")
      continue
    fi
    pre="${BASH_REMATCH[1]}"
    [[ -z "$pre" || "$pre" =~ ^[0-9]+$ ]] || ARGS+=("$pre")
    while [[ "$word" =~ $redirect ]]; do
      op="${BASH_REMATCH[2]}" word="${BASH_REMATCH[3]}"
      [[ "$word" =~ $next ]]
      rest="${BASH_REMATCH[1]}" word="${BASH_REMATCH[2]}"
      if [[ -z "$rest" && -z "$word" ]] && (( j + 1 < ${#w[@]} )); then
        j=$((j + 1))
        rest="${w[j]}"
      fi
      [[ "$op" == *'>'* ]] && TARGETS+=("$rest")
    done
  done
}

# parse_command_text <text> <depth>: appends the simple commands of <text> to
# SIMPLE and PIPE_ID.
parse_command_text() {
  local CMD="$1" depth="$2"

  # This also joins continued lines.
  strip_heredoc_bodies

  # A newline is held as the unit separator until the quotes are gone, so a
  # quoted string may span lines. The quoted text keeps its newlines, so a
  # command string of several lines is several commands.
  local SEP=$'\037'
  CMD=${CMD//$'\n'/$SEP}
  replace_quoted
  CMD=${CMD//$SEP/;}
  # A Bash here-string is a word of its own, even when written python<<<x.
  CMD=${CMD//<<</ <<< }
  # An unquoted ${...} is one word, so its braces do not split the command.
  local braced='\$\{[^}]*\}' n
  while [[ "$CMD" =~ $braced ]]; do
    n=${#EXPANSIONS[@]}
    EXPANSIONS+=("${BASH_REMATCH[0]:2:${#BASH_REMATCH[0]}-3}")
    CMD=${CMD/"${BASH_REMATCH[0]}"/'$%V'$n}
  done

  local kill_call='\.[Kk][Ii][Ll][Ll][[:space:]]*\('
  [[ "$CMD" =~ $kill_call ]] && KILL_METHOD=1

  # Redirections that hold & are not separators.
  CMD=${CMD//>&/>}
  CMD=${CMD//<&/<}
  CMD=${CMD//|&/|}
  # Lists (&& || & ;) start a new pipeline. An opening bracket, $( or a
  # backtick starts a new command inside the same pipeline. A closing bracket
  # followed by | stays in the pipeline, so a script block in Where-Object { }
  # keeps Get-Process and Stop-Process together. Any other closing bracket
  # ends it, so `if (Get-Process x) { Stop-Process -Id 1 }` is two pipelines.
  CMD=${CMD//&&/;}
  CMD=${CMD//||/;}
  CMD=${CMD//&/;}
  local close='[)}][[:space:]]*[|]'
  while [[ "$CMD" =~ $close ]]; do CMD=${CMD/"${BASH_REMATCH[0]}"/ |}; done
  CMD=${CMD//)/;}
  CMD=${CMD//\}/;}
  # A $( or backtick leaves \002 on the command before it, which is read into
  # SUBST below, because the split would otherwise hide that an argument was
  # substituted.
  CMD=${CMD//\$(/$'\002'|}
  CMD=${CMD//(/|}
  CMD=${CMD//\{/|}
  CMD=${CMD//\`/$'\002'|}

  local pipeline simple word flag inner i k subst prefix assign='^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*$'
  local -a pipelines parts words
  IFS=';' read -r -a pipelines <<< "$CMD"
  for pipeline in "${pipelines[@]}"; do
    PIPE_COUNT=$((PIPE_COUNT + 1))
    IFS='|' read -r -a parts <<< "$pipeline"
    for simple in "${parts[@]}"; do
      subst=0
      if [[ "$simple" == *$'\002'* ]]; then
        subst=1
        simple=${simple//$'\002'/}
      fi
      IFS=$' \t' read -r -a words <<< "$simple"
      # Past keywords, prefix commands and VAR=value assignments.
      prefix=""
      while (( ${#words[@]} > 0 )); do
        # The options of sudo, timeout and nice, the value of those options that
        # take one as the next word, and timeout's duration.
        if [[ -n "$prefix" && "${words[0]}" == -?* ]]; then
          case "$prefix ${words[0]}" in
            "sudo -u"|"sudo -g"|"sudo -h"|"sudo -p"|"sudo -C"|"sudo -D"|"sudo -r"|"sudo -t"|"sudo -U"|"timeout -s"|"timeout -k"|"timeout --signal"|"timeout --kill-after"|"nice -n"|"nice --adjustment") words=("${words[@]:2}") ;;
            *) words=("${words[@]:1}") ;;
          esac
          continue
        fi
        if [[ "$prefix" == timeout && "${words[0]}" =~ ^[0-9.]+[smhd]?$ ]]; then
          prefix=""
          words=("${words[@]:1}")
          continue
        fi
        prefix=""
        case "${words[0],,}" in
          if|while|until|then|do|else|elif|time|env|command|exec|nohup|!|.|foreach|for) words=("${words[@]:1}") ;;
          sudo|timeout|nice|busybox|*/sudo|*/timeout|*/nice|*/busybox) prefix=${words[0]##*/}; words=("${words[@]:1}") ;;
          *) if [[ "${words[0]}" =~ $assign ]]; then ASSIGNED+=("${#SIMPLE[@]} ${words[0]}"); words=("${words[@]:1}"); else break; fi ;;
        esac
      done
      (( ${#words[@]} > 0 )) || continue
      RAW+=("${words[*]}")
      SUBST+=("$subst")
      word="${words[0],,}"
      word="${word##*/}"
      word="${word##*\\}"
      word="${word%.exe}"
      SIMPLE+=("$word ${words[*]:1}")
      PIPE_ID+=("$PIPE_COUNT")

      # A shell given a command string: parse the string too.
      case "$word" in
        powershell|pwsh) flag='^-c(o(m(m(a(n(d)?)?)?)?)?)?$' ;;
        cmd) flag='^(//?)[ck]$' ;;
        bash|sh) flag='^-[[:alpha:]]*c[[:alpha:]]*$' ;;
        *) continue ;;
      esac
      (( depth < 3 )) || continue
      # The first command flag: everything after it is the command string.
      for (( i = 1; i < ${#words[@]}; i++ )); do
        [[ "${words[i],,}" =~ $flag ]] && break
      done
      (( i < ${#words[@]} )) || continue
      inner=""
      for (( k = i + 1; k < ${#words[@]}; k++ )); do
        unquote "${words[k]}"
        inner+="$UNQUOTED "
      done
      parse_command_text "$inner" $((depth + 1))
    done
  done
}

read_simple_commands() {
  # Already parsed by refuse-command-hooks.sh, which returned early if there
  # was nothing to check.
  [[ -n "${COMMAND_HOOK_PARSED:-}" ]] && return 0
  SIMPLE=()
  PIPE_ID=()
  RAW=()
  SUBST=()
  ASSIGNED=()
  QUOTED=()
  QUOTE_DQ=()
  EXPANSIONS=()
  HEREDOC=()
  KILL_METHOD=0
  PIPE_COUNT=0
  TOOL_NAME=""
  local input="" text key='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
  IFS= read -r -d '' input
  input=${input//$'\r'/}
  [[ "$input" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && TOOL_NAME="${BASH_REMATCH[1]}"
  case "$TOOL_NAME" in
    ""|Bash|PowerShell) ;;
    *) return 1 ;;
  esac
  # The JSON string value of "command", escapes and all. An escaped quote in
  # another field reads \"command\" and never matches the key.
  [[ "$input" =~ $key ]] || return 1
  text="${BASH_REMATCH[1]}"
  [[ -n "$text" ]] || return 1
  # An escaped backslash is held as \001 while the other escapes are read, so
  # \\n stays a backslash and an n. \r goes, and a \u escape or a control
  # character stands as ?, since only a command's shape matters here.
  text=${text//\\\\/$'\001'}
  text=${text//\\n/$'\n'}
  text=${text//\\t/$'\t'}
  text=${text//\\r/}
  text=${text//\\\"/\"}
  text=${text//\\\//\/}
  text=${text//\\[bf]/?}
  text=${text//\\u[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]/?}
  text=${text//$'\001'/\\}
  parse_command_text "$text" 0
  (( ${#SIMPLE[@]} > 0 ))
}
