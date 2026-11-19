// Measure YOUR PC as the benchmark reference, then bake it into probe.ps1's bench page.
//   node tools/ref.ts                 # Chromium, default GPU
//   BROWSER=google-chrome node tools/ref.ts
//   prime-run node tools/ref.ts       # e.g. force the discrete GPU
// Opens a Chromium window for ~30 s; closes it by itself. No dependencies.
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { spawn, type ChildProcess } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ps1Path = join(dirname(fileURLToPath(import.meta.url)), '..', 'probe.ps1');
const ps1 = readFileSync(ps1Path, 'utf8');
const m = ps1.match(/\$script:BenchHtml = @'\r?\n([\s\S]*?)\r?\n'@/);
if (!m) throw new Error('bench page not found in probe.ps1');
const page = m[1].replace(/const BASE = .*;/, 'const BASE = null;');

const profile = mkdtempSync(join(tmpdir(), 'prober-ref-'));
let child: ChildProcess | undefined;

const server = createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/result') {
    let body = '';
    req.on('data', c => (body += c));
    req.on('end', () => { res.end('ok'); done(JSON.parse(body)); });
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(page);
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address() as { port: number };
  child = spawn(process.env.BROWSER ?? 'chromium',
    [`--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', '--window-size=900,700', `--app=http://127.0.0.1:${port}/`],
    { stdio: 'ignore' });
  console.log(`benchmarking in ${process.env.BROWSER ?? 'chromium'} (~30 s, keep the window in front)...`);
});

function done(r: Record<string, number | string>) {
  const num = (k: string) => Math.round(Number(r[k]) * 100) / 100;
  const base = {
    cpu1: num('cpu1'), cpuN: num('cpuN'), mem: num('mem'), gpu: num('gpu'),
    name: 'my PC', // never write hardware details: probe.ps1 may be public
    date: new Date().toISOString().slice(0, 10),
  };
  writeFileSync(ps1Path, ps1.replace(/const BASE = .*;/, `const BASE = ${JSON.stringify(base)};`));
  console.log('reference written to probe.ps1:', base);
  child?.kill();
  server.close();
  setTimeout(() => rmSync(profile, { recursive: true, force: true }), 1500);
}
