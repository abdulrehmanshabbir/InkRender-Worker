# Shared helpers for the render jobs. Sourced, never run directly.
#   API  — Inkrender's public base URL (workflow input)
#   JOB  — the render's id (workflow input)
# Every call to Inkrender carries a fresh GitHub OIDC token; the server checks that it was issued to
# this repo's render workflow on main, for this very run. Nothing secret is stored in this repo.
set -euo pipefail

oidc() {
  curl -sSf --retry 4 --retry-delay 2 -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=inkrender" | jq -r .value
}

# api METHOD PATH [curl args…] — prints the response body
api() {
  local method=$1 path=$2 token
  shift 2
  token=$(oidc)  # never printed; nothing may be echoed here, callers parse this function's output
  curl -sSf --retry 5 --retry-all-errors --retry-delay 4 --max-time 3600 -X "$method" \
    -H "Authorization: Bearer $token" "$@" "$API/api/worker/$JOB$path"
}

# progress '{"chunk":"03","state":"rendering","pct":42}' — best effort, never fails the job
progress() {
  api POST /progress -H 'Content-Type: application/json' -d "$1" >/dev/null 2>&1 || true
}

# The per-render key that encrypts everything this run stores as an artifact (the repo is public).
load_key() {
  KEYJSON=$(api GET /key)
  KEY=$(jq -r .key <<< "$KEYJSON")
  [ -n "$KEY" ] && [ "$KEY" != null ] || { echo "::error::Inkrender did not hand out the render key"; exit 1; }
  echo "::add-mask::$KEY"
  export KEY KEYJSON
}

# Bulk data travels through the job's draft release on this repo (GitHub's own network), never
# through Inkrender's home connection. GH_TOKEN is the run's token (contents: write).
gh_download_asset() {  # asset id, output file
  curl -sSfL --retry 5 --retry-all-errors --retry-delay 5 -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/octet-stream" -o "$2" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/$1"
}
gh_upload_asset() {  # release id, file, asset name — replaces a half-uploaded copy from an earlier try
  local old
  old=$(curl -sSf -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/$1/assets?per_page=100" \
    | jq -r --arg n "$3" '.[] | select(.name == $n) | .id')
  [ -z "$old" ] || curl -sSf -X DELETE -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/$old"
  curl -sSf --retry 3 --retry-delay 10 -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: application/octet-stream" \
    --data-binary @"$2" "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$1/assets?name=$3" > /dev/null
}
encrypt() { openssl enc -aes-256-ctr -pbkdf2 -iter 200000 -salt -pass env:KEY -in "$1" -out "$2"; }
decrypt() { openssl enc -d -aes-256-ctr -pbkdf2 -iter 200000 -pass env:KEY -in "$1" -out "$2"; }

# Unpacks the encrypted package into ./pkg and cds into it.
open_package() {
  decrypt "$GITHUB_WORKSPACE/package/package.enc" "$RUNNER_TEMP/package.zip"
  rm -rf "$GITHUB_WORKSPACE/pkg"
  mkdir -p "$GITHUB_WORKSPACE/pkg"
  unzip -q "$RUNNER_TEMP/package.zip" -d "$GITHUB_WORKSPACE/pkg"
  rm -f "$RUNNER_TEMP/package.zip"
  cd "$GITHUB_WORKSPACE/pkg"/*/
}

# System ffmpeg with the SVT-AV1 encoder (chunks are encoded to AV1, the film is joined with it).
need_ffmpeg() {
  if ! ffmpeg -hide_banner -encoders 2>/dev/null | grep libsvtav1 > /dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y -qq ffmpeg > /dev/null
  fi
  ffmpeg -hide_banner -encoders 2>/dev/null | grep libsvtav1 > /dev/null || { echo "::error::ffmpeg has no SVT-AV1 encoder"; exit 1; }
}
