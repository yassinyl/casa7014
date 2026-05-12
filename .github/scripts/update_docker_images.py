import re
import requests
from pathlib import Path
from packaging.version import Version, InvalidVersion

updates = []


def get_latest_tag(image):
    if "/" not in image:
        repo = f"library/{image}"
    else:
        repo = image

    url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=100"

    try:
        r = requests.get(url, timeout=20)

        if r.status_code != 200:
            return None

        data = r.json()

        valid_tags = []

        blacklist = [
            "windows",
            "ltsc",
            "nanoserver",
            "alpine",
            "beta",
            "alpha",
            "dev",
            "nightly",
            "test",
            "debug",
            "arm",
            "arm64",
            "amd64",
            "rc"
        ]

        for item in data.get("results", []):
            tag = item["name"]

            tag_lower = tag.lower()

            # تجاهل latest
            if tag_lower == "latest":
                continue

            # تجاهل tags الغالطة
            if any(word in tag_lower for word in blacklist):
                continue

            clean = tag.lstrip("v")

            try:
                version = Version(clean)

                valid_tags.append((version, tag))

            except InvalidVersion:
                continue

        if not valid_tags:
            return None

        valid_tags.sort(reverse=True)

        latest = valid_tags[0][1]

        return latest

    except Exception as e:
        print(f"ERROR {image}: {e}")
        return None


def process_compose(compose_file):
    global updates

    print(f"Checking {compose_file}")

    content = compose_file.read_text(encoding="utf-8")

    changed = False

    pattern = re.compile(
        r'image:\s*["\']?([^:"\']+/[^:"\']+):([^"\'\s]+)["\']?'
    )

    def replace(match):
        nonlocal changed

        image_name = match.group(1)
        current_tag = match.group(2)

        latest_tag = get_latest_tag(image_name)

        if not latest_tag:
            return match.group(0)

        if latest_tag == current_tag:
            return match.group(0)

        print(f"{image_name}: {current_tag} -> {latest_tag}")

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

    new_content = pattern.sub(replace, content)

    if changed:
        compose_file.write_text(
            new_content,
            encoding="utf-8"
        )


def generate_pr_body():
    body = [
        "# Docker Image Updates",
        "",
        "| Package | Update | Change |",
        "|---|---|---|"
    ]

    for update in updates:
        old_ver = update["old"]
        new_ver = update["new"]

        update_type = "major"

        try:
            old_v = Version(old_ver.lstrip("v"))
            new_v = Version(new_ver.lstrip("v"))

            if old_v.major == new_v.major:
                if old_v.minor == new_v.minor:
                    update_type = "patch"
                else:
                    update_type = "minor"

        except:
            pass

        body.append(
            f"| `{update['image']}` | "
            f"{update_type} | "
            f"`{old_ver}` → `{new_ver}` |"
        )

    body.extend([
        "",
        "## Files Updated",
        ""
    ])

    done = set()

    for update in updates:
        file = update["file"]

        if file not in done:
            body.append(f"- `{file}`")
            done.add(file)

    Path(".github/PR_BODY.md").write_text(
        "\n".join(body),
        encoding="utf-8"
    )


compose_files = Path("Apps").glob("**/docker-compose.yml")

for compose in compose_files:
    process_compose(compose)

if updates:
    generate_pr_body()
else:
    print("No updates found")
