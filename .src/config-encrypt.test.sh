#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# config-encrypt.sh, config-decrypt.sh and config-decrypt-all.sh: the round
# trip, where the passphrase is looked for, and what happens when it is the
# wrong one.

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASSPHRASE="correct horse battery staple"
OTHER="wrong horse battery staple"

# openssl is loud about a failed decrypt, and that noise belongs to the case.
quietly() {
  "$@" >/dev/null 2>&1
}

encrypt() {
  quietly env IAC_FILE_PASSPHRASE="${PASSPHRASE}" "${SCRIPT_DIR}/config-encrypt.sh" "$@"
}

decrypt() {
  quietly env IAC_FILE_PASSPHRASE="${PASSPHRASE}" "${SCRIPT_DIR}/config-decrypt.sh" "$@"
}

# A directory holding one secret file, already encrypted, with the plaintext
# removed unless the case wants it.
new_secret() {
  local dir
  dir="$(mktemp -d "${TMP}/case.XXXXXX")"
  printf 'TOKEN=hunter2\n' >"${dir}/.env"
  encrypt "${dir}/.env"
  printf '%s' "${dir}"
}

contents_of() {
  cat "$1" 2>/dev/null
}

# Empty unless the file exists and holds the secret - the assertion for a
# decrypt that must not have worked.
grep_of() {
  grep -F -- "$2" "$1" 2>/dev/null || true
}

occurrences() {
  grep -c -- "$2" "$1" 2>/dev/null || true
}

# Only what config-decrypt-all claims in the exclude file. What surrounds it is
# git's template and whatever the person put there, and is asserted separately.
block_of() {
  sed -n '/^# BEGIN cuos config-decrypt$/,/^# END cuos config-decrypt$/p' "$1" \
    2>/dev/null
}

# --- the round trip ----------------------------------------------------------

ROUND="$(new_secret)"

expect_rc "encrypt: the ciphertext is written beside the plaintext" 0 \
  test -f "${ROUND}/.env.enc"

# It encrypts, it does not replace - the plaintext staying is why a forgotten
# re-encrypt silently commits the old secret.
expect_rc "encrypt: the plaintext is left in place" 0 test -f "${ROUND}/.env"

expect_rc "encrypt: the ciphertext is not the plaintext" 1 \
  quietly grep -qF "hunter2" "${ROUND}/.env.enc"

rm -f "${ROUND}/.env"
decrypt "${ROUND}/.env.enc"
expect "decrypt: the plaintext comes back" "TOKEN=hunter2" contents_of "${ROUND}/.env"

# Either name reaches the same pair.
NAMED="$(new_secret)"
rm -f "${NAMED}/.env"
decrypt "${NAMED}/.env"
expect "decrypt: the name may be given without .enc" "TOKEN=hunter2" \
  contents_of "${NAMED}/.env"

# --- a missing file ----------------------------------------------------------

expect_rc "encrypt: a file that is not there" 1 encrypt "${TMP}/nothing-here"
expect_rc "decrypt: a ciphertext that is not there" 1 decrypt "${TMP}/nothing-here.enc"

# Only the suffix is dropped when the plaintext's name is worked out. Removing
# ".enc" wherever it occurred turned "a.encoded.enc" into "aoded".
ODD="$(mktemp -d "${TMP}/odd.XXXXXX")"
printf 'TOKEN=hunter2\n' >"${ODD}/a.encoded"
encrypt "${ODD}/a.encoded"
rm -f "${ODD}/a.encoded"
decrypt "${ODD}/a.encoded.enc"
expect "decrypt: only the suffix is dropped from the name" "TOKEN=hunter2" \
  contents_of "${ODD}/a.encoded"

# --- the wrong passphrase ----------------------------------------------------
#
# Asserted on the content, not on the exit code: openssl checks only the final
# block's padding, so about one wrong key in 256 exits 0 with garbage. What has
# to hold either way is that the secret does not come out.

WRONG="$(new_secret)"
rm -f "${WRONG}/.env"
quietly env IAC_FILE_PASSPHRASE="${OTHER}" "${SCRIPT_DIR}/config-decrypt.sh" "${WRONG}/.env.enc"

expect "decrypt: the wrong passphrase does not yield the secret" "" \
  grep_of "${WRONG}/.env" "hunter2"

# --- a plaintext that is newer is kept ---------------------------------------
#
# What protects local edits from a config-decrypt-all, and what makes a stale
# plaintext outlive an .enc someone else updated.

NEWER="$(new_secret)"
printf 'TOKEN=my-local-edit\n' >"${NEWER}/.env"
touch -d '2030-01-01' "${NEWER}/.env"
touch -d '2020-01-01' "${NEWER}/.env.enc"
expect_rc "decrypt: a newer plaintext is left alone" 0 decrypt "${NEWER}/.env.enc"
expect "decrypt: and it still holds the local edit" "TOKEN=my-local-edit" \
  contents_of "${NEWER}/.env"

OLDER="$(new_secret)"
printf 'TOKEN=stale\n' >"${OLDER}/.env"
touch -d '2020-01-01' "${OLDER}/.env"
touch -d '2030-01-01' "${OLDER}/.env.enc"
decrypt "${OLDER}/.env.enc"
expect "decrypt: an older plaintext is replaced" "TOKEN=hunter2" contents_of "${OLDER}/.env"

# --- where the passphrase is looked for --------------------------------------

# The environment wins over everything on disk.
ENVWINS="$(new_secret)"
rm -f "${ENVWINS}/.env"
printf '%s\n' "${OTHER}" >"${ENVWINS}/system_file_password.txt"
( cd "${ENVWINS}" && quietly env IAC_FILE_PASSPHRASE="${PASSPHRASE}" \
  "${SCRIPT_DIR}/config-decrypt.sh" .env.enc )
expect "passphrase: the environment beats the password file" "TOKEN=hunter2" \
  contents_of "${ENVWINS}/.env"

# config-encrypt searches upwards, so a person can work inside a subdirectory
# of the configuration repository. A plaintext to encrypt is enough to see how
# far it reaches.
#
# Nothing to read from stdin, so an unfound passphrase ends the run rather than
# waiting for someone to type one.
encrypt_at_depth() {
  local depth="$1"
  local dir work
  dir="$(mktemp -d "${TMP}/up.XXXXXX")"
  work="${dir}$(printf '/d%.0s' $(seq 1 "${depth}"))"
  mkdir -p "${work}"
  printf 'TOKEN=hunter2\n' >"${work}/.env"
  printf '%s\n' "${PASSPHRASE}" >"${dir}/system_file_password.txt"
  ( cd "${work}" && "${SCRIPT_DIR}/config-encrypt.sh" .env </dev/null ) >/dev/null 2>&1
  test -f "${work}/.env.enc"
}

expect_rc "passphrase: encrypt finds the password file in this directory" 0 encrypt_at_depth 0
expect_rc "passphrase: encrypt finds it one level up" 0 encrypt_at_depth 1
expect_rc "passphrase: encrypt finds it two levels up" 0 encrypt_at_depth 2
expect_rc "passphrase: encrypt does not look three levels up" 1 encrypt_at_depth 3

# config-decrypt does not search upwards - only this directory. The asymmetry
# is why config-decrypt-all, which does search, is the command to reach for
# after a clone.
NEAR="$(new_secret)"
rm -f "${NEAR}/.env"
printf '%s\n' "${PASSPHRASE}" >"${NEAR}/system_file_password.txt"
( cd "${NEAR}" && quietly "${SCRIPT_DIR}/config-decrypt.sh" .env.enc )
expect "passphrase: decrypt finds the password file in this directory" "TOKEN=hunter2" \
  contents_of "${NEAR}/.env"

FAR="$(new_secret)"
rm -f "${FAR}/.env"
mkdir -p "${FAR}/d"
mv "${FAR}/.env.enc" "${FAR}/d/.env.enc"
printf '%s\n' "${PASSPHRASE}" >"${FAR}/system_file_password.txt"
expect_rc "passphrase: decrypt does not look one level up" 3 \
  bash -c "cd '${FAR}/d' && '${SCRIPT_DIR}/config-decrypt.sh' .env.enc </dev/null" \
  2>/dev/null

# system_secrets.json is the fallback, so a clone that has been decrypted once
# keeps working without the password file.
FALLBACK="$(new_secret)"
rm -f "${FALLBACK}/.env"
printf '{"system_file_password":"%s"}\n' "${PASSPHRASE}" >"${FALLBACK}/system_secrets.json"
( cd "${FALLBACK}" && quietly "${SCRIPT_DIR}/config-decrypt.sh" .env.enc )
expect "passphrase: system_secrets.json is the fallback" "TOKEN=hunter2" \
  contents_of "${FALLBACK}/.env"

# --- config-decrypt-all ------------------------------------------------------

ALL="$(mktemp -d "${TMP}/all.XXXXXX")"
git -C "${ALL}" init -q
mkdir -p "${ALL}/iac/certs"
printf 'TOKEN=hunter2\n' >"${ALL}/iac/.env"
printf 'KEY=private\n' >"${ALL}/iac/certs/server.key"
encrypt "${ALL}/iac/.env"
encrypt "${ALL}/iac/certs/server.key"
rm -f "${ALL}/iac/.env" "${ALL}/iac/certs/server.key"
printf '%s\n' "${PASSPHRASE}" >"${ALL}/system_file_password.txt"
( cd "${ALL}" && quietly "${SCRIPT_DIR}/config-decrypt-all.sh" )

expect "decrypt-all: a file at the top" "TOKEN=hunter2" contents_of "${ALL}/iac/.env"
expect "decrypt-all: and one further down" "KEY=private" \
  contents_of "${ALL}/iac/certs/server.key"

# The plaintexts it just created must not be committable by accident, wherever
# they are and whether or not a .gitignore covers them.
# Anchored and without find's "./", or git matches none of them - which is what
# the assertion after it actually proves.
expect "decrypt-all: every plaintext is excluded from the clone" \
  "# BEGIN cuos config-decrypt
/iac/.env
/iac/certs/server.key
# END cuos config-decrypt" \
  block_of "${ALL}/.git/info/exclude"

# git puts a commented template in that file when it creates the repository.
expect "decrypt-all: git's own template is left alone" "1" \
  occurrences "${ALL}/.git/info/exclude" "^# Lines that start with"

expect "decrypt-all: git sees only the ciphertexts" \
  "?? iac/.env.enc
?? iac/certs/server.key.enc
?? system_file_password.txt" \
  git -C "${ALL}" status --short --untracked-files=all

# The exclude file is the clone's, not this command's: what someone put there
# by hand survives, and a second run does not stack block on block.
KEEP="$(mktemp -d "${TMP}/keep.XXXXXX")"
git -C "${KEEP}" init -q
mkdir -p "${KEEP}/iac"
printf 'TOKEN=hunter2\n' >"${KEEP}/iac/.env"
encrypt "${KEEP}/iac/.env"
rm -f "${KEEP}/iac/.env"
printf '%s\n' "${PASSPHRASE}" >"${KEEP}/system_file_password.txt"
printf '/scratch.md\n' >"${KEEP}/.git/info/exclude"
( cd "${KEEP}" && quietly "${SCRIPT_DIR}/config-decrypt-all.sh" )
( cd "${KEEP}" && quietly "${SCRIPT_DIR}/config-decrypt-all.sh" )

expect "decrypt-all: an entry of one's own survives two runs" \
  "/scratch.md
# BEGIN cuos config-decrypt
/iac/.env
# END cuos config-decrypt" \
  contents_of "${KEEP}/.git/info/exclude"

expect "decrypt-all: and the block is written once, not stacked" "1" \
  occurrences "${KEEP}/.git/info/exclude" "^# BEGIN cuos config-decrypt$"

NOPASS="$(mktemp -d "${TMP}/nopass.XXXXXX")"
git -C "${NOPASS}" init -q
expect_rc "decrypt-all: without a passphrase it stops" 1 \
  bash -c "cd '${NOPASS}' && '${SCRIPT_DIR}/config-decrypt-all.sh' </dev/null" \
  2>/dev/null

summary
