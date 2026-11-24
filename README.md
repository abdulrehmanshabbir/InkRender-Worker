# InkRender-Worker

The GitHub Actions render farm behind **Inkrender**. It is started only by Inkrender (`workflow_dispatch`).

## What a run does

1. **Prepare**: takes the render ZIP from the job's draft release on this repo (Inkrender puts it there
   straight after the upload, so it never travels over Inkrender's home connection). It checks the
   SHA-256 of every file and the chunk plan (`render.mjs check --quick`), then stores the ZIP as an
   encrypted artifact.
2. **Preflight 0–19** (20 runners at once, about a minute): together they render a small still of every
   shot (start and middle) and of every overlay (entry and middle), about 2,300 frames for an 80-minute
   film. Any frame that throws, never settles, or is far slower than the rest stops the run before a
   single chunk renders. The error names the chunk, scene, shot, time and the error itself.
3. **Chunk NN** (one runner per chunk, 20 at a time): `scripts/render-chunk.mjs` renders the chunk in
   900-frame segments, each in a fresh browser, with a 3-minute limit per frame instead of Remotion's
   28 s. A failed segment is retried on its own with less parallelism (4 → 2 → 1). The segments are
   joined without re-encoding and verified like `render.mjs` does (frame count, size, codec, frame rate,
   every frame decoded). Progress is reported to Inkrender, and the chunk is stored as an encrypted
   artifact.
4. **Join and save**: re-verifies all chunks and joins them without re-encoding. It then adds the
   narration, verifies the film, and saves it, either straight into the Drive folder picked in Inkrender
   (resumable upload) or in the job's draft release, from which Inkrender downloads it directly.

If a chunk fails, Inkrender's **Retry** re-runs only the failed jobs. The finished chunks are reused.

## Security

- **No secrets in this repo.** Runners request a GitHub OIDC token (`id-token: write`). Inkrender
  checks its signature, and that it was issued to this repo's `render.yml` on `main` for the run that
  belongs to the render.
- **Encrypted artifacts.** The repo is public, which gives unlimited Actions minutes. Every artifact is
  AES-256 encrypted with a per-render key that only the run's own runners can get from Inkrender. The
  key and the Drive upload URL are masked in the logs.
- **Clean-up.** Inkrender deletes the whole run (logs and artifacts) as soon as the film is saved.
  Artifacts expire after 2 days anyway.
- **Drive access.** The upload URL covers one new file in the picked folder. Inkrender revokes its
  Drive access when the render ends.

## Files

| File | Purpose |
|---|---|
| `.github/workflows/render.yml` | prepare → chunk matrix → join and save |
| `scripts/lib.sh` | OIDC calls to Inkrender, progress, encryption |
| `scripts/prepare.sh`, `preflight.sh`, `chunk.sh`, `finish.sh` | the four stages |
| `scripts/preflight.mjs` | stills of every shot and overlay, split across runners |
| `scripts/render-chunk.mjs` | segmented, self-healing chunk render + verification |
