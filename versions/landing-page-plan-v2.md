# Landing page — Plan v2 (GitHub Pages, with local Pages simulation)

**Status:** Built and checked locally (LA1, LA2, LA4, LA5, LA7–LA11 pass); publishing waits for the repository. Supersedes [landing-page-plan-v1.md](landing-page-plan-v1.md). This is a separate track from the extractor plans.
**Date:** 2026-10-08

## Changes from v1

| Change | Reason |
|--------|--------|
| **Local GitHub Pages simulation** (`scripts/preview_site.sh`) before anything is published | Requested. GitHub Pages only hosts static files, so the published result can be reproduced locally. That includes the `/docling-batch-extract/` subpath and case-sensitive paths (macOS's file system ignores case and would hide those errors) |
| **Site source is assembled at build time in the repository's own folder layout** (`scripts/build_site.py`), plus a link-rewriting hook | The README links to `versions/…`, `tests/results/…`, `extract.py`, `.github/workflows/ci.yml` and so on. Pulling the README into `docs/` with includes would break every one of those relative links, and `--strict` would fail. Keeping the same layout makes the Markdown links work unchanged. Links to non-Markdown files (code, scripts, YAML) are rewritten to their GitHub page |
| **New pages:** *First demo run* and *Validation* (Ubuntu container go-ahead results) | Added to the solution after v1 |
| **New checks LA9–LA12** for local preview, link checking, case sensitivity and running the workflow locally | Catch publishing problems before the first push |

## 1. Expectations

| ID | Expectation |
|----|-------------|
| L1 | A **landing page** that explains the solution in under a minute: the problem, the result, how to start |
| L2 | **All documentation** on the site: setup, first demo run, operations, capacity, tests, CI, troubleshooting |
| L3 | **All learnings**: decision history (`versions/`), benchmark findings, validation results, the build story and the prompts |
| L4 | Hosted on **GitHub Pages** at `https://saibal-roy.github.io/docling-batch-extract/` |
| L5 | **One source of truth.** The site is built from the repository's Markdown, so docs and site can't drift |
| L6 | **Maintainable:** rebuilt and deployed automatically on every push to `main` |
| L7 | **No client data** on the site, ever |
| L8 | **Checked locally first:** the exact site that Pages will serve can be previewed and checked on a developer machine, under the same subpath, before publishing |

## 2. Design

### Technology
**MkDocs with the Material theme**, built in GitHub Actions and deployed with `actions/deploy-pages`. Material provides search, dark mode and a mobile layout. A custom `docs/index.md` is the landing page.

### Building the site source (single source of truth)
`scripts/build_site.py` assembles `site-src/` (git-ignored) **in the repository's own folder layout**, so every relative link in the Markdown keeps working:

| Copied into `site-src/` | Becomes |
|---|---|
| `docs/index.md` (written for the site) | Home / landing page |
| `README.md` | `guide.md`: getting started, server setup, first demo run, operations, capacity, tests and CI (one long page with a table of contents; links to `README.md` are pointed at `guide.md`) |
| `STORY.md`, `prompts.md` | Build story, Prompts |
| `versions/*.md` | Design history, plus a generated index (timeline of plan versions) |
| `tests/results/*/summary.md` | Validation and benchmark records |
| `scripts/demo-files/README.md` | Demo file and license |
| `LICENSE` | `license.md` |

A small **MkDocs hook** (`docs/hooks.py`) rewrites links to anything that isn't part of the site (`extract.py`, `scripts/*.sh`, `.github/workflows/*.yml`, `docker-compose.yml`, demo PDFs) to `https://github.com/saibal-roy/docling-batch-extract/blob/main/<path>`. Only `docs/index.md`, `docs/hooks.py`, `mkdocs.yml` and `scripts/build_site.py` are written specifically for the site.

### Site map

| Nav | Source |
|-----|--------|
| **Home** | `docs/index.md`: hero ("Batch PDF → Markdown for RAG on one CPU server"), cost card (self-hosted against Textract, from the README), how-it-works diagram, headline measured numbers, buttons: Get started · First demo run · Story · GitHub |
| Guide | `README.md` (setup, demo, operations, capacity, troubleshooting, tests, CI) |
| Validation | Go-ahead gate results (now Ubuntu 26.04 LTS on 2 vCPU / 8 GB; earlier 22.04/24.04 runs kept as history) and the acceptance and benchmark records (`tests/results/`) |
| Design history | `versions/` index + plans v1–v5 + landing-page plans |
| Build story | `STORY.md` |
| Prompts | `prompts.md` |
| License | `LICENSE` + demo-file attribution |

### Local GitHub Pages simulation (`scripts/preview_site.sh`)
Everything runs in Docker, so a developer only needs Docker. The script:

1. **Build.** Run `scripts/build_site.py`, then `mkdocs build --strict` in a `python:3.12-slim` container. It fails on any broken internal link or missing page. The output in `site/` is exactly what the Pages workflow uploads.
2. **Serve it the way Pages does.** `nginx:alpine` (a Linux, case-sensitive file system) serves `site/` under the project subpath:
   `docker run --rm -p 8080:80 -v "$PWD/site":/usr/share/nginx/html/docling-batch-extract:ro nginx:alpine`
   → `http://localhost:8080/docling-batch-extract/`. Assets that only work at the root of a domain, or paths whose letter case doesn't match, fail here just as they would on Pages.
3. **Check links.** Run `lycheeverse/lychee` over the served site: internal links, anchors, and (optionally, with `--online`) external links.
4. **Live editing mode** (`--serve`): `mkdocs serve` with auto-reload, for writing content.
5. **Optional extras:**
   - Lighthouse (`npx lighthouse http://localhost:8080/docling-batch-extract/`) for LA1 and LA7.
   - [`act`](https://github.com/nektos/act) to run `.github/workflows/pages.yml` locally up to the build and upload steps.

**What can't be reproduced locally:** the deploy step itself, GitHub's HTTPS certificate, a custom domain's DNS, and CDN caching. LA3 covers these on the first real deploy.

### Build and deploy
- `.github/workflows/pages.yml` runs on push to `main` (when `*.md`, `docs/**`, `mkdocs.yml`, `versions/**`, `tests/results/**` or `scripts/build_site.py` change) and on manual runs.
- Steps: `scripts/build_site.py` → `mkdocs build --strict` → lychee link check (offline) → upload the artifact → `deploy-pages`.
- The CI data guard also scans `docs/`. The workflow searches the built `site/` for client identifiers before uploading.
- Repository settings: Pages → Source: **GitHub Actions** (one-time, after the repository exists).

### Content rules
- Use only measured numbers, and always say which hardware they came from (Apple M2 / Ubuntu containers on Docker Desktop).
- Show cloud prices with an "as of" date and a source link. Make no claims about environments the solution wasn't run in.
- Never mention client names, file names or document text.

## 3. Acceptance criteria

| ID | Covers | Check | Pass condition |
|----|--------|-------|----------------|
| LA1 | L1 | Home page at 375 px and 1280 px | Problem, result and "Get started" are visible without scrolling; no horizontal scroll |
| LA2 | L2, L3 | Navigation | Every page in the site map exists and is reachable from the nav |
| LA3 | L4 | Visit `https://saibal-roy.github.io/docling-batch-extract/` after the first deploy | Site loads over HTTPS |
| LA4 | L5 | Change a sentence in README.md, then rebuild (locally) or push | The change appears on the site; no copy was edited by hand |
| LA5 | L6 | `mkdocs build --strict` locally and in the Pages workflow | Passes; an introduced broken link fails the build |
| LA6 | L7 | CI data guard + search of the built `site/` for client identifiers | Nothing found |
| LA7 | Quality | Lighthouse on the home page (local preview) | Accessibility ≥ 90, Performance ≥ 90 |
| LA8 | Search | Search for "pypdfium2" or "JBIG2" | Finds the troubleshooting and design-history entries |
| LA9 | L8 | `scripts/preview_site.sh` | Site works at `http://localhost:8080/docling-batch-extract/` in nginx: all nav pages load, CSS/JS/search work, no 404 in the server log |
| LA10 | L8 | lychee over the local preview | 0 broken internal links or anchors |
| LA11 | L8 | Code/script links on the Guide page | They open the file on GitHub (`/blob/main/…`) rather than 404 |
| LA12 | L6, L8 | (Optional) `act -j build` for `pages.yml` | Build and upload steps succeed locally |

## 4. Steps

1. Add `mkdocs.yml`, `docs/index.md`, `docs/hooks.py` and `scripts/build_site.py`, and git-ignore `site-src/` and `site/`.
2. Add `scripts/preview_site.sh` and run LA1, LA2, LA4, LA5 and LA7–LA11 locally.
3. Add `.github/workflows/pages.yml` and extend the data guard to `docs/` and the built site.
4. After the repository is created and pushed: enable Pages (Source: GitHub Actions), run the workflow, and check LA3 and LA6.
5. Add the site link to the README and the repository's "About" box.

## 5. Open questions

- **Domain:** a custom domain, or `saibal-roy.github.io/docling-batch-extract`? (Default: the GitHub one.)
- **Screenshots:** a short terminal recording of `scripts/demo_run.sh` on the landing page?

## 6. Implementation notes (2026-10-08)

Built as planned, with these differences, each found while testing locally:

| Planned | Built | Why |
|---------|-------|-----|
| lychee for link checking | `scripts/check_site.py` (standard library only) crawls the served site: HTTP status of every page and asset, `#fragment` targets, and search-index terms. An optional `--deny-file` checks for terms that must never appear (kept outside the repository) | No extra image; checks anchors and search too; the same script runs in the Pages workflow |
| Mermaid diagram on the landing page | Plain-text diagram | Mermaid loads a large JavaScript library from a CDN; phone performance was 63 |
| Theme fonts (Google Fonts) | System fonts (`theme.font: false`) | Faster, and no third-party requests |
| — | `docs/stylesheets/extra.css` + `docs/javascripts/a11y.js`: underlined links in text, darker code comments, footer and tab contrast, an accessible name for the search dialog | Lighthouse accessibility was 89 |
| — | The local nginx compresses responses | GitHub Pages does too, so local Lighthouse figures stay comparable |
| — | Folder links (`versions/`) point at the folder's index page | `--strict` flagged them as unrecognized links |
| — | Heading anchors use GitHub-style slugs (`pymdownx.slugs`) | The README's own `#links` work unchanged on the site |
| — | MkDocs pinned at 1.6.1 (Material 9.7.7) | Material's maintainers warn that MkDocs 2.0 drops plugins and theme overrides |

**Local results:** strict build passes; the crawl under `/docling-batch-extract/` covers 24 URLs (18 pages) with no broken links, anchors or assets and no 404s from nginx. Lighthouse on the home page: phone performance 92–99, accessibility 100, best practices 96, SEO 100; laptop 100 / 100 / 96 / 100. On a 375 px phone viewport the content fits with no horizontal scroll.

**Publishing readiness (checked 2026-10-08, read-only):** account `saibal-roy` signed in to the GitHub CLI with the `repo` and `workflow` scopes; no `saibal-roy.github.io` user-site repository (optional; project sites work without it) and no custom domain, so the site will be at `https://saibal-roy.github.io/docling-batch-extract/` once the public repository exists and Pages → Source is set to GitHub Actions. Email verification has to be confirmed in the web settings. `scripts/check_github_pages.sh` repeats these checks and changes nothing; the README's *Publishing the documentation site* section lists the prerequisites and steps for both the project and the user site.

**Two-address preview (2026-10-08):** the user site lives in its own repository folder next to this one (`../saibal-roy.github.io`: static `index.html`, `.nojekyll`, README). `scripts/preview_site.sh` serves it at `http://localhost:8080/` and this project at `/docling-batch-extract/` (the same layout as GitHub Pages) and crawls both. Lighthouse for the user site (phone): performance 100, accessibility 100, SEO 100.

**Deployment (2026-10-08):** both sites deploy through GitHub Actions on **every push to `main`**: the project's `pages.yml` (build --strict → crawl → deploy, path filter removed) and the user site's own `pages.yml` (stage → crawl with `--ignore docling-batch-extract/` → deploy). Pages source for both repositories: **GitHub Actions**.
