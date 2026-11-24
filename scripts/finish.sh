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
  # Leave the film in the job's draft release (parts under GitHub's 2 GB limit); Inkrender then
  # downloads it directly from GitHub, at full speed, and checks size + md5 before keeping it.
  RELEASE=$(jq -r '.release // empty' <<< "$KEYJSON")
  [ -n "$RELEASE" ] || { echo "::error::Inkrender gave no release for the film"; exit 1; }
  mkdir -p "$RUNNER_TEMP/film"
  split -b 1900m -d -a 3 "$FILM" "$RUNNER_TEMP/film/film.part"
  PARTS=()
  for f in "$RUNNER_TEMP"/film/film.part*; do
    name=$(basename "$f")
    echo "sending $name ($(stat -c %s "$f") bytes) to GitHub"
    gh_upload_asset "$RELEASE" "$f" "$name"
    PARTS+=("$name")
    rm -f "$f"
  done
  PJSON=$(printf '%s\n' "${PARTS[@]}" | jq -R . | jq -sc .)
  api POST /video-done -H 'Content-Type: application/json' \
    -d "{\"md5\":\"$MD5\",\"bytes\":$SIZE,\"parts\":$PJSON}" >/dev/null
  echo "film handed to Inkrender via GitHub"
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
