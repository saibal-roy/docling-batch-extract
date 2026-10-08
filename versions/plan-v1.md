# Plan v1 — PDF → Markdown extraction via docling-serve

**Status:** Superseded by [plan-v2.md](plan-v2.md)
**Date:** 2026-10-08

## 1. Expectations (as stated)

> Create a minimal python script to take the pdf files from input folder first one at a time and do parallel processing and then extract the markdown version using docling docker container that can be kept running and store the markdown content in json file in the outputs folder.

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

**Interpretation of E3 + E4:** each PDF is submitted as its own request (never batched), and up to N such requests run concurrently.

## 2. Design

### Layout
```
input/             # PDFs to convert
outputs/           # one <pdf-stem>.json per PDF
extract.py         # the script
requirements.txt   # requests
docker-compose.yml # existing docling-serve service
```

### Flow
1. **Health check:** `GET {url}/health`. Exit with a clear message if the container is unreachable. The script never runs `docker` commands (E6).
2. **Discover:** glob `input/*.pdf` (E2), sorted. Skip any PDF whose `outputs/<stem>.json` already exists, so runs are resumable and idempotent.
3. **Parallelise:** `ThreadPoolExecutor(max_workers=--workers)` with default **3**, matching `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` in `docker-compose.yml` (E4). Each task handles exactly one PDF (E3).
4. **Convert one PDF** (E5), using the async API so long CPU OCR jobs don't hit the sync timeout (~120 s default):
   1. `POST /v1/convert/file/async` with multipart `files=<pdf>` and `to_formats=md` → `task_id`
   2. Poll `GET /v1/status/poll/{task_id}` until `success` or `failure`
   3. `GET /v1/result/{task_id}` → `document.md_content`
5. **Write** `outputs/<stem>.json` (E7, E8): write to `<stem>.json.tmp`, then `os.replace` to the final name so no partial file is left behind.
6. **Errors:** a failed PDF is logged and gets no JSON (so the next run retries it). The other files continue. The script prints a final summary `N ok, M failed` and exits non-zero if M > 0.

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

Update this plan (as v2) if any path or response field differs.

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
| A8 | Resumability | Run the script a second time | All files reported as skipped; no new requests sent |
| A9 | Error handling | Add a corrupt `bad.pdf`; run | Other PDFs succeed; `bad.pdf` has no JSON; summary shows `1 failed`; exit code is non-zero |
| A10 | Health check | `docker compose stop`; run | Script exits immediately with a "service unreachable" message |

## 5. Defaults chosen (change in a later version if needed)

- **One JSON per PDF** rather than one combined file. This allows resuming and avoids concurrent writes.
- **OCR left on** (docling default). Set `do_ocr=false` if the PDFs already contain a text layer, which is much faster.
