#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

# Sourcing log.sh redirects nothing until log_init is called, so the pure
# helpers can be tested in this shell.
# shellcheck source=log.sh
source "${SCRIPT_DIR}/log.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# log.sh redirects the shell it is sourced into, so every case runs in a shell
# of its own rather than in this one. The subject is the split between what
# reaches the terminal and what reaches the log, which is what the two helpers
# below separate: 'terminal_of' returns what a person would have seen on stdout,
# 'terminal_err_of' what they would have seen on stderr, and the log is read
# from the file afterwards.
terminal_of() {
  bash -c "
    set -uo pipefail
    source '${SCRIPT_DIR}/log.sh'
    $1
  " 2>/dev/null
}

terminal_err_of() {
  # 2>&1 before >/dev/null, and in that order: stderr is moved onto the current
  # stdout - which the caller captures - and stdout is then discarded. Not the
  # "both into one" idiom shellcheck reads it as.
  # shellcheck disable=SC2069
  bash -c "
    set -uo pipefail
    source '${SCRIPT_DIR}/log.sh'
    $1
  " 2>&1 >/dev/null
}

log_of() {
  cat "$1" 2>/dev/null
}

occurrences() {
  grep -c -- "$2" "$1" 2>/dev/null || true
}

# How often the snippet showed the log's tail on the terminal. A count rather
# than the text, because the tail itself is asserted elsewhere and here only its
# presence matters.
tails_shown() {
  terminal_err_of "$1" | grep -c 'full output' || true
}

# --- without a log file, everything is on the terminal -----------------------

expect "no log: step goes to the terminal" \
  "==> building" \
  terminal_of 'step "building"'

expect "no log: log_path is empty" \
  "" \
  terminal_of 'printf "%s" "$(log_path)"'

# --- with a log file ---------------------------------------------------------

LOG="${WORK}/a.build.log"

expect "log: only the step line reaches the terminal" \
  "==> building" \
  terminal_of "log_init '${LOG}'; echo noise; step 'building'; echo 'more noise'"

expect "log: the noise reaches the log" \
  "noise
==> building
more noise" \
  log_of "${LOG}"

expect "log: log_path names the file" \
  "${LOG}" \
  terminal_of "log_init '${LOG}'; printf '%s' \"\$(log_path)\" >&3"

# The header carries the date, so it is checked for the part that is known.
LOG_HEADER="${WORK}/header.build.log"
terminal_of "log_init '${LOG_HEADER}' 'tool.sh image system.json'" >/dev/null
expect "log: the header names what is being run" \
  "1" \
  occurrences "${LOG_HEADER}" "tool.sh image system.json"

# stderr of the script and of the programs it starts is logged too. It is the
# half that carries the failure, and the half that must not reach the terminal.
LOG_ERR="${WORK}/err.build.log"
expect "log: stderr of a called program does not reach the terminal" \
  "" \
  terminal_err_of "log_init '${LOG_ERR}'; ls /definitely-not-here"

expect "log: stderr of a called program is in the log" \
  "1" \
  occurrences "${LOG_ERR}" "definitely-not-here"

# 'set -x' is the reason the log is worth keeping: it stays on and lands there.
LOG_TRACE="${WORK}/trace.build.log"
expect "log: the trace does not reach the terminal" \
  "" \
  terminal_err_of "log_init '${LOG_TRACE}'; set -x; true onetraced"

expect "log: the trace is in the log" \
  "1" \
  occurrences "${LOG_TRACE}" "true onetraced"

expect "log: a traced line carries a second count" \
  "1" \
  occurrences "${LOG_TRACE}" "^+ [0-9]\+s "

# A second log_init does not move an open log.
LOG_FIRST="${WORK}/first.build.log"
terminal_of "log_init '${LOG_FIRST}'; log_init '${WORK}/second.build.log'; echo kept" >/dev/null
expect "log: a second log_init is ignored" \
  "1" \
  occurrences "${LOG_FIRST}" "kept"

expect_rc "log: the second log file is not created" \
  1 \
  test -f "${WORK}/second.build.log"

# An unwritable path costs the log, not the build. A regular file as the parent
# directory, so that the case holds for root as well - anything merely
# non-existent is one mkdir away.
: >"${WORK}/not-a-directory"
expect "log: an unwritable log leaves the output on the terminal" \
  "noise
==> building" \
  terminal_of "log_init '${WORK}/not-a-directory/x.log'; echo noise; step 'building'"

# --- DEBUG=1 turns the whole mechanism off -----------------------------------

LOG_DEBUG="${WORK}/debug.build.log"
expect "DEBUG=1: the noise is on the terminal" \
  "noise
==> building" \
  terminal_of "DEBUG=1 log_init '${LOG_DEBUG}'; echo noise; step 'building'"

expect_rc "DEBUG=1: no log file is written" \
  1 \
  test -f "${LOG_DEBUG}"

# --- failure ----------------------------------------------------------------

LOG_FAIL="${WORK}/fail.build.log"
expect "failure: log_error reaches the terminal" \
  "Error: it broke" \
  terminal_err_of "log_init '${LOG_FAIL}'; log_error 'it broke'"

expect "failure: log_error is in the log as well" \
  "1" \
  occurrences "${LOG_FAIL}" "Error: it broke"

LOG_TAILED="${WORK}/tailed.build.log"
expect "failure: log_tail shows the end of the log and its path" \
  "--- last 30 lines of ${LOG_TAILED} ---
the last thing that happened
--- full output: ${LOG_TAILED} ---" \
  terminal_err_of "log_init '${LOG_TAILED}'; echo 'the last thing that happened'; log_tail"

expect "failure: log_tail prints once, however often it is called" \
  "1" \
  tails_shown "log_init '${WORK}/once.build.log'; echo line; log_tail; log_tail"

# The trap form: a command that dies on its own leaves its reason in the log,
# and log_exit is what puts it on the terminal.
expect "failure: log_exit tails on a non-zero exit" \
  "1" \
  tails_shown "
    trap log_trap_exit EXIT
    log_init '${WORK}/trap.build.log'
    ls /definitely-not-here
    exit 1
  "

expect "failure: log_exit stays quiet on a clean exit" \
  "0" \
  tails_shown "
    trap log_trap_exit EXIT
    log_init '${WORK}/clean.build.log'
    echo fine
    exit 0
  "

# --- durations --------------------------------------------------------------

expect "elapsed: seconds" "42s"   log_elapsed 42
expect "elapsed: minutes" "4m12s" log_elapsed 252
expect "elapsed: hours"   "1h04m" log_elapsed 3840
expect "elapsed: zero"    "0s"    log_elapsed 0

# --- passing on the step lines of a nested run -------------------------------

expect "nested: a step line of another program is indented, not rewritten" \
  "  ==> partitioning" \
  terminal_of 'nested_step "==> partitioning"'

LOG_NESTED="${WORK}/nested.build.log"
expect "nested: and it is in the log as well" \
  "  ==> partitioning" \
  terminal_of "log_init '${LOG_NESTED}'; nested_step '==> partitioning'"

expect "nested: the log has it too" \
  "  ==> partitioning" \
  log_of "${LOG_NESTED}"

# --- recognising another program's step lines --------------------------------

expect_rc "step line: a plain one" 0 log_is_step_line "==> building"
expect_rc "step line: an indented one" 0 log_is_step_line "  ==> partitioning"
expect_rc "step line: a tab-indented one" 0 log_is_step_line "	==> partitioning"
expect_rc "step line: the marker must be followed by a space" 1 \
  log_is_step_line "==>nope"
expect_rc "step line: not a traced line that mentions the marker" 1 \
  log_is_step_line "+ echo '==> not a step'"
expect_rc "step line: not ordinary output" 1 \
  log_is_step_line "Setting up libc6:amd64 ..."
expect_rc "step line: not an empty line" 1 log_is_step_line ""

summary
