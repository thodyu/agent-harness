#!/usr/bin/env bash
# mutant.sh <script> <old> <new> <out>
# Makes a broken copy of a script, to prove that a test can fail. For a folder that is not a git tree.
# Copies <script> to <out> with the one occurrence of <old> replaced by <new>.
# Both are plain text, never a pattern. A . * [ \ & / $ in either is taken as itself.
# <old> may span lines when the caller passes a newline in it, for example $'a\nb' from bash.
# It is matched against the whole file, so a CRLF file needs the CR in <old> too. <new> may be empty, which deletes <old>.
# Occurrences are counted over the whole file and may overlap, so aa in aaa counts as 2.
# The copy keeps every other byte, line endings and a missing final newline included, and the executable bit when <script> has one.
# Output: on success one line "mutant: <out> (line <n>)", where n is the line the replacement starts on.
# On failure nothing is written and one line goes to stderr.
# Exit 0 on success. Exit 1 on a wrong argument count, an empty <old>, <old> equal to <new>,
# an unreadable <script> (or one holding a NUL byte), <out> the same file as <script>, <out> already there,
# <old> occurring zero times or more than once (the message names the count), or a failed write.
# A copy that would not differ is an error, so a no-op copy can never show green.
# It starts no process on success except chmod, and only when <script> is executable. The failure paths that remove <out> start rm.
# The file is read and searched with bash built-ins.
# If the write or the chmod fails after <out> was made, <out> is removed again.
# The chmod is unproven on the machine this was written on. Git Bash shows an executable bit only for a file that starts with #!
# or ends in .exe, so no test there can tell a copy with the chmod from one without it. A test run elsewhere could.
# Example: bash bin/mutant.sh bin/slots.sh '-ge "$FLOOR_MB"' '-gt "$FLOOR_MB"' "$T/gt.sh"

LC_ALL=C

fail() {
  echo "mutant: $1" >&2
  exit 1
}

[ "$#" -eq 4 ] || fail "usage: mutant.sh <script> <old> <new> <out>"
script=$1
old=$2
new=$3
out=$4

[ -n "$old" ] || fail "<old> is empty"
[ "$old" != "$new" ] || fail "<old> and <new> are the same, so the copy would not differ"
[ -f "$script" ] && [ -r "$script" ] || fail "cannot read $script"
[ ! "$out" -ef "$script" ] || fail "<out> is the same file as <script>"
[ ! -e "$out" ] && [ ! -L "$out" ] || fail "$out already exists and is never overwritten"

# The open is its own step because test -r can say yes for a file that cannot be opened (an ACL deny).
{ exec 3<"$script"; } 2>/dev/null || fail "cannot read $script"
# read -d '' ends at a NUL byte and then returns 0. Reaching the end of the file without one returns 1.
if IFS= read -r -d '' content <&3; then
  fail "$script holds a NUL byte, which a bash variable cannot keep"
fi
exec 3<&-

rest=$content
count=0
while [[ $rest == *"$old"* ]]; do
  before=${rest%%"$old"*}
  count=$((count + 1))
  rest=${rest:${#before}+1}
done
[ "$count" -eq 1 ] || fail "the text occurs $count times in $script, not exactly once"

before=${content%%"$old"*}
lines=${before//[!$'\n']/}
result=$before$new${content:${#before}+${#old}}

# noclobber makes the open fail rather than replace a file that appeared since the check above.
# Once the open has worked <out> is ours, so a later failure removes it.
{
  set -C
  exec 4>"$out"
} 2>/dev/null || fail "cannot write $out"
set +C
if ! printf '%s' "$result" >&4 2>/dev/null; then
  rm -f "$out"
  fail "cannot write $out"
fi
exec 4>&-
if [ -x "$script" ] && ! chmod +x "$out" 2>/dev/null; then
  rm -f "$out"
  fail "cannot make $out executable"
fi
echo "mutant: $out (line $((${#lines} + 1)))"
exit 0
