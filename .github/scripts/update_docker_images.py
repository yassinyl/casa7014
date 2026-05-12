import re
import requests

from pathlib import Path
from packaging.version import parse as parse_version

updates = []


def get_latest_tag(image):
    url = f"https://hub.docker.com/v2/repositories/{image}/tags?page_size=100"

    try:
        response = requests.get(
            url,
            timeout=20
        )

        if response.status_code != 200:
            print(f"Failed to fetch tags for {image}")
            return None

        results = response.json().get(
            "results",
            []
        )

        valid_tags = []

        for tag in results:
            name = tag.get("name", "")

            if not name:
                continue

            lower = name.lower()

            # skip unstable / unwanted tags
            if any(x in lower for x in [
                "windows",
                "ltsc",
                "nanoserver",
                "arm",
                "arm64",
                "amd64",
                "ppc",
                "s390",
                "beta",
                "alpha",
                "rc",
                "dev",
                "test"
            ]):
                continue

            # skip latest
            if lower == "latest":
                continue

            # verify linux image exists
            images = tag.get(
                "images",
                []
            )

            linux_found = False

            for img in images:
                os_name = img.get(
                    "os",
                    ""
                )

                arch = img.get(
                    "architecture",
                    ""
                )

                if (
                    os_name == "linux"
                    and arch in [
                        "amd64",
                        "arm64",
                        "arm"
                    ]
                ):
                    linux_found = True
                    break

            if not linux_found:
                continue

            # remove leading "v"
            clean_name = lower.lstrip("v")

            try:
                version = parse_version(
                    clean_name
                )

                valid_tags.append(
                    (
                        version,
                        name
                    )
                )

            except:
                continue

        if not valid_tags:
            return None

        valid_tags.sort(
            key=lambda x: x[0],
            reverse=True
        )

        latest = valid_tags[0][1]

        return latest

    except Exception as e:
        print(f"Error fetching {image}: {e}")
        return None


def process_compose(compose_file):
    global updates

    print(f"Checking {compose_file}")

    content = compose_file.read_text(
        encoding="utf-8"
    )

    changed = False

    pattern = re.compile(
        r'image:\s*["\']?([^:"\']+/[^:"\']+):([^"\']+)["\']?'
    )

    def replace(match):
        nonlocal changed

        image_name = match.group(1).strip()
        current_tag = match.group(2).strip()

        latest_tag = get_latest_tag(
            image_name
        )

        if not latest_tag:
            return match.group(0)

        if latest_tag == current_tag:
            return match.group(0)

        print(
            f"{image_name}: "
            f"{current_tag} -> {latest_tag}"
        )

        updates.append({
            "image": image_name,
            "old": current_tag,
            "new": latest_tag,
            "file": str(compose_file)
        })

        changed = True

        return match.group(0).replace(
            f":{current_tag}",
            f":{latest_tag}"
        )

    new_content = pattern.sub(
        replace,
        content
    )

    if changed:
        compose_file.write_text(
            new_content,
            encoding="utf-8"
        )


def generate_pr_body():
    lines = [
        "# Docker Image Updates",
        "",
        "| Package | Update | Change |",
        "|---|---|---|"
    ]

    for item in updates:
        old_clean = item["old"].lstrip("v")
        new_clean = item["new"].lstrip("v")

        try:
            old_v = parse_version(
                old_clean
            )

            new_v = parse_version(
                new_clean
            )

            if new_v.major > old_v.major:
                update_type = "major"

            elif new_v.minor > old_v.minor:
                update_type = "minor"

            else:
                update_type = "patch"

        except:
            update_type = "unknown"

        lines.append(
            f"| {item['image']} "
            f"| {update_type} "
            f"| `{item['old']}` → `{item['new']}` |"
        )

    lines.extend([
        "",
        "## Files Updated",
        ""
    ])

    added = set()

    for item in updates:
        file_path = item["file"]

        if file_path in added:
            continue

        added.add(file_path)

        lines.append(
            f"- `{file_path}`"
        )

    Path(".github").mkdir(
        exist_ok=True
    )

    Path(".github/PR_BODY.md").write_text(
        "\n".join(lines),
        encoding="utf-8"
    )


def main():
    compose_files = list(
        Path(".").rglob(
            "docker-compose.yml"
        )
    )

    for compose_file in compose_files:
        process_compose(
            compose_file
        )

    if updates:
        generate_pr_body()

    else:
        print("No updates found")


if __name__ == "__main__":
    main()
