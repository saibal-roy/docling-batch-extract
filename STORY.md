# How this was built: from requirements to a tested open-source release in one day with Claude

*By [Saibal Roy](https://www.saibalroy.com/) ([LinkedIn](https://www.linkedin.com/in/roysaibal) · [GitHub](https://github.com/saibal-roy)), working with Claude Code.*

## The problem

Document-heavy work in **legal tech and claims insurance** needed thousands of pages (petitions, affidavits, court records, claim forms, assessment reports, many of them scanned) turned into Markdown for a **RAG search system**. The obvious tools were cloud OCR (AWS Textract) or vision-LLM APIs, but they were too expensive for a pilot of **~500 documents × ~47 pages (~23,500 pages)**. The documents are also confidential.

The requirement was a **cost-effective batch pipeline on one small CPU-only server** (validated on **2 vCPU / 8 GB**, no GPU) that runs unattended, never stops on a bad file, and leaves an audit trail for every document.

The aim from the start was more than a one-off script for one engagement: to turn a real production requirement into a **reusable open-source business solution**, cost-effective and reliable enough for another team to deploy, with the reasoning published alongside the code.

## The approach: Claude as the engineering manager

**Saibal Roy** set the requirements, made every trade-off decision (platform, target machine, engine version, what to publish) and owns the result. **Claude Code** did the planning, building, measuring and documenting, working the way an engineering manager would, so the process can be repeated by any team:

1. **Turn requests into numbered requirements** (E1, E2, …) before writing any code.
2. **Write a versioned plan** (`versions/plan-vN.md`) with **acceptance criteria** (A1, A2, …) linked to each requirement, and the defaults it chose so they can be challenged.
3. **Verify, don't assume.** Check the real API of the pinned docling-serve version, and test on a **real client document** early.
4. **When reality disagrees with the plan, write a new plan version** explaining what changed and why, with evidence.
5. **Make every check repeatable:** a test suite, benchmarks, CI, and documentation built from measured numbers only.

The developer brought in new requirements as the work went on. Each one became a new requirement ID and plan version rather than an ad-hoc change. This is what lets several teams work from the same playbook: the plan files show *what* was decided, *why*, and *how it's checked*.

## Timeline (2026-10-08, one session)

| Time | Phase | What happened |
|------|-------|---------------|
| 15:53 | **Start** | Repository has one file: a `docker-compose.yml` for docling-serve. `/init` creates `CLAUDE.md` |
| 16:00 | **Requirements and ideation** | First idea: "a minimal Python script; PDFs from `input/`, parallel processing, Markdown into JSON in `outputs/`." Claude proposes a design and asks the one question that matters ("one at a time" *and* "parallel"?) |
| 16:04 | Plan v1 | 8 requirements, 10 acceptance checks |
| 16:09 | Plan v2 | + move processed PDFs to `completed/`. Spotted a hidden bug in the v1 design (same-name files would be silently skipped) and redesigned it |
| 16:15 | Plan v3 | + monitoring log, page-range splitting, memory-aware concurrency → 21 checks |
| 16:16 | **Build** | Container pull starts. The developer asks for **6–7 GB, CPU only**: Claude finds the Docker VM only has 7.6 GB anyway and switches to the smaller CPU-only image |
| 16:37 | API verified | Every endpoint and option checked against the live `/docs`; `page_range` confirmed |
| 16:38 | **First real run fails** | A real scanned document crashes the container (out of memory), and timeouts trigger duplicate submissions |
| 16:40–17:07 | **Root cause** | Polling fixed (busy ≠ dead). Measuring one job at a time showed **a single page used 6.35 GB** with docling's default PDF reader (JBIG2-compressed scans). Switching to `pypdfium2`: **19 s, 2.6 GB** |
| 17:11 | First clean run | All files converted; corrupt file goes to `errors/`; one log per PDF (both new requirements from the developer during the build) |
| 17:16 | Quality fix | The scanner's text layer runs words together. docling's own OCR is cleaner **and faster**, so OCR is now forced automatically on scans |
| 17:17–17:40 | **Verification** | Full acceptance runs, container-restart recovery, server-down handling. Plan v4 records the evidence |
| 17:40–18:30 | **Benchmarks and a test suite** | `tests/` with generated PDFs (including a simulated scan, so no client data is needed). Benchmarks show that **splitting scans raises peak memory**, so scans are converted whole. Run-to-run noise (~35 %) is documented honestly, including a failed check |
| 17:46–18:30 | **Open-source prep** | Client file names and text removed, `.gitignore` for all data, MIT license, README with server spec and cost comparison, `prompts.md`, plan v5 |
| 18:54 | **Operations** | `setup_ubuntu.sh` (trial-run in an Ubuntu container) and `cleanup.sh` (tested on a temporary copy) |
| 19:00 | **CI** | GitHub Actions: lint, data guard, and the setup script + acceptance suite on real Ubuntu 22.04 and 24.04 runners |
| 19:06 | Landing-page plan and this story | |
| 19:10 | **Go-ahead criterion set** | The developer decides the release gate: the tests must pass in Ubuntu containers on Docker Desktop. No cloud pilot is claimed. `input/` is renamed to `inputs/` |
| 19:13 | **Testing the test** | The first container harness "passed" without running anything (no stdin attached); the second was cut short by a step that swallowed stdin. Both were caught by a rule added on the spot: a run passes only if its log reaches a final marker line |
| 19:18 | First demo run | `scripts/demo_run.sh` with a public CC BY 4.0 paper as the demo file: environment checks, then a benchmark for the machine it runs on |
| 19:20–19:45 | **Go-ahead: PASS** | Ubuntu 24.04 and 22.04 containers each pass setup → setup again → smoke test → cleanup → demo → 17 acceptance checks |
| 19:25–19:45 | **Landing page** | MkDocs site built from the repository's own Markdown; GitHub Pages simulated locally (nginx under the project subpath, link crawl, Lighthouse: accessibility 100, performance 92–100) |
| 19:45–20:20 | **Hardening and release discipline** | Port 5001 bound to loopback only (check A25) and AWS security guidance; GitHub Pages readiness check; semantic versioning (0.1.0, `extractor_version` + `engine` in every JSON, CHANGELOG, Release workflow); CPU-only "pinned and gated" maintenance policy |
| 20:20–21:15 | **Sizing for cost: 2 vCPU / 8 GB** | Policies set by the developer: latest LTS / latest stable everywhere, Ubuntu 26.04 only, 2 vCPU / 8 GB target. `tests/profile_benchmark.sh` compared docling v1.30.0 and v1.36.0 and 1 × 2 against 2 × 1 at 2 vCPU. Found the "memory at the limit" readings were file cache (real peak 2.8–3.4 GiB). The developer chose v1.36.0 with 1 × 2 (faster scans, slower text) |
| 21:18–21:50 | **Final gate: PASS** | Ubuntu 26.04 LTS on the simulated 2 vCPU / 8 GB machine: all steps, 18/18 checks |

**Total: about 6 hours of elapsed time** (15:53 → ~21:50) in one session. That includes the release gate, the landing page, security hardening, versioning and the 2 vCPU sizing study. Roughly 2.5 hours of it was the computer running tests, benchmarks and image downloads. The first tested, documented solution took about 3 h 15 min.

### Where the time went

The times above come from the session itself. About **2.5 hours of the ~6 hours were machine time** (tests, benchmarks, image downloads), measured from the test and benchmark runs. How the rest split between planning, coding, investigating and writing wasn't tracked, so it isn't given here.

## What testing on real data and real limits caught

| Problem | How it was caught | Cost if missed |
|---------|-------------------|----------------|
| docling's default PDF reader exhausts memory on JBIG2 scans | Measuring one page at a time with `measure_job.py` | Container crash loop on the real pilot |
| Poll timeouts resent jobs, doubling the load | Reading the first failing run's log | Out-of-memory crashes under load |
| Scanner text layers garble words | Reading the actual Markdown output | Poor RAG retrieval quality, discovered weeks later |
| Splitting scans raises peak memory | 4-mode benchmark | Throttling and slower batches |
| Benchmark noise of ~35 % on a laptop | Repeating runs | Wrong default chosen from one lucky run |
| Same-name files silently skipped | Reviewing the plan-v2 design | Missing documents in the index |
| Client file names in docs and local tool settings | A search before release + `.gitignore` | Confidential data published |

## System thinking behind the solution

This is how Saibal builds open source: from real production requirements to reusable solutions, with the systems thinking as part of the deliverable. The engineering followed a few business-first principles (also written up as reusable prompts in [prompts.md](prompts.md)):

| Principle | How it shows up |
|-----------|-----------------|
| **Start from the unit economics** | The question was cost per page and confidentiality, not "which OCR is best". So: CPU-only, self-hosted, and sized down to **2 vCPU / 8 GB** after measuring. The pilot works out at roughly $3–11 of compute against $35–353 on a cloud OCR API |
| **Evidence before decisions; the owner decides trade-offs** | Engineering produced the numbers: docling v1.30.0 against v1.36.0, 1 × 2 against 2 × 1, real memory against cache. The owner chose (v1.36.0 for scan-heavy legal and claims work). Every choice is recorded in a plan version with its evidence |
| **Design for the maintainer you actually have** | A part-time maintainer gets one supported OS (latest LTS), exact version pins, upgrades only through the gate, scripts for setup, demo, cleanup and preview, and CI that rehearses a real server setup |
| **Secure by default, not by documentation** | The API is bound to loopback (enforced by a check), there are no stored cloud keys, client documents never leave the machine, and a CI data guard plus `.gitignore` keep client files out of the public repository |
| **A contract for the downstream system** | The RAG index depends on the JSON, so the versioning contract is defined around it, and every output records which extractor and engine versions produced it |
| **Grow in stages, each with a trigger** | One small server today → several identical small servers → a shared document queue in Amazon S3 through **S3 Files** (NFS), so storage scales with the archive instead of with pre-sized EBS volumes. That last step is written up as a [proposal](versions/proposal-s3-files-inputs.md): options compared, risks, a cost model to build, and the conditions under which it's worth the added complexity |

## Playbook for other teams

1. Start with `prompts.md` Part 1. The improved prompts already include every decision above, so a rebuild skips the dead ends.
2. Keep the `versions/` habit: **one plan file per change, with requirement IDs, acceptance checks and evidence.**
3. Test on one **real** document within the first hour. Every serious problem here came from real data, not from the design.
4. Treat benchmarks with suspicion: repeat runs, record the hardware, publish failures.
5. Make client-data protection mechanical (`.gitignore` + CI data guard), not a matter of memory.

## Go-ahead validation: Ubuntu containers on Docker Desktop

**Criterion (set by the developer):** the solution goes ahead if the full operator workflow passes in fresh Ubuntu containers on Docker Desktop. `tests/ubuntu_container_test.sh` runs it in each container, as a non-root sudo user, against the host's Docker daemon.

**Result: PASS on both versions** (2026-10-08, first round: docling v1.30.0, 4 CPUs).

| Step | Ubuntu 24.04 | Ubuntu 22.04 |
|------|--------------|--------------|
| 1. `setup_ubuntu.sh` (Docker from the official apt repo, venv, container, cron) | PASS | PASS |
| 2. Setup results (health, venv, folders, cron entry) | PASS | PASS |
| 3. Setup run again: still one cron entry | PASS | PASS |
| 4. Smoke test: good PDF → `outputs/` + `completed/`, corrupt PDF → `errors/`, exit code 1 | PASS | PASS |
| 5. `cleanup.sh`: folders emptied, `.gitignore` kept | PASS | PASS |
| 6. `demo_run.sh` (9-page demo PDF) | PASS: 27.3 s, 3.03 s/page, peak 2.78 GiB | PASS: 33.6 s, 3.73 s/page, peak 2.44 GiB |
| 7. Acceptance checks | **17 / 17** | **17 / 17** |
| Full acceptance batch (103 pages) | 2.18 s/page, peak 3.3 GiB, 0 restarts | 3.25 s/page, peak 3.2 GiB, 0 restarts |

Both containers ran on the same Apple M2 (Docker VM: 4 CPUs, 7.7 GB). The 22.04 run shared the CPU with site builds and Lighthouse runs, which explains its slower times; it isn't a difference between Ubuntu versions. Full logs: `tests/results/*_ubuntu-*/`.

### Final gate: Ubuntu 26.04 LTS on the 2 vCPU / 8 GB target

The developer then narrowed the platform to **the latest Ubuntu LTS only (26.04)**, set the target machine to **2 vCPU / 8 GB** for cost, and chose **docling v1.36.0** (latest stable) after seeing the benchmark trade-off. The gate was re-run on a simulated target: the Ubuntu container pinned to 2 CPUs, docling capped at 2 CPUs, about 8 GB of RAM.

| Step | Ubuntu 26.04 LTS · 2 vCPU / 8 GB |
|------|-----------------------------------|
| 1. `setup_ubuntu.sh`: Docker from the 26.04 ("resolute") repository; `.env` sized to 1 worker × 2 threads | PASS |
| 2–3. Setup results; setup run again, still one cron entry | PASS |
| 4–5. Smoke test; cleanup | PASS |
| 6. `demo_run.sh` (9-page demo PDF) | PASS: 54.5 s, 6.06 s/page, peak 2.16 GiB, Python 3.14.4 |
| 7. Acceptance checks (now including A25: port on loopback only) | **18 / 18** |
| Full acceptance batch (103 pages) | 4.47 s/page, peak process memory 2.8 GiB, 0 restarts |

**Not claimed:** no run on a cloud VM (for example AWS EC2) has been made. The README lists EC2 instances as deployment choices (`m7i.large` for batches, `t3.large` for small ones); run `scripts/demo_run.sh` on the chosen instance for its own benchmark.
