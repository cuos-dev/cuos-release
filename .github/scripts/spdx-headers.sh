#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# spdx-headers.sh — check or add SPDX license headers in a CuOS repository.
#
#   ./spdx-headers.sh check [REPO_DIR]   # list files missing a header; exit 1 if any
#   ./spdx-headers.sh fix   [REPO_DIR]   # insert the header where it is missing
#   ./spdx-headers.sh list  [REPO_DIR]   # list every file considered in scope
#
# REPO_DIR defaults to the current directory. Only git-tracked files are
# considered, so build output and untracked scratch files are ignored.
#
# Policy: Apache-2.0 for every file CuOS itself authors — see
# brain/decisions/0007-apache-2-0-everywhere.md. There is still no license map:
# every in-scope file gets the same identifier. What there now *is* is a short
# list of vendored third-party files that must never be stamped at all, because
# they carry someone else's license — see third_party() below.
#
# Scope and exclusions are defined in third_party()/in_scope()/comment_style()
# below, with a reason per exclusion. Keep them there and nowhere else.
#
# Run by .github/workflows/ci.yml. The same file is vendored in all four CuOS
# repositories; change it in one and copy it to the others.

set -euo pipefail

IDENTIFIER="Apache-2.0"
MODE="${1:-check}"
REPO_DIR="${2:-.}"

usage() {
  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's|^# \?||'
  exit 2
}

case "${MODE}" in
  check|fix|list) ;;
  *) usage ;;
esac

cd "${REPO_DIR}" || { echo "Error: cannot enter ${REPO_DIR}" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "Error: ${REPO_DIR} is not a git repository." >&2; exit 2; }

# Which comment syntax a file uses — also decides whether it is in scope at all.
comment_style() {
  local file="$1"
  case "${file}" in
    # ---- in scope -----------------------------------------------------------
    *.sh|Dockerfile|*/Dockerfile|Dockerfile.*|*/Dockerfile.*) echo hash ;;
    .github/*.yml|.github/*.yaml|*/.github/*.yml|*/.github/*.yaml) echo hash ;;
    docker-compose*.yml|*/docker-compose*.yml) echo hash ;;
    *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx) echo slash ;;
    *.css) echo block ;;

    # ---- out of scope, with the reason --------------------------------------
    # *.json          — JSON cannot carry comments (schemas, fixtures, package*)
    # *.md            — documentation; the license is stated in LICENSE/NOTICE
    # *.handlebars    — could use {{!-- --}}; deliberately left out for now
    # *.test.*.yml    — test fixtures: a header may change what a test compares
    # *.gpg, *.key    — third-party archive keys and binary material
    # *.png           — binary
    # LICENSE*, NOTICE, DCO.txt, *.rc, *.service, *.socket, *.env, *.cmd
    #                 — legal texts and small config files
    # NB cuos/system/armbianEnv.txt carries an Apache-2.0 header anyway (U-Boot
    #    skips '#' lines on "env import -t", verified 2026-08-26). It is out of
    #    scope here, so the tool neither checks nor maintains it.
    *) echo "" ;;
  esac
}

# Vendored third-party files. These carry someone else's copyright, so this
# script must never stamp them with the project identifier — not even if the
# extension is later brought into scope. They are listed here rather than in
# comment_style() so the reason survives a change to the scope rules.
# Attribution for each one lives in the repo's NOTICE.
third_party() {
  case "$1" in
    # Armbian U-Boot boot script for Allwinner H616 (Orange Pi Zero 3), from
    # armbian/build config/bootscripts/boot-sun50iw9.cmd — GPL-2.0-only.
    system/armbian-boot.cmd|*/system/armbian-boot.cmd) return 0 ;;
  esac
  return 1
}

in_scope() {
  local file="$1"

  # Someone else's license: never in scope, whatever the extension says.
  third_party "${file}" && return 1

  # The test *scripts* are ordinary shell code and must be matched BEFORE the
  # fixture exclusion below — `api.test.sh` also matches `*.test.*`.
  case "${file}" in
    *.test.sh) return 0 ;;
  esac
  # Test fixtures: never touch, whatever the extension. A header could change
  # what a test compares. This also covers the fixture directories, whose paths
  # contain ".test." as well - init.test.sys_class_net/eth0/address and the like.
  case "${file}" in
    *.test.*) return 1 ;;
  esac

  case "${file}" in
    */node_modules/*|node_modules/*) return 1 ;;
    */dist/*|dist/*) return 1 ;;
    *.min.js) return 1 ;;
  esac

  [[ -n "$(comment_style "${file}")" ]] && return 0

  # Extensionless files count when they carry a shebang (dev-container/docker,
  # iac/api/*, initramfs hooks).
  if [[ "$(basename "${file}")" != *.* ]] && [[ -f "${file}" ]]; then
    head -c2 "${file}" 2>/dev/null | grep -q '#!' && return 0
  fi
  return 1
}

style_for() { # extensionless shebang files are shell
  local s
  s="$(comment_style "$1")"
  echo "${s:-hash}"
}

has_header() {
  head -5 "$1" 2>/dev/null | grep -q "SPDX-License-Identifier"
}

header_line() {
  case "$1" in
    hash)  echo "# SPDX-License-Identifier: ${IDENTIFIER}" ;;
    slash) echo "// SPDX-License-Identifier: ${IDENTIFIER}" ;;
    block) echo "/* SPDX-License-Identifier: ${IDENTIFIER} */" ;;
  esac
}

# Insert the header. A shebang MUST stay on line 1 — inserting above it breaks
# the file. This bug shipped twice during the initial sweep; do not "simplify"
# it away.
insert_header() {
  local file="$1" line="$2" tmp
  tmp="$(mktemp)"
  if head -1 "${file}" | grep -q '^#!'; then
    { head -1 "${file}"; echo "${line}"; tail -n +2 "${file}"; } >"${tmp}"
  else
    { echo "${line}"; cat "${file}"; } >"${tmp}"
  fi
  cat "${tmp}" >"${file}"   # preserves mode and ownership
  rm -f "${tmp}"
}

missing=0
fixed=0
scoped=0

while IFS= read -r file; do
  [[ -f "${file}" ]] || continue          # deleted but still tracked
  in_scope "${file}" || continue
  scoped=$((scoped + 1))

  if [[ "${MODE}" == "list" ]]; then
    printf '%s\t%s\n' "$(style_for "${file}")" "${file}"
    continue
  fi

  has_header "${file}" && continue

  if [[ "${MODE}" == "fix" ]]; then
    insert_header "${file}" "$(header_line "$(style_for "${file}")")"
    echo "added: ${file}"
    fixed=$((fixed + 1))
  else
    echo "missing header: ${file}"
    missing=$((missing + 1))
  fi
done < <(git ls-files)

case "${MODE}" in
  list)
    echo "---"
    echo "${scoped} files in scope"
    ;;
  fix)
    echo "---"
    echo "${fixed} header(s) added, ${scoped} files in scope"
    ;;
  check)
    if (( missing > 0 )); then
      echo "---" >&2
      echo "FAIL: ${missing} of ${scoped} in-scope files lack an SPDX header." >&2
      echo "Run: $(basename "${BASH_SOURCE[0]}") fix" >&2
      exit 1
    fi
    echo "OK: all ${scoped} in-scope files carry an SPDX header."
    ;;
esac
