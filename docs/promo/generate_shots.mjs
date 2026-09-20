/**
 * Generates the live-action plates for the film with Open Higgsfield AI's
 * backend (muapi.ai), using the prompts and model ids already written into
 * storyboard.json.
 *
 *   export MUAPI_KEY=...
 *   node generate_shots.mjs                       # every scene with a shot
 *   node generate_shots.mjs --only ledger,close
 *   node generate_shots.mjs --dry-run             # print the requests, spend nothing
 *
 * Point --repo at a checkout of Autom8AI/Open-Higgsfield-AI and the model ids
 * are checked against its own catalog before anything is submitted, so a typo
 * costs nothing instead of a generation.
 *
 * Plates land in .promo-build/shots/<scene-id>.mp4. To use one, add
 * "plate": "<scene-id>.mp4" to that scene in storyboard.json and re-run the
 * build — scene.html composites it behind the type.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SB_PATH = resolve(HERE, 'storyboard.json');
const SB = JSON.parse(readFileSync(SB_PATH, 'utf8'));

const args = process.argv.slice(2);
const flag = (n, d) => { const i = args.indexOf('--' + n); return i === -1 ? d : args[i + 1]; };
const has = n => args.includes('--' + n);

const DRY = has('dry-run');
const BASE = flag('base', 'https://api.muapi.ai');
const OUT = resolve(HERE, flag('out', '../../.promo-build/shots'));
const only = (flag('only') || '').split(',').filter(Boolean);

const KEY = process.env.MUAPI_KEY || process.env.MUAPI_API_KEY;
if (!KEY && !DRY) {
  console.error('MUAPI_KEY is not set. Get one at https://muapi.ai, or pass --dry-run.');
  process.exit(2);
}

/* ---- check the model ids against the studio's own catalog ---------- */
const repo = flag('repo', process.env.OPEN_HIGGSFIELD_PATH);
if (repo) {
  const models = resolve(repo, 'src/lib/models.js');
  if (!existsSync(models)) {
    console.error(`--repo does not look like an Open-Higgsfield-AI checkout: ${models} is missing`);
    process.exit(2);
  }
  const m = await import(pathToFileURL(models).href);
  const known = new Set([...(m.t2vModels || []), ...(m.i2vModels || [])].map(x => x.id));
  const bad = SB.scenes.filter(s => s.shot && !known.has(s.shot.model));
  if (bad.length) {
    console.error('models not in the catalog:');
    bad.forEach(s => console.error(`  ${s.id}: ${s.shot.model}`));
    process.exit(2);
  }
  console.log(`checked ${SB.scenes.filter(s => s.shot).length} model ids against the catalog`);
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

/* Mirrors MuapiClient.pollForResult in src/lib/muapi.js. */
async function poll(requestId, { attempts = 900, interval = 2000 } = {}) {
  const url = `${BASE}/api/v1/predictions/${requestId}/result`;
  for (let i = 1; i <= attempts; i++) {
    await sleep(interval);
    let res;
    try {
      res = await fetch(url, { headers: { 'Content-Type': 'application/json', 'x-api-key': KEY } });
    } catch (e) {
      if (i === attempts) throw e;
      continue;                                    // transient; keep polling
    }
    if (!res.ok) {
      const body = await res.text();
      if (res.status >= 500) continue;
      throw new Error(`poll failed ${res.status}: ${body.slice(0, 200)}`);
    }
    const data = await res.json();
    const status = (data.status || '').toLowerCase();
    if (['completed', 'succeeded', 'success'].includes(status)) return data;
    if (['failed', 'error'].includes(status)) {
      throw new Error(`generation failed: ${data.error || 'unknown'}`);
    }
    if (i % 15 === 0) process.stderr.write(`\r    still working (${i * interval / 1000}s)   `);
  }
  throw new Error('timed out waiting for the generation');
}

/* Mirrors MuapiClient.generateVideo: t2v endpoints are addressed by id. */
async function generate(scene) {
  const { model, prompt, aspect_ratio, duration, resolution, quality } = scene.shot;
  const url = `${BASE}/api/v1/${model}`;
  const payload = { prompt };
  if (aspect_ratio) payload.aspect_ratio = aspect_ratio;
  if (duration) payload.duration = duration;
  if (resolution) payload.resolution = resolution;
  if (quality) payload.quality = quality;

  if (DRY) {
    console.log(`  POST ${url}\n  ${JSON.stringify(payload)}`);
    return null;
  }

  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-api-key': KEY },
    body: JSON.stringify(payload),
  });
  if (!res.ok) throw new Error(`submit failed ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const sub = await res.json();

  const id = sub.request_id || sub.id;
  const result = id ? await poll(id) : sub;
  const videoUrl = result.outputs?.[0] || result.url || result.output?.url;
  if (!videoUrl) throw new Error('the generation completed but returned no video url');
  return videoUrl;
}

mkdirSync(OUT, { recursive: true });

const wanted = SB.scenes.filter(s => s.shot && (!only.length || only.includes(s.id)));
if (!wanted.length) {
  console.error('nothing to generate' + (only.length ? ` for --only ${only.join(',')}` : ''));
  process.exit(2);
}

const failures = [];
for (const scene of wanted) {
  console.log(`\n${scene.id}  [${scene.shot.model}]`);
  try {
    const url = await generate(scene);
    if (!url) continue;
    process.stderr.write('\r    downloading                    \n');
    const buf = Buffer.from(await (await fetch(url)).arrayBuffer());
    const file = resolve(OUT, `${scene.id}.mp4`);
    writeFileSync(file, buf);
    console.log(`    ${file}  ${(buf.length / 1e6).toFixed(1)} MB`);
  } catch (e) {
    console.error(`    ${e.message}`);
    failures.push(scene.id);                       // one bad shot must not lose the rest
  }
}

if (failures.length) {
  console.error(`\n${failures.length} of ${wanted.length} failed: ${failures.join(', ')}`);
  process.exit(1);
}
console.log(`\n${wanted.length} plate(s) in ${OUT}`);
console.log('Add "plate": "<scene-id>.mp4" to a scene in storyboard.json, then re-run ./build.sh.');
