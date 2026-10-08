# Plan v4: PDF → Markdown extraction via docling-serve (as implemented)

**Status:** Superseded by [plan-v5.md](plan-v5.md) (scanned PDFs no longer split; timeout per page). Supersedes [plan-v3.md](plan-v3.md).
**Date:** 2026-10-08

## Changes from v3

New requirements came up during implementation, and testing on real documents forced some design changes.

| Change | Reason |
|--------|--------|
| **E13 – one log per PDF** (`logs/<stem>.log`, replaced each time that PDF is processed) instead of one cumulative `logs/extract.log` | Requested: the log should cover the file being extracted |
| **E14 – failed PDFs move to `errors/`**, and the run continues | Requested. A server outage is the exception: the run stops and leaves the files in `input/` |
| **E15 – 6–7 GB RAM, CPU only** | Requested for cost. The container now uses the `docling-serve-cpu` image with a 6.5 GB limit and 2 workers × 2 threads |
| **`pdf_backend=pypdfium2`** instead of docling's default `docling_parse` | With `docling_parse`, a **single page** of the user's JBIG2-scanned PDF filled 6.35 GB in about 5 minutes and crashed the container. With `pypdfium2`, the same page took 19 s and peaked at 2.6 GB |
| **OCR is forced automatically on scanned PDFs** (`--ocr auto`) | The scanner's embedded text layer ran words together. docling's own OCR produced clean text and was faster (18 s compared with 35–47 s for 5 pages) |
| **`--chunk-pages` default lowered from 10 to 5** | Smaller jobs need less memory at their peak |
| **`--max-inflight` default lowered from 3 to 2** | Matches the 2 workers on the server |
| **`--mem-high` default lowered from 0.85 to 0.75** | The idle container with models loaded uses about 2.6 GB, and each job adds about 1 GB |
| **Status checks tolerate a busy server.** A timeout means "keep waiting". Pages are resent only if the container's restart count changed | In v3, timeouts caused duplicate submissions, which doubled the load and led to an out-of-memory crash |

## 1. Expectations

| ID | Expectation | Where it's met |
|----|-------------|----------------|
| E1 | Minimal Python script | One file, stdlib + `requests` + `pypdf` |
| E2 | Read PDFs from `input/` | `plan_docs()` |
| E3 | Documents are taken one at a time, in order | The chunk queue is ordered by document |
| E4 | Parallel processing | `ThreadPoolExecutor(--max-inflight)` |
| E5 | Conversion uses the docling container | `/v1/convert/file/async` |
| E6 | The container keeps running; the script never starts or stops it | Only `docker stats` and `docker inspect` are called |
| E7 | Markdown stored in JSON | `outputs/<stem>.json` |
| E8 | Output written to `outputs/` | `--output` |
| E9 | Finished PDF moves to `completed/` | `finish_doc()`, after the JSON is written |
| E10 | Monitoring: work in progress, time taken, page count | `SUBMIT`, `PROGRESS`, `CHUNK_DONE` and `DOC_DONE` lines |
| E11 | Page-range splitting when it helps | `--chunk-pages`, benchmarked in A16 |
| E12 | Concurrency limited by container memory | `MemoryMonitor` plus the `--mem-high` throttle |
| E13 | Log per extracted file, not cumulative | `doc_logger()` → `logs/<stem>.log` (mode `w`) |
| E14 | Failed PDFs move to `errors/`; other files continue | `fail_doc()` |
| E15 | Runs in 6–7 GB RAM, CPU only | `docker-compose.yml`: `docling-serve-cpu`, `memory: 6500M` |

## 2. Design summary

- **Input queue:** `input/*.pdf`, sorted. Each PDF's page count and scanned-page share are read with `pypdf`. A page counts as scanned if it holds an image at least as wide as the page.
- **Chunks:** `--chunk-pages` (default 5) consecutive pages each, sent with `page_range=[start, end]`, `pdf_backend=pypdfium2`, and `force_ocr=true` when at least 50% of the pages are scanned.
- **Dispatch:** at most `--max-inflight` (2) chunks run at once. While container memory is at or above `--mem-high` (75%), nothing new is submitted, unless nothing is running at all.
- **Per chunk:** submit → poll every 3 s (a timeout means the server is busy, so keep waiting) → fetch the result.
- **Container restart:** detected through `docker inspect` RestartCount or a 404 for a task the server no longer knows. The script waits up to 10 minutes for `/health`, then resends the chunk, up to `--retries` (2) times.
- **Success:** join the chunks' Markdown in page order → write `outputs/<stem>.json` (temp file, then rename) → move the PDF to `completed/`.
- **Document failure** (unreadable PDF, docling error, retries used up): move the PDF to `errors/`. The reason is in `logs/<stem>.log`.
- **Server failure** (no `/health` after a restart): `ABORTED` is logged, unfinished PDFs stay in `input/`, and the script exits with code 2.
- **Exit codes:** `0` all succeeded · `1` some PDFs moved to `errors/` · `2` server unreachable or down.

## 3. Acceptance criteria

The checks are the same as in v3, plus A22–A24 below. Results are recorded in the [README](../README.md#test-results).

| ID | Covers | Check | Pass condition |
|----|--------|-------|----------------|
| A9 | E14 | Corrupt `bad.pdf` in `input/` | Moved to `errors/`; `DOC_FAILED` in `logs/bad.log`; other PDFs succeed; exit code 1 |
| A12 | E14 | After A9 | `input/` is empty; `bad.pdf` is in `errors/` |
| A14 | E13 | `ls logs/` after a run | One `<stem>.log` per PDF, each containing only that PDF's lines |
| A22 | E15 | `docker inspect` restart count before and after the full run | Unchanged; memory stays under 6.5 GB |
| A23 | OCR auto | `DOC_START` line in each log | `force_ocr=True` only for the scanned PDF |
| A24 | Restart | `docker restart` mid-run (A21) | Chunks are resent; PDFs end up in `completed/` |
