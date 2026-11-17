#!/usr/bin/env bash
# worktree-remove.sh [--owner-word <their words>] <worktree> [<tab id>]
# Closes a ticket's worktree in the order that does not lock it. Steps, in this order, each only when the one before worked:
#   1. When a tab id is given, closes that tab through herdr-safe.sh, which strips a trailing carriage return.
#      It closes only the tab id it is given, and never looks for one.
#   2. Looks for node, esbuild and workerd processes whose command line holds the worktree's path.
#      When there is one, it prints each one's name and process id (the Windows id under Git Bash), removes nothing and exits 3. It stops no process.
#      Git Bash on Windows (uname -s starts MINGW, MSYS or CYGWIN) asks PowerShell for the list. Any other machine reads /proc/<pid>/cmdline and /proc/<pid>/comm,
#      matches a process by its comm name or the last part of its first word, and compares the path case-sensitively.
#   3. Removes the worktree with git worktree remove, run from the repository's main checkout, without --force.
#   4. Deletes the worktree's branch, as its own command, only when GitHub has a merged pull request for it
#      or --owner-word records the owner's word. Pull requests here are squash merged, so git branch --merged cannot tell.
#      It asks gh pr list -R <owner>/<repo> --head <branch> --state merged --json number,headRefOid,isCrossRepository,
#      with <owner>/<repo> read from the origin URL. A pull request counts only when it is not from a fork and its head
#      commit (headRefOid) is the branch's tip, so a commit made after the merge, or a branch name used again, keeps it.
#      Otherwise it keeps the branch, says why in one line, and exits 0.
#      The delete is a compare-and-swap. The tip is read once, before gh is asked, and git update-ref -d refs/heads/<branch> <tip>
#      deletes the branch only while it still points at that commit. A branch that moved in between is kept with one line that
#      names both short ids, and the script exits 0. Because update-ref, unlike git branch -D, does not refuse a branch that
#      another worktree has checked out, the script looks for that first, keeps the branch with a line that names the worktree,
#      and exits 0. If the worktree list cannot be read it keeps the branch and exits 5. A branch that another worktree holds mid-rebase
#      or mid-bisect shows there as a detached HEAD, so it is not seen and is deleted. Only git worktree add --force makes that state.
#      After a delete that worked it removes the config section branch.<branch>, which git branch -D used to drop.
#      No such section is the usual case and is ignored. Any other failure there prints one line to stderr and the exit stays 0.
# Output: one line per step to stdout. Errors go to stderr. git's own output goes to stderr.
# The origin URL is never printed whole, since it can carry a token.
#
# Flags:
#   --owner-word <their words>   the owner's word that the branch may go, quoted in the output line. It must not be empty.
# For this script's own test only:
#   WORKTREE_HERDR_SAFE  the herdr-safe.sh to call [the one beside this script]
#   WORKTREE_PROC        the folder read as /proc off Windows [/proc]
# Exit codes:
#   0  the worktree was removed. The branch was deleted, kept with a line that says why (including one that moved after the check), or there was none (a detached HEAD).
#   1  usage, or a path that is not the top of a linked worktree (the main checkout is refused)
#   2  closing the tab failed, so nothing was removed
#   3  a process holds the path, or the process list could not be read, so nothing was removed
#   4  git worktree remove failed, so the branch stays
#   5  deleting the branch failed after the worktree was removed, or the list of worktrees could not be read before the delete
#
# What it misses:
#   - It finds a process by its command line only. A process that holds a file in the worktree without naming the path
#     on its command line (an editor, a shell whose working folder is there, a process of another name) is not found,
#     and git worktree remove then fails or leaves files behind.
#   - On Linux a process of another user can have a /proc/<pid>/cmdline that this user cannot read, and is then not found. A process that renamed itself (node's process.title) shows its new title.
#   - Under Git Bash the process list comes from PowerShell's Get-CimInstance Win32_Process. A process of another user or an elevated
#     process can show no command line and is then not found. A command line with characters outside the console's code page
#     can be garbled, so a path with such characters may not match.
#   - The tab is closed before the process check, so a run that stops at step 2 has already closed the tab.
#     Run it again without the tab id.
#   - It does not take worktree-new.sh's lock, so it is not kept apart from a git worktree add running in the same repository.
#   - It never deletes the branch on origin.
#   - The branch it judges is the one HEAD names in the worktree at the start. If the worktree was switched to another
#     branch, that one is judged and the ticket's own branch is left alone.
#   - A worktree on a detached HEAD has no branch to judge. It says so in one line and exits 0 once the worktree is removed.
#   - An origin that is not on github.com cannot be asked about pull requests, so its branch goes only on --owner-word.

LC_ALL=C
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HERDR_SAFE=${WORKTREE_HERDR_SAFE:-$HERE/herdr-safe.sh}
PROC=${WORKTREE_PROC:-/proc}
# Git Bash on Windows (uname -s starts MINGW, MSYS or CYGWIN) reads its process list from PowerShell. Any other machine reads /proc.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ON_WIN=1 ;;
  *) ON_WIN=0 ;;
esac
WORD=""
HAVE_WORD=0

say() {
  printf 'worktree-remove: %s\n' "$1"
}

err() {
  printf 'worktree-remove: %s\n' "$1" >&2
}

usage() {
  err "usage: worktree-remove.sh [--owner-word <their words>] <worktree> [<tab id>]"
  exit 1
}

while [ $# -gt 0 ]; do
  case $1 in
    --owner-word)
      [ -n "${2:-}" ] || usage
      WORD=$2
      HAVE_WORD=1
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || [ $# -eq 2 ] || usage
TAB=${2:-}

[ -d "$1" ] || {
  err "no folder at $1"
  exit 1
}
if [ "$ON_WIN" -eq 1 ]; then
  WT=$(cd -- "$1" && pwd -W)
else
  WT=$(cd -- "$1" && pwd -P)
fi || {
  err "cannot enter $1"
  exit 1
}
TOP=$(git -C "$WT" rev-parse --show-toplevel 2>/dev/null) || {
  err "$WT is not a git work tree"
  exit 1
}
if [ "$ON_WIN" -eq 1 ]; then
  if [ "${TOP,,}" != "${WT,,}" ]; then
    err "$WT is not the top of a worktree (that is $TOP)"
    exit 1
  fi
else
  # Git names the top in its own form of the path, so ask it whether this folder is the top, and use its form from here on.
  if [ -n "$(git -C "$WT" rev-parse --show-cdup)" ]; then
    err "$WT is not the top of a worktree (that is $TOP)"
    exit 1
  fi
  WT=$TOP
fi
GIT_DIR_ABS=$(git -C "$WT" rev-parse --absolute-git-dir) || exit 1
COMMON=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir) || exit 1
if [ "${GIT_DIR_ABS,,}" = "${COMMON,,}" ]; then
  err "$WT is a main checkout, not a linked worktree, and is never removed"
  exit 1
fi
MAIN=$(git -C "$WT" worktree list --porcelain | while IFS= read -r line; do
  printf '%s\n' "${line#worktree }"
  break
done)
[ -n "$MAIN" ] && [ -d "$MAIN" ] || {
  err "cannot find the main checkout of $WT"
  exit 1
}
BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD)
URL=$(git -C "$WT" config --get remote.origin.url)

# parse_origin <url>: sets HOST and OWNER_REPO. Fails on another shape.
parse_origin() {
  local u=$1 path
  case $u in
    https://* | http://* | ssh://*)
      u=${u#*://}
      u=${u#*@}
      HOST=${u%%/*}
      HOST=${HOST%%:*}
      path=${u#*/}
      ;;
    *@*:*)
      u=${u#*@}
      HOST=${u%%:*}
      path=${u#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [[ $path =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  OWNER_REPO=$path
  HOST=${HOST,,}
}

# Step 1: the tab.
if [ -n "$TAB" ]; then
  if ! "$HERDR_SAFE" tab close "$TAB" >&2; then
    err "closing the tab ${TAB%$'\r'} failed, so nothing was removed"
    exit 2
  fi
  say "closed the tab ${TAB%$'\r'}"
fi

# Step 2: processes whose command line holds the path.
PS_LIST="Get-CimInstance Win32_Process | Where-Object { @('node.exe','esbuild.exe','workerd.exe') -contains \$_.Name } | ForEach-Object { [string]\$_.ProcessId + [char]9 + \$_.Name + [char]9 + \$_.CommandLine }"

# list_linux: sets LIST to one line per node, esbuild or workerd process, "<pid><tab><name><tab><command line>", read from /proc/<pid>/cmdline
# (its words are separated by a NUL). A process counts by its comm name or by the last part of its first word. Fails when /proc cannot be read.
list_linux() {
  local d pid comm first name n
  local -a words
  LIST=""
  [ -d "$PROC" ] && [ -r "$PROC" ] || return 1
  for d in "$PROC"/[0-9]*; do
    [ -r "$d/cmdline" ] || continue
    pid=${d##*/}
    comm=""
    { IFS= read -r comm <"$d/comm"; } 2>/dev/null
    words=()
    mapfile -d '' -t words <"$d/cmdline" 2>/dev/null
    first=${words[0]:-}
    first=${first##*/}
    name=""
    for n in "$comm" "${first%.exe}"; do
      case $n in
        node | esbuild | workerd) name=$n ;;
      esac
    done
    [ -n "$name" ] || continue
    LIST+="$pid"$'\t'"$name"$'\t'"${words[*]}"$'\n'
  done
}

if [ "$ON_WIN" -eq 1 ]; then
  LIST=$(powershell.exe -NoProfile -NonInteractive -Command "$PS_LIST")
else
  list_linux
fi || {
  err "could not read the process list, so nothing was removed"
  exit 3
}
want=${WT//\\//}
[ "$ON_WIN" -eq 0 ] || want=${want,,}
HOLDERS=0
while IFS=$'\t' read -r pid name cmd; do
  cmd=${cmd%$'\r'}
  [ -n "$pid" ] || continue
  cmd=${cmd//\\//}
  [ "$ON_WIN" -eq 0 ] || cmd=${cmd,,}
  cmd="$cmd "
  # The path counts only when a separator, a quote or a space follows it, so ticket-1-a does not match ticket-1-ab.
  if [[ $cmd == *"$want"[/\"\'\ \;,]* ]]; then
    err "${name%$'\r'} pid $pid has $WT on its command line"
    HOLDERS=$((HOLDERS + 1))
  fi
done <<<"$LIST"
if [ "$HOLDERS" -gt 0 ]; then
  err "$HOLDERS process(es) hold $WT. Stop them by their ids, then run this again without the tab id. Nothing was removed."
  exit 3
fi

# Step 3: the worktree.
if ! git -C "$MAIN" worktree remove "$WT" >&2; then
  err "git worktree remove failed for $WT${BRANCH:+, so the branch $BRANCH stays}"
  exit 4
fi
say "removed the worktree $WT"

# Step 4: the branch, as its own command.
if [ -z "$BRANCH" ]; then
  say "the worktree was on a detached HEAD, so there is no branch to delete"
  exit 0
fi
# The tip is read once, here, before the pull request is asked about and before the delete, so the commit that is matched
# against headRefOid is the commit that the delete compares against.
TIP=$(git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$BRANCH")
if [ "$HAVE_WORD" -eq 1 ]; then
  reason="the owner's word: $WORD"
else
  if ! parse_origin "$URL" || [ "$HOST" != github.com ]; then
    say "kept the branch $BRANCH: its origin is not a GitHub repository, so no merged pull request can be found, and there is no --owner-word"
    exit 0
  fi
  if ! json=$(cd -- "$MAIN" && gh pr list -R "$OWNER_REPO" --head "$BRANCH" --state merged --json number,headRefOid,isCrossRepository); then
    say "kept the branch $BRANCH: gh could not say whether $OWNER_REPO has a merged pull request for it, and there is no --owner-word"
    exit 0
  fi
  # A pull request counts only when it is the origin repository's own (not a fork's) and its head commit is the
  # branch's tip. Otherwise the branch may hold commits that no merged pull request has, such as a commit after the merge.
  # gh prints an array of flat objects whose values hold no brace, so splitting on },{ gives one object per line.
  match="" own="" own_oid="" fork=""
  body=${json#*\[}
  body=${body%\]*}
  while IFS= read -r obj; do
    n="" oid="" cross=""
    [[ $obj =~ \"number\":[[:space:]]*([0-9]+) ]] && n=${BASH_REMATCH[1]}
    [[ $obj =~ \"headRefOid\":[[:space:]]*\"([0-9a-f]+)\" ]] && oid=${BASH_REMATCH[1]}
    [[ $obj =~ \"isCrossRepository\":[[:space:]]*(true|false) ]] && cross=${BASH_REMATCH[1]}
    [ -n "$n" ] || continue
    if [ "$cross" = false ]; then
      if [ -n "$TIP" ] && [ "$oid" = "$TIP" ]; then
        match=$n
        break
      fi
      [ -n "$own" ] || {
        own=$n
        own_oid=$oid
      }
    elif [ -z "$fork" ]; then
      fork=$n
    fi
  done <<<"${body//\},\{/$'\n'}"
  if [ -n "$match" ]; then
    reason="pull request #$match on $OWNER_REPO is merged at the branch's tip"
  elif [ -n "$own" ]; then
    say "kept the branch $BRANCH: pull request #$own on $OWNER_REPO was merged at ${own_oid:0:7}, but the branch's tip is ${TIP:0:7}, so it holds commits that no merged pull request has"
    exit 0
  elif [ -n "$fork" ]; then
    say "kept the branch $BRANCH: the merged pull request #$fork with that head name came from a fork, not from $OWNER_REPO"
    exit 0
  else
    say "kept the branch $BRANCH: $OWNER_REPO has no merged pull request for it, and there is no --owner-word"
    exit 0
  fi
fi
if [ -z "$TIP" ]; then
  err "deleting the branch $BRANCH failed ($reason)"
  exit 5
fi
# git branch -D refuses a branch that another worktree has checked out, and git update-ref -d does not, so ask first.
if ! wt_list=$(git -C "$MAIN" worktree list --porcelain); then
  err "could not list the worktrees to see whether another one has the branch $BRANCH checked out, so the branch was not deleted ($reason)"
  exit 5
fi
elsewhere=$(while IFS= read -r line; do
  case $line in
    "worktree "*) other=${line#worktree } ;;
    "branch refs/heads/$BRANCH")
      printf '%s\n' "$other"
      break
      ;;
  esac
done <<<"$wt_list")
if [ -n "$elsewhere" ]; then
  say "kept the branch $BRANCH: the worktree $elsewhere has it checked out"
  exit 0
fi
# The delete names the tip it was matched against, so git deletes the ref only while the ref still points there.
if ! git -C "$MAIN" update-ref -d "refs/heads/$BRANCH" "$TIP" >&2; then
  NOW=$(git -C "$MAIN" rev-parse --verify --quiet "refs/heads/$BRANCH")
  if [ -n "$NOW" ] && [ "$NOW" != "$TIP" ]; then
    say "kept the branch $BRANCH: it moved from ${TIP:0:7} to ${NOW:0:7} after the check, so it was not deleted"
    exit 0
  fi
  err "deleting the branch $BRANCH failed ($reason)"
  exit 5
fi
# git branch -D dropped the branch's config section and update-ref does not. A branch with no section is the usual case, and git
# says so with exit 128 and "no such section", which is also the exit of other fatal errors, so the message tells them apart.
if ! cfg=$(LC_ALL=C git -C "$MAIN" config --remove-section "branch.$BRANCH" 2>&1); then
  case $cfg in
    *"no such section"*) ;;
    *) err "could not remove the config section branch.$BRANCH after deleting the branch: ${cfg//$'\n'/ | }" ;;
  esac
fi
say "deleted the branch $BRANCH ($reason)"
exit 0
