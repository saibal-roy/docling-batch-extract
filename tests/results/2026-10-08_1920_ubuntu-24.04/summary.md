# Ubuntu 24.04 container validation (2026-10-08_1920)

**Result: PASS**. Fresh `ubuntu:24.04` container on Docker Desktop, run as a non-root sudo user against the host's Docker daemon.

## Steps

- Prepare: sudo user 'ops', copy of the repository (no local venv, data or tool settings)
- **1.** setup_ubuntu.sh
- **2.** Setup results
- **3.** Setup is safe to run again (one cron entry)
- **4.** Smoke test: inputs/ → outputs/ + completed/, corrupt PDF → errors/
- **5.** cleanup.sh
- **6.** First demo run (scripts/demo_run.sh)
- **7.** Acceptance checks
- ALL STEPS PASSED

## Demo benchmark

| Machine | |
|---|---|
| OS | Ubuntu 24.04.5 LTS |
| CPU |  (4 CPUs, 7.7 GB RAM) |
| Docker | 4 CPUs, 7.7 GB available; container limit 6.348GiB |

| PDF | Pages | Chunks | Scanned | OCR forced | Seconds | Sec/page | Markdown chars | Result |
|-----|-------|--------|---------|------------|---------|----------|----------------|--------|
| docling_paper.pdf | 9 | 2 | 11% | False | 27.3 | 3.03 | 36,199 | OK |

| Run | |
|---|---|
| Wall time | 29 s |
| Throughput | 1,117 pages/hour (3.22 s/page) |
| Time per 1,000 pages at this rate | 0.9 h |
| Peak container memory | 2.78 GiB of 6.348GiB |
| Container restarts during run | 0 |
| extract.py exit code | 0 (all converted) |

Note: the first conversion after the container starts includes ~20–45 s of pipeline
start-up, so a one-document demo understates steady-state throughput. A small demo is a
smoke test; size a batch with `tests/run_acceptance.sh --bench-only`.

## Acceptance run 2026-10-08_1353

Host: Linux aarch64 · Docker VM: 4 CPUs, 8215646208 bytes · container limit:  6.348GiB

### Checks

| ID | Result | Check |
|----|--------|-------|
| A1 | PASS | single file, about 400 lines or fewer, third-party imports are only requests + pypdf |
| A6 | PASS | only read-only docker commands (stats, inspect) in extract.py |
| A2 | PASS | full run: one JSON per good PDF in outputs/ (5 expected) |
| A9 | PASS | corrupt bad.pdf → DOC_FAILED, others succeed, exit code 1 |
| A11 | PASS | inputs/ empty, good PDFs in completed/ |
| A12 | PASS | bad.pdf moved to errors/ |
| A13 | PASS | every PDF in completed/ has outputs/<stem>.json |
| A7 | PASS | every JSON is valid, matches the schema, and pages = real page count |
| A14 | PASS | one log per PDF, each containing only its own document's lines |
| A15 | PASS | PROGRESS lines logged while converting |
| A22 | PASS | no container restart during the full run (restarts 0 → 0) |
| A23 | PASS | OCR forced only on the scanned PDF(s) |
| A8 | PASS | rerun with empty inputs/: nothing processed, exit code 0 |
| A19 | PASS | --mem-high 0.3: THROTTLE logged and the run still completes |
| A20 | PASS | memory monitor unavailable: warning logged, run completes |
| A21 | PASS | container restarted mid-run: chunks resent, all PDFs completed |
| A10 | PASS | server down: exit code 2, PDF stays in inputs/ |

Full run: ok=5 failed=1 pages=103 secs=224.7 sec_per_page=2.18 restarts=0 · peak container memory 3.3 GiB

**17 passed, 0 failed.**
