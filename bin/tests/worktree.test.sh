#!/usr/bin/env bash
# shellcheck disable=SC2034  # cases.sh reads CASE_NAMES
#
# Tests worktree-new.sh and worktree-remove.sh against a throwaway repository. The repository's origin remote is a GitHub URL
# that git rewrites to a local bare repository (url.<bare>.insteadOf), so the scripts read a real-looking origin and fetch with no network.
# A fake gh answers the merged pull request question. Each case is its own function, run by cases.sh.
#   makes_worktree         a worktree on a new branch from origin's default branch, no upstream, and the JSON line on stdout
#   runs_setup             a manifest's setup.run runs inside the worktree
#   bad_arguments          a bad slug, a bad issue and a missing checkout are refused, exit 1, and nothing is made
#   no_manifest            a repository with no manifest is refused with a line naming the file, exit 1
#   branch_exists          a branch that already exists is refused, exit 3, and left alone
#   setup_failure_undone   a failing setup command removes the worktree and the branch, exit 4
#   copy_not_ignored       a copy.path that git does not ignore is refused and everything is undone, exit 4
#   copy_ignored           an ignored copy.path is copied into the worktree
#   detach                 --detach makes a detached copy at a commit and makes no branch
#   lock_held              a live holder keeps the lock, so a call with --wait 0 exits 2 and names the holder
#   stale_lock             a lock whose process is gone is taken over with a line saying so
#   cloud_policy           with a machine-self file, a manifest without repo.remote, one with a copy.path and a checkout with no identity are refused
#   remove_keeps_branch    worktree-remove removes the worktree and keeps the branch when no merged pull request is found
#   remove_with_word       --owner-word deletes the branch and quotes the word
#   remove_merged          a merged pull request at the branch's tip deletes the branch, one at another commit keeps it
#   remove_refuses_main    the main checkout is never removed

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CASES_SH="${CASES_SH:-$HERE/cases.sh}"
# shellcheck source=cases.sh
source "$CASES_SH"
BIN=$(cd "$HERE/.." && pwd)
NEW="$BIN/worktree-new.sh"
REMOVE="$BIN/worktree-remove.sh"

CASE_NAMES=(makes_worktree runs_setup bad_arguments no_manifest branch_exists setup_failure_undone copy_not_ignored copy_ignored detach
  lock_held stale_lock cloud_policy remove_keeps_branch remove_with_word remove_merged remove_refuses_main)
cases_init "$@"

WORK=$(mktemp -d)
trap 'cases_stop; rm -rf "${WORK:?}"' EXIT
trap 'exit 1' INT TERM
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export WORKTREE_LOCK="$WORK/locks/worktree-git.lock"
export MACHINE_SELF_FILE="$WORK/no-machine-self"
MANIFESTS="$WORK/manifests"
export WORKTREE_MANIFESTS="$MANIFESTS"
mkdir -p "$MANIFESTS" "$WORK/bin"
ORIGIN_URL=https://github.com/example-org/demo

# A bare repository stands in for the remote, and a checkout of it has the GitHub URL as its origin.
git init -q --bare -b main "$WORK/remote.git"
git init -q -b main "$WORK/seed"
git -C "$WORK/seed" commit -q --allow-empty -m first
printf 'ignored/\n.env\n' >"$WORK/seed/.gitignore"
git -C "$WORK/seed" add .gitignore
git -C "$WORK/seed" commit -q -m ignore
git -C "$WORK/seed" push -q "$WORK/remote.git" main
git config --global "url.$WORK/remote.git.insteadOf" "$ORIGIN_URL"
mkdir -p "$WORK/src"
git clone -q "$ORIGIN_URL" "$WORK/src/demo"
git -C "$WORK/src/demo" remote set-head origin --auto >/dev/null
CHECKOUT="$WORK/src/demo"

# manifest [extra lines]: the manifest of the demo repository.
manifest() {
  {
    printf '[repo]\n\torigin = %s\n\tworktree = {parent}/demo-{issue}-{slug}\n\tbranch = ticket/{issue}-{slug}\n' "$ORIGIN_URL"
    printf '%s\n' "$@"
  } >"$MANIFESTS/demo.conf"
}

# A fake gh: GH_JSON is what gh pr list prints.
cat >"$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GH_JSON:-[]}"
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

# new <args...>: OUT is stdout, ERRTEXT stderr, RC the exit status.
new() {
  OUT=$(bash "$NEW" "$@" 2>"$WORK/err")
  RC=$?
  ERRTEXT=$(<"$WORK/err")
}
remove() {
  OUT=$(bash "$REMOVE" "$@" 2>"$WORK/err")
  RC=$?
  ERRTEXT=$(<"$WORK/err")
}
rc_is() { [[ "$RC" == "$1" ]] || WHY+=("exit $RC, want $1: $OUT $ERRTEXT"); }
has_branch() { git -C "$CHECKOUT" show-ref --verify --quiet "refs/heads/$1"; }

case_makes_worktree() {
  manifest
  new "$CHECKOUT" 7 first-ticket
  rc_is 0
  [[ "$OUT" == '{"path":"'"$WORK"'/src/demo-7-first-ticket","branch":"ticket/7-first-ticket","base":"origin/main"}' ]] || WHY+=("the JSON line is wrong: $OUT")
  [[ -d "$WORK/src/demo-7-first-ticket/.git" || -f "$WORK/src/demo-7-first-ticket/.git" ]] || WHY+=("no worktree")
  has_branch ticket/7-first-ticket || WHY+=("no branch")
  git -C "$CHECKOUT" rev-parse --verify --quiet 'ticket/7-first-ticket@{upstream}' >/dev/null 2>&1 && WHY+=("the branch has an upstream")
  [[ ! -e "$WORKTREE_LOCK" ]] || WHY+=("the lock was left")
}

case_runs_setup() {
  manifest '[setup]' $'\tdir = sub' $'\trun = pwd > ../ran.txt'
  mkdir -p "$WORK/src/x"
  git -C "$CHECKOUT" worktree prune
  # The setup directory must exist in the worktree, so commit one to the remote first.
  new "$CHECKOUT" 8 with-setup
  [[ "$RC" == 4 ]] || WHY+=("a setup dir that is missing should fail with 4, got $RC: $ERRTEXT")
  has_branch ticket/8-with-setup && WHY+=("the branch was left after the failed setup")
  manifest '[setup]' $'\trun = pwd > ran.txt'
  new "$CHECKOUT" 8 with-setup
  rc_is 0
  [[ "$(<"$WORK/src/demo-8-with-setup/ran.txt")" == "$WORK/src/demo-8-with-setup" ]] || WHY+=("the setup did not run in the worktree")
}

case_bad_arguments() {
  manifest
  new "$CHECKOUT" 9 Bad_Slug
  rc_is 1
  new "$CHECKOUT" nine ok-slug
  rc_is 1
  new "$WORK/no-such-folder" 9 ok-slug
  rc_is 1
  new "$CHECKOUT" 9
  rc_is 1
  has_branch ticket/9-ok-slug && WHY+=("a branch was made")
}

case_no_manifest() {
  rm -f "$MANIFESTS/demo.conf"
  new "$CHECKOUT" 10 anything
  rc_is 1
  [[ "$ERRTEXT" == *"no manifest at $MANIFESTS/demo.conf"* ]] || WHY+=("the line does not name the manifest: $ERRTEXT")
}

case_branch_exists() {
  manifest
  git -C "$CHECKOUT" branch ticket/11-dup
  new "$CHECKOUT" 11 dup
  rc_is 3
  [[ "$ERRTEXT" == *"already exists"* ]] || WHY+=("no 'already exists' line: $ERRTEXT")
  has_branch ticket/11-dup || WHY+=("the branch that was there is gone")
}

case_setup_failure_undone() {
  manifest '[setup]' $'\trun = false'
  new "$CHECKOUT" 12 broken
  rc_is 4
  [[ ! -e "$WORK/src/demo-12-broken" ]] || WHY+=("the worktree was left")
  has_branch ticket/12-broken && WHY+=("the branch was left")
  [[ "$ERRTEXT" == *"removed"* ]] || WHY+=("no 'removed' line: $ERRTEXT")
  [[ ! -e "$WORKTREE_LOCK" ]] || WHY+=("the lock was left")
}

case_copy_not_ignored() {
  manifest '[copy]' $'\tfrom = '"$WORK/secrets" $'\tpath = notignored.txt'
  mkdir -p "$WORK/secrets"
  printf 'x\n' >"$WORK/secrets/notignored.txt"
  new "$CHECKOUT" 13 leak
  rc_is 4
  [[ "$ERRTEXT" == *"is not ignored by git"* ]] || WHY+=("no 'not ignored' line: $ERRTEXT")
  [[ ! -e "$WORK/src/demo-13-leak" ]] || WHY+=("the worktree was left")
  has_branch ticket/13-leak && WHY+=("the branch was left")
}

case_copy_ignored() {
  mkdir -p "$WORK/secrets"
  printf 'x\n' >"$WORK/secrets/.env"
  manifest '[copy]' $'\tfrom = '"$WORK/secrets" $'\tpath = .env'
  new "$CHECKOUT" 14 copies
  rc_is 0
  [[ "$(<"$WORK/src/demo-14-copies/.env")" == x ]] || WHY+=("the file was not copied")
}

case_detach() {
  manifest
  local head
  head=$(git -C "$CHECKOUT" rev-parse HEAD)
  new --detach "$CHECKOUT" "${head:0:12}" review-me
  rc_is 0
  [[ "$OUT" == '{"path":"'"$WORK"'/src/demo-review-review-me","detached":"'"$head"'"}' ]] || WHY+=("the JSON line is wrong: $OUT")
  [[ -z "$(git -C "$WORK/src/demo-review-review-me" branch --show-current)" ]] || WHY+=("the copy is on a branch")
  new --detach "$CHECKOUT" deadbeef2 review-two
  rc_is 3
}

case_lock_held() {
  manifest
  mkdir -p "$WORK/locks"
  sleep 30 &
  local holder=$! start
  start=$(awk '{ s = $0; sub(/^.*\) /, "", s); split(s, f, " "); print f[20] }' "/proc/$holder/stat")
  printf 'pid=%s\nstart=%s\nwinpid=\nsince=now\nnonce=1\ncheckout=%s\nbranch=other\n' "$holder" "$start" "$CHECKOUT" >"$WORKTREE_LOCK"
  new --wait 0 "$CHECKOUT" 15 blocked
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  rm -f "$WORKTREE_LOCK"
  rc_is 2
  [[ "$ERRTEXT" == *"held by pid $holder"* ]] || WHY+=("the line does not name the holder: $ERRTEXT")
  has_branch ticket/15-blocked && WHY+=("a branch was made")
}

case_stale_lock() {
  manifest
  mkdir -p "$WORK/locks"
  printf 'pid=999999\nstart=1\nwinpid=\nsince=then\nnonce=1\ncheckout=x\nbranch=other\n' >"$WORKTREE_LOCK"
  new --wait 5 "$CHECKOUT" 16 stale
  rc_is 0
  [[ "$ERRTEXT" == *"took the stale lock"* ]] || WHY+=("no stale lock line: $ERRTEXT")
}

case_cloud_policy() {
  printf 'cloud\n' >"$WORK/self"
  export MACHINE_SELF_FILE="$WORK/self"
  manifest
  new "$CHECKOUT" 17 policy
  rc_is 1
  [[ "$ERRTEXT" == *"repo.remote is not true"* ]] || WHY+=("a manifest without repo.remote was not refused: $ERRTEXT")
  manifest $'\tremote = true' '[copy]' $'\tfrom = '"$WORK/secrets" $'\tpath = .env'
  new "$CHECKOUT" 17 policy
  rc_is 1
  [[ "$ERRTEXT" == *"copy.path is set"* ]] || WHY+=("a manifest with copy.path was not refused: $ERRTEXT")
  manifest $'\tremote = true'
  new "$CHECKOUT" 17 policy
  rc_is 1
  [[ "$ERRTEXT" == *"no repo-local git user.name"* ]] || WHY+=("a checkout with no identity was not refused: $ERRTEXT")
  git -C "$CHECKOUT" config --local user.name t
  git -C "$CHECKOUT" config --local user.email t@example.invalid
  new "$CHECKOUT" 17 policy
  rc_is 0
}

# made <issue> <slug>: a worktree made by the tool, for the remove cases.
made() {
  manifest
  new "$CHECKOUT" "$1" "$2"
  [[ "$RC" == 0 ]] || WHY+=("could not make the worktree for $2: $ERRTEXT")
}

case_remove_keeps_branch() {
  made 20 keep
  GH_JSON='[]' remove "$WORK/src/demo-20-keep"
  rc_is 0
  [[ ! -e "$WORK/src/demo-20-keep" ]] || WHY+=("the worktree is still there")
  has_branch ticket/20-keep || WHY+=("the branch was deleted with no merged pull request")
  [[ "$OUT" == *"has no merged pull request"* ]] || WHY+=("no reason line: $OUT")
}

case_remove_with_word() {
  made 21 word
  remove --owner-word "go ahead" "$WORK/src/demo-21-word"
  rc_is 0
  has_branch ticket/21-word && WHY+=("the branch is still there")
  [[ "$OUT" == *"the owner's word: go ahead"* ]] || WHY+=("the word is not quoted: $OUT")
}

case_remove_merged() {
  made 22 merged
  local tip
  tip=$(git -C "$CHECKOUT" rev-parse "ticket/22-merged")
  GH_JSON='[{"number": 5, "headRefOid": "'"$tip"'", "isCrossRepository": false}]' remove "$WORK/src/demo-22-merged"
  rc_is 0
  has_branch ticket/22-merged && WHY+=("a branch with a merged pull request at its tip was kept: $OUT")
  made 23 moved
  GH_JSON='[{"number": 6, "headRefOid": "0000000000000000000000000000000000000001", "isCrossRepository": false}]' remove "$WORK/src/demo-23-moved"
  rc_is 0
  has_branch ticket/23-moved || WHY+=("a branch whose tip is not the merged commit was deleted")
  made 24 fork
  GH_JSON='[{"number": 7, "headRefOid": "0000000000000000000000000000000000000001", "isCrossRepository": true}]' remove "$WORK/src/demo-24-fork"
  has_branch ticket/24-fork || WHY+=("a branch with only a fork's pull request was deleted")
}

case_remove_refuses_main() {
  manifest
  remove "$CHECKOUT"
  rc_is 1
  [[ "$ERRTEXT" == *"main checkout"* ]] || WHY+=("no main checkout line: $ERRTEXT")
  [[ -d "$CHECKOUT/.git" ]] || WHY+=("the main checkout is gone")
}

cases_run
