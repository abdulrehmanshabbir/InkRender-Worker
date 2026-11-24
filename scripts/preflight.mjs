#!/usr/bin/env node
/**
 * Preflight: prove the whole film renders before any chunk starts, in about a minute.
 *
 *   node preflight.mjs <package dir> [--part 0 --parts 20] [--concurrency 4] [--scale 0.25] [--slow-ms 8000]
 *
 * Renders small stills of every shot (its start and middle) and of every overlay's entry and middle,
 * several at a time, timing each one. --part/--parts split the list so many runners share the work. Fails on any frame that throws, never settles, or is far
 * slower than the rest. Every failure is reported with its chunk, scene, shot, time and the error, so a
 * broken shot is caught in seconds instead of an hour into a render.
 */
import { createRequire } from "node:module";
import { readFileSync, mkdirSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import os from "node:os";

const [pkgArg, ...rest] = process.argv.slice(2);
const pkg = resolve(pkgArg);
const opt = (n, d) => { const i = rest.indexOf(n); return i >= 0 ? Number(rest[i + 1]) : d; };
const CONC = opt("--concurrency", Math.max(2, os.cpus().length));
const SCALE = opt("--scale", 0.25);
const SLOW_MS = opt("--slow-ms", 8000);
const PART = opt("--part", 0), PARTS = opt("--parts", 1);
const TIMEOUT_MS = 60000;

const r = createRequire(join(pkg, "package.json"))("@remotion/renderer");
const m = JSON.parse(readFileSync(join(pkg, "manifest.json"), "utf8"));
const film = JSON.parse(readFileSync(join(pkg, "film.json"), "utf8"));
const fps = m.fps, last = m.durationInFrames - 1;
const serveUrl = join(pkg, m.serveUrl);
const chromiumOptions = { gl: "angle" };
const clock = (f) => { const s = Math.floor(f / fps); return `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`; };
const chunkOf = (f) => m.chunks.find((c) => f >= c.from && f <= c.to);

// ── which frames: every shot (start, middle, end) + every overlay (entry, middle)
const frames = new Map(); // frame -> why
const add = (sec, why) => {
  const f = Math.min(last, Math.max(0, Math.round(sec * fps)));
  if (!frames.has(f)) frames.set(f, why);
};
for (const s of film.shots) {
  const a = Number(s.start), b = Number(s.end);
  const where = `${s.scene} ${s.id}`;
  add(a + 2 / fps, `${where} start`);
  add((a + b) / 2, `${where} middle`);
  for (const o of s.overlays || []) {
    const io = String(o["In → Out"] ?? o.In ?? "").match(/([\d.]+)\s*→\s*([\d.]+)/);
    if (!io) continue;
    const i = a + Number(io[1]), e = a + Number(io[2]);
    if (i >= b) continue;
    add(i + 0.4, `${where} ${o.Component} entering`);
    add((i + Math.min(e, b)) / 2, `${where} ${o.Component}`);
  }
}
// every PARTS-th frame for this part: each runner gets an even spread across the whole film
const list = [...frames.keys()].sort((x, y) => x - y).filter((_, i) => i % PARTS === PART);

// ── render them, CONC at a time, each with a hard deadline
const out = join(os.tmpdir(), "inkrender-preflight");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const browser = await r.openBrowser("chrome", {
  ...(process.env.CHROME ? { browserExecutable: process.env.CHROME, chromeMode: "chrome-for-testing" } : {}),
  chromiumOptions,
});
const composition = await r.selectComposition({ serveUrl, id: m.composition, puppeteerInstance: browser, inputProps: {}, chromiumOptions });
if (composition.durationInFrames !== m.durationInFrames) {
  console.log(`::error::the film has ${composition.durationInFrames} frames but the manifest says ${m.durationInFrames}`);
  process.exit(1);
}

const t0 = Date.now();
const times = [], failures = [];
let next = 0, done = 0;
const worker = async () => {
  while (next < list.length) {
    const f = list[next++];
    const s = Date.now();
    try {
      await r.renderStill({
        serveUrl, composition, frame: f, puppeteerInstance: browser, chromiumOptions, inputProps: {},
        output: join(out, `${f}.jpg`), imageFormat: "jpeg", jpegQuality: 50, scale: SCALE, timeoutInMilliseconds: TIMEOUT_MS,
      });
      times.push({ f, ms: Date.now() - s });
    } catch (e) {
      failures.push({ f, error: String(e?.message ?? e).split("\n")[0].slice(0, 240) });
    }
    if (++done % 100 === 0) console.log(`  ${done}/${list.length} frames checked · ${((Date.now() - t0) / 1000).toFixed(0)} s`);
  }
};
await Promise.all(Array.from({ length: CONC }, worker));
await browser.close({ silent: true });
rmSync(out, { recursive: true, force: true });

// ── verdict
const sorted = times.map((t) => t.ms).sort((a, b) => a - b);
const median = sorted[Math.floor(sorted.length / 2)] || 0;
const slow = times.filter((t) => t.ms > Math.max(SLOW_MS, median * 12));
const where = (f) => { const c = chunkOf(f); return `chunk ${c?.id} · ${frames.get(f)} · ${clock(f)} (frame ${f})`; };
console.log(`part ${PART + 1}/${PARTS}: checked ${list.length} of ${frames.size} frames (${film.shots.length} shots) in ${((Date.now() - t0) / 1000).toFixed(0)} s · median ${median} ms per frame`);
for (const x of failures) console.log(`::error::${where(x.f)}: ${x.error}`);
for (const x of slow) console.log(`::error::${where(x.f)}: took ${(x.ms / 1000).toFixed(1)} s (median ${median} ms), so it would stall the render`);
if (failures.length || slow.length) {
  console.log(`✘ preflight: ${failures.length} failing and ${slow.length} too-slow frame(s). Fix these shots in the film, pack it again, and re-upload.`);
  process.exit(1);
}
console.log("✔ preflight: every shot and overlay renders");
