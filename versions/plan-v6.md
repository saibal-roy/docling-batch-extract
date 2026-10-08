# Plan v6 — semantic versioning and releases

**Status:** Superseded by [plan-v7.md](plan-v7.md) (2 vCPU target, latest LTS, docling v1.36.0). Supersedes [plan-v5.md](plan-v5.md).
**Date:** 2026-10-08

## Changes from v5

| Change | Reason |
|--------|--------|
| **Semantic versioning**, starting at **0.1.0** | People depend on this tool's *outputs*, so the version must signal when they break. **1.0.0** follows the first production pilot, once the JSON schema and folder layout are confirmed. Until then, 0.x allows breaking changes in a MINOR release, called out in the notes |
| **The public contract is defined** (`CHANGELOG.md`): output JSON schema, folder layout, `extract.py` options and exit codes, per-document log lines, script options | This is a batch tool, not a library: MAJOR/MINOR/PATCH only mean something once the contract is stated. A docling image upgrade is MINOR, but its notes must say the Markdown may change |
| **`__version__` in `extract.py`** and `extract.py --version` | One source of truth, kept inside the single-file tool |
| **`extractor_version` and `engine` in every output JSON** (`docling_serve`, `docling`, `pdf_backend`, read from docling-serve's `/version`) | Provenance for the RAG index: which tool and model versions produced each document, so re-processing after an upgrade can be selective. An additive field, so MINOR-compatible |
| **`RUN_START` shows `scanned_chunk_pages`, the version and the docling-serve version** | It previously showed only `chunk_pages=5` while a scan used `0`, which was confusing |
| **`CHANGELOG.md`** (Keep a Changelog) | Release notes in the repository, linked to the plan versions that explain *why* |
| **`release.yml`**: tag `vX.Y.Z` → check that the tag, `__version__` and a **dated** CHANGELOG section agree → **full CI** (reused via `workflow_call`) → GitHub Release with that section as notes (relative links made absolute; `-rc` tags become prereleases) | A release can't happen with mismatched versions, an undated changelog, or failing tests. The maintainer still decides when to tag |
| **Maintenance policy: CPU only, pinned, upgraded deliberately** (README) | Requested: the solution exists to stay cost-effective and is maintained part-time. docling publishes **no LTS line** (checked 2026-10-08: 323 `docling-serve-cpu` tags, stable `v1.x.y` up to `v1.36.0` plus the moving `latest`/`main`). So "LTS" here means the **pinned, validated CPU tag** (`v1.30.0`). Upgrades happen only to stable CPU tags, with a reason or about quarterly, and only after the go-ahead gate and benchmarks pass. They're released as MINOR. GPU variants are out of scope |

## New expectations and checks

| ID | Expectation | Check |
|----|-------------|-------|
| E20 | Every output records the tool and engine versions | A7 now requires `extractor_version` and `engine` (with `docling_serve` and `pdf_backend` filled in) |
| E21 | A release can't be published inconsistently | `release.yml` verify job (tag = `__version__`, semver format, dated CHANGELOG section) and the full CI |

Plan numbers (`plan-vN`) remain design history and are independent of release numbers.
