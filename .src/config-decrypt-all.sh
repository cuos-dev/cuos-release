#!/bin/bash

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

enc_files="$(find . -type f -iname \*.enc | \
  sed -e 's/\.enc$//g')"

echo "${enc_files}" >"${exclude_file}"

