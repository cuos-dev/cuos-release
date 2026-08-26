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

if [[ -f "${system_secrets_file}.enc" ]]; then
  echo "System secrets file existing." >&2
  exit 3
fi

system_secrets_file="${CONFIG_DIR}/system_secrets.json"
system_secrets_file="$(echo "${system_secrets_file}" | sed -e 's/^\.\///g')"
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

  SYSTEM_FILE_PASSWORD="$(openssl rand "$((L*8))" | tr -dc 'A-Za-z0-9._-+' | fold -w "$L" | head -n1)"
  echo "${SYSTEM_FILE_PASSWORD}" >"${system_file_password_file}"

  jq_set \
    --arg pass "${SYSTEM_FILE_PASSWORD}" \
    '.system_file_password = $pass' \
    "${system_secrets_file}"
}

# encrypt secret files:
"${SCRIPT_DIR}/config-encrypt.sh" "${system_secrets_file}"

echo "${system_file_password_file}" >>"${CONFIG_DIR}/.gitignore"
echo "${system_secrets_file}" >>"${CONFIG_DIR}/.gitignore"

cat <<EOF
Please encrypt "${system_file_password_file}" e.g. via gpg
EOF
