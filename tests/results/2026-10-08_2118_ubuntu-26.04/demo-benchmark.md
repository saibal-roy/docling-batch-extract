# Demo benchmark

| Machine | |
|---|---|
| OS | Ubuntu 26.04.1 LTS |
| CPU | aarch64 CPU (2 CPUs, 7.7 GB RAM) |
| Docker | 4 CPUs, 7.7 GB available; container limit 6.055GiB |

| PDF | Pages | Chunks | Scanned | OCR forced | Seconds | Sec/page | Markdown chars | Result |
|-----|-------|--------|---------|------------|---------|----------|----------------|--------|
| docling_paper.pdf | 9 | 2 | 11% | False | 54.5 | 6.06 | 35,896 | OK |

| Run | |
|---|---|
| Wall time | 57 s |
| Throughput | 568 pages/hour (6.33 s/page) |
| Time per 1,000 pages at this rate | 1.8 h |
| Peak container memory | 2.16 GiB of 6.055GiB |
| Container restarts during run | 0 |
| extract.py exit code | 0 (all converted) |

Note: the first conversion after the container starts includes ~20–45 s of pipeline
start-up, so a one-document demo understates steady-state throughput. A small demo is a
smoke test; size a batch with `tests/run_acceptance.sh --bench-only`.
