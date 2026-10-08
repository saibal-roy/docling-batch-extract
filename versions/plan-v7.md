# Plan v7 — 2 vCPU / 8 GB target, latest LTS only, latest stable dependencies

**Status:** Implemented; validated by the Ubuntu 26.04 go-ahead gate on the simulated 2 vCPU / 8 GB machine (see `tests/results/*_ubuntu-26.04/`). Supersedes [plan-v6.md](plan-v6.md).
**Date:** 2026-10-08

## Changes from v6

| Change | Reason / evidence |
|--------|-------------------|
| **Validated target: 2 vCPU / 8 GB RAM**, the only size validated | Requested for cost efficiency (for example EC2 `t3.large`, ~$60.74/month). Larger machines are auto-sized by setup but **not validated** |
| **Default: 1 worker × 2 threads**, 6.5 GB container limit | Benchmarked at 2 vCPU on a 95-page batch (`tests/profile_benchmark.sh`, results in `tests/results/2026-10-08_profiles/`). With v1.36.0, 1 × 2 converts scans fastest (94–103 s for 20 pages, against 130–139 s with 2 × 1) at similar overall speed (436–516 s against 446–476 s) |
| **docling-serve-cpu v1.30.0 → v1.36.0** (latest stable CPU release) | Maintainer's choice under the "latest stable" policy, made after seeing the trade-off. v1.36.0 is **~20–25 % faster on scanned PDFs** (most legal and claims records) and **~45–80 % slower on text PDFs** than v1.30.0 at 2 vCPU. The best v1.30.0 setting (2 × 1) was ~25 % faster on the mixed batch (344 s). The text regression is recorded so later docling releases can be checked against it |
| **Memory: no change needed** | Process memory (cgroup `anon`) peaked at **2.8–3.4 GiB of 6.5 GiB**, never reached the limit, no OOM kills. The earlier "6.35 GiB peaks" were reclaimable file cache counted by `docker stats`, so the benchmark now measures `anon` |
| **Sizing from `.env`** (`DOCLING_WORKERS`, `DOCLING_THREADS`, `DOCLING_MEMORY`, `DOCLING_TAG`). `setup_ubuntu.sh` writes it from the machine's CPUs and RAM (`--resize` to recompute); `.env.example` documents it | One repository fits the target and larger machines without editing `docker-compose.yml` |
| **`extract.py --max-inflight` defaults to the container's worker count** (read with `docker inspect`) | Client and server concurrency can't drift apart |
| **Only the latest Ubuntu LTS: 26.04** ("resolute"; `ubuntu:latest` = 26.04.1 LTS). `setup_ubuntu.sh` refuses other releases without `--force`; CI and the gate run on 26.04 only | Requested: "only support the latest LTS". One supported platform is cheaper to maintain part-time |
| **Latest stable, pinned dependencies:** `requests==2.34.2`, `pypdf==6.19.0`, `reportlab==5.0.1`, `ruff==0.16.10`, MkDocs 1.6.1 + Material 9.7.7 (MkDocs 1.x stays: 2.0 drops plugins), GitHub Actions `checkout@v7`, `setup-python@v7`, `upload-artifact@v7`, `upload-pages-artifact@v5`, `deploy-pages@v5`, `nginx:stable-alpine` | Requested: "latest LTS versions only" for every package. Few have LTS lines, so the rule is: latest LTS where one exists, otherwise the latest stable, **always pinned**, upgraded through the gate |
| **Go-ahead gate simulates the target:** Ubuntu container pinned to 2 CPUs (`--cpuset-cpus 0-1`, so setup writes the 2 vCPU `.env`), docling capped at 2 CPUs; the gate checks `.env` | The gate must validate the machine the solution is sold on |
| **`tests/profile_benchmark.sh`** | Re-measure any profile or docling release on the same batch: time, process memory, limit events, OOM kills |
| **User site in its own repository folder** (`../saibal-roy.github.io`); `preview_site.sh` serves both addresses | Requested: the user site is pushed from a separate folder |

## Acceptance

- `tests/ubuntu_container_test.sh` (default 26.04) passes all steps: setup with 2 vCPU sizing → checks → setup again → smoke test → cleanup → demo → 18 acceptance checks, on the simulated 2 vCPU / 8 GB machine.
- `scripts/preview_site.sh` crawls both addresses with no broken links.
