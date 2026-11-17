#!/usr/bin/env bash
# prose-check.sh <file>...
# prose-check.sh --comments <file>...   (the comments mode, described after the rules below)
# Fails when any named file holds an em dash (U+2014), an en dash (U+2013) or a control
# character other than tab, line feed and carriage return (U+0001 to U+0008, U+000B, U+000C,
# U+000E to U+001F and U+007F). A lost backslash leaves one of these in text, for example a
# BEL or a backspace. A file with a NUL byte counts as binary and is skipped, as before.
# It also fails when a file whose name ends in .md (any case) holds a semicolon outside code.
# A dash hit prints path:line: em or en dash. Write two sentences, or use a comma.
# A control hit prints path:line: control character U+0007. Remove it, a lost backslash often leaves one.
# A semicolon hit prints path:line: semicolon. Write two sentences, or use a comma.
# A line with several of these gives a line for each kind, a code is named once per line, and a line with
# two semicolons gives one semicolon line. The dash and control lines come first, then the semicolon lines.
# Exit 0 and one "ok" line when no file holds any, 1 on any hit, 2 on a usage
# error (no argument, or a named file that does not exist) or when a read fails.
# The dashes are built from their UTF-8 bytes, so this file carries neither.
# The semicolon rules are:
#   Which files: only names ending in .md. A YAML or shell file carries code, so it gets the dash and control checks only.
#   Code, where a semicolon is no hit:
#     A fenced block. A line whose first non-blank characters are three or more backticks or three or more tildes opens it,
#     with any text after them. A line of the same character, at least as long and followed by blanks only, closes it.
#     A fence is code also inside a list. A fence that never closes runs to the end of its file only, and warns on stderr.
#     An inline code span: a run of n backticks up to the next run of exactly n backticks on the same line.
#     A backtick run with no closing run on its line is plain text, so a semicolon after it is a hit.
#   Not code: an indented block with no fence, since list items are indented.
#   Not a hit: an HTML entity, &name; or &#digits; or &#xhex;.
#   Not read: backslash escapes, and a fence behind a quote mark (> ```). A line that opens with a fence and
#   closes it with backticks on the same line, for example ```x```, is read as an opening fence.
# One grep reads every file at once and finds the dash and control hits. -I skips binary files, -Z puts
# a NUL after each path so a colon in a path (a drive letter, say) does not split it, and LC_ALL=C keeps
# the match to bytes. Only the hit lines are then read, with bash built-ins and no further process.
# One awk reads every .md file at once for semicolons. It opens the files itself from BEGIN and never reads its operands as
# input, so a path starting with a dash or holding an equals sign is not taken for an option or an assignment.
# It skips a file with a NUL byte, as grep -I does. Both reads finish before any line is printed.
# The awk reads bytes as they are (BINMODE=1, which only gawk reads), and the script itself drops a UTF-8 byte order mark
# from line 1 and a carriage return from the end of each line, so a fence opens and closes the same on any awk and any mount.
#
# The comments mode:
#   prose-check.sh --comments <file>... reads only the comments of .js, .cjs, .mjs, .css and .html files (any case of the suffix) for a semicolon and a US spelling, and ignores the code for those two.
#   It also makes the dash and control checks of the plain run over the whole of each file, code and comments, exactly as a plain run makes them, and their lines come first.
#   The comments are // to the end of the line (JavaScript only), /* */ across lines (JavaScript and CSS) and <!-- --> across lines (HTML).
#   In an HTML file a <script> block is read by the JavaScript rules and a <style> block by the CSS rules, up to its closing tag. Every <script> block is read as
#   JavaScript, whatever its type. In that block, as a browser reads a script, <!-- (outside a string, a regular expression and a comment) starts a comment that runs to the end
#   of the line, and --> at the start of a line (blanks before it allowed) is a comment too. So the old way of hiding a script from a browser that knew no script is read,
#   and a semicolon in it is a hit. In a .js file and in a <style> block they are no comment. Any other suffix, a missing file or no file is a usage error, exit 2, and nothing is read. The mode makes no other check. The first argument must be --comments, and anywhere else it is taken for a file name as before.
#   A hit prints path:line: semicolon in a comment, or path:line: US spelling "<word>", write "<British>" for a word of the list prose-check.us-words beside this script.
#   The list has one "us british" pair per line, and a blank line or a line starting with # is skipped. A word matches whole and in any case. A word is a run of letters, digits,
#   underscore and hyphen, so colorful, backgroundColor, text_color and border-color are no hit, since they are code names that are correct as written. The British word takes the
#   case of the one found (Color gives Colour, COLOR gives COLOUR). A line gives its semicolon hit once and each US word once. A semicolon counts anywhere in a comment, also in a
#   code span or an entity. Exit 0 and one ok line when no file has a hit of any kind, 1 on any hit, 2 on a usage error or when the list cannot be read.
#   Not a comment: // or /* inside a string in single quotes, double quotes or backticks (also inside a ${ } of a template), inside a regular expression literal, and :// in a URL.
#   A regular expression literal is told from a division by the last token before the slash: it is a division after ) ] } a name or a number, and a regular expression
#   after anything else or after one of the words return, typeof, instanceof, in, of, new, delete, void, throw, case, do, else, yield and await.
#   The forms it cannot tell, and gets wrong, are a regular expression after ) or } (if (x) /"/.test(s)), which is read as a division so a quote in it opens a string,
#   and a division after ++ or -- (a++ / 2), which is read as the start of a regular expression. Either one hides the rest of its line from the scan (a string or a regular
#   expression ends with its line) and case cm_rx_limit of the test shows it. A regular expression, like a string, ends at the end of its line. A template literal and a block comment run over lines.
#   The scan is one awk over all the files, in the style of the semicolon check above (bytes as they are, a carriage return dropped from the end of each line, a file with a NUL byte skipped).
#   A byte order mark needs no handling here, since nothing in the scan is anchored to the start of a line.

set -u
LC_ALL=C

EM=$(printf '\xe2\x80\x94')
EN=$(printf '\xe2\x80\x93')
CTRL=$'[\001-\010\013\014\016-\037\177]'

# char_hits <file>: reads the output of the grep for the dashes and the control characters (a path, a NUL, then line:text) and prints one line for each dash and each
# control code of each line, as the plain run does. The plain run and the comments mode both call it.
char_hits() {
  local path rest line text seen only i ch code
  while IFS= read -r -d '' path && IFS= read -r rest; do
    line=${rest%%:*}
    text=${rest#*:}
    if [[ $text == *"$EM"* || $text == *"$EN"* ]]; then
      echo "$path:$line: em or en dash. Write two sentences, or use a comma."
    fi
    seen=
    only=${text//[^[:cntrl:]]/}
    for ((i = 0; i < ${#only}; i++)); do
      ch=${only:i:1}
      if [[ $ch == $'\t' || $ch == $'\r' ]]; then
        continue
      fi
      printf -v code 'U+%04X' "'$ch"
      if [[ $seen != *"$code"* ]]; then
        seen+=" $code"
        echo "$path:$line: control character $code. Remove it, a lost backslash often leaves one."
      fi
    done
  done <"$1"
}

# comments_mode <file>...: the whole of the comments mode, which exits and never returns.
comments_mode() {
  local list f bad=0 rc=0 chars=0 charhits
  list=$(dirname "${BASH_SOURCE[0]}")/prose-check.us-words
  if (($# == 0)); then
    echo "usage: prose-check.sh --comments <file>..." >&2
    exit 2
  fi
  for f in "$@"; do
    if [[ ! -f $f ]]; then
      echo "prose-check.sh: no such file: $f" >&2
      bad=1
    else
      case ${f,,} in
        *.js | *.cjs | *.mjs | *.css | *.html) ;;
        *)
          echo "prose-check.sh: --comments reads only .js, .cjs, .mjs, .css and .html files, not: $f" >&2
          bad=1
          ;;
      esac
    fi
  done
  if ((bad)); then
    exit 2
  fi
  if [[ ! -r $list ]]; then
    echo "prose-check.sh: cannot read the word list $list" >&2
    exit 2
  fi
  # The dash and control checks of the plain run, over the whole of each file, code and comments, and their lines come first.
  charhits=$(mktemp)
  trap 'rm -f "${charhits:?}"' EXIT
  LC_ALL=C grep -H -I -Z -n -e "$EM" -e "$EN" -e "$CTRL" -- "$@" >"${charhits:?}" || chars=$?
  if ((chars > 1)); then
    echo "prose-check.sh: grep could not read every file (exit $chars)" >&2
    exit 2
  fi
  if ((chars == 0)); then
    char_hits "$charhits"
  fi
  LC_ALL=C awk -v BINMODE=1 '
# Updates the last token seen in code from t, the code since the last stop: lastch is its last character and lastword the name it ends in.
function tokens(t) {
  sub(/[ \t]+$/, "", t)
  if (t == "") return
  lastch = substr(t, length(t), 1)
  lastword = ""
  if (lastch ~ /[A-Za-z0-9_$]/) {
    match(t, /[A-Za-z0-9_$]+$/)
    lastword = substr(t, RSTART)
  }
}

# Whether a slash in code starts a regular expression, by the last token before it.
function regex_ok() {
  if (lastch == "") return 1
  if (lastch == ")" || lastch == "]" || lastch == "}") return 0
  if (lastch ~ /[A-Za-z0-9_$]/) return (lastword in iskw)
  return 1
}

function hit(msg) {
  found = found path ":" n ": " msg "\n"
}

# The British word br in the case of the US word tok that was found.
function fit(tok, br) {
  if (length(tok) > 1 && tok == toupper(tok)) return toupper(br)
  if (substr(tok, 1, 1) ~ /[A-Z]/) return toupper(substr(br, 1, 1)) substr(br, 2)
  return br
}

# The text of a comment on line n, without its delimiters.
function comment(t,    u, tok, lo) {
  if (index(t, ";") > 0 && semil != n) {
    semil = n
    hit("semicolon in a comment")
  }
  u = t
  while (match(u, /[A-Za-z0-9_-]+/)) {
    tok = substr(u, RSTART, RLENGTH)
    u = substr(u, RSTART + RLENGTH)
    lo = tolower(tok)
    if ((lo in us) && !((n SUBSEP lo) in seen)) {
      seen[n SUBSEP lo] = 1
      hit("US spelling \"" tok "\", write \"" fit(tok, us[lo]) "\"")
    }
  }
}

# The position of the tag name (as <script) in the lower-case text low, when a space, > or / or the end of the line follows it, else 0.
function tagpos(low, name,    off, q, ch) {
  off = 0
  while ((q = index(substr(low, off + 1), name)) > 0) {
    ch = substr(low, off + q + length(name), 1)
    if (ch == "" || ch ~ /[ \t>\/]/) return off + q
    off += q
  }
  return 0
}

# Scans s, the rest of a line, as JavaScript or CSS (lang) from the state st. Strings, regular expressions, template literals and block comments carry their state to the next line.
function body(s,    p, c, nx) {
  while (s != "") {
    if (st == "block") {
      p = index(s, "*/")
      if (p == 0) {
        comment(s)
        return
      }
      comment(substr(s, 1, p - 1))
      s = substr(s, p + 2)
      st = "code"
    } else if (st == "sq" || st == "dq") {
      p = match(s, st == "sq" ? RE_SQ : RE_DQ)
      if (p == 0) return
      c = substr(s, p, 1)
      if (c == "\\") {
        if (p == length(s)) cont = 1
        s = substr(s, p + 2)
      } else {
        st = "code"
        lastch = "a"
        lastword = ""
        s = substr(s, p + 1)
      }
    } else if (st == "tpl") {
      p = match(s, RE_TPL)
      if (p == 0) return
      c = substr(s, p, 1)
      if (c == "\\") {
        s = substr(s, p + 2)
      } else if (c == "`") {
        st = "code"
        lastch = "a"
        lastword = ""
        s = substr(s, p + 1)
      } else if (substr(s, p + 1, 1) == "{") {
        tb[++tn] = 0
        st = "code"
        lastch = "("
        lastword = ""
        s = substr(s, p + 2)
      } else {
        s = substr(s, p + 1)
      }
    } else if (st == "rx") {
      p = match(s, /[\\\[\/]/)
      if (p == 0) return
      c = substr(s, p, 1)
      if (c == "\\") {
        s = substr(s, p + 2)
      } else if (c == "[") {
        st = "rxc"
        s = substr(s, p + 1)
      } else {
        st = "code"
        lastch = "a"
        lastword = ""
        s = substr(s, p + 1)
      }
    } else if (st == "rxc") {
      p = match(s, /[\\\]]/)
      if (p == 0) return
      c = substr(s, p, 1)
      if (c == "\\") {
        s = substr(s, p + 2)
      } else {
        st = "rx"
        s = substr(s, p + 1)
      }
    } else {
      p = match(s, lang == "js" ? (embedded ? RE_JSE : RE_JS) : RE_CSS)
      if (p == 0) {
        tokens(s)
        return
      }
      tokens(substr(s, 1, p - 1))
      c = substr(s, p, 1)
      s = substr(s, p + 1)
      if (c == "\047") {
        st = "sq"
      } else if (c == "\"") {
        st = "dq"
      } else if (c == "`") {
        st = "tpl"
      } else if (c == "<") {
        if (substr(s, 1, 3) == "!--") {
          comment(substr(s, 4))
          s = ""
        } else {
          lastch = "<"
          lastword = ""
        }
      } else if (c == "{") {
        if (tn > 0) tb[tn]++
        lastch = "{"
        lastword = ""
      } else if (c == "}") {
        if (tn > 0 && tb[tn] == 0) {
          tn--
          st = "tpl"
        } else {
          if (tn > 0) tb[tn]--
          lastch = "}"
          lastword = ""
        }
      } else {
        nx = substr(s, 1, 1)
        if (nx == "/" && lang == "js") {
          comment(substr(s, 2))
          s = ""
        } else if (nx == "*") {
          st = "block"
          s = substr(s, 2)
        } else if (lang == "js" && regex_ok()) {
          st = "rx"
        } else {
          lastch = "/"
          lastword = ""
        }
      }
    }
  }
}

# Scans one line. In an HTML file the text between tags is looked at only for a comment, a <script> or a <style>.
function scanline(s,    low, p1, p2, p3, p, kind, lim) {
  while (s != "") {
    if (st == "text") {
      low = tolower(s)
      p1 = index(low, "<!--")
      p2 = tagpos(low, "<script")
      p3 = tagpos(low, "<style")
      p = 0
      kind = ""
      if (p1 > 0) { p = p1; kind = "c" }
      if (p2 > 0 && (p == 0 || p2 < p)) { p = p2; kind = "tagjs" }
      if (p3 > 0 && (p == 0 || p3 < p)) { p = p3; kind = "tagcss" }
      if (p == 0) return
      if (kind == "c") {
        st = "hcomment"
        s = substr(s, p + 4)
      } else {
        st = kind
        s = substr(s, p + (kind == "tagjs" ? 7 : 6))
      }
    } else if (st == "hcomment") {
      p = index(s, "-->")
      if (p == 0) {
        comment(s)
        return
      }
      comment(substr(s, 1, p - 1))
      s = substr(s, p + 3)
      st = "text"
    } else if (st == "tagjs" || st == "tagcss") {
      p = index(s, ">")
      if (p == 0) return
      lang = (st == "tagjs") ? "js" : "css"
      closetag = (st == "tagjs") ? "</script" : "</style"
      embedded = 1
      st = "code"
      lastch = ""
      lastword = ""
      tn = 0
      s = substr(s, p + 1)
    } else {
      if (embedded) {
        lim = index(tolower(s), closetag)
        if (lim > 0) {
          body(substr(s, 1, lim - 1))
          embedded = 0
          st = "text"
          s = substr(s, lim + length(closetag))
          continue
        }
      }
      body(s)
      return
    }
  }
}

BEGIN {
  nul = sprintf("%c", 0)
  RE_SQ = "[\\\\\047]"
  RE_DQ = "[\\\\\"]"
  RE_TPL = "[\\\\`$]"
  RE_JS = "[\047\"`/{}]"
  RE_JSE = "[\047\"`/{}<]"
  RE_CSS = "[\047\"/]"
  split("return typeof instanceof in of new delete void throw case do else yield await", words, " ")
  for (k in words) iskw[words[k]] = 1
  listed = 0
  while ((r = getline entry < ARGV[1]) > 0) {
    sub(/\r$/, "", entry)
    if (entry == "" || entry ~ /^#/) continue
    split(entry, pair, " ")
    us[tolower(pair[1])] = pair[2]
    listed++
  }
  close(ARGV[1])
  if (r < 0 || listed == 0) {
    print "prose-check.sh: the word list " ARGV[1] " cannot be read or holds no word" > "/dev/stderr"
    exit 2
  }
  for (i = 2; i < ARGC; i++) {
    path = ARGV[i]
    ext = tolower(path)
    sub(/^.*\./, "", ext)
    lang = (ext == "css") ? "css" : "js"
    st = (ext == "html") ? "text" : "code"
    embedded = 0
    tn = 0
    lastch = ""
    lastword = ""
    semil = 0
    delete seen
    found = ""
    isbin = 0
    n = 0
    while ((r = getline raw < path) > 0) {
      n++
      sub(/\r$/, "", raw)
      if (index(raw, nul) > 0) {
        isbin = 1
        break
      }
      if (embedded && lang == "js" && st == "code" && raw ~ /^[ \t]*-->/ && index(tolower(raw), closetag) == 0) {
        sub(/^[ \t]*-->/, "", raw)
        comment(raw)
        continue
      }
      cont = 0
      scanline(raw)
      if ((st == "sq" || st == "dq") && !cont) {
        st = "code"
        lastch = "a"
        lastword = ""
      } else if (st == "rx" || st == "rxc") {
        st = "code"
        lastch = "a"
        lastword = ""
      }
    }
    close(path)
    if (isbin) continue
    if (found != "") failed = 1
    printf "%s", found
  }
  exit (failed ? 1 : 0)
}
' "$list" "$@" || rc=$?
  if ((rc > 1)); then
    echo "prose-check.sh: awk could not read every file (exit $rc)" >&2
    exit 2
  fi
  if ((rc == 0 && chars == 1)); then
    echo "ok: no em or en dash, control character, semicolon or US spelling in a comment in $# file(s)"
    exit 0
  fi
  exit 1
}

if [[ ${1:-} == --comments ]]; then
  shift
  comments_mode "$@"
fi

if (($# == 0)); then
  echo "usage: prose-check.sh <file>..." >&2
  exit 2
fi

missing=0
mds=()
for f in "$@"; do
  if [[ ! -f $f ]]; then
    echo "prose-check.sh: no such file: $f" >&2
    missing=1
  elif [[ ${f,,} == *.md ]]; then
    mds+=("$f")
  fi
done
if ((missing)); then
  exit 2
fi

hits=$(mktemp)
semis=$(mktemp)
trap 'rm -f "$hits" "$semis"' EXIT

rc=0
LC_ALL=C grep -H -I -Z -n -e "$EM" -e "$EN" -e "$CTRL" -- "$@" >"$hits" || rc=$?
if ((rc > 1)); then
  echo "prose-check.sh: grep could not read every file (exit $rc)" >&2
  exit 2
fi

src=0
if ((${#mds[@]} > 0)); then
  LC_ALL=C awk -v BINMODE=1 '
# The text of s with its inline code spans cut out, a space left in the place of each.
function plain(s,    out, n, tail, rest) {
  out = ""
  while (match(s, /`+/)) {
    n = RLENGTH
    out = out substr(s, 1, RSTART - 1) " "
    rest = substr(s, RSTART + n)
    tail = rest
    while (match(tail, /`+/)) {
      if (RLENGTH == n) break
      tail = substr(tail, RSTART + RLENGTH)
    }
    if (RSTART > 0) {
      s = substr(tail, RSTART + RLENGTH)
    } else {
      s = rest
    }
  }
  return out s
}

# How many semicolons line holds outside code spans and entities.
function semis(line,    t) {
  if (index(line, ";") == 0) return 0
  t = plain(line)
  gsub(/&[A-Za-z][A-Za-z0-9]*;/, "", t)
  gsub(/&#[0-9]+;/, "", t)
  gsub(/&#[xX][0-9A-Fa-f]+;/, "", t)
  return gsub(/;/, ";", t)
}

# The length of the run of c that starts at the first non-blank character of line, or 0.
# FEND is left holding the number of characters up to the end of that run.
function fence_run(line, c,    len) {
  match(line, /^[ \t]*/)
  FEND = RLENGTH
  len = 0
  while (substr(line, FEND + 1, 1) == c) {
    len++
    FEND++
  }
  return len
}

BEGIN {
  nul = sprintf("%c", 0)
  for (i = 1; i < ARGC; i++) {
    path = ARGV[i]
    buf = ""
    binary = 0
    fchar = ""
    n = 0
    while ((r = getline line < path) > 0) {
      n++
      if (n == 1) sub(/^\357\273\277/, "", line)
      sub(/\r$/, "", line)
      if (index(line, nul) > 0) {
        binary = 1
        break
      }
      if (fchar != "") {
        if (fence_run(line, fchar) >= flen && substr(line, FEND + 1) ~ /^[ \t]*$/) fchar = ""
        continue
      }
      match(line, /^[ \t]*/)
      c = substr(line, RLENGTH + 1, 1)
      if ((c == "`" || c == "~") && fence_run(line, c) >= 3) {
        fchar = c
        flen = fence_run(line, c)
        opened = n
        continue
      }
      if (semis(line) > 0) buf = buf path ":" n ": semicolon. Write two sentences, or use a comma.\n"
    }
    close(path)
    if (binary) continue
    if (fchar != "") print "prose-check.sh: " path ":" opened ": fence is never closed, the rest of the file is read as code" > "/dev/stderr"
    if (buf != "") any = 1
    printf "%s", buf
  }
  exit (any ? 1 : 0)
}
' "${mds[@]}" >"$semis" || src=$?
  if ((src > 1)); then
    echo "prose-check.sh: awk could not read every file (exit $src)" >&2
    exit 2
  fi
fi

if ((rc == 1 && src == 0)); then
  echo "ok: no em or en dash, semicolon or control character in $# file(s)"
  exit 0
fi

if ((rc == 0)); then
  char_hits "$hits"
fi
cat "$semis"
exit 1
