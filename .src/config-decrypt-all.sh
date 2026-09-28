#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

system_file_password_file="./system_file_password.txt"
system_secrets_file='./system_secrets.json'
if [[ -n "${IAC_FILE_PASSPHRASE}" ]]; then
  :
elif [[ -f "${system_file_password_file}" ]]; then
  IAC_FILE_PASSPHRASE="$(cat "${system_file_password_file}")"
elif [[ -f "${system_secrets_file}" ]]; then
  IAC_FILE_PASSPHRASE="$(jq -r '.system_file_password' "${system_secrets_file}")"
else
  echo -n "Please insert iac-file-passphrase:"
  read -r IAC_FILE_PASSPHRASE
fi
if [[ -z "${IAC_FILE_PASSPHRASE}" ]]; then
  echo "No password defined."
  exit 1
fi
export IAC_FILE_PASSPHRASE


enc_files="$(find . -type f -iname \*.enc -exec "${SCRIPT_DIR}/config-decrypt.sh" "{}" ";")"


exclude_file="$(git rev-parse --git-dir)/info/exclude"

# Anchored at the repository root, and without the "./" find prints: git matches
# an exclude pattern against the path from the root, so "./iac/.env" matches
# nothing at all. Sorted, because find lists in the filesystem's order.
enc_files="$(find . -type f -iname \*.enc | \
  sed -e 's/\.enc$//' -e 's|^\./|/|' | LC_ALL=C sort)"

# The exclude file belongs to whoever works in this clone as well, so only the
# block between the markers is this command's to rewrite. Anything outside it -
# including an earlier block, which is removed first - is carried over.
exclude_begin="# BEGIN cuos config-decrypt"
exclude_end="# END cuos config-decrypt"

# git creates info/ only from its templates, and a clone can be without them.
mkdir -p "$(dirname "${exclude_file}")"

kept=""
if [[ -f "${exclude_file}" ]]; then
  kept="$(sed -e "/^${exclude_begin}\$/,/^${exclude_end}\$/d" "${exclude_file}")"
fi

{
  if [[ -n "${kept}" ]]; then
    echo "${kept}"
  fi
  echo "${exclude_begin}"
  if [[ -n "${enc_files}" ]]; then
    echo "${enc_files}"
  fi
  echo "${exclude_end}"
} >"${exclude_file}"

