# Plan v5: benchmark-driven defaults, test suite, open-source release

**Status:** Superseded by [plan-v6.md](plan-v6.md) (semantic versioning). Supersedes [plan-v4.md](plan-v4.md).
**Date:** 2026-10-08

## Context

This solution supplies Markdown to a **RAG search system for legal and claims-insurance documents**. It replaces cloud OCR (AWS Textract, vision-LLM APIs), which was too expensive for a pilot of **about 500 documents × ~47 pages (~23,500 pages)**. It has to run unattended in batches on one low-cost CPU-only VM. The documents are confidential client files, which shapes the data-handling rules below.

## Changes from v4

| Change | Reason / evidence |
|--------|-------------------|
| **Scanned PDFs are no longer split** (`--scanned-chunk-pages 0`). Text PDFs still use 5-page ranges | Benchmark (A16). A 37-page real scanned document took **156 s** split into ranges and **133 s** as one job. Two OCR jobs at once pushed memory to 5.4 GB and caused 5 throttle pauses; one job peaked at 4.8 GB with 1 pause. A 60-page text PDF was the opposite: **125 s** split and **157 s** whole, with no throttling. Markdown output was the same either way (±0.01 %) |
| **`--timeout` is now seconds per page** (default 60, minimum 10 minutes per job) | An unsplit scanned document can be hundreds of pages, so a fixed per-job limit would cut long scans off |
| **Test suite in `tests/`** | `make_test_pdfs.py` (including a simulated scan, so tests don't need client files), `measure_job.py` (one job: time and peak memory) and `run_acceptance.sh` (17 PASS/FAIL checks plus a 4-mode benchmark, run in an isolated `tests/work/`) |
| **Benchmarks warm up first** | The first conversion after a container start pays ~20–45 s of pipeline set-up. A cold benchmark measured 176 s instead of ~125 s |
| **Client data hygiene** | Removed every client file name and quoted text from the docs and tests. Each data folder (`inputs/`, `outputs/`, `completed/`, `errors/`, `logs/`, `tests/fixtures/`) has its own `.gitignore` (`*` / `!.gitignore`), so the folder exists in a fresh clone but its contents are never tracked. The root `.gitignore` adds `*.pdf`, `tests/work/` and `.claude/` (local tool settings can contain file names). `cleanup.sh` keeps those `.gitignore` files, and the CI data guard allows only them inside data folders. Real documents are benchmarked only through the git-ignored `tests/fixtures/` |
| **Open source:** MIT `LICENSE` (saibal-roy), README with background, setup, capacity and cost comparison | Release requirement |
| **`scripts/setup_ubuntu.sh`** and **`scripts/cleanup.sh`** | Repeatable server preparation (Docker from the official repo, venv, container, cron). Cleanup keeps `inputs/` (unprocessed documents) and test results unless asked, and asks before deleting. Setup was trial-run in an `ubuntu:24.04` container up to the systemd step; the container start and cron steps still need a run on a real server |
| **GitHub Actions CI** (`.github/workflows/ci.yml`) | Every push and PR is linted and **tested end to end on real Ubuntu 22.04 and 24.04 runners**. The setup script provisions the runner, so the server setup path is tested in CI (including the container start and cron steps that couldn't run in a local container). A data guard fails the build if a PDF or output is ever tracked. Benchmarks run on demand. `ruff.toml` pins the lint rules so local and CI results match |
| **`input/` renamed to `inputs/`** | Requested; matches `outputs/`. `extract.py --input` keeps its name (default now `inputs`); `cleanup.sh --inputs` (alias `--input`) |
| **Go-ahead criterion: tests pass in Ubuntu containers on Docker Desktop** (`tests/ubuntu_container_test.sh`, Ubuntu 22.04 and 24.04) | Requested as the release gate. A cloud pilot is not claimed. Each container runs, as a non-root sudo user: setup → checks → setup again → smoke test → cleanup → 17 acceptance checks, against the host's Docker daemon. A pass needs the log's final marker. The first version of the harness "passed" without running anything (`docker run` without `-i`), so the marker check was added |
| **`scripts/demo_run.sh`** + **`scripts/demo-files/`** | Requested: a first run on a newly deployed machine. It checks the environment (OS, CPUs, RAM, disk, Docker resources, container and memory limit, `/health`, venv, folders, empty `inputs/`), converts the demo PDF with the real `extract.py` and reports a benchmark for that machine. The demo PDF is the public *Docling Technical Report* (arXiv:2408.09869, **CC BY 4.0**, so redistribution is allowed with attribution). It's the only PDF exempt from `*.pdf` in `.gitignore`, and the CI guard requires every demo PDF to be listed with its license in `scripts/demo-files/README.md`. Runs in CI and in the Ubuntu container test |
| **AWS EC2 as a deployment choice** (README *Deploying on AWS EC2*) | Requested for products already on AWS. CPU-only instances: `t3.large` (2/8 GiB, ~$60.74/month, 1-worker settings, burstable credits), **`c6i.xlarge`** (4/8 GiB, ~$124.10/month, the shipped configuration, recommended), `c6i.2xlarge` (8/16 GiB, ~$248.20/month, 4 workers). Presented as deployment options with settings, **not** as a validated environment: the measured figures come from the M2 and the Ubuntu containers |
| **Production security on AWS** (README) | Requested: **never open port 5001** in security groups. docling-serve has no authentication, and Docker-published ports bypass `ufw`, so the security group is the real boundary. Only SSH (admin IP or Session Manager) is inbound; SSH tunnel for API access; SFTP or S3 with an IAM role for uploads; encrypted EBS. The setup script prints the reminder. **Enforced in configuration:** `docker-compose.yml` now publishes `127.0.0.1:5001:5001` (loopback only), so a misconfigured security group can't expose the service. Checked by acceptance check **A25** and by `demo_run.sh`, and re-validated in both Ubuntu containers (test containers still reach it through Docker Desktop's `host.docker.internal`) |
| **Fixed compose project name** (`name: docling-batch-extract`) | A checkout in any folder (`/opt/textextract`, a test container) manages the same container instead of failing on a name clash |
| **`DOCLING_URL`** (setup health check, `extract.py --url` default, tests) | Lets the service be reached where it isn't on `localhost`, e.g. from a container (`http://host.docker.internal:5001`) |
| **`setup_ubuntu.sh` installs `cron` and only uses `systemctl` when systemd is running** | Minimal Ubuntu images have no `crontab`; containers and WSL have no systemd |
| **`prompts.md`** | Rebuild prompts with these decisions built in, plus prompts for operating, investigating and extending the solution |

## New expectations

| ID | Expectation | Where it's met |
|----|-------------|----------------|
| E16 | No client data anywhere in the repository | `.gitignore`; repository search before release |
| E17 | Releasable as MIT open source | `LICENSE`, README |
| E18 | Reproducible with Claude, including the reasoning behind decisions | `prompts.md` + `versions/` |
| E19 | Tests and benchmarks are repeatable by anyone | `tests/` + `tests/results/` |

## Acceptance

- `tests/run_acceptance.sh --quick`: all 17 checks pass (results in `tests/results/`).
- `tests/run_acceptance.sh --bench-only`: A4 and A17 checks per benchmark PDF.
- Release check: `grep -rniE '<client file name or parties>' .` (excluding `.venv`) returns nothing, and `git status` shows no PDFs, outputs or logs.

## Open questions for the next version

- **Mixed PDFs:** OCR is decided per document (≥ 50 % scanned pages). Mixed documents may need a per-page decision.
- **RAG output:** page markers or citations (`md_page_break_placeholder`) and pre-chunking with docling's hybrid chunker are not implemented yet; see `prompts.md` Part 4.
- **Scale-out** beyond one VM needs a way for workers to claim files from a shared `inputs/`.
