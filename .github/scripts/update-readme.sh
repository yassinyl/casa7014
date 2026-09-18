#!/usr/bin/env bash
set -euo pipefail

README="README.md"
APPS_DIR="Apps"

START_MARKER="<!-- APPS_START -->"
END_MARKER="<!-- APPS_END -->"

[[ -d "$APPS_DIR" ]] || { echo "Error: $APPS_DIR directory not found."; exit 1; }
[[ -f "$README" ]] || { echo "Error: $README not found."; exit 1; }

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

{
  echo "$START_MARKER"
  echo
  echo "## 📦 Applications"
  echo

  while IFS= read -r -d '' compose; do
    app_dir="$(dirname "$compose")"
    app_name="$(basename "$app_dir")"
    [[ "$app_name" == .* ]] && continue

    version="$(sed -n 's/^  version: *//p' "$compose" | head -n 1 || true)"
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

content = open(readme, encoding="utf-8").read()
replacement = open(generated, encoding="utf-8").read().rstrip()

start_pos = content.find(start)
end_pos = content.find(end)

if start_pos != -1 and end_pos != -1 and end_pos > start_pos:
    end_pos += len(end)
    content = content[:start_pos] + replacement + content[end_pos:]
else:
    if not content.endswith("\n"):
        content += "\n"
    content += "\n" + replacement + "\n"

open(readme, "w", encoding="utf-8").write(content)
PY

echo "README updated successfully."
