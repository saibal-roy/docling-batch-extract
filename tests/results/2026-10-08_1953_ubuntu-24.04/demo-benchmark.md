# Demo benchmark

| Machine | |
|---|---|
| OS | Ubuntu 24.04.5 LTS |
| CPU | - (4 CPUs, 7.7 GB RAM) |
| Docker | 4 CPUs, 7.7 GB available; container limit 6.348GiB |

| PDF | Pages | Chunks | Scanned | OCR forced | Seconds | Sec/page | Markdown chars | Result |
|-----|-------|--------|---------|------------|---------|----------|----------------|--------|
| docling_paper.pdf | 9 | 2 | 11% | False | 27.9 | 3.10 | 36,199 | OK |

| Run | |
|---|---|
| Wall time | 30 s |
| Throughput | 1,080 pages/hour (3.33 s/page) |
| Time per 1,000 pages at this rate | 0.9 h |
| Peak container memory | 2.71 GiB of 6.348GiB |
| Container restarts during run | 0 |
| extract.py exit code | 0 (all converted) |

Note: the first conversion after the container starts includes ~20–45 s of pipeline
start-up, so a one-document demo understates steady-state throughput. A small demo is a
smoke test; size a batch with `tests/run_acceptance.sh --bench-only`.
