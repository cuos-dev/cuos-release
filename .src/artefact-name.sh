#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Reads a merged configuration on stdin and prints the name of the artefacts
# built from it.
set -uo pipefail

merged_config="$(cat)"

product_name="$(echo "${merged_config}" | jq -r '.product_name // empty')"
if [[ -z "${product_name}" ]]; then
  if echo "${merged_config}" | jq -r '.init_image' | grep -q 'cuos-iac'; then
    product_name="CuOS IaC"
  else
    product_name="CuOS"
  fi
fi

system_name="$(echo "${merged_config}" | jq -r '.system_name // .hostname // empty')"
if [[ -z "${system_name}" ]]; then
  file_path="$(echo "${merged_config}" | jq -r '."__filename"')"
  if [[ "$(basename "${file_path}")" == "system.json" ]]
  then
    system_name="$(basename "$(dirname "${file_path}")")"
  else
    system_name="$(basename "${file_path}" ".json")"
  fi
fi

template="$(echo "${merged_config}" | jq -r '.artefact_name // empty')"
if [[ -z "${template}" ]]; then
  name="${product_name}-${system_name}"
else
  # Consumed left to right, so a value that itself contains braces is copied
  # rather than expanded again.
  placeholder='\{([^{}]*)\}'
  rest="${template}"
  name=""
  while [[ "${rest}" =~ ${placeholder} ]]; do
    match="${BASH_REMATCH[0]}"
    key="${BASH_REMATCH[1]}"
    name+="${rest%%"${match}"*}"
    rest="${rest#*"${match}"}"

    case "${key}" in
      product_name) value="${product_name}" ;;
      system_name) value="${system_name}" ;;
      *)
        value="$(echo "${merged_config}" | jq -r --arg key "${key}" \
          '.[$key] | select(type == "string" or type == "number" or type == "boolean") | tostring')"
        ;;
    esac
    if [[ -z "${value}" ]]; then
      echo "artefact_name \"${template}\": the configuration has no value for {${key}}." >&2
      exit 1
    fi
    name+="${value}"
  done
  name+="${rest}"
fi

echo "${name// /-}"
