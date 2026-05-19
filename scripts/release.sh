#!/bin/bash
# Tag, build, and publish a new GitHub release.
#
# Usage:  ./scripts/release.sh v0.6.0  [optional release notes]
#
# Requirements:
#   - `gh` CLI authenticated against the repo (`gh auth login`)
#   - clean git working tree
#   - VERSION argument starts with `v` and parses as semver-ish

set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
  echo "usage: $0 vMAJOR.MINOR.PATCH [notes]" >&2
  exit 1
fi

TAG="$1"
NOTES="${2:-Release $TAG}"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Tag must look like vX.Y.Z (got '$TAG')" >&2
  exit 1
fi
VERSION="${TAG#v}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean. Commit or stash first." >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required: https://cli.github.com" >&2
  exit 1
fi

echo "==> Building $TAG"
VERSION="$VERSION" ./scripts/build-app.sh

echo "==> Tagging $TAG"
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "Tag $TAG already exists locally — refusing to overwrite." >&2
  exit 1
fi
git tag -a "$TAG" -m "$NOTES"
git push origin "$TAG"

echo "==> Creating GitHub release"
gh release create "$TAG" \
  --title "ClaudeNotch $TAG" \
  --notes "$NOTES" \
  dist/ClaudeNotch.zip

echo
echo "Released $TAG."
echo "The running app will detect this on its next 24h check (or when the user picks Check for Updates…)."
