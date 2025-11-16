#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Detect whether we are in a git repo
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: Not a git repository." >&2
  exit 2
fi

TOP_REPO_DIR="$(git rev-parse --show-superproject-working-tree 2>/dev/null)"
TOP_REPO_DIR="${TOP_REPO_DIR:-"$(git rev-parse --show-toplevel)"}"

git -C "${SCRIPT_DIR}" config allowedSignersFile "./.allowed-signers"

if [ ! -f "$TOP_REPO_DIR/.gitmodules" ]; then
  echo "Error: no submodules found." >&2
  exit 1
fi

# ensure submodule working trees exist
git -C "${TOP_REPO_DIR}" submodule update --init --recursive

git -C "${TOP_REPO_DIR}" submodule foreach --recursive '
  echo "=== $name ($path) ==="
  # fetch remote
  git fetch --prune origin

  # determine branch to follow: first .gitmodules setting, then local branch, then origin/HEAD
  cfg_branch="$(git config --file '"${TOP_REPO_DIR}"'/.gitmodules submodule."$path".branch || true)"
  local_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [ -n "$cfg_branch" ]; then
    branch="$cfg_branch"
  elif [ -n "$local_branch" ]; then
    branch="$local_branch"
  else
    # fallback: ask origin for its HEAD branch
    branch="$(git ls-remote --symref origin HEAD 2>/dev/null | awk "/^ref:/ {print \$3; exit}" | sed "s@refs/heads/@@")"
  fi

  # resolve remote ref to commit
  if [ -n "$branch" ]; then
    remote_ref="origin/$branch"
  else
    remote_ref="origin/HEAD"
  fi

  remote_sha=$(git rev-parse --verify --quiet "$remote_ref") || remote_sha=""
  if [ -z "$remote_sha" ]; then
    echo "Could not resolve $remote_ref; skipping"
    exit 0
  fi

  echo "Remote tip $remote_ref => $remote_sha"

  local_sha="$(git rev-parse --verify --quiet HEAD)" || local_sha=""
  if [[ "$remote_sha" == "$local_sha" ]]; then
    echo "No update required."
    exit 0
  fi

  # verify the remote commit (and its chain if desired). Here we verify the single tip commit.
  if git verify-commit "$remote_sha"; then
    echo "Verification passed for $remote_sha"
    git checkout --detach "$remote_sha"
  else
    echo "Verification FAILED for $remote_sha — leaving submodule at current commit"
    exit 1
  fi
' || exit "$?"

echo
echo "Everything updated."
