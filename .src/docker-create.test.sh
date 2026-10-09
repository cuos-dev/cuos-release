#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# CONFIG, PLATFORM and the rest are inputs of the sourced script under test,
# which shellcheck cannot see being read, so SC2034 is off for the whole file.
# shellcheck disable=SC2034

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/docker-create.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# docker-create.sh runs under 'set -e'; expect_rc needs a non-zero return not to
# end the test run.
set +e

# raise() ends the process, so anything asserted to fail runs in a subshell.
fails() {
  ( "$@" ) >/dev/null 2>&1
}

# One key of the resolved image.
image_field() {
  action_image | jq -r ".$1 // \"null\""
}

# One value of the compose file, by jq path; a list or a map comes out as
# compact JSON.
compose_value() {
  compose_json | jq -r "$1 // empty | if type == \"string\" then . else tojson end"
}

CONFIG_BASE='{
  "hostname": "demo",
  "lxc_image": "ghcr.io/cuos-dev/cuos-system-lxc",
  "lxc_image_version": "v1",
  "lxc_image_digest": "sha256:aaa",
  "os_image": "ghcr.io/cuos-dev/cuos-system",
  "os_image_version": "v1",
  "os_image_digest": "sha256:bbb"
}'

# --------------------------------------------------------------------- image

CONFIG="${CONFIG_BASE}"
PLATFORM=""
expect "image: lxc_image first" \
  "ghcr.io/cuos-dev/cuos-system-lxc:v1@sha256:aaa" image_field ref
expect "image: without the digest, for the environment" \
  "ghcr.io/cuos-dev/cuos-system-lxc:v1" image_field image
expect "image: lxc is amd64" "linux/amd64" image_field platform

CONFIG="$(echo "${CONFIG_BASE}" | jq 'del(.lxc_image)')"
expect "image: os_image without lxc_image" \
  "ghcr.io/cuos-dev/cuos-system:v1@sha256:bbb" image_field ref

CONFIG="$(echo "${CONFIG_BASE}" | jq '.lxc_image = ""')"
expect "image: an empty lxc_image is none" \
  "ghcr.io/cuos-dev/cuos-system:v1@sha256:bbb" image_field ref

CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {
  "rpi-arm64_image": "ghcr.io/cuos-dev/cuos-system-rpi-arm64",
  "rpi-arm64_image_version": "v2",
  "rpi-arm64_image_digest": "sha256:ccc"}')"
PLATFORM="rpi-arm64"
expect "image: --platform selects <P>_image" \
  "ghcr.io/cuos-dev/cuos-system-rpi-arm64:v2@sha256:ccc" image_field ref
expect "image: rpi-arm64 is arm64" "linux/arm64" image_field platform

CONFIG="${CONFIG_BASE}"
expect_rc "image: a board never falls back to os_image" 1 fails action_image
PLATFORM="rpi-arm32"
expect_rc "image: nor does rpi-arm32" 1 fails action_image

PLATFORM="x86_64"
expect "image: another platform falls back to os_image" \
  "ghcr.io/cuos-dev/cuos-system:v1@sha256:bbb" image_field ref

PLATFORM="os"
expect "image: --platform os" "ghcr.io/cuos-dev/cuos-system:v1@sha256:bbb" image_field ref

PLATFORM="my-board"
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"my-board_image": "registry.example.com/my-os"}')"
expect "image: an unknown platform with an image of its own" \
  "registry.example.com/my-os" image_field ref
expect "image: ... and no docker platform" "null" image_field platform

PLATFORM=""
CONFIG='{"update_registry": "registry.example.com", "os_image": "my/os", "os_image_version": "v3"}'
expect "image: a name without a registry is taken from update_registry" \
  "registry.example.com/my/os:v3" image_field ref
CONFIG='{"update_registry": "https://registry.example.com/", "update_registry_proxy": "proxy.example.com", "os_image": "/os"}'
expect "image: the proxy before the registry" "proxy.example.com/os" image_field ref

CONFIG='{"hostname": "demo"}'
expect_rc "image: none at all" 1 fails action_image

# ------------------------------------------------------------------ networks

IMAGE_NAME="CuOS-demo"
CONFIG_FILE="./CuOS-demo.system.json"
COMMAND_LINE="docker-create system.json"
PLATFORM=""

CONFIG="${CONFIG_BASE}"
expect "networks: one bridge without any network entry" \
  'bridge' compose_value '.networks.net0.driver'
expect "networks: the service is attached to it" \
  "1000" compose_value '.services["cuos-demo"].networks.net0.priority'

CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"network": [
  {"dhcp": true, "dns-server": ["1.1.1.1", "9.9.9.9"]},
  {"ip-address": "10.20.0.5", "network-mask": "255.255.255.0", "gateway": "10.20.0.1",
   "mac-address": "02-11-22-AA-44-55", "dns-server": "1.1.1.1"}]}')"
expect "networks: one per network entry" \
  'bridge' compose_value '.networks.net1.driver'
expect "networks: a bridge takes no address from system.json by default" \
  "" compose_value '.services["cuos-demo"].networks.net1.ipv4_address'
expect "networks: the MAC address, normalised" \
  '02:11:22:aa:44:55' compose_value '.services["cuos-demo"].networks.net1.mac_address'
expect "networks: the order of the entries is kept" \
  "999" compose_value '.services["cuos-demo"].networks.net1.priority'
expect "networks: resolvers of every entry, each once" \
  '["1.1.1.1","9.9.9.9"]' compose_value '.services["cuos-demo"].dns'

CONFIG="$(echo "${CONFIG}" | jq '.docker.nets = ["lan", {"name": "iot", "static": true}]')"
expect "networks: a bare string names the network" \
  'bridge' compose_value '.networks.lan.driver'
expect "networks: static takes the address" \
  '10.20.0.5' compose_value '.services["cuos-demo"].networks.iot.ipv4_address'
expect "networks: ... the subnet it is in" \
  '10.20.0.0/24' compose_value '.networks.iot.ipam.config[0].subnet'
expect "networks: ... and the gateway" \
  '10.20.0.1' compose_value '.networks.iot.ipam.config[0].gateway'

CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {
  "network": [{}, {}, {"ip-address": "192.168.50.7", "network-mask": "22"}],
  "docker": {"nets": [null, "lan", {"name": "field", "driver": "macvlan", "parent": "eth1"}]}}')"
expect "networks: null keeps its place" \
  'bridge' compose_value '.networks.net0.driver'
expect "networks: macvlan" 'macvlan' compose_value '.networks.field.driver'
expect "networks: ... on its parent" 'eth1' compose_value '.networks.field.driver_opts.parent'
expect "networks: ... always static, prefix spelled as a number" \
  '192.168.48.0/22' compose_value '.networks.field.ipam.config[0].subnet'

CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"docker": {"nets": [{"driver": "macvlan", "parent": "eth1"}]}}')"
expect_rc "networks: macvlan without an address" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"network": [{"ip-address": "10.0.0.2", "network-mask": "255.255.255.0"}],
  "docker": {"nets": [{"driver": "macvlan"}]}}')"
expect_rc "networks: macvlan without a parent" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"docker": {"nets": [{"driver": "overlay"}]}}')"
expect_rc "networks: an unknown driver" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"network": [{"ip-address": "10.0.0.2"}],
  "docker": {"nets": [{"static": true}]}}')"
expect_rc "networks: static without a mask" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"network": [{"ip-address": "10.0.0.2", "network-mask": "255.0.255.0"}],
  "docker": {"nets": [{"static": true}]}}')"
expect_rc "networks: a mask that is no mask" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"docker": {"nets": ["lan", "lan"]}}')"
expect_rc "networks: a name twice" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"docker": {"nets": ["my lan"]}}')"
expect_rc "networks: a name that is none" 1 fails action_compose
CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {"docker": {"nets": "lan"}}')"
expect_rc "networks: nets is a list" 1 fails action_compose

# ------------------------------------------------------------------- service

CONFIG="${CONFIG_BASE}"
expect "service: the project is named after the artefact" \
  'cuos-demo' compose_value '.name'
expect "service: systemd as PID 1" \
  '["/sbin/init"]' compose_value '.services["cuos-demo"].entrypoint'
expect "service: the hostname" 'demo' compose_value '.services["cuos-demo"].hostname'
expect "service: the image, pinned" \
  'ghcr.io/cuos-dev/cuos-system-lxc:v1@sha256:aaa' compose_value '.services["cuos-demo"].image'
expect "service: the image for /etc/image" \
  'ghcr.io/cuos-dev/cuos-system-lxc:v1' compose_value '.services["cuos-demo"].environment.CUOS_IMAGE'
expect "service: /data is a volume" \
  'cuos-demo-data' compose_value '.services["cuos-demo"].volumes[0].source'
expect "service: the configuration as /system_init.json" \
  '/system_init.json' compose_value '.services["cuos-demo"].volumes[1].target'
expect "service: ... from beside the compose file" \
  './CuOS-demo.system.json' compose_value '.services["cuos-demo"].volumes[1].source'

CONFIG="$(echo "${CONFIG_BASE}" | jq 'del(.lxc_image_digest)')"
expect "service: no digest is 'unknown', as on the system" \
  'unknown' compose_value '.services["cuos-demo"].environment.CUOS_IMAGE_DIGEST'

# ---------------------------------------------------------------------- yaml

expect "yaml: maps, lists and scalars" \
  $'a:\n  b: 1\n  c:\n    - "x"\n    - true\nd: "s"' \
  eval "echo '{\"a\":{\"b\":1,\"c\":[\"x\",true]},\"d\":\"s\"}' | to_yaml"
expect "yaml: a list of maps" \
  $'l:\n  - k: "v"\n    m: null\n  - {}' \
  eval "echo '{\"l\":[{\"k\":\"v\",\"m\":null},{}]}' | to_yaml"
expect "yaml: empty map and list" $'a: {}\nb: []' \
  eval "echo '{\"a\":{},\"b\":[]}' | to_yaml"
expect "yaml: a key that needs quoting" $'"a b": 1' \
  eval "echo '{\"a b\":1}' | to_yaml"
expect "yaml: a dollar is doubled, or compose would interpolate it" \
  $'s: "\\"$$X\\""' \
  eval "echo '{\"s\":\"\\\"\$X\\\"\"}' | to_yaml"

# The syntax itself is docker compose's to judge. Run where it is installed - the
# CI runners have it - and skipped where it is not.
compose_config() {
  local dir
  dir="$(mktemp -d)"
  echo '{}' >"${dir}/CuOS-demo.system.json"
  action_compose >"${dir}/CuOS-demo.compose.yml"
  docker compose -f "${dir}/CuOS-demo.compose.yml" config --quiet
  local rc="$?"
  rm -rf "${dir}"
  return "${rc}"
}
if docker compose version >/dev/null 2>&1; then
  CONFIG="$(echo "${CONFIG_BASE}" | jq '. + {
    "network": [{"dns-server": "1.1.1.1"}, {"ip-address": "10.20.0.5", "network-mask": "24",
      "gateway": "10.20.0.1", "mac-address": "021122334455"}],
    "docker": {"nets": ["lan", {"name": "iot", "static": true}]}}')"
  expect_rc "yaml: docker compose accepts the file" 0 compose_config
else
  echo "SKIP yaml: docker compose accepts the file (no docker compose here)"
fi

summary
