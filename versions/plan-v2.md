# Plan v2 — PDF → Markdown extraction via docling-serve

**Status:** Superseded by [plan-v3.md](plan-v3.md). Supersedes [plan-v1.md](plan-v1.md).
**Date:** 2026-10-08

## Changes from v1

- **New expectation E9:** after a PDF is processed, it is moved from `input/` to `completed/`.
- **Resumability now comes from the folders.** `input/` is the work queue: anything still in it gets processed. The v1 rule "skip if `outputs/<stem>.json` exists" is removed. With files moved out, that rule would silently skip a new PDF that has the same name as an earlier one.
- Acceptance criterion A8 is rewritten, and A11–A13 are added.

## 1. Expectations (as stated)

> Create a minimal python script to take the pdf files from input folder first one at a time and do parallel processing and then extract the markdown version using docling docker container that can be kept running and store the markdown content in json file in the outputs folder.
>
> Also include after the processing is done move the completed processed documents from the input folder to completed folder.

| ID | Expectation |
|----|-------------|
| E1 | A **minimal** Python script |
| E2 | Reads **PDF files from an `input/` folder** |
| E3 | Each PDF is handled **one at a time** (one file per conversion request) |
| E4 | Files are processed **in parallel** |
| E5 | Markdown is extracted using the **docling Docker container** |
| E6 | The container **stays running** between runs (the script does not start/stop it) |
| E7 | Markdown content is **stored in JSON** |
| E8 | JSON is written to the **`outputs/` folder** |
| E9 | After processing, the PDF is **moved from `input/` to `completed/`** |

**Interpretation of E3 + E4:** each PDF is submitted as its own request (never batched), and up to N such requests run concurrently.

**Interpretation of E9:** each PDF is moved as soon as *its own* JSON has been written, not after the whole batch finishes. If the script is interrupted, the files already finished are out of `input/` and won't be converted again. Only successful conversions are moved. Failed PDFs stay in `input/` so they are retried on the next run.

## 2. Design

### Layout
```
input/             # PDFs waiting to be converted (the queue)
completed/         # PDFs that converted successfully
outputs/           # one <pdf-stem>.json per converted PDF
extract.py         # the script
requirements.txt   # requests
docker-compose.yml # existing docling-serve service
```

### Flow
1. **Health check:** `GET {url}/health`. Exit with a clear message if the container is unreachable. The script never runs `docker` commands (E6).
2. **Discover:** glob `input/*.pdf` (E2), sorted. Create `outputs/` and `completed/` if they are missing.
3. **Parallelise:** `ThreadPoolExecutor(max_workers=--workers)` with default **3**, matching `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` in `docker-compose.yml` (E4). Each task handles exactly one PDF (E3).
4. **Convert one PDF** (E5), using the async API so long CPU OCR jobs don't hit the sync timeout (~120 s default):
   1. `POST /v1/convert/file/async` with multipart `files=<pdf>` and `to_formats=md` → `task_id`
   2. Poll `GET /v1/status/poll/{task_id}` until `success` or `failure`
   3. `GET /v1/result/{task_id}` → `document.md_content`
5. **Write** `outputs/<stem>.json` (E7, E8): write to `<stem>.json.tmp`, then `os.replace` to the final name so no partial file is left behind.
6. **Move** (E9), only after step 5 succeeds: `os.replace(input/<name>, completed/<name>)`.
7. **Errors:** a failed PDF is logged, gets no JSON, and stays in `input/`. The other files continue. The script prints a final summary `N ok, M failed` and exits non-zero if M > 0.

### Ordering guarantees
- The JSON is always written **before** the PDF is moved. A PDF in `completed/` therefore always has its JSON in `outputs/`.
- If the script dies between writing the JSON and moving the PDF, the PDF is still in `input/`. The next run converts it again and overwrites the JSON. That costs time but loses nothing.

### Name collisions
If `completed/<name>` or `outputs/<stem>.json` already exists (a re-submitted file with the same name), it is **overwritten** and the latest run wins. The PDF and its JSON stay consistent.

### Output schema
```json
{
  "source_file": "report.pdf",
  "status": "success",
  "markdown": "# Title\n...",
  "processing_time": 42.1,
  "errors": [],
  "converted_at": "2026-10-08T16:20:00Z"
}
```

### CLI
| Flag | Default |
|------|---------|
| `--input` | `input` |
| `--output` | `outputs` |
| `--completed` | `completed` |
| `--workers` | `3` |
| `--url` | `http://localhost:5001` |

### Minimalism constraints (E1)
- Single file, standard library plus `requests` only.
- No classes or config files. Target is about 150 lines or fewer.

## 3. Pre-implementation check

Endpoint paths above are from the docling-serve v1 API and were **not** verified against the pinned `v1.30.0` image, because the container was not running when this plan was written. Before coding:

```bash
docker compose up -d
open http://localhost:5001/docs   # confirm /v1/convert/file/async, /v1/status/poll/{id}, /v1/result/{id}, /health
```

Write a new version of this plan if any path or response field differs.

## 4. Acceptance criteria

The plan is achieved when every check below passes.

| ID | Covers | Check | Pass condition |
|----|--------|-------|----------------|
| A1 | E1 | `wc -l extract.py`; inspect imports | One file, about 150 lines or fewer, deps are stdlib + `requests` only |
| A2 | E2, E8 | Put 3 PDFs in `input/`, run `python extract.py` | Exactly 3 files appear in `outputs/`, named `<stem>.json` |
| A3 | E3 | Inspect code / server logs | Each request carries exactly one PDF |
| A4 | E4 | Run with 3+ PDFs; compare wall time vs `--workers 1` | Logs show overlapping jobs; `--workers 3` finishes noticeably faster |
| A5 | E5 | Open any output JSON | `markdown` holds the document text as Markdown (headings/tables preserved) |
| A6 | E6 | `docker ps` before and after a run | Container is still running after the script exits; script contains no `docker` calls |
| A7 | E7 | `python -c "import json; json.load(open('outputs/<stem>.json'))"` | Valid JSON matching the schema in §2 |
| A8 | Resumability | Run the script a second time with `input/` now empty | Reports 0 files to process; sends no conversion requests |
| A9 | Error handling | Add a corrupt `bad.pdf`; run | Other PDFs succeed; `bad.pdf` has no JSON; summary shows `1 failed`; exit code is non-zero |
| A10 | Health check | `docker compose stop`; run | Script exits immediately with a "service unreachable" message; nothing is moved |
| A11 | E9 | After the A2 run, `ls input completed` | `input/` is empty; all 3 PDFs are in `completed/` |
| A12 | E9 (failures) | After the A9 run, `ls input completed` | `bad.pdf` is still in `input/`; the good PDFs are in `completed/` |
| A13 | E9 (ordering) | For every file in `completed/` | A matching `outputs/<stem>.json` exists |

## 5. Defaults chosen (change in a later version if needed)

- **One JSON per PDF** rather than one combined file. This avoids concurrent writes.
- **Move per file, as each finishes**, rather than once at the end of the batch.
- **Overwrite on name collision** in `completed/` and `outputs/`.
- **OCR left on** (docling default). Set `do_ocr=false` if the PDFs already contain a text layer, which is much faster.
