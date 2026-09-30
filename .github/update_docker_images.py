#!/usr/bin/env python3

import re
import sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import requests
import yaml
from packaging.version import InvalidVersion, Version


ROOT = Path("Apps")
PR_BODY = Path(".github/PR_BODY.md")
TIMEOUT = 30

SKIP_TAGS = {
    "latest",
    "edge",
    "nightly",
    "rolling",
    "dev",
    "development",
    "snapshot",
    "unstable",
}

SKIP_WORDS = {
    "alpha",
    "beta",
    "rc",
    "dev",
    "nightly",
    "snapshot",
    "test",
    "testing",
    "debug",
    "unstable",
    "rolling",
    "windows",
    "win32",
    "win64",
    "nanoserver",
    "ltsc",
}

session = requests.Session()
session.headers.update({
    "User-Agent": "casa7014-docker-image-updater/4.0",
    "Accept": "application/json",
})

updates = []
skipped_latest = []
skipped_non_version = []
errors = []


def log(message):
    print(message, flush=True)


# ---------------------------------------------------------
# IMAGE REFERENCE
# ---------------------------------------------------------

def parse_image_reference(image):
    image = image.strip()

    if not image:
        return None, None

    # Digest image, e.g. image@sha256:...
    if "@" in image:
        return image, None

    last = image.rsplit("/", 1)[-1]

    # No explicit tag -> Docker defaults to latest
    if ":" not in last:
        return image, "latest"

    repository, tag = image.rsplit(":", 1)

    return repository, tag


# ---------------------------------------------------------
# REGISTRY DETECTION
# ---------------------------------------------------------

def detect_registry(repository):
    repository = repository.strip()

    if repository.startswith("ghcr.io/"):
        return "ghcr"

    if repository.startswith("docker.io/"):
        return "dockerhub"

    # Docker Hub shorthand:
    #
    # postgres
    # postgres:16
    # redis
    # portainer/portainer-ce
    #
    # Anything whose first component has no dot and no colon
    # is treated as Docker Hub.
    first = repository.split("/", 1)[0]

    if "." not in first and ":" not in first:
        return "dockerhub"

    return "unknown"


def normalize_dockerhub_repository(repository):
    repository = repository.strip()

    if repository.startswith("docker.io/"):
        repository = repository[len("docker.io/"):]

    if "/" not in repository:
        repository = f"library/{repository}"

    return repository


def normalize_registry_repository(repository, registry):
    repository = repository.strip()

    if registry == "dockerhub":
        return normalize_dockerhub_repository(repository)

    if registry == "ghcr":
        if repository.startswith("ghcr.io/"):
            return repository[len("ghcr.io/"):]

    return repository


# ---------------------------------------------------------
# TAG PARSING
# ---------------------------------------------------------

def classify_tag(tag):
    """
    Return:

        (kind, version, suffix)

    Examples:

        3.22
            -> ("version", Version("3.22"), "")

        16-alpine
            -> ("version", Version("16"), "alpine")

        7-alpine
            -> ("version", Version("7"), "alpine")

        2026.9.1
            -> ("version", Version("2026.9.1"), "")

        20260805
            -> ("date", Version("20260805"), "")

        20260805-alpine
            -> ("date", Version("20260805"), "alpine")
    """

    raw = str(tag).strip()
    lower = raw.lower()

    if not raw:
        return None

    if lower in SKIP_TAGS:
        return None

    for word in SKIP_WORDS:
        if re.search(
            rf"(^|[-_.]){re.escape(word)}($|[-_.])",
            lower,
        ):
            return None

    clean = raw[1:] if lower.startswith("v") else raw

    # Date-style Docker tags:
    #
    # 20260805
    # 20260901-alpine
    date_match = re.fullmatch(
        r"(\d{8})(?:[-_](.+))?",
        clean,
    )

    if date_match:
        date_value = date_match.group(1)
        suffix = date_match.group(2) or ""

        try:
            return (
                "date",
                Version(date_value),
                suffix.lower(),
            )
        except InvalidVersion:
            return None

    # Numeric version + optional suffix:
    #
    # 16
    # 16.0
    # 16.2.1
    # 16-alpine
    # 3.23-alpine3.23
    #
    version_match = re.fullmatch(
        r"(\d+(?:\.\d+){0,3})(?:[-_](.+))?",
        clean,
    )

    if not version_match:
        return None

    version_string = version_match.group(1)
    suffix = version_match.group(2) or ""

    try:
        version = Version(version_string)
    except InvalidVersion:
        return None

    return (
        "version",
        version,
        suffix.lower(),
    )


def version_from_tag(tag):
    parsed = classify_tag(tag)

    if not parsed:
        return None

    return parsed[1]


def compatible_tag(current_tag, candidate_tag):
    """
    Only compare tags belonging to the same tag family.

    Examples:

        16-alpine -> 17-alpine       YES
        7-alpine -> 8-alpine         YES

        3.22 -> 3.23                 YES
        3.22 -> 20260805             NO

        20260805 -> 20260901         YES

        2026.8.1 -> 2026.9.1         YES
    """

    current = classify_tag(current_tag)
    candidate = classify_tag(candidate_tag)

    if not current or not candidate:
        return False

    current_kind, _, current_suffix = current
    candidate_kind, _, candidate_suffix = candidate

    if current_kind != candidate_kind:
        return False

    if current_suffix != candidate_suffix:
        return False

    return True


# ---------------------------------------------------------
# REGISTRY AUTHENTICATION
# ---------------------------------------------------------

def registry_token(registry, repository):
    """
    Get a pull token from the Docker Registry token service.

    This avoids relying on Docker Hub's authenticated API endpoint
    and also supports anonymous pulls of public GHCR images.
    """

    if registry == "dockerhub":
        service = "registry.docker.io"
        scope_repository = repository

        url = "https://auth.docker.io/token"

    elif registry == "ghcr":
        service = "ghcr.io"
        scope_repository = repository

        url = "https://ghcr.io/token"

    else:
        return None

    params = {
        "service": service,
        "scope": f"repository:{scope_repository}:pull",
    }

    try:
        response = session.get(
            url,
            params=params,
            timeout=TIMEOUT,
        )

        response.raise_for_status()

        data = response.json()

        token = data.get("token") or data.get("access_token")

        if not token:
            raise RuntimeError(
                "registry token response did not contain a token"
            )

        return token

    except Exception as exc:
        errors.append(
            f"{registry}/{repository}: token request failed: {exc}"
        )

        log(
            f"  ERROR: {registry}/{repository}: "
            f"token request failed: {exc}"
        )

        return None


# ---------------------------------------------------------
# DOCKER REGISTRY TAG LIST
# ---------------------------------------------------------

def registry_tags(registry, repository):
    """
    Read tags through the Docker Registry v2 API.

    Supports pagination through the `Link` header.
    """

    normalized_repository = normalize_registry_repository(
        repository,
        registry,
    )

    token = registry_token(
        registry,
        normalized_repository,
    )

    if not token:
        return None

    if registry == "dockerhub":
        base_url = "https://registry-1.docker.io"

    elif registry == "ghcr":
        base_url = "https://ghcr.io"

    else:
        return None

    url = (
        f"{base_url}/v2/"
        f"{normalized_repository}/tags/list"
    )

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }

    tags = []

    try:
        while url:
            response = session.get(
                url,
                headers=headers,
                params={"n": 100},
                timeout=TIMEOUT,
            )

            response.raise_for_status()

            data = response.json()

            for tag in data.get("tags") or []:
                if tag:
                    tags.append(tag)

            # Docker Registry pagination uses Link:
            # <url>; rel="next"
            next_url = None

            link = response.headers.get("Link")

            if link:
                match = re.search(
                    r'<([^>]+)>;\s*rel="next"',
                    link,
                )

                if match:
                    next_url = match.group(1)

            url = next_url

        return tags

    except Exception as exc:
        errors.append(
            f"{registry}/{normalized_repository}: "
            f"tag lookup failed: {exc}"
        )

        log(
            f"  ERROR: {registry}/{normalized_repository}: "
            f"tag lookup failed: {exc}"
        )

        return None


def get_tags(repository):
    registry = detect_registry(repository)

    if registry == "dockerhub":
        return registry_tags(
            "dockerhub",
            repository,
        )

    if registry == "ghcr":
        return registry_tags(
            "ghcr",
            repository,
        )

    errors.append(
        f"{repository}: unsupported registry"
    )

    log(
        f"  ERROR: unsupported registry: {repository}"
    )

    return None


# ---------------------------------------------------------
# UPDATE DETECTION
# ---------------------------------------------------------

def get_latest_version_tag(repository, current_tag):
    parsed_current = classify_tag(current_tag)

    if not parsed_current:
        skipped_non_version.append(
            f"{repository}:{current_tag}"
        )

        log(
            f"  SKIP unsupported tag: "
            f"{repository}:{current_tag}"
        )

        return None

    current_version = parsed_current[1]

    tags = get_tags(repository)

    # IMPORTANT:
    #
    # None means registry failure.
    # [] means registry was successfully queried but no tags.
    #
    # We must NOT confuse these two cases.
    if tags is None:
        return None

    candidates = []

    for tag in tags:
        if not compatible_tag(
            current_tag,
            tag,
        ):
            continue

        parsed = classify_tag(tag)

        if not parsed:
            continue

        candidate_version = parsed[1]

        if candidate_version <= current_version:
            continue

        candidates.append(
            (
                candidate_version,
                tag,
            )
        )

    if not candidates:
        return None

    candidates.sort(
        reverse=True,
        key=lambda item: item[0],
    )

    return candidates[0][1]


# ---------------------------------------------------------
# CASAOS VERSION METADATA
# ---------------------------------------------------------

def update_compose_version(
    metadata,
    old_tag,
    new_tag,
):
    current = metadata.get("version")

    if current is None:
        return False

    old_parsed = classify_tag(old_tag)
    new_parsed = classify_tag(new_tag)

    if not old_parsed or not new_parsed:
        return False

    current_parsed = classify_tag(
        str(current)
    )

    if not current_parsed:
        return False

    old_kind, old_version, old_suffix = old_parsed
    new_kind, new_version, new_suffix = new_parsed
    current_kind, current_version, current_suffix = current_parsed

    if current_kind != old_kind:
        return False

    if current_suffix != old_suffix:
        return False

    if current_version != old_version:
        return False

    # Store metadata gets the exact new Docker tag.
    metadata["version"] = str(new_tag)

    return True


# ---------------------------------------------------------
# COMPOSE PROCESSING
# ---------------------------------------------------------

def process_compose(compose_file):
    log("")
    log("=" * 70)
    log(f"Checking: {compose_file}")
    log("=" * 70)

    try:
        with open(
            compose_file,
            encoding="utf-8",
        ) as file:
            data = yaml.safe_load(file)

    except Exception as exc:
        errors.append(
            f"{compose_file}: YAML error: {exc}"
        )

        log(
            f"  YAML ERROR: {exc}"
        )

        return

    if not isinstance(data, dict):
        return

    services = data.get(
        "services",
        {},
    )

    if not isinstance(services, dict):
        return

    metadata = data.get(
        "x-casaos"
    )

    if not isinstance(metadata, dict):
        metadata = {}

    changed = False

    for service_name, service in services.items():

        if not isinstance(service, dict):
            continue

        image = service.get("image")

        if not isinstance(image, str):
            continue

        repository, current_tag = parse_image_reference(
            image
        )

        if not repository or current_tag is None:
            continue

        # -------------------------------------------------
        # USER REQUEST:
        # ONLY explicit :latest is skipped.
        # -------------------------------------------------

        if current_tag.lower() == "latest":
            skipped_latest.append(
                f"{repository}:latest"
            )

            log(
                f"  SKIP latest: "
                f"{repository}:latest"
            )

            continue

        log(
            f"  Image: "
            f"{repository}:{current_tag}"
        )

        latest_tag = get_latest_version_tag(
            repository,
            current_tag,
        )

        if not latest_tag:
            continue

        if latest_tag == current_tag:
            continue

        log(
            f"  UPDATE: "
            f"{current_tag} -> {latest_tag}"
        )

        service["image"] = (
            f"{repository}:{latest_tag}"
        )

        version_changed = update_compose_version(
            metadata,
            current_tag,
            latest_tag,
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

        with open(
            compose_file,
            "w",
            encoding="utf-8",
        ) as file:

            yaml.safe_dump(
                data,
                file,
                sort_keys=False,
                allow_unicode=True,
            )


# ---------------------------------------------------------
# PR REPORT
# ---------------------------------------------------------

def update_type(old, new):
    old_parsed = classify_tag(old)
    new_parsed = classify_tag(new)

    if not old_parsed or not new_parsed:
        return "version"

    old_kind, old_version, _ = old_parsed
    new_kind, new_version, _ = new_parsed

    if old_kind != new_kind:
        return "version"

    if new_version.major != old_version.major:
        return "major"

    if new_version.minor != old_version.minor:
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
        sync = (
            "updated"
            if item["version_changed"]
            else "unchanged"
        )

        lines.append(
            f"| {item['app']} | "
            f"`{item['image']}` | "
            f"`{item['service']}` | "
            f"`{item['old']}` → `{item['new']}` | "
            f"{update_type(item['old'], item['new'])} | "
            f"{sync} |"
        )

    lines += [
        "",
        "## Files",
        "",
    ]

    for file in sorted(
        {item["file"] for item in updates}
    ):
        lines.append(
            f"- `{file}`"
        )

    if skipped_latest:
        lines += [
            "",
            "## ⏭️ Skipped `latest` images",
            "",
            "Images explicitly using the `latest` tag "
            "are intentionally excluded from updates.",
            "",
        ]

        for image in sorted(
            set(skipped_latest)
        ):
            lines.append(
                f"- `{image}`"
            )

    if skipped_non_version:
        lines += [
            "",
            "## ⏭️ Skipped unsupported tags",
            "",
        ]

        for image in sorted(
            set(skipped_non_version)
        ):
            lines.append(
                f"- `{image}`"
            )

    if errors:
        lines += [
            "",
            "## ⚠️ Registry warnings",
            "",
        ]

        for error in errors:
            lines.append(
                f"- {error}"
            )

    PR_BODY.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    PR_BODY.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------
# MAIN
# ---------------------------------------------------------

def main():
    if not ROOT.exists():
        print("Apps directory not found.")
        sys.exit(1)

    compose_files = sorted(
        ROOT.glob("*/docker-compose.yml")
    )

    if not compose_files:
        print(
            "No docker-compose.yml files found."
        )
        return

    log(
        f"Found {len(compose_files)} "
        "application(s)."
    )

    for compose_file in compose_files:
        process_compose(
            compose_file
        )

    log("")
    log("=" * 70)
    log("SUMMARY")
    log("=" * 70)

    log(
        f"Updates: {len(updates)}"
    )

    log(
        f"Skipped latest: "
        f"{len(set(skipped_latest))}"
    )

    log(
        f"Skipped unsupported: "
        f"{len(set(skipped_non_version))}"
    )

    log(
        f"Warnings/errors: "
        f"{len(errors)}"
    )

    if updates:
        generate_pr_body()

        for item in updates:
            log(
                f"  {item['image']}: "
                f"{item['old']} -> "
                f"{item['new']}"
            )

    elif PR_BODY.exists():
        PR_BODY.unlink()

    log("")
    log(
        "Docker image update scan complete."
    )


if __name__ == "__main__":
    main()
