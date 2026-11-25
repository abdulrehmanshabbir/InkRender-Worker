# Helpers for the compress workflow: assets of the draft release, and ffmpeg with SVT-AV1.
set -euo pipefail
REPO_API="https://api.github.com/repos/$GITHUB_REPOSITORY"
auth=(-H "Authorization: Bearer $GH_TOKEN")

assets() { curl -sSf "${auth[@]}" "$REPO_API/releases/$RELEASE/assets?per_page=100"; }
asset_id() { assets | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'; }
download() {  # asset name, output file
  curl -sSfL --retry 5 --retry-all-errors --retry-delay 5 "${auth[@]}" -H "Accept: application/octet-stream" \
    -o "$2" "$REPO_API/releases/assets/$(asset_id "$1")"
}
upload() {  # file, asset name (replaces a half-uploaded copy from an earlier try)
  local old; old=$(asset_id "$2")
  [ -z "$old" ] || curl -sSf -X DELETE "${auth[@]}" "$REPO_API/releases/assets/$old"
  curl -sSf --retry 3 --retry-delay 10 -X POST "${auth[@]}" -H "Content-Type: application/octet-stream" \
    --data-binary @"$1" "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$RELEASE/assets?name=$(jq -rn --arg n "$2" '$n | @uri')" > /dev/null
}
need_ffmpeg() {
  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep libsvtav1 > /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg > /dev/null
  fi
  ffmpeg -hide_banner -encoders 2>/dev/null | grep libsvtav1 > /dev/null || { echo "::error::ffmpeg has no SVT-AV1"; exit 1; }
}
