import re
import requests
from pathlib import Path

ROOT = Path("Apps")

updates = []


def get_latest_tag(image):
    if "/" not in image:
        repo = f"library/{image}"
    else:
        repo = image

    url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=20"

    try:
        r = requests.get(url, timeout=20)

        if r.status_code != 200:
            return None

        data = r.json()

        versions = []

        for item in data.get("results", []):
            tag = item["name"]

            if any(x in tag.lower() for x in [
                "latest",
                "beta",
                "alpha",
                "nightly",
                "dev",
                "test"
            ]):
                continue

            if re.match(r"^v?[0-9].*", tag):
                versions.append(tag)

        if not versions:
            return None

        versions.sort(reverse=True)

        return versions[0]

    except Exception as e:
        print(f"ERROR {image}: {e}")
        return None


def process_compose(compose_file):
    global updates

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


def build_pr_body():
    lines = []

    lines.append("## Docker Image Updates\n")

    lines.append("| Package | Update | Change |")
    lines.append("|---|---|---|")

    for u in updates:
        old_v = u["old"]
        new_v = u["new"]

        update_type = "major"

        try:
            old_parts = old_v.lstrip("v").split(".")
            new_parts = new_v.lstrip("v").split(".")

            if old_parts[0] == new_parts[0]:
                if len(old_parts) > 1 and len(new_parts) > 1:
                    if old_parts[1] == new_parts[1]:
                        update_type = "patch"
                    else:
                        update_type = "minor"

        except:
            pass

        lines.append(
            f"| `{u['image']}` | {update_type} | `{old_v}` → `{new_v}` |"
        )

    lines.append("\n---\n")
    lines.append("### Files Updated\n")

    added = set()

    for u in updates:
        if u["file"] not in added:
            lines.append(f"- `{u['file']}`")
            added.add(u["file"])

    with open(".github/PR_BODY.md", "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def main():
    for compose in ROOT.rglob("docker-compose.yml"):
        print(f"Checking {compose}")

        process_compose(compose)

    if updates:
        build_pr_body()
    else:
        with open(".github/PR_BODY.md", "w") as f:
            f.write("No updates found")


if __name__ == "__main__":
    main()
