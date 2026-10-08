#!/usr/bin/env bash
# Simulate GitHub Pages locally: build the site exactly as the Pages workflow does, serve it
# from a Linux web server with GitHub Pages' layout, and check every link, anchor and asset:
#   http://localhost:8080/                        ↔ https://saibal-roy.github.io/  (user site: the separate
#                                                   repository folder ../saibal-roy.github.io, or $USER_SITE)
#   http://localhost:8080/docling-batch-extract/  ↔ https://saibal-roy.github.io/docling-batch-extract/
#
# Usage: scripts/preview_site.sh [--serve | --stop] [--deny-file FILE]
#   (default)          build --strict → serve at http://localhost:8080/docling-batch-extract/ → check
#                      (the preview keeps running so you can browse it)
#   --serve            live editing: mkdocs serve with auto-reload at http://localhost:8000/docling-batch-extract/
#                      (edits to README/STORY/etc. need a rerun, since the site source is assembled)
#   --stop             stop the preview server
#   --deny-file FILE   also fail if any term in FILE (e.g. client names) appears on the site
#
# Needs Docker and python3. Pinned MkDocs versions: docs/requirements.txt.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1
NAME=docling-site-preview
PORT=8080
SUBPATH=docling-batch-extract
USER_SITE=${USER_SITE:-../saibal-roy.github.io}   # the user-site repository, checked out next to this one
MKDOCS=(docker run --rm -v "$PWD":/repo -w /repo -v docling-site-pip:/root/.cache/pip)
SETUP="pip install -q --root-user-action=ignore --disable-pip-version-check -r docs/requirements.txt"

MODE=check; DENY=()
while [ $# -gt 0 ]; do
  case $1 in
    --serve) MODE=serve ;;
    --stop) docker rm -f "$NAME" >/dev/null 2>&1 && echo "preview stopped"; exit 0 ;;
    --deny-file) DENY=(--deny-file "$2"); shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "==> Assembling site source"
python3 scripts/build_site.py

if [ "$MODE" = serve ]; then
  echo "==> Live preview at http://localhost:8000/$SUBPATH/ (Ctrl+C to stop)"
  exec "${MKDOCS[@]}" -p 8000:8000 python:3.12-slim sh -c "$SETUP && mkdocs serve -a 0.0.0.0:8000"
fi

echo "==> Building with mkdocs build --strict (fails on broken internal links and anchors)"
"${MKDOCS[@]}" python:3.12-slim sh -c "$SETUP && mkdocs build --strict 2>&1 | grep -vE '^\s*$|│|Material for MkDocs team'"

echo "==> Serving like GitHub Pages: user site at /, project site at /$SUBPATH/ (nginx: Linux, case-sensitive)"
docker rm -f "$NAME" >/dev/null 2>&1 || true
PAGES=$(mktemp -d)                      # same layout as <user>.github.io
if [ -f "$USER_SITE/index.html" ]; then
  # Same files the user site's pages.yml publishes: index.html, .nojekyll, assets/ and every
  # top-level folder with its own index.html (e.g. github-practices/); not README/scripts
  cp "$USER_SITE/index.html" "$PAGES/"; [ -f "$USER_SITE/.nojekyll" ] && cp "$USER_SITE/.nojekyll" "$PAGES/"
  [ -d "$USER_SITE/assets" ] && cp -R "$USER_SITE/assets" "$PAGES/"
  for d in "$USER_SITE"/*/; do d=${d%/}; [ -f "$d/index.html" ] && cp -R "$d" "$PAGES/"; done
  echo "    user site from $(cd "$USER_SITE" && pwd)"
else
  printf '<!doctype html><title>No user site</title><p>No user site found at %s (set USER_SITE). On GitHub Pages this address is 404 until a &lt;user&gt;.github.io repository exists.</p><p><a href="%s/">Project site</a></p>\n' "$USER_SITE" "$SUBPATH" >"$PAGES/index.html"
  echo "    no user site at $USER_SITE: serving a placeholder at /"
fi
cp -R site "$PAGES/$SUBPATH"
chmod -R a+rX "$PAGES"
# GitHub Pages compresses responses, so the preview does too (keeps Lighthouse figures comparable).
GZIP_CONF=$(mktemp)
printf 'gzip on;\ngzip_types text/css application/javascript application/json image/svg+xml text/plain;\n' >"$GZIP_CONF"
chmod 644 "$GZIP_CONF"
docker run -d --name "$NAME" -p "$PORT:80" \
  -v "$GZIP_CONF":/etc/nginx/conf.d/gzip.conf:ro \
  -v "$PAGES":/usr/share/nginx/html:ro nginx:stable-alpine >/dev/null
ROOT_URL="http://localhost:$PORT/"
URL="http://localhost:$PORT/$SUBPATH/"
for _ in $(seq 1 20); do curl -sf -o /dev/null "$URL" && break; sleep 0.5; done

echo "==> Crawling $URL"
RC=0
python3 scripts/check_site.py "$URL" ${DENY[@]+"${DENY[@]}"} || RC=$?
echo "==> Crawling $ROOT_URL (user site)"
python3 scripts/check_site.py "$ROOT_URL" --no-search ${DENY[@]+"${DENY[@]}"} || RC=$?
NOT_FOUND=$(docker logs "$NAME" 2>&1 | grep -c '" 404 ' || true)
echo "nginx 404 responses during the crawl: $NOT_FOUND"
echo
echo "Preview running (stop: scripts/preview_site.sh --stop):"
echo "  $ROOT_URL                        ↔ https://saibal-roy.github.io/"
echo "  $URL   ↔ https://saibal-roy.github.io/$SUBPATH/"
echo "Optional: npx lighthouse $URL --view    ·    act -j build -W .github/workflows/pages.yml"
exit $RC
