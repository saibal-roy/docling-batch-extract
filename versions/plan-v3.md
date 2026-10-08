# Plan v3 — PDF → Markdown extraction via docling-serve

**Status:** Superseded by [plan-v4.md](plan-v4.md). Supersedes [plan-v2.md](plan-v2.md).
**Date:** 2026-10-08

## Changes from v2

- **E10 – Monitoring log:** a log file records what is in progress, how long each document takes, and its page count.
- **E11 – Page-range splitting:** large PDFs are split into page ranges that convert in parallel. The split is kept only if a benchmark shows it is faster (A16).
- **E12 – Memory-aware concurrency:** the number of jobs running at once is limited by the container's memory as well as its worker count.
- **The unit of work is now a chunk** (one PDF plus a page range), not a whole PDF. A document counts as done only when all of its chunks are done.
- **New dependency `pypdf`,** used to count pages before submitting. The line-count target rises to about 250.
- **E6 clarified:** the script may *read* container stats (`docker stats`, `docker inspect`). It still never starts, stops or restarts the container.
- Acceptance criteria A1 and A3 are updated, and A14–A21 are added.

## 1. Expectations (as stated)

> Create a minimal python script to take the pdf files from input folder first one at a time and do parallel processing and then extract the markdown version using docling docker container that can be kept running and store the markdown content in json file in the outputs folder.
>
> Also include after the processing is done move the completed processed documents from the input folder to completed folder.
>
> Also, maintain a log file for monitoring purpose with running in process and time taken for each process to complete with number of pages. If by breaking into page range the process can be optimized for each document then include that optimization as well. Also the script should be able to process multiple documents based on the docling container memory capacity to handle.

| ID | Expectation |
|----|-------------|
| E1 | A **minimal** Python script |
| E2 | Reads **PDF files from an `input/` folder** |
| E3 | Documents are taken **one at a time**, in order |
| E4 | Work is processed **in parallel** |
| E5 | Markdown is extracted using the **docling Docker container** |
| E6 | The container **stays running** between runs (the script never starts, stops or restarts it) |
| E7 | Markdown content is **stored in JSON** |
| E8 | JSON is written to the **`outputs/` folder** |
| E9 | After processing, the PDF is **moved from `input/` to `completed/`** |
| E10 | A **log file** shows what is **in progress**, plus **time taken** and **page count** for each document |
| E11 | Documents are **split into page ranges** when that makes processing faster |
| E12 | **Multiple documents** run at once, limited by the **container's memory capacity** |

**Interpretation of E3 + E4 + E11:** documents are queued in order, and each one becomes one or more chunks. Chunks go to the server in queue order, so the workers finish document 1 before most of document 2's chunks start. That's "one at a time" while every worker stays busy. A small document is a single chunk.

**Interpretation of E9:** a PDF is moved as soon as its own JSON is written. Only successful conversions are moved. Failed PDFs stay in `input/` and are retried on the next run.

**Interpretation of E12:** the server only converts `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` (3) jobs at a time, so that's the most worth having in flight. On top of that, the script holds back new submissions while the container's memory is near its limit, so it can't push the container into an out-of-memory restart.

## 2. Design

### Layout
```
input/             # PDFs waiting to be converted (the queue)
completed/         # PDFs that converted successfully
outputs/           # one <pdf-stem>.json per converted PDF
logs/extract.log   # monitoring log (appended across runs)
extract.py         # the script
requirements.txt   # requests, pypdf
docker-compose.yml # existing docling-serve service
```

### Flow
1. **Health check:** `GET {url}/health`. Exit with a clear message if the container is unreachable (E6).
2. **Discover and plan:** glob `input/*.pdf` (E2), sorted. Count the pages of each file with `pypdf`. A file that can't be opened is logged as failed and left in `input/`. Split each document into chunks (see *Page-range splitting*). Log the run plan: number of files, total pages, total chunks.
3. **Schedule** (E4, E12): chunks go into a single queue in document order (E3). A dispatcher submits the next chunk only when both of these hold:
   - fewer than `--max-inflight` chunks are running (default **3**, the server's worker count), and
   - container memory is below `--mem-high` (default **85 %** of the limit; see *Memory-aware concurrency*).
4. **Convert one chunk** (E5), using the async API so long CPU OCR jobs don't hit the sync timeout (~120 s default):
   1. `POST /v1/convert/file/async` with multipart `files=<pdf>`, `to_formats=md` and `page_range=[start, end]` → `task_id`
   2. Poll `GET /v1/status/poll/{task_id}` until `success` or `failure`
   3. `GET /v1/result/{task_id}` → `document.md_content`
5. **Assemble:** when all chunks of a document have finished, join their Markdown in page order with `\n\n`.
6. **Write** `outputs/<stem>.json` (E7, E8): write to `<stem>.json.tmp`, then `os.replace` to the final name.
7. **Move** (E9), only after step 6 succeeds: `os.replace(input/<name>, completed/<name>)`.
8. **Errors:** if any chunk fails after its retries, the whole document fails. It gets no JSON and stays in `input/`. The script cancels that document's remaining queued chunks, and the other documents continue. A final summary is printed and logged, and the exit code is non-zero if anything failed.

### Page-range splitting (E11)
- **Rule:** split when `pages > --chunk-pages` (default **10**). For example, 45 pages → chunks 1–10, 11–20, 21–30, 31–40, 41–45. `--chunk-pages 0` turns splitting off.
- **Why it can be faster:** docling-serve gives each job to one worker. A single 200-page PDF uses 1 of the 3 workers while the other 2 sit idle. Split into chunks, it uses all 3. Each chunk is also a shorter job, so it's less likely to time out, and it holds less of the document in memory.
- **Costs:**
  - The full PDF is uploaded once per chunk. This is cheap on localhost.
  - A table or list that crosses a chunk boundary comes out as two pieces.
  - There's a small per-request overhead.
- **Keep or drop:** acceptance check A16 benchmarks one large PDF with and without splitting. If splitting isn't measurably faster, set the default to `--chunk-pages 0` and record the result in a v4 plan.

### Memory-aware concurrency (E12)
- **Reading memory:** a background thread runs `docker stats --no-stream --format '{{.MemUsage}}' docling_ocr_worker_cpu` every 5 s and parses `used / limit` (e.g. `9.1GiB / 13GiB`).
- **Throttle:** while `used / limit ≥ --mem-high`, the dispatcher submits nothing new. Chunks already running continue. Each time throttling starts or stops, it's logged.
- **Fallback:** if `docker stats` isn't available (no Docker CLI, or the container name differs), the script logs one warning and runs on the `--max-inflight` limit alone.
- **Crash recovery:** the script records the container's restart count (`docker inspect -f '{{.RestartCount}}'`) at startup. If a poll or result call fails because of a lost connection or an unknown task, it checks the count again. If the container has restarted (for example after running out of memory), the script waits for `/health` and resubmits the lost chunks, up to `--retries` (default **2**) times each.
- **Sizing guidance:** the log records peak container memory for each chunk. If peaks stay well under 13 GiB, raise `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` in `docker-compose.yml` and `--max-inflight` together. If throttling happens often, lower `--chunk-pages`.

### Monitoring log (E10)
The log is written to `logs/extract.log` and echoed to the console. Each line is plain text in `key=value` form, which is easy to grep or `tail -f`.

```
2026-10-08T16:20:00 RUN_START   files=4 pages=212 chunks=24 max_inflight=3 chunk_pages=10
2026-10-08T16:20:01 SUBMIT      doc=report.pdf chunk=1/5 pages=1-10 task=ab12
2026-10-08T16:20:31 PROGRESS    running=[report.pdf#1(30s) report.pdf#2(29s) report.pdf#3(29s)] queued=21 done=0 mem=8.4/13.0GiB
2026-10-08T16:20:44 CHUNK_DONE  doc=report.pdf chunk=1/5 pages=10 secs=43.1 sec_per_page=4.31
2026-10-08T16:21:02 THROTTLE    on mem=11.2/13.0GiB
2026-10-08T16:22:10 DOC_DONE    doc=report.pdf pages=45 chunks=5 secs=129.7 sec_per_page=2.88 moved=completed/report.pdf
2026-10-08T16:22:10 DOC_FAILED  doc=bad.pdf reason="..." left_in=input/
2026-10-08T16:30:00 RUN_END     ok=3 failed=1 pages=212 secs=600.0 sec_per_page=2.83
```

- `PROGRESS` heartbeat every 30 s (`--heartbeat`): the chunks in progress with their elapsed time, how many chunks are queued and done, and current memory. This is the "what's running now" view.
- `secs` for a document is wall-clock time from its first chunk being submitted to its JSON being written.

### Output schema
```json
{
  "source_file": "report.pdf",
  "status": "success",
  "pages": 45,
  "chunks": 5,
  "markdown": "# Title\n...",
  "processing_time": 129.7,
  "errors": [],
  "converted_at": "2026-10-08T16:22:10Z"
}
```

### Name collisions
If `completed/<name>` or `outputs/<stem>.json` already exists, it is overwritten and the latest run wins.

### CLI
| Flag | Default |
|------|---------|
| `--input` | `input` |
| `--output` | `outputs` |
| `--completed` | `completed` |
| `--log` | `logs/extract.log` |
| `--url` | `http://localhost:5001` |
| `--max-inflight` | `3` |
| `--chunk-pages` | `10` (`0` = no splitting) |
| `--mem-high` | `0.85` |
| `--container` | `docling_ocr_worker_cpu` |
| `--retries` | `2` |
| `--heartbeat` | `30` (seconds) |

### Minimalism constraints (E1)
- A single file. Dependencies are the standard library, `requests` and `pypdf`.
- No classes beyond what's necessary and no config files. The target is about 250 lines.

## 3. Pre-implementation check

Endpoint paths and options above are from the docling-serve v1 API and were **not** verified against the pinned `v1.30.0` image, because the container was not running when this plan was written. Before coding:

```bash
docker compose up -d
open http://localhost:5001/docs
```

Confirm:
1. `/health`, `/v1/convert/file/async`, `/v1/status/poll/{id}` and `/v1/result/{id}` exist.
2. `page_range` is accepted on the file upload, along with its format and whether it's 1-based and inclusive. If it isn't supported, split the PDF on the client with `pypdf` and upload each chunk as its own file.
3. `docker stats` reports a limit of 13 GiB for `docling_ocr_worker_cpu`.

Write a new version of this plan if anything differs.

## 4. Acceptance criteria

The plan is achieved when every check below passes.

| ID | Covers | Check | Pass condition |
|----|--------|-------|----------------|
| A1 | E1 | `wc -l extract.py`; inspect imports | One file, about 250 lines or fewer, deps are stdlib + `requests` + `pypdf` only |
| A2 | E2, E8 | Put 3 PDFs in `input/`, run `python extract.py` | Exactly 3 files appear in `outputs/`, named `<stem>.json` |
| A3 | E3 | Inspect `SUBMIT` lines in the log | Chunks are submitted in document order; each request carries one PDF and one page range |
| A4 | E4 | Run with 3+ PDFs; compare wall time vs `--max-inflight 1` | `PROGRESS` shows up to 3 chunks running; the default finishes noticeably faster |
| A5 | E5 | Open any output JSON | `markdown` holds the document text as Markdown (headings/tables preserved) |
| A6 | E6 | `docker ps` before and after a run; grep the script for `docker` | Container still running; the only docker calls are `stats` and `inspect` |
| A7 | E7 | `python -c "import json; json.load(open('outputs/<stem>.json'))"` | Valid JSON matching the schema in §2, with `pages` equal to the PDF's real page count |
| A8 | Resumability | Run again with `input/` empty | Reports 0 files to process; sends no conversion requests |
| A9 | Error handling | Add a corrupt `bad.pdf`; run | Other PDFs succeed; `bad.pdf` has no JSON; `DOC_FAILED` is logged; exit code is non-zero |
| A10 | Health check | `docker compose stop`; run | Exits immediately with a "service unreachable" message; nothing is moved |
| A11 | E9 | After A2, `ls input completed` | `input/` is empty; all 3 PDFs are in `completed/` |
| A12 | E9 (failures) | After A9, `ls input completed` | `bad.pdf` is still in `input/`; good PDFs are in `completed/` |
| A13 | E9 (ordering) | For every file in `completed/` | A matching `outputs/<stem>.json` exists |
| A14 | E10 | Open `logs/extract.log` after a run | `RUN_START`, `DOC_DONE` (with `pages` and `secs`) for every success, and `RUN_END` are present |
| A15 | E10 (in progress) | `tail -f logs/extract.log` during a run with a large PDF | `PROGRESS` lines appear every ~30 s, listing running chunks with elapsed time |
| A16 | E11 (benchmark) | One PDF of 60+ pages: run with `--chunk-pages 10`, then `--chunk-pages 0` | The split run is measurably faster (compare `DOC_DONE secs`). If not, change the default to `0` and record the result in plan v4 |
| A17 | E11 (correctness) | Compare Markdown from the A16 runs | Same content in the same page order; length differs by no more than ~5 % |
| A18 | E12 (capacity) | Run with 5+ PDFs; check `docker inspect -f '{{.RestartCount}}'` before and after | Restart count unchanged; no out-of-memory restart |
| A19 | E12 (throttle) | Run with `--mem-high 0.3` | `THROTTLE on/off` is logged; submissions pause while it's on; the run still completes |
| A20 | E12 (fallback) | Run with `--container doesnotexist` | One warning is logged; the run completes using `--max-inflight` alone |
| A21 | E12 (recovery) | `docker restart docling_ocr_worker_cpu` during a run | Lost chunks are resubmitted after `/health` recovers; the documents still complete |

## 5. Defaults chosen (change in a later version if needed)

- **One JSON per PDF**, written once all of its chunks are done.
- **Move per file, as each finishes**, rather than once at the end of the batch.
- **Overwrite on name collision** in `completed/` and `outputs/`.
- **`--chunk-pages 10`** stays the default only if A16 shows it's faster.
- **`--max-inflight 3`**, matching the server's worker count. More in flight only queues jobs on the server.
- **OCR left on** (docling default). Set `do_ocr=false` if the PDFs already contain a text layer, which is much faster.
