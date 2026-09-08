#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# One output convention for the build tooling: a few readable step lines on the
# terminal, the complete technical output in a log file beside the artefact.
#
# log_init moves this shell's stdout and stderr into the log file. Everything
# printed from then on is logged rather than displayed - by this script, by the
# programs it starts, and by the tracing of 'set -x', none of which have to know
# about it. The terminal is kept on descriptors 3 and 4, and 'step' and
# 'log_error' write there, so they are the only output a person sees.
#
# DEBUG=1 skips all of it: no log file, no redirection, every line on the
# terminal.
#
# The factory containers in 'cuos' do not use this file - they only mark their
# own step lines with LOG_STEP_MARKER, and tool.sh sorts their output out from
# the outside (run_factory). The marker is therefore the whole of the contract
# between the two repositories; log_is_step_line below is this side of it.

# The terminal, before log_init redirects anything. Taken unconditionally so
# that the writers below need no case distinction: without a log file, fd 3 and
# fd 1 are the same thing.
exec 3>&1 4>&2

LOG_FILE=""
LOG_TAIL_LINES=30
LOG_TAIL_SHOWN=0

# What marks a line as meant for a person. Shared with the factory scripts in
# 'cuos', which print it themselves, so it is not a detail of 'step'.
LOG_STEP_MARKER="==>"

# Traced lines carry their origin and a second count. $SECONDS is a builtin, so
# this costs no process per line - a timestamp via date(1) would, and a full
# build traces a lot of lines.
export PS4='+ ${SECONDS}s ${BASH_SOURCE:+${BASH_SOURCE##*/}:${LINENO}: }'

# Open the log and send everything but the step lines into it. Appends, so that
# a caller which has already written a header keeps it. Truncating is the
# caller's business.
#
# Usage: log_init PATH [what is being run]
log_init() {
  local path="$1"
  shift

  if [[ -n "${LOG_FILE}" ]]; then
    return 0
  fi
  if [[ "${DEBUG:-}" == "1" ]]; then
    return 0
  fi
  if [[ -z "${path}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "${path}")" 2>/dev/null || true
  # Tested in a subshell: a failing redirection on 'exec' terminates a
  # non-interactive shell, and an unwritable log is not a reason to fail a
  # build. It only means the output stays where it is.
  if ! (: >>"${path}") 2>/dev/null; then
    return 0
  fi

  LOG_FILE="${path}"
  exec >>"${path}" 2>&1

  if [[ -n "$*" ]]; then
    printf -- '=== %s | %s ===\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"
  fi
}

# The path of the log, empty while none is open. For a caller that wants to name
# it in its own closing line.
log_path() {
  printf '%s' "${LOG_FILE}"
}

# One step of the work, in the terminal and in the log.
step() {
  printf '%s %s\n' "${LOG_STEP_MARKER}" "$*" >&3
  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s %s\n' "${LOG_STEP_MARKER}" "$*"
  fi
}

# One step of a nested run, indented so that it is visibly not this script's.
# Takes a line the other program already marked, and passes it on as it is.
nested_step() {
  printf '%s%s\n' "${LOG_STEP_INDENT}" "$1" >&3
  if [[ -n "${LOG_FILE}" ]]; then
    printf '%s%s\n' "${LOG_STEP_INDENT}" "$1"
  fi
}
LOG_STEP_INDENT="  "

# Whether a line another program produced is one of its step lines. Anchored,
# and leading whitespace is allowed, because a program may indent its own: a
# traced line that happens to contain the marker somewhere is not a step line.
log_is_step_line() {
  [[ "$1" =~ ^[[:space:]]*"${LOG_STEP_MARKER}"[[:space:]] ]]
}

# An error, in the terminal and in the log.
log_error() {
  printf 'Error: %s\n' "$*" >&4
  if [[ -n "${LOG_FILE}" ]]; then
    printf 'Error: %s\n' "$*"
  fi
}

# The end of the log on the terminal, plus its path. Quiet must not mean
# uninformative: this is what a failing run shows instead of asking for a
# re-run. Printed at most once.
log_tail() {
  # Tracing off, and not turned back on: this runs on the way out, and its own
  # trace would land in the log a moment before tail(1) reads it - filling the
  # tail with this function instead of with the cause.
  set +x

  if [[ -z "${LOG_FILE}" ]]; then
    return 0
  fi
  if [[ "${LOG_TAIL_SHOWN}" == "1" ]]; then
    return 0
  fi
  LOG_TAIL_SHOWN=1

  {
    printf -- '--- last %s lines of %s ---\n' "${LOG_TAIL_LINES}" "${LOG_FILE}"
    tail -n "${LOG_TAIL_LINES}" "${LOG_FILE}"
    printf -- '--- full output: %s ---\n' "${LOG_FILE}"
  } >&4
}

# Catches what log_error does not: a command that died on its own, with its
# reason in the log and nothing on the terminal.
log_exit() {
  if [[ "${1:-0}" != "0" ]]; then
    log_tail
  fi
}

# For 'trap log_trap_exit EXIT'. A function rather than an inline
# 'log_exit "$?"', because the pending status has to be taken before anything
# else in the trap runs - and because a trap string that has to survive its own
# quoting is how the wrong status gets passed.
log_trap_exit() {
  local rc=$?
  set +x
  log_exit "${rc}"
}

# Seconds as a human reads them: 42s, 4m12s, 1h04m.
log_elapsed() {
  local total="${1:-0}"
  local h=$((total / 3600))
  local m=$(((total % 3600) / 60))
  local s=$((total % 60))

  if ((h > 0)); then
    printf '%dh%02dm' "${h}" "${m}"
  elif ((m > 0)); then
    printf '%dm%02ds' "${m}" "${s}"
  else
    printf '%ds' "${s}"
  fi
}
