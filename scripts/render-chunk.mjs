#!/usr/bin/env node
/**
 * Render one chunk of a film-packer package straight to AV1, so that a stall can't sink it.
 *
 *   node render-chunk.mjs <package dir> <chunk id> [--segment 900] [--concurrency 4]
 *   env: AV1_KBPS (780), AV1_PRESET (7), FFMPEG / FFPROBE (system ffmpeg with libsvtav1)
 *
 * The chunk is rendered in short segments, each in a fresh browser (nothing builds up over thousands of
 * frames), with a 3-minute limit per frame instead of Remotion's 28 s. Each segment is rendered to a
 * temporary high-quality H.264 file, then encoded to AV1 in the background while the next segment
 * renders (10-bit, SVT-AV1, VBR at AV1_KBPS, visual-quality tuning, a keyframe every 10 s), and the
 * temporary file is deleted. A segment that fails is retried on its own with less parallelism. The AV1
 * segments are joined without re-encoding into out/chunks/<id>.mp4, which is checked (codec, size, frame
 * rate, exact frame count) and fully decoded once, and <id>.ok.json is written. Progress lines keep
 * render.mjs's format ("chunk 03  42% · … · 7.1 fps") for the runner's progress reporting.
 */
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";

const [pkgArg, id, ...rest] = process.argv.slice(2);
const pkg = resolve(pkgArg);
const opt = (n, d) => { const i = rest.indexOf(n); return i >= 0 ? Number(rest[i + 1]) : d; };
const SEGMENT = opt("--segment", 900);
const CONC = opt("--concurrency", 4);
const FRAME_TIMEOUT_MS = 180000;
const KBPS = Number(process.env.AV1_KBPS || 780);
const PRESET = Number(process.env.AV1_PRESET || 7);
const FFMPEG = process.env.FFMPEG || "ffmpeg", FFPROBE = process.env.FFPROBE || "ffprobe";

const r = createRequire(join(pkg, "package.json"))("@remotion/renderer");
const m = JSON.parse(readFileSync(join(pkg, "manifest.json"), "utf8"));
const c = m.chunks.find((x) => x.id === id);
if (!c) { console.log(`::error::no chunk ${id} in this package`); process.exit(1); }
const chromiumOptions = { gl: "angle" }, serveUrl = join(pkg, m.serveUrl);
const CHUNKS = join(pkg, "out", "chunks"), SEGS = join(pkg, "out", "segments", id);
mkdirSync(CHUNKS, { recursive: true });
mkdirSync(SEGS, { recursive: true });

const run = (exe, args) => {
  const res = spawnSync(exe, args, { encoding: "utf8", maxBuffer: 1 << 28 });
  return { ok: res.status === 0, out: res.stdout ?? "", err: (res.stderr ?? "").trim() };
};
const frameCount = (file) => {
  const p = run(FFPROBE, ["-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries",
    "stream=codec_name,width,height,r_frame_rate,nb_read_packets", "-of", "json", file]);
  if (!p.ok) return { error: p.err || "ffprobe failed" };
  return JSON.parse(p.out).streams?.[0] ?? { error: "no video stream" };
};
const sha256 = (file) => new Promise((res, rej) => {
  const h = createHash("sha256");
  createReadStream(file).on("data", (d) => h.update(d)).on("end", () => res(h.digest("hex"))).on("error", rej);
});
if (!run(FFMPEG, ["-hide_banner", "-encoders"]).out.includes("libsvtav1")) {
  console.log("::error::ffmpeg has no libsvtav1 encoder"); process.exit(1);
}

// ── segments
const total = c.to - c.from + 1;
const segs = [];
for (let a = c.from; a <= c.to; a += SEGMENT) segs.push([a, Math.min(c.to, a + SEGMENT - 1)]);
const av1File = (i) => join(SEGS, `${String(i).padStart(3, "0")}.mp4`);
const midFile = (i) => join(SEGS, `${String(i).padStart(3, "0")}.h264.mp4`);
const t0 = Date.now();
let rendered = 0, encoded = 0;
const report = (extra = "") => {
  const pct = Math.floor(((rendered * 0.75 + encoded * 0.25) / total) * 100);
  const fps = rendered / Math.max((Date.now() - t0) / 1000, 1);
  process.stdout.write(`\r  chunk ${id} ${String(pct).padStart(3)}% · ${extra} · ${fps.toFixed(1)} fps   `);
};

const renderSegment = async (i, [a, b], conc) => {
  const browser = await r.openBrowser("chrome", {
    ...(process.env.CHROME ? { browserExecutable: process.env.CHROME, chromeMode: "chrome-for-testing" } : {}),
    chromiumOptions,
  });
  try {
    const composition = await r.selectComposition({ serveUrl, id: m.composition, puppeteerInstance: browser, inputProps: {}, chromiumOptions });
    const tmp = `${midFile(i)}.part.mp4`;
    const base = rendered;
    await r.renderMedia({
      serveUrl, composition, puppeteerInstance: browser, chromiumOptions, inputProps: {},
      // a near-lossless, fast-to-write intermediate: AV1 is made from it right after
      codec: "h264", crf: 12, x264Preset: "veryfast", pixelFormat: "yuv420p", imageFormat: "jpeg",
      jpegQuality: m.render.jpegQuality, muted: true, enforceAudioTrack: false, overwrite: true, concurrency: conc,
      timeoutInMilliseconds: FRAME_TIMEOUT_MS, frameRange: [a, b], outputLocation: tmp,
      onProgress: ({ renderedFrames }) => { rendered = base + renderedFrames; report(`segment ${i + 1}/${segs.length}`); },
    });
    const p = frameCount(tmp);
    if (p.error) throw new Error(p.error);
    if (Number(p.nb_read_packets) !== b - a + 1) throw new Error(`${p.nb_read_packets} frames, expected ${b - a + 1}`);
    renameSync(tmp, midFile(i));
    rendered = base + (b - a + 1);
  } finally {
    await browser.close({ silent: true }).catch(() => {});
  }
};

// AV1 encoding of finished segments, one at a time, in the background while rendering continues
const encodeSegment = (i, [a, b]) => new Promise((res, rej) => {
  const tmp = `${av1File(i)}.part.mp4`;
  const p = spawn(FFMPEG, ["-hide_banner", "-v", "error", "-y", "-i", midFile(i), "-an",
    "-c:v", "libsvtav1", "-preset", String(PRESET), "-b:v", `${KBPS}k`, "-g", "300", "-pix_fmt", "yuv420p10le",
    "-svtav1-params", "tune=0", tmp], { stdio: ["ignore", "ignore", "pipe"] });
  let err = "";
  p.stderr.on("data", (d) => { err += d; });
  p.on("close", (code) => {
    if (code !== 0) return rej(new Error(`AV1 encode failed: ${err.trim().split("\n").pop()}`));
    const f = frameCount(tmp);
    if (f.error || f.codec_name !== "av1" || Number(f.nb_read_packets) !== b - a + 1)
      return rej(new Error(`AV1 segment check failed: ${f.error || `${f.codec_name}, ${f.nb_read_packets} frames`}`));
    renameSync(tmp, av1File(i));
    rmSync(midFile(i), { force: true });
    res();
  });
});
let encoding = Promise.resolve();
const queueEncode = (i, seg) => {
  encoding = encoding.then(async () => {
    try {
      await encodeSegment(i, seg);
    } catch (e) {
      console.log(`\n✘ chunk ${id} segment ${i + 1}: ${e.message}; encoding once more`);
      await encodeSegment(i, seg);
    }
    encoded += seg[1] - seg[0] + 1;
    report(`segment ${Math.min(i + 2, segs.length)}/${segs.length}`);
  });
  encoding.catch(() => {});  // surfaced below when awaited
};

for (let i = 0; i < segs.length; i++) {
  const [a, b] = segs[i];
  if (existsSync(av1File(i))) { rendered += b - a + 1; encoded += b - a + 1; continue; }  // a retried job keeps finished segments
  if (!existsSync(midFile(i))) {
    let ok = false;
    for (const conc of [CONC, Math.max(1, Math.floor(CONC / 2)), 1]) {
      try {
        await renderSegment(i, segs[i], conc);
        ok = true;
        break;
      } catch (e) {
        console.log(`\n✘ chunk ${id} frames ${a}–${b} (concurrency ${conc}): ${String(e?.message ?? e).split("\n")[0].slice(0, 300)}`);
        rmSync(`${midFile(i)}.part.mp4`, { force: true });
      }
    }
    if (!ok) { console.log(`::error::chunk ${id}: frames ${a}–${b} failed 3 times`); process.exit(1); }
  } else {
    rendered += b - a + 1;
  }
  queueEncode(i, segs[i]);
}
try {
  await encoding;
} catch (e) {
  console.log(`\n::error::chunk ${id}: ${e.message}`);
  process.exit(1);
}
report(`joining`);
process.stdout.write("\n");

// ── join (no re-encode) + verify: codec, size, frame rate, exact frames, and one full decode
const list = join(SEGS, "list.txt");
writeFileSync(list, segs.map((_, i) => `file '${av1File(i)}'`).join("\n") + "\n");
const out = join(CHUNKS, `${id}.mp4`);
const j = run(FFMPEG, ["-hide_banner", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list, "-c", "copy", out]);
if (!j.ok) { console.log(`::error::joining chunk ${id} failed: ${j.err}`); process.exit(1); }
const p = frameCount(out);
const problem = p.error ? p.error
  : p.codec_name !== "av1" ? `codec ${p.codec_name}`
  : Number(p.nb_read_packets) !== total ? `${p.nb_read_packets} frames, expected ${total}`
  : p.width !== m.width || p.height !== m.height ? `${p.width}×${p.height}, expected ${m.width}×${m.height}`
  : p.r_frame_rate !== `${m.fps}/1` ? `frame rate ${p.r_frame_rate}` : null;
const decode = problem ? null : run(FFMPEG, ["-hide_banner", "-v", "error", "-i", out, "-f", "null", "-"]);
if (problem || !decode.ok || decode.err) {
  rmSync(out, { force: true });
  console.log(`::error::chunk ${id}: ${problem || `decode error: ${decode.err.split("\n")[0]}`}`);
  process.exit(1);
}
writeFileSync(join(CHUNKS, `${id}.ok.json`), JSON.stringify({ chunk: id, frames: total, codec: "av1", sha256: await sha256(out), version: m.version, verified: new Date().toISOString() }, null, 1));
rmSync(SEGS, { recursive: true, force: true });
console.log(`✔ chunk ${id} (${c.label}) rendered to AV1 and verified · ${total} frames in ${segs.length} segments · ${((Date.now() - t0) / 60000).toFixed(1)} min`);
