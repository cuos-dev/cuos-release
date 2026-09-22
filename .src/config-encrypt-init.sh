#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

jq_set() {
  # Usage: jq_set jq_expression file
  # like jq, but with inplace edit function
  local args=("$@")
  local file="${!#}"
  unset 'args[-1]'

  local new_config
  new_config="$(jq "${args[@]}" "${file}")" || exit "$?"
  echo "${new_config}" >"${file}"
}

gitignore_add() {
  # Usage: gitignore_add pattern
  # Adds the pattern to CONFIG_DIR/.gitignore, once, on a line of its own
  local pattern="$1"
  local gitignore="${CONFIG_DIR}/.gitignore"

  if [[ -f "${gitignore}" ]]; then
    grep -qxF -- "${pattern}" "${gitignore}" && return 0
    if [[ -s "${gitignore}" && -n "$(tail -c1 "${gitignore}")" ]]; then
      echo >>"${gitignore}"
    fi
  fi

  echo "${pattern}" >>"${gitignore}"
}

CONFIG_PATH="${1:-"./system.json"}"
CONFIG_DIR="$(dirname "${CONFIG_PATH}")"

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "No system.json found" >&2
  exit 1
fi

system_file_password_file="${CONFIG_DIR}/system_file_password.txt"
system_file_password_file="$(echo "${system_file_password_file}" | sed -e 's/^\.\///g')"

if [[ -f "${system_file_password_file}" ]]; then
  echo "System file password existing." >&2
  exit 2
fi

system_secrets_file="${CONFIG_DIR}/system_secrets.json"
system_secrets_file="$(echo "${system_secrets_file}" | sed -e 's/^\.\///g')"

if [[ -f "${system_secrets_file}.enc" ]]; then
  echo "System secrets file existing." >&2
  exit 3
fi

if [[ ! -f "${system_secrets_file}" ]]; then
  echo '{}' >"${system_secrets_file}"

  jq_set \
    '."#include" += ["./system_secrets.json"]' \
    "${CONFIG_PATH}"
fi

L="${PASSWORD_LENGTH:-"25"}"

{
  export LC_CTYPE=C
  export LC_ALL=C
  export LANG=C

  # Only about a quarter of random bytes survive the filter, and how many is
  # itself random - one draw is not reliably enough for short passwords. Draw
  # again until there is enough to cut from.
  # The dash goes last, or tr reads "_-+" as a range and refuses.
  SYSTEM_FILE_PASSWORD=""
  for _ in 1 2 3 4 5; do
    SYSTEM_FILE_PASSWORD+="$(openssl rand "$((L*8))" | tr -dc 'A-Za-z0-9._+-')"
    if [[ "${#SYSTEM_FILE_PASSWORD}" -ge "$L" ]]; then
      break
    fi
  done
  SYSTEM_FILE_PASSWORD="${SYSTEM_FILE_PASSWORD:0:$L}"

  if [[ "${#SYSTEM_FILE_PASSWORD}" -ne "$L" ]]; then
    echo "Could not generate a password of ${L} characters." >&2
    exit 4
  fi

  echo "${SYSTEM_FILE_PASSWORD}" >"${system_file_password_file}"

  jq_set \
    --arg pass "${SYSTEM_FILE_PASSWORD}" \
    '.system_file_password = $pass' \
    "${system_secrets_file}"
}

# encrypt secret files:
# config-encrypt looks for the password file from the working directory, which
# is not where we just put it when the config lives in a subdirectory
IAC_FILE_PASSPHRASE="${SYSTEM_FILE_PASSWORD}" \
  "${SCRIPT_DIR}/config-encrypt.sh" "${system_secrets_file}"

gitignore_add "/system_file_password.txt"
gitignore_add "/system_secrets.json"

cat <<EOF
Please encrypt "${system_file_password_file}" e.g. via gpg
EOF
