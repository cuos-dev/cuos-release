#!/bin/bash

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SRC_DIR="${SCRIPT_DIR}/.src"
OUTPUT_DIR="${PWD}/output"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.versions.env"

if [[ "${DEVELOPMENT}" == "1" ]]; then
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
    -e "OS_ARCH=${OS_ARCH:-}" \
    "${IMAGE_FACTORY_VERSION}" || exit "$?"
}

create_installer() {
  download_image "${INSTALLER_FACTORY_VERSION}" "${INSTALLER_FACTORY_DIGEST}"

  docker run --rm \
    -v "${OUTPUT_DIR}:/output" \
    "${INSTALLER_FACTORY_VERSION}" || exit "$?"
}

if ! command -v jq >/dev/null 2>&1; then
	raise "jq is required but not installed. Please install jq."
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 mode path/to/system.json [another/system.json]" >&2
  echo "mode = image | installer | lxc | rpi-arm64 | start-iac-local | config" >&2
  exit 2
fi

MODE="$1"
shift


merged_config="$("${SRC_DIR}/merge-configs.sh" "$@")" || exit 1

case "${MODE}" in
  "config")
    echo "${merged_config}"
    exit
    ;;
  "lxc")
    create_image \
      -e "OS_ARCH=lxc"
    ;;
  "installer")
    create_image \
      -e "OS_ARCH=$(arch)"
    create_installer
    ;;
  "image")
    create_image \
      -e "OS_ARCH=$(arch)"
    ;;
  "rpi-arm64")
    create_image \
      -e "OS_ARCH=rpi-arm64" \
      -e "TARGET=rpi"
    ;;
  "start-iac-local")
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
    ;;
  *)
    echo "Error: Unknown mode. Exiting." >&2
    exit 2
    ;;
esac
