"""MkDocs hook: point links to repository files that aren't part of the site at GitHub.

The site source (site-src/, assembled by scripts/build_site.py) keeps the repository's layout,
so links between Markdown pages work as they are. Links to code, scripts, YAML, PDFs or folders
without a page become https://github.com/<repo>/blob|tree/main/<path>, instead of 404s.
"""
import posixpath
import re

REPO = "https://github.com/saibal-roy/docling-batch-extract"
LINK = re.compile(r"(\]\()([^)\s]+)(\))")
SKIP = ("http://", "https://", "mailto:", "#")


def _rewrite(target, page_dir, files):
    if target.startswith(SKIP):
        return target
    path, _, anchor = target.partition("#")
    resolved = posixpath.normpath(posixpath.join(page_dir, path))
    if resolved.startswith(".."):
        return target
    is_dir = path.endswith("/")
    if is_dir:
        for index in ("index.md", "README.md"):
            if files.get_file_from_path(posixpath.join(resolved, index)):
                return path + index + (f"#{anchor}" if anchor else "")
        return f"{REPO}/tree/main/{resolved}"
    if files.get_file_from_path(resolved):
        return target
    return f"{REPO}/blob/main/{resolved}" + (f"#{anchor}" if anchor else "")


def on_page_markdown(markdown, page, config, files):
    page_dir = posixpath.dirname(page.file.src_uri)
    return LINK.sub(lambda m: m[1] + _rewrite(m[2], page_dir, files) + m[3], markdown)
