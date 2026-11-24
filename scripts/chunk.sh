#!/usr/bin/env bash
# Chunk: render one chunk with the package's own render.mjs (verified: frames, size, codec, every
# frame decoded), reporting progress to Inkrender, then store it encrypted for the join job.
source "$(dirname "$0")/lib.sh"
CHUNK=$1
load_key
progress "{\"chunk\":\"$CHUNK\",\"state\":\"setup\",\"pct\":0}"
open_package

echo "::group::Install the pinned renderer"
node render.mjs setup
echo "::endgroup::"

progress "{\"chunk\":\"$CHUNK\",\"state\":\"rendering\",\"pct\":0}"
node render.mjs render --chunks "$CHUNK" --concurrency "${CONCURRENCY:-4}" > render.log 2>&1 &
pid=$!
report() {
  # render.mjs redraws "  chunk 03  42% · overall … · 7.1 fps · ETA …" with \r
  local line pct fps
  line=$(tr '\r' '\n' < render.log | grep -E "chunk $CHUNK +[0-9]+%" | tail -n 1 || true)
  [ -n "$line" ] || return 0
  pct=$(sed -nE "s/.*chunk $CHUNK +([0-9]+)%.*/\1/p" <<< "$line")
  fps=$(sed -nE 's/.* ([0-9.]+) fps.*/\1/p' <<< "$line")
  progress "{\"chunk\":\"$CHUNK\",\"state\":\"rendering\",\"pct\":${pct:-0},\"fps\":${fps:-0}}"
  echo "chunk $CHUNK: ${pct:-0}% at ${fps:-?} fps"
}
while kill -0 "$pid" 2>/dev/null; do
  sleep 8
  report
done
if wait "$pid"; then status=0; else status=$?; fi
tr '\r' '\n' < render.log | grep -vE "^ +chunk $CHUNK +[0-9]+%" || true

if [ "$status" -ne 0 ] || [ ! -f "out/chunks/$CHUNK.ok.json" ]; then
  progress "{\"chunk\":\"$CHUNK\",\"state\":\"failed\"}"
  echo "::error::chunk $CHUNK failed to render or verify"
  exit 1
fi

mkdir -p "$GITHUB_WORKSPACE/result"
tar -C out/chunks -cf "$RUNNER_TEMP/$CHUNK.tar" "$CHUNK.mp4" "$CHUNK.ok.json"
encrypt "$RUNNER_TEMP/$CHUNK.tar" "$GITHUB_WORKSPACE/result/chunk-$CHUNK.enc"
rm -f "$RUNNER_TEMP/$CHUNK.tar"
progress "{\"chunk\":\"$CHUNK\",\"state\":\"done\",\"pct\":100}"
