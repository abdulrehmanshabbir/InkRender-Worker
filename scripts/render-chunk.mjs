#!/usr/bin/env node
/**
 * Render one chunk of a film-packer package so that a stall can't sink it.
 *
 *   node render-chunk.mjs <package dir> <chunk id> [--segment 900] [--concurrency 4]
 *
 * The chunk is rendered in short segments, each in a fresh browser (nothing builds up over thousands
 * of frames), with a 3-minute limit per frame instead of Remotion's 28 s. A segment that fails is
 * retried on its own with less parallelism (4 → 2 → 1). The segments are then joined without
 * re-encoding into out/chunks/<id>.mp4 and verified the same way render.mjs does (exact frame count,
 * size, codec, frame rate, every frame decoded), and <id>.ok.json is written. Progress lines keep
 * render.mjs's format ("chunk 03  42% · … · 7.1 fps"), so the runner's progress reporting still works.
 */
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";

const [pkgArg, id, ...rest] = process.argv.slice(2);
const pkg = resolve(pkgArg);
const opt = (n, d) => { const i = rest.indexOf(n); return i >= 0 ? Number(rest[i + 1]) : d; };
const SEGMENT = opt("--segment", 900);
const CONC = opt("--concurrency", 4);
const FRAME_TIMEOUT_MS = 180000;

const r = createRequire(join(pkg, "package.json"))("@remotion/renderer");
const m = JSON.parse(readFileSync(join(pkg, "manifest.json"), "utf8"));
const c = m.chunks.find((x) => x.id === id);
if (!c) { console.log(`::error::no chunk ${id} in this package`); process.exit(1); }
const S = m.render, chromiumOptions = { gl: "angle" }, serveUrl = join(pkg, m.serveUrl);
const CHUNKS = join(pkg, "out", "chunks"), SEGS = join(pkg, "out", "segments", id);
mkdirSync(CHUNKS, { recursive: true });
mkdirSync(SEGS, { recursive: true });

// Remotion's own ffmpeg/ffprobe (shipped with @remotion/renderer)
const base = join(pkg, "node_modules", "@remotion");
const binDir = join(base, readdirSync(base).find((d) => d.startsWith("compositor-") && existsSync(join(base, d, "ffprobe"))));
const tool = (name, args) => {
  const res = spawnSync(join(binDir, name), args, { cwd: binDir, env: { ...process.env, LD_LIBRARY_PATH: binDir }, encoding: "utf8", maxBuffer: 1 << 28 });
  return { ok: res.status === 0, out: res.stdout ?? "", err: (res.stderr ?? "").trim() };
};
const probeFrames = (file) => {
  const p = tool("ffprobe", ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
    "stream=codec_name,width,height,r_frame_rate,nb_read_frames", "-of", "json", file]);
  if (!p.ok || p.err) return { error: p.err || "ffprobe failed" };
  return JSON.parse(p.out).streams?.[0] ?? { error: "no video stream" };
};
const sha256 = (file) => new Promise((res, rej) => {
  const h = createHash("sha256");
  createReadStream(file).on("data", (d) => h.update(d)).on("end", () => res(h.digest("hex"))).on("error", rej);
});

// ── segments
const total = c.to - c.from + 1;
const segs = [];
for (let a = c.from; a <= c.to; a += SEGMENT) segs.push([a, Math.min(c.to, a + SEGMENT - 1)]);
const segFile = (i) => join(SEGS, `${String(i).padStart(3, "0")}.mp4`);
const t0 = Date.now();
let doneFrames = 0;

const renderSegment = async (i, [a, b], conc) => {
  const browser = await r.openBrowser("chrome", {
    ...(process.env.CHROME ? { browserExecutable: process.env.CHROME, chromeMode: "chrome-for-testing" } : {}),
    chromiumOptions,
  });
  try {
    const composition = await r.selectComposition({ serveUrl, id: m.composition, puppeteerInstance: browser, inputProps: {}, chromiumOptions });
    const tmp = `${segFile(i)}.part.mp4`;
    await r.renderMedia({
      serveUrl, composition, puppeteerInstance: browser, chromiumOptions, inputProps: {},
      codec: "h264", crf: S.crf, x264Preset: S.x264Preset, pixelFormat: S.pixelFormat, imageFormat: "jpeg",
      jpegQuality: S.jpegQuality, muted: true, enforceAudioTrack: false, overwrite: true, concurrency: conc,
      timeoutInMilliseconds: FRAME_TIMEOUT_MS, frameRange: [a, b], outputLocation: tmp,
      onProgress: ({ renderedFrames }) => {
        const d = doneFrames + renderedFrames;
        const fps = d / Math.max((Date.now() - t0) / 1000, 1);
        process.stdout.write(`\r  chunk ${id} ${String(Math.floor((d / total) * 100)).padStart(3)}% · segment ${i + 1}/${segs.length} · ${fps.toFixed(1)} fps   `);
      },
    });
    const p = probeFrames(tmp);
    if (p.error) throw new Error(p.error);
    if (Number(p.nb_read_frames) !== b - a + 1) throw new Error(`${p.nb_read_frames} frames, expected ${b - a + 1}`);
    renameSync(tmp, segFile(i));
  } finally {
    await browser.close({ silent: true }).catch(() => {});
  }
};

for (let i = 0; i < segs.length; i++) {
  const [a, b] = segs[i];
  if (existsSync(segFile(i))) { doneFrames += b - a + 1; continue; }  // a retried job keeps finished segments
  let ok = false;
  for (const conc of [CONC, Math.max(1, Math.floor(CONC / 2)), 1]) {
    try {
      await renderSegment(i, segs[i], conc);
      ok = true;
      break;
    } catch (e) {
      process.stdout.write("\n");
      console.log(`✘ chunk ${id} frames ${a}–${b} (concurrency ${conc}): ${String(e?.message ?? e).split("\n")[0].slice(0, 300)}`);
      rmSync(`${segFile(i)}.part.mp4`, { force: true });
    }
  }
  if (!ok) { console.log(`::error::chunk ${id}: frames ${a}–${b} failed 3 times`); process.exit(1); }
  doneFrames += b - a + 1;
}
process.stdout.write("\n");

// ── join (no re-encode) + verify exactly like render.mjs
const list = join(SEGS, "list.txt");
writeFileSync(list, segs.map((_, i) => `file '${segFile(i)}'`).join("\n") + "\n");
const out = join(CHUNKS, `${id}.mp4`);
const j = tool("ffmpeg", ["-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", out]);
if (!j.ok) { console.log(`::error::joining chunk ${id} failed: ${j.err}`); process.exit(1); }
const p = probeFrames(out);
const problem = p.error ? p.error
  : Number(p.nb_read_frames) !== total ? `${p.nb_read_frames} frames, expected ${total}`
  : p.width !== m.width || p.height !== m.height ? `${p.width}×${p.height}, expected ${m.width}×${m.height}`
  : p.codec_name !== "h264" ? `codec ${p.codec_name}`
  : p.r_frame_rate !== `${m.fps}/1` ? `frame rate ${p.r_frame_rate}` : null;
if (problem) { rmSync(out, { force: true }); console.log(`::error::chunk ${id}: ${problem}`); process.exit(1); }
writeFileSync(join(CHUNKS, `${id}.ok.json`), JSON.stringify({ chunk: id, frames: total, sha256: await sha256(out), version: m.version, verified: new Date().toISOString() }, null, 1));
rmSync(SEGS, { recursive: true, force: true });
console.log(`✔ chunk ${id} (${c.label}) rendered and verified · ${total} frames in ${segs.length} segments · ${((Date.now() - t0) / 60000).toFixed(1)} min`);
