#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
for s in detect-v2-migration.sh lint-casaos-v2.sh; do bash -n "$ROOT/.github/scripts/$s"; done
command -v yq >/dev/null
bash "$ROOT/.github/scripts/lint-casaos-v2.sh" "$ROOT"
echo "test-v2-scripts: PASS"
