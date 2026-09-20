/**
 * Renders docs/promo/scene.html one frame at a time and pipes the frames
 * straight into ffmpeg. Every frame is a pure function of time, so two runs
 * of this script produce the same file.
 *
 *   node render.mjs --out promo.mp4
 *   node render.mjs --preview 0.9,7.2,15,23,31,39,46,53,58   (stills, for looking at)
 */
import { chromium } from 'playwright';
import ffmpegPath from 'ffmpeg-static';
import { spawn } from 'node:child_process';
import { readFileSync, mkdirSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SB = JSON.parse(readFileSync(resolve(HERE, 'storyboard.json'), 'utf8'));

const args = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = args.indexOf('--' + name);
  return i === -1 ? dflt : args[i + 1];
};

const FPS = SB.format.fps;
const W = SB.format.width;
const H = SB.format.height;
const TOTAL = SB.duration_seconds;

/* The storyboard must describe a film with no gaps and no overlaps. A seam
   here is invisible in the output but wrong, so it fails the render. */
SB.scenes.forEach((s, i) => {
  const prev = SB.scenes[i - 1];
  if (prev && Math.abs(prev.start + prev.duration - s.start) > 1e-9) {
    throw new Error(`scene "${s.id}" does not start where "${prev.id}" ends`);
  }
});
const last = SB.scenes[SB.scenes.length - 1];
if (Math.abs(last.start + last.duration - TOTAL) > 1e-9) {
  throw new Error('scenes do not add up to duration_seconds');
}

/* Playwright's own download is skipped on machines that already carry a
   Chromium (CI images, the remote sandbox). Point CHROMIUM_PATH at one, or
   let this find the usual place, before falling back to Playwright's copy. */
const findChromium = () => {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH;
  const roots = [process.env.PLAYWRIGHT_BROWSERS_PATH, '/opt/pw-browsers'].filter(Boolean);
  for (const root of roots) {
    let entries = [];
    try { entries = readdirSync(root); } catch { continue; }
    for (const e of entries.sort().reverse()) {
      for (const tail of ['chrome-linux/chrome', 'chrome-linux/headless_shell']) {
        const c = resolve(root, e, tail);
        if (existsSync(c)) return c;
      }
    }
  }
  return undefined;            // let Playwright resolve its own download
};

const browser = await chromium.launch({
  executablePath: findChromium(),
  args: ['--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb',
         '--hide-scrollbars', '--disable-gpu'],
});
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
await page.addInitScript(sb => { window.__STORYBOARD__ = sb; }, SB);
await page.goto(pathToFileURL(resolve(HERE, 'scene.html')).href, { waitUntil: 'load' });
await page.evaluate(() => document.fonts.ready);
await page.waitForFunction(() => window.__ready === true);

const preview = flag('preview');
if (preview) {
  const dir = resolve(HERE, flag('preview-dir', '../../.promo-preview'));
  mkdirSync(dir, { recursive: true });
  for (const raw of preview.split(',')) {
    const t = parseFloat(raw);
    await page.evaluate(tt => window.__render(tt), t);
    const buf = await page.screenshot({ type: 'png' });
    const f = resolve(dir, `t${String(t).replace('.', '_')}.png`);
    writeFileSync(f, buf);
    console.log('preview', f);
  }
  await browser.close();
  process.exit(0);
}

const out = resolve(HERE, flag('out', '../../.promo-build/iakauntan-promo-silent.mp4'));
mkdirSync(dirname(out), { recursive: true });

const ff = spawn(ffmpegPath, [
  '-y', '-hide_banner', '-loglevel', 'error',
  '-f', 'image2pipe', '-framerate', String(FPS), '-i', 'pipe:0',
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '17',
  '-pix_fmt', 'yuv420p', '-profile:v', 'high', '-level', '4.2',
  '-x264-params', 'keyint=60:min-keyint=30',
  '-movflags', '+faststart',
  out,
], { stdio: ['pipe', 'inherit', 'inherit'] });

const write = buf => new Promise((res, rej) => {
  if (ff.stdin.write(buf)) return res();
  ff.stdin.once('drain', res);
  ff.stdin.once('error', rej);
});

const frames = Math.round(TOTAL * FPS);
const t0 = Date.now();
for (let i = 0; i < frames; i++) {
  const t = i / FPS;
  await page.evaluate(tt => window.__render(tt), t);
  await write(await page.screenshot({ type: 'jpeg', quality: 96 }));
  if (i % 60 === 0 || i === frames - 1) {
    const pct = ((i + 1) / frames * 100).toFixed(1);
    const rate = (i + 1) / ((Date.now() - t0) / 1000);
    process.stderr.write(`\r  frame ${i + 1}/${frames}  ${pct}%  ${rate.toFixed(1)} fps   `);
  }
}
process.stderr.write('\n');

ff.stdin.end();
await new Promise((res, rej) => {
  ff.on('close', code => (code === 0 ? res() : rej(new Error('ffmpeg exited ' + code))));
});
await browser.close();
console.log('wrote', out);
