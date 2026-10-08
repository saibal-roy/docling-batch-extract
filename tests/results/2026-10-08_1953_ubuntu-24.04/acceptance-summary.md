# Acceptance run 2026-10-08_1427

Host: Linux aarch64 · Docker VM: 4 CPUs, 8215646208 bytes · container limit:  6.348GiB

## Checks

| ID | Result | Check |
|----|--------|-------|
| A1 | PASS | single file, about 400 lines or fewer, third-party imports are only requests + pypdf |
| A6 | PASS | only read-only docker commands (stats, inspect) in extract.py |
| A25 | PASS | docling-serve published on loopback only (127.0.0.1:5001), never on the network |
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

Full run: ok=5 failed=1 pages=103 secs=243.1 sec_per_page=2.36 restarts=0 · peak container memory 3.2 GiB

**18 passed, 0 failed.**
