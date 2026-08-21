#!/usr/bin/env bash

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

SCRIPTS_DIR="$ROOT/.github/scripts"

rc=0


echo "=============================================="
echo "Testing Casa7014 V2 scripts"
echo "=============================================="


for script in \
    migrate-to-v2.sh \
    detect-v2-migration.sh \
    lint-casaos-v2.sh
do

    path="$SCRIPTS_DIR/$script"


    if [[ ! -f "$path" ]]; then

        echo "ERROR: missing $script"

        rc=1

        continue

    fi


    echo
    echo "Checking: $script"


    if bash -n "$path"; then

        echo "  Syntax: OK"

    else

        echo "  Syntax: FAILED"

        rc=1

    fi

done


# ==============================================================
# CHECK REQUIRED REPOSITORY FILES
# ==============================================================

if [[ ! -d "$ROOT/Apps" ]]; then

    echo "ERROR: Apps directory missing"

    rc=1

fi


# ==============================================================
# CHECK YQ
# ==============================================================

if ! command -v yq >/dev/null 2>&1; then

    echo "ERROR: yq is not installed"

    rc=1

else

    echo
    echo "yq: $(yq --version)"

fi


# ==============================================================
# RESULT
# ==============================================================

echo

if [[ "$rc" -eq 0 ]]; then

    echo "test-v2-scripts: PASS"

else

    echo "test-v2-scripts: FAIL"

fi


exit "$rc"
