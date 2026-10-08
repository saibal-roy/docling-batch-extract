#!/usr/bin/env bash
# Remove generated artifacts.
#
# Usage: scripts/cleanup.sh [options]
#
#   (default)       outputs/ completed/ errors/ logs/ tests/work/ __pycache__/
#   --inputs        also inputs/ (PDFs that have NOT been processed yet)
#   --results       also tests/results/ (saved test and benchmark records)
#   --venv          also .venv/
#   --docker        also stop and remove the docling container (docker compose down)
#   --docker-image  also remove the docling image (~5 GB; next start downloads it again)
#   --all           all of the above
#   -n, --dry-run   show what would be removed, remove nothing
#   -y, --yes       don't ask for confirmation
#
# Folders are emptied but kept (with their .gitignore), so the extractor can run straight away.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/extract.py" ] || { echo "extract.py not found in $ROOT; refusing to clean" >&2; exit 1; }
cd "$ROOT"

EMPTY=(outputs completed errors logs)   # emptied, folder kept
REMOVE=(tests/work __pycache__)          # removed entirely
DOCKER_DOWN=0; DOCKER_IMAGE=0; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case $1 in
    --inputs|--input) EMPTY+=(inputs) ;;
    --results) REMOVE+=(tests/results) ;;
    --venv) REMOVE+=(.venv) ;;
    --docker) DOCKER_DOWN=1 ;;
    --docker-image) DOCKER_DOWN=1; DOCKER_IMAGE=1 ;;
    --all) EMPTY+=(inputs); REMOVE+=(tests/results .venv); DOCKER_DOWN=1; DOCKER_IMAGE=1 ;;
    -n|--dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Each data folder's own .gitignore (which keeps the folder in git) is never removed.
count() { find "$1" -mindepth 1 ! -path "$1/.gitignore" 2>/dev/null | wc -l | tr -d ' '; }
IMAGE=$(awk '/image:/ { print $2 }' docker-compose.yml)

echo "Will clean in $ROOT:"
for d in "${EMPTY[@]}"; do [ -d "$d" ] && echo "  empty   $d/  ($(count "$d") items)"; done
for d in "${REMOVE[@]}"; do [ -e "$d" ] && echo "  remove  $d/  ($(count "$d") items)"; done
[ $DOCKER_DOWN -eq 1 ] && echo "  docker  compose down (container docling_ocr_worker_cpu)"
[ $DOCKER_IMAGE -eq 1 ] && echo "  docker  remove image $IMAGE"
case " ${EMPTY[*]} " in *" inputs "*) echo "  NOTE: inputs/ holds PDFs that have not been processed yet." ;; esac

if [ $DRY -eq 1 ]; then echo "(dry run: nothing removed)"; exit 0; fi
if [ $YES -eq 0 ]; then
  read -r -p "Proceed? [y/N] " answer
  case $answer in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

for d in "${EMPTY[@]}"; do [ -d "$d" ] && find "$d" -mindepth 1 ! -path "$d/.gitignore" -delete; done
for d in "${REMOVE[@]}"; do rm -rf "$d"; done
find . -path ./.venv -prune -o -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
if [ $DOCKER_DOWN -eq 1 ]; then docker compose down; fi
if [ $DOCKER_IMAGE -eq 1 ]; then docker image rm "$IMAGE" || true; fi
echo "Cleanup done."
