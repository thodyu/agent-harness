#!/usr/bin/env bash
# state-check.sh <file>
# Checks the shape of an orchestrator's state file (docs/how-it-works.md, "The state file").
# Three rules, one output line for each break, naming the rule:
#   headings    the "## " headings hold Where things stand, Threads, Open for the owner,
#               Recurring problems, Next move and Updates, each once and in that order,
#               and Updates is the last. A "## Hand-over..." heading is optional and sits
#               between Next move and Updates. Other "## " headings may sit before Updates.
#   size        the body (every byte before the "## Updates" line) and the Updates (that
#               line to the end) are each under 25600 bytes
#   stale text  no "once it exists", any case, in the body. Updates are history
# Exit 0 and no output when every rule holds, 1 when any is broken, 2 on a usage error
# or an unreadable file. Reads with bash built-ins only and starts no process.
# A code fence opens at a line starting with three backticks or three tildes and closes
# at the next line starting with the same three. A "## " line inside one is not a heading.
# Its bytes still count, and "once it exists" in it is still stale.

if [[ $# -ne 1 || ! -f $1 || ! -r $1 ]]; then
  echo "usage: state-check.sh <file>" >&2
  exit 2
fi

export LC_ALL=C
file=$1
cap=25600
required=("Where things stand" "Threads" "Open for the owner" "Recurring problems" "Next move" "Updates")
updates=5
next_move=4

count=("${required[@]/*/0}")
first=("${required[@]/*/0}")
where=("${required[@]/*/}")
hand_over=()
heading_names=()
heading_lines=()
body_bytes=0
updates_bytes=0
in_updates=0
fence=""
stale=()
lineno=0
status=0

while :; do
  if IFS= read -r line; then
    newline=1
  elif [[ -n $line ]]; then
    newline=0
  else
    break
  fi
  lineno=$((lineno + 1))
  bytes=$((${#line} + newline))

  if [[ $line == '```'* || $line == '~~~'* ]]; then
    mark=${line:0:3}
    if [[ -z $fence ]]; then
      fence=$mark
    elif [[ $fence == "$mark" ]]; then
      fence=""
    fi
  elif [[ -z $fence && $line == "## "* ]]; then
    name=${line#"## "}
    name=${name%"${name##*[![:space:]]}"}
    heading_names+=("$name")
    heading_lines+=("$lineno")
    for k in "${!required[@]}"; do
      if [[ $name == "${required[k]}" ]]; then
        count[k]=$((count[k] + 1))
        ((first[k] == 0)) && first[k]=$lineno
        where[k]+="${where[k]:+, }$lineno"
        ((k == updates)) && in_updates=1
      fi
    done
    [[ $name == Hand-over* ]] && hand_over+=("$lineno")
  fi

  if ((in_updates)); then
    updates_bytes=$((updates_bytes + bytes))
  else
    body_bytes=$((body_bytes + bytes))
    lower=${line,,}
    [[ $lower == *"once it exists"* ]] && stale+=("$lineno")
  fi
done <"$file"

# Headings: missing, duplicated.
for k in "${!required[@]}"; do
  if ((count[k] == 0)); then
    echo "headings: '## ${required[k]}' is missing"
    status=1
  elif ((count[k] > 1)); then
    echo "headings: '## ${required[k]}' appears ${count[k]} times, at lines ${where[k]}"
    status=1
  fi
done

# Headings: out of order. Each heading is compared with the one before it in the
# required order, so one displaced heading gives one line.
prev_line=0
prev_name=""
for k in "${!required[@]}"; do
  ((first[k] > 0)) || continue
  if ((first[k] < prev_line)); then
    echo "headings: '## ${required[k]}' at line ${first[k]} is out of order, it comes before '## $prev_name' at line $prev_line"
    status=1
  fi
  prev_line=${first[k]}
  prev_name=${required[k]}
done

# Headings: nothing may follow Updates, and Hand-over sits after Next move.
for h in "${!heading_names[@]}"; do
  name=${heading_names[h]}
  n=${heading_lines[h]}
  if ((first[updates] > 0 && n > first[updates])) && [[ $name != "Updates" ]]; then
    echo "headings: '## $name' at line $n comes after '## Updates', which must be the last heading"
    status=1
  fi
done
for n in "${hand_over[@]}"; do
  if ((first[next_move] > 0 && n < first[next_move])); then
    echo "headings: the Hand-over heading at line $n comes before '## Next move' at line ${first[next_move]}, it must sit between Next move and Updates"
    status=1
  fi
done

# Size.
if ((body_bytes >= cap)); then
  echo "size: the body is $body_bytes bytes, it must be under $cap"
  status=1
fi
if ((updates_bytes >= cap)); then
  echo "size: the Updates are $updates_bytes bytes, they must be under $cap"
  status=1
fi

# Stale text.
for n in "${stale[@]}"; do
  echo "stale text: line $n of the body says \"once it exists\""
  status=1
done

exit "$status"
