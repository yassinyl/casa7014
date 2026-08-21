#!/usr/bin/env bash

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

APPS_DIR="$ROOT/Apps"

echo "=============================================="
echo "Casa7014 V1 -> V2 migration"
echo "=============================================="

if [[ ! -d "$APPS_DIR" ]]; then
    echo "ERROR: Apps directory not found."
    exit 1
fi


# ==============================================================
# STORE CONFIG
# ==============================================================

echo
echo "Preparing store-config.json..."


if [[ -f "$ROOT/store-config.json" ]]; then

    yq -o=json '.' "$ROOT/store-config.json" \
      > "$ROOT/store-config.tmp.json"

    python3 - "$ROOT/store-config.tmp.json" "$ROOT/store-config.json" <<'PY'
import json
import sys

src = sys.argv[1]
dst = sys.argv[2]

with open(src, encoding="utf-8") as f:
    data = json.load(f)

data["version"] = 2

if not isinstance(data.get("store_id"), str) or not data["store_id"].strip():
    data["store_id"] = "casa7014-yl"

name = data.get("name")

if isinstance(name, str):
    data["name"] = {
        "en_US": name
    }

elif not isinstance(name, dict):
    data["name"] = {
        "en_US": "Casa7014 AppStore"
    }

elif not data["name"].get("en_US"):
    first = next(
        iter(data["name"].values()),
        "Casa7014 AppStore"
    )

    data["name"]["en_US"] = str(first)


description = data.get("description")

if isinstance(description, str):
    data["description"] = {
        "en_US": description
    }

elif not isinstance(description, dict):
    data["description"] = {
        "en_US": "Casa7014 AppStore"
    }

elif not description.get("en_US"):
    first = next(
        iter(description.values()),
        "Casa7014 AppStore"
    )

    description["en_US"] = str(first)


if not isinstance(data.get("maintainer"), str):
    data["maintainer"] = "yassinyl"

if not isinstance(data.get("url"), str):
    data["url"] = "https://github.com/yassinyl/casa7014"

with open(dst, "w", encoding="utf-8") as f:
    json.dump(
        data,
        f,
        indent=2,
        ensure_ascii=False
    )
    f.write("\n")
PY

    rm -f "$ROOT/store-config.tmp.json"

else

    cat > "$ROOT/store-config.json" <<'EOF'
{
  "version": 2,
  "store_id": "casa7014-yl",
  "name": {
    "en_US": "Casa7014 AppStore"
  },
  "description": {
    "en_US": "Casa7014 AppStore"
  },
  "maintainer": "yassinyl",
  "url": "https://github.com/yassinyl/casa7014"
}
EOF

fi


# ==============================================================
# SUPPORTED LANGUAGES
# ==============================================================

cat > "$ROOT/supported-languages.json" <<'EOF'
[
  "en_US"
]
EOF


# ==============================================================
# CATEGORY NORMALIZATION
# ==============================================================

normalize_category() {

    local category="$1"

    case "$category" in

        Media)
            echo "Media"
            ;;

        Productivity|Utility|Utilities|Tools|Tool)
            echo "Productivity"
            ;;

        Home)
            echo "Home"
            ;;

        Network|Networking)
            echo "Networking"
            ;;

        AI)
            echo "AI"
            ;;

        Finance)
            echo "Finance"
            ;;

        Social)
            echo "Social"
            ;;

        Development|Developer)
            echo "Developer"
            ;;

        *)
            echo "Others"
            ;;

    esac
}


# ==============================================================
# ID GENERATION
# ==============================================================

make_id() {

    local app="$1"

    local slug

    slug="$(
        printf '%s' "$app" |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[^a-z0-9]+/-/g' |
        sed -E 's/^-+//;s/-+$//'
    )"

    echo "com.casa7014.${slug}"
}


# ==============================================================
# PROCESS APPS
# ==============================================================

FAILED=0
COUNT=0


for compose in "$APPS_DIR"/*/docker-compose.yml; do

    [[ -f "$compose" ]] || continue

    app_dir="$(dirname "$compose")"
    app="$(basename "$app_dir")"

    COUNT=$((COUNT + 1))

    echo
    echo "=============================================="
    echo "Migrating: $app"
    echo "=============================================="


    # ==========================================================
    # VALIDATE YAML
    # ==========================================================

    if ! yq eval '.' "$compose" >/dev/null 2>&1; then

        echo "ERROR: malformed YAML"

        FAILED=1
        continue

    fi


    # ==========================================================
    # CREATE TOP LEVEL NAME
    # ==========================================================

    current_name="$(
        yq eval '.name // ""' "$compose"
    )"

    if [[ -z "$current_name" || "$current_name" == "null" ]]; then

        compose_name="$(
            printf '%s' "$app" |
            tr '[:upper:]' '[:lower:]' |
            sed -E 's/[^a-z0-9_-]+/-/g' |
            sed -E 's/^-+//;s/-+$//'
        )"

        yq -i \
          ".name = \"$compose_name\"" \
          "$compose"

    fi


    # ==========================================================
    # COLLECT LEGACY SERVICE-LEVEL X-CASAOS
    # ==========================================================

    legacy_found=false

    service_names="$(
        yq eval '.services | keys | .[]' "$compose" 2>/dev/null || true
    )"

    for service in $service_names; do

        has_legacy="$(
            yq eval \
              ".services.\"$service\".\"x-casaos\" // null" \
              "$compose"
        )"

        if [[ "$has_legacy" != "null" ]]; then

            echo "Found legacy x-casaos under service: $service"

            if [[ "$legacy_found" == "false" ]]; then

                yq eval \
                  ".\"x-casaos\" = (.services.\"$service\".\"x-casaos\" // {})" \
                  -i "$compose"

                legacy_found=true

            else

                yq eval \
                  ".\"x-casaos\" *= (.services.\"$service\".\"x-casaos\" // {})" \
                  -i "$compose"

            fi

            # Remove legacy service-level block.
            yq eval \
              "del(.services.\"$service\".\"x-casaos\")" \
              -i "$compose"

        fi

    done


    # ==========================================================
    # ENSURE TOP LEVEL X-CASAOS
    # ==========================================================

    yq eval \
      '.["x-casaos"] = (.["x-casaos"] // {})' \
      -i "$compose"


    # ==========================================================
    # ID
    # ==========================================================

    current_id="$(
        yq eval '.["x-casaos"].id // ""' "$compose"
    )"

    if [[ -z "$current_id" || "$current_id" == "null" ]]; then

        new_id="$(make_id "$app")"

        yq eval \
          ".\"x-casaos\".id = \"$new_id\"" \
          -i "$compose"

    fi


    # ==========================================================
    # MAIN SERVICE
    # ==========================================================

    main="$(
        yq eval '.["x-casaos"].main // ""' "$compose"
    )"

    if [[ -z "$main" || "$main" == "null" ]]; then

        service_count="$(
            yq eval '.services | length' "$compose"
        )"

        if [[ "$service_count" == "1" ]]; then

            main="$(
                yq eval '.services | keys | .[0]' "$compose"
            )"

            yq eval \
              ".\"x-casaos\".main = \"$main\"" \
              -i "$compose"

        else

            echo "WARNING: cannot automatically determine main service."

        fi

    fi


    # ==========================================================
    # INDEX
    # ==========================================================

    if [[ "$(yq eval '.["x-casaos"].index // ""' "$compose")" == "" ]]; then

        yq eval \
          '.["x-casaos"].index = "/"' \
          -i "$compose"

    fi


    # ==========================================================
    # SCHEME
    # ==========================================================

    if [[ "$(yq eval '.["x-casaos"].scheme // ""' "$compose")" == "" ]]; then

        yq eval \
          '.["x-casaos"].scheme = "http"' \
          -i "$compose"

    fi


    # ==========================================================
    # PORT MAP
    # ==========================================================

    port="$(
        yq eval '.["x-casaos"].port_map // ""' "$compose"
    )"


    if [[ -z "$port" || "$port" == "null" ]]; then

        port="$(
            yq eval '
              [
                .services[]?.ports[]?
                |
                tostring
                |
                select(test("/udp$") | not)
                |
                sub("/tcp$"; "")
                |
                split(":")
                |
                if length >= 2 then .[-2]
                else .[0]
                end
                |
                select(test("^[0-9]+$"))
              ][0] // ""
            ' "$compose"
        )"

    fi


    # CastSponsorSkip known port.
    if [[ -z "$port" || "$port" == "null" ]]; then

        if [[ "${app,,}" == "castsponsorskip" ]]; then

            port="9790"

        fi

    fi


    if [[ -n "$port" && "$port" != "null" ]]; then

        yq eval \
          ".\"x-casaos\".port_map = \"$port\"" \
          -i "$compose"

    else

        echo "WARNING: port_map could not be detected."

    fi


    # ==========================================================
    # ICON
    # ==========================================================

    icon="$(
        yq eval '.["x-casaos"].icon // ""' "$compose"
    )"


    if [[ -z "$icon" || "$icon" == "null" ]]; then

        for icon_file in \
            icon.svg \
            icon.png \
            icon.jpg \
            icon.jpeg
        do

            if [[ -f "$app_dir/$icon_file" ]]; then

                icon_url="https://cdn.jsdelivr.net/gh/yassinyl/casa7014@main/Apps/${app}/${icon_file}"

                yq eval \
                  ".\"x-casaos\".icon = \"$icon_url\"" \
                  -i "$compose"

                break

            fi

        done

    fi


    # ==========================================================
    # TITLE
    # ==========================================================

    title="$(
        yq eval '.["x-casaos"].title // null' "$compose"
    )"

    if [[ "$title" == "null" ]]; then

        yq eval \
          ".\"x-casaos\".title = {\"en_US\": \"$app\"}" \
          -i "$compose"

    elif [[ "$title" != *"en_US"* ]]; then

        title_value="$(
            yq eval '.["x-casaos"].title | to_entries | .[0].value // ""' "$compose"
        )"

        [[ -z "$title_value" ]] && title_value="$app"

        yq eval \
          ".\"x-casaos\".title.en_US = \"$title_value\"" \
          -i "$compose"

    fi


    # ==========================================================
    # TAGLINE
    # ==========================================================

    tagline="$(
        yq eval '.["x-casaos"].tagline // null' "$compose"
    )"

    if [[ "$tagline" == "null" ]]; then

        yq eval \
          ".\"x-casaos\".tagline = {\"en_US\": \"$app\"}" \
          -i "$compose"

    elif [[ "$tagline" != *"en_US"* ]]; then

        tagline_value="$(
            yq eval '.["x-casaos"].tagline | to_entries | .[0].value // ""' "$compose"
        )"

        [[ -z "$tagline_value" ]] && tagline_value="$app"

        yq eval \
          ".\"x-casaos\".tagline.en_US = \"$tagline_value\"" \
          -i "$compose"

    fi


    # ==========================================================
    # DESCRIPTION
    # ==========================================================

    description="$(
        yq eval '.["x-casaos"].description // null' "$compose"
    )"

    if [[ "$description" == "null" ]]; then

        yq eval \
          ".\"x-casaos\".description = {\"en_US\": \"$app\"}" \
          -i "$compose"

    elif [[ "$description" != *"en_US"* ]]; then

        description_value="$(
            yq eval '.["x-casaos"].description | to_entries | .[0].value // ""' "$compose"
        )"

        [[ -z "$description_value" ]] && description_value="$app"

        yq eval \
          ".\"x-casaos\".description.en_US = \"$description_value\"" \
          -i "$compose"

    fi


    # ==========================================================
    # NORMALIZE LOCALE KEY en_us -> en_US
    # ==========================================================

    yq eval \
      '(.. | select(tag == "!!map") | with_entries(
        if .key == "en_us"
        then .key = "en_US"
        else .
        end
      ))' \
      -i "$compose"


    # ==========================================================
    # CATEGORY
    # ==========================================================

    category="$(
        yq eval '.["x-casaos"].category // ""' "$compose"
    )"

    if [[ -z "$category" || "$category" == "null" ]]; then

        category="Others"

    fi

    category="$(normalize_category "$category")"

    yq eval \
      ".\"x-casaos\".category = \"$category\"" \
      -i "$compose"


    # ==========================================================
    # ARCHITECTURES
    #
    # IMPORTANT:
    # Do not invent architectures.
    #
    # If old metadata has architectures, preserve them.
    # If missing, default to amd64 + arm64.
    #
    # The official V2 builder performs image/platform validation.
    # ==========================================================

    architecture_count="$(
        yq eval \
          '.["x-casaos"].architectures // [] | length' \
          "$compose"
    )"

    if [[ "$architecture_count" == "0" ]]; then

        yq eval \
          '.["x-casaos"].architectures = ["amd64", "arm64"]' \
          -i "$compose"

    fi


    # ==========================================================
    # VERSION
    # ==========================================================

    version="$(
        yq eval '.["x-casaos"].version // ""' "$compose"
    )"

    if [[ -z "$version" || "$version" == "null" ]]; then

        yq eval \
          '.["x-casaos"].version = "1.0.0"' \
          -i "$compose"

    fi


    # ==========================================================
    # REMOVE LEGACY x-casaos FROM ALL SERVICES
    # ==========================================================

    service_names="$(
        yq eval '.services | keys | .[]' "$compose" 2>/dev/null || true
    )"

    for service in $service_names; do

        yq eval \
          "del(.services.\"$service\".\"x-casaos\")" \
          -i "$compose"

    done


    # ==========================================================
    # FINAL CHECK
    # ==========================================================

    final_id="$(
        yq eval '.["x-casaos"].id // ""' "$compose"
    )"

    echo
    echo "Result:"
    echo "  App:            $app"
    echo "  ID:             $final_id"
    echo "  Main:           $(yq eval '.["x-casaos"].main // ""' "$compose")"
    echo "  Port:           $(yq eval '.["x-casaos"].port_map // ""' "$compose")"
    echo "  Category:       $(yq eval '.["x-casaos"].category // ""' "$compose")"
    echo "  Architectures:  $(yq eval '.["x-casaos"].architectures // [] | join(",")' "$compose")"

done


# ==============================================================
# RESULT
# ==============================================================

echo
echo "=============================================="
echo "Migration complete"
echo "Apps processed: $COUNT"
echo "=============================================="


if [[ "$FAILED" -ne 0 ]]; then
    echo "Migration completed with errors."
    exit 1
fi

echo "Migration successful."
