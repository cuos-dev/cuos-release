#!/usr/bin/env bash
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 path/to/system.json [another/system.json]" >&2
  exit 2
fi

SEEN=()
order=()

seen_has() {
  local key="$1" i
  for i in "${!SEEN[@]}"; do
    [ "${SEEN[i]}" = "$key" ] && return 0
  done
  return 1
}

seen_add() {
  local key="$1"
  SEEN+=("$key")
}

process() {
  local file="$1"
  local abs
  abs="$(abspath "$file")" || { echo "Cannot resolve file: $file" >&2; exit 3; }
  if seen_has "$abs"; then
    return
  fi
  if [[ ! -f "$abs" ]]; then
    echo "File not found: $abs" >&2
    exit 4
  fi
  seen_add "$abs"
  local dir
  dir="$(dirname "$abs")"

  while IFS= read -r inc; do
    if [[ "$inc" != /* ]]; then
      inc="$dir/$inc"
    fi
    process "$inc"
  done < <(
    jq -r '
      if has("#include") then
        ( .["#include"] | (if type=="string" then [.] elif type=="array" then . else [] end) ) | .[]
      else empty end
    ' "$abs" 2>/dev/null || true
  )

  order+=("$abs")
}

abspath() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$p" 2>/dev/null
  else
    (cd "$(dirname "$p")" && printf "%s/%s" "$(pwd -P)" "$(basename "$p")")
  fi
}


for file; do
  process "${file}"
done

# print in order (includes first, root last)
for f in "${order[@]}"; do
  printf 'Config file: %s\n' "$f" >&2
done

jq -s '
  # normalize "#include" to an array (string -> [string], others -> [])
  map(
    if has("#include") then
      .["#include"] |= (if type=="string" then [.] elif type=="array" then . else [] end)
    else .
    end
  )
  # now reduce (fold) the normalized inputs with recursive merge
  | reduce .[] as $item ({}; . * $item)
' "${order[@]}"

