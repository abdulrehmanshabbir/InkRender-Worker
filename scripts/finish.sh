#!/usr/bin/env bash
# Join and save: re-verify every chunk, join them without re-encoding, add the narration, verify the
# film, then save it: straight into the user's Drive folder (resumable; Inkrender opens the upload), or
# onto the Inkrender server when Drive is switched off for this render.
source "$(dirname "$0")/lib.sh"
load_key
progress '{"stage":"joining"}'
open_package
PKG=$PWD

echo "::group::Unpack the verified chunks"
mkdir -p out/chunks
for f in "$GITHUB_WORKSPACE"/chunks/chunk-*.enc; do
  decrypt "$f" "$RUNNER_TEMP/c.tar"
  rm -f "$f"
  tar -C out/chunks -xf "$RUNNER_TEMP/c.tar"
  rm -f "$RUNNER_TEMP/c.tar"
done
ls -l out/chunks
echo "::endgroup::"

echo "::group::Install the pinned renderer"
node render.mjs setup
echo "::endgroup::"

node render.mjs verify
node render.mjs stitch
FILM="$PKG/out/$(jq -r .output manifest.json)"
SIZE=$(stat -c %s "$FILM")
MD5=$(md5sum "$FILM" | cut -d' ' -f1)
echo "film: $SIZE bytes, md5 $MD5"

progress '{"stage":"saving"}'
TARGET=$(api POST /video-upload -H 'Content-Type: application/json' -d "{\"bytes\":$SIZE}")
MODE=$(jq -r .mode <<< "$TARGET")

if [ "$MODE" = server ]; then
  # Save on the Inkrender server: 32 MB parts, each resumed from what the server reports it has.
  PART=$((32 * 1024 * 1024))
  sent=$(api GET /video | jq -r .received)
  fails=0
  while [ "$sent" -lt "$SIZE" ]; do
    dd if="$FILM" of="$RUNNER_TEMP/part" bs=4M iflag=skip_bytes,count_bytes skip="$sent" count="$PART" status=none
    if got=$(api PUT "/video?offset=$sent" -H 'Content-Type: application/octet-stream' --data-binary @"$RUNNER_TEMP/part" | jq -r .received); then
      fails=0
      sent=$got
      echo "saved $((sent * 100 / SIZE))% to the server"
    else
      fails=$((fails + 1))
      [ "$fails" -le 8 ] || { echo "::error::uploading the film to the server failed"; exit 1; }
      sleep $((fails * 5))
      sent=$(api GET /video | jq -r .received)
    fi
  done
  rm -f "$RUNNER_TEMP/part"
  api POST /video-done -H 'Content-Type: application/json' -d "{\"md5\":\"$MD5\",\"bytes\":$SIZE}" >/dev/null
  echo "saved to the server"
  exit 0
fi

URL=$(jq -r .url <<< "$TARGET")
[ -n "$URL" ] && [ "$URL" != null ] || { echo "::error::Inkrender could not open the Drive upload"; exit 1; }
echo "::add-mask::$URL"

# Resumable upload: send what Drive hasn't got yet, ask where it got to after any failure.
sent=0
for attempt in 1 2 3 4 5 6 7 8; do
  if [ "$sent" -eq 0 ]; then
    code=$(curl -sS -o "$RUNNER_TEMP/drive.json" -w '%{http_code}' -X PUT -H "Content-Length: $SIZE" \
      --upload-file "$FILM" "$URL" || echo 000)
  else
    code=$(tail -c +"$((sent + 1))" "$FILM" | curl -sS -o "$RUNNER_TEMP/drive.json" -w '%{http_code}' -X PUT \
      -H "Content-Length: $((SIZE - sent))" -H "Content-Range: bytes $sent-$((SIZE - 1))/$SIZE" \
      --data-binary @- "$URL" || echo 000)
  fi
  if [ "$code" = 200 ] || [ "$code" = 201 ]; then break; fi
  echo "upload attempt $attempt stopped (HTTP $code); resuming"
  sleep $((attempt * 5))
  range=$(curl -sS -o /dev/null -D - -X PUT -H "Content-Length: 0" -H "Content-Range: bytes */$SIZE" "$URL" \
    | tr -d '\r' | sed -nE 's/^[Rr]ange: bytes=0-([0-9]+)$/\1/p' || true)
  sent=$(( ${range:--1} + 1 ))
done
[ "$code" = 200 ] || [ "$code" = 201 ] || { echo "::error::uploading the film to Drive failed"; exit 1; }
FILE_ID=$(jq -r .id "$RUNNER_TEMP/drive.json")
api POST /video-done -H 'Content-Type: application/json' \
  -d "{\"fileId\":\"$FILE_ID\",\"md5\":\"$MD5\",\"bytes\":$SIZE}" >/dev/null
echo "saved to Drive"
