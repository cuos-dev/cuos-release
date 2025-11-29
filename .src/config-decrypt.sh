#!/bin/bash

file="$1"
file="${file//.enc/}"
encfile="${file}.enc"

if test ! -f "${encfile}"; then
  echo "File not found." >&2
  exit 1
fi
if [[ "${file}" = "${encfile}" ]]; then
  echo "File and encfile are the same." >&2
  exit 4
fi

if [[ -f "${file}" && "${file}" -nt "${encfile}" ]]; then
  #echo "File already decrypted." >&2
  exit 0
fi
rm -f -- "${file}"


if [[ -z "${IAC_FILE_PASSPHRASE}" ]]; then
  system_file_password_file="./system_file_password.txt"
  system_secrets_file='./system_secrets.json'
  if [[ -f "${system_file_password_file}" ]]; then
    IAC_FILE_PASSPHRASE="$(cat "${system_file_password_file}")"
  elif [[ -f "${system_secrets_file}" ]]; then
    IAC_FILE_PASSPHRASE="$(jq -r '.system_file_password' "${system_secrets_file}")"
  else
    echo -n "Please insert iac-file-passphrase:"
    read -r IAC_FILE_PASSPHRASE
  fi
  if [[ -z "${IAC_FILE_PASSPHRASE}" ]]; then
    echo "No password defined."
    exit 3
  fi
fi

if ! openssl enc \
    -d \
    -aes-256-cbc \
    -pbkdf2 \
    -iter 200000 \
    -in "${encfile}" \
    -out "${file}" \
    -pass pass:"${IAC_FILE_PASSPHRASE}"; then
  echo "Warning: Can not decrypt ${encfile}" >&2
  rm -f -- "${file}"
  exit 2
fi

