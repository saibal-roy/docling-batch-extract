# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning policy

The version is `__version__` in `extract.py` (`extract.py --version`). It's also written into every output JSON as `extractor_version`, next to the docling versions in `engine`.

These are the **public contract**. Breaking any of them is a **MAJOR** change:

| Contract | Examples of breaking changes |
|----------|------------------------------|
| Output JSON schema (`outputs/<name>.json`) | Renaming or removing a field, or changing a field's type or meaning |
| Folder layout | Renaming `inputs/`, `outputs/`, `completed/`, `errors/` or `logs/` |
| `extract.py` options and exit codes (0 / 1 / 2) | Removing or renaming an option, or changing what an exit code means |
| Per-document log lines (`DOC_START`, `DOC_DONE`, …) | Renaming fields that monitoring may parse |
| Script options (`setup_ubuntu.sh`, `demo_run.sh`, `cleanup.sh`) | Changing what a default run deletes or installs |

- **MINOR:** additive, backwards-compatible changes. Examples: new options, new JSON fields, new scripts, and **docling image upgrades**. A docling upgrade can change the Markdown even when the schema doesn't, so its release notes say so: re-index if you need consistent output.
- **PATCH:** fixes and documentation that leave the output unchanged.
- **Engine policy:** CPU-only `docling-serve-cpu`, pinned to an exact stable tag; upgrades are deliberate and gated (see the README's *Maintenance policy*). GPU variants are out of scope.
- **0.x:** until 1.0.0 the contract may still change in a MINOR release, and the release notes call it out. **1.0.0** follows the first production pilot batch, once the JSON schema and folder layout are confirmed.

Plan files (`versions/plan-vN.md`) are design history, not release numbers. Each release links to the plans it implements.

**Releasing:** the next version's changes collect under `## [X.Y.Z] - Unreleased`. When releasing, replace `Unreleased` with the date (`YYYY-MM-DD`), make sure `__version__` matches, then push the tag `vX.Y.Z`. The *Release* workflow checks that the tag, `__version__` and this file agree, runs the full CI, and creates the GitHub Release from this section.

## [0.1.0] - 2026-10-09

First public release: a batch PDF → Markdown extractor for RAG on one CPU-only **2 vCPU / 8 GB** server running **Ubuntu 26.04 LTS**. Plans: [v1](versions/plan-v1.md)–[v7](versions/plan-v7.md).

### Added
- `extract.py`: converts `inputs/*.pdf` with docling-serve to `outputs/<name>.json`, then moves each PDF to `completed/`, or to `errors/` on failure. Per-document logs in `logs/<name>.log`. Exit codes: 0 all succeeded, 1 some PDFs failed, 2 server down.
- Parallel page-range conversion for text PDFs (`--chunk-pages 5`); scanned PDFs are detected automatically, converted whole and OCR'd (`--ocr auto`).
- Memory-aware dispatch (`--mem-high 0.75`), container-restart recovery, and "busy is not down" polling.
- `pdf_backend=pypdfium2` by default. docling's default PDF reader ran out of memory on JBIG2 scans.
- Every output JSON carries `extractor_version` and `engine` (docling-serve and docling versions, PDF reader). `extract.py --version` prints the version.
- `docker-compose.yml`: CPU-only `docling-serve-cpu:v1.36.0` (latest stable), **published on `127.0.0.1` only**. Sizing comes from `.env` (written by `setup_ubuntu.sh` from the machine's CPUs and RAM): **1 worker × 2 threads, ~6.5 GB limit on the 2 vCPU / 8 GB target**. `extract.py` reads the worker count from the container.
- Scripts: `setup_ubuntu.sh` (server setup), `demo_run.sh` (first run + benchmark, with a CC BY 4.0 demo PDF), `cleanup.sh`, `preview_site.sh` and `check_github_pages.sh` (documentation site).
- Tests: 18 acceptance checks, benchmarks, `tests/profile_benchmark.sh` (size any machine), and the go-ahead gate `tests/ubuntu_container_test.sh`: Ubuntu 26.04 LTS on a simulated 2 vCPU / 8 GB machine.
- CI (lint, data guard, setup + acceptance on Ubuntu 26.04 LTS), a Pages workflow (documentation site), and a Release workflow. All dependencies pinned to their latest stable releases (`requests` 2.34.2, `pypdf` 6.19.0, Actions `checkout@v7` …).
- Documentation: README, STORY.md, prompts.md, design history, and a documentation site built with MkDocs.

### Known trade-off
- docling-serve-cpu v1.36.0 converts **scanned PDFs ~20–25 % faster** but **text PDFs ~45–80 % slower** than v1.30.0 at 2 vCPU (`tests/results/2026-10-08_profiles/`). Chosen for scan-heavy legal and claims batches. Re-check when upgrading docling.

### Security
- docling-serve has no authentication. It's bound to loopback, and acceptance check A25 and `demo_run.sh` fail if it's published beyond loopback. The README's AWS guidance: never open port 5001 in a security group.
- `SECURITY.md`: report vulnerabilities privately through GitHub (private vulnerability reporting is enabled); never attach real documents.
