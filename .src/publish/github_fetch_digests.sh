#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

: "${ORG:?set ORG=your-org}"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN=...}"

per_page=100
page=1
first=true

request_digests() {
  # Emit JSON array start
  printf '['

  while :; do
    resp=$(curl -sS -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/orgs/${ORG}/packages?package_type=container&per_page=${per_page}&page=${page}")

    pkg_count=$(echo "$resp" | jq 'length')
    if [[ "$pkg_count" -eq 0 ]]; then
      break
    fi

    # iterate packages
    echo "$resp" | jq -c '.[] | {name: .name}' | while read -r pkgobj; do
      pkg=$(echo "$pkgobj" | jq -r '.name')

      versions=$(curl -sS -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/orgs/${ORG}/packages/container/${pkg}/versions?state=active&per_page=100")

      # pick the newest active version by created_at, fall back to updated_at if created_at missing
      newest=$(echo "$versions" | jq -r '
        map(select(.metadata.container.tags and .metadata.container.tags[0] and (.metadata.container.tags[0] | test("^v")))) | (map(. + {__ts: (.created_at // .updated_at // "1970-01-01T00:00:00Z")})
         | sort_by(.__ts) | last) // empty')

      if [[ -z "$newest" || "$newest" == "null" ]]; then
        continue
      fi


      # build output object with safe fallbacks
      out=$(echo "$newest" | jq -c --arg pkg "$pkg" '
        {
          package: $pkg,
          version_id: (.id // null),
          name: (.name // null),
          created_at: (.created_at // null),
          updated_at: (.updated_at // null),
          state: (.state // null),
          tags: (.metadata.container.tags // []),
          digest: (.metadata.container.digest // null),
          raw: .
        }')

      # comma-separate JSON array elements
      if $first; then
        printf '%s' "$out"
        first=false
      else
        printf ',%s' "$out"
      fi
    done

    page=$((page+1))
  done

  # Emit JSON array end
  printf ']'
  printf '\n'
}

request_digests

