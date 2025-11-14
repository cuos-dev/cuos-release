#!/bin/bash

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SRC_DIR="${SCRIPT_DIR}/.src"
OUTPUT_DIR="${PWD}/output"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.versions.env"

if [[ "${DEVELOPMENT:-}" == "1" ]]; then
  IMAGE_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-image-factory:development"
  IMAGE_FACTORY_DIGEST=""

  INSTALLER_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-installer-factory:development"
  INSTALLER_FACTORY_DIGEST=""
fi

raise() {
	echo "Error: $*" >&2
	exit 1
}

download_image() {
  local image="$1"
  local image_digest="$2"

  if ! docker image pull "${image}"; then
    echo "Failed to pull image ${image}." >&2
    exit 1
  fi

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


create_image() {
  mkdir -p "${OUTPUT_DIR}"
  echo "${merged_config}" >"${OUTPUT_DIR}/system.json"

  docker_login "${OUTPUT_DIR}/system.json"

  download_image "${IMAGE_FACTORY_VERSION}" "${IMAGE_FACTORY_DIGEST}"

  docker run --rm \
    --pull=never \
    --privileged \
    -v "${HOME}/.docker/config.json":/root/.docker/config.json:ro \
    -v "${OUTPUT_DIR}:/output" \
    "$@" \
    "${IMAGE_FACTORY_VERSION}" || exit "$?"
}

create_installer() {
  download_image "${INSTALLER_FACTORY_VERSION}" "${INSTALLER_FACTORY_DIGEST}"

  docker run --rm \
    -v "${OUTPUT_DIR}:/output" \
    "${INSTALLER_FACTORY_VERSION}" || exit "$?"
}

start_iac_local() {
  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME

  export SYSTEM_CONFIG_PATH="${SCRIPT_DIR}/cuos-iac-local/config-${IAC_COMPOSE_PROJECT_NAME}.json"
  echo "${merged_config}" >"${SYSTEM_CONFIG_PATH}"

  docker_login "${SYSTEM_CONFIG_PATH}"
  iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.yml"

  IAC_VERSION="$(grep "image" "${iac_compose_file}" | sed -n 's/^ *image: "//p' | sed -n 's/"$//p')"
  IAC_DIGEST="$(grep "x-digest" "${iac_compose_file}" | grep -oE 'sha256:[0-9a-f]+')"
  download_image "${IAC_VERSION}" "${IAC_DIGEST}"

  docker compose \
    -f "${iac_compose_file}" \
    up -d \
    --remove-orphans \
    --pull never
}
stop_iac_local() {
  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  export SYSTEM_CONFIG_PATH="${SCRIPT_DIR}/cuos-iac-local/config-${IAC_COMPOSE_PROJECT_NAME}.json"
  echo "${merged_config}" >"${SYSTEM_CONFIG_PATH}"

  iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.yml"

  docker exec "${COMPOSE_PROJECT_NAME}_cuos-iac" "/api/stop" || true

  docker compose \
    -f "${iac_compose_file}" \
    down \
    --remove-orphans
}
update_iac_local() {
  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  docker exec "${COMPOSE_PROJECT_NAME}_cuos-iac" "/api/pre_update"
  exit "$?"
}

if ! command -v jq >/dev/null 2>&1; then
	raise "jq is required but not installed. Please install jq."
fi
if [[ "$(uname)" = "Darwin" ]]; then
  sed() {
    gsed "$@"
  }
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
## config    path/to/system.json[] - Show merged system configuration
  "config")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    echo "${merged_config}"
    exit
    ;;
## installer path/to/system.json[] - Build ISO based installer for current arch
  "installer")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    create_image \
      -e "OS_ARCH=$(arch || uname -m)"
    create_installer
    ;;
## image     path/to/system.json[] - Build RAW image for current arch
  "image")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    create_image \
      -e "OS_ARCH=$(arch || uname -m)"
    ;;
## rpi-arm64 path/to/system.json[] - Build RAW image for 64bit Raspberry Pi
  "rpi-arm64")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    create_image \
      -e "OS_ARCH=rpi-arm64" \
      -e "TARGET=rpi"
    ;;
## lxc       path/to/system.json[] - Build LXC image for x64
  "lxc")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    create_image \
      -v "/var/run/docker.sock:/var/run/docker.sock" \
      -e "OS_ARCH=lxc"
    ;;

## start-iac-local path/to/system.json[] - Start IaC local,
##                                         see cuos-iac-local/README.md
  "start-iac-local")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    start_iac_local
    ;;
## stop-iac-local  path/to/system.json[]  - Stop IaC local
  "stop-iac-local")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    stop_iac_local
    ;;
## update-iac-local path/to/system.json[]- Update IaC local
  "update-iac-local")
    merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1
    update_iac_local
    ;;
  *)
    echo "Error: Unknown command. Exiting." >&2
    exit 2
    ;;
esac
