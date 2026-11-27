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
# A release-asset name GitHub keeps as it is (spaces and other characters become hyphens).
safe_name() { printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/-/g'; }

gh_upload_asset() {  # release id, file, asset name — replaces a half-uploaded copy from an earlier try
  local old enc
  old=$(curl -sSf -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/$1/assets?per_page=100" \
    | jq -r --arg n "$3" '.[] | select(.name == $n) | .id')
  [ -z "$old" ] || curl -sSf -X DELETE -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/$old"
  enc=$(jq -rn --arg n "$3" '$n | @uri')
  curl -sSf --retry 3 --retry-delay 10 -X POST -H "Authorization: Bearer $GH_TOKEN" -H "Content-Type: application/octet-stream" \
    --data-binary @"$2" "https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$1/assets?name=$enc" > /dev/null
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
# Runner images carry third-party apt sources (Microsoft, …) that sometimes answer 403 or lose their signature; one
# broken source makes `apt-get update` fail and ffmpeg never installs. Only Ubuntu's own archive is used, a failed
# update never stops the install, it is retried, and if apt still has no SVT-AV1 a static build (BtbN, GPL) is used.
has_svtav1() { ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libsvtav1; }
need_ffmpeg() {
  if ! has_svtav1; then
    sudo find /etc/apt/sources.list.d -type f ! -name 'ubuntu*' -delete 2>/dev/null || true
    for try in 1 2 3; do
      sudo apt-get update -qq || true
      sudo apt-get install -y -qq ffmpeg > /dev/null && break
      echo "apt install of ffmpeg failed (try $try), retrying"; sleep $((try * 10))
    done
  fi
  if ! has_svtav1; then
    echo "apt's ffmpeg has no SVT-AV1: using the static build"
    local dir="$RUNNER_TEMP/ffmpeg-static"
    mkdir -p "$dir"
    for try in 1 2 3; do
      curl -fsSL --retry 3 https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz \
        | tar -xJ -C "$dir" --strip-components=1 && break
      sleep $((try * 10))
    done
    export PATH="$dir/bin:$PATH"
    [ -n "${GITHUB_PATH:-}" ] && echo "$dir/bin" >> "$GITHUB_PATH"
  fi
  has_svtav1 || { echo "::error::ffmpeg has no SVT-AV1 encoder"; exit 1; }
  echo "ffmpeg: $(command -v ffmpeg)"
}
