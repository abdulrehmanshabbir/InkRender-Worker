#!/usr/bin/env bash
# Join the AV1 parts without re-encoding, add the original narration (copied), verify, upload $1.
source "$(dirname "$0")/lib.sh"
NAME=$1
need_ffmpeg
cd "$RUNNER_TEMP"
: > list.txt
for i in $(seq 0 $((PARTS - 1))); do
  p=$(printf "part-%03d.mp4" "$i")
  download "$p" "$p"
  echo "file '$PWD/$p'" >> list.txt
done
download narration.opus narration.opus
ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i list.txt -i narration.opus \
  -map 0:v -map 1:a -c copy -movflags +faststart -y "$NAME"
GOT=$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 "$NAME")
[ "$GOT" = "$FRAMES" ] || { echo "::error::the film has $GOT frames, expected $FRAMES"; exit 1; }
ffprobe -v error -show_entries stream=codec_name,width,height,pix_fmt:format=duration,size,bit_rate -of compact "$NAME"
upload "$NAME" "$NAME"
for i in $(seq 0 $((PARTS - 1))); do  # the parts are no longer needed
  id=$(asset_id "$(printf "part-%03d.mp4" "$i")"); [ -z "$id" ] || curl -sSf -X DELETE "${auth[@]}" "$REPO_API/releases/assets/$id"
done
echo "done: $NAME ($(stat -c %s "$NAME") bytes)"
