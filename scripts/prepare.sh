#!/usr/bin/env bash
# Prepare: fetch the render ZIP from Inkrender once, prove every file's SHA-256, store it encrypted.
source "$(dirname "$0")/lib.sh"
load_key
progress '{"stage":"preparing"}'

echo "::group::Download the render package"
api GET /package -o "$RUNNER_TEMP/package.zip"
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
