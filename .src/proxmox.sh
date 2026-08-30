#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# proxmox.sh — put a built artefact on a Proxmox VE host as a guest, or take it
# off again.
#
# Invoked by tool.sh as './proxmox.sh create|destroy|status' with the merged
# configuration on stdin. Everything else arrives in the environment:
#
#   PLATFORM             resolved platform; "lxc" selects pct, anything else qm
#   IMAGE_NAME           artefact name without extension (tool.sh 'name')
#   OUTPUT_DIR           where the artefacts are
#   PROXMOX_HOST         overrides proxmox.host
#   PROXMOX_VMID         overrides proxmox.vmid
#   PROXMOX_ARTEFACT     overrides proxmox.artefact ("iso" or "img")
#   PROXMOX_REPLACE      1: destroy an existing guest of the same name first
#   PROXMOX_YES          1: do not ask before destroying
#   PROXMOX_NO_START     1: create the guest but leave it stopped
#   PROXMOX_DRY_RUN      1: print the commands instead of running them
#
# The keys it reads and what they default to: docs/testing-on-proxmox.md.
#
# One run makes three ssh channels over a single multiplexed connection: it
# reads the host's state, uploads the artefact, and sends every mutating command
# as one script. The decisions in between - which id, does it exist, may it be
# destroyed - are made here, locally, so they stay testable and so the guest
# owner can be asked before anything is destroyed.

set -euo pipefail

PLATFORM="${PLATFORM:-}"
IMAGE_NAME="${IMAGE_NAME:-}"
OUTPUT_DIR="${OUTPUT_DIR:-"${PWD}/output"}"
REPLACE="${PROXMOX_REPLACE:-0}"
ASSUME_YES="${PROXMOX_YES:-0}"
NO_START="${PROXMOX_NO_START:-0}"
DRY_RUN="${PROXMOX_DRY_RUN:-0}"

raise() {
  echo "Error: $*" >&2
  exit 1
}

# ---------------------------------------------------------------- configuration

CONFIG=""

# A value from the "proxmox" object, or $2 if the key is absent or null.
# 'false' is a value and not an absence, so has() decides rather than jq's
# '//' operator, which treats false as missing.
cfg() {
  local value
  value="$(printf '%s' "${CONFIG}" | jq -r --arg k "$1" '
    (.proxmox // {})
    | if has($k) and .[$k] != null then .[$k] else empty end')"
  if [[ -z "${value}" ]]; then
    printf '%s' "${2:-}"
  else
    printf '%s' "${value}"
  fi
}

# 1 or 0, for a key holding a boolean.
cfg_flag() {
  case "$(cfg "$1" "$2")" in
    1|true|yes|on) echo 1 ;;
    0|false|no|off) echo 0 ;;
    *) raise "proxmox.$1 must be true or false." ;;
  esac
}

# A jq expression against the configuration itself, for the keys that describe
# the system rather than its placement.
sys() {
  printf '%s' "${CONFIG}" | jq -r "$1"
}

# ------------------------------------------------------------------- the remote

SSH_PORT=""
SSH_CONTROL_DIR=""

# One remote command line, every word quoted for the remote shell. The words
# become a line of a script that bash runs on the far side, so a value
# containing a space or a ';' - '--boot order=scsi0;ide2' - has to be quoted
# here, once, rather than at each call site.
remote_cmd() {
  local out="" word escaped
  for word in "$@"; do
    if [[ "${word}" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      out+="${word} "
    else
      # An embedded single quote closes the quoting, escapes itself, reopens it.
      escaped="${word//\'/\'\\\'\'}"
      out+="'${escaped}' "
    fi
  done
  printf '%s' "${out% }"
}

# Multiplexing: the first connection carries the rest, so a run costs one TCP
# handshake and one authentication instead of one per command. Started from
# main() only, so that sourcing this file for a test sets up nothing and
# installs no trap.
ssh_control_start() {
  SSH_CONTROL_DIR="$(mktemp -d)"
}

ssh_control_stop() {
  if [[ -n "${SSH_CONTROL_DIR}" ]]; then
    if [[ -S "${SSH_CONTROL_DIR}/m" ]]; then
      ssh -o "ControlPath=${SSH_CONTROL_DIR}/m" -O exit "${HOST}" 2>/dev/null || true
    fi
    rm -rf "${SSH_CONTROL_DIR}"
    SSH_CONTROL_DIR=""
  fi
}

ssh_to() {
  local args=()
  [[ -z "${SSH_PORT}" ]] || args+=(-p "${SSH_PORT}")
  if [[ -n "${SSH_CONTROL_DIR}" ]]; then
    args+=(
      -o "ControlMaster=auto"
      -o "ControlPath=${SSH_CONTROL_DIR}/m"
      -o "ControlPersist=30"
    )
  fi
  ssh "${args[@]}" "${HOST}" "$@"
}

upload() {
  local target="$1"
  echo "scp ${ARTEFACT} ${HOST}:${target}" >&2
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  local args=()
  [[ -z "${SSH_PORT}" ]] || args+=(-P "${SSH_PORT}")
  if [[ -n "${SSH_CONTROL_DIR}" ]]; then
    args+=(-o "ControlPath=${SSH_CONTROL_DIR}/m")
  fi
  scp "${args[@]}" "${ARTEFACT}" "${HOST}:${target}"
}

# ---------------------------------------------------------- the mutating batch

# Every command that changes something is collected and sent as one script, so
# that a run makes one connection for all of them and 'set -e' on the far side
# stops the sequence at the first failure instead of leaving a half-created
# guest behind.
BATCH=()

queue() {
  BATCH+=("$(remote_cmd "$@")")
}

# The script as it will be sent — also what --dry-run prints, in a form that can
# be pasted into a terminal.
batch_script() {
  printf '%s\n' 'set -eux' "${BATCH[@]}"
}

run_batch() {
  if [[ "${#BATCH[@]}" -eq 0 ]]; then
    return 0
  fi

  {
    echo "ssh ${HOST} bash -s <<'EOS'"
    batch_script
    echo "EOS"
  } >&2

  if [[ "${DRY_RUN}" != "1" ]]; then
    batch_script | ssh_to bash -s
  fi
  BATCH=()
}

confirm() {
  if [[ "${ASSUME_YES}" == "1" ]]; then
    return 0
  fi
  # stdin carries the configuration, so the prompt has to go to the terminal.
  if [[ ! -r /dev/tty ]]; then
    raise "$1
       There is no terminal to ask on. Pass --yes to answer in advance."
  fi
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ "${answer}" == [Yy] || "${answer}" == [Yy][Ee][Ss] ]]
}

# --------------------------------------------------------------------- resolving

resolve_target() {
  HOST="${PROXMOX_HOST:-"$(cfg host)"}"
  [[ -n "${HOST}" ]] || raise "No Proxmox host given. Add it to the configuration
         \"proxmox\": { \"host\": \"root@pve-1\" }
       or pass --host root@pve-1. There is deliberately no default."

  SSH_PORT="$(cfg ssh_port)"

  if [[ "${PLATFORM}" == "lxc" ]]; then
    GUEST_TYPE="lxc"
    CLI="pct"
  else
    GUEST_TYPE="qemu"
    CLI="qm"
  fi

  # The guest's name is its identity: it comes from the configuration, so the
  # guest can be found again without an id being recorded anywhere.
  GUEST_NAME="$(cfg name "$(sys '.hostname // empty')")"
  [[ -n "${GUEST_NAME}" ]] || GUEST_NAME="${IMAGE_NAME}"
  [[ -n "${GUEST_NAME}" ]] || raise "The configuration has no 'hostname', and no
       artefact name was resolved. Set \"hostname\", or \"proxmox\": {\"name\": ...}."
}

resolve_artefact() {
  if [[ "${GUEST_TYPE}" == "lxc" ]]; then
    ARTEFACT_KIND="tar.gz"
  else
    local want="${PROXMOX_ARTEFACT:-"$(cfg artefact)"}"
    case "${want}" in
      iso|img)
        ARTEFACT_KIND="${want}"
        ;;
      "")
        # An installer ISO is the more likely thing to want on a hypervisor, so
        # it wins when both have been built.
        if [[ -f "${OUTPUT_DIR}/${IMAGE_NAME}.iso" ]]; then
          ARTEFACT_KIND="iso"
        else
          ARTEFACT_KIND="img"
        fi
        ;;
      *)
        raise "Unknown artefact '${want}'. Use 'iso' or 'img'."
        ;;
    esac
  fi
  ARTEFACT="${OUTPUT_DIR}/${IMAGE_NAME}.${ARTEFACT_KIND}"
}

resolve_placement() {
  STORAGE="$(cfg storage local)"
  # Only a directory-backed storage can hold an ISO or a container template, and
  # that is not necessarily where the disks go.
  TEMPLATE_STORAGE="$(cfg template_storage local)"
  UPLOAD_DIR="$(cfg upload_dir /var/tmp)"
  BRIDGE="$(cfg bridge vmbr0)"
  CORES="$(cfg cores 2)"
  MEMORY="$(cfg memory 4096)"
  DISK_SIZE="$(cfg disk_size 16)"
  ONBOOT="$(cfg_flag onboot true)"
  UNPRIVILEGED="$(cfg_flag unprivileged false)"
  FEATURES="$(cfg features nesting=1)"
}

# --------------------------------------------------------------- the host state

# Everything the local decisions need, in one round trip: what guests exist,
# which id is free, and where the template storage keeps its files. Read even
# under --dry-run, because the commands to be printed depend on the answers.
remote_state() {
  local storage="${1:-}"
  ssh_to bash -s -- "${storage}" <<'REMOTE'
set -euo pipefail
storage="${1:-}"
resources="$(pvesh get /cluster/resources --type vm --output-format json)"
nextid="$(pvesh get /cluster/nextid | tr -d '"[:space:]')"
if [[ -n "${storage}" ]]; then
  storage_json="$(pvesh get "/storage/${storage}" --output-format json)"
else
  storage_json=null
fi
printf '{"resources":%s,"nextid":"%s","storage":%s}\n' \
  "${resources}" "${nextid}" "${storage_json}"
REMOTE
}

STATE=""

load_state() {
  local storage="${1:-}"
  STATE="$(remote_state "${storage}")" || STATE=""
  if [[ -z "${STATE}" ]]; then
    raise "Could not read the state of ${HOST}.
       Reachable over ssh, and may that user run pvesh, ${CLI} and pvesm?${storage:+
       Does the storage '${storage}' exist?}"
  fi
}

vmid_of_name() {
  jq -r --arg name "${GUEST_NAME}" --arg type "${GUEST_TYPE}" '
    [ .resources[] | select(.type == $type and .name == $name) | .vmid ]
    | first // empty
  ' <<<"${STATE}"
}

# "<type> <name>" of whatever holds this id, or empty.
holder_of_vmid() {
  jq -r --arg id "$1" '
    [ .resources[] | select((.vmid | tostring) == $id) | "\(.type) \(.name)" ]
    | first // empty
  ' <<<"${STATE}"
}

state_of_vmid() {
  jq -r --arg id "$1" '
    [ .resources[] | select((.vmid | tostring) == $id) | .status ] | first // empty
  ' <<<"${STATE}"
}

next_free_vmid() {
  jq -r '.nextid // empty' <<<"${STATE}"
}

# The filesystem path of the template storage, needed because an ISO and a
# container template are uploaded as files and only then referred to as volumes.
template_storage_path() {
  local path
  path="$(jq -r '.storage.path // empty' <<<"${STATE}")"
  [[ -n "${path}" ]] || raise "Storage '${TEMPLATE_STORAGE}' has no filesystem
       path, so an ISO or a container template cannot be put there. Point
       \"proxmox\": { \"template_storage\": ... } at a directory storage."
  printf '%s' "${path}"
}

# ---------------------------------------------------------------------- network

# A prefix length, from either spelling of a subnet mask.
mask_to_prefix() {
  local mask="$1"
  if [[ "${mask}" =~ ^[0-9]+$ ]]; then
    (( mask <= 32 )) || raise "'${mask}' is not a prefix length."
    printf '%s' "${mask}"
    return 0
  fi
  [[ "${mask}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
    || raise "Cannot read '${mask}' as a subnet mask."
  local bits prefix
  bits=$(( (BASH_REMATCH[1] << 24) | (BASH_REMATCH[2] << 16) \
         | (BASH_REMATCH[3] << 8) | BASH_REMATCH[4] ))
  # Comparing against every valid mask also rejects a non-contiguous one.
  for prefix in {0..32}; do
    if (( bits == ((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF) )); then
      printf '%s' "${prefix}"
      return 0
    fi
  done
  raise "'${mask}' is not a valid subnet mask."
}

# The Proxmox side of the container's network: the "proxmox" keys if they say
# anything, else the first "network" entry, else DHCP.
#
# The "network" section is Proxmox's to use because CuOS configures no network
# inside a container at all - configure_network() returns immediately for
# VIRT_TYPE lxc (cuos/system/cuos/init.sh) - so the address is stated once and
# serves both.
lxc_net0() {
  local raw
  raw="$(cfg net0)"
  if [[ -n "${raw}" ]]; then
    printf '%s' "${raw}"
    return 0
  fi

  local ip gateway
  ip="$(cfg ip)"
  gateway="$(cfg gateway)"
  if [[ -z "${ip}" ]]; then
    local dhcp address mask prefix
    dhcp="$(sys '(.network // [])[0].dhcp // empty')"
    address="$(sys '(.network // [])[0]["ip-address"] // empty')"
    if [[ "${dhcp}" == "true" ]]; then
      ip="dhcp"
    elif [[ -n "${address}" ]]; then
      mask="$(sys '(.network // [])[0]["network-mask"] // empty')"
      if [[ -z "${mask}" ]]; then
        raise "The first 'network' entry has an 'ip-address' but no
       'network-mask', so the container's address has no prefix length. Add the
       mask, or state the address for Proxmox instead:
         \"proxmox\": { \"ip\": \"${address}/24\" }"
      fi
      # raise() inside a command substitution would only end this shell through
      # 'set -e'; ending it here does not depend on that.
      prefix="$(mask_to_prefix "${mask}")" || exit 1
      ip="${address}/${prefix}"
    fi
    [[ -n "${gateway}" ]] || gateway="$(sys '(.network // [])[0].gateway // empty')"
  fi
  [[ -n "${ip}" ]] || ip="dhcp"

  if [[ "${ip}" != "dhcp" && "${ip}" != */* ]]; then
    raise "proxmox.ip must carry a prefix length, e.g. \"${ip}/24\", or be \"dhcp\"."
  fi

  local net0="name=eth0,bridge=${BRIDGE},ip=${ip}"
  if [[ -n "${gateway}" && "${ip}" != "dhcp" ]]; then
    net0+=",gw=${gateway}"
  fi
  printf '%s' "${net0},ip6=none"
}

# Resolvers for the container, likewise stated once. pct takes a space-separated
# list; system.json allows one name or a list.
lxc_nameserver() {
  local nameserver
  nameserver="$(cfg nameserver)"
  if [[ -z "${nameserver}" ]]; then
    nameserver="$(sys '[(.network // [])[0]["dns-server"] // empty] | flatten | join(" ")')"
  fi
  printf '%s' "${nameserver}"
}

# ---------------------------------------------------------------------- queuing

queue_lxc() {
  upload "$(template_storage_path)/template/cache/$(basename "${ARTEFACT}")"

  local args=(
    pct create "${VMID}" "${TEMPLATE_STORAGE}:vztmpl/$(basename "${ARTEFACT}")"
    --hostname "${GUEST_NAME}"
    --storage "${STORAGE}"
    --rootfs "${STORAGE}:${DISK_SIZE}"
    --memory "${MEMORY}"
    --cores "${CORES}"
    --net0 "$(lxc_net0)"
    --features "${FEATURES}"
    --unprivileged "${UNPRIVILEGED}"
    --onboot "${ONBOOT}"
  )
  local nameserver
  nameserver="$(lxc_nameserver)"
  [[ -z "${nameserver}" ]] || args+=(--nameserver "${nameserver}")

  queue "${args[@]}"
}

queue_vm_from_iso() {
  upload "$(template_storage_path)/template/iso/$(basename "${ARTEFACT}")"

  # Boot order disk first, cdrom second: the disk is empty, so the first boot
  # falls through to the installer and every later one comes off the disk.
  queue qm create "${VMID}" \
    --name "${GUEST_NAME}" \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --sockets 1 \
    --ostype l26 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:${DISK_SIZE}" \
    --ide2 "${TEMPLATE_STORAGE}:iso/$(basename "${ARTEFACT}"),media=cdrom" \
    --boot "order=scsi0;ide2" \
    --onboot "${ONBOOT}"
}

queue_vm_from_image() {
  local staged
  staged="${UPLOAD_DIR}/$(basename "${ARTEFACT}")"
  upload "${staged}"

  # import-from converts the RAW image into a disk on ${STORAGE} as part of
  # creating the VM, so a failure leaves no orphaned volume behind. Needs
  # Proxmox VE 8 or newer.
  queue qm create "${VMID}" \
    --name "${GUEST_NAME}" \
    --memory "${MEMORY}" \
    --cores "${CORES}" \
    --sockets 1 \
    --ostype l26 \
    --net0 "virtio,bridge=${BRIDGE}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:0,import-from=${staged}" \
    --boot "order=scsi0" \
    --onboot "${ONBOOT}"

  queue rm -f "${staged}"
}

queue_destroy() {
  local id="$1"
  if [[ "$(state_of_vmid "${id}")" == "running" ]]; then
    queue "${CLI}" stop "${id}"
  fi
  queue "${CLI}" destroy "${id}" --purge
}

# ----------------------------------------------------------------------- actions

action_create() {
  resolve_artefact
  resolve_placement

  [[ -f "${ARTEFACT}" ]] || raise "Artefact not found: ${ARTEFACT}
       Build it first, e.g. './tool.sh $(build_hint)'."

  load_state "${TEMPLATE_STORAGE}"

  local existing
  existing="$(vmid_of_name)"
  if [[ -n "${existing}" ]]; then
    if [[ "${REPLACE}" != "1" ]]; then
      raise "${CLI} ${existing} on ${HOST} is already named '${GUEST_NAME}'.
       Pass --replace to stop and destroy it first, or give this configuration a
       different 'hostname'."
    fi
    confirm "Stop and destroy ${CLI} ${existing} ('${GUEST_NAME}') on ${HOST}?" \
      || raise "Aborted; nothing was changed."
    queue_destroy "${existing}"
  fi

  VMID="${PROXMOX_VMID:-"$(cfg vmid)"}"
  if [[ -z "${VMID}" ]]; then
    VMID="${existing:-"$(next_free_vmid)"}"
    [[ -n "${VMID}" ]] || raise "${HOST} reported no free id."
  else
    # An id explicitly asked for may be held by something unrelated. That is
    # never destroyed, not even with --replace: only a name match is ours.
    local holder
    holder="$(holder_of_vmid "${VMID}")"
    if [[ -n "${holder}" && "${VMID}" != "${existing}" ]]; then
      raise "${VMID} on ${HOST} is in use by ${holder}. Pick another id."
    fi
  fi

  case "${GUEST_TYPE}:${ARTEFACT_KIND}" in
    lxc:*) queue_lxc ;;
    qemu:iso) queue_vm_from_iso ;;
    qemu:img) queue_vm_from_image ;;
  esac

  if [[ "${NO_START}" != "1" ]]; then
    queue "${CLI}" start "${VMID}"
  fi

  run_batch

  if [[ "${NO_START}" == "1" ]]; then
    echo "Created ${CLI} ${VMID} ('${GUEST_NAME}'), not started (--no-start)."
  else
    echo "Created and started ${CLI} ${VMID} ('${GUEST_NAME}') on ${HOST}."
  fi
}

action_destroy() {
  load_state

  local existing
  existing="${PROXMOX_VMID:-"$(vmid_of_name)"}"
  if [[ -z "${existing}" ]]; then
    raise "No ${CLI} guest named '${GUEST_NAME}' on ${HOST}."
  fi

  confirm "Stop and destroy ${CLI} ${existing} ('${GUEST_NAME}') on ${HOST}?" \
    || raise "Aborted; nothing was changed."
  queue_destroy "${existing}"
  run_batch
  echo "Destroyed ${CLI} ${existing} on ${HOST}."
}

action_status() {
  load_state

  local existing
  existing="${PROXMOX_VMID:-"$(vmid_of_name)"}"
  if [[ -z "${existing}" ]]; then
    echo "${GUEST_NAME}: no ${CLI} guest on ${HOST}"
    return 1
  fi
  echo "${GUEST_NAME}: ${CLI} ${existing} on ${HOST} is $(state_of_vmid "${existing}")"
}

# Which tool.sh command would have produced the missing artefact.
build_hint() {
  case "${GUEST_TYPE}:${ARTEFACT_KIND}" in
    lxc:*) echo "image --platform lxc CONFIG" ;;
    qemu:iso) echo "installer CONFIG" ;;
    *) echo "image CONFIG" ;;
  esac
}

main() {
  local action="${1:-}"

  command -v jq >/dev/null 2>&1 || raise "jq is required but not installed."

  CONFIG="$(cat)"
  [[ -n "${CONFIG}" ]] || raise "No configuration on stdin. Run this through tool.sh."

  resolve_target

  ssh_control_start
  trap ssh_control_stop EXIT

  case "${action}" in
    create) action_create ;;
    destroy) action_destroy ;;
    status) action_status ;;
    *) raise "Unknown action '${action}'. Use create, destroy or status." ;;
  esac
}

# Execute main only if the script is run, not sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
