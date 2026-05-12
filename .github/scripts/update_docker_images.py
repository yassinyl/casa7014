import re
import yaml
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

    except:
        return None


def process_compose(compose_file):
    global updates

    with open(compose_file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    changed = False

    for service_name, service in data.get("services", {}).items():
        image = service.get("image")

        if not image or ":" not in image:
            continue

        image_name, current_tag = image.rsplit(":", 1)

        latest_tag = get_latest_tag(image_name)

        if not latest_tag:
            continue

        if latest_tag != current_tag:
            service["image"] = f"{image_name}:{latest_tag}"

            updates.append({
                "image": image_name,
                "old": current_tag,
                "new": latest_tag,
                "file": str(compose_file)
            })

            changed = True

    if changed:
        with open(compose_file, "w", encoding="utf-8") as f:
            yaml.dump(data, f, sort_keys=False)


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
            old_major = old_v.lstrip("v").split(".")[0]
            new_major = new_v.lstrip("v").split(".")[0]

            if old_major == new_major:
                old_minor = old_v.lstrip("v").split(".")[1]
                new_minor = new_v.lstrip("v").split(".")[1]

                if old_minor == new_minor:
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
        process_compose(compose)

    if updates:
        build_pr_body()
    else:
        with open(".github/PR_BODY.md", "w") as f:
            f.write("No updates found")


if __name__ == "__main__":
    main()
