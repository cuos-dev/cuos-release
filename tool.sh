#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SRC_DIR="${SCRIPT_DIR}/.src"
OUTPUT_DIR="${PWD}/output"

raise() {
	echo "Error: $*" >&2
	exit 1
}

sign_json() {
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    raise "ssh-keygen is required but not installed. Please install it."
  fi

  local json
  json="$(jq \
    --arg name "$(git config user.name)" \
    '{
      "name": $name,
      "config": .,
      "iat": now
    }')"
  IAC_SIGNKEY_PATH="${IAC_SIGNKEY_PATH:-"$HOME/.ssh/id_ed25519"}"
  local ns="file"

  # binary signature -> base64url (no padding)
  b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

  local sig_b64url
  sig_b64url="$(printf '%s' "$json" | ssh-keygen -Y sign -f "${IAC_SIGNKEY_PATH}" -n "$ns" -q - 2>/dev/null | b64url)"

  local payload_b64url
  payload_b64url="$(printf '%s' "$json" | b64url)"

  printf '%s.%s\n' "$payload_b64url" "$sig_b64url"
}

download_image() {
  local image="$1"
  local image_digest="$2"

  if ! docker image pull "${image}"; then
    echo "Failed to pull image ${image}." >&2
    exit 1
  fi

  local current_image_digest
  current_image_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}" 2>/dev/null | cut -d'@' -f2)"

  if [[ -n "${current_image_digest}" && -z "${image_digest}" ]]; then
    return 0
  fi
  if [[ -n "${current_image_digest}" && "${current_image_digest}" = "${image_digest}" ]]; then
    return 0
  fi
  echo "Security: Digest check failed for image ${image}."
  exit 1
}

docker_login() {
  CONFIG_PATH="$1" "${SRC_DIR}/util-docker-login.sh" || exit "$?"
}

image_name() {
  local merged_config
  merged_config="$(cat)"
  local product_name
  product_name="$(echo "${merged_config}" | jq -r '.product_name // empty')"
  if [[ -z "${product_name}" ]]; then
    if echo "${merged_config}" | jq -r '.init_image' | grep -q 'cuos-iac'; then
      product_name="CuOS IaC"
    else
      product_name="CuOS"
    fi
  fi
  local system_name
  system_name="$(echo "${merged_config}" | jq -r '.system_name // .hostname // empty')"
  if [[ -z "${system_name}" ]]; then
    local file_path
    file_path="$(echo "${merged_config}" | jq -r '."__filename"')"
    if [[ "$(basename "${file_path}")" == "system.json" ]]
    then
      system_name="$(basename "$(dirname "${file_path}")")"
    else
      system_name="$(basename "${file_path}" ".json")"
    fi
  fi
  local image_name="${product_name}-${system_name}"
  echo "${image_name// /-}"
}

create_image() {
  local merged_config
  merged_config="$(cat)"
  local image_name
  image_name="$(echo "${merged_config}" | image_name)"

  mkdir -p "${OUTPUT_DIR}"
  echo "${merged_config}" >"${OUTPUT_DIR}/${image_name}.json"

  docker_login "${OUTPUT_DIR}/${image_name}.json"

  download_image "${IMAGE_FACTORY_VERSION}" "${IMAGE_FACTORY_DIGEST}"


  local docker_config_local="${DOCKER_CONFIG:-"${HOME}/.docker/"}"

  docker run --rm \
    --pull=never \
    --privileged \
    -v "${docker_config_local}/config.json":/root/.docker/config.json:ro \
    -v "${OUTPUT_DIR}:/output" \
    -e "IMAGE_NAME=${image_name}" \
    "$@" \
    "${IMAGE_FACTORY_VERSION}" || exit "$?"
}

create_installer() {
  local merged_config
  merged_config="$(cat)"
  local image_name
  image_name="$(echo "${merged_config}" | image_name)"

  mkdir -p "${OUTPUT_DIR}"
  echo "${merged_config}" >"${OUTPUT_DIR}/${image_name}.json"

  download_image "${INSTALLER_FACTORY_VERSION}" "${INSTALLER_FACTORY_DIGEST}"

  docker run --rm \
    -v "${OUTPUT_DIR}:/output" \
    -e "IMAGE_NAME=${image_name}" \
    "${INSTALLER_FACTORY_VERSION}" || exit "$?"
}

start_iac_local() {
  local merged_config
  merged_config="$(cat)"

  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME

  export SYSTEM_CONFIG_PATH="${SCRIPT_DIR}/cuos-iac-local/config-${IAC_COMPOSE_PROJECT_NAME}.json"
  echo "${merged_config}" >"${SYSTEM_CONFIG_PATH}"

  docker_login "${SYSTEM_CONFIG_PATH}"
  local iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.yml"

  local iac_version
  iac_version="$(grep "image" "${iac_compose_file}" | sed -n 's/^ *image: "//p' | sed -n 's/"$//p')"
  local iac_digest
  iac_digest="$(grep "x-digest" "${iac_compose_file}" | grep -oE 'sha256:[0-9a-f]+')"
  download_image "${iac_version}" "${iac_digest}"

  docker compose \
    -f "${iac_compose_file}" \
    up -d \
    --remove-orphans \
    --pull never
}
stop_iac_local() {
  local merged_config
  merged_config="$(cat)"

  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  export SYSTEM_CONFIG_PATH="${SCRIPT_DIR}/cuos-iac-local/config-${IAC_COMPOSE_PROJECT_NAME}.json"
  echo "${merged_config}" >"${SYSTEM_CONFIG_PATH}"

  local iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.yml"

  docker exec "${COMPOSE_PROJECT_NAME}_cuos-iac" "/api/stop" || true

  docker compose \
    -f "${iac_compose_file}" \
    down \
    --remove-orphans
}
update_iac_local() {
  local merged_config
  merged_config="$(cat)"

  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  docker exec "${COMPOSE_PROJECT_NAME}_cuos-iac" "/api/pre_update"
  exit "$?"
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    raise "jq is required but not installed. Please install jq."
  fi
  if ! command -v docker >/dev/null 2>&1; then
    raise "jq is required but not installed. Please install jq."
  fi
  if [[ "$(uname)" = "Darwin" ]]; then
    sed() {
      gsed "$@"
    }
  fi

  # if docker config is read only: copy it!
  if command -v findmnt >/dev/null 2>&1 && findmnt -n -o TARGET,PROPAGATION,OPTIONS "${HOME}/.docker/config.json" | grep -q '\bro\b'; then
    export DOCKER_CONFIG="${PWD}/.docker/"
    if [[ ! -f "${PWD}/.docker/config.json" ]]; then
      mkdir -p "${PWD}/.docker"
      cat "${HOME}/.docker/config.json" >"${PWD}/.docker/config.json"
    fi
  fi

  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.versions.env"

  if [[ "${DEVELOPMENT:-}" == "1" ]]; then
    IMAGE_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-image-factory:development"
    IMAGE_FACTORY_DIGEST=""

    INSTALLER_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-installer-factory:development"
    INSTALLER_FACTORY_DIGEST=""
  fi


  COMMAND="${1:-}"
  shift

  case "${COMMAND}" in
## help                            - Show this help message
##
    ""|"help"|"--help")
      cat <<EOF
USAGE: tool.sh ACTION

ACTIONS:
EOF

      grep -E "^##" "${BASH_SOURCE[0]}" | sed -e 's/^## \?//'
      echo
    ;;
## update                          - Update all git submodules
##                                   checks commit verification
    "update")
      "${SRC_DIR}/submodule-update.sh" || exit "$?"
      ;;
##
## config    path/to/system.json[] - Show merged system configuration
    "config")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}"
      exit
      ;;
## installer path/to/system.json[] - Build ISO based installer for current arch
    "installer")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | create_image \
        -e "OS_ARCH=$(arch || uname -m)" && \
        echo "${merged_config}" | create_installer
      ;;
## image     path/to/system.json[] - Build RAW image for current arch
    "image")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | create_image \
        -e "OS_ARCH=$(arch || uname -m)"
      ;;
## rpi-arm64 path/to/system.json[] - Build RAW image for 64bit Raspberry Pi
    "rpi-arm64")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | create_image \
        -e "OS_ARCH=rpi-arm64" \
        -e "TARGET=rpi"
      ;;
## lxc       path/to/system.json[] - Build LXC image for x64
    "lxc")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | create_image \
        -v "/var/run/docker.sock:/var/run/docker.sock" \
        -e "OS_ARCH=lxc"
      ;;

## start-iac-local path/to/system.json[] - Start IaC local,
##                                         see cuos-iac-local/README.md
    "start-iac-local")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | start_iac_local "$@"
      ;;
## stop-iac-local  path/to/system.json[] - Stop IaC local
    "stop-iac-local")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | stop_iac_local "$@"
      ;;
## update-iac-local path/to/system.json[]- Update IaC local
    "update-iac-local")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | update_iac_local "$@"
      ;;
##
## HELPER
## config-sign path/to/system.json[] - Show merged and signed system configuration
    "config-sign")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo >&2

      echo "${merged_config}" | sign_json
      exit
      ;;
## config-encrypt-init [system.json] - Initiate config encryption
## config-encrypt file.ext         - Encrypt file
## config-decrypt file.ext         - Decrypt file
## config-decrypt-all              - Decrypt all files, that can be decrypted
    "config-encrypt-init"|"config-encrypt"|"config-decrypt"|"config-decrypt-all")
      "${SRC_DIR}/${COMMAND}.sh" "$@"
      ;;
## root-password                   - Helper to create hash for os_root_admin
    "root-password")
      "${SRC_DIR}/create-root-password.sh" "$@"
      ;;


# only internal api:
    "publish")
      "${SRC_DIR}/publish/publish.sh"
      ;;

    "image_name")
      merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
      echo "${merged_config}" | image_name
      ;;
    *)
      echo "Error: Unknown command. Exiting." >&2
      exit 2
      ;;
  esac
}


main "$@"
