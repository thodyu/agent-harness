#!/usr/bin/env bash
# run-long.sh start --name <name> [--floor <GB>] [--wait-max <seconds>] -- <command> [args...]
# run-long.sh run --name <name> [--floor <GB>] [--wait-max <seconds>] [--limit <seconds>] -- <command> [args...]
# run-long.sh wait --name <name>
# run-long.sh status --name <name>
# Runs one long command so that it outlives the shell that started it, under a name, with a log of its own and a last line that says how it ended.
# <name> is the caller's own Herdr name, for example a1-runlong. It holds letters, digits and hyphens only.
# What this guards:
#   1. The floor before a start. start reads free memory first and starts nothing under the floor, so a long run never begins on a machine that is already short.
#   2. One run per name. A second start under a name whose run is alive, or whose start is waiting for memory, is refused, so nobody starts a second copy of a run that is still going.
#      The runner also checks that the lock still names its own start, before it runs the command and before it touches the lock or the record, so a slow runner whose start was replaced runs nothing.
#   3. The run outliving its shell. The command runs apart from the shell that called start, so a stopped shell does not stop it.
#      The test proves the detach by one check only: the runner is not a child of the start process. A plain background job also survives the kill the test uses,
#      so the survival half of that test would pass without the detach and proves only that the run, the end line and the code are right afterwards.
#   4. The end line. The last line of the log is "run-long: end exit <code> <ISO time>", so a lost completion notice does not lose the result. wait gives the code again.
# What it does not guard: memory that falls after the start (the floor is read once, before the command begins),
# and any run started without it. A command that starts its own background children is not waited for, and their later output follows the end line.
# start:
#   Checks the name, the flags and the lock, and reads free memory, before anything is made. A failure there prints one line and makes no log.
#   Then it makes the log with mktemp and prints "run-long: log <path>" as its first line, before any wait for memory.
#   Under the floor it prints one line with the free memory and the floor, then reads again every RUN_LONG_INTERVAL seconds, holding no lock.
#   While it waits it keeps a waiting record, the folder <locks>/run-long-<name>.waiting/ with an info file (the start's ids and the log path). The record is never the lock.
#   It goes when the start takes the lock or gives up. status shows it as waiting for memory with that log, and a second start under the name is refused (75) as it is while a run is alive.
#   When --wait-max seconds pass with memory still under the floor it gives up, with a line naming the last value and the floor (on stderr, and as the "refused" line on stdout). It starts nothing, removes the log and keeps the record of the give-up.
#   Past the floor it takes the lock, starts the command detached, and waits for the end of the run. It exits with the command's own code, so the Bash tool's completion notice carries it.
#   Run it with run_in_background. If that shell is stopped the run goes on, and "wait --name <name>" gives the code. Never start a second copy.
#   That holds once the lock is taken. A caller whose shell is stopped during the wait for memory must start again, since nothing ran: the start was stopped with the shell, and status says no run (or, after kill -9, that the waiting start is gone).
# wait: gives the code from the end of the current run under the name, or of the last run if none is going. It returns at once when the run has ended.
#   While a start is waiting for memory, wait waits for that start's own run and never gives the previous run's code. If that start gives up, wait says so and exits 76.
# status: prints one line and the log path: waiting for memory, running (with the process ids), ended with a code, stopped without an end line, refused, or no run.
# Neither wait nor status starts anything. They print one line each, to stdout. The one exception is wait for a run that has ended, which follows its line with the tail below.
# The tail (wait for an ended run, and run at its end): the line "run-long: last <n> lines of the log:" and then the last lines of the command's own output, as they are, <n> of them.
#   The end line is not one of them (it is printed apart). At most 15 lines, and at most 4000 bytes with a newline counted for each, the oldest lines dropped first.
#   A line over 300 bytes is cut at 300 (not inside a UTF-8 character) and ends with " [cut, <its size> bytes]". A log with no output of the command prints neither the header nor a line.
#   Stated limit: tail -n reads back through a log whose last line has no newline for megabytes, so one huge line costs time and memory before the cut. status gets no tail, and neither does start.
# A give-up under a name (exit 76 of start or run) is kept as a record, so a later wait or status says it. They then print "run-long: <name> refused at <ISO time>, <the reason>", exit 76,
#   and never give the code or the log of a run before it, until a run under the name takes the lock. A live run, a waiting start or a waiting start that is gone are still read first.
#   A refusal for a live run (75) keeps no record, since that run's own result is the answer.
#   When the record cannot be written or read back, the give-up still exits 76 and the earlier run's .last record is removed,
#   so wait and status say "no run" (exit 1) and never that run's code or log. The give-up's own line is on stderr and stdout as always.
#   Stated limit: a start that is between its checks and its wait for memory while another start takes the lock can give up after that run began. Its record is then read once that run has ended, in place of that run's result.
#   Stated limit: in that same window, when the record cannot be written, the removal of the earlier run's .last record deletes that run's real result, and wait and status then say "no run" (exit 1).
#   Stated limit: after two give-ups in a row where the second record cannot be written, wait and status say the first give-up, with the first one's time.
#   Stated limit: when a folder stands where the record goes, every later run prints the error line of rm on stderr as it takes the lock, and the folder stays. The run itself is right.
# Flags: --floor is the free memory floor in GB, a whole number or one decimal place (default 1.5), as slots.sh has it. --wait-max is whole seconds (default 7200).
# The lock is the folder <locks>/run-long-<name>/, made with mkdir so the take is atomic. Its files, one value each:
#   owner      the process id and second id of the process that holds the lock (the runner once it is up)
#   starter    the id of the start process that made it
#   log        the log path
#   cmdline    the command line, quoted so a shell could run it again
#   started    the ISO time of the start
#   pid        the process id and second id of the process that runs the command, written once it is up and its second id has settled
#   group      run only: the process group of its command and the second id of the group's leader (timeout), read once that id has settled as pid's is (- until then). The lock is alive while a process of the group lives
# The second id is the process's start time (field 22 of /proc/<pid>/stat) on Linux, and its Windows id under Git Bash, where a process gets a new Windows id when it execs the command,
# so status and the refusal line read that id live from /proc, and pid is the record. A live id with another second id is a reused id, and its lock is stale.
# To stop a run, use kill <id> (the end line then says 143), or under Git Bash taskkill /PID <Windows id> /T from status to stop the tree. Never stop a process by name.
# A lock whose owner is gone, or whose id now belongs to a process with another second id, is stale, and the next start takes it over with one line saying so.
# A lock with no owner file that is under 30 seconds old is taken as one being made.
# When the end line is written the lock folder is removed, after the record of the run is written to <locks>/run-long-<name>.last
# (a log= line and a code= line). wait and status read that record. The next run under the name replaces it when it ends.
# The end line is written after the command ends, on a line of its own, and nothing else in the log starts "run-long: end".
# A command stopped by a signal (kill <pid> gives 143, kill -9 <pid> gives 137) ends with that status above 128, and that is the code. A command that is not found gives 127.
# Stated limit: under Git Bash a command ended with taskkill /F can show exit 0, because Git Bash reports it so. Its end line then says exit 0 and start exits 0.
# So a caller reads the test's own counts line in the log ("passed N failed M") as well as the end line, and does not take exit 0 alone for a pass.
# If taskkill /F takes the runner as well, no end line is ever written. status and wait then say "stopped without an end line" and exit 77, and never hang or give 0.
# Files written: the log (a mktemp file in TMPDIR, its path made absolute when TMPDIR is relative, a path that starts with a drive letter and a slash counting as absolute), the lock folder, the .last record, the .refused record (a time= line and a reason= line, written at a give-up and removed when a run takes the lock), the .waiting folder while a start waits for memory, and a <lock>.takeover folder for the moment of a takeover.
# The log path is printed in the form cygpath -m gives (C:/...) under Git Bash, which Git Bash and the Windows tools both read, and as it is on Linux.
# Exit codes:
#   start   the command's own code (0 to 255), once the run has ended
#           1 usage error, unreadable or figureless meminfo, unreadable CPU count on the machine itself, mktemp or lock failure
#           75 refused, because a run under the name is alive
#           76 --wait-max passed with memory still under the floor, nothing started
#           77 the run is lost, because its process went without an end line or the runner did not start
#   run     the command's own code (124 or 137 when the limit killed it), 1 for a usage error, a --limit not above the wait, or an unreadable machine-self,
#           meminfo, loadavg or CPU count, 75 refused as start is, 76 when --wait-max passed with memory or load still shut, nothing started
#   wait    the command's own code, 1 for a usage error or no run, 76 when the start it waited for gave up or is gone, 77 for a lost run
#   status  0 for waiting, running or ended, 1 for a usage error or no run, 76 when the waiting start is gone, 77 for a lost run
#   A waiting record left by a start that is gone, with no give-up (a give-up removes the record), makes both say "waiting start is gone, it ran nothing", with 76. Any start under the name clears such a record once its refusals are past, and status ignores it while a lock is alive or a record of an ended run is newer than it.
#   Stated limit: a waiting start stopped with TERM removes its own record, so wait, which saw it waiting, then says it gave up waiting for memory (76) though it was stopped.
#   A command can exit with 1 or 75 to 77 itself. The line printed says which it was.
#   A refusal or give-up of start or run (75 and 76) prints its line on stderr and, as the last line on stdout, "run-long: refused (exit <75 or 76>): <the same words>".
#   So a caller that reads stdout only finds the reason and the figures. Exit 1 (usage, an unreadable file or count) and 77 stay on stderr only.
#   wait and status give 76 with the line "run-long: <name> refused at <ISO time>, <reason>" for a give-up, as they do for a waiting start that is gone.
# Environment (all for the test, except TMPDIR and ORCH_HOME):
#   ORCH_HOME             the root folder (default: the folder above this script's), whose locks folder holds the locks and records
#   RUN_LONG_LOCKS        the folder that holds the locks and records (default: $ORCH_HOME/locks)
#   RUN_LONG_MEMINFO      the file that holds the MemFree line, or the MemAvailable line on the machine itself (default /proc/meminfo)
#   RUN_LONG_INTERVAL     whole seconds between memory reads while waiting (default 30)
#   RUN_LONG_POLL         seconds between looks for the end of a run, may be a decimal (default 2)
#   RUN_LONG_LAUNCH_WAIT  whole seconds start waits for the runner to come up (default 30)
#   RUN_LONG_LOADAVG      the file that holds the load figure on the machine itself (default /proc/loadavg)
#   RUN_LONG_NPROC        the command that prints the CPU count on the machine itself, a name or a path, run with no arguments (default nproc)
#   RUN_LONG_SAMPLE       seconds between the memory reads of run's sampler, may be a decimal (default 2)
#   RUN_LONG_TEST_PAUSE   test only, off when unset: a path. run then writes its own id to <path>.at once its pid record is written, and waits there until <path> exists,
#                         so a test can land a TERM between the records and the wait every time, not by timing
#   MACHINE_SELF_FILE and MACHINES_CONF, read through machine-lib.sh
#   TMPDIR                the folder mktemp makes the log in
# Free memory is the MemFree line of /proc/meminfo, as slots.sh reads it, which tracks the free figure Windows reports under Git Bash.
# How the run is detached: start launches a second copy of this script (the runner) from a subshell that ends at once, with its input, output and error closed,
# so the runner has no parent shell to be stopped with. The runner ignores SIGHUP, runs the command, writes the end line and the record, and removes the lock.
# The first argument of that copy is the internal word __run, which a caller never uses.
#
# On Linux a process has no Windows id, so the second id of every record (owner, pid and the waiting record) is the process's start time, and the lines say "start <n>" where Git Bash's say "winpid <n>".
#   The runner records the command's ids at once, since the start time does not change at exec. The log path is printed as it is, since there is no cygpath.
#   A zombie (state Z, ended and not yet reaped by its parent) counts as gone, so a runner killed with kill -9 reads as lost and not as running.
#   Linux is told from Git Bash by /proc/<this process>/winpid, which only Git Bash has.
# The machine itself. Where the machine-self file (see machine-lib.sh) names a label, such as a cloud machine, start and run
#   read the MemAvailable line, the floor is that label's floor in machines.conf (--floor overrides it), and the 1-minute load, the first figure of
#   /proc/loadavg, must also be under the CPU count of the machine. That count is what nproc prints there (or the command named by RUN_LONG_NPROC),
#   read once per call, before anything is made, and every line then says "under <n>" with it. A command that fails, prints nothing, or prints anything but a whole
#   number of 1 or more (up to 9 digits, with spaces and a carriage return allowed at the ends) fails the call with one line naming the command and what it printed, exit 1, and nothing is started.
#   The wait and give-up lines then say "free <x.xx> GB available" and name the load when it is too high.
#   status and wait still say "waiting for memory" for a start that waits on the load, since orch-wake.sh reads that text.
#   Where there is no machine-self file (the control machine) none of this applies, and every line is as above. No CPU count is read there.
# run: the command runs in the caller's foreground and the call returns when it ends. It is for a run under 9 minutes, and start
#   with wait is for a longer one. run takes the same lock as start, so status, wait and orch-wake see it, and a start or run under a running name is refused (75).
#   It waits for memory and load itself, reading every RUN_LONG_INTERVAL seconds, so the caller needs no sleep. While it waits it keeps the waiting record, as start does.
#   When --wait-max seconds (default 120) pass with the gate still shut it prints one line with the last figures on stderr, the same words as the "refused" line on stdout, and exits 76, having started nothing.
#   A --limit that is not above the wait (--wait-max, or its default of 120) is refused before anything is read or made, with one line naming both, exit 1.
#   A run stopped while it waits (a TERM, or a meminfo or loadavg that can no longer be read) leaves no waiting record and no log, since it started nothing.
#   It prints nothing while it waits. Then it prints "run-long: started <ISO time>, <the figures>, limit <s> s, log <path>" and runs the command into that log,
#   a mktemp file, under timeout -s KILL, in a process group of its own (bash's set -m). The whole call, the wait included, ends within --limit seconds
#   (default 540): at the limit timeout kills the command, and run then kills every process left in the group, such as a child the command put in the
#   background. A process that leaves the group (setsid) is not reached. The recorded pid is timeout's, and timeout leads the group.
#   While the command runs a sampler reads the memory line every RUN_LONG_SAMPLE seconds (default 2). It is stopped by the id run recorded, and it stops
#   by itself once run is gone, a zombie run (killed and not yet reaped by its parent) counting as gone.
#   After a kill -9 of run the command goes on in its group. The lock stays alive while a process of the group lives (on Linux one that is not a zombie),
#   so a start or run under the name is refused (75), and status says running and that run is gone, so no end line will come. Once the group has ended,
#   status says stopped without an end line (77) and the next start takes the lock over. start's runner has no group of its own, so a kill -9 of the runner
#   leaves its command running under a lock that reads as stale.
#   At the end run writes the end line to the log as start's runner does, writes the record, removes the lock, and prints on stdout:
#     the end line, then "run-long: killed at the limit of <s> s" when the limit ended it. The code is then 124 or 137, with the time since the command
#     began at the limit: uutils timeout exits 124, GNU timeout kills its own group too and gives 137, and run's own KILL after a TERM gives 137,
#     the tail of the command's output (see the tail above), before the counts,
#     "run-long: counts (<kind>) <word> <n> ..." for each kind of count found in the log, summed when a kind comes more than once:
#       node, from the spec reporter's "ℹ <word> <n>" lines or the tap reporter's "# <word> <n>" lines: tests, pass, fail, cancelled, skipped and todo,
#       pytest, from its summary line: each word it gives, such as failed, passed and skipped,
#       cases.sh, from its "passed <n> failed <n>" line: passed and failed,
#     or "run-long: counts none found in the log",
#     "run-long: failed <name>" for each failed test, at most 20, then "run-long: failed and <n> more, see the log":
#       node spec, each test of its "failing tests:" list that comes after a "test at <place>" line, with that place,
#       node tap, each "not ok" line that is neither a suite (type: 'suite' in its block) nor a TODO,
#       pytest, each FAILED or ERROR line of its short summary, and cases.sh, each FAIL line,
#     "run-long: skipped <n>: <reason>" for each skip reason, the most common first, at most 10, then "run-long: skipped and <n> more reasons, see the log".
#       A skip with no reason is "(no reason given)". The reasons come from node spec "﹣ <name> (<time>) # <reason>", node tap "# SKIP <reason>",
#       pytest "SKIPPED [<n>] <place>: <reason>" (which pytest prints only with -rs) and cases.sh "PASS <name> (skipped: <reason>)",
#     and "run-long: lowest <x.xx> GB <available or free> at <HH:MM:SS>, sampled every <s> s", which misses a dip shorter than one step,
#       or "run-long: lowest not read, since <meminfo> could not be read" when neither the sampler nor the read at the end found a figure.
#   Failed names and skips are read only for a kind whose counts are in the log. It exits with the command's code.
#   A TERM, INT or HUP to run passes a TERM to the command's whole group, and the end line, the record and the summary follow as above, with the
#   command's code (143). The limit still holds: a timeout that is sent a TERM can drop its own deadline, so run sends KILL to the group at the deadline
#   itself, and a command that ignores the TERM ends there with 137 and the killed line. The pid record is the last one written before the wait, and a
#   TERM that lands after it and before the wait is acted on once the wait would begin. One gap is left: a TERM between that last read and the start of
#   the wait builtin (no process runs there) is acted on only when the command ends or at the limit, since bash's wait does not return for a trap that
#   ran just before it.
#   It writes the log, the lock folder, the record, the waiting record while it waits, and <log>.low for the sampler, which it removes at the end.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
ORCH_HOME="${ORCH_HOME:-$(cd "$HERE/.." && pwd)}"
LOCKS="${RUN_LONG_LOCKS:-$ORCH_HOME/locks}"
MEMINFO="${RUN_LONG_MEMINFO:-/proc/meminfo}"
INTERVAL="${RUN_LONG_INTERVAL:-30}"
POLL="${RUN_LONG_POLL:-2}"
LAUNCH_WAIT="${RUN_LONG_LAUNCH_WAIT:-30}"
LOADAVG="${RUN_LONG_LOADAVG:-/proc/loadavg}"
NPROC="${RUN_LONG_NPROC:-nproc}"
SAMPLE="${RUN_LONG_SAMPLE:-2}"
FLOOR_TENTHS=15
FLOOR_FLAG=""
LOAD_LIMIT=""
WAIT_MAX=7200
LIMIT=540
MEM_KEY=MemFree
UNIT=""
GATE_LOAD=0
ON_WIN=0
[ -r "/proc/$$/winpid" ] && ON_WIN=1
ID2_LABEL=start
[ "$ON_WIN" -eq 0 ] || ID2_LABEL=winpid
ID2=""
ID2_ZOMBIE=0
NAME=""
LOCKDIR=""
LASTFILE=""
REFUSEDFILE=""
REF_TIME=""
REF_REASON=""
WAITDIR=""
IN_WAIT=0
SKIP_WAIT=0
my_win=""
CMD=()
TMP_LOG=""
HELD=0
GROUP_ONLY=0

usage() {
  echo "usage: run-long.sh start --name <name> [--floor <GB>] [--wait-max <seconds>] -- <command> [args...] | run --name <name> [--floor <GB>] [--wait-max <seconds>] [--limit <seconds>] -- <command> [args...] | wait --name <name> | status --name <name>" >&2
  exit 1
}

fail() {
  echo "run-long: $1" >&2
  exit "${2:-1}"
}

# fail_refused <message> <code>: a refusal or give-up of start or run (75 or 76). The line goes to stderr as fail prints it, and to stdout as the last line,
# "run-long: refused (exit <code>): <message>", so a caller that reads stdout only sees it too.
fail_refused() {
  echo "run-long: $1" >&2
  echo "run-long: refused (exit $2): $1"
  exit "$2"
}

whole_number() {
  [[ $1 =~ ^[0-9]+$ ]]
}

[[ $INTERVAL =~ ^[0-9]+$ ]] && [ "$INTERVAL" -ge 1 ] || fail "RUN_LONG_INTERVAL must be whole seconds, 1 or more"
[[ $POLL =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "RUN_LONG_POLL must be a number of seconds"
whole_number "$LAUNCH_WAIT" || fail "RUN_LONG_LAUNCH_WAIT must be whole seconds"
[[ $SAMPLE =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "RUN_LONG_SAMPLE must be a number of seconds"

# shellcheck source=machine-lib.sh
source "$HERE/machine-lib.sh"

# Sets REPLY to the first line of a file. Returns 1 when there is none.
read_first() {
  REPLY=""
  IFS= read -r REPLY 2>/dev/null <"$1" || [ -n "$REPLY" ]
}

# id2_of <pid>: sets ID2 to the process's second id, its Windows id under Git Bash and its start time (field 22 of /proc/<pid>/stat) on Linux, or "" when it cannot be read.
# On Linux it also sets ID2_ZOMBIE to 1 for a process that has ended and waits to be reaped (state Z). It starts no process.
id2_of() {
  local s="" f
  ID2=""
  ID2_ZOMBIE=0
  if [ "$ON_WIN" -eq 1 ]; then
    IFS= read -r ID2 2>/dev/null <"/proc/$1/winpid" || true
    return 0
  fi
  IFS= read -r s 2>/dev/null <"/proc/$1/stat" || [ -n "$s" ] || return 0
  # The name in brackets may hold spaces, so the fields are counted from the last ") ". The state is then the first, and the start time the twentieth.
  read -r -a f <<<"${s##*) }"
  [[ ${f[19]:-} =~ ^[0-9]+$ ]] && ID2=${f[19]}
  [ "${f[0]:-}" != Z ] || ID2_ZOMBIE=1
  return 0
}

# settle_id2 <pid>: sets ID2 as id2_of does, for a process just launched. Under Git Bash a forked process gets a Windows id of its own and a new one again when it execs the command,
# so the id is read until it has been the same for three reads in a row, or the process has ended (the last id read then stands). On Linux the start time does not change at exec, so one read is enough.
settle_id2() {
  local same=0 last="" i
  if [ "$ON_WIN" -eq 0 ]; then
    id2_of "$1"
    return 0
  fi
  for ((i = 0; i < 50; i++)); do
    kill -0 "$1" 2>/dev/null || break
    id2_of "$1"
    if [ -n "$ID2" ] && [ "$ID2" = "$last" ]; then
      same=$((same + 1))
      [ "$same" -ge 3 ] && break
    else
      same=0
    fi
    last=$ID2
    sleep 0.15
  done
  ID2=$last
}

# pid_alive <pid> <second id>: the process is there and, when its second id can be read and was recorded (a record holds - when it could not be read), still has that id, so a reused id is not taken for it.
# On Linux a zombie is not alive: kill -0 finds it until its parent reaps it, which for a killed runner can be later, but it runs nothing. No process is started here.
pid_alive() {
  kill -0 "$1" 2>/dev/null || return 1
  id2_of "$1"
  [ "$ID2_ZOMBIE" -eq 0 ] || return 1
  [ -z "$ID2" ] || [ -z "$2" ] || [ "$2" = - ] || [ "$ID2" = "$2" ]
}

# group_alive <lock folder>: the lock has a group file (run's) and a process of that group is still there. The leader alive with its recorded
# second id is enough. A live process with the leader's id and another second id means the id, and so the group number, was reused.
# Otherwise on Linux a member is looked for in /proc (the group is the third field after the name in /proc/<pid>/stat), and a zombie does not count.
# Under Git Bash kill -0 on the group decides. No process is started.
group_alive() {
  local g w d s f
  read_first "$1/group" || return 1
  read -r g w <<<"$REPLY"
  [[ $g =~ ^[0-9]+$ ]] || return 1
  pid_alive "$g" "$w" && return 0
  id2_of "$g"
  [ -z "$ID2" ] || [ "$ID2_ZOMBIE" -eq 1 ] || return 1
  kill -0 -- "-$g" 2>/dev/null || return 1
  [ "$ON_WIN" -eq 0 ] || return 0
  for d in /proc/[0-9]*/stat; do
    IFS= read -r s 2>/dev/null <"$d" || continue
    read -r -a f <<<"${s##*) }"
    [ "${f[2]:-}" = "$g" ] && [ "${f[0]}" != Z ] && return 0
  done
  return 1
}

# lock_alive <lock folder>: the process that holds the lock is alive, or the lock is too young to have an owner, or (run's lock) a process of its
# command's group lives on after run is gone. GROUP_ONLY is then 1.
lock_alive() {
  local pid win m now
  GROUP_ONLY=0
  if read_first "$1/owner"; then
    read -r pid win <<<"$REPLY"
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    # A failed check is made three times, 0.4 s apart, so a machine too short of memory to start a process for a moment does not make a live run look lost.
    pid_alive "$pid" "$win" && return 0
    sleep 0.4
    read_first "$1/owner" && read -r pid win <<<"$REPLY"
    pid_alive "$pid" "$win" && return 0
    sleep 0.4
    read_first "$1/owner" && read -r pid win <<<"$REPLY"
    pid_alive "$pid" "$win" && return 0
    group_alive "$1" || return 1
    GROUP_ONLY=1
    return 0
  fi
  m=$(stat -c %Y "$1" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - m)) -lt 30 ]
}

# Sets WAIT_LOG and returns 0 when a start under the name is waiting for memory: its record is there and the start process is alive.
# A record folder with no info file under 30 seconds old is one being made.
# A failed check is made three times, 0.4 s apart, as lock_alive does. WAIT_LOG holds the record's log path, also when the start is gone.
waiting_alive() {
  local pid win log m now try
  WAIT_LOG=""
  [ -d "$WAITDIR" ] || return 1
  for try in 1 2 3; do
    if read_first "$WAITDIR/info"; then
      read -r pid win log <<<"$REPLY"
      [[ $pid =~ ^[0-9]+$ ]] || return 1
      WAIT_LOG=$log
      pid_alive "$pid" "$win" && return 0
      [ "$try" -ge 3 ] || sleep 0.4
    else
      m=$(stat -c %Y "$WAITDIR" 2>/dev/null) || return 1
      now=$(date +%s)
      [ $((now - m)) -lt 30 ]
      return
    fi
  done
  return 1
}

# Sets LAST_LOG and LAST_CODE from the record of the last run. Returns 1 when there is no whole record.
read_last() {
  local k v
  LAST_LOG=""
  LAST_CODE=""
  [ -r "$LASTFILE" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case $k in
      log) LAST_LOG=$v ;;
      code) LAST_CODE=$v ;;
    esac
  done <"$LASTFILE"
  [ -n "$LAST_LOG" ] && [[ $LAST_CODE =~ ^[0-9]+$ ]]
}

# Sets REF_TIME and REF_REASON from the record of the last give-up under the name. Returns 1 when there is no whole record.
read_refused() {
  local k v
  REF_TIME=""
  REF_REASON=""
  [ -f "$REFUSEDFILE" ] && [ -r "$REFUSEDFILE" ] || return 1
  while IFS='=' read -r k v || [ -n "$k" ]; do
    case $k in
      time) REF_TIME=$v ;;
      reason) REF_REASON=$v ;;
    esac
  done <"$REFUSEDFILE"
  [ -n "$REF_TIME" ] && [ -n "$REF_REASON" ]
}

# note_refused <reason>: writes the record of a give-up under the name, through a temporary name, so a reader never sees half of it, and reads it back.
# It fails (quietly) when the record cannot be written or read back, for example with a folder where the temporary file or the record goes, and its caller then removes the earlier run's record.
note_refused() {
  { printf 'time=%s\nreason=%s\n' "$(date -Iseconds)" "$1" >"${REFUSEDFILE:?}.tmp" && mv -f "${REFUSEDFILE:?}.tmp" "${REFUSEDFILE:?}" && read_refused; } 2>/dev/null
}

# Sets RUN_STATE (waiting, waitgone, refused, running, ended, lost or none), RUN_LOG, RUN_CODE and RUN_IDS for the name.
run_state() {
  local lock_log=""
  RUN_STATE=none
  RUN_LOG=""
  RUN_CODE=""
  RUN_IDS=""
  # A live lock comes first, so a live run never reads as anything else.
  if [ -d "$LOCKDIR" ]; then
    read_first "$LOCKDIR/log" && lock_log=$REPLY
    RUN_LOG=$lock_log
    if lock_alive "$LOCKDIR"; then
      RUN_STATE=running
      if read_first "$LOCKDIR/pid"; then
        RUN_IDS=$REPLY
      elif read_first "$LOCKDIR/owner"; then
        RUN_IDS=$REPLY
      fi
      return
    fi
  fi
  # Then the waiting record. One whose start is gone, with no give-up written (a give-up removes the record), counts only
  # when no record of an ended run is newer than it, since a later run has then replaced it.
  if [ "$SKIP_WAIT" -ne 1 ]; then
    if waiting_alive; then
      RUN_STATE=waiting
      RUN_LOG=$WAIT_LOG
      return
    fi
    if [ -s "$WAITDIR/info" ] && ! [ "$LASTFILE" -nt "$WAITDIR/info" ]; then
      RUN_STATE=waitgone
      RUN_LOG=$WAIT_LOG
      return
    fi
    # The last thing that happened under the name was a give-up (a run that takes the lock removes the record), so no earlier run's record or log is its answer.
    if read_refused; then
      RUN_STATE=refused
      return
    fi
  fi
  if [ -d "$LOCKDIR" ]; then
    # The runner can end after it wrote the record and before it removed the lock.
    if read_last && [ "$LAST_LOG" = "$lock_log" ]; then
      RUN_STATE=ended
      RUN_CODE=$LAST_CODE
      return
    fi
    RUN_STATE=lost
    return
  fi
  if read_last; then
    RUN_STATE=ended
    RUN_LOG=$LAST_LOG
    RUN_CODE=$LAST_CODE
  fi
}

# Sets IDS_TEXT from a recorded "pid <second id>" line to "pid <pid> winpid <w>" (on Linux "pid <pid> start <s>"), with the second id read live from /proc
# when the process is still there, since a recorded Windows id can be from before the command's exec.
ids_text() {
  local pid=${1%% *} win=${1#* }
  id2_of "$pid"
  [ -z "$ID2" ] || win=$ID2
  IDS_TEXT="pid $pid $ID2_LABEL $win"
}

# Prints the one line for the state and sets STATE_EXIT: the command's code for an ended run, 77 for a lost one, 1 for none, 0 for running or waiting.
describe_run() {
  case $RUN_STATE in
    waiting)
      echo "run-long: $NAME waiting for memory, log $RUN_LOG"
      STATE_EXIT=0
      ;;
    waitgone)
      echo "run-long: $NAME waiting start is gone, it ran nothing, log $RUN_LOG"
      STATE_EXIT=76
      ;;
    refused)
      echo "run-long: $NAME refused at $REF_TIME, $REF_REASON"
      STATE_EXIT=76
      ;;
    running)
      ids_text "$RUN_IDS"
      if [ "$GROUP_ONLY" -eq 1 ]; then
        echo "run-long: $NAME running, $IDS_TEXT, but run-long itself is gone, so no end line will come, log $RUN_LOG"
      else
        echo "run-long: $NAME running, $IDS_TEXT, log $RUN_LOG"
      fi
      STATE_EXIT=0
      ;;
    ended)
      echo "run-long: $NAME ended with code $RUN_CODE, log $RUN_LOG"
      STATE_EXIT=$RUN_CODE
      ;;
    lost)
      echo "run-long: $NAME stopped without an end line, log $RUN_LOG"
      STATE_EXIT=77
      ;;
    *)
      echo "run-long: $NAME no run"
      STATE_EXIT=1
      ;;
  esac
}

# mem_mb: sets MEM_MB from the MEM_KEY line (MemFree, or MemAvailable on the machine itself) of the meminfo file.
# Returns 1 when the file cannot be read and 2 when it has no such figure. It starts no process.
mem_mb() {
  local key value rest found=""
  [ -f "$MEMINFO" ] && [ -r "$MEMINFO" ] || return 1
  while read -r key value rest; do
    if [ "$key" = "$MEM_KEY:" ]; then
      found="$value"
      break
    fi
  done <"$MEMINFO"
  whole_number "$found" || return 2
  MEM_MB=$((10#$found / 1024))
}

# gb_text <MB>: sets GB_TEXT to the figure in GB with two decimals.
gb_text() {
  local centi=$(($1 * 100 / 1024))
  printf -v GB_TEXT '%d.%02d' $((centi / 100)) $((centi % 100))
}

# Sets FREE_MB, FREE_TEXT and under (0 or 1) from the memory line of the meminfo file.
read_free() {
  local rc=0
  mem_mb || rc=$?
  [ "$rc" -ne 1 ] || fail "cannot read $MEMINFO"
  [ "$rc" -ne 2 ] || fail "no $MEM_KEY figure in $MEMINFO"
  FREE_MB=$MEM_MB
  gb_text "$FREE_MB"
  FREE_TEXT=$GB_TEXT
  under=0
  [ "$FREE_MB" -ge $((FLOOR_TENTHS * 1024 / 10)) ] || under=1
}

# Sets LOAD_TEXT to the 1-minute load, the first figure of the loadavg file, and high (0 or 1) to whether it is LOAD_LIMIT or more.
read_load() {
  local first="" rest frac
  [ -f "$LOADAVG" ] && [ -r "$LOADAVG" ] || fail "cannot read $LOADAVG"
  read -r first rest <"$LOADAVG" || [ -n "$first" ] || fail "no load figure in $LOADAVG"
  [[ $first =~ ^([0-9]+)(\.([0-9]+))?$ ]] || fail "no load figure in $LOADAVG"
  frac="${BASH_REMATCH[3]}00"
  LOAD_TEXT=$first
  high=0
  [ $((10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2})) -lt $((LOAD_LIMIT * 100)) ] || high=1
}

floor_text() {
  printf '%s' "$((FLOOR_TENTHS / 10)).$((FLOOR_TENTHS % 10))"
}

# read_gate: reads the memory and, on the machine itself, the load. Sets SHUT (0 or 1), GATE_WHY (the reasons it is shut, joined by " and ")
# and GATE_FIGURES (the figures as start's line of run gives them).
read_gate() {
  read_free
  GATE_WHY=""
  GATE_FIGURES="free $FREE_TEXT GB$UNIT (floor $(floor_text) GB)"
  [ "$under" -eq 0 ] || GATE_WHY="free $FREE_TEXT GB$UNIT under the floor of $(floor_text) GB"
  if [ "$GATE_LOAD" -eq 1 ]; then
    read_load
    GATE_FIGURES="$GATE_FIGURES, load $LOAD_TEXT (under $LOAD_LIMIT)"
    [ "$high" -eq 0 ] || GATE_WHY="${GATE_WHY:+$GATE_WHY and }load $LOAD_TEXT, not under $LOAD_LIMIT"
  fi
  SHUT=0
  [ -z "$GATE_WHY" ] || SHUT=1
}

# cpu_count: sets LOAD_LIMIT to the CPU count that the command NPROC prints, a whole number of 1 or more (up to 9 digits, so the arithmetic of read_load cannot wrap),
# with spaces and a carriage return allowed at its ends. Anything else fails the call with one line that names the command and what it printed.
cpu_count() {
  local out="" rc=0 shown ws=$' \r'
  out=$("$NPROC" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 0 ] && [[ $out =~ ^[$ws]*([0-9]{1,9})[$ws]*$ ]] && [ $((10#${BASH_REMATCH[1]})) -ge 1 ]; then
    LOAD_LIMIT=$((10#${BASH_REMATCH[1]}))
    return 0
  fi
  shown=${out//[^[:print:]]/ }
  fail "cannot read the CPU count, $NPROC printed '${shown:0:40}' (exit $rc)"
}

# self_setup: on the machine itself (see the header) the memory line is MemAvailable, the floor is that label's unless --floor was given, and the load is read too,
# against the CPU count, which is read here once for the call and not at each poll. Off the machine itself nothing is read.
self_setup() {
  machine_self || fail "$MACHINE_ERR"
  [ -n "$MACHINE_SELF" ] || return 0
  MEM_KEY=MemAvailable
  UNIT=" available"
  GATE_LOAD=1
  [ -n "$FLOOR_FLAG" ] || FLOOR_TENTHS=${MACHINE_FLOOR[$MACHINE_SELF]}
  cpu_count
}

check_name() {
  [[ $NAME =~ ^[A-Za-z0-9-]+$ ]] || usage
  LOCKDIR="$LOCKS/run-long-$NAME"
  LASTFILE="$LOCKS/run-long-$NAME.last"
  REFUSEDFILE="$LOCKS/run-long-$NAME.refused"
  WAITDIR="$LOCKS/run-long-$NAME.waiting"
}

# Prints the refusal for a live lock and exits 75.
refuse() {
  local ids="" log=""
  read_first "$LOCKDIR/pid" && ids=$REPLY
  [ -n "$ids" ] || { read_first "$LOCKDIR/owner" && ids=$REPLY; }
  read_first "$LOCKDIR/log" && log=$REPLY
  [ -z "$TMP_LOG" ] || rm -f "$TMP_LOG"
  ids_text "$ids"
  [ -n "$log" ] && log="log $log" || log="log not written yet"
  fail_refused "$NAME is already running ($IDS_TEXT), $log, so no second run was started" 75
}

# Prints the refusal for a start that is waiting for memory under the name and exits 75.
refuse_waiting() {
  [ -z "$TMP_LOG" ] || rm -f "$TMP_LOG"
  local log="log $WAIT_LOG"
  [ -n "$WAIT_LOG" ] || log="log not written yet"
  fail_refused "$NAME is already waiting for memory, $log, so no second run was started" 75
}

# Makes the waiting record folder with mkdir, so two starts cannot both wait under the name. It is a folder beside the lock, never the lock.
begin_waiting() {
  mkdir -p "$LOCKS" || fail "cannot make $LOCKS"
  if ! mkdir "$WAITDIR" 2>/dev/null; then
    waiting_alive && refuse_waiting
    rm -rf "${WAITDIR:?}"
    mkdir "$WAITDIR" 2>/dev/null || { waiting_alive; refuse_waiting; }
  fi
  IN_WAIT=1
  id2_of $$
  my_win=$ID2
  printf '%s %s %s\n' "$$" "${my_win:--}" "$1" >"$WAITDIR/info.tmp" && mv -f "$WAITDIR/info.tmp" "$WAITDIR/info"
}

# Removes this start's own waiting record, when it has one.
drop_waiting() {
  [ "$IN_WAIT" -eq 1 ] || return 0
  IN_WAIT=0
  rm -rf "${WAITDIR:?}"
}

# Takes the lock folder with mkdir. A live lock refuses. A stale one is taken over under a mutex folder, so two starts cannot both remove and make it.
take_lock() {
  local tries=0 old
  mkdir -p "$LOCKS" || fail "cannot make $LOCKS"
  while :; do
    mkdir "$LOCKDIR" 2>/dev/null && return 0
    if [ -d "$LOCKDIR" ]; then
      lock_alive "$LOCKDIR" && refuse
      if mkdir "$LOCKDIR.takeover" 2>/dev/null; then
        if [ -d "$LOCKDIR" ] && lock_alive "$LOCKDIR"; then
          rmdir "$LOCKDIR.takeover"
          refuse
        fi
        old=""
        read_first "$LOCKDIR/owner" && old=$REPLY
        echo "run-long: $NAME had a stale lock (process ${old%% *} is gone or its id was reused), taking it over"
        rm -rf "${LOCKDIR:?}"
        if mkdir "$LOCKDIR" 2>/dev/null; then
          rmdir "$LOCKDIR.takeover"
          return 0
        fi
        rmdir "$LOCKDIR.takeover"
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 25 ] || fail "cannot take the lock $LOCKDIR"
    sleep 0.2
  done
}

# Writes a file in the lock folder through a temporary name, so a reader never sees half of it.
put() {
  printf '%s\n' "$2" >"$LOCKDIR/$1.tmp" && mv -f "$LOCKDIR/$1.tmp" "$LOCKDIR/$1"
}

# parse_flags <start|run> <arguments...>: reads --name, --floor, --wait-max, --limit (run only) and the command after --, then checks the name.
parse_flags() {
  local sub=$1
  shift
  CMD=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)
        [ $# -ge 2 ] || usage
        NAME=$2
        shift 2
        ;;
      --floor)
        [[ ${2:-} =~ ^([0-9]+)(\.([0-9]))?$ ]] || usage
        FLOOR_TENTHS=$((10#${BASH_REMATCH[1]} * 10 + 10#${BASH_REMATCH[3]:-0}))
        FLOOR_FLAG=$FLOOR_TENTHS
        shift 2
        ;;
      --wait-max)
        whole_number "${2:-}" || usage
        WAIT_MAX=$((10#$2))
        shift 2
        ;;
      --limit)
        [ "$sub" = run ] || usage
        whole_number "${2:-}" || usage
        LIMIT=$((10#$2))
        shift 2
        ;;
      --)
        shift
        CMD=("$@")
        break
        ;;
      *) usage ;;
    esac
  done
  [ "${#CMD[@]}" -gt 0 ] || usage
  check_name
}

# prepare: the checks that come before anything is made (a live run or a waiting start under the name, the machine-self file, memory and load),
# then the log. Sets TMP_LOG and LOG, the path as it is printed. A failure here prints one line and makes no log.
prepare() {
  self_setup
  mkdir -p "$LOCKS" || fail "cannot make $LOCKS"
  if [ -d "$LOCKDIR" ] && lock_alive "$LOCKDIR"; then
    refuse
  fi
  waiting_alive && refuse_waiting
  # A waiting record that is left here belongs to a start that is gone. It is cleared, so it cannot hide this run.
  [ ! -d "$WAITDIR" ] || rm -rf "${WAITDIR:?}"
  read_gate
  TMP_LOG=$(mktemp -t "run-long-$NAME.XXXXXX") || fail "mktemp failed"
  # A relative TMPDIR gives a relative path, which status read from another folder could not follow.
  # Under Git Bash a TMPDIR in the form cygpath -m gives (C:/...) gives a path that starts with a drive letter, which is absolute too.
  [[ $TMP_LOG == /* || $TMP_LOG == [A-Za-z]:/* ]] || TMP_LOG="$PWD/$TMP_LOG"
  LOG=$(cygpath -m "$TMP_LOG" 2>/dev/null) || LOG=$TMP_LOG
}

# gate_wait [quiet]: while memory or load keeps the gate shut, keeps the waiting record and reads again every INTERVAL seconds.
# After WAIT_MAX seconds it gives up with one line (see fail_refused) and 76, keeps the record of the give-up and removes the log. quiet leaves out the line that says it waits.
gate_wait() {
  local t0 left
  [ "$SHUT" -eq 1 ] || return 0
  begin_waiting "$LOG"
  [ "${1:-}" = quiet ] || echo "run-long: $GATE_WHY, waiting up to $WAIT_MAX s"
  t0=$SECONDS
  while [ "$SHUT" -eq 1 ]; do
    left=$((WAIT_MAX - (SECONDS - t0)))
    if [ "$left" -le 0 ]; then
      rm -f "$TMP_LOG"
      # The record is written before the waiting record goes, so a look never finds neither.
      # When the record cannot be kept, the earlier run's record goes instead, so status and wait say there is no run and never that run's result.
      note_refused "gave up after $WAIT_MAX s, last $GATE_WHY, nothing started" || rm -f "${LASTFILE:?}"
      drop_waiting
      fail_refused "gave up after $WAIT_MAX s, last $GATE_WHY, nothing started" 76
    fi
    sleep "$((left < INTERVAL ? left : INTERVAL))"
    read_gate
  done
}

# hold_lock: takes the lock, drops the waiting record and writes this process as the owner, with the log, the command line and the start time.
hold_lock() {
  take_lock
  # A run under the name has started, so the record of an earlier give-up no longer describes the name.
  rm -f "${REFUSEDFILE:?}"
  drop_waiting
  id2_of $$
  put owner "$$ ${ID2:--}"
  put starter "$$"
  put log "$LOG"
  put cmdline "$(printf '%q ' "${CMD[@]}")"
  STARTED=$(date -Iseconds)
  put started "$STARTED"
}

cmd_start() {
  local log launched
  parse_flags start "$@"
  prepare
  log=$LOG
  echo "run-long: log $log"

  trap drop_waiting EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  gate_wait
  hold_lock

  # The runner is launched from a subshell that ends at once, with nothing open to this shell, so it has no parent shell to be stopped with.
  (bash "$SELF" __run "$NAME" "$LOCKDIR" "$log" "$LASTFILE" -- "${CMD[@]}" </dev/null >/dev/null 2>&1 &)

  launched=$SECONDS
  # This start judges its own run by the lock and the record alone, so another start waiting under the name does not hold it.
  SKIP_WAIT=1
  while :; do
    run_state
    # The record of its own log is final, whatever a later start is doing under the name.
    if read_last && [ "$LAST_LOG" = "$log" ]; then
      RUN_STATE=ended
      RUN_LOG=$LAST_LOG
      RUN_CODE=$LAST_CODE
    fi
    case $RUN_STATE in
      waiting) ;;
      running)
        # Still the start process as owner after the launch wait means the runner never came up.
        if [ "$((SECONDS - launched))" -ge "$LAUNCH_WAIT" ] && read_first "$LOCKDIR/owner" && [ "${REPLY%% *}" = "$$" ]; then
          rm -rf "${LOCKDIR:?}"
          fail "the runner did not start within $LAUNCH_WAIT s, nothing ran, log $log" 77
        fi
        ;;
      ended)
        if [ "$RUN_LOG" = "$log" ]; then
          describe_run
          exit "$STATE_EXIT"
        fi
        fail "the record of the run under $NAME is another run's, log $log" 77
        ;;
      *)
        fail "the run under $NAME stopped without an end line, log $log" 77
        ;;
    esac
    sleep "$POLL"
  done
}

# own_lock <lock folder> <log>: the lock is there and its log file names this log.
own_lock() {
  read_first "$1/log" && [ "$REPLY" = "$2" ]
}

# The runner, run by start through __run: <name> <lock folder> <log> <record file> -- <command...>
cmd_run() {
  local lock=$2 log=$3 cpid win code
  LASTFILE=$4
  shift 5
  trap '' HUP
  LOCKDIR=$lock
  # The runner works only while the lock names its own start (by the log path), so a slow runner cannot run a command that another start has taken the lock for.
  own_lock "$lock" "$log" || exit 0
  id2_of $$
  put owner "$$ ${ID2:--}"
  "$@" >>"$log" 2>&1 </dev/null &
  cpid=$!
  settle_id2 "$cpid"
  win=$ID2
  put pid "$cpid ${win:--}"
  wait "$cpid"
  code=$?
  write_end "$log" "$code"
  close_run "$lock" "$log" "$code"
  exit 0
}

# write_end <log> <code>: appends the end line to the log, on a line of its own whether or not the output ended with a newline. Sets END_LINE.
write_end() {
  local last nl=""
  last=$(
    tail -c 1 "$1" 2>/dev/null
    echo x
  )
  [ -s "$1" ] && [ "${last%x}" != $'\n' ] && nl=$'\n'
  END_LINE="run-long: end exit $2 $(date -Iseconds)"
  printf '%s%s\n' "$nl" "$END_LINE" >>"$1"
}

# close_run <lock folder> <log> <code>: writes the record of the run and removes the lock. A lock that now names another start is left alone,
# with its record, and the end line stays in this run's own log.
close_run() {
  own_lock "$1" "$2" || return 0
  printf 'log=%s\ncode=%s\n' "$2" "$3" >"$LASTFILE.tmp" && mv -f "$LASTFILE.tmp" "$LASTFILE"
  mv "$1" "$1.done.$$" 2>/dev/null && rm -rf "${1:?}.done.$$"
}

# The reader of run's summary (see the header). awk reads the log with LC_ALL=C, so the marks of node's reporters are matched as bytes,
# and substr counts bytes: "✖ " is 4 of them.
# shellcheck disable=SC2016  # the dollar signs are awk's own
SUMMARY_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function count(kind, word, n) {
  if (!((kind, word) in cnt)) { nw[kind]++; words[kind, nw[kind]] = word; cnt[kind, word] = 0 }
  cnt[kind, word] += n
  has[kind] = 1
}
function addfail(kind, n) { nfl[kind]++; fl[kind, nfl[kind]] = n }
function addskip(kind, r, c) { nsk[kind]++; skr[kind, nsk[kind]] = r; skc[kind, nsk[kind]] = c }
function flushtap() { if (pend != "") addfail("node", pend); pend = "" }
{ line = $0; sub(/\r$/, "", line); t = trim(line) }
t ~ /^ℹ (tests|pass|fail|cancelled|skipped|todo) [0-9]+$/ || t ~ /^# (tests|pass|fail|cancelled|skipped|todo) [0-9]+$/ {
  split(t, a, " "); count("node", a[2], a[3]); next
}
t == "✖ failing tests:" { infail = 1; next }
t ~ /^test at / { at = substr(t, 9); next }
infail && at != "" && t ~ /^✖ .* \([0-9.]+m?s\)$/ {
  n = substr(t, 5); sub(/ \([0-9.]+m?s\)$/, "", n); addfail("node", n " (" at ")"); at = ""; next
}
t ~ /^﹣ .* \([0-9.]+m?s\)( # .*)?$/ {
  r = ""; if (match(t, / # .*$/)) r = substr(t, RSTART + 3)
  if (r == "SKIP") r = ""
  addskip("node", r, 1); next
}
t ~ /^not ok [0-9]+ - / {
  flushtap(); n = t; sub(/^not ok [0-9]+ - /, "", n)
  if (n !~ / # TODO/) pend = n
  next
}
t ~ /^ok [0-9]+ - / {
  flushtap(); if (match(t, / # SKIP/)) addskip("node", trim(substr(t, RSTART + 7)), 1)
  next
}
t ~ /^# Subtest: / { flushtap(); next }
t == "type: \047suite\047" { pend = ""; next }
t ~ /^=* ?[0-9]+ (passed|failed|skipped|xfailed|xpassed|error|errors|deselected|warning|warnings|rerun)(, [0-9]+ [a-z]+)* in [0-9.]+s/ {
  s = t; gsub(/=/, "", s); sub(/ in [0-9.]+s.*$/, "", s); s = trim(s)
  k = split(s, parts, ", ")
  for (i = 1; i <= k; i++) { split(parts[i], p, " "); count("pytest", p[2], p[1]) }
  next
}
line ~ /^(FAILED|ERROR) [^ ]/ { split(line, a, " "); addfail("pytest", a[2]); next }
line ~ /^SKIPPED \[[0-9]+\] / {
  c = line; sub(/^SKIPPED \[/, "", c); c = substr(c, 1, index(c, "]") - 1)
  r = line; sub(/^SKIPPED \[[0-9]+\] /, "", r); i = index(r, ": "); r = (i ? substr(r, i + 2) : "")
  addskip("pytest", r, c); next
}
line ~ /^passed [0-9]+ failed [0-9]+$/ { split(line, a, " "); count("cases.sh", "passed", a[2]); count("cases.sh", "failed", a[4]); next }
line ~ /^FAIL [A-Za-z0-9_]+( |$)/ { split(line, a, " "); addfail("cases.sh", a[2]); next }
line ~ /^PASS [A-Za-z0-9_]+ \(skipped: .*\)$/ {
  r = line; sub(/^PASS [A-Za-z0-9_]+ \(skipped: /, "", r); sub(/\)$/, "", r); addskip("cases.sh", r, 1); next
}
t != "" { at = "" }
END {
  flushtap()
  nk = split("node pytest cases.sh", kinds, " ")
  nodeorder = "tests pass fail cancelled skipped todo"
  any = 0
  for (k = 1; k <= nk; k++) {
    kd = kinds[k]
    if (!has[kd]) continue
    any = 1; s = ""
    if (kd == "node") {
      m = split(nodeorder, ow, " ")
      for (i = 1; i <= m; i++) if ((kd, ow[i]) in cnt) s = s " " ow[i] " " cnt[kd, ow[i]]
    } else {
      for (i = 1; i <= nw[kd]; i++) s = s " " words[kd, i] " " cnt[kd, words[kd, i]]
    }
    print "run-long: counts (" kd ")" s
  }
  if (!any) print "run-long: counts none found in the log"
  shown = 0; total = 0
  for (k = 1; k <= nk; k++) {
    kd = kinds[k]
    if (!has[kd]) continue
    for (i = 1; i <= nfl[kd]; i++) {
      total++
      if (shown < 20) { print "run-long: failed " fl[kd, i]; shown++ }
    }
  }
  if (total > shown) print "run-long: failed and " (total - shown) " more, see the log"
  ng = 0
  for (k = 1; k <= nk; k++) {
    kd = kinds[k]
    if (!has[kd]) continue
    for (i = 1; i <= nsk[kd]; i++) {
      r = skr[kd, i]; if (r == "") r = "(no reason given)"
      if (!(r in g)) { ng++; gr[ng] = r; g[r] = 0 }
      g[r] += skc[kd, i]
    }
  }
  for (i = 1; i <= ng; i++) {
    b = i
    for (j = i + 1; j <= ng; j++) if (g[gr[j]] > g[gr[b]]) b = j
    if (b != i) { x = gr[b]; for (j = b; j > i; j--) gr[j] = gr[j - 1]; gr[i] = x }
  }
  for (i = 1; i <= ng && i <= 10; i++) print "run-long: skipped " g[gr[i]] ": " gr[i]
  if (ng > 10) print "run-long: skipped and " (ng - 10) " more reasons, see the log"
}
'

# The reader of the tail (see the header). It reads the last lines of the log (print_tail gives it at most 16), leaves out the end line, and prints the header and at most 15 lines.
# awk runs with LC_ALL=C, so length and substr count bytes. A line over 300 bytes is cut at 300 and marked with its size, and the cut backs off to the first byte of a UTF-8
# character that it would split (a byte from 0x80 to 0xBF at the 301st place means the cut is inside one). The lines are then taken from the newest while their bytes,
# a newline counted for each, stay within 4000.
# shellcheck disable=SC2016  # the dollar signs are awk's own
TAIL_AWK='
BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
{ n++; l[n] = $0 }
END {
  if (n > 0 && l[n] ~ /^run-long: end exit /) n--
  start = n - 14; if (start < 1) start = 1
  for (i = start; i <= n; i++) {
    s = l[i]; len = length(s)
    if (len > 300) {
      cut = 300
      o = ord[substr(s, 301, 1)]
      if (o >= 128 && o < 192) {
        while (cut > 0 && ord[substr(s, cut, 1)] >= 128 && ord[substr(s, cut, 1)] < 192) cut--
        cut--
      }
      l[i] = substr(s, 1, cut) " [cut, " len " bytes]"
    }
  }
  total = 0; first = n + 1
  for (i = n; i >= start; i--) {
    b = length(l[i]) + 1
    if (total + b > 4000) break
    total += b; first = i
  }
  if (first <= n) {
    print "run-long: last " (n - first + 1) " lines of the log:"
    for (i = first; i <= n; i++) print l[i]
  }
}
'

# print_tail <log>: prints the last lines of the command's output from the log (see the header), nothing when the log has none or cannot be read.
print_tail() {
  [ -r "$1" ] || return 0
  tail -n 16 -- "$1" 2>/dev/null | LC_ALL=C awk "$TAIL_AWK"
}

# sampler <owner pid> <owner's second id> <file>: reads the memory line every SAMPLE seconds and writes "<MB> <HH:MM:SS>" to the file at each new lowest.
# A TERM stops it, and it stops by itself once the owner is gone, so a run stopped with kill -9 leaves no sampler behind.
# Gone is as pid_alive judges it, so an owner that is a zombie under a parent that never reaps it is gone too.
sampler() {
  local low="" t sp=""
  trap 'kill "$sp" 2>/dev/null; exit 0' TERM
  while pid_alive "$1" "$2"; do
    if mem_mb && { [ -z "$low" ] || [ "$MEM_MB" -lt "$low" ]; }; then
      low=$MEM_MB
      printf -v t '%(%H:%M:%S)T' -1
      printf '%s %s\n' "$low" "$t" >"$3"
    fi
    sleep "$SAMPLE" &
    sp=$!
    wait "$sp"
  done
}

# killer <group> <seconds>: sends KILL to the whole group once the seconds have passed. A TERM stops it first.
killer() {
  local sp=""
  trap 'kill "$sp" 2>/dev/null; exit 0' TERM
  sleep "$2" &
  sp=$!
  wait "$sp"
  kill -KILL -- "-$1" 2>/dev/null
}

# The EXIT trap of run. Until run holds the lock it has started nothing, so a run that stops then leaves no waiting record and no log.
run_cleanup() {
  drop_waiting
  [ "$HELD" -eq 1 ] || [ -z "$TMP_LOG" ] || rm -f "${TMP_LOG:?}"
}

# run: see the header.
cmd_foreground() {
  local t0 left run_t0 cpid spid kpid="" code stop="" killed=0 lowfile low_mb="" low_at="" word=free default=""
  WAIT_MAX=""
  t0=$SECONDS
  parse_flags run "$@"
  [ -n "$WAIT_MAX" ] || { WAIT_MAX=120; default=" (its default)"; }
  [ "$LIMIT" -gt "$WAIT_MAX" ] || fail "--limit $LIMIT is not above --wait-max $WAIT_MAX$default, so nothing started"
  prepare
  trap run_cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  gate_wait quiet
  hold_lock
  HELD=1
  left=$((LIMIT - (SECONDS - t0)))
  [ "$left" -ge 1 ] || left=1
  echo "run-long: started $STARTED, $GATE_FIGURES, limit $left s, log $LOG"
  # From here a signal passes a TERM to the command's group, and the end line, the record and the summary still follow.
  trap 'stop=1' TERM INT HUP
  lowfile="$TMP_LOG.low"
  id2_of $$
  sampler $$ "${ID2:--}" "$lowfile" &
  spid=$!
  # The time is taken before the launch, so timeout's own deadline is never earlier than run_t0 + left.
  run_t0=$SECONDS
  # set -m gives the command a process group of its own, led by timeout, so the limit and a TERM reach each process in it.
  set -m
  timeout -s KILL "$left" "${CMD[@]}" >>"$TMP_LOG" 2>&1 </dev/null &
  cpid=$!
  set +m
  # The group number is recorded at once, with - for the second id (not read yet, which every reader takes as unknown), so a caller that stops this run
  # (mutant-run.sh reads the group before it sends a TERM) finds the group without waiting for the id to settle.
  put group "$cpid -"
  # Under Git Bash the id is read until it has settled, since timeout gets a new Windows id when it execs. The records then name the id status reads live.
  settle_id2 "$cpid"
  # The group first, so the pid record is the last step before the wait, and a caller that waits for it finds the group there too.
  put group "$cpid ${ID2:--}"
  put pid "$cpid ${ID2:--}"
  # A test's pause point (see the header). It is off unless RUN_LONG_TEST_PAUSE names a file.
  if [ -n "${RUN_LONG_TEST_PAUSE:-}" ]; then
    printf '%s\n' "$$" >"$RUN_LONG_TEST_PAUSE.at"
    while [ ! -e "$RUN_LONG_TEST_PAUSE" ]; do
      sleep 0.1
    done
  fi
  while :; do
    # The trap only sets stop, so stop is read once more before each wait: a TERM that came before it is acted on here, not lost.
    if [ -z "$stop" ]; then
      # bash reports a job killed by a signal on stderr, and the end line says it instead.
      wait "$cpid" 2>/dev/null
      code=$?
    fi
    if [ -z "$stop" ] || ! kill -0 "$cpid" 2>/dev/null; then
      # With stop set, a status read so far was the interrupt's, or none was read. bash reaps an ended job by itself and keeps its status,
      # so this wait gives the command's own code.
      if [ -n "$stop" ]; then
        wait "$cpid" 2>/dev/null
        code=$?
      fi
      break
    fi
    kill -TERM -- "-$cpid" 2>/dev/null
    stop=""
    # A timeout that is sent a TERM can drop its deadline, so from the first TERM run keeps the deadline itself.
    if [ -z "$kpid" ]; then
      killer "$cpid" "$((run_t0 + left - SECONDS > 0 ? run_t0 + left - SECONDS : 0))" &
      kpid=$!
    fi
  done
  if { [ "$code" -eq 124 ] || [ "$code" -eq 137 ]; } && [ $((SECONDS - run_t0)) -ge "$left" ]; then
    killed=1
    # uutils timeout kills only the command it ran, so run kills what is left of the group, such as a child the command put in the background.
    kill -KILL -- "-$cpid" 2>/dev/null
  fi
  if [ -n "$kpid" ]; then
    kill "$kpid" 2>/dev/null
    wait "$kpid" 2>/dev/null
  fi
  kill "$spid" 2>/dev/null
  wait "$spid" 2>/dev/null
  write_end "$TMP_LOG" "$code"
  close_run "$LOCKDIR" "$LOG" "$code"
  echo "$END_LINE"
  [ "$killed" -eq 0 ] || echo "run-long: killed at the limit of $LIMIT s"
  print_tail "$TMP_LOG"
  LC_ALL=C awk "$SUMMARY_AWK" "$TMP_LOG"
  [ -r "$lowfile" ] && read -r low_mb low_at <"$lowfile"
  rm -f "$lowfile"
  if mem_mb && { [ -z "$low_mb" ] || [ "$MEM_MB" -lt "$low_mb" ]; }; then
    low_mb=$MEM_MB
    printf -v low_at '%(%H:%M:%S)T' -1
  fi
  [ "$MEM_KEY" = MemFree ] || word=available
  if [ -n "$low_mb" ]; then
    gb_text "$low_mb"
    echo "run-long: lowest $GB_TEXT GB $word at $low_at, sampled every $SAMPLE s"
  else
    echo "run-long: lowest not read, since $MEMINFO could not be read"
  fi
  exit "$code"
}

cmd_wait() {
  local wlog=""
  while :; do
    run_state
    [ "$RUN_STATE" = waiting ] && wlog=$RUN_LOG
    [ "$RUN_STATE" = running ] || [ "$RUN_STATE" = waiting ] || break
    sleep "$POLL"
  done
  # A start that waited for memory and then gave up ran nothing, so the previous run's code is not its answer.
  # When the give-up left its record, describe_run says it with its time.
  if [ "$RUN_STATE" != refused ] && [ -n "$wlog" ] && [ "$RUN_LOG" != "$wlog" ]; then
    echo "run-long: $NAME start gave up waiting for memory, nothing ran, log $wlog"
    exit 76
  fi
  describe_run
  [ "$RUN_STATE" != ended ] || print_tail "$RUN_LOG"
  exit "$STATE_EXIT"
}

cmd_status() {
  run_state
  describe_run
  [ "$RUN_STATE" != ended ] || STATE_EXIT=0
  exit "$STATE_EXIT"
}

[ $# -gt 0 ] || usage
SUB=$1
shift
case "$SUB" in
  start) cmd_start "$@" ;;
  run) cmd_foreground "$@" ;;
  wait | status)
    [ $# -eq 2 ] && [ "$1" = --name ] || usage
    NAME=$2
    check_name
    "cmd_$SUB"
    ;;
  __run) cmd_run "$@" ;;
  *) usage ;;
esac
