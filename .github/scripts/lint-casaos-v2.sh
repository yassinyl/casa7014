#!/usr/bin/env bash

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

VALID_CATEGORY='^(Media|Productivity|Home|Networking|AI|Finance|Social|Developer|Others)$'

VALID_ARCH='^(amd64|arm64|arm|386|ppc64le|s390x)$'

rc=0
checked=0


for f in "$ROOT"/Apps/*/docker-compose.yml; do

    [[ -f "$f" ]] || continue

    app="$(basename "$(dirname "$f")")"


    # ==========================================================
    # YAML
    # ==========================================================

    if ! yq eval '.' "$f" >/dev/null 2>&1; then

        echo "[$app] malformed YAML"

        rc=1

        continue

    fi


    # ==========================================================
    # ID
    # ==========================================================

    id="$(
        yq eval '.["x-casaos"].id // ""' "$f"
    )"


    # Skip apps that are not migrated.
    if [[ -z "$id" ]]; then
        continue
    fi


    checked=$((checked + 1))


    if [[ "$id" != com.casa7014.* ]]; then

        echo "[$app] invalid x-casaos.id ('$id')"

        rc=1

    fi


    # ==========================================================
    # SERVICE-LEVEL X-CASAOS MUST NOT EXIST
    # ==========================================================

    legacy_count="$(
        yq eval '
          [
            .services[]?
            | select(has("x-casaos"))
          ]
          | length
        ' "$f"
    )"


    if [[ "$legacy_count" != "0" ]]; then

        echo "[$app] legacy service-level x-casaos found"

        rc=1

    fi


    # ==========================================================
    # LOCALE
    # ==========================================================

    if yq eval '
      [..
       | select(tag == "!!map")
       | keys
       | .[]
      ]
      | any_c(. == "en_us")
    ' "$f" 2>/dev/null | grep -q true; then

        echo "[$app] lowercase en_us locale key"

        rc=1

    fi


    # ==========================================================
    # REQUIRED FIELDS
    # ==========================================================

    for field in \
        id \
        main \
        index \
        port_map \
        icon \
        title \
        category \
        version
    do

        value="$(
            yq eval \
              ".\"x-casaos\".${field} // null" \
              "$f"
        )"


        if [[ "$value" == "null" || -z "$value" ]]; then

            echo "[$app] missing x-casaos.$field"

            rc=1

        fi

    done


    # ==========================================================
    # CATEGORY
    # ==========================================================

    cat="$(
        yq eval '.["x-casaos"].category // ""' "$f"
    )"


    if ! echo "$cat" | grep -Eq "$VALID_CATEGORY"; then

        echo "[$app] invalid category ('$cat')"

        rc=1

    fi


    # ==========================================================
    # ARCHITECTURES
    # ==========================================================

    arch_count="$(
        yq eval \
          '.["x-casaos"].architectures // [] | length' \
          "$f"
    )"


    if [[ "$arch_count" == "0" ]]; then

        echo "[$app] missing architectures"

        rc=1

    else

        for arch in $(
            yq eval \
              '.["x-casaos"].architectures[]' \
              "$f"
        ); do

            if ! echo "$arch" | grep -Eq "$VALID_ARCH"; then

                echo "[$app] invalid architecture ('$arch')"

                rc=1

            fi

        done

    fi


    # ==========================================================
    # MAIN SERVICE
    # ==========================================================

    main="$(
        yq eval '.["x-casaos"].main // ""' "$f"
    )"


    if ! yq eval \
        ".services | has(\"$main\")" \
        "$f" |
        grep -q true
    then

        echo "[$app] x-casaos.main '$main' does not exist"

        rc=1

    fi


    # ==========================================================
    # RESULT
    # ==========================================================

    if [[ "$rc" -eq 0 ]]; then

        echo "[$app] OK"

    fi

done


if [[ "$rc" -eq 0 ]]; then

    echo
    echo "lint-casaos-v2: $checked migrated app(s) v2-clean"

fi


exit "$rc"
