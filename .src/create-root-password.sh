#!/usr/bin/env bash

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

if command -v mkpasswd >/dev/null 2>&1; then
  root_hash="$(mkpasswd --method=SHA-512 --rounds=500000)"
elif command -v openssl >/dev/null 2>&1; then
  root_hash="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  root_hash="$(openssl passwd -6 -salt "$root_hash")"
else
  echo "Non of the needed tools is installed. Install mkpasswd or openssl" >&2
  exit 1
fi
unset root_password

jq -n \
  --arg password "${root_hash}" \
  '{"os_root_password": $password}'

#jq_set \
#  --arg password "${root_password}" \
#  '.os_root_password = $password' \
#  "${system_config}"

#echo "${root_hash}"
