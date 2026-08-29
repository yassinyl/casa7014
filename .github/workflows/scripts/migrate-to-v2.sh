#!/usr/bin/env bash

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
APPS_DIR="$ROOT/Apps"

echo "=============================================="
echo "Casa7014 V1 -> V2 migration"
echo "=============================================="

# ==============================================================
# REQUIREMENTS
# ==============================================================

command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required."
    exit 1
}

python3 -c "import yaml" >/dev/null 2>&1 || {
    echo "ERROR: PyYAML is required."
    exit 1
}

# ==============================================================
# STORE CONFIG
# ==============================================================

echo
echo "Preparing store-config.json..."

if [[ -f "$ROOT/store-config.json" ]]; then

    python3 - "$ROOT/store-config.json" <<'PY'
import json
import sys

path = sys.argv[1]

with open(path, encoding="utf-8") as f:
    data = json.load(f)

if not isinstance(data, dict):
    data = {}

data["version"] = 2

if not isinstance(data.get("store_id"), str) or not data["store_id"].strip():
    data["store_id"] = "casa7014-yl"

name = data.get("name")

if isinstance(name, str):
    data["name"] = {"en_US": name}

elif not isinstance(name, dict):
    data["name"] = {"en_US": "Casa7014 AppStore"}

elif not data["name"].get("en_US"):
    first = next(iter(data["name"].values()), "Casa7014 AppStore")
    data["name"]["en_US"] = str(first)

description = data.get("description")

if isinstance(description, str):
    data["description"] = {"en_US": description}

elif not isinstance(description, dict):
    data["description"] = {"en_US": "Casa7014 AppStore"}

elif not data["description"].get("en_US"):
    first = next(
        iter(data["description"].values()),
        "Casa7014 AppStore"
    )
    data["description"]["en_US"] = str(first)

if not isinstance(data.get("maintainer"), str):
    data["maintainer"] = "yassinyl"

if not isinstance(data.get("url"), str):
    data["url"] = "https://github.com/yassinyl/casa7014"

with open(path, "w", encoding="utf-8") as f:
    json.dump(
        data,
        f,
        indent=2,
        ensure_ascii=False
    )
    f.write("\n")
PY

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
  "en_US",
  "zh_CN",
  "fr_FR"
]
EOF

# ==============================================================
# PYTHON MIGRATION
# ==============================================================

python3 - "$APPS_DIR" <<'PY'

import os
import re
import sys
import yaml

APPS_DIR = sys.argv[1]

# ==============================================================
# CATEGORY
# ==============================================================

CATEGORY_MAP = {
    "Media": "Media",

    "Productivity": "Productivity",
    "Utility": "Productivity",
    "Utilities": "Productivity",
    "Tools": "Productivity",
    "Tool": "Productivity",

    "Home": "Home",

    "Network": "Networking",
    "Networking": "Networking",

    "AI": "AI",

    "Finance": "Finance",

    "Social": "Social",

    "Development": "Developer",
    "Developer": "Developer",
}

ALLOWED_CATEGORIES = {
    "Media",
    "Productivity",
    "Home",
    "Networking",
    "AI",
    "Finance",
    "Social",
    "Developer",
    "Others",
}

# ==============================================================
# HELPERS
# ==============================================================

def make_id(app_name):
    slug = re.sub(
        r"[^a-zA-Z0-9]+",
        "-",
        app_name
    ).strip("-").lower()

    return f"com.casa7014.{slug}"


def normalize_locale_keys(value):

    if isinstance(value, dict):

        result = {}

        for key, val in value.items():

            key_lower = str(key).lower()

            if key_lower == "en_us":
                key = "en_US"

            elif key_lower == "zh_cn":
                key = "zh_CN"

            elif key_lower == "fr_fr":
                key = "fr_FR"

            result[key] = normalize_locale_keys(val)

        return result

    if isinstance(value, list):
        return [
            normalize_locale_keys(v)
            for v in value
        ]

    return value


def get_localized(value, default):

    if value is None:
        return {
            "en_US": default
        }

    if isinstance(value, str):
        return {
            "en_US": value
        }

    if isinstance(value, dict):

        value = normalize_locale_keys(value)

        if not value.get("en_US"):

            first = next(
                (
                    v for v in value.values()
                    if isinstance(v, str) and v.strip()
                ),
                default
            )

            value["en_US"] = str(first)

        return value

    return {
        "en_US": default
    }


def get_existing_port(xc):

    value = xc.get("port_map")

    if value is None:
        return None

    value = str(value).strip()

    if value.isdigit():
        return value

    return None


def parse_port_value(port):

    if isinstance(port, int):
        return str(port)

    if isinstance(port, dict):

        published = port.get("published")

        if published is not None:
            published = str(published)

            if published.isdigit():
                return published

        return None

    if not isinstance(port, str):
        return None

    value = port.strip()

    if "/udp" in value.lower():
        return None

    value = re.sub(
        r"/tcp$",
        "",
        value,
        flags=re.IGNORECASE
    )

    parts = value.split(":")

    if len(parts) >= 2:

        published = parts[-2]

        if published.isdigit():
            return published

    elif len(parts) == 1:

        if parts[0].isdigit():
            return parts[0]

    return None


def get_ports_from_service(service):

    if not isinstance(service, dict):
        return []

    ports = service.get("ports", [])

    if not isinstance(ports, list):
        return []

    result = []

    for port in ports:

        parsed = parse_port_value(port)

        if parsed and parsed not in result:
            result.append(parsed)

    return result


def get_ports_from_compose(data):

    services = data.get("services", {})

    if not isinstance(services, dict):
        return []

    result = []

    for service in services.values():

        for port in get_ports_from_service(service):

            if port not in result:
                result.append(port)

    return result


def get_ports_from_environment(data):

    services = data.get("services", {})

    if not isinstance(services, dict):
        return None

    candidates = []

    for service in services.values():

        if not isinstance(service, dict):
            continue

        env = service.get("environment", [])

        if isinstance(env, dict):

            items = env.items()

        elif isinstance(env, list):

            items = []

            for item in env:

                if not isinstance(item, str):
                    continue

                if "=" not in item:
                    continue

                key, value = item.split("=", 1)

                items.append((key, value))

        else:
            continue

        for key, value in items:

            if not isinstance(value, str):
                continue

            value = value.strip()

            if not value.isdigit():
                continue

            if str(key).upper().endswith("_PORT"):
                candidates.append(
                    (
                        str(key).upper(),
                        value
                    )
                )

    preferred = [
        "HTTP_PORT",
        "WEB_PORT",
        "SERVER_PORT",
        "PORT",
    ]

    for wanted in preferred:

        for key, value in candidates:

            if key == wanted:
                return value

    if candidates:
        return candidates[0][1]

    return None


def get_icon(app_dir, app_name, existing):

    if isinstance(existing, str) and existing.strip():
        return existing

    for icon_name in [
        "icon.svg",
        "icon.png",
        "icon.jpg",
        "icon.jpeg",
        "icon.webp",
    ]:

        icon_path = os.path.join(
            app_dir,
            icon_name
        )

        if os.path.isfile(icon_path):

            return (
                "https://cdn.jsdelivr.net/gh/"
                "yassinyl/casa7014@refs/heads/main/"
                f"Apps/{app_name}/{icon_name}"
            )

    return None


def get_main_service(data, xc):

    services = data.get("services", {})

    main = xc.get("main")

    if (
        isinstance(main, str)
        and main in services
    ):
        return main

    if len(services) == 1:
        return next(iter(services))

    preferred = [
        "app",
        "server",
        "web",
        "frontend",
        "main",
    ]

    for candidate in preferred:

        if candidate in services:
            return candidate

    return None


def get_image(service):

    if not isinstance(service, dict):
        return None

    image = service.get("image")

    if not isinstance(image, str):
        return None

    image = image.strip()

    if not image:
        return None

    return image


def get_image_tag(image):

    if not image:
        return None

    image = image.strip()

    if "@" in image:
        return image.split("@", 1)[1]

    last = image.rsplit("/", 1)[-1]

    if ":" in last:
        return image.rsplit(":", 1)[1]

    return "latest"


def version_from_image(image, existing):

    tag = get_image_tag(image)

    if not tag:
        return existing or "1.0.0"

    # latest cannot be converted into a numeric version.
    # Preserve an existing valid version instead.
    if tag.lower() == "latest":
        if (
            isinstance(existing, str)
            and existing.strip()
            and existing.strip().lower() != "latest"
        ):
            return existing.strip()

        return "1.0.0"

    return tag


def clean_architectures(value):

    if not isinstance(value, list):
        return []

    result = []

    for item in value:

        if not item:
            continue

        item = str(item).strip()

        if item and item not in result:
            result.append(item)

    return result


# ==============================================================
# PROCESS APPS
# ==============================================================

errors = []
processed = 0
changed = 0

if not os.path.isdir(APPS_DIR):

    print(f"ERROR: Apps directory not found: {APPS_DIR}")
    raise SystemExit(1)


for app_name in sorted(os.listdir(APPS_DIR)):

    app_dir = os.path.join(
        APPS_DIR,
        app_name
    )

    if not os.path.isdir(app_dir):
        continue

    compose_path = os.path.join(
        app_dir,
        "docker-compose.yml"
    )

    if not os.path.isfile(compose_path):
        continue

    processed += 1

    print()
    print("=" * 70)
    print(f"Migrating: {app_name}")
    print("=" * 70)

    try:

        with open(
            compose_path,
            encoding="utf-8"
        ) as f:

            data = yaml.safe_load(f)

    except Exception as exc:

        errors.append(
            f"{app_name}: YAML error: {exc}"
        )

        continue

    if not isinstance(data, dict):

        errors.append(
            f"{app_name}: invalid YAML"
        )

        continue

    services = data.get(
        "services",
        {}
    )

    if not isinstance(services, dict) or not services:

        errors.append(
            f"{app_name}: no services"
        )

        continue

    # ==========================================================
    # NAME
    # ==========================================================

    if not isinstance(data.get("name"), str):

        data["name"] = re.sub(
            r"[^a-zA-Z0-9_-]+",
            "-",
            app_name
        ).strip("-").lower()

    # ==========================================================
    # X-CASAOS
    # ==========================================================

    xc = data.get(
        "x-casaos",
        {}
    )

    if not isinstance(xc, dict):
        xc = {}

    # ==========================================================
    # MOVE LEGACY SERVICE X-CASAOS
    # ==========================================================

    for service_name, service in services.items():

        if not isinstance(service, dict):
            continue

        legacy = service.get("x-casaos")

        if isinstance(legacy, dict):

            print(
                f"Moving legacy x-casaos from "
                f"service '{service_name}'"
            )

            for key, value in legacy.items():

                if key not in xc:
                    xc[key] = value

            service.pop(
                "x-casaos",
                None
            )

    # ==========================================================
    # LOCALES
    # ==========================================================

    xc = normalize_locale_keys(xc)

    # ==========================================================
    # ID
    # ==========================================================

    current_id = xc.get("id")

    if (
        not isinstance(current_id, str)
        or not current_id.strip()
    ):

        xc["id"] = make_id(app_name)

    # ==========================================================
    # MAIN
    # ==========================================================

    main_service = get_main_service(
        data,
        xc
    )

    if not main_service:

        errors.append(
            f"{app_name}: cannot determine x-casaos.main"
        )

        continue

    xc["main"] = main_service

    # ==========================================================
    # INDEX
    # ==============================================================

    if not isinstance(xc.get("index"), str):
        xc["index"] = "/"

    # ==========================================================
    # SCHEME
    # ==============================================================

    if xc.get("scheme") not in (
        "http",
        "https"
    ):

        xc["scheme"] = "http"

    # ==========================================================
    # PORT
    # ==============================================================

    port = get_existing_port(xc)

    if port is None:

        main_service_data = services.get(
            main_service,
            {}
        )

        main_ports = get_ports_from_service(
            main_service_data
        )

        if main_ports:
            port = main_ports[0]

    if port is None:

        all_ports = get_ports_from_compose(
            data
        )

        if all_ports:
            port = all_ports[0]

    if port is None:

        port = get_ports_from_environment(
            data
        )

    if (
        port is None
        and app_name.lower() == "castsponsorskip"
    ):

        port = "9790"

    if port is None:

        errors.append(
            f"{app_name}: cannot determine x-casaos.port_map"
        )

        continue

    xc["port_map"] = str(port)

    # ==========================================================
    # ICON
    # ==============================================================

    icon = get_icon(
        app_dir,
        app_name,
        xc.get("icon")
    )

    if icon:
        xc["icon"] = icon

    else:

        errors.append(
            f"{app_name}: missing x-casaos.icon"
        )

        continue

    # ==========================================================
    # THUMBNAIL
    # ==============================================================

    thumbnail = xc.get("thumbnail")

    if not isinstance(thumbnail, str) or not thumbnail.strip():

        for filename in [
            "thumbnail.png",
            "thumbnail.jpg",
            "thumbnail.jpeg",
            "thumbnail.webp",
        ]:

            local = os.path.join(
                app_dir,
                filename
            )

            if os.path.isfile(local):

                xc["thumbnail"] = (
                    "https://cdn.jsdelivr.net/gh/"
                    "yassinyl/casa7014@refs/heads/main/"
                    f"Apps/{app_name}/{filename}"
                )

                break

    # ==========================================================
    # SCREENSHOTS
    # ==============================================================

    screenshots = xc.get(
        "screenshot_link"
    )

    if not isinstance(screenshots, list):
        screenshots = []

    screenshots = [
        str(x).strip()
        for x in screenshots
        if str(x).strip()
    ]

    if not screenshots:

        local_screenshots = []

        for filename in sorted(
            os.listdir(app_dir)
        ):

            lower = filename.lower()

            if (
                lower.startswith("screenshot")
                and lower.endswith(
                    (
                        ".png",
                        ".jpg",
                        ".jpeg",
                        ".webp"
                    )
                )
            ):

                local_screenshots.append(
                    (
                        "https://cdn.jsdelivr.net/gh/"
                        "yassinyl/casa7014@refs/heads/main/"
                        f"Apps/{app_name}/{filename}"
                    )
                )

        if local_screenshots:
            xc["screenshot_link"] = local_screenshots

    else:
        xc["screenshot_link"] = screenshots

    # ==========================================================
    # TITLE
    # ==============================================================

    xc["title"] = get_localized(
        xc.get("title"),
        app_name
    )

    # ==========================================================
    # TAGLINE
    # ==============================================================

    xc["tagline"] = get_localized(
        xc.get("tagline"),
        app_name
    )

    # ==========================================================
    # DESCRIPTION
    # ==============================================================

    xc["description"] = get_localized(
        xc.get("description"),
        app_name
    )

    # ==========================================================
    # CATEGORY
    # ==============================================================

    category = xc.get(
        "category"
    )

    category = CATEGORY_MAP.get(
        category,
        "Others"
    )

    if category not in ALLOWED_CATEGORIES:
        category = "Others"

    xc["category"] = category

    # ==========================================================
    # ARCHITECTURES
    # ==============================================================

    architectures = clean_architectures(
        xc.get("architectures")
    )

    if not architectures:

        architectures = [
            "amd64",
            "arm64"
        ]

    xc["architectures"] = architectures

    # ==========================================================
    # VERSION
    #
    # IMPORTANT:
    #
    # x-casaos.version follows the MAIN service image tag.
    #
    # Example:
    #
    # image: portainer/portainer-ee:2.45.0
    #
    # becomes:
    #
    # version: 2.45.0
    #
    # latest is NOT converted to a fake version.
    # ==============================================================

    main_image = get_image(
        services.get(main_service)
    )

    old_version = xc.get(
        "version"
    )

    new_version = version_from_image(
        main_image,
        old_version
    )

    xc["version"] = str(
        new_version
    )

    # ==========================================================
    # FINALIZE
    # ==============================================================

    data["x-casaos"] = xc

    for service in services.values():

        if isinstance(service, dict):

            service.pop(
                "x-casaos",
                None
            )

    # ==========================================================
    # SAVE
    # ==============================================================

    with open(
        compose_path,
        "w",
        encoding="utf-8"
    ) as f:

        yaml.safe_dump(
            data,
            f,
            sort_keys=False,
            allow_unicode=True,
            default_flow_style=False
        )

    changed += 1

    print(f"ID:             {xc['id']}")
    print(f"MAIN:           {xc['main']}")
    print(f"IMAGE:          {main_image or 'N/A'}")
    print(f"PORT:           {xc['port_map']}")
    print(f"CATEGORY:       {xc['category']}")
    print(f"ARCHITECTURES:  {xc['architectures']}")
    print(f"VERSION:        {xc['version']}")
    print(
        f"THUMBNAIL:      "
        f"{xc.get('thumbnail', 'N/A')}"
    )
    print(
        f"SCREENSHOTS:    "
        f"{len(xc.get('screenshot_link', []))}"
    )
    print("Migration: OK")


# ==============================================================
# RESULT
# ==============================================================

print()
print("=" * 70)
print("MIGRATION RESULT")
print("=" * 70)
print(f"Apps processed: {processed}")
print(f"Apps changed:   {changed}")

if errors:

    print()
    print("MIGRATION ERRORS")
    print("=" * 70)

    for error in errors:
        print(f"ERROR: {error}")

    raise SystemExit(1)

print()
print("ALL APPS MIGRATED SUCCESSFULLY")

PY

echo
echo "=============================================="
echo "Casa7014 V1 -> V2 migration completed"
echo "=============================================="
