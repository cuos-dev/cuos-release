#!/usr/bin/env bash

show_help() {
  echo "Usage: tool.sh root-password [-w system.json]"
  echo
  echo "Without arguments: Enter password and show hash."
  echo "-w system.json  - write password to json file"
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

password_hint() {
  echo "Please enter a password:"
  echo "Please be aware, that you might need to enter it via an english keyboard on a console within 30secs."

  if command -v openssl >/dev/null 2>&1; then
    {
      local L="${PASSWORD_LENGTH:-"20"}"
      export LC_CTYPE=C
      export LC_ALL=C
      export LANG=C

      root_password="$(openssl rand "$((L*8))" | tr -dc 'A-Xa-x0-9!$%' | fold -w "$L" | head -n1)"
      echo "Random: ${root_password}"
    }
  fi

}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_help
  exit 2
fi

if command -v openssl >/dev/null 2>&1; then
  password_hint
  root_hash="$(openssl rand -base64 12 | tr '+/' './' | cut -c1-16)"
  root_hash="$(openssl passwd -6 -salt "$root_hash")"
else
  echo "Needed tools are not availbale Please install openssl" >&2
  exit 1
fi
unset root_password

if [[ "${1:-}" == "-w" && -n "${2:-}" && -f "${2}" ]]; then
  system_config="${2}"
  jq_set \
    --arg password "${root_hash}" \
    '.os_root_password = $password' \
    "${system_config}"
else
  # show password
  jq -n \
    --arg password "${root_hash}" \
    '{"os_root_password": $password}'
fi
