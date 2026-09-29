#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# artefact-name.sh: the default name, its fallbacks, and the 'artefact_name'
# template.

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

name_of() {
  echo "$1" | "${SCRIPT_DIR}/artefact-name.sh" 2>/dev/null
}

error_of() {
  # stderr onto the captured stdout, then stdout discarded - not "both into one".
  # shellcheck disable=SC2069
  echo "$1" | "${SCRIPT_DIR}/artefact-name.sh" 2>&1 >/dev/null
}

# --- without artefact_name ---------------------------------------------------

expect "default: product and system name" \
  "Acme-OS-plant-7" \
  name_of '{"product_name": "Acme OS", "system_name": "plant-7"}'

expect "default: CuOS IaC for a cuos-iac init image, hostname as system name" \
  "CuOS-IaC-edge" \
  name_of '{"init_image": "ghcr.io/cuos-dev/cuos-iac", "hostname": "edge"}'

expect "default: CuOS, and the directory of a system.json" \
  "CuOS-line-3" \
  name_of '{"init_image": "ghcr.io/acme/app", "__filename": "systems/line-3/system.json"}'

expect "default: the file name of any other configuration" \
  "CuOS-test-vm" \
  name_of '{"__filename": "systems/test-vm.json"}'

# --- with artefact_name ------------------------------------------------------

expect "template: any key of the configuration" \
  "Acme-OS-plant-7-1.4.0" \
  name_of '{"artefact_name": "{product_name}-{system_name}-{product_version}",
            "product_name": "Acme OS", "system_name": "plant-7",
            "product_version": "1.4.0"}'

expect "template: product and system name keep their defaults" \
  "CuOS-IaC-edge-v0.6.2" \
  name_of '{"artefact_name": "{product_name}-{system_name}-{os_image_version}",
            "init_image": "ghcr.io/cuos-dev/cuos-iac", "hostname": "edge",
            "os_image_version": "v0.6.2"}'

expect "template: a number is used as it is" \
  "build-42" \
  name_of '{"artefact_name": "build-{build}", "build": 42}'

expect "template: spaces become dashes, also those of the template" \
  "Acme-OS-plant-7-final" \
  name_of '{"artefact_name": "{product_name} {system_name} final",
            "product_name": "Acme OS", "system_name": "plant-7"}'

expect "template: braces in a value are not expanded again" \
  "x-{system_name}" \
  name_of '{"artefact_name": "x-{v}", "v": "{system_name}", "system_name": "s"}'

expect_rc "template: a missing key fails" \
  1 \
  name_of '{"artefact_name": "{product_name}-{product_version}"}'

expect "template: the failure names the key" \
  'artefact_name "{product_name}-{product_version}": the configuration has no value for {product_version}.' \
  error_of '{"artefact_name": "{product_name}-{product_version}"}'

expect_rc "template: an empty value fails" \
  1 \
  name_of '{"artefact_name": "{product_version}", "product_version": ""}'

expect_rc "template: an object fails" \
  1 \
  name_of '{"artefact_name": "{proxmox}", "proxmox": {"host": "pve"}}'

summary
