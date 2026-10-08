# Landing page: Plan v1 (GitHub Pages)

**Status:** Superseded by [landing-page-plan-v2.md](landing-page-plan-v2.md) (local Pages simulation, link handling). This is a separate track from the extractor plans (`plan-v1` … `plan-v5`).
**Date:** 2026-10-08

## 1. Expectations

> A landing page for this solution with all the documentation and learnings so far, hosted on GitHub Pages.

| ID | Expectation |
|----|-------------|
| L1 | A **landing page** that explains the solution in under a minute: the problem, the result, how to start |
| L2 | **All documentation** on the site: setup, operations, capacity, tests, CI, troubleshooting |
| L3 | **All learnings**: the decision history (`versions/`), benchmark findings, the build story and the prompts |
| L4 | Hosted on **GitHub Pages** from this repository, at `https://saibal-roy.github.io/docling-batch-extract/` |
| L5 | **One source of truth.** The site is built from the repository's Markdown, so docs and site can't drift |
| L6 | **Maintainable:** rebuilt and deployed automatically on every push to `main` |
| L7 | **No client data** on the site, ever (same rule as the repository) |

**Audiences:** developers who want to run it · engineering managers and teams evaluating the "build with Claude" approach · legal-tech and RAG teams comparing it with cloud OCR.

## 2. Design

### Technology
**MkDocs with the Material theme**, built in GitHub Actions and deployed with `actions/deploy-pages`.
- **Why:** pages are written in Markdown, so the existing README, plans, prompts and story are reused as they are (L5). It provides search, dark mode and a mobile layout without custom code.
- **Landing page:** a custom home page that uses Material's built-in landing-page features, so no separate HTML project is needed.
- **Alternatives considered:**
  - A hand-written HTML landing page: nicer visually, but the docs would have to be copied into it (violates L5).
  - Jekyll, GitHub Pages' default: weaker search and theming.

### Site map

| Page | Source |
|------|--------|
| **Home (landing)** | New `docs/index.md`: hero ("Batch PDF → Markdown for RAG on one CPU server"), a cost comparison card (self-hosted against Textract, from the README), how-it-works diagram, headline numbers, buttons for Quick start · Story · GitHub |
| Getting started | README: developer machine setup |
| Server setup | README: server setup + `scripts/setup_ubuntu.sh` |
| Operations | README: usage, logs, cleanup, troubleshooting |
| Capacity & cost | README: spec, memory profile, throughput, pilot estimate |
| Tests & CI | README: test results, benchmarks, CI |
| Design history | `versions/plan-v1.md` … `plan-v5.md`, with a timeline index page |
| Build story | `STORY.md` |
| Prompts | `prompts.md` |
| License | `LICENSE` |

### Single source of truth
- The site pages are short wrapper files in `docs/` that pull in the repository's files with the `pymdownx.snippets` extension (`--8<-- "README.md"`), or that use the `mkdocs-include-markdown-plugin` to include sections of the README.
- Only `docs/index.md` (the landing page) and `mkdocs.yml` are written specifically for the site.

### Build and deploy
- New `.github/workflows/pages.yml` runs on push to `main` (when `*.md`, `docs/**`, `mkdocs.yml` or `versions/**` change) and on manual runs.
- Steps: `pip install mkdocs-material` → `mkdocs build --strict` (fails on broken links) → upload the artifact → `deploy-pages`.
- The existing CI data guard also scans `docs/` (L7).
- Repository settings: Pages → Source: GitHub Actions.

### Content rules
- Use only measured numbers, and always say which hardware they came from.
- Show cloud prices with an "as of" date and a link to the source.
- Never mention client names, file names or document text.

## 3. Acceptance criteria

| ID | Covers | Check | Pass condition |
|----|--------|-------|----------------|
| LA1 | L1 | Open the home page on a phone and a laptop | Problem, result and "Get started" are visible without scrolling; no horizontal scroll at 375 px |
| LA2 | L2, L3 | Navigation | Every page in the site map exists and is reachable from the nav |
| LA3 | L4 | Visit `https://saibal-roy.github.io/docling-batch-extract/` | Site loads over HTTPS |
| LA4 | L5 | Change a sentence in README.md and push | The change appears on the site after the workflow runs; no copy was edited by hand |
| LA5 | L6 | `mkdocs build --strict` in CI | Passes; a broken link fails the build |
| LA6 | L7 | CI data guard + `grep` for client identifiers in the built `site/` | Nothing found |
| LA7 | Quality | Lighthouse on the home page | Accessibility ≥ 90, Performance ≥ 90 |
| LA8 | Search | Search for "pypdfium2" or "JBIG2" | Finds the troubleshooting and design-history entries |

## 4. Steps

1. Add `mkdocs.yml`, `docs/index.md` (landing page) and wrapper pages; build locally with `mkdocs serve`.
2. Add `.github/workflows/pages.yml`; extend the CI data guard to cover `docs/`.
3. Enable Pages (Source: GitHub Actions) once the repository exists.
4. Run LA1–LA8, then add the site link to the README and the repository's "About" box.

## 5. Open questions

- **Domain:** a custom domain, or `saibal-roy.github.io/docling-batch-extract`? (Default: the GitHub one.)
- **Screenshots:** should the landing page include a short terminal recording of a run?
- **Validation:** show the Ubuntu-container go-ahead results from `STORY.md` on the Tests & CI page.
