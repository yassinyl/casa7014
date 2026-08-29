#!/usr/bin/env python3

import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

import requests
import yaml
from packaging.version import InvalidVersion, Version


ROOT = Path("Apps")
PR_BODY = Path(".github/PR_BODY.md")

TIMEOUT = 30

SUPPORTED_ARCHITECTURES = {
    "amd64",
    "arm64",
    "arm",
    "386",
    "ppc64le",
    "s390x",
}

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
    "User-Agent": "casa7014-docker-image-updater/2.0"
})


updates = []
skipped_latest = []
errors = []


# ============================================================
# HELPERS
# ============================================================

def log(message):
    print(message, flush=True)


def is_latest_tag(tag):
    return tag.strip().lower() == "latest"


def parse_image_reference(image):
    """
    Supports:

    nginx:1.27
    ghcr.io/user/app:1.2.3
    lscr.io/linuxserver/aria2:latest
    docker.io/user/app:1.2.3
    """

    image = image.strip()

    if not image:
        return None, None

    # Digest references are intentionally skipped.
    if "@" in image:
        return image, None

    last_part = image.rsplit("/", 1)[-1]

    if ":" not in last_part:
        return image, "latest"

    repository, tag = image.rsplit(":", 1)

    return repository, tag


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

    if repository.startswith("lscr.io/"):
        return "lscr"

    if repository.startswith("quay.io/"):
        return "quay"

    if repository.startswith("registry.gitlab.com/"):
        return "gitlab"

    if repository.startswith("docker.io/"):
        return "dockerhub"

    # Docker Hub shorthand
    if "." not in repository.split("/")[0]:
        return "dockerhub"

    return "unknown"


# ============================================================
# VERSION
# ============================================================

def version_from_tag(tag):
    """
    Accept:

        1.2.3
        v1.2.3
        1.2
        v1.2

    Reject:

        latest
        beta
        nightly
        1.2.3-rc1
    """

    raw = tag.strip()

    if not raw:
        return None

    lower = raw.lower()

    if lower in SKIP_TAGS:
        return None

    for word in SKIP_WORDS:
        if re.search(
            rf"(^|[-_.]){re.escape(word)}($|[-_.])",
            lower
        ):
            return None

    clean = raw

    if clean.lower().startswith("v"):
        clean = clean[1:]

    # Only normal numeric versions.
    if not re.fullmatch(
        r"\d+(?:\.\d+){0,3}",
        clean
    ):
        return None

    try:
        return Version(clean)

    except InvalidVersion:
        return None


# ============================================================
# DOCKER HUB
# ============================================================

def dockerhub_tags(repository):
    repository = normalize_dockerhub_repository(repository)

    log(f"  Docker Hub: {repository}")

    tags = []

    url = (
        f"https://hub.docker.com/v2/repositories/"
        f"{repository}/tags"
    )

    params = {
        "page_size": 100,
        "ordering": "last_updated",
    }

    try:

        while url:

            response = session.get(
                url,
                params=params,
                timeout=TIMEOUT,
            )

            if response.status_code != 200:

                raise RuntimeError(
                    f"HTTP {response.status_code}"
                )

            data = response.json()

            for item in data.get("results", []):

                name = item.get("name")

                if not name:
                    continue

                tags.append({
                    "name": name,
                    "images": item.get(
                        "images",
                        []
                    )
                })

            url = data.get("next")
            params = {}

    except Exception as exc:

        errors.append(
            f"{repository}: {exc}"
        )

        log(
            f"  ERROR: {exc}"
        )

        return []

    return tags


# ============================================================
# GHCR
# ============================================================

def ghcr_tags(repository):

    # GHCR API requires authentication for many packages.
    # Public packages may still expose metadata through the
    # unauthenticated endpoint, but if not available we skip.

    log(f"  GHCR: {repository}")

    parts = repository.split("/", 1)

    if len(parts) != 2:
        return []

    owner, package = parts

    url = (
        "https://ghcr.io/v2/"
        f"{owner}/{package}/tags/list"
    )

    try:

        response = session.get(
            url,
            timeout=TIMEOUT,
            headers={
                "Accept":
                    "application/json"
            }
        )

        if response.status_code != 200:

            raise RuntimeError(
                f"HTTP {response.status_code}"
            )

        data = response.json()

        return [
            {
                "name": tag,
                "images": []
            }
            for tag in data.get(
                "tags",
                []
            )
        ]

    except Exception as exc:

        errors.append(
            f"{repository}: {exc}"
        )

        log(
            f"  ERROR: {exc}"
        )

        return []


# ============================================================
# REGISTRY
# ============================================================

def get_tags(repository):

    registry = detect_registry(
        repository
    )

    if registry == "dockerhub":
        return dockerhub_tags(
            repository
        )

    if registry == "ghcr":

        return ghcr_tags(
            repository[len("ghcr.io/"):]
        )

    # We intentionally don't blindly query unknown
    # registries because different APIs behave differently.

    log(
        f"  Unsupported registry: {repository}"
    )

    return []


# ============================================================
# FIND LATEST VERSION
# ============================================================

def get_latest_version_tag(
    repository,
    current_tag
):

    # --------------------------------------------------------
    # IMPORTANT:
    # latest is NEVER touched.
    # --------------------------------------------------------

    if is_latest_tag(
        current_tag
    ):

        skipped_latest.append(
            repository
        )

        log(
            f"  SKIP latest: "
            f"{repository}:latest"
        )

        return None

    current_version = version_from_tag(
        current_tag
    )

    if current_version is None:

        log(
            f"  SKIP non-version tag: "
            f"{repository}:{current_tag}"
        )

        return None

    tags = get_tags(
        repository
    )

    if not tags:
        return None

    candidates = []

    for item in tags:

        tag = item.get(
            "name",
            ""
        )

        if not tag:
            continue

        # Never consider latest.
        if is_latest_tag(tag):
            continue

        version = version_from_tag(
            tag
        )

        if version is None:
            continue

        # Never downgrade.
        if version <= current_version:
            continue

        candidates.append(
            (
                version,
                tag
            )
        )

    if not candidates:
        return None

    candidates.sort(
        key=lambda item: item[0],
        reverse=True
    )

    return candidates[0][1]


# ============================================================
# COMPOSE
# ============================================================

def process_compose(compose_file):

    log("")
    log("=" * 70)
    log(f"Checking: {compose_file}")
    log("=" * 70)

    try:

        with open(
            compose_file,
            "r",
            encoding="utf-8"
        ) as file:

            data = yaml.safe_load(
                file
            )

    except Exception as exc:

        errors.append(
            f"{compose_file}: YAML error: {exc}"
        )

        log(
            f"  YAML ERROR: {exc}"
        )

        return

    if not isinstance(
        data,
        dict
    ):
        return

    services = data.get(
        "services",
        {}
    )

    if not isinstance(
        services,
        dict
    ):
        return

    changed = False

    for service_name, service in services.items():

        if not isinstance(
            service,
            dict
        ):
            continue

        image = service.get(
            "image"
        )

        if not isinstance(
            image,
            str
        ):
            continue

        repository, current_tag = parse_image_reference(
            image
        )

        if not repository:
            continue

        # Digest image.
        if current_tag is None:

            log(
                f"  SKIP digest image: {image}"
            )

            continue

        # ----------------------------------------------------
        # latest = NEVER TOUCH
        # ----------------------------------------------------

        if is_latest_tag(
            current_tag
        ):

            skipped_latest.append(
                f"{repository}:latest"
            )

            log(
                f"  SKIP latest: "
                f"{repository}:latest"
            )

            continue

        log(
            f"  Image: {repository}:{current_tag}"
        )

        latest_tag = get_latest_version_tag(
            repository,
            current_tag
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

        updates.append({
            "app": compose_file.parent.name,
            "service": service_name,
            "image": repository,
            "old": current_tag,
            "new": latest_tag,
            "file": str(compose_file),
        })

        changed = True

    if changed:

        with open(
            compose_file,
            "w",
            encoding="utf-8"
        ) as file:

            yaml.safe_dump(
                data,
                file,
                sort_keys=False,
                allow_unicode=True
            )


# ============================================================
# PR BODY
# ============================================================

def update_type(old, new):

    old_v = version_from_tag(
        old
    )

    new_v = version_from_tag(
        new
    )

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
        "| Application | Image | Service | Update | Type |",
        "|---|---|---|---|---|",
    ]

    for item in updates:

        lines.append(
            f"| {item['app']} "
            f"| `{item['image']}` "
            f"| `{item['service']}` "
            f"| `{item['old']}` → `{item['new']}` "
            f"| {update_type(item['old'], item['new'])} |"
        )

    lines.extend([
        "",
        "## Files",
        "",
    ])

    files = sorted({
        item["file"]
        for item in updates
    })

    for file in files:

        lines.append(
            f"- `{file}`"
        )

    if skipped_latest:

        lines.extend([
            "",
            "## ⏭️ Skipped `latest` images",
            "",
            "The updater intentionally does not modify "
            "`latest` tags.",
            "",
        ])

        for image in sorted(
            set(skipped_latest)
        ):

            lines.append(
                f"- `{image}`"
            )

    if errors:

        lines.extend([
            "",
            "## ⚠️ Registry warnings",
            "",
        ])

        for error in errors:

            lines.append(
                f"- {error}"
            )

    PR_BODY.parent.mkdir(
        parents=True,
        exist_ok=True
    )

    PR_BODY.write_text(
        "\n".join(lines) + "\n",
        encoding="utf-8"
    )


# ============================================================
# MAIN
# ============================================================

def main():

    if not ROOT.exists():

        print(
            "Apps directory not found."
        )

        sys.exit(1)

    compose_files = sorted(
        ROOT.glob(
            "*/docker-compose.yml"
        )
    )

    if not compose_files:

        print(
            "No docker-compose.yml files found."
        )

        return

    log(
        f"Found {len(compose_files)} application(s)."
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
        f"Warnings/errors: "
        f"{len(errors)}"
    )

    if updates:

        generate_pr_body()

        log("")
        log(
            "Updates detected."
        )

        for item in updates:

            log(
                f"  {item['image']}: "
                f"{item['old']} -> {item['new']}"
            )

    else:

        # Make sure stale PR body doesn't accidentally
        # describe old updates.
        if PR_BODY.exists():
            PR_BODY.unlink()

        log("")
        log(
            "No Docker image updates found."
        )

    # Registry failures should NOT make the whole workflow
    # fail. Other images can still be processed.

    log("")
    log(
        "Docker image update scan complete."
    )


if __name__ == "__main__":
    main()
