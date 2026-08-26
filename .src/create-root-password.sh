#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

show_help() {
  echo "Usage: tool.sh root-password [-w system.json]"
  echo
  echo "Without arguments: Enter password and show hash."
  echo "-w system.json  - write password to json file"
  echo "-g              - generate random password"
  # field: os_root_password
  echo "-r              - password for os_root_password"
  # field: console_password
  echo "-c              - password for console_password"
  # field: console_expert_password
  echo "-e              - password for console_expert_password"
}

jq_set() {
  # Usage: jq_replace jq_expression file
  # like jq, but with inplace edit function
  local args=("$@")
  local file="${!#}"
  unset 'args[-1]'

  local new_config
  new_config="$(jq "${args[@]}" "${file}")" || exit "$?"
  echo "${new_config}" >"${file}"
}

generate_password() {
  local L="${PASSWORD_LENGTH:-"20"}"
  {
    export LC_CTYPE=C
    export LC_ALL=C
    export LANG=C

    root_password="$(openssl rand "$((L*8))" | tr -dc 'A-Xa-x0-9!$%' | fold -w "$L" | head -n1)"
    echo "${root_password}"
  }
}

password_hint() {
  echo "Please be aware, that you might need to enter it via an english keyboard on a console within 30secs."

  echo "Password Suggestion: $(generate_password)"

  echo "Please enter a password:"
}

key="os_root_password"
generate_password=0
system_config=""

while getopts "rcegw:h" opt; do
  case "$opt" in
    r) key="os_root_password" ;;
    c) key="console_password" ;;
    e) key="console_expert_password" ;;
    g) generate_password=1 ;;
    w) system_config="$OPTARG" ;;
    h) show_help; exit 2 ;;
    *) show_help; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if ! command -v openssl >/dev/null 2>&1; then
  echo "Needed tools are not availbale Please install openssl" >&2
  exit 1
fi

if [[ "${generate_password}" == "1" ]]; then
  root_password="$(generate_password)"
  echo "${key}: ${root_password}"
  root_salt="$(openssl rand -base64 12 | tr '+/' './' | cut -c1-16)"
  root_hash="$(echo -n "${root_password}" | openssl passwd -6 -salt "$root_salt" -stdin)"

  unset root_password
else
  password_hint
  root_salt="$(openssl rand -base64 12 | tr '+/' './' | cut -c1-16)"
  root_hash="$(openssl passwd -6 -salt "$root_salt")"
fi


if [[ -n "${system_config}" ]]
then
  jq_set \
    --arg key "${key}" \
    --arg password "${root_hash}" \
    '.[$key] = $password' \
    "${system_config}"
else
  jq -n \
    --arg key "${key}" \
    --arg password "${root_hash}" \
    '.[$key] = $password'
fi

