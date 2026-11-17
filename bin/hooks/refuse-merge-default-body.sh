#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the command run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Bash and PowerShell tools. Refuses `gh pr merge`
# unless it passes both a subject (--subject or -t) and a body (--body, -b,
# --body-file or -F), each with a value. Without them GitHub writes its
# default body, which lists the commits and adds a Co-authored-by trailer.
# A shell's command string (bash -c, powershell -Command, cmd /c) is read with
# the same rules. These pass: --help and -h, --disable-auto (it merges
# nothing), and --rebase or -r, which writes no merge commit (gh's help gives
# --subject and --body as "for the merge commit").
#
# Test: test-command-hooks.sh beside it.

HOOK_DIR="${BASH_SOURCE[0]%/*}"
[[ "$HOOK_DIR" == "${BASH_SOURCE[0]}" ]] && HOOK_DIR=.
# shellcheck source=lib/command-position.sh
. "$HOOK_DIR/lib/command-position.sh" || exit 0
read_simple_commands || exit 0

# has_value <word>: the word after a flag is its value. A flag or nothing is
# not, except "-", which is standard input for --body-file.
has_value() { [[ -n "$1" && ( "$1" != -* || "$1" == "-" ) ]]; }

for simple in "${SIMPLE[@]}"; do
  [[ "${simple%% *}" == "gh" ]] || continue
  read -r -a words <<< "${simple#* }"
  # Past gh's own --repo or -R before the subcommand.
  while (( ${#words[@]} > 0 )); do
    case "${words[0]}" in
      -R|--repo) words=("${words[@]:2}") ;;
      --repo=*) words=("${words[@]:1}") ;;
      *) break ;;
    esac
  done
  [[ "${words[0]:-}" == "pr" && "${words[1]:-}" == "merge" ]] || continue
  args=("${words[@]:2}")
  subject=0 body=0 exempt=0
  for (( j = 0; j < ${#args[@]}; j++ )); do
    next="${args[j + 1]:-}"
    case "${args[j]}" in
      --help|-h|--disable-auto|--rebase|-r) exempt=1 ;;
      --subject|-t) [[ "$next" != "-" ]] && has_value "$next" && subject=1 ;;
      --body|-b) [[ "$next" != "-" ]] && has_value "$next" && body=1 ;;
      --body-file|-F) has_value "$next" && body=1 ;;
      --subject=?*) subject=1 ;;
      --body=?*|--body-file=?*) body=1 ;;
    esac
  done
  (( exempt )) && continue
  if (( ! subject || ! body )); then
    printf '%s\n' \
      "Refused: gh pr merge without both --subject and --body. GitHub's default body lists the commits" \
      "and adds a Co-authored-by trailer. Pass both, each with a value, for example:" \
      "  gh pr merge <N> --squash --subject \"<title> (#<N>)\" --body \"Closes #<issue>. The gate's log is on the pull request.\"" >&2
    HOOK_REFUSED=1
    exit 2
  fi
done
exit 0
