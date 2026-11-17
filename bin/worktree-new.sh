#!/usr/bin/env bash
# worktree-new.sh [--wait <seconds>] <repo checkout> <issue> <slug>
# worktree-new.sh [--wait <seconds>] --detach <repo checkout> <commit> <slug>
# Makes a worktree for one ticket, the same way every time, from the manifest of the checkout's repository.
# With --detach it makes a reviewer's own copy instead: a detached worktree at <commit> (7 to 40 hex digits, the author's
# committed head, which may be a commit never pushed, since every worktree of a checkout shares its objects), with no branch made, at the manifest's
# repo.worktree with {issue} filled as review (project-review-<slug>). It takes the same lock, fetches, copies and runs the setup as for a ticket,
# needs no repo.branch, checks no branch, and prints {"path":"<worktree>","detached":"<full commit>"}. A commit the checkout does not hold exits 3.
# A failure undoes it the same way, and touches no branch. worktree-remove.sh removes it and says there is no branch to delete.
# Use it for every reviewer copy, never git worktree add by hand, so the lock holds.
# Steps, in this order:
#   1. Reads the manifest worktree-manifests/<repository name>.conf beside this script, where the name is the last part of the checkout's origin URL in lower case.
#      The manifest's repo.origin must name the same repository as the checkout's origin.
#   2. Takes the machine-wide lock, fetches origin, then runs git worktree add with a new branch from the default branch
#      (origin/HEAD, so origin/master or origin/main), with no upstream. Then it frees the lock.
#   3. Checks that git ignores every copy.path in the new worktree (git check-ignore, with a trailing slash for a folder),
#      and refuses the whole copy with one line naming the first path that is not ignored. Then it copies each copy.path
#      of the manifest from copy.from into the worktree, at the same relative path.
#   4. Runs each setup.run of the manifest, in order, in the folder setup.dir inside the worktree, through bash -c.
#   5. Prints one line of JSON to stdout: {"path":"<worktree>","branch":"<branch>","base":"origin/<default>"}.
# Nothing else goes to stdout. Progress, git's own output, setup output and errors go to stderr.
# Manifest keys (git config syntax, read with git config --file): repo.origin, repo.worktree, repo.branch,
# copy.from, copy.path (one per line, a file or a folder), setup.dir, setup.run (one per line).
# repo.worktree and repo.branch take the placeholders {issue}, {slug}, and {parent} for the checkout's parent folder.
# The issue is digits. The slug is lower case letters, digits and single hyphens.
# Another key, repo.remote (a boolean), says whether the manifest may be used on a cloud machine, where an agent holds no secret of the control machine.
# A machine is a cloud machine when a machine-self file sits beside this script (see machine-lib.sh). On such a machine a manifest without repo.remote = true is refused
# with one line naming the key, and so is a manifest with any copy.path, since a copied file could carry a secret. There the checkout must also hold a repo-local
# user.name and user.email (git config --local), or the call is refused with one line naming the missing key. The control machine does not check any of these, and ignores repo.remote.
#
# The lock: one file, $ORCH_HOME/locks/worktree-git.lock (ORCH_HOME defaults to the folder above this script's), the same for every caller whatever its working folder.
# It is held around the fetch and git worktree add, never around the copy or the setup, and again around an undo.
# It is made with ln from a complete holder record, so it never exists half written.
# A second call waits for it, polling each second, for at most --wait seconds (default 120), then fails with one line that
# names the lock and its holder. A waiting call says once that it waits, naming the holder.
# The holder is proved alive by its process id and that process's start time, read from /proc/<pid>/stat.
# A holder whose process is gone, or whose id now belongs to a process that started at another time, is stale.
# A stale lock is taken over with one line that says so.
# What that proof misses:
#   - A holder outside this machine's /proc (under Windows, WSL, Cygwin or another Git for Windows install) looks dead, so its lock is taken.
#     Run this script only from one shell runtime on a machine. On Linux the holder's record has no Windows id.
#   - A killed run's own git child can outlive it for a moment, and the takeover does not wait for that child.
#   - Two waiters that find the same stale lock at the same instant are kept apart by an atomic rename of the stale file.
#     If a third call takes the lock inside that window, the rename can move a live lock aside. The waiter then puts it back,
#     and if it cannot, two holders run at once. Each holder frees only a lock that still holds its own record.
#     A waiter that puts a moved lock back after its holder has already freed the lock leaves a record of a live
#     process in place. Nobody frees it, so the lock counts as held until that process ends, which can be minutes into
#     its copy or setup. Waiters meanwhile wait to their bound.
#   - A holder that hangs while alive keeps the lock. Waiters fail at their bound and name it, and a person decides.
#     The likely hang is git fetch, which runs under the lock with no time limit.
#   - A lock file with no pid or no start line (made by hand, by a flock or a touch, or cut short) is an unreadable record.
#     It counts as alive while the file is younger than 300 s (WORKTREE_STALE_EMPTY), and while another process holds a flock
#     on it. After that it is stale and taken over like any other (an empty file once blocked every call for
#     hours). The age is the file's modification time, read with stat, so a touch makes it young again. The flock is asked through a
#     descriptor opened for reading, so the check never makes the file. Where flock is missing (Git Bash) only the age counts.
#     These two checks fork, so a waiter forks once a poll while it waits on an unreadable record, and never on a readable one.
#
# A failure undoes what this call made. A missing copy source, a copy path git does not ignore, a failed copy, a failed
# setup command or a stop by INT, TERM or HUP removes the worktree (git worktree remove --force --force) and the branch
# this call created, under the lock, and says what it removed. It never touches a branch, folder or worktree it did not create.
# A stop that arrives while git worktree add runs is handled when git ends. From the start of git worktree add, a
# worktree path or branch that exists counts as this call's own, because the call proved under the lock just before
# that neither existed. Only a caller that skips this lock (a git branch or git worktree add typed by hand in that
# moment) could make one that the undo then removes as its own.
# A run killed outright (kill -9) cannot undo.
# What the undo and its lines miss:
#   - A stop that lands in the last moment of a good run, after the made flags are cleared, says "nothing was made" and exits 4 while the worktree stays.
#   - A copy folder that is missing at its source, and whose ignore pattern needs a trailing slash (work/), is reported as not ignored, not as missing. The call is undone either way.
#   - A worktree at the same path that git still lists but whose folder was deleted by hand is removed from git's list as this call's own, and the line says this call made it.
# Secrets: a copied file is copied with cp and nothing else. Its contents are never printed, logged, diffed or hashed.
# The origin URL is never printed whole, since it can carry a token. Only host/owner/repo is printed.
# A setup command's own output goes to stderr as it is. This script cannot vouch that a setup command prints no secret.
#
# Flags:
#   --wait <seconds>   how long to wait for the lock, a whole number, 0 to try once (default 120)
#   --detach           make a reviewer's detached copy at the commit given in place of the issue (above)
# For this script's own test only (never set them in real use, since they break the machine-wide lock):
#   WORKTREE_LOCK       the lock file [$ORCH_HOME/locks/worktree-git.lock]
#   WORKTREE_MANIFESTS  the manifest folder [the worktree-manifests folder beside this script]
#   WORKTREE_STALE_EMPTY  the age in whole seconds after which an unreadable record is stale [300]
#   MACHINE_SELF_FILE   the machine-self file whose presence makes this a cloud machine [machine-self beside this script]
# Exit codes:
#   0  made, the JSON line printed
#   1  usage, a checkout that is not a git work tree, no origin, no origin/HEAD, no manifest, a bad manifest, or (on a cloud machine) one without repo.remote = true or with a copy.path, or a checkout without a repo-local git identity
#      With --detach also a commit that is not 7 to 40 hex digits. origin/HEAD is not needed then.
#   2  the lock was still held at the end of --wait, or it could not be made at all (its line says which)
#   3  a git step failed before anything was kept: the fetch, a branch or a path that already exists, git worktree add, or with --detach a commit the checkout does not hold
#   4  a copy path git does not ignore, a failed copy or setup command, or a stop, and the worktree and branch were removed again
#   5  the undo itself failed. Its line names what is left and the commands to remove it.

LC_ALL=C
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Git Bash on Windows is told by uname -s (MINGW, MSYS or CYGWIN), which matters for path forms only.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*) ON_WIN=1 ;;
  *) ON_WIN=0 ;;
esac
# A cloud machine is one with a machine-self file beside this script, as slots.sh and run-long.sh read it. The policy for what may be set up there follows from it.
REMOTE=0
[ ! -e "${MACHINE_SELF_FILE:-$HERE/machine-self}" ] || REMOTE=1
ORCH_HOME=${ORCH_HOME:-$(cd "$HERE/.." && pwd)}
LOCK=${WORKTREE_LOCK:-$ORCH_HOME/locks/worktree-git.lock}
MANIFESTS=${WORKTREE_MANIFESTS:-$HERE/worktree-manifests}
WAIT=120
POLL_US=1000000
STALE_EMPTY=${WORKTREE_STALE_EMPTY:-300}
[[ $STALE_EMPTY =~ ^[0-9]+$ ]] || {
  printf 'worktree-new: WORKTREE_STALE_EMPTY must be a whole number of seconds, got %s\n' "$STALE_EMPTY" >&2
  exit 1
}
STALE_EMPTY=$((10#$STALE_EMPTY))

HAVE_LOCK=0
MY_RECORD=""
MADE_WT=0
MADE_BRANCH=0
ATTEMPT=0
REMOVED=""
CHECKOUT=""
WT=""
BRANCH=""
DETACH=0
COMMIT=""

say() {
  printf 'worktree-new: %s\n' "$1" >&2
}

usage() {
  say "usage: worktree-new.sh [--wait <seconds>] [--detach] <repo checkout> <issue, or with --detach a commit> <slug>"
  exit 1
}

# The helpers below set a variable instead of printing, because the wait loop must not fork.
# A fork in Git Bash can take seconds on a loaded machine, and a loop that forks overshoots its bound.

# now_us: sets NOW_US to the time in microseconds.
now_us() {
  local t=${EPOCHREALTIME/./}
  NOW_US=$((10#$t))
}

# start_of <pid>: sets START_OF to the start time field of that Git Bash process, or fails when it is gone.
start_of() {
  local line rest f
  START_OF=""
  [ -r "/proc/$1/stat" ] || return 1
  { IFS= read -r line <"/proc/$1/stat"; } 2>/dev/null || return 1
  rest=${line##*) }
  read -r -a f <<<"$rest"
  [ -n "${f[19]:-}" ] || return 1
  START_OF=${f[19]}
}

# field <record> <key>: sets FIELD to the value of key=value in a holder record, or fails when the key is not there.
field() {
  local pattern=$'\n'"$2"$'=([^\n]*)'
  FIELD=""
  [[ $'\n'$1 =~ $pattern ]] || return 1
  FIELD=${BASH_REMATCH[1]}
}

# lock_age: sets LOCK_AGE to the seconds since the lock file last changed, or fails when the file cannot be looked at.
# It forks stat, so only an unreadable record calls it.
lock_age() {
  local mtime now
  LOCK_AGE=""
  mtime=$(stat -c %Y -- "$LOCK" 2>/dev/null) || return 1
  [[ $mtime =~ ^[0-9]+$ ]] || return 1
  printf -v now '%(%s)T' -1
  LOCK_AGE=$((now - 10#$mtime))
  [ "$LOCK_AGE" -ge 0 ] || LOCK_AGE=0
}

# describe <record>: sets DESCRIBED to one phrase naming the holder, and UNREADABLE to 1 for a record with no pid or no start time.
# For an unreadable record it reads the lock file's age, so call it while the file is still in place.
describe() {
  local pid winpid since branch age="age unknown"
  UNREADABLE=0
  if ! field "$1" pid || ! field "$1" start; then
    UNREADABLE=1
    ! lock_age || age="$LOCK_AGE s old"
    DESCRIBED="an unreadable holder record (${#1} bytes, $age)"
    return
  fi
  field "$1" pid
  pid=$FIELD
  field "$1" winpid
  winpid=$FIELD
  field "$1" since
  since=$FIELD
  field "$1" branch
  branch=$FIELD
  field "$1" checkout
  DESCRIBED="pid $pid${winpid:+ (Windows $winpid)}, since $since, making $branch from $FIELD"
}

# holder_alive <record>: true while the holder's process runs. A record with no pid or no start time is judged by unreadable_alive.
holder_alive() {
  local pid
  field "$1" pid || {
    unreadable_alive
    return
  }
  pid=$FIELD
  field "$1" start || {
    unreadable_alive
    return
  }
  start_of "$pid" || return 1
  [ "$START_OF" = "$FIELD" ]
}

# unreadable_alive: true while the lock file is younger than STALE_EMPTY seconds, while it cannot be looked at, or while another
# process holds a flock on it. The flock is asked through a descriptor opened for reading, which never makes the file.
unreadable_alive() {
  local fd held=0
  lock_age || return 0
  [ "$LOCK_AGE" -ge "$STALE_EMPTY" ] || return 0
  if type -P flock >/dev/null && { exec {fd}<"$LOCK"; } 2>/dev/null; then
    flock -n "$fd" || held=1
    exec {fd}<&-
  fi
  [ "$held" -eq 1 ]
}

read_lock() {
  LOCK_TEXT=""
  [ -e "$LOCK" ] || return 1
  { IFS= read -r -d '' LOCK_TEXT <"$LOCK"; } 2>/dev/null
  return 0
}

# take_stale <record>: moves the stale lock aside, and removes it only when it still holds that record.
# Returns 0 when the lock file is gone or changed, so the caller tries again at once.
# Returns 1 when the stale lock could not be moved and is still there, so the caller waits as for a live one.
take_stale() {
  local moved got=""
  describe "$1"
  moved="$LOCK.stale.$$.$RANDOM"
  if ! mv -- "$LOCK" "$moved" 2>/dev/null; then
    read_lock || return 0
    [ "$LOCK_TEXT" != "$1" ]
    return
  fi
  { IFS= read -r -d '' got <"$moved"; } 2>/dev/null
  if [ "$got" = "$1" ]; then
    rm -f -- "$moved"
    if [ "$UNREADABLE" -eq 1 ]; then
      say "took the stale lock $LOCK, $DESCRIBED, older than $STALE_EMPTY s and with no flock held on it"
    else
      say "took the stale lock $LOCK left by $DESCRIBED, which no longer runs"
    fi
  else
    ln -- "$moved" "$LOCK" 2>/dev/null
    rm -f -- "$moved"
  fi
  return 0
}

# acquire: takes the lock within --wait seconds. Returns 1 when it is still held at the end.
acquire() {
  local deadline tmp said=0 left pause
  [ "$HAVE_LOCK" -eq 0 ] || return 0
  mkdir -p -- "${LOCK%/*}" 2>/dev/null
  tmp="$LOCK.$$.tmp"
  start_of $$ || {
    say "cannot read this process's start time from /proc/$$/stat, so the lock cannot be taken"
    return 1
  }
  local winpid="" since
  { IFS= read -r winpid <"/proc/$$/winpid"; } 2>/dev/null
  printf -v since '%(%Y-%m-%d %H:%M:%S)T' -1
  MY_RECORD="pid=$$
start=$START_OF
winpid=$winpid
since=$since
nonce=$RANDOM$RANDOM
checkout=$CHECKOUT
branch=$BRANCH
"
  if ! printf '%s' "$MY_RECORD" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    say "cannot write $tmp, so the lock cannot be taken"
    return 1
  fi
  now_us
  deadline=$((NOW_US + WAIT * 1000000))
  while :; do
    if ln -- "$tmp" "$LOCK" 2>/dev/null; then
      rm -f -- "$tmp"
      HAVE_LOCK=1
      return 0
    fi
    now_us
    if read_lock; then
      if ! holder_alive "$LOCK_TEXT" && take_stale "$LOCK_TEXT"; then
        continue
      fi
    elif [ "$NOW_US" -lt "$deadline" ]; then
      # Freed between the ln and the read. Try again soon, but never past the bound, so a lock that cannot be made at all ends.
      sleep 0.1
      continue
    fi
    now_us
    left=$((deadline - NOW_US))
    if [ "$left" -le 0 ]; then
      rm -f -- "$tmp"
      if [ -e "$LOCK" ]; then
        describe "$LOCK_TEXT"
        say "gave up after $WAIT s: the lock $LOCK is held by $DESCRIBED"
      else
        say "gave up after $WAIT s: the lock $LOCK could not be made"
      fi
      return 1
    fi
    if [ "$said" -eq 0 ]; then
      describe "$LOCK_TEXT"
      say "waiting up to $WAIT s for the lock $LOCK, held by $DESCRIBED"
      said=1
    fi
    [ "$left" -le "$POLL_US" ] || left=$POLL_US
    printf -v pause '%d.%06d' $((left / 1000000)) $((left % 1000000))
    sleep "$pause"
  done
}

release() {
  [ "$HAVE_LOCK" -eq 1 ] || return 0
  HAVE_LOCK=0
  read_lock || return 0
  [ "$LOCK_TEXT" != "$MY_RECORD" ] || rm -f -- "$LOCK"
}

listed() {
  git -C "$CHECKOUT" worktree list --porcelain 2>/dev/null | grep -qixF "worktree $WT"
}

# undo: removes the worktree and the branch this call made, under the lock. Sets REMOVED to what it removed, for the
# message. Returns 1 when something is left.
# From the moment git worktree add starts (ATTEMPT=1), a worktree path or branch that exists is this call's own, because
# the call proved under the lock that neither existed just before. A signal arriving during git worktree add runs its
# trap only after git ends, with MADE_WT and MADE_BRANCH still 0, so the undo looks for itself.
undo() {
  local left=""
  REMOVED=""
  if [ "$ATTEMPT" -eq 1 ]; then
    if [ -e "$WT" ] || [ -L "$WT" ] || listed; then
      MADE_WT=1
    fi
    # A detached copy has no branch of its own, so no branch is ever removed for it.
    if [ "$DETACH" -eq 0 ] && git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      MADE_BRANCH=1
    fi
  fi
  [ "$MADE_WT" -eq 1 ] || [ "$MADE_BRANCH" -eq 1 ] || return 0
  if ! acquire; then
    left="the lock was not free"
  else
    if [ "$MADE_WT" -eq 1 ]; then
      # Twice --force also removes a worktree that a git stopped half way left locked.
      if git -C "$CHECKOUT" worktree remove --force --force "$WT" >&2; then
        MADE_WT=0
      elif ! listed && rm -rf -- "$WT" && git -C "$CHECKOUT" worktree prune >&2; then
        # A folder git made but never registered. It did not exist before this call.
        MADE_WT=0
      else
        left="git worktree remove failed"
      fi
      [ "$MADE_WT" -eq 1 ] || REMOVED="the worktree $WT"
    fi
    if [ "$MADE_WT" -eq 0 ] && [ "$MADE_BRANCH" -eq 1 ]; then
      if git -C "$CHECKOUT" branch -D "$BRANCH" >/dev/null 2>&1; then
        MADE_BRANCH=0
        REMOVED="${REMOVED:+$REMOVED and }the branch $BRANCH"
      else
        left="git branch -D failed"
      fi
    fi
    release
  fi
  [ -z "$left" ] && return 0
  if [ "$DETACH" -eq 1 ]; then
    # A detached copy has no branch, so the line names none.
    say "could not undo ($left).${REMOVED:+ Removed $REMOVED.} Left: the detached copy $WT, which has no branch. Remove it with: git -C \"$CHECKOUT\" worktree remove --force --force \"$WT\""
  else
    say "could not undo ($left).${REMOVED:+ Removed $REMOVED.} Left: worktree $WT and branch $BRANCH. Remove them with: git -C \"$CHECKOUT\" worktree remove --force --force \"$WT\", then git -C \"$CHECKOUT\" branch -D $BRANCH"
  fi
  return 1
}

# fail_undo <message>: undoes what this call made, says what it removed, then exits 4, or 5 when the undo failed.
fail_undo() {
  say "$1"
  undo || exit 5
  if [ -n "$REMOVED" ]; then
    say "removed $REMOVED, which this call made"
  else
    say "nothing was made"
  fi
  exit 4
}

# shellcheck disable=SC2329  # run by the signal traps below
on_signal() {
  trap - INT TERM HUP
  fail_undo "stopped by a signal"
}

# shellcheck disable=SC2329  # run by the EXIT trap below
on_exit() {
  release
  [ -z "${TMP_LOCK:-}" ] || rm -f -- "$TMP_LOCK"
}

# parse_origin <url>: sets ORIGIN_ID to host/owner/repo in lower case and REPO_NAME to repo. Fails on another shape.
parse_origin() {
  local u=$1 host path
  case $u in
    https://* | http://* | ssh://*)
      u=${u#*://}
      u=${u#*@}
      host=${u%%/*}
      host=${host%%:*}
      path=${u#*/}
      ;;
    *@*:*)
      u=${u#*@}
      host=${u%%:*}
      path=${u#*:}
      ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ $path =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  ORIGIN_ID="$host/$path"
  ORIGIN_ID=${ORIGIN_ID,,}
  REPO_NAME=${ORIGIN_ID##*/}
}

fill() {
  local s=$1
  # Quoted, because bash 5.2 and later read an unquoted & in the replacement as the matched text.
  s=${s//\{issue\}/"$ISSUE"}
  s=${s//\{slug\}/"$SLUG"}
  s=${s//\{parent\}/"$PARENT"}
  printf '%s\n' "$s"
}

# A relative path inside the worktree: not empty, not absolute, no .. part.
inside_path() {
  [ -n "$1" ] || return 1
  case "/$1/" in
    *"/../"* | *"/./"* | *"\\"*) return 1 ;;
  esac
  case $1 in
    /* | [A-Za-z]:*) return 1 ;;
  esac
  return 0
}

json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

while [ $# -gt 0 ]; do
  case $1 in
    --wait)
      [[ ${2:-} =~ ^[0-9]+$ ]] || usage
      WAIT=$((10#$2))
      shift 2
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -eq 3 ] || usage
ISSUE=$2
SLUG=$3
if [ "$DETACH" -eq 1 ]; then
  COMMIT=$2
  [[ $COMMIT =~ ^[0-9a-f]{7,40}$ ]] || { say "the commit must be 7 to 40 hex digits, got '$COMMIT'"; exit 1; }
  # The copy's path is the manifest's worktree path with {issue} filled as review.
  ISSUE=review
fi
[ "$DETACH" -eq 1 ] || [[ $ISSUE =~ ^[0-9]+$ ]] || { say "the issue must be digits, got '$ISSUE'"; exit 1; }
[[ $SLUG =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { say "the slug must be lower case letters, digits and single hyphens, got '$SLUG'"; exit 1; }
[ -d "$1" ] || { say "no folder at $1"; exit 1; }
CHECKOUT=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || { say "$1 is not a git work tree"; exit 1; }
PARENT=${CHECKOUT%/*}

url=$(git -C "$CHECKOUT" config --get remote.origin.url) || { say "$CHECKOUT has no origin remote"; exit 1; }
parse_origin "$url" || { say "cannot read host/owner/repo from the origin of $CHECKOUT"; exit 1; }
CHECKOUT_ID=$ORIGIN_ID
MF="$MANIFESTS/$REPO_NAME.conf"
[ -f "$MF" ] || { say "no manifest at $MF for $CHECKOUT_ID"; exit 1; }

mget() {
  git config --file "$MF" --get "$1"
}
mall() {
  git config --file "$MF" --get-all "$1"
}
bad_manifest() {
  say "manifest $MF: $1"
  exit 1
}

murl=$(mget repo.origin) || bad_manifest "no repo.origin"
parse_origin "$murl" || bad_manifest "cannot read host/owner/repo from repo.origin"
[ "$ORIGIN_ID" = "$CHECKOUT_ID" ] || bad_manifest "it names $ORIGIN_ID, but the checkout's origin is $CHECKOUT_ID"
# On a cloud machine only a manifest that says so may be used: repo.remote = true, and no copy.path below.
if [ "$REMOTE" -eq 1 ]; then
  [ "$(git config --file "$MF" --type=bool --get repo.remote 2>/dev/null)" = true ] || bad_manifest "repo.remote is not true, so this repository may not be set up on this machine"
fi
pattern=$(mget repo.worktree) || bad_manifest "no repo.worktree"
bpattern=""
[ "$DETACH" -eq 1 ] || bpattern=$(mget repo.branch) || bad_manifest "no repo.branch"
WT=$(fill "$pattern")
case $WT in
  [A-Za-z]:/*) ;;
  /*) [ "$ON_WIN" -eq 0 ] || WT=$(cygpath -m "$WT") ;;
  *) bad_manifest "repo.worktree must be an absolute path, got $WT" ;;
esac
if [ "$DETACH" -eq 0 ]; then
  BRANCH=$(fill "$bpattern")
  git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || bad_manifest "repo.branch makes '$BRANCH', which is not a branch name"
fi
mapfile -t COPY_PATHS < <(mall copy.path)
[ "$REMOTE" -eq 0 ] || [ "${#COPY_PATHS[@]}" -eq 0 ] || bad_manifest "copy.path is set, and a manifest that copies files may not be used on this machine"
# On a cloud machine the checkout must carry its own git identity, since the machine has none of the control machine's global config. A worktree shares the checkout's local config.
if [ "$REMOTE" -eq 1 ]; then
  for key in user.name user.email; do
    [ -n "$(git -C "$CHECKOUT" config --local --get "$key" 2>/dev/null)" ] || {
      say "$CHECKOUT has no repo-local git $key, so a commit there would carry the wrong author. Set it with git config --local $key in the checkout"
      exit 1
    }
  done
fi
COPY_FROM=""
if [ "${#COPY_PATHS[@]}" -gt 0 ]; then
  COPY_FROM=$(mget copy.from) || bad_manifest "copy.path is set but copy.from is not"
  for p in "${COPY_PATHS[@]}"; do
    inside_path "$p" || bad_manifest "copy.path '$p' must be a relative path with no . or .. part"
  done
fi
mapfile -t SETUP_RUNS < <(mall setup.run)
SETUP_DIR=$(mget setup.dir) || SETUP_DIR=.
[ "$SETUP_DIR" = . ] || inside_path "$SETUP_DIR" || bad_manifest "setup.dir '$SETUP_DIR' must be a relative path with no . or .. part"

BASE=""
[ "$DETACH" -eq 1 ] || BASE=$(git -C "$CHECKOUT" symbolic-ref --quiet --short refs/remotes/origin/HEAD) || {
  say "origin/HEAD is not set in $CHECKOUT, so the default branch is unknown. Run git remote set-head origin --auto there first."
  exit 1
}

trap on_exit EXIT
trap on_signal INT TERM HUP

TMP_LOCK="$LOCK.$$.tmp"
acquire || exit 2
say "fetching origin in $CHECKOUT"
git -C "$CHECKOUT" fetch --quiet origin >&2 || { say "the fetch from origin failed in $CHECKOUT, so nothing was made"; exit 3; }
if [ "$DETACH" -eq 1 ]; then
  FULL=$(git -C "$CHECKOUT" rev-parse --verify --quiet "$COMMIT^{commit}") || {
    say "$COMMIT is not a commit in $CHECKOUT, so nothing was made. The copy is made from the author's committed head, so the author commits first"
    exit 3
  }
else
  git -C "$CHECKOUT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { say "$BASE is not a commit after the fetch, so nothing was made"; exit 3; }
  if git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    say "the branch $BRANCH already exists in $CHECKOUT, so nothing was made"
    exit 3
  fi
fi
if [ -e "$WT" ] || [ -L "$WT" ]; then
  say "$WT already exists, so nothing was made"
  exit 3
fi
# The checks above proved, under the lock, that neither the branch nor the path exists. From here on any that exists is ours.
ATTEMPT=1
if [ "$DETACH" -eq 1 ]; then
  say "adding the detached copy $WT at $FULL"
  added=0
  git -C "$CHECKOUT" worktree add --quiet --detach "$WT" "$FULL" >&2 && added=1
else
  say "adding the worktree $WT on $BRANCH from $BASE"
  added=0
  git -C "$CHECKOUT" worktree add --quiet --no-track -b "$BRANCH" "$WT" "$BASE" >&2 && added=1
fi
if [ "$added" -eq 0 ]; then
  say "git worktree add failed"
  undo || exit 5
  say "nothing was kept${REMOVED:+ (removed $REMOVED, which this call made)}"
  exit 3
fi
MADE_WT=1
if [ "$DETACH" -eq 0 ]; then
  MADE_BRANCH=1
  if git -C "$CHECKOUT" rev-parse --verify --quiet "$BRANCH@{upstream}" >/dev/null 2>&1; then
    git -C "$CHECKOUT" branch --unset-upstream "$BRANCH" >&2 || fail_undo "could not unset the upstream of $BRANCH"
  fi
fi
release

# Every copy path must be ignored by git in the new worktree before anything is copied, so a secret can never show in
# git status or a diff. A folder is checked with a trailing slash, since git's folder patterns such as work/ need one.
for p in "${COPY_PATHS[@]}"; do
  q=$p
  [ ! -d "$COPY_FROM/$p" ] || q="$p/"
  if ! git -C "$WT" check-ignore -q -- "$q"; then
    fail_undo "the copy path $p is not ignored by git in $WT, so nothing was copied"
  fi
done

for p in "${COPY_PATHS[@]}"; do
  src="$COPY_FROM/$p"
  dst="$WT/$p"
  if [ -d "$src" ]; then
    if ! { mkdir -p -- "$dst" && cp -pR -- "$src/." "$dst/"; }; then
      fail_undo "copying the folder $src failed"
    fi
  elif [ -f "$src" ]; then
    if ! { mkdir -p -- "${dst%/*}" && cp -p -- "$src" "$dst"; }; then
      fail_undo "copying the file $src failed"
    fi
  else
    fail_undo "the copy source $src is missing"
  fi
done

for cmd in "${SETUP_RUNS[@]}"; do
  say "running '$cmd' in $WT/$SETUP_DIR"
  (cd -- "$WT/$SETUP_DIR" && bash -c "$cmd") </dev/null >&2
  rc=$?
  [ "$rc" -eq 0 ] || fail_undo "the setup command '$cmd' failed in $WT/$SETUP_DIR (exit $rc)"
done

MADE_WT=0
MADE_BRANCH=0
ATTEMPT=0
if [ "$DETACH" -eq 1 ]; then
  printf '{"path":%s,"detached":%s}\n' "$(json "$WT")" "$(json "$FULL")"
else
  printf '{"path":%s,"branch":%s,"base":%s}\n' "$(json "$WT")" "$(json "$BRANCH")" "$(json "$BASE")"
fi
exit 0
