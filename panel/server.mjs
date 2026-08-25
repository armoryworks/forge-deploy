#!/usr/bin/env node
// forge-panel — a single-file, zero-dependency local web panel for one Forge
// install. It is a thin shell over scripts/forge-deploy: every button runs the
// same gated CLI an operator would (backup -> schema reconcile -> swap ->
// health gate -> audit log), so the panel can never bypass an invariant the
// CLI enforces. Installed as a systemd service by scripts/install-forge-panel.sh.
//
// Security model: bearer token (X-Panel-Token) required on every /api call,
// generated at install time and stored in /etc/forge/panel.token. The page
// itself contains no secrets. Intended for LAN access on the client's box —
// never proxy it through the public edge.

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { createHash, timingSafeEqual } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CLI = join(REPO_ROOT, 'scripts', 'forge-deploy');
const STATE_FILE = '/etc/forge/deploy-state.json';
const TOKEN = (process.env.PANEL_TOKEN
  ?? (existsSync('/etc/forge/panel.token') ? readFileSync('/etc/forge/panel.token', 'utf8') : '')).trim();
const PORT = Number(process.env.PANEL_PORT ?? 8484);
const RUN_TIMEOUT_MS = 30 * 60 * 1000;

if (!TOKEN) {
  console.error('forge-panel: no token (PANEL_TOKEN or /etc/forge/panel.token) — refusing to start');
  process.exit(1);
}

// Every runnable action maps to a fixed CLI argv — nothing from the request
// ever reaches the command line.
const ACTIONS = {
  status:  { argv: ['--status'] },
  check:   { argv: ['--update', '--check'] },
  update:  { argv: ['--update'] },
  approve: { argv: ['--update', '--allow-destructive'], confirm: 'APPLY' },
  logs:    { argv: ['--logs'] },
  ps:      { argv: ['compose', 'ps'] },
};

let running = null; // { action, startedAt, child }

const sha = (s) => createHash('sha256').update(s, 'utf8').digest();
function authorized(req) {
  const got = req.headers['x-panel-token'];
  return typeof got === 'string' && timingSafeEqual(sha(got), sha(TOKEN));
}

function json(res, code, body) {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': buf.length });
  res.end(buf);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 65536) req.destroy(); });
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}); } catch { resolve({}); } });
    req.on('error', reject);
  });
}

function run(argv) {
  return spawn('bash', [CLI, ...argv], {
    cwd: REPO_ROOT,
    env: { ...process.env, FORCE_COLOR: '0', NO_COLOR: '1', TERM: 'dumb' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function collect(cmd, args, timeoutMs = 15000) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { cwd: REPO_ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    const t = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.stdout.on('data', (d) => { out += d; });
    child.on('close', () => { clearTimeout(t); resolve(out); });
    child.on('error', () => { clearTimeout(t); resolve(''); });
  });
}

async function stateSnapshot() {
  let state = {};
  try { state = JSON.parse(readFileSync(STATE_FILE, 'utf8')); } catch { /* absent is fine */ }
  const psRaw = await collect('docker', ['ps', '-a', '--format', '{{json .}}']);
  const containers = psRaw.split('\n').filter(Boolean).flatMap((l) => {
    try {
      const c = JSON.parse(l);
      return c.Names?.startsWith('forge') ? [{ name: c.Names, image: c.Image, status: c.Status, ports: c.Ports ?? '' }] : [];
    } catch { return []; }
  });
  return { state, containers, running: running ? { action: running.action, startedAt: running.startedAt } : null };
}

const HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Forge Panel</title>
<style>
  :root { --bg:#10141a; --card:#1a2029; --line:#2b3442; --text:#dbe4f0; --dim:#8494a8;
          --ok:#3fca7c; --warn:#e8b23e; --bad:#e2634f; --accent:#4f8ff0; }
  * { box-sizing:border-box; margin:0; }
  body { background:var(--bg); color:var(--text); font:15px/1.5 system-ui,sans-serif; padding:1.2rem; }
  .wrap { max-width:920px; margin:0 auto; display:flex; flex-direction:column; gap:1rem; }
  h1 { font-size:1.15rem; display:flex; align-items:center; gap:.5rem; }
  h1 small { color:var(--dim); font-weight:400; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem; }
  table { width:100%; border-collapse:collapse; font-size:.92rem; }
  th,td { text-align:left; padding:.3rem .6rem .3rem 0; vertical-align:top; }
  th { color:var(--dim); font-weight:500; }
  .chip { display:inline-block; padding:.05rem .55rem; border-radius:99px; font-size:.8rem; }
  .chip.ok { background:#12351f; color:var(--ok); } .chip.bad { background:#3a1712; color:var(--bad); }
  .chip.warn { background:#372a10; color:var(--warn); }
  .btns { display:flex; flex-wrap:wrap; gap:.6rem; }
  button { background:var(--accent); border:0; border-radius:8px; color:#fff; font:600 .92rem system-ui;
           padding:.55rem 1rem; cursor:pointer; }
  button.secondary { background:#28303c; color:var(--text); }
  button.danger { background:var(--bad); }
  button:disabled { opacity:.45; cursor:not-allowed; }
  #out { background:#0a0d12; border:1px solid var(--line); border-radius:8px; padding:.8rem;
         font:12.5px/1.45 ui-monospace,monospace; white-space:pre-wrap; overflow-x:auto;
         max-height:26rem; overflow-y:auto; min-height:8rem; }
  #approveBox { display:none; border:1px solid var(--warn); border-radius:8px; padding:1rem; margin-top:.8rem; }
  #approveBox input { background:#0a0d12; border:1px solid var(--line); border-radius:6px; color:var(--text);
                      font:600 1rem ui-monospace,monospace; padding:.4rem .6rem; width:9rem; }
  .hint { color:var(--dim); font-size:.85rem; }
  dialog { background:var(--card); color:var(--text); border:1px solid var(--line); border-radius:10px; padding:1.2rem; }
  dialog::backdrop { background:#000a; }
</style></head><body><div class="wrap">
<h1>&#128296; Forge Panel <small id="host"></small></h1>

<div class="card">
  <table id="tbl"><thead><tr><th>container</th><th>version</th><th>state</th><th>ports</th></tr></thead>
  <tbody></tbody></table>
  <p class="hint" id="stamp"></p>
</div>

<div class="card">
  <div class="btns">
    <button id="b-check">Check for updates</button>
    <button id="b-update">Upgrade to newest</button>
    <button id="b-status" class="secondary">Deploy status</button>
    <button id="b-ps" class="secondary">Containers</button>
    <button id="b-logs" class="secondary">Deploy log</button>
  </div>
  <div id="approveBox">
    <p><strong style="color:var(--warn)">The upgrade stopped because it would apply destructive schema
    changes</strong> — they are listed in the output below. If the backup completed and you accept losing
    what those statements remove, type <code>APPLY</code> and continue.</p>
    <p style="margin-top:.6rem; display:flex; gap:.6rem; align-items:center;">
      <input id="confirmWord" placeholder="APPLY" autocomplete="off">
      <button id="b-approve" class="danger">Approve &amp; continue upgrade</button>
    </p>
  </div>
  <div id="out" style="margin-top:.8rem">Ready.</div>
</div>

<dialog id="tokDlg"><form method="dialog">
  <p style="margin-bottom:.6rem">Enter the panel token (printed when the panel was installed;<br>
  also in <code>/etc/forge/panel.token</code> on the server):</p>
  <p style="display:flex;gap:.6rem"><input id="tokIn" style="flex:1;background:#0a0d12;border:1px solid var(--line);
  border-radius:6px;color:var(--text);padding:.4rem .6rem" autocomplete="off"><button>Save</button></p>
</form></dialog>
</div><script>
const $ = (id) => document.getElementById(id);
$('host').textContent = location.host;
let token = localStorage.getItem('panelToken') || '';
const dlg = $('tokDlg');
dlg.addEventListener('close', () => { token = $('tokIn').value.trim(); localStorage.setItem('panelToken', token); refresh(); });
if (!token) dlg.showModal();

const H = () => ({ 'x-panel-token': token, 'content-type': 'application/json' });
let busy = false;

async function refresh() {
  if (!token) return;
  try {
    const r = await fetch('/api/state', { headers: H() });
    if (r.status === 401) { dlg.showModal(); return; }
    const d = await r.json();
    const rows = d.containers.map((c) => {
      const up = /Up/.test(c.status), healthy = /healthy/.test(c.status), sick = /unhealthy|Restarting/.test(c.status);
      const cls = sick ? 'bad' : (healthy || up) ? 'ok' : 'warn';
      const ver = (c.image.split(':')[1] || '').replace('1.0.0-','');
      return '<tr><td>' + c.name + '</td><td>' + ver + '</td><td><span class="chip ' + cls + '">'
        + c.status.replace(/\\s*\\(.*\\)/, m => m) + '</span></td><td class="hint">' + c.ports + '</td></tr>';
    }).join('');
    document.querySelector('#tbl tbody').innerHTML = rows || '<tr><td colspan=4 class="hint">no forge containers found</td></tr>';
    $('stamp').textContent = d.running ? ('running: ' + d.running.action + ' (started ' + d.running.startedAt + ')')
                                       : ('refreshed ' + new Date().toLocaleTimeString());
    setBusy(!!d.running);
  } catch { $('stamp').textContent = 'panel unreachable'; }
}
function setBusy(b) {
  busy = b;
  for (const id of ['b-check','b-update','b-status','b-ps','b-logs','b-approve']) $(id).disabled = b;
}
async function act(action, confirm) {
  if (busy) return;
  setBusy(true);
  $('approveBox').style.display = 'none';
  const out = $('out'); out.textContent = '$ forge-deploy ' + action + '\\n';
  try {
    const r = await fetch('/api/run', { method: 'POST', headers: H(), body: JSON.stringify({ action, confirm }) });
    if (r.status === 401) { dlg.showModal(); setBusy(false); return; }
    if (!r.ok && !r.body) { out.textContent += 'error: HTTP ' + r.status; setBusy(false); return; }
    const reader = r.body.getReader(); const dec = new TextDecoder();
    let all = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = dec.decode(value, { stream: true });
      all += chunk; out.textContent += chunk; out.scrollTop = out.scrollHeight;
    }
    if (action === 'update' && /DESTRUCTIVE|destructive/.test(all) && /halt|HALT|refus|blocked/i.test(all)) {
      $('approveBox').style.display = 'block';
    }
  } catch (e) { out.textContent += '\\n[connection lost: ' + e.message + ']'; }
  setBusy(false); refresh();
}
$('b-check').onclick  = () => act('check');
$('b-update').onclick = () => act('update');
$('b-status').onclick = () => act('status');
$('b-ps').onclick     = () => act('ps');
$('b-logs').onclick   = () => act('logs');
$('b-approve').onclick = () => {
  if ($('confirmWord').value.trim() !== 'APPLY') { $('confirmWord').focus(); return; }
  act('approve', 'APPLY'); $('confirmWord').value = '';
};
refresh(); setInterval(refresh, 10000);
</script></body></html>`;

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (req.method === 'GET' && url.pathname === '/') {
    const buf = Buffer.from(HTML);
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'content-length': buf.length });
    return res.end(buf);
  }
  if (!url.pathname.startsWith('/api/')) return json(res, 404, { error: 'not found' });
  if (!authorized(req)) return json(res, 401, { error: 'bad token' });

  if (req.method === 'GET' && url.pathname === '/api/state') {
    return json(res, 200, await stateSnapshot());
  }

  if (req.method === 'POST' && url.pathname === '/api/run') {
    const body = await readBody(req);
    const spec = ACTIONS[body.action];
    if (!spec) return json(res, 400, { error: 'unknown action' });
    if (spec.confirm && body.confirm !== spec.confirm) return json(res, 400, { error: `confirmation word required: ${spec.confirm}` });
    if (running) return json(res, 409, { error: `busy: ${running.action} still running` });

    res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'x-accel-buffering': 'no' });
    const child = run(spec.argv);
    running = { action: body.action, startedAt: new Date().toISOString(), child };
    const timer = setTimeout(() => child.kill('SIGKILL'), RUN_TIMEOUT_MS);
    const strip = (b) => b.toString().replace(/\x1b\[[0-9;]*m/g, '');
    child.stdout.on('data', (d) => res.write(strip(d)));
    child.stderr.on('data', (d) => res.write(strip(d)));
    child.on('close', (code) => {
      clearTimeout(timer);
      running = null;
      res.end(`\n[exit ${code}]${code === 10 ? ' — updates are available' : code === 0 ? ' — success' : ''}\n`);
    });
    req.on('close', () => { /* keep running; panel state endpoint reports it */ });
    return;
  }
  return json(res, 404, { error: 'not found' });
});

server.listen(PORT, () => {
  console.log(`forge-panel listening on :${PORT} (repo: ${REPO_ROOT})`);
});
