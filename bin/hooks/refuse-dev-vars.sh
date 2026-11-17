#!/usr/bin/env bash
# Only a deliberate refusal exits 2. Any other end, a syntax error or a crash
# included, exits 0 and lets the call run.
trap '[[ "${HOOK_REFUSED:-}" == 1 ]] && exit 2; exit 0' EXIT
#
# PreToolUse hook for the Read, Write and Edit tools. Refuses a file_path whose
# last part is .dev.vars or starts with .dev.vars. (.dev.vars.local and the
# like), except .dev.vars.example. A .dev.vars file holds secrets, and the
# harness echoes a file it reads or writes back into the transcript.
#
# The name is matched in lower case, so .DEV.VARS is refused. Either slash style
# works, a path in quotes works, trailing spaces and an NTFS stream suffix
# (.dev.vars:name) are ignored, and the folder does not matter. The hook never
# looks at the file or at the tool, only at the name.
#
# Not seen: a short 8.3 name, a link to the file, and a payload whose file_path
# comes after its first 16 KB. The harness writes file_path first in tool_input,
# and the hook reads only the first 16 KB, as check-state-file.sh does, because
# bash reads about 10 microseconds a byte and a Write can hold a megabyte. A
# call that fills the 16 KB with no file_path in it passes with one line on
# standard error that says the name was not checked. The command hooks refuse
# cat, head, tail, less, more, type, Get-Content, gc and bat on the same name
# (refuse-dev-vars-print.sh). Test: test-dev-vars.sh beside this file.

input=""
IFS= read -r -N 16384 input
if [[ ! "$input" =~ \"file_path\"[[:space:]]*:[[:space:]]*\"(([^\"\\]|\\.)*)\" ]]; then
  # A full read with no file_path in it is the gap named above, so say so.
  (( ${#input} < 16384 )) || echo "refuse-dev-vars.sh: the payload is longer than 16 KB and file_path is not in the first 16 KB, so the name was not checked." >&2
  exit 0
fi
# The JSON string value of file_path. An escaped quote means the path was in
# quotes. Every backslash, doubled in JSON or not, is a separator.
file="${BASH_REMATCH[1]//\\\"/}"
file="${file//[\"\']/}"
file="${file//\\//}"

name="${file##*/}"
name="${name,,}"
name="${name%%:*}"
while [[ "$name" == *" " ]]; do name="${name% }"; done

[[ "$name" == .dev.vars || ( "$name" == .dev.vars.* && "$name" != .dev.vars.example ) ]] || exit 0

printf '%s\n' \
  "Refused: ${file##*/} is a .dev.vars file, which holds secrets. Read, Write and Edit are refused on it, because the harness echoes the file into the transcript." \
  "A human copies .dev.vars.example to .dev.vars and types the keys. Make or change .dev.vars.example instead, with placeholders and no real values." \
  "A check reads a key by name and shape only, for example:" \
  "  grep -c '^EXAMPLE_API_KEY=abc_' .dev.vars" >&2
HOOK_REFUSED=1
exit 2
