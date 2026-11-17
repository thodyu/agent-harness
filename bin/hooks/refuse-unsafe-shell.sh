#!/usr/bin/env bash
# shellcheck disable=SC2016  # the messages and patterns hold a literal $
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Refuses two shapes that
# hide a failure. A shell's command string (bash -c, sh -c, powershell
# -Command, cmd /c) is read with the same rules.
#
# R6, rm and redirects (Bash tool only). A path built from a command
# substitution, or from a variable that comes out empty, turns "$d/build" into
# /build.
#   rm, any flags: refused when any argument holds a command substitution
#     ($(...) or backticks) or a variable expansion ($VAR or ${VAR}) that is
#     not in the guarded form ${VAR:?}.
#   A redirect (>, >>, 2>, &> and the like), spaced or glued to a word as in
#     echo x>"$T/out": refused when its target holds a command substitution,
#     or an unguarded variable followed by / or \.
# The sanctioned form is bash's own guard, ${VAR:?}, which aborts the command
# when the variable is unset or empty: rm -rf "${WORK:?}/build". A literal
# path passes. So does a redirect to a whole variable (>"$T" or >>$LOG), since
# an empty one fails with an error and writes nowhere else, and so do the
# usual 2>&1, 2>/dev/null, >&2 and >/dev/null 2>&1.
# Six variables count as guarded without ${VAR:?}: HOME, PWD, USERPROFILE,
# TEMP, TMP and TMPDIR. In the Bash tool each is always set and never empty,
# and this hook only runs inside Claude Code calls. They are matched by whole
# name, in the ALWAYS_SET array near the top, so $HOMEDIR is refused.
#
# R13, git that changes state, piped to tail or head. git commit, revert,
# merge, rebase, push, reset or cherry-pick, with any global options before
# the subcommand (git -C <dir> push), refused when a pipe leads from it to
# tail or head in the same pipeline, directly or after another command. The
# pipe hides git's exit status behind tail's, so a failed push goes unnoticed.
# It passes when the same command sets set -o pipefail (or bash -o pipefail)
# before the git command, or reads $PIPESTATUS after it. Read-only git (log,
# diff, status, show, fetch) piped to tail or head passes.
#
# Inside a quoted string, a heredoc body and a commit message nothing counts,
# as in the other hooks. Single quotes are literal, so rm '$HOME' passes. A
# double-quoted rm argument is read, since the shell expands it.
#
# Known gaps. PowerShell's Remove-Item (and rm, its alias) and PowerShell
# redirects are out of scope, so the R6 rules do not run for the PowerShell
# tool at all, a bash -c string inside it included. R13 runs for both tools.
# A variable on the ALWAYS_SET list is not a gap, see above. These are not seen:
#   - a redirect with a noclobber override (>|)
#   - a redirect before the command, as in 2>/dev/null rm -rf "$d"
#   - a pipe from a brace group or subshell around git
#   - xargs rm and find -exec rm
#   - find "$d" -delete
#   - rm behind sudo, timeout or nice, and rm inside eval "..."
#   - a quoted command name
#   - an assignment such as x=$(...) used later in a path, where the guard on
#     that later use is what counts
#   - a variable inside single quotes within a double-quoted command string,
#     which the outer shell expands first
#   - bash -c "rm -rf \$x/y", where the outer shell has already consumed the
#     backslash and the inner pass cannot tell (the \$ is dropped as a literal)
#   - pipefail taken from any earlier set or bash command in the same command,
#     even one that turns it off again, and a PIPESTATUS read after any later
#     command, even one in another pipeline
# R13 covers the seven subcommands above and tail and head only. It does not
# cover git pull, git stash pop or gh pr merge, or PowerShell's Select-Object.
#
# Test: test-command-hooks.sh beside it.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

refuse() {
  printf '%s\n' "$@" >&2
  HOOK_REFUSED=1
  exit 2
}

# Variables that count as guarded without ${VAR:?}, matched by whole name. In the
# Bash tool each one is always set and never empty, and this hook only runs
# inside Claude Code calls. A name that only starts like one of these, such as
# $HOMEDIR, is not on the list.
ALWAYS_SET=(HOME PWD USERPROFILE TEMP TMP TMPDIR)

GUARD_EXAMPLE=(
  "Guard each variable with bash's own check, which aborts the command when it is unset or empty:"
  '  rm -rf "${WORK:?}/build"'
  '  d=$(mktemp -d) && rm -rf "${d:?}"'
  "Put a substituted path in a variable first and guard that. A literal path needs no guard."
)

# expand_text <text>: EXPANDED is the text with each $%V<n> put back as ${...}
# and each Q<n> put back as its quoted text, wherever it stands in the word, so
# /tmp/x"$d" is read as /tmp/x$d. A single-quoted string is literal, so it
# becomes the letter x. A Q<n> with no such quote is plain text and is kept.
# Each loop is bounded, so odd input cannot spin.
expand_text() {
  local text="$1" i token n rep
  local brace='\$%[Vv]([0-9]+)' quote='Q([0-9]+)'
  for (( i = 0; i < 20; i++ )); do
    [[ "$text" =~ $brace ]] || break
    n="${BASH_REMATCH[1]}"
    [[ -n "${EXPANSIONS[n]+set}" ]] || break
    text=${text/"${BASH_REMATCH[0]}"/"\${${EXPANSIONS[n]}}"}
  done
  for (( i = 0; i < 20; i++ )); do
    [[ "$text" =~ $quote ]] || break
    token="${BASH_REMATCH[0]}" n="${BASH_REMATCH[1]}"
    if [[ -z "${QUOTED[n]+set}" ]]; then
      # Not a quote token: hide the Q so the loop moves on.
      text=${text/"$token"/$'\003'"$n"}
      continue
    fi
    rep=x
    (( ${QUOTE_DQ[n]:-0} )) && rep="${QUOTED[n]}"
    text=${text/"$token"/"$rep"}
  done
  text=${text//$'\003'/Q}
  EXPANDED=${text//\\\$/}
}

# scan_expansions <text>: HAS_SUBST is 1 when the text holds $( or a backtick,
# UNGUARDED is 1 when it holds a variable that is not ${VAR:?}, and
# UNGUARDED_SLASH is 1 when such a variable is followed by / or \.
scan_expansions() {
  local text="$1" match next name always allowed
  local var='\$(\{[^}]*\}|[A-Za-z_][A-Za-z0-9_]*|[1-9@*])'
  local guarded='^\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}$'
  HAS_SUBST=0 UNGUARDED=0 UNGUARDED_SLASH=0
  [[ "$text" == *'$('* || "$text" == *\`* ]] && HAS_SUBST=1
  while [[ "$text" =~ $var ]]; do
    match="${BASH_REMATCH[0]}"
    text="${text#*"$match"}"
    [[ "$match" =~ $guarded ]] && continue
    # $NAME or ${NAME} of an always-set variable, by whole name.
    name="${match#\$}"
    name="${name#\{}"
    name="${name%\}}"
    always=0
    for allowed in "${ALWAYS_SET[@]}"; do
      [[ "$name" == "$allowed" ]] && always=1
    done
    (( always )) && continue
    UNGUARDED=1
    next="${text:0:1}"
    [[ "$next" == "/" || "$next" == "\\" ]] && UNGUARDED_SLASH=1
  done
}

# split_words is in lib/command-position.sh, since refuse-shell-edits.sh reads
# redirect targets with it too.

refuse_rm() {
  refuse "Refused: rm on a path that comes from a command substitution or from a variable with no guard. $1" \
    "If the substitution fails or the variable is empty, \"\$d/build\" becomes /build and rm runs on the wrong path." \
    "${GUARD_EXAMPLE[@]}"
}

refuse_redirect() {
  refuse "Refused: a redirect to a path that comes from a command substitution or from a variable with no guard. $1" \
    "If the substitution fails or the variable is empty, > \"\$T/out\" writes to /out." \
    "Guard each variable with bash's own check, which aborts the command when it is unset or empty:" \
    '  cmd > "${T:?}/out"' \
    "Put a substituted path in a variable first and guard that. A redirect to a whole variable (>\"\$T\") and a literal path need no guard."
}

# git_subcommand <index>: GIT_SUB is the subcommand of the git command, past
# its global options, or empty.
git_subcommand() {
  local -a w
  local j=0
  read -r -a w <<< "${SIMPLE[$1]#* }"
  while (( j < ${#w[@]} )); do
    case "${w[j]}" in
      -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  GIT_SUB="${w[j]:-}"
}

# reads_pipestatus <text>: succeeds when the text expands $PIPESTATUS. The
# library lowers a command's first word, so a leading q<n> token is raised again.
reads_pipestatus() {
  expand_text "${1^}"
  [[ "$EXPANDED" == *'$PIPESTATUS'* || "$EXPANDED" == *'${PIPESTATUS'* ]]
}

pipefail_flag='(^|[[:space:]])-[A-Za-z]*o[[:space:]]+pipefail([[:space:]]|$)'

for i in "${!SIMPLE[@]}"; do
  name="${SIMPLE[i]%% *}"

  # R6: rm and redirects, for the Bash tool.
  if [[ "$TOOL_NAME" != "PowerShell" ]]; then
    split_words "$i"
    if [[ "$name" == "rm" ]]; then
      (( SUBST[i] )) && refuse_rm "An unquoted \$( or backtick is in the command."
      for (( j = 1; j < ${#ARGS[@]}; j++ )); do
        expand_text "${ARGS[j]}"
        scan_expansions "$EXPANDED"
        (( HAS_SUBST || UNGUARDED )) && refuse_rm "The argument is: $EXPANDED"
      done
    fi
    for target in "${TARGETS[@]}"; do
      if [[ -z "$target" ]]; then
        (( SUBST[i] )) && refuse_redirect "An unquoted \$( or backtick is the target."
        continue
      fi
      expand_text "$target"
      scan_expansions "$EXPANDED"
      (( HAS_SUBST || UNGUARDED_SLASH )) && refuse_redirect "The target is: $EXPANDED"
    done
  fi

  # R13: git that changes state, piped to tail or head.
  [[ "$name" == "git" ]] || continue
  git_subcommand "$i"
  case "$GIT_SUB" in
    commit|revert|merge|rebase|push|reset|cherry-pick) ;;
    *) continue ;;
  esac
  piped=""
  for (( j = i + 1; j < ${#SIMPLE[@]}; j++ )); do
    [[ "${PIPE_ID[j]}" == "${PIPE_ID[i]}" ]] || continue
    case "${SIMPLE[j]%% *}" in
      tail|head) piped="${SIMPLE[j]%% *}"; break ;;
    esac
  done
  [[ -n "$piped" ]] || continue
  # A set -o pipefail before the git command, or a $PIPESTATUS read after it.
  safe=0
  for (( j = 0; j < ${#SIMPLE[@]}; j++ )); do
    if (( j < i )); then
      case "${SIMPLE[j]%% *}" in
        set|bash|sh) [[ "${SIMPLE[j]#* }" =~ $pipefail_flag ]] && safe=1 ;;
      esac
    elif (( j > i )); then
      reads_pipestatus "${SIMPLE[j]}" && safe=1
    fi
  done
  # An assignment such as rc=${PIPESTATUS[0]} is not a command of its own.
  for entry in "${ASSIGNED[@]}"; do
    (( ${entry%% *} > i )) && reads_pipestatus "${entry#* }" && safe=1
  done
  (( safe )) && continue
  refuse "Refused: git $GIT_SUB piped into $piped. The pipe hides git's exit status behind $piped's, so a failed $GIT_SUB looks like a success." \
    "Write the output to a log and read git's exit status first:" \
    '  log=$(mktemp) && git push > "$log" 2>&1; echo "exit $?"; tail -3 "$log"' \
    "Or keep the pipe and read the status after it:" \
    '  git push 2>&1 | tail -3; echo "exit ${PIPESTATUS[0]}"' \
    "Or run set -o pipefail before the git command in the same call."
done
exit 0
