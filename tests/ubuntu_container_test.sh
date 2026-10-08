#!/usr/bin/env bash
# Validate the solution end to end inside fresh Ubuntu containers on a local Docker host
# (e.g. Docker Desktop). This is the go-ahead test: everything an operator does on a new
# Ubuntu server, run as a non-root sudo user:
#   setup_ubuntu.sh → checks → setup again (idempotent) → smoke test (inputs/ → outputs/,
#   completed/, errors/) → cleanup.sh → demo_run.sh → tests/run_acceptance.sh --quick
#
# Usage: tests/ubuntu_container_test.sh [ubuntu-version ...]     (default: 26.04, the latest LTS)
#
# Simulates the 2 vCPU / 8 GB target: the Ubuntu container is pinned to 2 CPUs (so setup sizes .env for
# 2 vCPU) and the docling container is capped at 2 CPUs; the Docker Desktop VM provides ~8 GB.
#
# The Ubuntu container talks to the host's Docker daemon through the mounted socket, so the
# docling container it starts (and restarts/stops during the acceptance checks) is the host's.
# systemd isn't available in a container, so setup_ubuntu.sh skips enabling services.
# Results: tests/results/<timestamp>_ubuntu-<version>/ (steps.log + the acceptance summary).
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
VERSIONS=("$@"); [ ${#VERSIONS[@]} -gt 0 ] || VERSIONS=(26.04)
OVERALL=0

# summary.md for the results folder (picked up by the site's Validation page).
write_summary() {
  local out=$1 ver=$2 rc=$3
  {
    echo "# Ubuntu $ver container validation ($(basename "$out" | cut -d_ -f1-2))"
    echo
    echo "**Result: $([ "$rc" -eq 0 ] && echo PASS || echo "FAIL (rc=$rc)")**. Fresh \`ubuntu:$ver\` container on Docker Desktop simulating the **2 vCPU / 8 GB** target (2 CPUs for the server and for docling), run as a non-root sudo user against the host's Docker daemon."
    echo
    echo "## Steps"
    echo
    grep -E "^######## " "$out/steps.log" | sed -E 's/^######## ([0-9]+)\. /- **\1.** /; s/^######## /- /'
    for f in demo-benchmark.md acceptance-summary.md; do
      [ -f "$out/$f" ] || continue
      echo
      sed -E '1s/^# /## /; 2,$s/^## /### /' "$out/$f"
    done
  } >"$out/summary.md"
}

# Steps run inside each container. Passed as an argument, not on stdin: a command inside a step
# that reads stdin would otherwise swallow the remaining steps.
INNER=$(cat <<'STEPS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
step() { printf '\n######## %s\n' "$*"; }

step "Prepare: sudo user 'ops', copy of the repository (no local venv, data or tool settings)"
apt-get update -qq && apt-get install -yqq sudo >/dev/null
useradd -m -s /bin/bash ops
echo 'ops ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ops
usermod -aG "$(stat -c %G /var/run/docker.sock)" ops   # access to the host's Docker socket
mkdir -p /opt/app
tar -C /src --exclude=./.venv --exclude=./.env --exclude=./.claude --exclude=./tests/results --exclude=./tests/work -cf - . | tar -C /opt/app -xf -
chown -R ops /opt/app
# stdin from /dev/null: nothing inside a step may read (and consume) input
as_ops() { su - ops -c "cd /opt/app && export DOCLING_URL=$DOCLING_URL && set -euo pipefail && $1" </dev/null; }

step "1. setup_ubuntu.sh"
as_ops "scripts/setup_ubuntu.sh --cron-minutes 5"

step "1b. Target machine: cap the docling container at 2 CPUs (2 vCPU / 8 GB simulation)"
docker update --cpus 2 docling_ocr_worker_cpu >/dev/null
echo "nproc in this server: $(nproc) · docling container CPU limit: $(docker inspect -f '{{.HostConfig.NanoCpus}}' docling_ocr_worker_cpu | awk '{print $1/1e9}')"

step "2. Setup results"
as_ops 'cat .env && grep -q "^DOCLING_WORKERS=" .env && echo ".env sized for $(nproc) CPUs"
        curl -sf "$DOCLING_URL/health" && echo
        test -x .venv/bin/python && echo "venv ok"
        for d in inputs outputs completed errors logs; do test -d "$d" && test -f "$d/.gitignore"; done && echo "folders ok"
        crontab -l | grep "# docling-batch-extract"'

step "3. Setup is safe to run again (one cron entry)"
as_ops 'scripts/setup_ubuntu.sh --cron-minutes 5 >/dev/null
        test "$(crontab -l | grep -c "# docling-batch-extract")" -eq 1 && echo "one cron entry"
        crontab -l | grep -v "# docling-batch-extract" | crontab - || true'

step "4. Smoke test: inputs/ → outputs/ + completed/, corrupt PDF → errors/"
as_ops '.venv/bin/pip install -q -r tests/requirements.txt
        .venv/bin/python tests/make_test_pdfs.py /tmp/pdfs >/dev/null
        cp /tmp/pdfs/small_a.pdf /tmp/pdfs/bad.pdf inputs/
        rc=0; .venv/bin/python extract.py || rc=$?
        test "$rc" -eq 1 && echo "exit code 1 as expected"
        test -f outputs/small_a.json && test -f completed/small_a.pdf && test -f errors/bad.pdf && echo "files routed ok"
        .venv/bin/python -c "import json; d = json.load(open(\"outputs/small_a.json\")); assert d[\"pages\"] == 3 and d[\"markdown\"].strip(); print(\"json ok\")"'

step "5. cleanup.sh"
as_ops 'scripts/cleanup.sh --dry-run
        scripts/cleanup.sh --inputs -y
        for d in inputs outputs completed errors logs; do test -f "$d/.gitignore" && test -z "$(find "$d" -mindepth 1 ! -name .gitignore)"; done
        echo "cleanup ok: folders empty, .gitignore kept"'

step "6. First demo run (scripts/demo_run.sh)"
as_ops 'scripts/demo_run.sh --clean-after'
cp /opt/app/logs/demo-benchmark-*.md /out/demo-benchmark.md

step "7. Acceptance checks"
as_ops 'tests/run_acceptance.sh --quick'
cp /opt/app/tests/results/*/summary.md /out/acceptance-summary.md

step "ALL STEPS PASSED"
STEPS
)

for ver in "${VERSIONS[@]}"; do
  OUT=$ROOT/tests/results/$(date +%Y-%m-%d_%H%M)_ubuntu-$ver
  mkdir -p "$OUT"
  echo "=== Ubuntu $ver → $OUT"
  set +e
  docker run --rm --name "docling-batch-extract-test-$ver" --cpuset-cpus 0-1 \
    -v "$ROOT":/src:ro -v "$OUT":/out -v /var/run/docker.sock:/var/run/docker.sock \
    -e DOCLING_URL=http://host.docker.internal:5001 \
    "ubuntu:$ver" bash -c "$INNER" >"$OUT/steps.log" 2>&1 </dev/null
  rc=$?
  set -e
  # Only a log that reached the final marker counts as a pass (guards against a silent no-op).
  grep -q "^######## ALL STEPS PASSED" "$OUT/steps.log" || { [ $rc -ne 0 ] || rc=99; }
  (cd "$ROOT" && docker compose up -d --force-recreate >/dev/null 2>&1) || true   # drop the simulation cap and .env
  write_summary "$OUT" "$ver" "$rc"
  if [ $rc -eq 0 ]; then echo "    PASS (log: $OUT/steps.log)"; else echo "    FAIL rc=$rc (log: $OUT/steps.log)"; OVERALL=1; tail -20 "$OUT/steps.log"; fi
  [ -f "$OUT/acceptance-summary.md" ] && grep -E "passed|FAIL" "$OUT/acceptance-summary.md" | tail -3
done
exit $OVERALL
