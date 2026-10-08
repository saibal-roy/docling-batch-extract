#!/usr/bin/env bash
# Benchmark one server profile (CPU limit, workers, threads, memory, image) on a fixed batch,
# to size docling-serve for a target machine, e.g. 2 vCPU / 8 GB.
#
# Usage: tests/profile_benchmark.sh --cpus N --workers N --threads N [--memory 6500M] [--tag vX.Y.Z] [--label NAME]
#
# Recreates the docling container with those settings, limits it to N CPUs (docker update --cpus,
# simulating a smaller machine), warms it up, converts the same batch with the real extract.py
# (text 15 + 60 pages, simulated scan 20 pages) and appends one result row to
# tests/results/<date>_profiles/summary.md. The container is restored to docker-compose.yml's
# normal settings (no CPU limit) afterwards.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
PY=${PY:-$ROOT/.venv/bin/python}
CONTAINER=docling_ocr_worker_cpu
CPUS=""; WORKERS=""; THREADS=""; MEMORY=6500M; TAG=""; LABEL=""
while [ $# -gt 0 ]; do
  case $1 in
    --cpus) CPUS=$2 ;; --workers) WORKERS=$2 ;; --threads) THREADS=$2 ;;
    --memory) MEMORY=$2 ;; --tag) TAG=$2 ;; --label) LABEL=$2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift 2
done
[ -n "$CPUS" ] && [ -n "$WORKERS" ] && [ -n "$THREADS" ] || { echo "need --cpus, --workers and --threads" >&2; exit 2; }
LABEL=${LABEL:-${CPUS}cpu-${WORKERS}w-${THREADS}t${TAG:+-$TAG}}
OUTDIR=$ROOT/tests/results/$(date +%Y-%m-%d)_profiles
WORK=$ROOT/tests/work/profile-$LABEL
mkdir -p "$OUTDIR"; rm -rf "$WORK"; mkdir -p "$WORK/pdfs" "$WORK/run/inputs"
"$PY" tests/make_test_pdfs.py "$WORK/pdfs" >/dev/null

restore() { unset DOCLING_TAG; docker compose up -d --force-recreate >/dev/null 2>&1 || true; }
trap restore EXIT

echo "==> $LABEL: recreating container (workers=$WORKERS threads=$THREADS memory=$MEMORY${TAG:+ tag=$TAG}), CPU limit $CPUS"
[ -z "$TAG" ] || export DOCLING_TAG=$TAG
DOCLING_WORKERS=$WORKERS DOCLING_THREADS=$THREADS DOCLING_MEMORY=$MEMORY docker compose up -d --force-recreate >/dev/null
docker update --cpus "$CPUS" $CONTAINER >/dev/null
until curl -sf -m 3 localhost:5001/health >/dev/null; do sleep 2; done
IMAGE=$(docker inspect -f '{{.Config.Image}}' $CONTAINER)

echo "==> warm-up"
cp "$WORK/pdfs/small_a.pdf" "$WORK/run/inputs/"
(cd "$WORK/run" && "$PY" "$ROOT/extract.py" >/dev/null 2>&1) || true
rm -rf "$WORK/run"; mkdir -p "$WORK/run/inputs"

echo "==> batch: medium (15) + large (60, text) + scanned (20, OCR)"
cp "$WORK/pdfs"/{medium,large,scanned}.pdf "$WORK/run/inputs/"
R0=$(docker inspect -f '{{.RestartCount}}' $CONTAINER)
MEMLOG=$WORK/mem.log
# Process memory (cgroup "anon"), not docker stats: that also counts reclaimable file cache.
( while true; do docker exec $CONTAINER awk '/^anon /{print $2 "B"}' /sys/fs/cgroup/memory.stat >>"$MEMLOG" 2>/dev/null; sleep 2; done ) &
SAMPLER=$!
RC=0
(cd "$WORK/run" && "$PY" "$ROOT/extract.py" --heartbeat 30 >"$WORK/console.log" 2>&1) || RC=$?
kill $SAMPLER 2>/dev/null || true; wait $SAMPLER 2>/dev/null || true
R1=$(docker inspect -f '{{.RestartCount}}' $CONTAINER)
# Times the container reached its memory limit (kernel reclaimed cache) and processes killed for lack of memory.
EVENTS=$(docker exec $CONTAINER awk '/^max /{m=$2} /^oom_kill /{k=$2} END{print m+0 " " k+0}' /sys/fs/cgroup/memory.events 2>/dev/null || echo "? ?")

"$PY" - "$WORK" "$OUTDIR/summary.md" "$LABEL" "$CPUS" "$WORKERS" "$THREADS" "$MEMORY" "$IMAGE" "$RC" "$R0" "$R1" $EVENTS <<'PYEOF'
import re, sys
from pathlib import Path
work, summary, label, cpus, workers, threads, memory, image, rc, r0, r1, at_limit, oom_kills = sys.argv[1:]
console = Path(work, "console.log").read_text()
end = re.search(r"RUN_END\s+ok=(\d+) failed=(\d+) pages=(\d+) secs=([\d.]+) sec_per_page=([\d.]+)", console)
peak = max((int(m[1]) / 2**30 for m in re.finditer(r"(\d+)B", Path(work, "mem.log").read_text())), default=0)
docs = {m[1]: m[2] for m in re.finditer(r"\[(\w+)\] DOC_DONE .*?secs=([\d.]+)", console)}
throttles = console.count("THROTTLE    on")
row = (f"| {label} | {cpus} | {workers}×{threads} | {memory} | {image.split(':')[-1]} | "
       + (f"{end[4]} | {end[5]} | {docs.get('large','-')} | {docs.get('scanned','-')} | {peak:.2f} | {throttles} | {int(r1)-int(r0)} | "
          f"{at_limit} | {oom_kills} | {'OK' if rc == '0' else 'exit ' + rc} |" if end
          else f"- | - | - | - | {peak:.2f} | {throttles} | {int(r1)-int(r0)} | {at_limit} | {oom_kills} | FAILED (exit {rc}) |"))
p = Path(summary)
if not p.exists():
    p.write_text("# Server profile benchmarks\n\nSame batch each run: text 15 + 60 pages, simulated scan 20 pages (95 pages), after a warm-up job. "
                 "CPU limit applied with `docker update --cpus` on the docling container (Apple M2 host, Docker Desktop).\n\n"
                 "Peak = process memory (cgroup `anon`), excluding reclaimable file cache. *At limit* = times the container reached "
                 "its memory limit (cache reclaimed); *OOM kills* = processes killed for lack of memory.\n\n"
                 "| Profile | CPUs | Workers×threads | Memory limit | Image | Batch s | s/page | Text 60p s | Scan 20p s | Peak GiB | Throttles | Restarts | At limit | OOM kills | Result |\n"
                 "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n")
p.write_text(p.read_text() + row + "\n")
print(row)
PYEOF
rm -rf "$WORK"
