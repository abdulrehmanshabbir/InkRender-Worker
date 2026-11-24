# InkRender-Worker

The GitHub Actions render farm behind **Inkrender**. It is started only by Inkrender (`workflow_dispatch`).

## What a run does

1. **Prepare**: downloads the film-packer render ZIP from Inkrender once and checks the SHA-256 of every
   file and the chunk plan (`render.mjs check --quick`). It then stores the ZIP as an encrypted artifact.
2. **Chunk NN** (one runner per chunk, 20 at a time): renders its chunk with the package's own
   `render.mjs`. Every chunk is verified: frame count, resolution, codec, and every frame decoded.
   Progress is reported to Inkrender, and the result is stored as an encrypted artifact.
3. **Join and save**: re-verifies all chunks and joins them without re-encoding. It then adds the
   narration, verifies the film, and uploads it straight into the Drive folder picked in Inkrender
   (resumable upload).

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
| `scripts/prepare.sh`, `chunk.sh`, `finish.sh` | the three jobs |
