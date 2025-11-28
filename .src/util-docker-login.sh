#!/bin/bash

# Check and read configuration:
CONFIG_PATH="${CONFIG_PATH:-"/system.json"}"

# Remove config.json if it is a directory (legacy bugfix)
rmdir "${HOME}/.docker/config.json" 2>/dev/null && echo "Warning: deleted config.json as dir"

# Function to perform docker login for a given server, user, password
docker_login() {
  local server="$1"
  local user="$2"
  local password="$3"
  # Only login if not already present in config.json
  if ! grep -q "$server" "${HOME}/.docker/config.json" 2>/dev/null; then
    if ! echo "$password" | docker login "$server" --username "$user" --password-stdin; then
      echo "Docker login failed for $server" >&2
      return 1
    fi
  else
    echo "Credentials for $server already existing. Skipped login."
  fi
}

UPDATE_REGISTRY="$(jq -r '.update_registry' "${CONFIG_PATH}")"
UPDATE_REGISTRY_SERVER="${UPDATE_REGISTRY//\/*}"
UPDATE_REGISTRY_USER="$(jq -r '.update_registry_user // .update_server_user // ""' "${CONFIG_PATH}")"
UPDATE_REGISTRY_PASSWORD="$(jq -r '.update_registry_password // .update_server_password // ""' "${CONFIG_PATH}")"
if [ -n "$UPDATE_REGISTRY_SERVER" ] && [ -n "$UPDATE_REGISTRY_USER" ] && [ -n "$UPDATE_REGISTRY_PASSWORD" ]; then
  docker_login "$UPDATE_REGISTRY_SERVER" "$UPDATE_REGISTRY_USER" "$UPDATE_REGISTRY_PASSWORD" || exit 1
else
  echo "Warning: No registry credentials found in config."
fi

# Try to read docker_registries array from config
DOCKER_REGISTRIES_COUNT=$(jq 'if .docker_registries then .docker_registries | length else 0 end' "${CONFIG_PATH}")

if [ "$DOCKER_REGISTRIES_COUNT" -gt 0 ]; then
  # Loop over all registries in the array
  for ((i=0; i<DOCKER_REGISTRIES_COUNT; i++)); do
    reg_server=$(jq -r ".docker_registries[$i].server" "${CONFIG_PATH}")
    reg_user=$(jq -r ".docker_registries[$i].user" "${CONFIG_PATH}")
    reg_password=$(jq -r ".docker_registries[$i].password" "${CONFIG_PATH}")
    if [ -n "$reg_server" ] && [ -n "$reg_user" ] && [ -n "$reg_password" ]; then
      docker_login "$reg_server" "$reg_user" "$reg_password"
    else
      echo "Incomplete registry entry at index $i, skipping." >&2
    fi
  done
fi

exit 0
