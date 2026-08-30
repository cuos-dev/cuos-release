#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# The same helper as cuos/system/cuos/lib-test.sh. The two repositories share no
# code, so it is vendored rather than included; keep them identical.

export TEST=1

pass=0; fail=0
expect() {
  local label="$1"; shift
  local EXPECTED="$1"; shift
  local GOT
  GOT="$("$@")" || true
  if [ "$GOT" = "$EXPECTED" ]; then
    printf 'OK   %s\n' "$label"
    pass=$((pass+1))
  else
    printf 'FAIL %s\n  got:      %q\n  expected: %q\n' "$label" "$GOT" "$EXPECTED"
    fail=$((fail+1))
  fi
}
expect_rc() {
  local label="$1"; shift
  local EXPECTED="$1"; shift
  local GOT
  "$@" >/dev/null
  GOT="$?"
  if [ "$GOT" = "$EXPECTED" ]; then
    printf 'OK   %s\n' "$label"
    pass=$((pass+1))
  else
    printf 'FAIL %s\n  got:      %q\n  expected: %q\n' "$label" "$GOT" "$EXPECTED"
    fail=$((fail+1))
  fi
}

summary() {
  printf '\nSummary: %d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ] || exit 1
}

