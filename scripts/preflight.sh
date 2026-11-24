#!/usr/bin/env bash
# Preflight part N of M: render a share of every shot and overlay as small stills, so a broken or
# stalling shot stops the run in a minute or two, before any chunk starts rendering.
source "$(dirname "$0")/lib.sh"
PART=$1 PARTS=$2
load_key
[ "$PART" = 0 ] && progress '{"stage":"preparing"}'
open_package

echo "::group::Install the pinned renderer"
node render.mjs setup
echo "::endgroup::"

node "$GITHUB_WORKSPACE/scripts/preflight.mjs" "$PWD" --part "$PART" --parts "$PARTS"
