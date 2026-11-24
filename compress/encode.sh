#!/usr/bin/env bash
# Encode frames [A, B) of the master to AV1: part $1 of $PARTS. Exact frames, verified, then uploaded.
source "$(dirname "$0")/lib.sh"
PART=$1
need_ffmpeg

echo "::group::Fetch the master"
for n in $(assets | jq -r '.[].name' | grep '^master\.part' | sort); do
  download "$n" "$RUNNER_TEMP/$n"
  cat "$RUNNER_TEMP/$n" >> "$RUNNER_TEMP/master.mp4"
  rm -f "$RUNNER_TEMP/$n"
done
ls -l "$RUNNER_TEMP/master.mp4"
echo "::endgroup::"

A=$(( FRAMES * PART / PARTS )); B=$(( FRAMES * (PART + 1) / PARTS )); N=$(( B - A ))
read -r SS T0 T1 < <(python3 -c "print(max(0, $A/$FPS - 2), ($A - 0.5)/$FPS, ($B - 0.5)/$FPS)")
OUT="$RUNNER_TEMP/part-$(printf %03d "$PART").mp4"
echo "frames $A..$((B - 1)) ($N frames)"
# Seek just before the range, keep exactly frames A..B-1 by their original timestamps, stop after N.
ffmpeg -hide_banner -loglevel error -stats -copyts -ss "$SS" -i "$RUNNER_TEMP/master.mp4" -an \
  -vf "select=between(t\,$T0\,$T1),setpts=N/($FPS*TB)" -fps_mode passthrough -frames:v "$N" \
  -c:v libsvtav1 -preset 7 -b:v "${KBPS}k" -g 300 -pix_fmt yuv420p10le -svtav1-params tune=0 \
  -movflags +faststart -y "$OUT"
GOT=$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 "$OUT")
[ "$GOT" = "$N" ] || { echo "::error::part $PART has $GOT frames, expected $N"; exit 1; }
echo "part $PART: $N frames, $(stat -c %s "$OUT") bytes"
upload "$OUT" "$(basename "$OUT")"
