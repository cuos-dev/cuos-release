#!/bin/bash

# Configuration variables with defaults
HOME="${HOME:-/root}"
CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"
DOCKER_CONFIG="${DOCKER_CONFIG:-"${HOME}/.docker/"}"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG_FILE:-"${DOCKER_CONFIG}/config.json"}"
BASE64_CMD="${BASE64_CMD:-"base64"}"  # Allow overriding base64 command for testing

# minimal helper: base64 without newline
_b64() {
  if command -v "$BASE64_CMD" >/dev/null 2>&1; then
    printf '%s' "$1" | "$BASE64_CMD" | tr -d '\n'
  else
    printf '%s' "$1" | openssl base64 | tr -d '\n'
  fi
}

# Initialize docker config
init_docker_config() {
  local config_file="$1"
  local docker_dir
  docker_dir="$(dirname "$config_file")"
  
  # Remove config.json if it is a directory (legacy bugfix)
  rmdir "$config_file" 2>/dev/null && echo "Warning: deleted config.json as dir"
  
  mkdir -p "$docker_dir"
  
  if [ ! -f "$config_file" ] || ! jq empty "$config_file" >/dev/null 2>&1; then
    printf '%s\n' '{}' > "$config_file"
    chmod 600 "$config_file"
  fi

  if [[ "${docker_dir}" == "/root/.docker" ]]; then
    chmod 700 "$docker_dir"
  fi
}

# Function to perform docker login for a given server, user, password
docker_login() {
  local server="$1"
  local user="$2"
  local password="$3"
  local config_file="${4:-$DOCKER_CONFIG_FILE}"

  if [ -z "$server" ] || [ -z "$user" ] || [ -z "$password" ]; then
    echo "docker_login called with empty args"
    return 1
  fi

  local auth
  auth="$(_b64 "${user}:${password}")"

  # Skip if auth already exists for server
  if jq -e --arg s "$server" '.auths[$s].auth? // empty' "$config_file" | grep -q . >/dev/null 2>&1; then
    echo "Credentials for $server already existing. Skipped login."
    return 0
  fi

  # Use jq to produce merged output and write it in-place without mv
  if ! tmp_output="$(jq --arg s "$server" --arg a "$auth" '
      .auths |= (if (type == "object") then . else {} end)
      | .auths[$s] = (.auths[$s] // {}) + {auth: $a}
    ' "$config_file" 2>/dev/null)"; then
    echo "Failed to write auth for $server"
    return 1
  fi

  # Write back in-place without mv: truncate then write
  : > "$config_file" || { echo "Cannot truncate $config_file"; return 1; }
  printf '%s\n' "${tmp_output}" > "$config_file" || { echo "Cannot write $config_file"; return 1; }
  chmod 600 "$config_file"
  echo "Wrote credentials for ${server} to ${config_file}" >&2
  return 0
}

# Function to load update registry credentials from config
load_update_registry() {
  local config_file="$1"
  local update_registry
  local update_registry_server
  local update_registry_user
  local update_registry_password

  # dont use update_registry_proxy here, because we are not yet in the
  # target infrastructure. Thus the proxy might not be reachable.
  update_registry="$(jq -r '.update_registry' "$config_file")"
  update_registry_server="${update_registry//\/*}"
  update_registry_user="$(jq -r '.update_registry_user // .update_server_user // ""' "$config_file")"
  update_registry_password="$(jq -r '.update_registry_password // .update_server_password // ""' "$config_file")"

  echo "$update_registry_server;$update_registry_user;$update_registry_password"
}

# Function to load docker registries from config
load_docker_registries() {
  local config_file="$1"
  local count
  local failed=0
  
  count=$(jq 'if .docker_registries then .docker_registries | length else 0 end' "$config_file")
  
  for ((i=0; i<count; i++)); do
    local reg_server
    local reg_user
    local reg_password
    
    reg_server=$(jq -r ".docker_registries[$i].server" "$config_file")
    reg_user=$(jq -r ".docker_registries[$i].user" "$config_file")
    reg_password=$(jq -r ".docker_registries[$i].password" "$config_file")
    
    if [ -n "$reg_server" ] && [ -n "$reg_user" ] && [ -n "$reg_password" ]; then
      echo "$reg_server;$reg_user;$reg_password"
    else
      echo "Incomplete registry entry at index $i, skipping."
      failed=1
    fi
  done
  return "${failed}"
}

# Main execution
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  init_docker_config "$DOCKER_CONFIG_FILE"

  # Process update registry
  IFS=';' read -r server user password <<< "$(load_update_registry "$CONFIG_PATH")"
  if [ -n "$server" ] && [ -n "$user" ] && [ -n "$password" ]; then
    docker_login "$server" "$user" "$password" || exit 1
  else
    echo "Warning: No registry credentials found in config."
  fi

  # Process additional registries
  while IFS=';' read -r server user password; do
    [ -n "$server" ] && docker_login "$server" "$user" "$password"
  done < <(load_docker_registries "$CONFIG_PATH")

  exit 0
fi
