#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
migrated=false
for f in "$ROOT"/Apps/*/docker-compose.yml; do
  [[ -f "$f" ]] || continue
  if yq eval 'has("name") and has("x-casaos")' "$f" | grep -q true; then migrated=true; break; fi
done
echo "migrated=$migrated"
[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "migrated=$migrated" >> "$GITHUB_OUTPUT"
