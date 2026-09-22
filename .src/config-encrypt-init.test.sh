#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# config-encrypt-init.sh is run, not sourced: it is a command with side effects
# on a directory, and what it leaves behind is the subject.

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A repository holding one configuration, at the root or in a subdirectory.
# Printed, so a case can name the directory it just made.
new_repo() {
  local sub="${1:-}"
  local dir
  dir="$(mktemp -d "${TMP}/repo.XXXXXX")"
  git -C "${dir}" init -q
  mkdir -p "${dir}/${sub}"
  echo '{"hostname":"gateway-01"}' >"${dir}/${sub:-.}/system.json"
  printf '%s' "${dir}"
}

# The command under test, run from the repository root as a person would.
init() {
  local dir="$1"; shift
  ( cd "${dir}" && "${SCRIPT_DIR}/config-encrypt-init.sh" "$@" ) >/dev/null 2>&1
}

lines_of() {
  cat "$1" 2>/dev/null
}

# openssl is loud about a failed decrypt, and that noise belongs to the case,
# not to the terminal.
quietly() {
  "$@" >/dev/null 2>&1
}

occurrences() {
  grep -c -- "$2" "$1" 2>/dev/null || true
}

length_of() {
  local value
  value="$(cat "$1" 2>/dev/null)"
  printf '%s' "${#value}"
}

# --- the configuration has to be there first ---------------------------------

EMPTY="$(mktemp -d "${TMP}/empty.XXXXXX")"
expect_rc "no system.json: refused" 1 init "${EMPTY}"

# --- what a run leaves behind ------------------------------------------------

ROOT="$(new_repo)"
expect_rc "root: the run succeeds" 0 init "${ROOT}"

expect_rc "root: the passphrase file is written" 0 test -f "${ROOT}/system_file_password.txt"
expect_rc "root: the secrets file is written" 0 test -f "${ROOT}/system_secrets.json"
expect_rc "root: the secrets are encrypted" 0 test -f "${ROOT}/system_secrets.json.enc"

expect "root: the secrets are included by the configuration" \
  "./system_secrets.json" \
  jq -r '."#include"[0]' "${ROOT}/system.json"

expect "root: both plaintexts are ignored, anchored and without a directory" \
  "/system_file_password.txt
/system_secrets.json" \
  lines_of "${ROOT}/.gitignore"

# The passphrase generator once fed tr a reversed range and produced nothing at
# all, which left an empty file and an unopenable .enc. Length is the assertion
# that catches that, and the script now refuses rather than writing a short one.
expect "root: the passphrase is 25 characters" "25" length_of "${ROOT}/system_file_password.txt"

expect "root: the secrets carry the same passphrase" \
  "$(cat "${ROOT}/system_file_password.txt")" \
  jq -r '.system_file_password' "${ROOT}/system_secrets.json"

# The encrypted form has to open with the passphrase that was just generated -
# the one thing the whole mechanism rests on.
rm -f "${ROOT}/system_secrets.json"
( cd "${ROOT}" && "${SCRIPT_DIR}/config-decrypt.sh" system_secrets.json ) >/dev/null 2>&1
expect "root: the encrypted secrets open again" \
  "$(cat "${ROOT}/system_file_password.txt")" \
  jq -r '.system_file_password' "${ROOT}/system_secrets.json"

# --- PASSWORD_LENGTH ---------------------------------------------------------

SHORT="$(new_repo)"
PASSWORD_LENGTH=8 init "${SHORT}"
expect "PASSWORD_LENGTH: honoured" "8" length_of "${SHORT}/system_file_password.txt"

# --- a configuration in a subdirectory ---------------------------------------
#
# The case a repository of several systems is made of, and the one where the
# paths used to go wrong in both directions: the ignore entries carried the
# directory into the .gitignore that was already in it, and the encrypt step
# could not find the passphrase file that had just been written beside the
# configuration.

SUB="$(new_repo systems/gateway-01)"
expect_rc "subdirectory: the run succeeds" 0 init "${SUB}" systems/gateway-01/system.json

expect_rc "subdirectory: the secrets are encrypted" 0 \
  test -f "${SUB}/systems/gateway-01/system_secrets.json.enc"

expect "subdirectory: the ignore entries name the files, not the path to them" \
  "/system_file_password.txt
/system_secrets.json" \
  lines_of "${SUB}/systems/gateway-01/.gitignore"

expect_rc "subdirectory: no .gitignore at the repository root" 1 test -f "${SUB}/.gitignore"

expect "subdirectory: git ignores the plaintexts" \
  "?? systems/gateway-01/.gitignore
?? systems/gateway-01/system.json
?? systems/gateway-01/system_secrets.json.enc" \
  git -C "${SUB}" status --short --untracked-files=all

# --- every system gets its own passphrase ------------------------------------

TWO="$(new_repo systems/a)"
mkdir -p "${TWO}/systems/b"
echo '{"hostname":"b"}' >"${TWO}/systems/b/system.json"
init "${TWO}" systems/a/system.json
init "${TWO}" systems/b/system.json

expect_rc "two systems: the passphrases differ" 1 \
  cmp -s "${TWO}/systems/a/system_file_password.txt" \
         "${TWO}/systems/b/system_file_password.txt"

# What the separation is worth: B's passphrase does not yield A's secret.
#
# Asserted on the content rather than on the exit code, because openssl checks
# only the final block's padding: about one wrong key in 256 happens to produce
# valid padding and exits 0 with garbage. Rare enough never to matter in use,
# common enough to make an exit-code assertion flaky in CI. What has to hold
# either way is that A's passphrase does not come out.
A_PASSPHRASE="$(cat "${TWO}/systems/a/system_file_password.txt")"

b_reads_a() {
  rm -f "${TWO}/systems/a/system_secrets.json"
  quietly env IAC_FILE_PASSPHRASE="$(cat "${TWO}/systems/b/system_file_password.txt")" \
    "${SCRIPT_DIR}/config-decrypt.sh" "${TWO}/systems/a/system_secrets.json.enc"
  grep -F "${A_PASSPHRASE}" "${TWO}/systems/a/system_secrets.json" 2>/dev/null || true
}

expect "two systems: one cannot read the other's secrets" "" b_reads_a

# --- an existing .gitignore is added to, not replaced -------------------------

KEEP="$(new_repo)"
# No trailing newline: appending to it used to join the first entry onto the
# last line that was already there.
printf 'output/\nnode_modules/' >"${KEEP}/.gitignore"
init "${KEEP}"
expect "existing .gitignore: kept, and the entries are on their own lines" \
  "output/
node_modules/
/system_file_password.txt
/system_secrets.json" \
  lines_of "${KEEP}/.gitignore"

DUPE="$(new_repo)"
printf '/system_secrets.json\n' >"${DUPE}/.gitignore"
init "${DUPE}"
expect "existing .gitignore: an entry already there is not repeated" \
  "1" \
  occurrences "${DUPE}/.gitignore" "^/system_secrets\.json$"

# --- an existing #include is added to ----------------------------------------

INC="$(new_repo)"
echo '{"#include":["cuos-release/release.json"],"hostname":"a"}' >"${INC}/system.json"
init "${INC}"
expect "existing #include: the secrets are appended to it" \
  "cuos-release/release.json
./system_secrets.json" \
  jq -r '."#include"[]' "${INC}/system.json"

# --- existing secrets are not thrown away ------------------------------------

HAS="$(new_repo)"
echo '{"api_token":"already here"}' >"${HAS}/system_secrets.json"
init "${HAS}"
expect "existing secrets: kept" "already here" \
  jq -r '.api_token' "${HAS}/system_secrets.json"
expect "existing secrets: the passphrase is added beside them" \
  "$(cat "${HAS}/system_file_password.txt")" \
  jq -r '.system_file_password' "${HAS}/system_secrets.json"

# --- it does not run a second time -------------------------------------------
#
# Both guards exist for the same reason: a second passphrase over files
# encrypted with the first leaves nothing that can be opened again.

AGAIN="$(new_repo)"
init "${AGAIN}"
expect_rc "second run: refused while the passphrase file is there" 2 init "${AGAIN}"

expect "second run: the passphrase is untouched" \
  "$(cat "${AGAIN}/system_file_password.txt")" \
  jq -r '.system_file_password' "${AGAIN}/system_secrets.json"

# The guard below it: the passphrase file is gone - deleted, or never fetched
# onto this machine - but the encrypted secrets are in the clone.
rm -f "${AGAIN}/system_file_password.txt"
expect_rc "second run: refused while encrypted secrets are there" 3 init "${AGAIN}"

expect_rc "second run: no new passphrase was written" 1 \
  test -f "${AGAIN}/system_file_password.txt"

summary
