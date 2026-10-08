#!/usr/bin/env bash
# First demo run on a newly deployed machine: check the environment, convert the demo PDF(s)
# from scripts/demo-files/ with the real extract.py, and report a benchmark for this machine.
#
# Usage: scripts/demo_run.sh [--clean-after]
#   --clean-after   remove the demo's outputs, completed PDFs and logs afterwards
#
# Steps:
#   1. Environment checks: OS, CPUs, RAM, disk, Docker daemon, docling container, its memory
#      limit, /health, Python venv and packages, data folders. Hard failures stop the demo.
#   2. Copy the demo PDF(s) into inputs/ (refuses if inputs/ already holds other PDFs).
#   3. Run extract.py while sampling container memory.
#   4. Print the benchmark (also saved as logs/demo-benchmark-<timestamp>.md).
#
# DOCLING_URL (default http://localhost:5001) overrides the service address.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
DEMO_DIR=$ROOT/scripts/demo-files
CONTAINER=docling_ocr_worker_cpu
export DOCLING_URL=${DOCLING_URL:-http://localhost:5001}
PY=$ROOT/.venv/bin/python
CLEAN_AFTER=0
case ${1:-} in
  --clean-after) CLEAN_AFTER=1 ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

FAILS=0; WARNS=0
ok()   { printf '  [ OK ]  %s\n' "$*"; }
warn() { printf '  [WARN]  %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  [FAIL]  %s\n' "$*"; FAILS=$((FAILS + 1)); }
header() { printf '\n== %s\n' "$*"; }

# --- 1. Environment checks -----------------------------------------------------------------
header "1. Environment checks"
OS=$(uname -s)
if [ "$OS" = Linux ] && [ -f /etc/os-release ]; then . /etc/os-release; OS_NAME=$PRETTY_NAME
elif [ "$OS" = Darwin ]; then OS_NAME="macOS $(sw_vers -productVersion)"
else OS_NAME=$OS; fi
ok "OS: $OS_NAME ($(uname -m))"

if [ "$OS" = Darwin ]; then
  CPU_MODEL=$(sysctl -n machdep.cpu.brand_string); CPUS=$(sysctl -n hw.ncpu)
  RAM_GB=$(awk -v b="$(sysctl -n hw.memsize)" 'BEGIN { printf "%.1f", b / 2^30 }')
else
  CPU_MODEL=$(awk -F': ' '/model name|^Model/ { print $2; exit }' /proc/cpuinfo); CPUS=$(nproc)
  [ -n "$CPU_MODEL" ] || CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/Model name/ && $2 != "-" { print $2; exit }')
  [ -n "$CPU_MODEL" ] || CPU_MODEL="$(uname -m) CPU"
  RAM_GB=$(awk '/MemTotal/ { printf "%.1f", $2 / 2^20 }' /proc/meminfo)
fi
DISK_GB=$(df -k "$ROOT" | awk 'NR == 2 { printf "%d", $4 / 2^20 }')
ok "Host: ${CPU_MODEL:-unknown CPU}, $CPUS CPUs, ${RAM_GB} GB RAM, ${DISK_GB} GB free disk"

if ! command -v docker >/dev/null; then fail "docker CLI not found (run scripts/setup_ubuntu.sh)"
elif ! docker info >/dev/null 2>&1; then fail "Docker daemon not reachable (is Docker running? are you in the docker group?)"
else
  read -r D_CPUS D_MEM <<<"$(docker info --format '{{.NCPU}} {{.MemTotal}}')"
  D_MEM_GB=$(awk -v b="$D_MEM" 'BEGIN { printf "%.1f", b / 2^30 }')
  ok "Docker: $(docker version --format '{{.Server.Version}}'), $D_CPUS CPUs, ${D_MEM_GB} GB available to containers"
  [ "$D_CPUS" -ge 4 ] || warn "fewer than 4 CPUs available to Docker: expect slower conversions"
  awk -v m="$D_MEM_GB" 'BEGIN { exit !(m < 7) }' && warn "less than 7 GB available to Docker: the 6.5 GB container may run out of memory"
fi
[ "$DISK_GB" -ge 10 ] || warn "less than 10 GB free disk"

STATE=$(docker inspect -f '{{.State.Status}}' $CONTAINER 2>/dev/null || echo missing)
if [ "$STATE" = running ]; then
  MEM_LIMIT=$(docker stats --no-stream --format '{{.MemUsage}}' $CONTAINER | awk -F' / ' '{ print $2 }')
  RESTARTS_BEFORE=$(docker inspect -f '{{.RestartCount}}' $CONTAINER)
  ok "Container $CONTAINER running (memory limit $MEM_LIMIT, restarts so far $RESTARTS_BEFORE)"
  PUBLISHED=$(docker port $CONTAINER 5001/tcp 2>/dev/null | paste -sd' ' -)
  if [ -n "$PUBLISHED" ] && ! echo "$PUBLISHED" | tr ' ' '\n' | grep -vE '^$|^127\.0\.0\.1:' >/dev/null; then
    ok "Port 5001 published on loopback only ($PUBLISHED)"
  else
    fail "Port 5001 is published beyond loopback ($PUBLISHED): the API has no authentication. Use \"127.0.0.1:5001:5001\" in docker-compose.yml"
  fi
else
  fail "Container $CONTAINER is $STATE (start it: docker compose up -d)"
fi
if curl -sf -m 5 "$DOCLING_URL/health" >/dev/null; then ok "Service healthy at $DOCLING_URL"
else fail "Service not answering at $DOCLING_URL/health"; fi

if [ -x "$PY" ] && "$PY" -c "import requests, pypdf" 2>/dev/null; then
  ok "Python venv: $("$PY" --version), requests + pypdf installed"
else fail "Python venv missing or incomplete (python3 -m venv .venv && .venv/bin/pip install -r requirements.txt)"; fi

for d in inputs outputs completed errors logs; do
  mkdir -p "$d" 2>/dev/null
  [ -w "$d" ] || fail "folder $d/ is not writable"
done
ok "Data folders present and writable"

DEMO_PDFS=("$DEMO_DIR"/*.pdf)
if [ ! -f "${DEMO_PDFS[0]}" ]; then fail "no demo PDFs in scripts/demo-files/"; fi
EXISTING=$(find inputs -maxdepth 1 -name '*.pdf' | wc -l | tr -d ' ')
[ "$EXISTING" -eq 0 ] || fail "inputs/ already holds $EXISTING PDF(s); move them out first so the demo measures only the demo files"

if [ $FAILS -gt 0 ]; then
  printf '\n%d check(s) failed: fix them and run the demo again.\n' "$FAILS"; exit 1
fi
printf '\nAll checks passed (%d warning(s)).\n' "$WARNS"

# --- 2. Copy the demo files -----------------------------------------------------------------
header "2. Demo input"
STEMS=()
for f in "${DEMO_PDFS[@]}"; do
  cp "$f" inputs/
  STEMS+=("$(basename "$f" .pdf)")
  echo "  copied $(basename "$f") → inputs/"
done

# --- 3. Run the extractor ---------------------------------------------------------------------
header "3. Running extract.py"
MEMLOG=$(mktemp)
( while true; do docker stats --no-stream --format '{{.MemUsage}}' $CONTAINER >>"$MEMLOG" 2>/dev/null; sleep 2; done ) &
SAMPLER=$!
START=$(date +%s)
"$PY" extract.py --heartbeat 15
RC=$?
SECS=$(( $(date +%s) - START ))
kill $SAMPLER 2>/dev/null; wait $SAMPLER 2>/dev/null
RESTARTS_AFTER=$(docker inspect -f '{{.RestartCount}}' $CONTAINER 2>/dev/null || echo "?")

# --- 4. Benchmark -------------------------------------------------------------------------------
header "4. Benchmark"
REPORT=logs/demo-benchmark-$(date +%Y%m%d-%H%M%S).md
"$PY" - "$MEMLOG" "$RC" "$SECS" "$RESTARTS_BEFORE" "$RESTARTS_AFTER" \
  "$OS_NAME" "$CPU_MODEL" "$CPUS" "$RAM_GB" "${D_CPUS:-?}" "${D_MEM_GB:-?}" "${MEM_LIMIT:-?}" "${STEMS[@]}" >"$REPORT" <<'EOF'
import json, re, sys
from pathlib import Path
memlog, rc, secs, r0, r1, os_name, cpu, cpus, ram, dcpus, dmem, limit, *stems = sys.argv[1:]
units = {"B": 2**-30, "KiB": 2**-20, "MiB": 2**-10, "GiB": 1, "kB": 1e3 / 2**30, "MB": 1e6 / 2**30, "GB": 1e9 / 2**30}
peak = 0.0
for line in Path(memlog).read_text().splitlines():
    m = re.match(r"\s*([\d.]+)\s*([KMG]?i?B)", line)
    if m:
        peak = max(peak, float(m[1]) * units[m[2]])
rows, total_pages = [], 0
for stem in stems:
    log = Path("logs") / f"{stem}.log"
    text = log.read_text() if log.exists() else ""
    start = re.search(r"DOC_START .*?pages=(\d+) chunks=(\d+).*?scanned_pages=(\d+)% force_ocr=(\w+)", text)
    done = re.search(r"DOC_DONE .*?secs=([\d.]+) sec_per_page=([\d.]+)", text)
    out = Path("outputs") / f"{stem}.json"
    chars = len(json.loads(out.read_text())["markdown"]) if out.exists() else 0
    if start and done:
        total_pages += int(start[1])
        rows.append(f"| {stem}.pdf | {start[1]} | {start[2]} | {start[3]}% | {start[4]} | {done[1]} | {done[2]} | {chars:,} | OK |")
    else:
        failed = re.search(r'DOC_FAILED .*?reason="([^"]*)"', text)
        rows.append(f"| {stem}.pdf | {start[1] if start else '?'} | | | | | | | FAILED: {failed[1] if failed else 'see log'} |")
secs = int(secs)
pph = total_pages / secs * 3600 if secs and total_pages else 0
print(f"""# Demo benchmark

| Machine | |
|---|---|
| OS | {os_name} |
| CPU | {cpu} ({cpus} CPUs, {ram} GB RAM) |
| Docker | {dcpus} CPUs, {dmem} GB available; container limit {limit} |

| PDF | Pages | Chunks | Scanned | OCR forced | Seconds | Sec/page | Markdown chars | Result |
|-----|-------|--------|---------|------------|---------|----------|----------------|--------|
""" + "\n".join(rows) + f"""

| Run | |
|---|---|
| Wall time | {secs} s |
| Throughput | {pph:,.0f} pages/hour ({secs / total_pages if total_pages else 0:.2f} s/page) |
| Time per 1,000 pages at this rate | {1000 / pph if pph else 0:.1f} h |
| Peak container memory | {peak:.2f} GiB of {limit} |
| Container restarts during run | {int(r1) - int(r0) if r0.isdigit() and r1.isdigit() else '?'} |
| extract.py exit code | {rc} ({'all converted' if rc == '0' else 'see logs/'}) |

Note: the first conversion after the container starts includes ~20–45 s of pipeline
start-up, so a one-document demo understates steady-state throughput. A small demo is a
smoke test; size a batch with `tests/run_acceptance.sh --bench-only`.""")
EOF
cat "$REPORT"
rm -f "$MEMLOG"
echo
echo "Report saved: $REPORT"
if [ $CLEAN_AFTER -eq 1 ]; then
  for s in "${STEMS[@]}"; do rm -f "outputs/$s.json" "completed/$s.pdf" "errors/$s.pdf" "logs/$s.log"; done
  echo "Demo outputs removed (--clean-after); the report is kept."
else
  echo "Output:       outputs/${STEMS[0]}.json   (PDF moved to completed/)"
  echo "Remove the demo files later with: scripts/cleanup.sh"
fi
exit $RC
