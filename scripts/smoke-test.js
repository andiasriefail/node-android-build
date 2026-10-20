// Smoke test for the Android node binary. Run it ON THE PHONE (Studio Mobile or adb):
//   node smoke-test.js [--npm=<dir that contains npm's package.json>]
// Prints one line per check and exits 1 if a required check fails.
// OPTIONAL checks (Temporal, node:sqlite) only report; they never fail the run.
'use strict';
const os = require('node:os');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const cp = require('node:child_process');

const required = [];
const optional = [];
const npmArg = process.argv.find((a) => a.startsWith('--npm='));

function req(name, fn) { required.push([name, fn]); }
function opt(name, fn) { optional.push([name, fn]); }
function assert(cond, msg) { if (!cond) throw new Error(msg || 'assertion failed'); }

req('version and arch', () => {
  assert(/^v\d+\./.test(process.version), process.version);
  assert(['arm64', 'arm', 'x64', 'ia32'].includes(process.arch), process.arch);
  assert(process.platform === 'android' || process.platform === 'linux', process.platform);
});
req('modern syntax (?., ??, #private, BigInt, class static block)', () => {
  const r = new Function('class A { #x = 2n; static v; static { A.v = 40n; } get() { return this.#x + A.v; } } return (null ?? new A()?.get());')();
  assert(r === 42n, String(r));
});
req('structuredClone, Array.at, Object.groupBy, Promise.withResolvers', () => {
  assert(structuredClone({ a: new Map([[1, 2]]) }).a.get(1) === 2);
  assert([1, 2, 3].at(-1) === 3);
  assert(Object.groupBy([1, 2, 3], (n) => (n % 2 ? 'odd' : 'even')).odd.length === 2);
  assert(typeof Promise.withResolvers === 'function');
});
req('Intl (full ICU: locales, time zones, Segmenter)', () => {
  const d = new Date(Date.UTC(2024, 0, 15, 12, 0, 0));
  const jp = new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', dateStyle: 'full' }).format(d);
  assert(/2024/.test(jp) && /月/.test(jp), jp);
  const de = new Intl.NumberFormat('de-DE', { style: 'currency', currency: 'EUR' }).format(1234.5);
  assert(de.includes('1.234,50'), de);
  assert([...new Intl.Segmenter('en', { granularity: 'word' }).segment('hello big world')].length >= 5);
});
req('crypto (sha256, randomUUID, aes-256-gcm)', () => {
  assert(crypto.createHash('sha256').update('abc').digest('hex') === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert(/^[0-9a-f-]{36}$/.test(crypto.randomUUID()));
  const key = crypto.randomBytes(32), iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const enc = Buffer.concat([c.update('hello'), c.final()]); const tag = c.getAuthTag();
  const dc = crypto.createDecipheriv('aes-256-gcm', key, iv); dc.setAuthTag(tag);
  assert(Buffer.concat([dc.update(enc), dc.final()]).toString() === 'hello');
});
req('zlib gzip and brotli round trip', () => {
  const data = Buffer.from('studio mobile '.repeat(1000));
  assert(zlib.gunzipSync(zlib.gzipSync(data)).equals(data));
  assert(zlib.brotliDecompressSync(zlib.brotliCompressSync(data)).equals(data));
});
req('fs in os.tmpdir() (set TMPDIR to an app-writable folder)', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'smoke-'));
  const file = path.join(dir, 'a.txt');
  fs.writeFileSync(file, 'ok'); assert(fs.readFileSync(file, 'utf8') === 'ok');
  fs.rmSync(dir, { recursive: true });
});
req('WebAssembly (add function)', () => {
  const bytes = new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11]);
  const inst = new WebAssembly.Instance(new WebAssembly.Module(bytes));
  assert(inst.exports.add(40, 2) === 42);
});
req('child_process spawns this binary', () => {
  const r = cp.spawnSync(process.execPath, ['-p', '6*7'], { encoding: 'utf8' });
  assert(r.status === 0 && r.stdout.trim() === '42', JSON.stringify(r));
});
req('fetch, URL, TextEncoder, AbortController, Blob exist', () => {
  for (const n of ['fetch', 'URL', 'TextEncoder', 'AbortController', 'Blob', 'WebSocket', 'ReadableStream'])
    assert(typeof globalThis[n] !== 'undefined', n + ' missing');
});
req('timers and async/await', async () => {
  const t0 = Date.now(); await new Promise((r) => setTimeout(r, 30)); assert(Date.now() - t0 >= 25);
});
req('worker_threads', () => new Promise((resolve, reject) => {
  const { Worker } = require('node:worker_threads');
  const w = new Worker('require("node:worker_threads").parentPort.postMessage(7*6)', { eval: true });
  w.once('message', (m) => (m === 42 ? resolve() : reject(new Error('got ' + m))));
  w.once('error', reject);
}));
req('ES modules (dynamic import of a data: URL)', async () => {
  const m = await import('data:text/javascript,export default 42');
  assert(m.default === 42);
});
if (npmArg) req('npm is bundled', () => {
  const dir = npmArg.slice('--npm='.length);
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
  assert(pkg.name === 'npm' && fs.existsSync(path.join(dir, 'bin', 'npm-cli.js')), 'npm files missing in ' + dir);
  const r = cp.spawnSync(process.execPath, [path.join(dir, 'bin', 'npm-cli.js'), '--version'], { encoding: 'utf8', env: { ...process.env, HOME: process.env.HOME || os.tmpdir() } });
  assert(r.status === 0 && r.stdout.trim() === pkg.version, r.stderr || r.stdout);
});

opt('Temporal (Node 26+ only; disabled in these builds)', () => assert(typeof Temporal !== 'undefined', 'not available'));
opt('node:sqlite', () => { require('node:sqlite'); });

(async () => {
  let failed = 0;
  console.log(`node ${process.version} ${process.platform}/${process.arch} v8 ${process.versions.v8}`);
  for (const [name, fn] of required) {
    try { await fn(); console.log('PASS ' + name); }
    catch (e) { failed++; console.log('FAIL ' + name + ': ' + (e && e.message)); }
  }
  for (const [name, fn] of optional) {
    try { await fn(); console.log('info ' + name + ': yes'); }
    catch (e) { console.log('info ' + name + ': no (' + (e && e.message) + ')'); }
  }
  console.log(failed ? `RESULT: ${failed} required check(s) FAILED` : 'RESULT: OK');
  process.exit(failed ? 1 : 0);
})();
