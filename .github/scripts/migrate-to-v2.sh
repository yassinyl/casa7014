#!/usr/bin/env bash

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

APPS_DIR="$ROOT/Apps"

echo "=============================================="
echo "Casa7014 V1 -> V2 migration"
echo "=============================================="


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
  "en_US"
]
EOF


# ==============================================================
# PROCESS APPS
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

            if key.lower() == "en_us":
                key = "en_US"

            elif key.lower() == "zh_cn":
                key = "zh_CN"

            result[key] = normalize_locale_keys(val)

        return result


    if isinstance(value, list):

        return [
            normalize_locale_keys(v)
            for v in value
        ]


    return value


def get_existing_port(xc):

    value = xc.get("port_map")

    if value is None:
        return None

    value = str(value).strip()

    if value.isdigit():
        return value

    return None


def get_ports_from_compose(data):

    services = data.get("services", {})

    if not isinstance(services, dict):
        return []


    ports_found = []


    for service_name, service in services.items():

        if not isinstance(service, dict):
            continue


        ports = service.get("ports", [])

        if not isinstance(ports, list):
            continue


        for port in ports:

            if isinstance(port, int):

                ports_found.append(str(port))
                continue


            if not isinstance(port, str):
                continue


            value = port.strip()


            # Ignore UDP
            if "/udp" in value.lower():
                continue


            value = re.sub(
                r"/tcp$",
                "",
                value,
                flags=re.IGNORECASE
            )


            # Docker long syntax is handled below
            if isinstance(port, dict):
                continue


            parts = value.split(":")


            # Examples:
            #
            # 8080:80
            # 127.0.0.1:8080:80
            # 8080
            #
            if len(parts) >= 2:

                published = parts[-2]

                if published.isdigit():
                    ports_found.append(
                        published
                    )


            elif len(parts) == 1:

                if parts[0].isdigit():

                    ports_found.append(
                        parts[0]
                    )


    return ports_found


def get_ports_from_environment(data):

    services = data.get(
        "services",
        {}
    )

    candidates = []


    for service in services.values():

        if not isinstance(service, dict):
            continue


        env = service.get(
            "environment",
            []
        )


        if isinstance(env, dict):

            items = env.items()


        elif isinstance(env, list):

            items = []

            for item in env:

                if not isinstance(item, str):
                    continue

                if "=" not in item:
                    continue

                key, value = item.split(
                    "=",
                    1
                )

                items.append(
                    (key, value)
                )


        else:

            continue


        for key, value in items:

            if not isinstance(value, str):
                continue


            value = value.strip()


            if not value.isdigit():
                continue


            if key.upper().endswith("_PORT"):

                candidates.append(
                    (
                        key.upper(),
                        value
                    )
                )


    preferred = [

        "HTTP_PORT",
        "WEB_PORT",
        "SERVER_PORT",
        "PORT",
        "METRICS_PORT",
        "CSS_METRICS_PORT",

    ]


    for wanted in preferred:

        for key, value in candidates:

            if key == wanted:
                return value


    if candidates:

        return candidates[0][1]


    return None


def get_icon(app_dir, app_name, existing):

    if existing:
        return existing


    for icon_name in [

        "icon.svg",
        "icon.png",
        "icon.jpg",
        "icon.jpeg",

    ]:

        icon_path = os.path.join(
            app_dir,
            icon_name
        )


        if os.path.isfile(icon_path):

            return (
                "https://cdn.jsdelivr.net/gh/"
                "yassinyl/casa7014@main/"
                f"Apps/{app_name}/{icon_name}"
            )


    return None


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

        if not value.get("en_US"):

            first = next(
                iter(value.values()),
                default
            )

            value["en_US"] = str(first)


        return value


    return {
        "en_US": default
    }


# ==============================================================
# PROCESS
# ==============================================================

errors = []

count = 0


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


    count += 1


    print()
    print("=" * 70)
    print(f"Migrating: {app_name}")
    print("=" * 70)


    # ==========================================================
    # LOAD YAML
    # ==========================================================

    try:

        with open(
            compose_path,
            encoding="utf-8"
        ) as f:

            data = yaml.safe_load(f)

    except Exception as e:

        errors.append(
            f"{app_name}: YAML error: {e}"
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
    # TOP LEVEL NAME
    # ==========================================================

    if not data.get("name"):

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
    # LEGACY SERVICE X-CASAOS
    #
    # Move it to top-level.
    # ==========================================================

    for service_name, service in services.items():

        if not isinstance(service, dict):
            continue


        legacy = service.get(
            "x-casaos"
        )


        if isinstance(legacy, dict):

            print(
                f"Found legacy x-casaos under service: "
                f"{service_name}"
            )


            # Only fill missing fields.
            for key, value in legacy.items():

                if key not in xc:

                    xc[key] = value


            del service["x-casaos"]


    # ==========================================================
    # ID
    # ==========================================================

    current_id = xc.get("id")


    if not isinstance(current_id, str) or not current_id.strip():

        xc["id"] = make_id(app_name)


    # ==========================================================
    # MAIN
    # ==========================================================

    main = xc.get("main")


    if not isinstance(main, str) or not main.strip():

        if len(services) == 1:

            xc["main"] = next(
                iter(services)
            )

        else:

            # Try to find a likely web/main service.
            candidates = [

                name
                for name in services
                if name.lower() in (
                    "app",
                    "server",
                    "web",
                    "frontend",
                    "main"
                )
            ]


            if candidates:

                xc["main"] = candidates[0]

            else:

                errors.append(
                    f"{app_name}: "
                    "cannot automatically determine "
                    "x-casaos.main"
                )

                continue


    # ==========================================================
    # INDEX
    # ==========================================================

    if not xc.get("index"):

        xc["index"] = "/"


    # ==========================================================
    # SCHEME
    # ==========================================================

    if not xc.get("scheme"):

        xc["scheme"] = "http"


    # ==========================================================
    # PORT MAP
    # ==========================================================

    port = get_existing_port(xc)


    if port is None:

        ports = get_ports_from_compose(
            data
        )


        if ports:

            # Prefer port from main service.
            main_service = xc.get("main")


            main_ports = []


            if main_service in services:

                main_data = services[
                    main_service
                ]


                if isinstance(
                    main_data,
                    dict
                ):

                    main_ports = (
                        main_data.get(
                            "ports",
                            []
                        )
                    )


            if main_ports:

                main_data_copy = {
                    "services": {
                        main_service: {
                            "ports": main_ports
                        }
                    }
                }


                main_candidates = (
                    get_ports_from_compose(
                        main_data_copy
                    )
                )


                if main_candidates:

                    port = main_candidates[0]


            if port is None:

                port = ports[0]


    # Environment fallback.
    if port is None:

        port = get_ports_from_environment(
            data
        )


    # Known CastSponsorSkip.
    if (
        port is None
        and app_name.lower() == "castsponsorskip"
    ):

        port = "9790"


    if port is None:

        errors.append(
            f"{app_name}: "
            "cannot determine x-casaos.port_map"
        )

        continue


    xc["port_map"] = str(port)


    # ==========================================================
    # ICON
    # ==========================================================

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
    # LOCALES
    # ==========================================================

    xc = normalize_locale_keys(
        xc
    )


    # ==========================================================
    # TITLE
    # ==========================================================

    xc["title"] = get_localized(
        xc.get("title"),
        app_name
    )


    # ==========================================================
    # TAGLINE
    # ==========================================================

    xc["tagline"] = get_localized(
        xc.get("tagline"),
        app_name
    )


    # ==========================================================
    # DESCRIPTION
    # ==========================================================

    xc["description"] = get_localized(
        xc.get("description"),
        app_name
    )


    # ==========================================================
    # CATEGORY
    # ==========================================================

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
    #
    # Preserve existing architecture metadata.
    # The official IceWhale builder validates the image.
    # ==========================================================

    architectures = xc.get(
        "architectures"
    )


    if not isinstance(
        architectures,
        list
    ) or not architectures:

        xc["architectures"] = [

            "amd64",
            "arm64"

        ]


    # ==========================================================
    # VERSION
    # ==========================================================

    if not xc.get("version"):

        xc["version"] = "1.0.0"


    # ==========================================================
    # FINAL X-CASAOS
    # ==========================================================

    data["x-casaos"] = xc


    # ==========================================================
    # REMOVE SERVICE LEVEL X-CASAOS
    # ==========================================================

    for service in services.values():

        if isinstance(service, dict):

            service.pop(
                "x-casaos",
                None
            )


    # ==========================================================
    # SAVE
    # ==========================================================

    with open(
        compose_path,
        "w",
        encoding="utf-8"
    ) as f:

        yaml.safe_dump(
            data,
            f,
            sort_keys=False,
            allow_unicode=True
        )


    # ==========================================================
    # OUTPUT
    # ==========================================================

    print(
        f"ID:             {xc['id']}"
    )

    print(
        f"MAIN:           {xc['main']}"
    )

    print(
        f"PORT:           {xc['port_map']}"
    )

    print(
        f"CATEGORY:       {xc['category']}"
    )

    print(
        f"ARCHITECTURES:  {xc['architectures']}"
    )

    print(
        f"VERSION:        {xc['version']}"
    )

    print(
        "Migration: OK"
    )


# ==============================================================
# RESULT
# ==============================================================

print()
print("=" * 70)
print(
    f"Apps processed: {count}"
)
print("=" * 70)


if errors:

    print()
    print("MIGRATION ERRORS")
    print("=" * 70)


    for error in errors:

        print(
            f"ERROR: {error}"
        )


    raise SystemExit(1)


print(
    "ALL APPS MIGRATED SUCCESSFULLY"
)

PY
