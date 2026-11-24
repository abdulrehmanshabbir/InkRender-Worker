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
  KEY=$(api GET /key | jq -r .key)
  [ -n "$KEY" ] && [ "$KEY" != null ] || { echo "::error::Inkrender did not hand out the render key"; exit 1; }
  echo "::add-mask::$KEY"
  export KEY
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
