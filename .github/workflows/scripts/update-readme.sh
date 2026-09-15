#!/usr/bin/env bash
set -euo pipefail

README="README.md"
APPS_DIR="Apps"

START_MARKER="<!-- APPS_START -->"
END_MARKER="<!-- APPS_END -->"

if [[ ! -d "$APPS_DIR" ]]; then
    echo "Error: $APPS_DIR directory not found."
    exit 1
fi

if [[ ! -f "$README" ]]; then
    echo "Error: $README not found."
    exit 1
fi

TMP_FILE="$(mktemp)"

{
    echo "$START_MARKER"
    echo
    echo "## 📦 Applications"
    echo

    while IFS= read -r -d '' compose; do
        app_dir="$(dirname "$compose")"
        app_name="$(basename "$app_dir")"

        # Skip hidden directories
        [[ "$app_name" == .* ]] && continue

        # Read basic metadata from docker-compose.yml
        app_id="$(sed -n 's/^  id: *//p' "$compose" | head -n 1 || true)"
        version="$(sed -n 's/^  version: *//p' "$compose" | head -n 1 || true)"

        # Remove YAML quotes
        app_id="${app_id%\"}"
        app_id="${app_id#\"}"
        version="${version%\"}"
        version="${version#\"}"

        echo "- **${app_name}**${version:+ — v${version}}"

    done < <(find "$APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name "docker-compose.yml" -print0 | sort -z)

    echo
    echo "$END_MARKER"
} > "$TMP_FILE"

python3 - "$README" "$TMP_FILE" "$START_MARKER" "$END_MARKER" <<'PY'
import sys

readme, generated, start, end = sys.argv[1:]

with open(readme, "r", encoding="utf-8") as f:
    content = f.read()

with open(generated, "r", encoding="utf-8") as f:
    replacement = f.read().rstrip()

start_pos = content.find(start)
end_pos = content.find(end)

if start_pos != -1 and end_pos != -1 and end_pos > start_pos:
    end_pos += len(end)
    content = content[:start_pos] + replacement + content[end_pos:]
else:
    if not content.endswith("\n"):
        content += "\n"
    content += "\n" + replacement + "\n"

with open(readme, "w", encoding="utf-8") as f:
    f.write(content)
PY

rm -f "$TMP_FILE"

echo "README updated successfully."
