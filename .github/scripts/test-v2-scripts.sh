#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

for s in detect-v2-migration.sh lint-casaos-v2.sh; do
  if [[ -f "$ROOT/.github/scripts/$s" ]]; then
    bash -n "$ROOT/.github/scripts/$s"
  fi
done

ruby -c "$ROOT/.github/scripts/validate-store-catalog.rb"
ruby "$ROOT/.github/scripts/validate-store-catalog.rb" "$ROOT"

command -v yq >/dev/null
bash "$ROOT/.github/scripts/lint-casaos-v2.sh" "$ROOT"

echo "test-v2-scripts: PASS"
