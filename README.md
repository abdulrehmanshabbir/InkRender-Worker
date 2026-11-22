# InkRender-Worker

GitHub Actions render worker for **Inkrender**. Not meant to be used directly — the Inkrender backend triggers runs here via `workflow_dispatch`.

## How it works

1. Inkrender backend (on the InkStudio server) uploads a job manifest + pulls asset URLs from the user's Drive
2. Backend calls `POST /repos/.../actions/workflows/render.yml/dispatches` with:
   - `composition_id` (e.g. `Russia-Full`)
   - `total_frames` (e.g. `131707`)
   - `chunk_size` (default `900`)
   - `assets_url` (pre-signed Drive URL for the project tarball)
   - `callback_url` (Inkrender backend endpoint for progress)
3. Workflow fans out across 20 parallel runners using a matrix
4. Each runner downloads the tarball, renders its frame range, uploads chunk as artifact
5. Final concat job stitches with `ffmpeg -c copy`, uploads the final MP4 as artifact
6. Backend polls run status, pulls final MP4, uploads to user's picked Drive folder

## Files

- `.github/workflows/render.yml` — matrix render workflow (dispatch-only, no push triggers)
- `package.json` / `tsconfig.json` / `remotion.config.ts` — minimal Remotion scaffold

## Why is this repo public?

Public repos get unlimited GitHub Actions minutes on the free plan. No user data ever lives here — assets flow in as short-lived signed URLs from the user's own Google Drive, chunks live as temporary artifacts (auto-expire in 1 day), nothing persists.
