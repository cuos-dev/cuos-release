#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MAIN_DIR="${SCRIPT_DIR}/../../"

# --pins FILE writes the image pins - and nothing else - to FILE, leaving this
# repository untouched. It exists for the moment between tagging a release and
# publishing it: the images are in the registry, so their digests can be looked
# up, but release.json must not say so yet, because saying so is the act of
# publishing. A system test can include that file and exercise the new release
# without anything here being committed, and if it fails there is nothing to
# take back. See cuos-system-test/release-gate.sh.
PINS_TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pins)
      PINS_TARGET="${2:-}"
      [[ -n "${PINS_TARGET}" ]] || { echo "--pins needs a file." >&2; exit 2; }
      shift 2
      ;;
    *)
      echo "Usage: publish.sh [--pins FILE]" >&2
      exit 2
      ;;
  esac
done

export ORG=cuos-dev

# Token: Release Digest Fetch (classic)
#export GITHUB_TOKEN=...
# shellcheck source=/dev/null
source "${MAIN_DIR}.publish_github_token"

if [[ "$(uname)" = "Darwin" ]]; then
  sed() {
    gsed "$@"
  }
fi

VERSIONS="$("${SCRIPT_DIR}/github_fetch_digests.sh" | jq '.[] | {"package": .package, "version": .tags[0], "digest": .name}' | jq -s . | jq 'map({ (.package): del(.package) }) | add')"

echo "${VERSIONS}"

version() {
  package="$1"
  echo "${VERSIONS}" | jq -r --arg pkg "${package}" '.[$pkg].version'
}
digest() {
  package="$1"
  echo "${VERSIONS}" | jq -r --arg pkg "${package}" '.[$pkg].digest'
}


# The image pins, merged into whatever the given file holds. release.json keeps
# its image names, registry and signing keys that way; an empty object yields
# the pins on their own, which is what an override fragment wants to be.
pins_json() {
  jq \
    --argjson v "${VERSIONS}" \
    '
      .os_image_version = $v."cuos-system".version |
      .os_image_digest = $v."cuos-system".digest |
      ."rpi-arm64_image_version" = $v."cuos-system-rpi-arm64".version |
      ."rpi-arm64_image_digest" = $v."cuos-system-rpi-arm64".digest |
      ."rpi-arm32_image_version" = $v."cuos-system-rpi-arm32".version |
      ."rpi-arm32_image_digest" = $v."cuos-system-rpi-arm32".digest |
      ."orangepi-zero3_image_version" = $v."cuos-system-orangepi-zero3".version |
      ."orangepi-zero3_image_digest" = $v."cuos-system-orangepi-zero3".digest |
      .lxc_image_version = $v."cuos-system-lxc".version |
      .lxc_image_digest = $v."cuos-system-lxc".digest |
      .updater_image_version = $v."cuos-updater".version |
      .updater_image_digest = $v."cuos-updater".digest |
      .init_image_version = $v."cuos-iac".version |
      .init_image_digest = $v."cuos-iac".digest |
      .iac_image_version = $v."cuos-iac".version |
      .iac_image_digest = $v."cuos-iac".digest
    ' "$1"
}

if [[ -n "${PINS_TARGET}" ]]; then
  # Nothing in this repository is written: not .versions.env, not release.json,
  # and above all not the four compose files, which are rewritten in place.
  PINS="$(pins_json <(echo '{}'))" || exit "$?"
  printf '%s\n' "${PINS}" >"${PINS_TARGET}.tmp" \
    && mv "${PINS_TARGET}.tmp" "${PINS_TARGET}" \
    || exit "$?"
  echo "Wrote the pins to ${PINS_TARGET}. Nothing here was changed."
  exit 0
fi

# write .versions.env
cat >"${MAIN_DIR}.versions.env" <<EOF

IMAGE_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-image-factory:$(version "cuos-image-factory")"
IMAGE_FACTORY_DIGEST="$(digest "cuos-image-factory")"

INSTALLER_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-installer-factory:$(version "cuos-installer-factory")"
INSTALLER_FACTORY_DIGEST="$(digest "cuos-installer-factory")"

EOF

RELEASE_JSON="$(pins_json "${MAIN_DIR}/release.json")"
echo "${RELEASE_JSON}" >"${MAIN_DIR}/release.json"

docker_compose_version() {
  local l_file="$1"
  local l_version="$2"
  local l_digest="$3"

  sed -E -i \
    -e "s|(image: *\"[^\"]+:)[^\"]+(\")|\1${l_version}\2|" \
    -e "s|(^[[:space:]]*x-digest: *\")[^\"]+(\"$)|\1${l_digest}\2|" \
    "${MAIN_DIR}${l_file}"
}

docker_compose_version \
  "cuos-iac-webui/docker-compose.yml" \
  "$(version "cuos-iac-webui")" "$(digest "cuos-iac-webui")"

docker_compose_version \
  "cuos-dev-container/docker-compose.yml" \
  "$(version "cuos-iac-dev-container")" "$(digest "cuos-iac-dev-container")"

docker_compose_version \
  "cuos-iac-fleet-agent/docker-compose.yml" \
  "$(version "cuos-iac-fleet-agent")" "$(digest "cuos-iac-fleet-agent")"

docker_compose_version \
  "cuos-iac-local/docker-compose.yml" \
  "$(version "cuos-iac")" "$(digest "cuos-iac")"


