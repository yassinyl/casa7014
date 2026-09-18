#!/usr/bin/env python3

import re
import sys
from pathlib import Path

import requests
import yaml
from packaging.version import InvalidVersion, Version

ROOT = Path("Apps")
PR_BODY = Path(".github/PR_BODY.md")
TIMEOUT = 30

SKIP_TAGS = {
    "latest", "edge", "nightly", "rolling", "dev", "development",
    "snapshot", "unstable",
}
SKIP_WORDS = {
    "alpha", "beta", "rc", "dev", "nightly", "snapshot", "test",
    "testing", "debug", "unstable", "rolling", "windows", "win32",
    "win64", "nanoserver", "ltsc",
}

session = requests.Session()
session.headers.update({"User-Agent": "casa7014-docker-image-updater/3.0"})

updates = []
skipped_latest = []
errors = []


def log(message):
    print(message, flush=True)


def parse_image_reference(image):
    image = image.strip()
    if not image:
        return None, None
    if "@" in image:
        return image, None
    last = image.rsplit("/", 1)[-1]
    if ":" not in last:
        return image, "latest"
    return image.rsplit(":", 1)


def normalize_dockerhub_repository(repository):
    repository = repository.strip()
    if repository.startswith("docker.io/"):
        repository = repository[len("docker.io/"):]
    if "/" not in repository:
        repository = f"library/{repository}"
    return repository


def detect_registry(repository):
    if repository.startswith("ghcr.io/"):
        return "ghcr"
    if repository.startswith("docker.io/") or "." not in repository.split("/")[0]:
        return "dockerhub"
    return "unknown"


def version_from_tag(tag):
    raw = str(tag).strip()
    lower = raw.lower()

    if not raw or lower in SKIP_TAGS:
        return None

    for word in SKIP_WORDS:
        if re.search(rf"(^|[-_.]){re.escape(word)}($|[-_.])", lower):
            return None

    clean = raw[1:] if lower.startswith("v") else raw

    if not re.fullmatch(r"\d+(?:\.\d+){0,3}", clean):
        return None

    try:
        return Version(clean)
    except InvalidVersion:
        return None


def dockerhub_tags(repository):
    repository = normalize_dockerhub_repository(repository)
    url = f"https://hub.docker.com/v2/repositories/{repository}/tags"
    params = {"page_size": 100, "ordering": "last_updated"}
    tags = []

    try:
        while url:
            response = session.get(url, params=params, timeout=TIMEOUT)
            response.raise_for_status()
            data = response.json()

            for item in data.get("results", []):
                name = item.get("name")
                if name:
                    tags.append(name)

            url = data.get("next")
            params = {}
    except Exception as exc:
        errors.append(f"{repository}: {exc}")
        log(f"  ERROR: {exc}")
        return []

    return tags


def ghcr_tags(repository):
    parts = repository.split("/", 1)
    if len(parts) != 2:
        return []

    owner, package = parts
    url = f"https://ghcr.io/v2/{owner}/{package}/tags/list"

    try:
        response = session.get(
            url,
            timeout=TIMEOUT,
            headers={"Accept": "application/json"},
        )
        response.raise_for_status()
        return response.json().get("tags", [])
    except Exception as exc:
        errors.append(f"ghcr.io/{repository}: {exc}")
        log(f"  ERROR: {exc}")
        return []


def get_tags(repository):
    registry = detect_registry(repository)

    if registry == "dockerhub":
        return dockerhub_tags(repository)

    if registry == "ghcr":
        return ghcr_tags(repository[len("ghcr.io/"):])

    log(f"  Unsupported registry: {repository}")
    return []


def get_latest_version_tag(repository, current_tag):
    if current_tag.lower() == "latest":
        skipped_latest.append(f"{repository}:latest")
        return None

    current_version = version_from_tag(current_tag)
    if current_version is None:
        log(f"  SKIP non-version tag: {repository}:{current_tag}")
        return None

    candidates = []

    for tag in get_tags(repository):
        version = version_from_tag(tag)
        if version is None or version <= current_version:
            continue
        candidates.append((version, tag))

    if not candidates:
        return None

    candidates.sort(reverse=True, key=lambda x: x[0])
    return candidates[0][1]


def update_compose_version(metadata, old_tag, new_tag):
    current = metadata.get("version")

    # Keep store metadata synchronized when it represented
    # the same numeric image version as the old tag.
    old_v = version_from_tag(old_tag)
    new_v = version_from_tag(new_tag)

    if old_v is None or new_v is None or current is None:
        return False

    current_v = version_from_tag(str(current))
    if current_v is None or current_v != old_v:
        return False

    metadata["version"] = str(new_tag)
    return True


def process_compose(compose_file):
    log("")
    log("=" * 70)
    log(f"Checking: {compose_file}")
    log("=" * 70)

    try:
        with open(compose_file, encoding="utf-8") as file:
            data = yaml.safe_load(file)
    except Exception as exc:
        errors.append(f"{compose_file}: YAML error: {exc}")
        log(f"  YAML ERROR: {exc}")
        return

    if not isinstance(data, dict):
        return

    services = data.get("services", {})
    if not isinstance(services, dict):
        return

    metadata = data.get("x-casaos")
    if not isinstance(metadata, dict):
        metadata = {}

    changed = False

    for service_name, service in services.items():
        if not isinstance(service, dict):
            continue

        image = service.get("image")
        if not isinstance(image, str):
            continue

        repository, current_tag = parse_image_reference(image)
        if not repository or current_tag is None:
            continue

        if current_tag.lower() == "latest":
            skipped_latest.append(f"{repository}:latest")
            log(f"  SKIP latest: {repository}:latest")
            continue

        log(f"  Image: {repository}:{current_tag}")

        latest_tag = get_latest_version_tag(repository, current_tag)
        if not latest_tag or latest_tag == current_tag:
            continue

        log(f"  UPDATE: {current_tag} -> {latest_tag}")

        service["image"] = f"{repository}:{latest_tag}"

        version_changed = update_compose_version(
            metadata, current_tag, latest_tag
        )

        updates.append({
            "app": compose_file.parent.name,
            "service": service_name,
            "image": repository,
            "old": current_tag,
            "new": latest_tag,
            "version_changed": version_changed,
            "file": str(compose_file),
        })

        changed = True

    if changed:
        if metadata:
            data["x-casaos"] = metadata

        with open(compose_file, "w", encoding="utf-8") as file:
            yaml.safe_dump(
                data,
                file,
                sort_keys=False,
                allow_unicode=True,
            )


def update_type(old, new):
    old_v = version_from_tag(old)
    new_v = version_from_tag(new)

    if not old_v or not new_v:
        return "version"
    if new_v.major != old_v.major:
        return "major"
    if new_v.minor != old_v.minor:
        return "minor"
    return "patch"


def generate_pr_body():
    lines = [
        "# 🐋 Docker Image Updates",
        "",
        "Automatically detected Docker image updates.",
        "",
        "## Updates",
        "",
        "| Application | Image | Service | Update | Type | Store version |",
        "|---|---|---|---|---|---|",
    ]

    for item in updates:
        sync = "updated" if item["version_changed"] else "unchanged"
        lines.append(
            f"| {item['app']} | `{item['image']}` | `{item['service']}` "
            f"| `{item['old']}` → `{item['new']}` | "
            f"{update_type(item['old'], item['new'])} | {sync} |"
        )

    lines += ["", "## Files", ""]
    for file in sorted({item["file"] for item in updates}):
        lines.append(f"- `{file}`")

    if skipped_latest:
        lines += [
            "",
            "## ⏭️ Skipped `latest` images",
            "",
            "The updater intentionally does not modify `latest` tags.",
            "",
        ]
        for image in sorted(set(skipped_latest)):
            lines.append(f"- `{image}`")

    if errors:
        lines += ["", "## ⚠️ Registry warnings", ""]
        for error in errors:
            lines.append(f"- {error}")

    PR_BODY.parent.mkdir(parents=True, exist_ok=True)
    PR_BODY.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    if not ROOT.exists():
        print("Apps directory not found.")
        sys.exit(1)

    compose_files = sorted(ROOT.glob("*/docker-compose.yml"))
    if not compose_files:
        print("No docker-compose.yml files found.")
        return

    log(f"Found {len(compose_files)} application(s).")

    for compose_file in compose_files:
        process_compose(compose_file)

    log("")
    log("=" * 70)
    log("SUMMARY")
    log("=" * 70)
    log(f"Updates: {len(updates)}")
    log(f"Skipped latest: {len(set(skipped_latest))}")
    log(f"Warnings/errors: {len(errors)}")

    if updates:
        generate_pr_body()
        for item in updates:
            log(f"  {item['image']}: {item['old']} -> {item['new']}")
    elif PR_BODY.exists():
        PR_BODY.unlink()

    log("")
    log("Docker image update scan complete.")


if __name__ == "__main__":
    main()
