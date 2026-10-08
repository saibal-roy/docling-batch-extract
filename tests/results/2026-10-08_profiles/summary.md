# Server profile benchmarks

Same batch each run: text 15 + 60 pages, simulated scan 20 pages (95 pages), after a warm-up job. CPU limit applied with `docker update --cpus` on the docling container (Apple M2 host, Docker Desktop).

Peak = process memory (cgroup `anon`), excluding reclaimable file cache. *At limit* = times the container reached its memory limit (cache reclaimed); *OOM kills* = processes killed for lack of memory.

| Profile | CPUs | Workers×threads | Memory limit | Image | Batch s | s/page | Text 60p s | Scan 20p s | Peak GiB | Throttles | Restarts | At limit | OOM kills | Result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2cpu-2w-1t-v1.30.0 | 2 | 2×1 | 6500M | v1.30.0 | 343.7 | 3.62 | 189.0 | 124.0 | 3.30 | 0 | 0 | 0 | 0 | OK |
| 2cpu-2w-1t-v1.36.0 | 2 | 2×1 | 6500M | v1.36.0 | 445.6 | 4.69 | 270.0 | 130.1 | 3.41 | 0 | 0 | 0 | 0 | OK |
| 2cpu-1w-2t-v1.36.0 | 2 | 1×2 | 6500M | v1.36.0 | 436.3 | 4.59 | 275.7 | 93.9 | 2.76 | 0 | 0 | 0 | 0 | OK |
