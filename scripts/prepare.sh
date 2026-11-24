#!/usr/bin/env bash
# Prepare: take the render ZIP from the job's draft release (Inkrender put it there straight after the
# upload), prove every file's SHA-256, then store it encrypted for the chunk runners.
source "$(dirname "$0")/lib.sh"
load_key
progress '{"stage":"preparing"}'

echo "::group::Download the render package"
ASSET=$(jq -r '.packageAsset // empty' <<< "$KEYJSON")
if [ -n "$ASSET" ]; then
  gh_download_asset "$ASSET" "$RUNNER_TEMP/package.zip"   # from GitHub itself: seconds
else
  api GET /package -o "$RUNNER_TEMP/package.zip"           # fallback: straight from Inkrender
fi
ls -l "$RUNNER_TEMP/package.zip"
echo "::endgroup::"

echo "::group::Check every file (SHA-256) and the chunk plan"
mkdir -p "$RUNNER_TEMP/check"
unzip -q "$RUNNER_TEMP/package.zip" -d "$RUNNER_TEMP/check"
(cd "$RUNNER_TEMP/check"/*/ && node render.mjs check --quick)
rm -rf "$RUNNER_TEMP/check"
echo "::endgroup::"

mkdir -p "$GITHUB_WORKSPACE/package"
encrypt "$RUNNER_TEMP/package.zip" "$GITHUB_WORKSPACE/package/package.enc"
rm -f "$RUNNER_TEMP/package.zip"
