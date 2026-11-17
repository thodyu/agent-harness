#!/usr/bin/env bash
# report-check.sh [--ready <worktree>] <file>
# Checks that a report file opens with the short summary an orchestrator reads
# with `head -40`, and that its text holds no mechanical fault. Six rules, one FAIL line for each
# that breaks (rules 5 and 6 give one FAIL line for each line they find, and rule 4 one indented line for each file):
#   1. the file has a line that is "## For the orchestrator", trailing spaces, tabs
#      or a carriage return allowed, and a UTF-8 byte order mark on line 1 ignored
#   2. that section is first (only blank lines and at most one "# " title line before it)
#   3. the section is at most 25 lines, from the line after its heading to the line
#      before the next heading (a line of one or more # then a space) or the end of
#      the file, trailing blank lines not counted
#   4. only with --ready <worktree>: `git status --short` in that folder prints nothing. A modified, a staged and an
#      untracked file all fail, and a file that git ignores does not. The FAIL line says the worktree has uncommitted
#      files, and one indented line for each path follows, as git prints it. Without --ready the script reads no git state,
#      so a report written in the middle of the work, with a question, still passes. Say --ready when the report says the
#      work is ready for the check or the push. The flag comes first: report-check.sh --ready <worktree> <file>.
#      A report kept inside the worktree and not committed is itself an untracked file, so keep it outside.
#   5. no line outside code holds a placeholder token: a word of upper-case letters and digits that starts with a letter
#      and has at least one underscore joining two runs, such as ISSUE_NUMBER or HEAD_SHA. No letter, digit or underscore
#      may touch it, so xISSUE_NUMBER is no token. A single upper-case word, README or NOT, and a snake_case word are not
#      tokens. A token that the repository holds as a whole word in a tracked file, such as a constant named MOST_READINGS,
#      is a real name and no placeholder. The repository is the top of the --ready worktree, else the top
#      of the git work tree that holds the current folder, else none, and with none every token fails as it did before.
#      Each token is looked up with git grep -qwF -e <token>, so a longer word that holds it and an untracked file do not
#      count, and the match is case-sensitive, so issue_number does not pass ISSUE_NUMBER. The report itself is left out of
#      the search, so a report that is tracked is no hit for its own tokens. A report given by a link
#      leaves out the file the link leads to.
#      The FAIL line names the line number and the first token on that line that the repository does not hold.
#   6. no heading (one or more # then a space, outside a fenced block) holds an ISO date YYYY-MM-DD, with an optional
#      time HH:MM after a space or a T, that is later than now. A date with no time fails only when the date is after
#      today. The FAIL line names the line number, the first later date read and now. A date on a line that is not a
#      heading is not read.
# Code, where rules 5 and 6 read nothing, is read as prose-check.sh reads it (the lines under "Code, where a semicolon
# is no hit" in its header), here in bash since this script uses no process but git and one readlink:
#   A fenced block. A line whose first non-blank characters are three or more backticks or three or more tildes opens it,
#   with any text after them. A line of the same character, at least as long and followed by blanks only, closes it.
#   A fence that never closes runs to the end of the file, and warns on stderr.
#   An inline code span: a run of n backticks up to the next run of exactly n backticks on the same line.
#   A backtick run with no closing run on its line is plain text.
# Now, for rule 6, is the machine's local time to the minute. REPORT_CHECK_NOW='YYYY-MM-DD HH:MM' overrides it, for the
# tests only, and any other form is a usage error.
# Exit 0 and one "ok" line when all hold, 1 on any failure, 2 on a usage error: a wrong argument list, a missing file,
# a malformed REPORT_CHECK_NOW, or a --ready folder that is not there or not inside a git work tree.
# Reads with bash built-ins only, and runs git only for --ready and to find and search the repository of rule 5 (without
# taking an index lock, so it cannot block a git command of the author). With no git on the path rule 5 has no repository.
# With a repository it also runs readlink -f once, to resolve the report's own path for rule 5's exclude.
# The git calls ignore GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE of the environment, which
# are unset first, and the git config keys status.showUntrackedFiles and color.status, so the verdict and the lines are
# the same in every repository. CRLF and LF endings both work.

set -u
LC_ALL=C

usage="usage: report-check.sh [--ready <worktree>] <file>"
ready=0
tree=
if [[ ${1:-} == --ready ]]; then
  if [[ $# -ne 3 || -z $2 ]]; then
    echo "$usage (--ready needs a worktree folder, then the report file)" >&2
    exit 2
  fi
  ready=1
  tree=$2
  shift 2
fi
if [[ $# -ne 1 || ! -f $1 ]]; then
  echo "$usage" >&2
  exit 2
fi

file=$1
max=25
heading='## For the orchestrator'
heading_re="^${heading}[[:space:]]*\$"
bom=$'\xef\xbb\xbf'
tok_re='(^|[^A-Za-z0-9_])([A-Z][A-Z0-9]*(_[A-Z0-9]+)+)([^A-Za-z0-9_]|$)'
date_re='(^|[^0-9])([0-9]{4}-[0-9]{2}-[0-9]{2})([ T]([0-9]{2}:[0-9]{2}))?'
tick_re='`+'
blanks=$' \t'

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
dirty=
if ((ready)); then
  if [[ ! -d $tree ]]; then
    echo "report-check.sh: --ready folder $tree is not a folder" >&2
    exit 2
  fi
  if ! command -v git >/dev/null; then
    echo "report-check.sh: --ready needs git, and git is not on the path" >&2
    exit 2
  fi
  inside=$(git --no-optional-locks -C "$tree" rev-parse --is-inside-work-tree 2>/dev/null)
  if [[ $inside != true ]]; then
    echo "report-check.sh: --ready folder $tree is not inside a git work tree, or git cannot read it" >&2
    exit 2
  fi
  if ! dirty=$(git -c color.status=false --no-optional-locks -C "$tree" status --short --untracked-files=normal 2>/dev/null); then
    echo "report-check.sh: git status failed in $tree" >&2
    exit 2
  fi
fi

# Rule 5's repository: the top of the --ready worktree, else of the work tree that holds the current folder, else none.
repo=$(git --no-optional-locks -C "${tree:-.}" rev-parse --show-toplevel 2>/dev/null) || repo=

# The report's own path in the repository, which git grep leaves out, so a tracked report is no hit for its own tokens.
# readlink -f resolves the report first, so a report given by a link leaves out the tracked file behind it. Then git itself says
# whether that file's folder is in the same repository and gives its path from the top, so the two paths compare in git's one form, which on
# Git Bash on Windows is C:/... where pwd -P would give /c/... A cd here once let a caller's CDPATH move the path. No cd is left, and
# CDPATH is unset where the path is worked out, so a cd added later is safe too.
spec=()
if [[ -n $repo ]]; then
  unset CDPATH
  real=$(readlink -f -- "$file" 2>/dev/null) || real=
  rdir=${real%/*}
  if [[ -n $real && $(git --no-optional-locks -C "${rdir:-/}" rev-parse --show-toplevel 2>/dev/null) == "$repo" ]]; then
    prefix=$(git --no-optional-locks -C "${rdir:-/}" rev-parse --show-prefix 2>/dev/null)
    spec=(-- ":(exclude,literal)$prefix${real##*/}")
  fi
fi

# in_repo <token>: the repository holds the token as a whole word in a tracked file other than the report.
in_repo() {
  [[ -n $repo ]] || return 1
  git --no-optional-locks -C "$repo" grep -qwF -e "$1" "${spec[@]}" 2>/dev/null
}

if [[ -n ${REPORT_CHECK_NOW:-} ]]; then
  now=$REPORT_CHECK_NOW
  if [[ ! $now =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]]; then
    echo "report-check.sh: REPORT_CHECK_NOW must be 'YYYY-MM-DD HH:MM', not '$now'" >&2
    exit 2
  fi
else
  printf -v now '%(%Y-%m-%d %H:%M)T' -1
fi
today=${now%% *}

# plain <text>: sets PLAIN to the text with its inline code spans cut out, a space left in the place of each.
plain() {
  local s=$1 out='' run before rest tail m after closed
  while [[ $s =~ $tick_re ]]; do
    run=${BASH_REMATCH[0]}
    before=${s%%"$run"*}
    out+="$before "
    rest=${s#*"$run"}
    tail=$rest
    closed=0
    while [[ $tail =~ $tick_re ]]; do
      m=${BASH_REMATCH[0]}
      after=${tail#*"$m"}
      if ((${#m} == ${#run})); then
        closed=1
        break
      fi
      tail=$after
    done
    if ((closed)); then
      s=$after
    else
      s=$rest
    fi
  done
  PLAIN=$out$s
}

first_line=1
found=0
first=1
titles=0
in_section=0
count=0
pending=0

while IFS= read -r line || [[ -n $line ]]; do
  line=${line%$'\r'}
  if ((first_line)); then
    line=${line#"$bom"}
    first_line=0
  fi
  if ((in_section)); then
    if [[ $line =~ ^#+[[:space:]] ]]; then
      break
    elif [[ $line =~ ^[[:space:]]*$ ]]; then
      pending=$((pending + 1))
    else
      count=$((count + pending + 1))
      pending=0
    fi
  elif ((found == 0)); then
    if [[ $line =~ $heading_re ]]; then
      found=1
      in_section=1
    elif [[ $line =~ ^[[:space:]]*$ ]]; then
      :
    elif [[ $line == "# "* && $titles -eq 0 ]]; then
      titles=1
    else
      first=0
    fi
  fi
done <"$file"

# Rules 5 and 6 read the whole file again, outside fenced blocks and inline code spans.
tokens=()
dates=()
n=0
fchar=
flen=0
opened=0
while IFS= read -r line || [[ -n $line ]]; do
  n=$((n + 1))
  line=${line%$'\r'}
  if ((n == 1)); then
    line=${line#"$bom"}
  fi
  t=${line#"${line%%[!"$blanks"]*}"}
  c=${t:0:1}
  if [[ -n $fchar ]]; then
    if [[ $c == "$fchar" ]]; then
      k=0
      while [[ ${t:k:1} == "$fchar" ]]; do k=$((k + 1)); done
      if ((k >= flen)) && [[ ${t:k} =~ ^[[:blank:]]*$ ]]; then
        fchar=
      fi
    fi
    continue
  fi
  if [[ $c == '`' || $c == '~' ]]; then
    k=0
    while [[ ${t:k:1} == "$c" ]]; do k=$((k + 1)); done
    if ((k >= 3)); then
      fchar=$c
      flen=$k
      opened=$n
      continue
    fi
  fi
  PLAIN=$line
  if [[ $line == *'`'* ]]; then
    plain "$line"
  fi
  if [[ $PLAIN == *_* ]]; then
    u=$PLAIN
    while [[ $u =~ $tok_re ]]; do
      tok=${BASH_REMATCH[2]}
      hit=${BASH_REMATCH[0]}
      if ! in_repo "$tok"; then
        tokens+=("FAIL $file: line $n: placeholder $tok outside code, fill it in or put it in backticks")
        break
      fi
      u=${u#*"$hit"}
    done
  fi
  if [[ $PLAIN =~ ^#+[[:space:]] ]]; then
    s=$PLAIN
    while [[ $s =~ $date_re ]]; do
      whole=${BASH_REMATCH[0]}
      d=${BASH_REMATCH[2]}
      tm=${BASH_REMATCH[4]}
      if [[ -n $tm ]]; then
        if [[ "$d $tm" > $now ]]; then
          dates+=("FAIL $file: line $n: heading dated $d $tm is later than now ($now)")
          break
        fi
      elif [[ $d > $today ]]; then
        dates+=("FAIL $file: line $n: heading dated $d is later than today ($today)")
        break
      fi
      s=${s#*"$whole"}
    done
  fi
done <"$file"
if [[ -n $fchar ]]; then
  echo "report-check.sh: $file:$opened: fence is never closed, the rest of the file is read as code" >&2
fi

status=0
if ((found == 0)); then
  echo "FAIL $file: section missing, no line is '$heading'"
  status=1
else
  if ((first == 0)); then
    echo "FAIL $file: section not first, only blank lines and one '# ' title may come before it"
    status=1
  fi
  if ((count > max)); then
    echo "FAIL $file: section longer than $max lines ($count)"
    status=1
  fi
fi

if [[ -n $dirty ]]; then
  echo "FAIL $file: worktree $tree has uncommitted files, commit or remove them"
  while IFS= read -r line; do
    echo "  $line"
  done <<<"$dirty"
  status=1
fi

for line in "${tokens[@]}" "${dates[@]}"; do
  echo "$line"
  status=1
done

if ((status == 0)); then
  echo "ok $file"
fi
exit "$status"
