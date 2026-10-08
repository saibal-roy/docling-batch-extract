"""Crawl a served copy of the site and report broken links, missing anchors and assets.

Usage: python3 scripts/check_site.py <base-url> [--deny-file FILE] [--no-search] [--ignore PATH ...]
  base-url     e.g. http://localhost:8080/docling-batch-extract/ (the GitHub Pages subpath)
  --no-search  don't check for an MkDocs search index (e.g. for the user-site root)
  --ignore     a path below base-url served by another repository (e.g. docling-batch-extract/):
               links into it aren't followed. Repeatable.
  --deny-file  optional local file of terms that must never appear on the site (one per line,
               e.g. client names). Keep that file out of the repository.

Follows every internal link and asset (href/src) below base-url, checks HTTP status, checks
that #fragments exist on the target page, and checks that the search index contains key terms.
Standard library only. Exit code 1 on any problem.
"""
import json
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urldefrag, urljoin, urlparse

SEARCH_TERMS = ["pypdfium2", "JBIG2", "setup_ubuntu", "demo_run"]


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids = [], set()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        for key in ("href", "src"):
            if a.get(key):
                self.links.append(a[key])


def fetch(url):
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return r.status, r.read(), r.headers.get_content_type()
    except urllib.error.HTTPError as e:
        return e.code, b"", ""
    except urllib.error.URLError as e:
        return str(e.reason), b"", ""


def main():
    base = sys.argv[1].rstrip("/") + "/"
    deny = []
    if "--deny-file" in sys.argv:
        with open(sys.argv[sys.argv.index("--deny-file") + 1]) as f:
            deny = [t.strip().lower() for t in f if t.strip()]
    ignored = [base + a[len("--ignore="):].lstrip("/") if a.startswith("--ignore=") else None for a in sys.argv]
    ignored += [base + sys.argv[i + 1].lstrip("/") for i, a in enumerate(sys.argv) if a == "--ignore"]
    ignored = [p for p in ignored if p]
    queue, seen, pages, problems = [base], set(), {}, []
    referrers = {}
    while queue:
        url = queue.pop()
        if url in seen:
            continue
        seen.add(url)
        status, body, ctype = fetch(url)
        if status != 200:
            problems.append(f"HTTP {status}: {url}  (linked from {referrers.get(url, '?')})")
            continue
        if ctype != "text/html":
            continue
        text = body.decode("utf-8", "replace")
        for term in deny:
            if term in text.lower():
                problems.append(f"denied term found on {url}")
        page = Page()
        page.feed(text)
        pages[url] = page
        for link in page.links:
            absolute = urljoin(url, link)
            target, _ = urldefrag(absolute)
            if urlparse(absolute).scheme not in ("http", "https") or not target.startswith(base):
                continue
            if any(target.startswith(p) for p in ignored):
                continue
            referrers.setdefault(target, url)
            if target not in seen:
                queue.append(target)

    # Fragments: every #id linked from a page must exist on the target page.
    for url, page in pages.items():
        for link in page.links:
            absolute = urljoin(url, link)
            target, frag = urldefrag(absolute)
            if frag and target.startswith(base) and target in pages and frag not in pages[target].ids:
                problems.append(f"missing anchor #{frag} on {target}  (linked from {url})")

    status, body = (None, None) if "--no-search" in sys.argv else fetch(base + "search/search_index.json")[:2]
    if status is None:
        pass
    elif status != 200:
        problems.append("search index missing")
    else:
        index = json.dumps(json.loads(body)).lower()
        problems += [f"search index lacks '{t}'" for t in SEARCH_TERMS if t.lower() not in index]

    html_pages = len(pages)
    print(f"checked {len(seen)} URLs ({html_pages} HTML pages) under {base}")
    for p in sorted(set(problems)):
        print("  PROBLEM:", p)
    print("OK: no broken links, anchors or assets" if not problems else f"{len(set(problems))} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
