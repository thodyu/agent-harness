#!/usr/bin/env bash
# shellcheck disable=SC2016  # the messages hold a literal $
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Refuses a file changed in
# place through the shell. A shell's command string (bash -c, powershell
# -Command, cmd /c) is read with the same rules.
#   sed -i, in any spelling of the flag: -i, -i.bak, -ni, -Ei, --in-place,
#     --in-place=.bak and the prefixes GNU sed takes (--in). Refused when one of
#     the files it names is a literal path outside a scratch folder.
#   A redirect (>, >>, 2>, &> and the like), a heredoc into cat (cat > f <<EOF)
#     included, whose target is a literal path outside a scratch folder.
#   tee, with or without -a, with a file outside a scratch folder.
# An edit through the shell skips check-state-file.sh, which fires on the Write
# and Edit tools only, and it corrupts files: a state file with control
# characters in it, a lost import, a function that called itself, dropped \u
# escapes and a shell hung on a bare cat >>. It refuses printf >> state.md lines
# too. They go through the Edit tool, which also runs the state check.
# A scratch folder is /tmp, /dev, any path under AppData/Local/Temp (either
# slash, any case), any path under a Claude scratchpad (a folder named
# scratchpad with a folder named claude somewhere above it and one more folder
# between them, as in claude/<project>/<session>/scratchpad), and the device NUL.
# A path is judged as written, so a relative path or ~ is outside, and so is a
# path with a .. segment (/tmp/../c/dev/x), since it leaves the folder it starts
# in. These pass:
#   - a target or file that holds a variable, a substitution or a % (>"$T",
#     sed -i ... "$F"), since it cannot be read. R6 in refuse-unsafe-shell.sh
#     judges a variable followed by a slash
#   - 2>&1, >&2, >&- and 2>/dev/null, where the target is a descriptor or /dev
#   - a here-string or a redirect from a file (<, <<<)
# Inside a quoted string, a heredoc body and a commit message nothing counts, as
# in the other hooks.
#
# Known gaps. These are not seen: PowerShell's Set-Content, Add-Content and
# Out-File, perl -pi, awk -i inplace, ed, dd of=, cp and mv onto a file, a
# redirect with a noclobber override (>|), xargs sed -i, find -exec sed -i, sed
# behind sudo or timeout, and a file built in a variable. A comparison written
# in (( a > b )) with a bare name reads as a redirect and is refused.
# A command substitution inside double quotes or backticks is not read either
# (x="$(sed -i s/a/b/ f.md)"), because the library replaces a quoted string by a
# token before it looks for $( . This is a known gap of lib/command-position.sh.
#
# Test: test-command-hooks.sh beside this file.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

refuse() {
  printf '%s\n' \
    "Refused: $1 changes a file through the shell, and the file is not in a scratch folder." \
    "An edit through the shell skips the state check, which runs on the Write and Edit tools only, and it has corrupted files: a sed replacement ate backslashes in a state file, and an appended heredoc broke source files." \
    "Use the Edit tool to change a file, which also runs the state check on a state.md, and the Write tool to make a new one." \
    "A file in a scratch folder is not refused: /tmp, /dev, a path under AppData/Local/Temp or under a Claude scratchpad." >&2
  HOOK_REFUSED=1
  exit 2
}

# outside_scratch <path>: succeeds when the path, as written, is a literal path
# outside a scratch folder. A path that holds a variable, a substitution or a %
# cannot be read, so it fails here and passes.
outside_scratch() {
  local p="$1"
  [[ -n "$p" ]] || return 1
  [[ "$p" == *'$'* || "$p" == *'`'* || "$p" == *%* ]] && return 1
  p=${p//\\//}
  p=${p,,}
  # A path that climbs out of a scratch folder with a .. segment is outside it.
  [[ "$p" == *'/../'* || "$p" == *'/..' ]] && return 0
  case "$p" in
    /tmp|/tmp/*|/dev|/dev/*|nul) return 1 ;;
    */appdata/local/temp|*/appdata/local/temp/*) return 1 ;;
    */claude/*/scratchpad|*/claude/*/scratchpad/*) return 1 ;;
  esac
  return 0
}

# --in-place and every prefix of it that GNU sed accepts, with an optional =suffix.
in_place_long='^--i(n(-(p(l(a(c(e)?)?)?)?)?)?)?(=.*)?$'

for i in "${!SIMPLE[@]}"; do
  name="${SIMPLE[i]%% *}"
  split_words "$i"

  for target in "${TARGETS[@]}"; do
    # An empty target is a substitution that came next (>$(mktemp)). It cannot be read.
    restore_quotes "$target"
    # 2>&1 reads as 2>1 and >&- as >-: a descriptor, not a file.
    [[ "$RESTORED" =~ ^[0-9]+$ || "$RESTORED" == - ]] && continue
    outside_scratch "$RESTORED" && refuse "a redirect to $RESTORED"
  done

  case "$name" in
    sed)
      in_place=0 has_script=0 skip=0 files=()
      for (( j = 1; j < ${#ARGS[@]}; j++ )); do
        word="${ARGS[j]}"
        if (( skip )); then
          skip=0
          continue
        fi
        case "$word" in
          --expression|--file) has_script=1 skip=1 ;;
          --line-length) skip=1 ;;
          --expression=*|--file=*) has_script=1 ;;
          --*) [[ "$word" =~ $in_place_long ]] && in_place=1 ;;
          -?*)
            if [[ "$word" =~ ^-[A-Za-z]*i ]]; then
              in_place=1
            elif [[ "$word" =~ ^-[A-Za-z]*[ef]$ ]]; then
              has_script=1 skip=1
            elif [[ "$word" == -l ]]; then
              skip=1
            fi ;;
          *) files+=("$word") ;;
        esac
      done
      (( in_place )) || continue
      # Without -e or -f the first word that is not a flag is the script.
      (( has_script )) || files=("${files[@]:1}")
      for word in "${files[@]}"; do
        restore_quotes "$word"
        outside_scratch "$RESTORED" && refuse "sed -i on $RESTORED"
      done ;;
    tee)
      for (( j = 1; j < ${#ARGS[@]}; j++ )); do
        word="${ARGS[j]}"
        # PowerShell's tee takes -Variable <name>, which names no file.
        case "${word,,}" in
          -variable|-v) j=$((j + 1)); continue ;;
          -*) continue ;;
        esac
        restore_quotes "$word"
        outside_scratch "$RESTORED" && refuse "tee to $RESTORED"
      done ;;
  esac
done
exit 0
