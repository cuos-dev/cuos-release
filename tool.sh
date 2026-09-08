#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SRC_DIR="${SCRIPT_DIR}/.src"
OUTPUT_DIR="${PWD}/output"

# shellcheck source=.src/log.sh
source "${SRC_DIR}/log.sh"

raise() {
	set +x
	log_tail
	log_error "$*"
	exit 1
}
trap log_trap_exit EXIT

host_arch() {
  arch 2>/dev/null || uname -m
}

# Run a factory container. Its output is split on the step marker: the step
# lines the factory marks go to the terminal, indented, and everything else into
# the log. The factories themselves do nothing but print the marker - the whole
# separation happens here, which is why an older factory image, which marks
# nothing at all, is quiet too rather than only once its digest has been bumped
# in .versions.env.
#
# Nothing is piped while no log is open: that is './tool.sh shell', whose
# container is interactive.
run_factory() {
  if [[ -z "$(log_path)" ]]; then
    docker run "$@"
    return "$?"
  fi

  # Tracing off for the loop below, and restored afterwards. It reads every line
  # the factory produces, so tracing it would write several lines of its own per
  # line of build output - and bury the build output in the log it is meant to
  # be readable in.
  local trace_was_on=""
  case "$-" in
    *x*) trace_was_on=1 ;;
  esac
  set +x

  # 2>&1 into the pipe: the factories trace to stderr, and docker's own failures
  # arrive there too - both belong in the log rather than on the terminal.
  # 'pipefail' is set, so the status is the container's, not the loop's, and the
  # loop itself cannot fail the way 'grep' would on a factory that marks
  # nothing.
  docker run "$@" 2>&1 | while IFS= read -r line; do
    if log_is_step_line "${line}"; then
      nested_step "${line}"
    else
      printf '%s\n' "${line}"
    fi
  done
  local rc="$?"

  # Restored only on success. A failed build is on its way out, and the few
  # traced lines it would still produce - the return, the exit, the trap - are
  # the last thing written to the log, and would be what the tail shows instead
  # of the cause.
  if [[ -n "${trace_was_on}" && "${rc}" == "0" ]]; then
    set -x
  fi
  return "${rc}"
}

# Open the log for a build: one file per artefact name, beside the artefact.
# Truncated, because it describes this run - the run before it is not the one
# anybody is looking for. An 'installer' build writes both of its halves here,
# under the one name.
start_build_log() {
  local image_name="$1"
  shift

  make_output_dir

  local path="${OUTPUT_DIR}/${image_name}.build.log"
  if [[ "${DEBUG:-}" != "1" ]]; then
    : >"${path}" 2>/dev/null || true
  fi
  log_init "${path}" "tool.sh $*"

  # Tracing where it has somewhere to go: into the log, or onto the terminal
  # because DEBUG=1 asked for it. Without either it would be the very noise this
  # is about.
  if [[ -n "$(log_path)" || "${DEBUG:-}" == "1" ]]; then
    set -x
  fi
}

# Create the output directory. Build artefacts are large and reproducible, so on
# macOS the directory is marked as excluded from Time Machine. The exclusion is
# an extended attribute on the directory itself: it needs no administrator
# rights, but it is lost when the directory is deleted, hence it is set here.
make_output_dir() {
  mkdir -p "${OUTPUT_DIR}"
  if command -v tmutil >/dev/null 2>&1; then
    tmutil addexclusion "${OUTPUT_DIR}" >/dev/null 2>&1 || true
  fi
}

# Split the options out of the argument list. Whatever is left
# is the list of configuration files, and is returned in the global ARGS array
# so that the caller can pass it to merge-configs.sh unchanged.
OPT_PLATFORM=""
OPT_LAYOUT=""
OPT_BASE=""
OPT_HOST=""
OPT_ID=""
OPT_ARTEFACT=""
OPT_REPLACE=0
OPT_YES=0
OPT_NO_START=0
OPT_DRY_RUN=0
parse_options() {
  ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform)
        [[ $# -ge 2 ]] || raise "--platform needs a value. See './tool.sh help'."
        OPT_PLATFORM="$2"
        shift 2
        ;;
      --platform=*)
        OPT_PLATFORM="${1#--platform=}"
        shift
        ;;
      --layout)
        [[ $# -ge 2 ]] || raise "--layout needs a value: mbr or gpt."
        OPT_LAYOUT="$2"
        shift 2
        ;;
      --layout=*)
        OPT_LAYOUT="${1#--layout=}"
        shift
        ;;
      --base)
        [[ $# -ge 2 ]] || raise "--base needs a path to an existing installer ISO."
        OPT_BASE="$2"
        shift 2
        ;;
      --base=*)
        OPT_BASE="${1#--base=}"
        shift
        ;;
      --host)
        [[ $# -ge 2 ]] || raise "--host needs a value: [user@]hostname."
        OPT_HOST="$2"
        shift 2
        ;;
      --host=*)
        OPT_HOST="${1#--host=}"
        shift
        ;;
      --id)
        [[ $# -ge 2 ]] || raise "--id needs a value: a VMID or CTID."
        OPT_ID="$2"
        shift 2
        ;;
      --id=*)
        OPT_ID="${1#--id=}"
        shift
        ;;
      --artefact)
        [[ $# -ge 2 ]] || raise "--artefact needs a value: iso or img."
        OPT_ARTEFACT="$2"
        shift 2
        ;;
      --artefact=*)
        OPT_ARTEFACT="${1#--artefact=}"
        shift
        ;;
      --replace)
        OPT_REPLACE=1
        shift
        ;;
      --yes|-y)
        OPT_YES=1
        shift
        ;;
      --no-start)
        OPT_NO_START=1
        shift
        ;;
      --dry-run)
        OPT_DRY_RUN=1
        shift
        ;;
      --)
        shift
        ARGS+=("$@")
        break
        ;;
      -*)
        raise "Unknown option '$1'. See './tool.sh help'."
        ;;
      *)
        ARGS+=("$1")
        shift
        ;;
    esac
  done

  # Every command using this helper takes at least one configuration file.
  # Checking here also keeps "${ARGS[@]}" safe to expand under 'set -u'.
  if [[ "${#ARGS[@]}" -eq 0 ]]; then
    raise "No configuration file given. See './tool.sh help'."
  fi
}

# The options only the proxmox-* commands take. Accepting them silently
# elsewhere would look like they had an effect.
reject_proxmox_options() {
  local command="$1"
  if [[ -n "${OPT_HOST}${OPT_ID}${OPT_ARTEFACT}" ]] ||
     [[ "${OPT_REPLACE}${OPT_YES}${OPT_NO_START}${OPT_DRY_RUN}" != "0000" ]]; then
    raise "--host, --id, --artefact, --replace, --yes, --no-start and --dry-run
       are only valid for the proxmox-* commands, not for '${command}'."
  fi
}

# A platform and a disk layout are two independent things:
#
#   OS_ARCH  - which OS image to pull. Free-form: it selects the "<arch>_image"
#              key in system.json, falling back to "os_image".
#   TARGET   - which partition layout and boot chain the factory builds. A
#              closed set, because image-factory/create_image.sh implements
#              exactly two:
#                mbr  (TARGET=rpi) MBR + FAT boot partition. Raspberry Pi,
#                                  Orange Pi Zero 3, and anything else booting
#                                  from a FAT partition on an MBR disk.
#                gpt  (TARGET="")  GPT + bios_grub + ESP, GRUB installed for
#                                  both UEFI and BIOS.
#
# Known boards get their layout from the table below. An unknown platform is
# accepted - but its layout must be stated, because guessing it wrong produces
# an image that builds cleanly and does not boot.
#
# Precedence, for both: command line > environment > merged config > default.
PLATFORM=""
PLATFORM_OS_ARCH=""
PLATFORM_TARGET=""

# Layout name as used on the command line -> value the factory expects.
layout_to_target() {
  case "$1" in
    mbr|rpi) echo "rpi" ;;
    gpt|grub) echo "" ;;
    *) raise "Unknown layout '$1'. Known layouts: mbr, gpt." ;;
  esac
}

# Default layout for the boards we know. Empty output means "no idea".
default_layout_for() {
  case "$1" in
    rpi-arm64|rpi-arm32|orangepi-zero3) echo "mbr" ;;
    x86_64|amd64|arm64|aarch64) echo "gpt" ;;
    *) echo "" ;;
  esac
}

# Which platforms can be wrapped in an ISO installer.
#
# The installer factory is not a cross-builder: installer-factory/prepare_iso.sh
# runs at *image build* time and takes the kernel and the initramfs from the
# factory container's own rootfs, so the ISO has whatever architecture that
# container has. It is built and published for amd64 alone, which makes amd64
# the only target with an ISO boot path.
#
# The build host is a separate question and does not belong in this test: an
# arm64 host runs the amd64 factory emulated and gets the very same ISO.
platform_has_iso_boot_path() {
  case "$1" in
    x86_64|amd64) return 0 ;;
    *) return 1 ;;
  esac
}

# ...and because it exists for amd64 alone, every host has to pull and run it as
# amd64 explicitly. Leaving it to Docker works only where the host already is
# amd64: pulling a manifest list that has no entry for the host's platform fails
# with "no matching manifest", it does not fall back to emulating the one entry
# there is. An arm64 host runs it emulated and gets the same ISO.
INSTALLER_FACTORY_PLATFORM="linux/amd64"

# Which platform, without deciding on a disk layout. Enough for the commands
# that only need to know what was built, not how to build it.
resolve_platform_name() {
  local merged_config="$1"

  # OS_ARCH from the environment is honoured, but undocumented.
  PLATFORM="${OPT_PLATFORM:-${OS_ARCH:-}}"
  if [[ -z "${PLATFORM}" ]]; then
    PLATFORM="$(echo "${merged_config}" | jq -r '.platform // empty')"
  fi
  [[ -n "${PLATFORM}" ]] || PLATFORM="$(host_arch)"
  PLATFORM_OS_ARCH="${PLATFORM}"
}

resolve_platform() {
  local merged_config="$1"

  resolve_platform_name "${merged_config}"

  # An LXC image is a container export - no disk, no partitions, no layout.
  if [[ "${PLATFORM}" == "lxc" ]]; then
    PLATFORM_TARGET=""
    return 0
  fi

  local layout="${OPT_LAYOUT:-}"
  if [[ -z "${layout}" ]]; then
    layout="$(echo "${merged_config}" | jq -r '.boot_layout // empty')"
  fi
  [[ -n "${layout}" ]] || layout="$(default_layout_for "${PLATFORM}")"

  if [[ -z "${layout}" ]]; then
    raise "Platform '${PLATFORM}' is not a board this tool knows, so its disk
       layout cannot be guessed - and guessing wrong builds an image that never
       boots. State it explicitly:
         --layout mbr    MBR + FAT boot partition (Raspberry Pi, Orange Pi, ...)
         --layout gpt    GPT + BIOS + UEFI (PC-style firmware)
       or set \"boot_layout\" in system.json."
  fi

  PLATFORM_TARGET="$(layout_to_target "${layout}")"
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
  # Which platform to fetch. Empty means this host's, which is what a multi-arch
  # image wants. Naming one is for an image published for a single architecture:
  # a manifest list with no entry for the host is a hard error, not a fallback
  # to emulation, so the caller has to ask for the architecture that exists.
  local platform="${3:-}"

  if [[ "${BUILD:-}" == "1" ]]; then
    return
  fi

  step "Fetching ${image}"

  # No --quiet: docker's progress writer is terminal-aware, and with the output
  # in the log file it already prints one plain line per layer rather than an
  # animation. Quietening it would only cost the log.
  #
  # Spelled out rather than built as an option array: this runs under 'set -u'
  # on macOS's bash 3.2, where expanding an empty array is an error.
  if [[ -n "${platform}" ]]; then
    docker image pull --platform "${platform}" "${image}"
  else
    docker image pull "${image}"
  fi || raise "Failed to pull image ${image}."

  local current_image_digest
  current_image_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}" 2>/dev/null | cut -d'@' -f2)"

  if [[ -n "${current_image_digest}" && -z "${image_digest}" ]]; then
    return 0
  fi
  if [[ -n "${current_image_digest}" && "${current_image_digest}" = "${image_digest}" ]]; then
    return 0
  fi
  raise "Security: Digest check failed for image ${image}."
}

docker_login() {
  # if docker config is read only: copy it!
  export DOCKER_CONFIG="${PWD}/.docker"
  mkdir -p "${DOCKER_CONFIG}"
  jq '{auths: .auths}' "${HOME}/.docker/config.json" >"${DOCKER_CONFIG}/config.json"

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

save_config() {
  local image_name="$1"
  shift
  local merged_config
  merged_config="$(cat)"

  make_output_dir
  echo "${merged_config}" >"${OUTPUT_DIR}/${image_name}.json"
}

create_image() {
  local image_name="$1"
  shift

  download_image "${IMAGE_FACTORY_VERSION}" "${IMAGE_FACTORY_DIGEST}"

  docker_login "${OUTPUT_DIR}/${image_name}.json"

  local docker_config_local="${DOCKER_CONFIG:-"${HOME}/.docker/"}"
  # The host's /dev, and not the copy of it that --privileged would make at
  # start: the factory asks the kernel for a loop device and maps partitions
  # through device-mapper, so nodes appear *during* the build. A bind mount of
  # devtmpfs shows them; a copy taken beforehand does not, which is why the very
  # first build on a machine used to fail and the second to succeed.
  run_factory --rm \
    --pull=never \
    --privileged \
    -v "/dev:/dev" \
    -v "${docker_config_local}/config.json":/root/.docker/config.json:ro \
    -v "${OUTPUT_DIR}:/output" \
    -v "/var/run/docker.sock:/run/cuos-docker.sock:ro" \
    -e "IMAGE_NAME=${image_name}" \
    "$@" \
    "${IMAGE_FACTORY_VERSION}" || exit "$?"
}

create_installer() {
  local merged_config
  merged_config="$(cat)"
  local image_name
  image_name="$(echo "${merged_config}" | image_name)"

  make_output_dir
  echo "${merged_config}" >"${OUTPUT_DIR}/${image_name}.json"

  download_image "${INSTALLER_FACTORY_VERSION}" "${INSTALLER_FACTORY_DIGEST}" \
    "${INSTALLER_FACTORY_PLATFORM}"

  run_factory --rm \
    --platform "${INSTALLER_FACTORY_PLATFORM}" \
    -v "${OUTPUT_DIR}:/output" \
    -e "IMAGE_NAME=${image_name}" \
    "${INSTALLER_FACTORY_VERSION}" || exit "$?"
}

# Build a new installer ISO from an existing one, embedding this configuration.
# The base ISO is never modified: it is mounted read-only, and the result is a
# separate file in ./output.
installer_from_base() {
  local base="$1"

  [[ -f "${base}" ]] || raise "Base installer ISO not found: ${base}"

  local base_abs
  base_abs="$(cd -- "$(dirname -- "${base}")" &>/dev/null && pwd)/$(basename -- "${base}")" \
    || raise "Cannot resolve the path of the base installer: ${base}"

  local merged_config
  merged_config="$(cat)"
  local image_name
  image_name="$(echo "${merged_config}" | image_name)"

  # The output name is derived from the configuration, so it can collide with
  # the base ISO — typically when the base was built from this same config.
  # xorriso would then read and write one file, with an undefined result.
  local target="${OUTPUT_DIR}/${image_name}.iso"
  if [[ "${base_abs}" == "${target}" ]]; then
    raise "The base installer and the output are the same file:
       ${target}
       This command writes a new ISO rather than modifying the base one, so the
       two must differ. Rename the base ISO, move it out of ./output, or give
       the configuration a different 'system_name'.
       './tool.sh name ${ARGS[*]}' shows the name that will be used."
  fi

  start_build_log "${image_name}" "installer --base ${base}"
  echo "${merged_config}" >"${OUTPUT_DIR}/${image_name}.json"

  download_image "${INSTALLER_FACTORY_VERSION}" "${INSTALLER_FACTORY_DIGEST}" \
    "${INSTALLER_FACTORY_PLATFORM}"

  step "Deriving the installer from ${base}"
  run_factory --rm \
    --platform "${INSTALLER_FACTORY_PLATFORM}" \
    -v "${OUTPUT_DIR}:/output" \
    -v "${base_abs}:/base.iso:ro" \
    -e "IMAGE_NAME=${image_name}" \
    --entrypoint "/patch_iso.sh" \
    "${INSTALLER_FACTORY_VERSION}" \
    "/base.iso" || exit "$?"

  step "output/${image_name}.iso written in $(log_elapsed "${SECONDS}")"
}

iac_local_download() {
  local iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.yml"
  if [[ "${DEVELOPMENT:-}" == "1" ]]; then
    iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.development.yml"
  fi

  local iac_version
  iac_version="$(grep "image" "${iac_compose_file}" | sed -n 's/^ *image: "//p' | sed -n 's/"$//p')"
  local iac_digest
  iac_digest="$(grep "x-digest" "${iac_compose_file}" | grep -oE 'sha256:[0-9a-f]+')"
  download_image "${iac_version}" "${iac_digest}"
}
iac_local_docker_compose() {
  local iac_compose_file="${SCRIPT_DIR}/cuos-iac-local/docker-compose.yml"

  export IAC_SOCKET_VOLUME="${COMPOSE_PROJECT_NAME}-iac-socket"

  if [[ "${DEVELOPMENT:-}" == "1" ]]; then
    docker compose \
      --pull=never \
      -f "${iac_compose_file}" \
      -f "${iac_compose_file/.yml/.development.yml}" \
      "$@"
  else
    docker compose \
      --pull=never \
      -f "${iac_compose_file}" \
      "$@"
  fi
}

start_iac_local() {
  local merged_config
  merged_config="$(cat)"
  CONFIG_DIR=$( cd -- "$( dirname -- "$1" )" &> /dev/null && pwd )

  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  export SYSTEM_CONFIG_PATH="${CONFIG_DIR}/.config-${IAC_COMPOSE_PROJECT_NAME}.json"
  echo "${merged_config}" >"${SYSTEM_CONFIG_PATH}"

  iac_local_download

  docker_login "${SYSTEM_CONFIG_PATH}"

  iac_local_docker_compose \
    up -d \
    --remove-orphans \
    --pull never
}
stop_iac_local() {
  local merged_config
  merged_config="$(cat)"
  CONFIG_DIR=$( cd -- "$( dirname -- "$1" )" &> /dev/null && pwd )

  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  export SYSTEM_CONFIG_PATH="${CONFIG_DIR}/.config-${IAC_COMPOSE_PROJECT_NAME}.json"

  docker exec "${COMPOSE_PROJECT_NAME}-cuos-iac-1" "/api/stop" || true

  iac_local_docker_compose \
    down \
    --remove-orphans
}
update_iac_local() {
  local merged_config
  merged_config="$(cat)"
  CONFIG_DIR=$( cd -- "$( dirname -- "$1" )" &> /dev/null && pwd )

  IAC_COMPOSE_PROJECT_NAME="iac-$(printf '%s' "$*" | sha1sum | cut -c1-8)"
  export IAC_COMPOSE_PROJECT_NAME
  export COMPOSE_PROJECT_NAME="local-${IAC_COMPOSE_PROJECT_NAME}"

  export SYSTEM_CONFIG_PATH="${CONFIG_DIR}/.config-${IAC_COMPOSE_PROJECT_NAME}.json"
  echo "${merged_config}" >"${SYSTEM_CONFIG_PATH}"

  docker exec "${COMPOSE_PROJECT_NAME}-cuos-iac-1" "/api/pre_update"
  exit "$?"
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    raise "jq is required but not installed. Please install jq."
  fi
  # The proxmox-* commands deploy an artefact that has already been built, so
  # they need ssh and not docker.
  if [[ "${1:-}" != proxmox-* ]] && ! command -v docker >/dev/null 2>&1; then
    raise "docker is required but not installed. Please install docker."
  fi
  if [[ "$(uname)" = "Darwin" ]]; then
    sed() {
      gsed "$@"
    }
  fi

  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.versions.env"

  if [[ "${DEVELOPMENT:-}" == "1" ]]; then
    IMAGE_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-image-factory:development"
    IMAGE_FACTORY_DIGEST=""

    INSTALLER_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-installer-factory:development"
    INSTALLER_FACTORY_DIGEST=""
  fi
  if [[ "${BUILD:-}" == "1" ]]; then
    export IMAGE_FACTORY_VERSION="cuos-image-factory-build"
    (
      cd cuos/image-factory/ 2>/dev/null ||
        cd ../cuos/image-factory/ 2>/dev/null ||
        cd ../../cuos/image-factory/ 2>/dev/null ||
	exit
      ./build.sh
    )
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
## image     [--platform P] [--layout L] path/to/system.json[]
##                                 - Build a RAW disk image  -> output/NAME.img
    "image")
      parse_options "$@"
      [[ -z "${OPT_BASE}" ]] || raise "--base is only valid for 'installer'."
      reject_proxmox_options "image"
      step "Merging the configuration"
      merged_config="$("${SRC_DIR}/merge-configs.sh" "${ARGS[@]}")" || exit 1
      resolve_platform "${merged_config}"
      image_name="$(echo "${merged_config}" | image_name)"
      start_build_log "${image_name}" "${COMMAND}" "$@"
      echo "${merged_config}" | save_config "${image_name}"
      step "Building the system image for '${PLATFORM}'"
      create_image "${image_name}" \
        -e "OS_ARCH=${PLATFORM_OS_ARCH}" \
        -e "TARGET=${PLATFORM_TARGET}"
      # The closing line is this script's, not the factory's: the path a person
      # can use is the one relative to where they are standing, and the time is
      # the whole run's rather than the container's part of it.
      artefact="output/${image_name}.img"
      if [[ "${PLATFORM_OS_ARCH}" == "lxc" ]]; then
        artefact="output/${image_name}.tar.gz"
      fi
      step "${artefact} written in $(log_elapsed "${SECONDS}")"
      ;;
## installer [--platform P] [--layout L] [--base existing.iso] system.json[]
##                                 - Build an ISO installer -> output/NAME.iso
    "installer")
      parse_options "$@"
      reject_proxmox_options "installer"
      step "Merging the configuration"
      merged_config="$("${SRC_DIR}/merge-configs.sh" "${ARGS[@]}")" || exit 1

      if [[ -n "${OPT_BASE}" ]]; then
        # The base ISO already carries a built system; only the configuration
        # is exchanged, so nothing is compiled and the platform is fixed by the
        # base.
        [[ -z "${OPT_PLATFORM}" ]] || raise \
          "--platform cannot be combined with --base: the platform is
       determined by the base ISO."
        echo "${merged_config}" | installer_from_base "${OPT_BASE}"
      else
        resolve_platform "${merged_config}"
        if ! platform_has_iso_boot_path "${PLATFORM_OS_ARCH}"; then
          raise "Cannot build an installer for platform '${PLATFORM}'.
       An ISO installer is only produced for x86_64; no other target has an
       ISO boot path yet.
       Use './tool.sh image --platform ${PLATFORM} ...' for a disk image."
        fi
        image_name="$(echo "${merged_config}" | image_name)"
        start_build_log "${image_name}" "${COMMAND}" "$@"
        echo "${merged_config}" | save_config "${image_name}"
        step "Building the system image for '${PLATFORM}'"
        create_image "${image_name}" \
          -e "OS_ARCH=${PLATFORM_OS_ARCH}" && \
          step "Building the installer" && \
          echo "${merged_config}" | create_installer
        step "output/${image_name}.iso written in $(log_elapsed "${SECONDS}")"
      fi
      ;;
##
##   --platform P  Target platform. Default: this host's architecture.
##                 Known: rpi-arm64, rpi-arm32, orangepi-zero3, lxc, host arch.
##                 Any other name works too - it selects "<P>_image" from
##                 system.json - but then --layout is required.
##                 May also be set as "platform" in system.json.
##   --layout L    Disk layout, only needed for an unknown platform:
##                   mbr  MBR + FAT boot partition (Raspberry Pi, Orange Pi)
##                   gpt  GPT + BIOS + UEFI (PC-style firmware)
##                 May also be set as "boot_layout" in system.json.
##   --base ISO    'installer' only: derive the ISO from an existing one
##                 instead of building a system. The base ISO is NOT
##                 modified - a NEW ISO is written to output/, named by the
##                 same rules as any other build (see './tool.sh name').
##
## shell     [--platform P] path/to/system.json[]
##                                 - Open a shell inside the built image.
##                                   Boot and root partitions are detected
##                                   automatically. Build the image first.
    "shell")
      parse_options "$@"
      reject_proxmox_options "shell"
      [[ "${DEBUG:-}" == "1" ]] && set -x
      merged_config="$("${SRC_DIR}/merge-configs.sh" "${ARGS[@]}")" || exit 1
      resolve_platform "${merged_config}"
      image_name="$(echo "${merged_config}" | image_name)"
      echo "${merged_config}" | save_config "${image_name}"
      create_image "${image_name}" \
        -it \
        -e "OS_ARCH=${PLATFORM_OS_ARCH}" \
        --entrypoint "/mount_image.sh"
      ;;
## name      path/to/system.json[] - Show the name the artefacts will get
    "name"|"image_name")
      parse_options "$@"
      reject_proxmox_options "name"
      merged_config="$("${SRC_DIR}/merge-configs.sh" "${ARGS[@]}")" || exit 1
      echo "${merged_config}" | image_name
      exit
      ;;

##
## PROXMOX  (add-on, see docs/testing-on-proxmox.md)
## proxmox-create  [--platform P] [--host H] [--id N] [--artefact iso|img]
##                 [--replace] [--yes] [--no-start] [--dry-run] system.json[]
##                                 - Put an artefact from output/ on a Proxmox
##                                   host and start it. A container for platform
##                                   'lxc', a VM otherwise. Build it first.
## proxmox-destroy [--host H] [--id N] [--yes] [--dry-run] system.json[]
##                                 - Stop and destroy that guest
## proxmox-status  [--host H] [--id N] system.json[]
##                                 - Report whether it exists, and its state
##
##   --host H      [user@]hostname of the Proxmox node, reached over ssh.
##                 May also be set as "proxmox": {"host": ...} in system.json;
##                 there is no default.
##   --id N        VMID/CTID to use. Default: the id of the guest already
##                 carrying this name, else the next free one.
##   --artefact A  Which build to deploy when both exist: iso or img.
##   --replace     Stop and destroy an existing guest of the same name first.
##                 Without it, an existing guest is an error.
##   --yes, -y     Do not ask before destroying anything.
##   --no-start    Create the guest but leave it stopped.
##   --dry-run     Print the ssh/qm/pct commands instead of running them.
##                 Read-only queries are still made - the commands depend on
##                 the host's state.
    "proxmox-create"|"proxmox-destroy"|"proxmox-status")
      parse_options "$@"
      [[ -z "${OPT_BASE}" ]] || raise "--base is only valid for 'installer'."
      [[ -z "${OPT_LAYOUT}" ]] || raise "--layout has no effect here: nothing is
       being built, and the disk layout is already in the artefact."
      [[ "${DEBUG:-}" == "1" ]] && set -x
      merged_config="$("${SRC_DIR}/merge-configs.sh" "${ARGS[@]}")" || exit 1
      resolve_platform_name "${merged_config}"
      image_name="$(echo "${merged_config}" | image_name)"
      [[ -z "${OPT_HOST}" ]] || export PROXMOX_HOST="${OPT_HOST}"
      [[ -z "${OPT_ID}" ]] || export PROXMOX_VMID="${OPT_ID}"
      [[ -z "${OPT_ARTEFACT}" ]] || export PROXMOX_ARTEFACT="${OPT_ARTEFACT}"
      echo "${merged_config}" | \
        PLATFORM="${PLATFORM_OS_ARCH}" \
        IMAGE_NAME="${image_name}" \
        OUTPUT_DIR="${OUTPUT_DIR}" \
        PROXMOX_REPLACE="${OPT_REPLACE}" \
        PROXMOX_YES="${OPT_YES}" \
        PROXMOX_NO_START="${OPT_NO_START}" \
        PROXMOX_DRY_RUN="${OPT_DRY_RUN}" \
        "${SRC_DIR}/proxmox.sh" "${COMMAND#proxmox-}"
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
## root-password [-r|-c|-e] [-w system.json]
##                                 - Create a password hash for os_root_password,
##                                   console_password or console_expert_password
    "root-password")
      "${SRC_DIR}/create-root-password.sh" "$@"
      ;;


# only internal api:
    "publish")
      "${SRC_DIR}/publish/publish.sh" "$@"
      ;;

    *)
      echo "Error: Unknown command. Exiting." >&2
      exit 2
      ;;
  esac
}


main "$@"
