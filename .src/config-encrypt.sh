#!/bin/bash

file="$1"

if test ! -f "${file}"; then
  echo "File not found." >&2
  exit 1
fi

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


openssl enc \
  -e \
  -aes-256-cbc \
  -pbkdf2 \
  -iter 200000 \
  -salt \
  -in "${file}" \
  -out "${file}.enc" \
  -pass pass:"${IAC_FILE_PASSPHRASE}"

