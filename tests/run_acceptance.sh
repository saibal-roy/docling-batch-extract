#!/usr/bin/env bash
# Acceptance tests and benchmarks for extract.py (criteria from versions/plan-v4.md).
#
# Usage: tests/run_acceptance.sh [--quick | --bench-only]
#   --quick       checks only; skip the benchmarks (A4, A16/A17), which take about 20 minutes
#   --bench-only  benchmarks only
#
# Runs in an isolated tests/work/ directory, so the real inputs/, outputs/, completed/,
# errors/ and logs/ folders are never touched. Requires the docling container to be
# running (docker compose up -d). Any PDFs in tests/fixtures/ (e.g. real scans) are
# added to the full run and the benchmarks.
#
# Note: A21 restarts the container and A10 stops and starts it again.
# Results: tests/results/<timestamp>/summary.md plus every run's console output.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
PY=${PY:-$ROOT/.venv/bin/python}
CONTAINER=docling_ocr_worker_cpu
MODE=${1:-}
STAMP=$(date +%Y-%m-%d_%H%M)
RES=$ROOT/tests/results/$STAMP
WORK=$ROOT/tests/work
PDFS=$WORK/pdfs
mkdir -p "$RES"
SUMMARY=$RES/summary.md
PASS=0; FAIL=0

say() { echo "$*" | tee -a "$SUMMARY"; }
check() {  # check <id> <description> <condition-command...>
  local id=$1 desc=$2; shift 2
  if "$@" >/dev/null 2>&1; then say "| $id | PASS | $desc |"; PASS=$((PASS + 1))
  else say "| $id | **FAIL** | $desc |"; FAIL=$((FAIL + 1)); fi
}
export DOCLING_URL=${DOCLING_URL:-http://localhost:5001}   # extract.py reads it too
healthy() { until curl -sf -m 3 "$DOCLING_URL/health" >/dev/null; do sleep 2; done; }
restarts() { docker inspect -f '{{.RestartCount}}' $CONTAINER; }
fresh() { rm -rf "$WORK/run"; mkdir -p "$WORK/run/inputs"; }
run() {  # run <name> [extract.py options...]; sets $RC and $OUT
  local name=$1; shift
  OUT=$RES/$name.console
  (cd "$WORK/run" && "$PY" "$ROOT/extract.py" "$@" >"$OUT" 2>&1); RC=$?
}
count() { ls "$WORK/run/$1" 2>/dev/null | wc -l | tr -d ' '; }
peak_mem() { grep -oE 'mem=[0-9.]+/' "$1" | tr -d 'mem=/' | sort -n | tail -1; }
doc_secs() { grep -E "\[$2\] DOC_DONE" "$1" | grep -oE 'secs=[0-9.]+' | head -1 | cut -d= -f2; }
md_chars() { "$PY" -c "import json,sys; print(len(json.load(open(sys.argv[1]))['markdown']))" "$1"; }

say "# Acceptance run $STAMP"
say ""
say "Host: $(uname -sm) · Docker VM: $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes') · container limit: $(docker stats --no-stream --format '{{.MemUsage}}' $CONTAINER | cut -d/ -f2)"
say ""
healthy
rm -rf "$WORK"; mkdir -p "$PDFS"
"$PY" "$ROOT/tests/make_test_pdfs.py" "$PDFS" >/dev/null
cp "$ROOT"/tests/fixtures/*.pdf "$PDFS/" 2>/dev/null
GOOD=0
BENCH_PDFS=(large.pdf scanned.pdf)   # plus any fixtures
for f in "$PDFS"/*.pdf; do
  name=$(basename "$f")
  [ "$name" = bad.pdf ] || GOOD=$((GOOD + 1))
  case $name in bad.pdf|small_a.pdf|small_b.pdf|medium.pdf|large.pdf|scanned.pdf) ;; *) BENCH_PDFS+=("$name") ;; esac
done

checks_header() { say ""; say "| ID | Result | Check |"; say "|----|--------|-------|"; }

if [ "$MODE" != "--bench-only" ]; then
say "## Checks"
checks_header

# --- Static checks -------------------------------------------------------------
check A1 "single file, about 450 lines or fewer, third-party imports are only requests + pypdf" \
  bash -c "[ \$(wc -l < extract.py) -le 450 ] && ! grep -E '^(import|from) ' extract.py | grep -vE '^(import|from) (argparse|json|logging|os|re|subprocess|sys|threading|time|collections|concurrent|datetime|pathlib|requests|pypdf)\b'"
check A6 "only read-only docker commands (stats, inspect) in extract.py" \
  bash -c "! grep -oE '\"docker\", \"[a-z]+\"' extract.py | grep -vE '\"(stats|inspect)\"'"
check A25 "docling-serve published on loopback only (127.0.0.1:5001), never on the network" \
  bash -c "p=\$(docker port $CONTAINER 5001/tcp); [ -n \"\$p\" ] && ! echo \"\$p\" | grep -qvE '^127\.0\.0\.1:'"

# --- Full run --------------------------------------------------------------------
fresh; cp "$PDFS"/*.pdf "$WORK/run/inputs/"; healthy; R0=$(restarts)
run full --heartbeat 10
R1=$(restarts)
check A2 "full run: one JSON per good PDF in outputs/ ($GOOD expected)" test "$(count outputs)" -eq "$GOOD"
check A9 "corrupt bad.pdf → DOC_FAILED, others succeed, exit code 1" \
  bash -c "[ $RC -eq 1 ] && grep -q 'DOC_FAILED  doc=bad.pdf' '$OUT' && grep -q 'ok=$GOOD failed=1' '$OUT'"
check A11 "inputs/ empty, good PDFs in completed/" bash -c "[ $(count inputs) -eq 0 ] && [ $(count completed) -eq $GOOD ]"
check A12 "bad.pdf moved to errors/" test -f "$WORK/run/errors/bad.pdf"
check A13 "every PDF in completed/ has outputs/<stem>.json" \
  bash -c "cd '$WORK/run' && for f in completed/*.pdf; do s=\$(basename \"\$f\" .pdf); [ -f \"outputs/\$s.json\" ] || exit 1; done"
check A7 "every JSON is valid, matches the schema (incl. extractor and engine versions), pages = real page count" \
  "$PY" - "$WORK/run" <<'EOF'
import json, sys
from pathlib import Path
from pypdf import PdfReader
run = Path(sys.argv[1])
keys = {"source_file", "status", "pages", "chunks", "force_ocr", "extractor_version", "engine", "markdown",
        "processing_time", "errors", "converted_at"}
for j in (run / "outputs").glob("*.json"):
    d = json.load(open(j))
    assert set(d) == keys, (j, set(d) ^ keys)
    assert d["pages"] == len(PdfReader(run / "completed" / d["source_file"]).pages), j
    assert d["markdown"].strip(), j
    assert d["extractor_version"] and d["engine"]["docling_serve"] and d["engine"]["pdf_backend"], j
EOF
check A14 "one log per PDF, each containing only its own document's lines" \
  bash -c "[ $(count logs) -eq $(ls "$PDFS" | wc -l) ] && cd '$WORK/run/logs' && for f in *.log; do s=\${f%.log}; grep -q \"DOC_START   doc=\$s.pdf\|DOC_FAILED  doc=\$s.pdf\" \"\$f\" || exit 1; [ -z \"\$(grep -oE 'doc=[^ ]+' \"\$f\" | grep -v \"doc=\$s.pdf\")\" ] || exit 1; done"
check A15 "PROGRESS lines logged while converting" grep -q PROGRESS "$OUT"
check A22 "no container restart during the full run (restarts $R0 → $R1)" test "$R0" = "$R1"
check A23 "OCR forced only on the scanned PDF(s)" \
  bash -c "grep -q 'doc=scanned.pdf.*force_ocr=True' '$OUT' && ! grep -E 'doc=(small_a|small_b|medium|large).pdf.*force_ocr=True' '$OUT'"
FULL_OUT=$OUT; FULL_PEAK=$(peak_mem "$OUT")

# --- Rerun with nothing to do -----------------------------------------------------
run empty
check A8 "rerun with empty inputs/: nothing processed, exit code 0" bash -c "[ $RC -eq 0 ] && grep -q 'files=0' '$OUT'"

# --- Memory throttle -------------------------------------------------------------------
fresh; cp "$PDFS"/{small_a,small_b,medium}.pdf "$WORK/run/inputs/"; healthy
run throttle --mem-high 0.01   # 1 % of any limit is below docling's idle memory, so it always throttles
check A19 "--mem-high 0.01 (below idle memory on any limit): THROTTLE logged and the run still completes" \
  bash -c "[ $RC -eq 0 ] && grep -q 'THROTTLE    on' '$OUT' && [ $(count completed) -eq 3 ]"

# --- Memory monitor unavailable ----------------------------------------------------------
fresh; cp "$PDFS/small_a.pdf" "$WORK/run/inputs/"
run nomonitor --container doesnotexist
check A20 "memory monitor unavailable: warning logged, run completes" \
  bash -c "[ $RC -eq 0 ] && grep -q 'memory monitoring unavailable' '$OUT'"

# --- Container restart mid-run ------------------------------------------------------------
fresh; cp "$PDFS"/{medium,small_b}.pdf "$WORK/run/inputs/"; healthy
(sleep 12; docker restart $CONTAINER >/dev/null) &
run restart
wait
check A21 "container restarted mid-run: chunks resent, all PDFs completed" \
  bash -c "[ $RC -eq 0 ] && grep -q RETRY '$OUT' && [ $(count completed) -eq 2 ]"

# --- Server down -------------------------------------------------------------------------------
fresh; cp "$PDFS/small_a.pdf" "$WORK/run/inputs/"
docker stop $CONTAINER >/dev/null
run serverdown
docker start $CONTAINER >/dev/null
check A10 "server down: exit code 2, PDF stays in inputs/" bash -c "[ $RC -eq 2 ] && [ -f '$WORK/run/inputs/small_a.pdf' ]"
healthy
say ""
say "Full run: $(grep RUN_END "$FULL_OUT" | sed -E 's/^[^ ]+ RUN_END +//') · peak container memory ${FULL_PEAK} GiB"
fi

# --- Benchmarks ------------------------------------------------------------------------------------
per_page() { awk -v s="$1" -v p="$2" 'BEGIN { if (s != "") printf "%.2f", s / p }'; }
within_5pct() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a > 0 && b > 0 && d / b <= 0.05) }'; }
faster() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && b != "" && a + 0 < b + 0) }'; }

if [ "$MODE" != "--quick" ]; then
  # Warm up so the first benchmark doesn't pay the pipeline start-up cost.
  fresh; cp "$PDFS/small_a.pdf" "$WORK/run/inputs/"; healthy; run warmup
  say ""
  say "## Benchmarks (each PDF converted alone, after a warm-up job)"
  say ""
  say "| PDF | Pages | Mode | Seconds | Sec/page | Peak memory (GiB) | Throttle pauses | Markdown chars |"
  say "|-----|-------|------|---------|----------|-------------------|-----------------|----------------|"
  BENCH_CHECKS=()
  for pdf in "${BENCH_PDFS[@]}"; do
    stem=${pdf%.pdf}
    pages=$("$PY" -c "import sys; from pypdf import PdfReader; print(len(PdfReader(sys.argv[1]).pages))" "$PDFS/$pdf")
    for mode in "split-5:--chunk-pages 5 --scanned-chunk-pages 5" "whole:--chunk-pages 0 --scanned-chunk-pages 0" \
                "default:" "1-at-a-time:--max-inflight 1 --chunk-pages 5 --scanned-chunk-pages 5"; do
      label=${mode%%:*}; opts=${mode#*:}
      fresh; cp "$PDFS/$pdf" "$WORK/run/inputs/"; healthy
      run "bench_${stem}_$label" --heartbeat 10 $opts
      secs=$(doc_secs "$OUT" "$stem")
      chars=$(md_chars "$WORK/run/outputs/$stem.json" 2>/dev/null || echo 0)
      case $label in
        split-5) S_SPLIT=$secs; C_SPLIT=$chars ;;
        whole) C_WHOLE=$chars ;;
        1-at-a-time) S_ONE=$secs ;;
      esac
      say "| $pdf | $pages | $label | ${secs:-FAILED} | $(per_page "$secs" "$pages") | $(peak_mem "$OUT") | $(grep -c 'THROTTLE    on' "$OUT") | $chars |"
    done
    BENCH_CHECKS+=("A17-$stem|split and whole outputs differ by no more than 5 % in length|within_5pct $C_SPLIT $C_WHOLE")
    BENCH_CHECKS+=("A4-$stem|2 ranges in parallel faster than 1 at a time ($S_SPLIT s vs $S_ONE s)|faster $S_SPLIT $S_ONE")
  done
  say ""
  say "Modes: **split-5** = 5-page ranges, 2 at once · **whole** = one job per PDF · **default** = split text PDFs, scans whole · **1-at-a-time** = 5-page ranges with --max-inflight 1"
  say ""
  say "### Benchmark checks"
  checks_header
  for c in "${BENCH_CHECKS[@]}"; do
    IFS='|' read -r id desc cmd <<<"$c"
    check "$id" "$desc" $cmd
  done
fi

say ""
say "**$PASS passed, $FAIL failed.**"
rm -rf "$WORK"
exit $((FAIL > 0))
