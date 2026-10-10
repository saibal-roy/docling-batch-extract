# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`extract.py` converts PDFs in `inputs/` to Markdown through a long-running docling-serve container (CPU-only image `docling-serve-cpu:v1.36.0`, `127.0.0.1:5001`, 1 worker × 2 threads on the validated 2 vCPU / 8 GB target, Ubuntu 26.04 LTS only). It writes `outputs/<stem>.json`, moves each PDF to `completed/` or `errors/`, and writes one log per PDF to `logs/<stem>.log`. Requirements and their history are in `versions/plan-v*.md` (latest: plan-v7; proposals such as `proposal-s3-files-inputs.md` are not implemented). Never commit client documents or their text; each data folder has its own `.gitignore` (keep the folder, ignore its contents; don't delete these files), and `*.pdf` and `.claude/` are ignored at the root, and real PDFs for benchmarks go in the git-ignored `tests/fixtures/`. The README covers setup, sizing and measured benchmarks. Never name the owner's employer or any client anywhere in this repository (code, docs, STORY.md, release notes, commit messages).

## Keeping prompts.md current

`prompts.md` is the single copy of the build prompts (saibal-roy.github.io links to it). At the end of every successful run (checks passed, the owner accepted the result), compare the prompt that started it with what actually worked, fold any improvement into the prompt itself, and add a line to its improvements log. Change nothing if nothing needs improving.

## Commands

```bash
docker compose up -d                       # start docling-serve (must be running; the script never starts it)
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python extract.py                # process inputs/ once; exits 0 ok / 1 some PDFs failed / 2 server down
.venv/bin/python extract.py --help         # all tuning flags

scripts/setup_ubuntu.sh                    # server: Docker + venv + container + cron (Ubuntu 26.04 LTS only; --force for others; run as non-root)
scripts/demo_run.sh                        # env checks + convert scripts/demo-files/*.pdf + benchmark report (inputs/ must hold no PDFs)
tests/ubuntu_container_test.sh             # go-ahead gate: setup → smoke → cleanup → demo → acceptance in an Ubuntu 26.04 LTS container
scripts/preview_site.sh                    # docs site: build --strict, serve like GitHub Pages at localhost:8080/docling-batch-extract/, crawl links
scripts/check_github_pages.sh              # read-only: is the GitHub account/repo ready for Pages? (never creates anything)
scripts/cleanup.sh --dry-run               # list artifacts; without -n it empties outputs/completed/errors/logs (keeps inputs/)

.venv/bin/pip install -r tests/requirements.txt
tests/run_acceptance.sh --quick            # acceptance checks only (~5 min); restarts and stops the container
tests/run_acceptance.sh                    # plus benchmarks (~25 min); results in tests/results/<timestamp>/summary.md
.venv/bin/python tests/measure_job.py <pdf> <first> <last> [docling_opt=value ...]   # one job: time and peak memory
```

Lint like CI does: `ruff check .` (rules in `ruff.toml`; broad `except Exception` is intentional) and `shellcheck -S warning scripts/*.sh tests/*.sh`. CI (`.github/workflows/ci.yml`) provisions an Ubuntu 26.04 LTS runner with `scripts/setup_ubuntu.sh`, then runs the smoke test, the cleanup test and `run_acceptance.sh --quick`. It also fails if any PDF or data folder is tracked by git.

There is no unit-test framework. The tests are end-to-end against the live container and run in an isolated `tests/work/` directory.

## Architecture notes

- **Unit of work is a chunk** (PDF + `page_range`), not a PDF. Chunks are queued in document order. A `ThreadPoolExecutor` runs at most `--max-inflight` of them, and new submissions pause while container memory ≥ `--mem-high`. The memory figure comes from a `MemoryMonitor` thread polling `docker stats`. A document is finished when all its chunks are; then the JSON is written (temp file + `os.replace`) **before** the PDF is moved.
- **Text PDFs are split** (`--chunk-pages 5`). **Scanned PDFs are not** (`--scanned-chunk-pages 0`) and get `force_ocr=true`. "Scanned" means ≥ 50 % of pages carry an image at least as wide as the page (`is_scanned_page`). Both choices come from the benchmarks in the README; re-measure before changing them.
- **`pdf_backend=pypdfium2` is deliberate.** docling's default `docling_parse` used more than 6 GB on a single JBIG2-scanned page and crashed the 6.5 GB container.
- **Busy server ≠ dead server.** docling-serve stops answering HTTP while converting, so poll timeouts mean "keep waiting". A chunk is resent only when `docker inspect` RestartCount changes or the task 404s. Resending on timeout caused duplicate jobs and OOM in earlier versions.
- **Failure routing:** document errors → `fail_doc()` moves the PDF to `errors/`. `ServerDown` (no `/health` after a restart) aborts the run and leaves PDFs in `inputs/`.
- **Logging:** the `extract` logger writes to the console only. Each document has a child logger `extract.doc.<stem>` with its own file handler (mode `w`). There is intentionally no cumulative log file.
- `--max-inflight` should equal `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` in `docker-compose.yml`. When changing workers, threads or the memory limit, change them together. The README has the measured memory profile.
- docling-serve API reference for the pinned version: http://localhost:5001/docs (endpoints used: `/health`, `/v1/convert/file/async`, `/v1/status/poll/{id}`, `/v1/result/{id}`).
- **Docs site:** `scripts/build_site.py` copies the repository's Markdown into `site-src/` (git-ignored) in the same layout; `docs/hooks.py` points links to non-page files at GitHub. Only `docs/index.md` (landing page), `docs/stylesheets`, `docs/javascripts` and `mkdocs.yml` are site-specific; edit content at its source (README, STORY, versions/), never in `site-src/`. Keep MkDocs at 1.x (pinned in `docs/requirements.txt`).
- **Security:** docling-serve has no authentication. `docker-compose.yml` publishes it on `127.0.0.1` only (acceptance check A25 and `demo_run.sh` enforce this); never change it to `0.0.0.0`, and never document opening port 5001 in a firewall or security group.
- **Versioning:** semantic versioning; `__version__` in `extract.py` is the single source and is written into every output JSON (`extractor_version`, `engine`). The public contract (JSON schema, folders, options, exit codes, log lines) is defined in `CHANGELOG.md`. Breaking it means a MAJOR bump (MINOR while 0.x). Add each change under the next version's `Unreleased` section. `release.yml` requires tag = `__version__` = a dated CHANGELOG section.
- **Engine policy:** CPU-only `docling-serve-cpu`, pinned to an exact stable tag (never `latest`/`main`, never GPU variants). Upgrade only deliberately (reason or ~quarterly), after `tests/ubuntu_container_test.sh` and benchmarks pass; release as MINOR with a re-index note. The maintainer works on this part-time, so prefer stability over new features.
- **User site:** `https://saibal-roy.github.io/` comes from a separate repository folder next to this one (`../saibal-roy.github.io`, plain `index.html`). `scripts/preview_site.sh` serves it at `/` with this project at `/docling-batch-extract/` (`USER_SITE` overrides the path). Both repositories deploy with their own `pages.yml` on every push to `main` (Pages source: GitHub Actions); the user site's checker skips `docling-batch-extract/`. Don't add user-site files to this repository.
- **Platform policy:** only the latest Ubuntu LTS is supported (currently 26.04). Setup refuses other releases without `--force`; CI, the container gate and docs target that one release. When a new LTS ships, move everything to it in one validated change.
