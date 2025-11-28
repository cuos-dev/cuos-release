#!/bin/bash

set -uo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
MAIN_DIR="${SCRIPT_DIR}/../../"

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


# write .versions.env
cat >"${MAIN_DIR}.versions.env" <<EOF

IMAGE_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-image-factory:$(version "cuos-image-factory")"
IMAGE_FACTORY_DIGEST="$(digest "cuos-image-factory")"

INSTALLER_FACTORY_VERSION="ghcr.io/cuos-dev/cuos-installer-factory:$(version "cuos-installer-factory")"
INSTALLER_FACTORY_DIGEST="$(digest "cuos-installer-factory")"

EOF

RELEASE_JSON="$(jq \
  --argjson v "${VERSIONS}" \
  --arg os_version "$(version "cuos-system")" \
  --arg os_digest "$(digest "cuos-system")" \
  --arg rpi64_version "$(version "cuos-system-rpi-arm64")" \
  --arg rpi64_digest "$(digest "cuos-system-rpi-arm64")" \
  '
    .os_image_version = $v."cuos-system".version |
    .os_image_digest = $v."cuos-system".digest |
    ."rpi-arm64_image_version" = $v."cuos-system-rpi-arm64".version |
    ."rpi-arm64_image_digest" = $v."cuos-system-rpi-arm64".digest |
    .lxc_image_version = $v."cuos-system-lxc".version |
    .lxc_image_digest = $v."cuos-system-lxc".digest |
    .updater_image_version = $v."cuos-updater".version |
    .updater_image_digest = $v."cuos-updater".digest |
    .init_image_version = $v."cuos-iac".version |
    .init_image_digest = $v."cuos-iac".digest |
    .iac_image_version = $v."cuos-iac".version |
    .iac_image_digest = $v."cuos-iac".digest
  ' "${MAIN_DIR}/release.json")"
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


