#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Almost every assignment here is an input of the sourced script under test -
# CONFIG, PLATFORM, REPLACE and the rest - which shellcheck cannot see being
# read, so SC2034 is off for the whole file.
# shellcheck disable=SC2034

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Nothing here talks to a Proxmox host: under PROXMOX_DRY_RUN=1 'upload' and
# 'run_batch' print instead of acting, and 'remote_state' is replaced below.
export PROXMOX_DRY_RUN=1
export PROXMOX_HOST="root@pve-test"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/proxmox.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-test.sh"

# proxmox.sh runs under 'set -e'; expect_rc needs a non-zero return not to end
# the test run.
set +e

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
OUTPUT_DIR="${TMP}"

MOCK_RESOURCES='[]'

# The one read-only round trip, answered locally. Everything the decisions below
# depend on comes from here.
remote_state() {
  printf '{"resources":%s,"nextid":"131","storage":{"path":"/var/lib/vz"}}\n' \
    "${MOCK_RESOURCES}"
}

# What a run would send to the host, in order. The trace goes to stderr, so that
# a caller can pipe the result of a command and still see what produced it.
trace() {
  { "$@" >/dev/null; } 2>&1
}

# raise() ends the process, so anything asserted to fail runs in a subshell.
fails() {
  ( "$@" ) >/dev/null 2>&1
}

# The artefact lives in a temporary directory, whose name changes every run.
create_trace() {
  trace action_create | sed "s|${TMP}/|/output/|"
}
guest_kind() {
  echo "${GUEST_TYPE} ${CLI}"
}

# --------------------------------------------------------------- reading the keys

CONFIG='{"hostname":"my-system","proxmox":{"cores":8,"onboot":false}}'

expect "cfg: value from the config" "8" cfg cores 2
expect "cfg: default when absent" "2" cfg memory 2
expect "cfg: absent and no default" "" cfg memory
expect "cfg_flag: false is a value, not an absence" "0" cfg_flag onboot true
expect "cfg_flag: default applies when absent" "1" cfg_flag unprivileged true
expect "sys: top-level key" "my-system" sys '.hostname'

CONFIG='{"proxmox":{"onboot":"maybe"}}'
expect_rc "cfg_flag: rejects a non-boolean" 1 fails cfg_flag onboot true

# ------------------------------------------------------- quoting for the remote

expect "remote_cmd: plain words are left alone" \
  "qm start 131" remote_cmd qm start 131
expect "remote_cmd: a ';' is quoted for the remote shell" \
  "qm set 131 --boot 'order=scsi0;ide2'" \
  remote_cmd qm set 131 --boot 'order=scsi0;ide2'
expect "remote_cmd: a space survives" \
  "pct set 131 --description 'two words'" \
  remote_cmd pct set 131 --description 'two words'

# ------------------------------------------------------------------- the target

CONFIG='{"hostname":"my-system"}'
PLATFORM="x86_64"
expect_rc "resolve_target: succeeds with a host in the environment" 0 fails resolve_target

PROXMOX_HOST=""
expect_rc "resolve_target: no host anywhere is an error" 1 fails resolve_target
PROXMOX_HOST="root@pve-test"

resolve_target
expect "resolve_target: a non-lxc platform is a VM" "qemu qm" guest_kind
expect "resolve_target: the name comes from the hostname" "my-system" \
  echo "${GUEST_NAME}"

PLATFORM="lxc"
resolve_target
expect "resolve_target: platform lxc is a container" "lxc pct" guest_kind

CONFIG='{"hostname":"my-system","proxmox":{"name":"other-name"}}'
resolve_target
expect "resolve_target: proxmox.name wins over the hostname" "other-name" \
  echo "${GUEST_NAME}"

# ----------------------------------------------------------------- the artefact

CONFIG='{"hostname":"my-system"}'
IMAGE_NAME="CuOS-my-system"

PLATFORM="lxc"; resolve_target; resolve_artefact
expect "resolve_artefact: lxc takes the container export" \
  "${TMP}/CuOS-my-system.tar.gz" echo "${ARTEFACT}"

PLATFORM="x86_64"; resolve_target
: >"${TMP}/CuOS-my-system.img"
resolve_artefact
expect "resolve_artefact: falls back to the disk image" "img" \
  echo "${ARTEFACT_KIND}"
: >"${TMP}/CuOS-my-system.iso"
resolve_artefact
expect "resolve_artefact: the installer wins when both exist" "iso" \
  echo "${ARTEFACT_KIND}"

PROXMOX_ARTEFACT="img"
resolve_artefact
expect "resolve_artefact: --artefact forces the choice" "img" \
  echo "${ARTEFACT_KIND}"
PROXMOX_ARTEFACT="qcow2"
expect_rc "resolve_artefact: rejects an unknown kind" 1 fails resolve_artefact
PROXMOX_ARTEFACT=""

# --------------------------------------------- the container's Proxmox network

PLATFORM="lxc"

expect "mask_to_prefix: dotted-decimal" "24" mask_to_prefix 255.255.255.0
expect "mask_to_prefix: an unusual but valid mask" "20" mask_to_prefix 255.255.240.0
expect "mask_to_prefix: all ones" "32" mask_to_prefix 255.255.255.255
expect "mask_to_prefix: a prefix length passes through" "26" mask_to_prefix 26
expect_rc "mask_to_prefix: rejects a non-contiguous mask" 1 fails \
  mask_to_prefix 255.0.255.0
expect_rc "mask_to_prefix: rejects nonsense" 1 fails mask_to_prefix not-a-mask

# CuOS configures no network inside a container (init.sh, configure_network),
# so the "network" section is Proxmox's to use.
CONFIG='{"hostname":"c","network":[{"ip-address":"10.0.0.5","network-mask":"255.255.255.0","gateway":"10.0.0.1","dns-server":"10.0.0.1"}]}'
resolve_placement
expect "lxc_net0: the address comes from the network section" \
  "name=eth0,bridge=vmbr0,ip=10.0.0.5/24,gw=10.0.0.1,ip6=none" lxc_net0
expect "lxc_nameserver: one resolver from the network section" "10.0.0.1" \
  lxc_nameserver

CONFIG='{"hostname":"c","network":[{"dns-server":["10.0.0.1","10.0.0.2"]}]}'
resolve_placement
expect "lxc_nameserver: a list becomes a space-separated one" "10.0.0.1 10.0.0.2" \
  lxc_nameserver

CONFIG='{"hostname":"c","network":[{"dhcp":true}]}'
resolve_placement
expect "lxc_net0: dhcp in the network section" \
  "name=eth0,bridge=vmbr0,ip=dhcp,ip6=none" lxc_net0

CONFIG='{"hostname":"c","network":[{"ip-address":"10.0.0.5"}]}'
resolve_placement
expect_rc "lxc_net0: an address without a mask is an error" 1 fails lxc_net0

CONFIG='{"hostname":"c"}'
resolve_placement
expect "lxc_net0: no network at all -> DHCP" \
  "name=eth0,bridge=vmbr0,ip=dhcp,ip6=none" lxc_net0
expect "lxc_nameserver: nothing to say" "" lxc_nameserver

CONFIG='{"hostname":"c","network":[{"ip-address":"10.0.0.5","network-mask":"255.255.255.0"}],"proxmox":{"ip":"192.168.0.9/24","gateway":"192.168.0.1","bridge":"vmbr1"}}'
resolve_placement
expect "lxc_net0: the proxmox keys win over the network section" \
  "name=eth0,bridge=vmbr1,ip=192.168.0.9/24,gw=192.168.0.1,ip6=none" lxc_net0

CONFIG='{"hostname":"c","proxmox":{"ip":"10.0.0.5"}}'
resolve_placement
expect_rc "lxc_net0: proxmox.ip without a prefix length is an error" 1 fails lxc_net0

CONFIG='{"hostname":"c","proxmox":{"net0":"name=eth0,bridge=vmbr9,ip=dhcp"}}'
resolve_placement
expect "lxc_net0: proxmox.net0 is passed through verbatim" \
  "name=eth0,bridge=vmbr9,ip=dhcp" lxc_net0

# -------------------------------------------------------------- what gets issued

CONFIG='{"hostname":"my-system","proxmox":{"memory":2048,"cores":2,"disk_size":32}}'
PLATFORM="x86_64"
PROXMOX_ARTEFACT="iso"
resolve_target

EXPECTED_VM="scp /output/CuOS-my-system.iso root@pve-test:/var/lib/vz/template/iso/CuOS-my-system.iso
ssh root@pve-test bash -s <<'EOS'
set -eux
qm create 131 --name my-system --memory 2048 --cores 2 --sockets 1 --ostype l26 --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci --scsi0 local:32 --ide2 local:iso/CuOS-my-system.iso,media=cdrom --boot 'order=scsi0;ide2' --onboot 1
qm start 131
EOS"

expect "create: a VM from an installer ISO" "${EXPECTED_VM}" create_trace

CONFIG='{"hostname":"my-system","network":[{"ip-address":"10.0.0.5","network-mask":"255.255.255.0","gateway":"10.0.0.1","dns-server":"10.0.0.1"}],"proxmox":{"memory":2048,"cores":4,"disk_size":20}}'
PLATFORM="lxc"
PROXMOX_ARTEFACT=""
resolve_target
: >"${TMP}/CuOS-my-system.tar.gz"

EXPECTED_LXC="scp /output/CuOS-my-system.tar.gz root@pve-test:/var/lib/vz/template/cache/CuOS-my-system.tar.gz
ssh root@pve-test bash -s <<'EOS'
set -eux
pct create 131 local:vztmpl/CuOS-my-system.tar.gz --hostname my-system --storage local --rootfs local:20 --memory 2048 --cores 4 --net0 name=eth0,bridge=vmbr0,ip=10.0.0.5/24,gw=10.0.0.1,ip6=none --features nesting=1 --unprivileged 0 --onboot 1 --nameserver 10.0.0.1
pct start 131
EOS"

expect "create: an LXC container from a container export" "${EXPECTED_LXC}" \
  create_trace

started_line() {
  trace action_create | grep -E "^pct start"
}
NO_START=1
expect "create: --no-start leaves the guest stopped" "" started_line
NO_START=0

# ----------------------------------------------------- existing guests are safe

MOCK_RESOURCES='[{"type":"lxc","name":"my-system","vmid":124,"status":"running"}]'
expect_rc "create: an existing guest of the same name is an error" 1 fails action_create

REPLACE=1
ASSUME_YES=1

replace_teardown() {
  trace action_create | grep -E "^pct (stop|destroy)"
}
expect "create: --replace stops and destroys the existing guest first, in the
         same batch as the create" \
  "pct stop 124
pct destroy 124 --purge" replace_teardown

expect "create: --replace reuses the id that guest already had" \
  "pct start 124" started_line

MOCK_RESOURCES='[{"type":"qemu","name":"someone-elses-vm","vmid":124,"status":"running"}]'
PROXMOX_VMID=124
expect_rc "create: an id held by an unrelated guest is never taken" 1 fails action_create
PROXMOX_VMID=""
REPLACE=0

# ---------------------------------------------------------- destroy and status

MOCK_RESOURCES='[{"type":"lxc","name":"my-system","vmid":124,"status":"stopped"}]'

expect "destroy: a stopped guest is not stopped again" \
  "ssh root@pve-test bash -s <<'EOS'
set -eux
pct destroy 124 --purge
EOS" trace action_destroy

expect "status: reports the state" \
  "my-system: pct 124 on root@pve-test is stopped" action_status

MOCK_RESOURCES='[]'
expect_rc "status: a missing guest exits non-zero" 1 fails action_status
expect_rc "destroy: a missing guest is an error" 1 fails action_destroy

summary
