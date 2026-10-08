# Server profile benchmarks

Same batch each run: text 15 + 60 pages, simulated scan 20 pages (95 pages), after a warm-up job. CPU limit applied with `docker update --cpus` on the docling container (Apple M2 host, Docker Desktop).

| Profile | CPUs | Workers×threads | Memory limit | Image | Batch s | s/page | Text 60p s | Scan 20p s | Peak GiB | Throttles | Restarts | Result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2cpu-1w-2t-v1.30.0 | 2 | 1×2 | 6500M | v1.30.0 | 428.3 | 4.51 | 178.9 | 131.7 | 6.35 | 0 | 0 | OK |
| 2cpu-1w-2t-v1.36.0 | 2 | 1×2 | 6500M | v1.36.0 | 516.5 | 5.44 | 340.6 | 103.2 | 6.35 | 0 | 0 | OK |
| 2cpu-2w-1t-v1.36.0 | 2 | 2×1 | 6500M | v1.36.0 | 476.0 | 5.01 | 291.4 | 139.2 | 6.35 | 0 | 0 | OK |

Notes: *Peak GiB* in this first table came from `docker stats`, which includes reclaimable file cache, so every run shows the 6.35 GiB limit; it is not process memory. A 4 vCPU run was discarded (the benchmark script was edited while it ran). Later runs measure process memory: see `summary.md`.
