#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# docker-create.sh — describe a CuOS system as a docker compose service, to run
# the OS itself as a container on a local docker.
#
# Invoked by tool.sh with the merged configuration on stdin:
#
#   ./docker-create.sh image     the image to run, as JSON:
#                                {ref, image, digest, platform}
#   ./docker-create.sh compose   the compose file, as YAML
#
# Everything else arrives in the environment:
#
#   PLATFORM     --platform as given; empty means lxc_image, else os_image
#   IMAGE_NAME   artefact name (tool.sh 'name'); names the project, the
#                service and the volume
#   CONFIG_FILE  the configuration's path as the compose file sees it,
#                relative to the compose file
#   COMMAND_LINE how this was called, for the header of the file
#
# The keys it reads and what they default to: docs/running-in-docker.md.
#
# What the container needs, and why each part is there:
#
#   entrypoint /sbin/init  the images' own entrypoint only sleeps; CuOS is
#                          systemd as PID 1
#   privileged             systemd and the docker daemon inside it
#   /data                  a volume: state, and /var/lib/docker, which the
#                          image links to /data/docker - a docker inside on
#                          overlay-on-overlay would not start
#   /system_init.json      what CuOS reads once, on the first start, in a
#                          container (cuos/system/cuos/init.sh)
#   networks               CuOS configures no network inside a container, so
#                          the compose file has to
#   CUOS_IMAGE[_DIGEST]    what first-run.sh writes to /etc/image, which an
#                          update compares against

set -euo pipefail

PLATFORM="${PLATFORM:-}"
IMAGE_NAME="${IMAGE_NAME:-}"
CONFIG_FILE="${CONFIG_FILE:-}"
COMMAND_LINE="${COMMAND_LINE:-}"

raise() {
  echo "Error: $*" >&2
  exit 1
}

CONFIG=""

# Shared jq definitions. Errors are raised with error() and leave jq with a
# non-zero status; the message is what jq prints, prefixed "jq: error".
JQ_LIB='
  # ----------------------------------------------------------------- image

  # The keys a platform selects: "<platform>_image", "_version", "_digest".
  # Without --platform the container image comes first, the os image second.
  # A board has an image of its own architecture or none: falling back to
  # os_image would run a different architecture, as create_image.sh refuses
  # to as well.
  def image_key($platform):
    if $platform == "" then
      if (.lxc_image // "") != "" then "lxc" else "os" end
    elif (.[$platform + "_image"] // "") != "" then $platform
    elif ($platform | IN("rpi-arm64", "rpi-arm32", "orangepi-zero3")) then
      error("No \"\($platform)_image\" in the configuration. Refusing to fall back to os_image: that is a different architecture.")
    else "os" end;

  # The docker platform of the images this project publishes. An image of
  # its own under a name this does not know gets none, and docker decides.
  def docker_platform($key):
    if $key | IN("lxc", "os", "x86_64", "amd64") then "linux/amd64"
    elif $key | IN("rpi-arm64", "orangepi-zero3", "arm64", "aarch64") then "linux/arm64"
    elif $key == "rpi-arm32" then "linux/arm/v6"
    else null end;

  # The image as utils.sh image_url() spells it on the system itself - a
  # name without a registry is taken from update_registry - because the
  # same spelling ends up in /etc/image and is compared against by updates.
  def image($platform):
    image_key($platform) as $key
    | (.[$key + "_image"] // "") as $name
    | if $name == "" then error("No \"\($key)_image\" in the configuration.") else . end
    | (if ($name | startswith("/")) or ($name | contains(".") | not) then
         ((.update_registry_proxy // .update_registry // "") + "/" + $name)
       else $name end) as $repo
    | (.[$key + "_image_version"] // "") as $version
    | (.[$key + "_image_digest"] // "") as $digest
    | (($repo + (if $version != "" then ":" + $version else "" end))
       | gsub("/+"; "/") | ltrimstr("/")) as $image
    | {
        ref: ($image + (if $digest != "" then "@" + $digest else "" end)),
        image: $image,
        digest: $digest,
        platform: docker_platform($key)
      };

  # --------------------------------------------------------------- network

  def ip_to_int:
    split(".") | map(tonumber)
    | if length != 4 or any(.[]; . > 255) then error("not an address") else . end
    | .[0] * 16777216 + .[1] * 65536 + .[2] * 256 + .[3];

  def int_to_ip:
    [(. / 16777216 | floor), (. / 65536 | floor) % 256,
     (. / 256 | floor) % 256, . % 256]
    | map(tostring) | join(".");

  # A prefix length, from either spelling of a subnet mask.
  def prefix_of($i):
    if type == "number" or test("^[0-9]+$") then tonumber
    else
      (try ip_to_int catch error("network[\($i)].network-mask \"\(.)\" is not a subnet mask.")) as $bits
      | [range(0; 33) | select($bits == 4294967296 - pow(2; 32 - .))]
      | if length == 0 then error("network[\($i)].network-mask is not a valid subnet mask.") else .[0] end
    end
    | if . > 32 then error("network[\($i)].network-mask is not a prefix length.") else . end;

  # docker.nets[i]. A bare string is shorthand for its name, null keeps an
  # element in its place.
  def docker_net($i):
    ((.docker.nets // [])[$i] // {})
    | if type == "string" then {name: .} else . end;

  # One compose network per "network" entry, net<i> for network[i] - the
  # same pairing as proxmox.nets. What only docker needs to know is in
  # docker.nets[i]:
  #
  #   name    the compose network; two systems naming the same one share it
  #   driver  bridge (default), macvlan or ipvlan
  #   parent  the host interface, for macvlan and ipvlan
  #   static  take the address from network[i]. Off for a bridge: the
  #           address of the real network, on a bridge of its own on the
  #           development machine, collides with the network that machine
  #           is in. Always on for macvlan and ipvlan, which have no DHCP.
  def networks:
    (.docker.nets // []) as $nets
    | if ($nets | type) != "array"
         or ($nets | any(.[]; type != "string" and type != "object" and type != "null")) then
        error("docker.nets must be a list of network names, objects or null.")
      else . end
    | ([(.network // [] | length), ($nets | length), 1] | max) as $count
    | . as $config
    | [range(0; $count) as $i
       | ($config | docker_net($i)) as $net
       | (($config.network // [])[$i] // {}) as $sys
       | ($net.name // "net\($i)") as $name
       | ($net.driver // "bridge") as $driver
       | (if $driver == "bridge" then ($net.static // false) else true end) as $static
       | if ($name | test("^[A-Za-z0-9][A-Za-z0-9_.-]*$") | not) then
           error("docker.nets[\($i)].name \"\($name)\" is not a network name.")
         elif ($driver | IN("bridge", "macvlan", "ipvlan") | not) then
           error("docker.nets[\($i)].driver must be bridge, macvlan or ipvlan, not \"\($driver)\".")
         elif $driver != "bridge" and ($net.parent // "") == "" then
           error("docker.nets[\($i)] is a \($driver) network and needs a \"parent\": the host interface it is attached to.")
         elif $static and ($sys["ip-address"] // "") == "" then
           error("docker.nets[\($i)] takes its address from network[\($i)], which has no \"ip-address\"." +
             (if $driver == "bridge" then "" else " A \($driver) network has no DHCP." end))
         elif $static and ($sys["network-mask"] // "") == "" then
           error("network[\($i)] has an \"ip-address\" but no \"network-mask\".")
         else . end
       | (if $static then
            ($sys["network-mask"] | prefix_of($i)) as $prefix
            | (try ($sys["ip-address"] | ip_to_int)
               catch error("network[\($i)].ip-address is not an address.")) as $ip
            | pow(2; 32 - $prefix) as $size
            | {address: $sys["ip-address"],
               subnet: "\(($ip / $size | floor) * $size | int_to_ip)/\($prefix)",
               gateway: ($sys.gateway // null)}
          else null end) as $ipam
       | ($sys["mac-address"] // "") as $mac
       | if $mac != "" and ($mac | test("^([0-9A-Fa-f]{2}[-:]?){5}[0-9A-Fa-f]{2}$") | not) then
           error("network[\($i)].mac-address \"\($mac)\" is not a MAC address.")
         else . end
       | {
           index: $i,
           name: $name,
           driver: $driver,
           parent: ($net.parent // null),
           ipam: $ipam,
           mac: (if $mac == "" then null
                 else $mac | gsub("[-:]"; "") | ascii_downcase
                      | [scan("..")] | join(":") end)
         }]
    | if (map(.name) | unique | length) != length then
        error("docker.nets names a network twice. A container is attached to a network once.")
      else . end;

  # Every resolver of every "network" entry, in order and each once.
  def dns:
    [(.network // [])[]["dns-server"] // empty] | flatten
    | reduce .[] as $s ([]; if any(.[]; . == $s) then . else . + [$s] end);

  # ------------------------------------------------------------------ yaml

  # Enough YAML for a compose file: maps, lists of scalars or maps, and
  # scalars - strings JSON-quoted, which YAML reads as double-quoted
  # strings. A "$" is doubled, or compose would interpolate it.
  def yaml_scalar:
    if type == "string" then gsub("\\$"; "$$") | tojson
    else tojson end;
  def yaml_key:
    if test("^[A-Za-z0-9_][A-Za-z0-9_.-]*$") then . else tojson end;
  def yaml($ind):
    if type == "object" then
      to_entries | map(
        .value as $v
        | $ind + (.key | yaml_key) + ":"
          + (if ($v | type) == "object" or ($v | type) == "array" then
               if ($v | length) == 0 then (if ($v | type) == "object" then " {}\n" else " []\n" end)
               else "\n" + ($v | yaml($ind + "  ")) end
             else " " + ($v | yaml_scalar) + "\n" end))
      | join("")
    elif type == "array" then
      map(
        if type == "object" and length > 0 then
          yaml($ind + "  ") | $ind + "- " + .[($ind | length) + 2:]
        elif type == "array" and length > 0 then error("yaml: a list in a list")
        elif type == "object" then $ind + "- {}\n"
        elif type == "array" then $ind + "- []\n"
        else $ind + "- " + yaml_scalar + "\n" end)
      | join("")
    else yaml_scalar + "\n" end;

  # A compose project, service or volume name: lower case, digits, "-", "_".
  def compose_name:
    ascii_downcase | gsub("[^a-z0-9_-]"; "-") | ltrimstr("-") | ltrimstr("_");
'

action_image() {
  local image
  image="$(printf '%s' "${CONFIG}" | jq -c --arg platform "${PLATFORM}" \
    "${JQ_LIB}"' image($platform)' 2>&1)" || raise "${image#jq: error*: }"
  printf '%s\n' "${image}"
}

# Until the published images read CUOS_IMAGE themselves (cuos, init.sh
# container_env), the hook writes /etc/image after the start. Guarded: an
# update inside the container switches the slot and writes /etc/image itself,
# and every later start would undo it. Its only race is with init.sh's own
# first-run on the very first start, and either order ends with the image named.
POST_START='[ -f /etc/image ] && [ "$(cat /etc/image)" != "unknown@unknown" ] || exec /usr/local/cuos/first-run.sh A "$CUOS_IMAGE" "$CUOS_IMAGE_DIGEST"'

# The compose file as JSON, before it is written as YAML.
compose_json() {
  [[ -n "${IMAGE_NAME}" ]] || raise "IMAGE_NAME is not set. Run this through tool.sh."
  [[ -n "${CONFIG_FILE}" ]] || raise "CONFIG_FILE is not set. Run this through tool.sh."

  local json
  json="$(printf '%s' "${CONFIG}" | jq \
    --arg platform "${PLATFORM}" \
    --arg name "${IMAGE_NAME}" \
    --arg config_file "${CONFIG_FILE}" \
    --arg post_start "${POST_START}" \
    "${JQ_LIB}"'
    image($platform) as $image
    | networks as $networks
    | dns as $dns
    | ($name | compose_name) as $service
    | {
        name: $service,
        services: {
          ($service): ({
            image: $image.ref,
            platform: $image.platform,
            pull_policy: "missing",
            entrypoint: ["/sbin/init"],
            hostname: (.hostname // null),
            privileged: true,
            tty: true,
            stop_signal: "SIGRTMIN+3",
            environment: {
              CUOS_IMAGE: $image.image,
              CUOS_IMAGE_DIGEST: (if $image.digest == "" then "unknown" else $image.digest end)
            },
            post_start: [{command: ["sh", "-c", $post_start]}],
            volumes: [
              {type: "volume", source: ($service + "-data"), target: "/data"},
              {type: "bind", source: $config_file, target: "/system_init.json",
               read_only: true, bind: {create_host_path: false}}
            ],
            networks: ($networks | map({
              key: .name,
              value: ({
                priority: (1000 - .index),
                ipv4_address: .ipam.address,
                mac_address: .mac
              } | with_entries(select(.value != null)))
            }) | from_entries),
            dns: (if ($dns | length) > 0 then $dns else null end)
          } | with_entries(select(.value != null)))
        },
        volumes: {($service + "-data"): {}},
        networks: ($networks | map({
          key: .name,
          value: ({
            driver: .driver,
            driver_opts: (if .parent then {parent: .parent} else null end),
            ipam: (if .ipam then
                     {config: [{subnet: .ipam.subnet, gateway: .ipam.gateway}
                               | with_entries(select(.value != null))]}
                   else null end)
          } | with_entries(select(.value != null)))
        }) | from_entries)
      }
    ' 2>&1)" || raise "${json#jq: error*: }"
  printf '%s\n' "${json}"
}

# A JSON value on stdin, as YAML.
to_yaml() {
  jq -r "${JQ_LIB}"' yaml("")'
}

action_compose() {
  local json
  json="$(compose_json)" || exit 1

  cat <<EOF
# Written by 'tool.sh ${COMMAND_LINE}'. Every run writes it again:
# put services of your own in a file that includes this one -
#   include:
#     - ${IMAGE_NAME}.compose.yml
#
# 'docker compose down' keeps the volume, and with it the configuration CuOS
# read on its first start. 'down -v' starts over.
EOF
  printf '%s' "${json}" | to_yaml
}

main() {
  local action="${1:-}"

  command -v jq >/dev/null 2>&1 || raise "jq is required but not installed."

  CONFIG="$(cat)"
  [[ -n "${CONFIG}" ]] || raise "No configuration on stdin. Run this through tool.sh."

  case "${action}" in
    image) action_image ;;
    compose) action_compose ;;
    *) raise "Unknown action '${action}'. Use image or compose." ;;
  esac
}

# Execute main only if the script is run, not sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
