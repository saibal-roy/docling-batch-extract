"""Assemble the MkDocs source (site-src/) from the repository's own Markdown.

Files keep the repository's folder layout, so the relative links between them keep working.
Only docs/index.md (the landing page) is written for the site; everything else is copied
from its single source. Links to files that aren't part of the site (code, scripts, YAML)
are pointed at GitHub by docs/hooks.py at build time. See versions/landing-page-plan-v2.md.

Usage: python scripts/build_site.py
"""
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "site-src"

# (source in the repository, destination in site-src)
COPIES = [
    ("docs/index.md", "index.md"),
    ("docs/stylesheets/extra.css", "stylesheets/extra.css"),
    ("docs/javascripts/a11y.js", "javascripts/a11y.js"),
    ("README.md", "guide.md"),
    ("STORY.md", "STORY.md"),
    ("prompts.md", "prompts.md"),
    ("scripts/demo-files/README.md", "scripts/demo-files/README.md"),
]


def plan_title(path):
    first = path.read_text().splitlines()[0]
    return first.lstrip("# ").strip()


def plan_status(path):
    m = re.search(r"^\*\*Status:\*\*\s*(.+)$", path.read_text(), re.M)
    return re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", m[1]) if m else ""


def versions_index():
    lines = ["# Design history", "",
             "Every change to the solution was planned in a new version with its requirements, "
             "acceptance checks and the evidence behind each decision. Newest first.", "",
             "| Plan | Status |", "|------|--------|"]
    plans = sorted((ROOT / "versions").glob("plan-v*.md"), key=lambda p: int(re.findall(r"\d+", p.stem)[0]),
                   reverse=True)
    for p in plans:
        lines.append(f"| [{plan_title(p)}]({p.name}) | {plan_status(p)} |")
    lines += ["", "## Proposals (not implemented)", ""]
    for p in sorted((ROOT / "versions").glob("proposal-*.md")):
        lines.append(f"- [{plan_title(p)}]({p.name}): {plan_status(p)}")
    lines += ["", "## Landing page plans", "", "| Plan | Status |", "|------|--------|"]
    for p in sorted((ROOT / "versions").glob("landing-page-plan-v*.md"), reverse=True):
        lines.append(f"| [{plan_title(p)}]({p.name}) | {plan_status(p)} |")
    return "\n".join(lines) + "\n"


def validation_page(results):
    ubuntu = [r for r in results if "_ubuntu-" in r.name]
    other = [r for r in results if "_ubuntu-" not in r.name]
    lines = ["# Validation", "",
             "**Go-ahead criterion:** the full operator workflow passes inside a fresh **Ubuntu 26.04 LTS** "
             "container (the only supported release) on Docker Desktop: setup → checks → setup again → "
             "smoke test → cleanup → first demo run → 18 acceptance checks (`tests/ubuntu_container_test.sh`).", ""]
    if ubuntu:
        lines += ["## Ubuntu container runs", ""]
        for r in sorted(ubuntu):
            lines.append(f"- [{r.name}]({r.name}/summary.md)")
    lines += ["", "## Acceptance and benchmark runs (Apple M2, Docker Desktop)", ""]
    for r in sorted(other):
        lines.append(f"- [{r.name}]({r.name}/summary.md)")
    lines += ["", "How to run these yourself: [Guide → Test results](../../guide.md#test-results)."]
    return "\n".join(lines) + "\n"


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()
    for src, dst in COPIES:
        target = OUT / dst
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / src, target)

    shutil.copytree(ROOT / "docs" / "images", OUT / "docs" / "images")  # README images keep their path

    (OUT / "versions").mkdir()
    for p in (ROOT / "versions").glob("*.md"):
        shutil.copy2(p, OUT / "versions" / p.name)
    (OUT / "versions" / "index.md").write_text(versions_index())

    results = [d for d in (ROOT / "tests" / "results").iterdir() if (d / "summary.md").exists()]
    for d in results:
        (OUT / "tests" / "results" / d.name).mkdir(parents=True)
        shutil.copy2(d / "summary.md", OUT / "tests" / "results" / d.name / "summary.md")
    (OUT / "tests" / "results" / "index.md").write_text(validation_page(results))

    (OUT / "license.md").write_text("# License\n\n```text\n" + (ROOT / "LICENSE").read_text() + "```\n\n"
                                    "The demo PDF is redistributed under its own license: "
                                    "see [Demo files](scripts/demo-files/README.md).\n")

    # The README becomes guide.md: point links at it from every copied page.
    for md in OUT.rglob("*.md"):
        text = md.read_text()
        new = re.sub(r"\]\(((?:\.\./)*)README\.md", r"](\1guide.md", text)
        if md.parent != OUT / "scripts" / "demo-files":
            new = new.replace("](LICENSE)", "](license.md)").replace("](../LICENSE)", "](../license.md)")
        if new != text:
            md.write_text(new)
    print(f"site source assembled in {OUT.relative_to(ROOT)}/ ({sum(1 for _ in OUT.rglob('*.md'))} pages)")


if __name__ == "__main__":
    main()
