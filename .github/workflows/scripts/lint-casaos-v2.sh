#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
rc=0; checked=0
for f in "$ROOT"/Apps/*/docker-compose.yml; do
 [[ -f "$f" ]] || continue; app="$(basename "$(dirname "$f")")"; checked=$((checked+1))
 yq eval '.' "$f" >/dev/null || { echo "[$app] malformed YAML"; rc=1; continue; }
 name="$(yq eval '.name // ""' "$f")"; [[ "$name" =~ ^[a-z0-9_-]+$ ]] || { echo "[$app] invalid name"; rc=1; }
 id="$(yq eval '."x-casaos".id // ""' "$f")"; [[ "$id" =~ ^[a-z0-9]+([._-][a-z0-9]+)+$ ]] || { echo "[$app] invalid x-casaos.id: $id"; rc=1; }
 for field in main port_map icon title category version; do v="$(yq eval ".\"x-casaos\".$field // \"\"" "$f")"; [[ -n "$v" ]] || { echo "[$app] missing x-casaos.$field"; rc=1; }; done
 main="$(yq eval '."x-casaos".main // ""' "$f")"; yq eval ".services | has("$main")" "$f" | grep -q true || { echo "[$app] main service not found"; rc=1; }
 echo "[$app] OK"
done
[[ $rc -eq 0 ]] && echo "lint-casaos-v2: $checked app(s) valid"
exit $rc
