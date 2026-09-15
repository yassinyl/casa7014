#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
echo "Casa7014 V2 normalization check"
bash "$ROOT/.github/scripts/lint-casaos-v2.sh" "$ROOT"
