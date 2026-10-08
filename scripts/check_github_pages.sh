#!/usr/bin/env bash
# Read-only check: is a GitHub account ready to publish this site on GitHub Pages?
# Changes nothing: only reads from the GitHub API with the GitHub CLI (gh).
#
# Usage: scripts/check_github_pages.sh [github-user] [repo-name]
#        (defaults: the signed-in gh user, docling-batch-extract)
#
# Checks: gh installed and signed in · token scopes (repo, workflow) · account type · user site
# repo <user>.github.io and its Pages settings (custom domain!) · project repo and its Pages
# source · what https://<user>.github.io/ and https://<user>.github.io/<repo>/ return now.
set -uo pipefail
ok()   { printf '  [ OK ]  %s\n' "$*"; }
todo() { printf '  [TODO]  %s\n' "$*"; }
info() { printf '  [INFO]  %s\n' "$*"; }

command -v gh >/dev/null || { echo "GitHub CLI not found: https://cli.github.com/"; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  echo "Not signed in: run 'gh auth login' (scopes: repo, workflow)"; exit 1
fi
USER_NAME=${1:-$(gh api user --jq .login)}
REPO=${2:-docling-batch-extract}
SCOPES=$(gh auth status 2>&1 | sed -n "s/.*Token scopes: //p")

echo "== Account: $USER_NAME"
gh api "users/$USER_NAME" --jq '"  [ OK ]  \(.type) account, name: \(.name // "-"), public repos: \(.public_repos)"'
case $SCOPES in *repo*) ok "gh token has 'repo' scope" ;; *) todo "gh token lacks 'repo' scope: gh auth refresh -s repo" ;; esac
case $SCOPES in *workflow*) ok "gh token has 'workflow' scope (needed to push .github/workflows/)" ;;
  *) todo "gh token lacks 'workflow' scope: gh auth refresh -s workflow" ;; esac
info "Email verification can't be read with these scopes: confirm at https://github.com/settings/emails (Pages needs a verified email)"

echo "== User site: https://$USER_NAME.github.io/"
if gh api "repos/$USER_NAME/$USER_NAME.github.io" >/dev/null 2>&1; then
  ok "repository $USER_NAME/$USER_NAME.github.io exists"
  CNAME=$(gh api "repos/$USER_NAME/$USER_NAME.github.io/pages" --jq '.cname // ""' 2>/dev/null)
  UBUILD=$(gh api "repos/$USER_NAME/$USER_NAME.github.io/pages" --jq '.build_type // ""' 2>/dev/null)
  if [ "$UBUILD" = workflow ]; then ok "user site Pages source: GitHub Actions (its pages.yml checks links, then deploys)"
  elif [ -n "$UBUILD" ]; then todo "user site Pages source is '$UBUILD': set Settings → Pages → Source: GitHub Actions"
  else todo "user site Pages not enabled: Settings → Pages → Source: GitHub Actions"; fi
  if [ -n "$CNAME" ]; then
    info "user site has custom domain '$CNAME': project sites will be served at https://$CNAME/$REPO/ instead"
  else
    ok "no custom domain on the user site: project sites stay at https://$USER_NAME.github.io/<repo>/"
  fi
else
  todo "no repository named $USER_NAME.github.io: https://$USER_NAME.github.io/ stays 404 (optional; project sites work without it)"
fi

echo "== Project site: https://$USER_NAME.github.io/$REPO/"
if gh api "repos/$USER_NAME/$REPO" >/dev/null 2>&1; then
  VIS=$(gh api "repos/$USER_NAME/$REPO" --jq '.visibility')
  [ "$VIS" = public ] && ok "repository is public" || todo "repository is $VIS: Pages on GitHub Free needs a public repository"
  BUILD=$(gh api "repos/$USER_NAME/$REPO/pages" --jq '.build_type // ""' 2>/dev/null)
  if [ "$BUILD" = workflow ]; then ok "Pages source: GitHub Actions"
  elif [ -n "$BUILD" ]; then todo "Pages source is '$BUILD': set Settings → Pages → Source: GitHub Actions"
  else todo "Pages not enabled: Settings → Pages → Source: GitHub Actions"; fi
else
  todo "repository $USER_NAME/$REPO doesn't exist yet (create it public, then push)"
fi

echo "== Live status"
for url in "https://$USER_NAME.github.io/" "https://$USER_NAME.github.io/$REPO/"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
  [ "$code" = 200 ] && ok "$url → 200" || info "$url → $code"
done
