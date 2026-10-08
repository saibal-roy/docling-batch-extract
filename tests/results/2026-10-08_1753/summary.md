# Acceptance run 2026-10-08_1753

Host: Darwin arm64 · Docker VM: 4 CPUs, 8215646208 bytes · container limit:  6.348GiB


## Benchmarks (each PDF converted alone, after a warm-up job)

| PDF | Pages | Mode | Seconds | Sec/page | Peak memory (GiB) | Throttle pauses | Markdown chars |
|-----|-------|------|---------|----------|-------------------|-----------------|----------------|
| large.pdf | 60 | split-5 | 197.1 | 3.28 | 2.6 | 0 | 37886 |
| large.pdf | 60 | whole | 169.3 | 2.82 | 2.4 | 0 | 37886 |
| large.pdf | 60 | default | 146.3 | 2.44 | 2.6 | 0 | 37886 |
| large.pdf | 60 | 1-at-a-time | 179.0 | 2.98 | 2.3 | 0 | 37886 |
| scanned.pdf | 20 | split-5 | 82.5 | 4.12 | 4.3 | 0 | 31568 |
| scanned.pdf | 20 | whole | 78.8 | 3.94 | 3.5 | 0 | 31568 |
| scanned.pdf | 20 | default | 69.6 | 3.48 | 3.6 | 0 | 31568 |
| scanned.pdf | 20 | 1-at-a-time | 88.2 | 4.41 | 3.6 | 0 | 31568 |

Modes: **split-5** = 5-page ranges, 2 at once · **whole** = one job per PDF · **default** = split text PDFs, scans whole · **1-at-a-time** = 5-page ranges with --max-inflight 1

### Benchmark checks

| ID | Result | Check |
|----|--------|-------|
| A17-large | PASS | split and whole outputs differ by no more than 5 % in length |
| A4-large | **FAIL** | 2 ranges in parallel faster than 1 at a time (197.1 s vs 179.0 s) |
| A17-scanned | PASS | split and whole outputs differ by no more than 5 % in length |
| A4-scanned | PASS | 2 ranges in parallel faster than 1 at a time (82.5 s vs 88.2 s) |

**3 passed, 1 failed.**
