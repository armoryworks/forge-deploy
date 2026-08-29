#!/usr/bin/env node
// forge-agent — headless, privileged job runner for one Forge box.
//
// It is the executor half of the self-service upgrade path: forge-api decides
// (who may upgrade, what was approved, what gets audited), this agent executes.
// Every action maps to a FIXED argv against scripts/forge-deploy, so the agent
// can never bypass an invariant that script enforces.
//
// It runs as a systemd service on the host — NOT in a container — because the
// containers it replaces include the ones serving the UI that started the job.
// Jobs are detached and disk-backed for the same reason: the deploy must
// outlive both the caller's connection and a restart of this process.
//
// Security model: shared secret (X-Forge-Agent-Token) on every route except
// /health, generated at install time into /etc/forge/agent.token. The browser
// never holds this token — only forge-api does. Binds loopback unless the box
// is a coordinator peer. Never proxy it through the public edge.

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import {
  readFileSync, writeFileSync, existsSync, mkdirSync, openSync, closeSync,
  readdirSync, statSync, createReadStream, rmSync, readSync, appendFileSync,
} from 'node:fs';
import { createHash, timingSafeEqual, randomUUID } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const AGENT_VERSION = '0.1.0';
const REPO_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const CLI = join(REPO_ROOT, 'scripts', 'forge-deploy');
// Same override the CLI honours. The two must agree on where deploy state
// lives, or the agent reports "no recorded version" for tiers the CLI just
// deployed.
const STATE_FILE = process.env.FORGE_STATE_DIR
  ? join(process.env.FORGE_STATE_DIR, 'deploy-state.json')
  : '/etc/forge/deploy-state.json';
const JOBS_DIR = process.env.FORGE_AGENT_JOBS_DIR ?? '/var/lib/forge-agent/jobs';
// Read by forge-ui (mounted read-only, served as /upgrade-status.json) so a
// browser can tell "Forge is upgrading" from "Forge is down" without the API.
// nginx serves it unauthenticated, to shop-floor tablets and the login screen
// alike, so it carries the generic envelope ONLY — never a tag, an action name,
// a job id, or log text. Operator detail goes over the authenticated API path.
const MARKER_FILE = process.env.FORGE_AGENT_MARKER ?? join(dirname(JOBS_DIR), 'upgrade.json');
const PORT = Number(process.env.FORGE_AGENT_PORT ?? 8484);
const BIND = process.env.FORGE_AGENT_BIND ?? '127.0.0.1';
const SYNC_TIMEOUT_MS = 60_000;
const KEEP_JOBS = 20;

const readTokenFile = (p) => (existsSync(p) ? readFileSync(p, 'utf8').trim() : '');
const TOKEN = (process.env.FORGE_AGENT_TOKEN
  || readTokenFile('/etc/forge/agent.token')
  || readTokenFile('/etc/forge/panel.token')).trim();

if (!TOKEN) {
  console.error('forge-agent: no token (FORGE_AGENT_TOKEN or /etc/forge/agent.token) — refusing to start');
  process.exit(1);
}

const SERVICE_IDS = ['api', 'ui', 'test', 'demo'];
const TAG_RE = /^(main-[a-f0-9]{7}|[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?)$/;

// Synchronous, read-only. Exit codes are meaningful: --update --check returns
// 10 when the box is behind, which is a result, not a failure.
const SYNC_ACTIONS = {
  status:     ['--status'],
  components: ['--components'],
  list:       ['--list'],
  check:      ['--update', '--check'],
  logs:       ['--logs'],
};

// Long-running, state-changing. Each becomes a job of one or more sequential steps.
// fanOut marks the actions that continue onto peer boxes after the local box is done.
const JOB_ACTIONS = {
  update:        { argv: () => ['--update'], fanOut: true },
  updateApprove: { argv: () => ['--update', '--allow-destructive'], confirm: 'APPLY', fanOut: true },
  rollback:      { argv: ({ svc }) => (svc ? ['--rollback', svc] : ['--rollback']) },
  deployService: { argv: ({ svc, tag }) => [tag, '--service', svc], needs: ['svc', 'tag'] },
};

// Peer boxes, from FORGE_PEER_AGENTS in .env: "ui=http://192.168.1.92:8484 db=http://..."
// Only the coordinator (the box running the API) has these; a peer's own list is empty, which is
// what stops two boxes from dispatching to each other.
function peers() {
  return (envGet('FORGE_PEER_AGENTS') || '')
    .split(/[,\s]+/)
    .filter(Boolean)
    .flatMap((entry) => {
      const eq = entry.indexOf('=');
      if (eq < 1) return [];
      const name = entry.slice(0, eq).trim();
      const url = entry.slice(eq + 1).trim().replace(/\/+$/, '');
      return /^https?:\/\//.test(url) ? [{ name, url }] : [];
    });
}

// Exact names, not a `forge` prefix: compose sets container_name for this
// stack, and a prefix match also swallows unrelated projects' containers
// (an e2e run's forge-deploy-forge-api-1) into this install's inventory.
const STACK_CONTAINERS = new Set([
  'forge', 'forge-api', 'forge-ui', 'forge-ui-b', 'forge-storage', 'forge-backup',
  'forge-demo', 'forge-test', 'forge-ai', 'forge-tts', 'forge-logs', 'forge-signing',
  'forge-crash', 'forge-crash-worker', 'forge-crash-db', 'forge-crash-cache',
]);

const HALT_RE = /DESTRUCTIVE schema changes detected/;
const PREMIGRATE_RE = /pre-migrate script\(s\) were already applied/i;

// ─────────────────────────────────────────────────────────────
// Job store
// ─────────────────────────────────────────────────────────────

mkdirSync(JOBS_DIR, { recursive: true });
mkdirSync(dirname(MARKER_FILE), { recursive: true });

const jobDir  = (id) => join(JOBS_DIR, id);
const metaPath = (id) => join(jobDir(id), 'meta.json');
const logPath  = (id) => join(jobDir(id), 'log');

function readMeta(id) {
  try { return JSON.parse(readFileSync(metaPath(id), 'utf8')); } catch { return null; }
}

function writeMeta(meta) {
  writeFileSync(metaPath(meta.id), JSON.stringify(meta, null, 2));
}

// A lock nobody can clear is worse than no lock: if this process dies holding
// the marker, expiresAt is what lets every console release itself.
function markerTtlMs() {
  const raw = envGet('HEALTHCHECK_TIMEOUT_SECS');
  const secs = /^[1-9][0-9]*$/.test(raw) ? Number(raw) : 300;
  return (secs * SERVICE_IDS.length + 300) * 1000;
}

function writeMarker(meta) {
  const running = meta.state === 'running';
  const body = {
    state: running ? 'running' : meta.state === 'succeeded' ? 'succeeded' : 'stopped',
    startedAt: meta.startedAt,
    endedAt: meta.endedAt,
    expiresAt: new Date(Date.parse(meta.startedAt) + markerTtlMs()).toISOString(),
    message: running
      ? 'Forge is being updated. This screen will come back on its own.'
      : null,
  };
  try { writeFileSync(MARKER_FILE, JSON.stringify(body, null, 2)); } catch { /* best effort */ }
}

function envGet(key) {
  try {
    const line = readFileSync(join(REPO_ROOT, '.env'), 'utf8')
      .split('\n').find((l) => l.startsWith(`${key}=`));
    return line ? line.slice(key.length + 1).trim() : '';
  } catch { return ''; }
}

function alive(pid) {
  if (!pid) return false;
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function tailLog(id, max = 64 * 1024) {
  try {
    const size = statSync(logPath(id)).size;
    const start = Math.max(0, size - max);
    const fd = openSync(logPath(id), 'r');
    const buf = Buffer.alloc(size - start);
    try { readSync(fd, buf, 0, buf.length, start); } finally { closeSync(fd); }
    return buf.toString('utf8');
  } catch { return ''; }
}

// The CLI prints destructive DDL as "  <n> - <statement>" under a halt banner
// (enumerate_destructive). Parse it so the browser renders a list rather than
// scraped text; the operator's disposition happens against these lines.
function parseDestructive(text) {
  if (!HALT_RE.test(text)) return null;
  const statements = [];
  for (const line of text.split('\n')) {
    const m = line.replace(/\x1b\[[0-9;]*m/g, '').match(/^\s{2,}(\d+)\s+-\s+(\S.*)$/);
    if (m) statements.push({ n: Number(m[1]), statement: m[2].trim() });
  }
  return {
    statements,
    preMigrateCommitted: PREMIGRATE_RE.test(text),
    dispositions: ['ok to delete', 'cannot until x,y,z', 'cannot delete'],
  };
}

// ── Step machine ────────────────────────────────────────────
// A job is a sequence of steps run strictly in order: the local box first, then
// each peer box. Ordering is the point — schema and API must land before a UI
// box is told to move, or the shop gets a new UI talking to an old API.
//
// Every step's outcome is recovered from disk (a local step's exit file, a peer
// step's job id), never from an in-process event. That is what lets the agent be
// killed mid-upgrade and pick the job back up on restart.

const stepExitPath = (id, i) => join(jobDir(id), `exit.${i}`);

function terminal(state) {
  return state === 'succeeded' || state === 'failed' || state === 'halted-destructive';
}

function appendLog(id, text) {
  try { appendFileSync(logPath(id), text); } catch { /* best effort */ }
}

// A local step reads its own exit file. Absent file plus dead pid means the
// process vanished without recording an outcome — reported as unknown rather
// than guessed, because "probably fine" is not a thing to say about a deploy.
function settleLocalStep(meta, step, i) {
  const path = stepExitPath(meta.id, i);
  if (existsSync(path)) {
    const code = Number(readFileSync(path, 'utf8').trim());
    const destructive = code !== 0 ? parseDestructive(tailLog(meta.id)) : null;
    step.exitCode = Number.isFinite(code) ? code : null;
    step.state = code === 0 ? 'succeeded' : destructive ? 'halted-destructive' : 'failed';
    if (destructive) meta.needsApproval = destructive;
    return true;
  }
  if (!alive(step.pid)) {
    step.state = 'failed';
    step.reason = 'agent-restarted: outcome unknown, check the deploy log';
    return true;
  }
  return false;
}

function startLocalStep(meta, step, i) {
  const fd = openSync(logPath(meta.id), 'a');
  const child = spawn('bash', ['-c', WRAPPER, 'forge-agent', ...step.argv], {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      FORGE_CLI: CLI,
      FORGE_EXIT_FILE: stepExitPath(meta.id, i),
      FORCE_COLOR: '0',
      NO_COLOR: '1',
      TERM: 'dumb',
    },
    detached: true,
    stdio: ['ignore', fd, fd],
  });
  closeSync(fd);
  child.unref();
  step.pid = child.pid;
  step.startedAt = new Date().toISOString();
}

async function peerFetch(step, path, init = {}) {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), 20_000);
  try {
    return await fetch(`${step.url}${path}`, {
      ...init,
      signal: controller.signal,
      headers: { 'content-type': 'application/json', 'x-forge-agent-token': TOKEN, ...(init.headers ?? {}) },
    });
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

// A peer step owns a job on another box. Its log is pulled in by offset so the
// coordinator's log reads as one upgrade rather than as a box that went quiet.
async function advancePeerStep(meta, step) {
  if (!step.jobId) {
    const response = await peerFetch(step, '/jobs', {
      method: 'POST',
      body: JSON.stringify({ action: 'update' }),
    });
    if (!response) {
      step.state = 'failed';
      step.reason = `cannot reach the ${step.peer} box at ${step.url}`;
      appendLog(meta.id, `\n    [XX] ${step.reason}\n`);
      return true;
    }
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      step.state = 'failed';
      step.reason = body.error ?? `the ${step.peer} box refused the job (HTTP ${response.status})`;
      appendLog(meta.id, `\n    [XX] ${step.reason}\n`);
      return true;
    }
    step.jobId = body.id;
    step.startedAt = new Date().toISOString();
    appendLog(meta.id, `\n==> Continuing on the ${step.peer} box (${step.url})\n`);
    return false;
  }

  const log = await peerFetch(step, `/jobs/${step.jobId}/log?offset=${step.logOffset ?? 0}`);
  if (log?.ok) {
    const text = await log.text();
    if (text) {
      appendLog(meta.id, text);
      step.logOffset = Number(log.headers.get('x-forge-log-offset') ?? (step.logOffset ?? 0) + text.length);
    }
  }

  const response = await peerFetch(step, `/jobs/${step.jobId}`);
  if (!response?.ok) return false;   // a peer rebooting its own UI container is expected
  const job = await response.json().catch(() => null);
  if (!job || !terminal(job.state)) return false;

  step.state = job.state;
  step.exitCode = job.exitCode ?? null;
  if (job.needsApproval) meta.needsApproval = job.needsApproval;
  return true;
}

function finishJob(meta) {
  const states = meta.steps.map((s) => s.state);
  meta.state = states.includes('halted-destructive') ? 'halted-destructive'
    : states.every((x) => x === 'succeeded') ? 'succeeded'
    : 'failed';

  // A cross-box upgrade that got partway is not the same as one that failed at
  // the start, and the screen has to be able to say which boxes moved.
  const done = meta.steps.filter((s) => s.state === 'succeeded').map((s) => s.peer ?? 'this box');
  const stuck = meta.steps.filter((s) => s.state && s.state !== 'succeeded').map((s) => s.peer ?? 'this box');
  if (meta.state !== 'succeeded' && done.length) {
    meta.partial = { completed: done, incomplete: stuck };
    meta.reason ??= `partial upgrade: ${done.join(', ')} completed, ${stuck.join(', ')} did not`;
  }
  meta.exitCode = meta.steps.at(-1)?.exitCode ?? null;
  meta.endedAt = new Date().toISOString();
  writeMeta(meta);
  writeMarker(meta);
}

const supervising = new Set();

async function supervise(id) {
  if (supervising.has(id)) return;
  supervising.add(id);
  try {
    for (;;) {
      const meta = readMeta(id);
      if (!meta || meta.state !== 'running') return;

      const i = meta.steps.findIndex((s) => !terminal(s.state));
      if (i === -1) { finishJob(meta); return; }

      const step = meta.steps[i];
      let advanced;
      if (step.kind === 'local') {
        if (!step.pid) { startLocalStep(meta, step, i); advanced = false; }
        else advanced = settleLocalStep(meta, step, i);
      } else {
        advanced = await advancePeerStep(meta, step);
      }
      writeMeta(meta);

      // A failed step stops the sequence. Rolling on would deploy a UI against
      // an API that never came up.
      if (advanced && step.state !== 'succeeded') { finishJob(meta); return; }

      await new Promise((r) => setTimeout(r, 1000));
    }
  } finally {
    supervising.delete(id);
  }
}

function listJobs() {
  let ids;
  try { ids = readdirSync(JOBS_DIR); } catch { return []; }
  return ids
    .map(readMeta)
    .filter(Boolean)
    .sort((a, b) => (a.startedAt < b.startedAt ? 1 : -1));
}

function prune() {
  for (const meta of listJobs().slice(KEEP_JOBS)) {
    try { rmSync(jobDir(meta.id), { recursive: true, force: true }); } catch { /* best effort */ }
  }
}

function currentJob() {
  return listJobs().find((m) => m.state === 'running') ?? null;
}

// ─────────────────────────────────────────────────────────────
// Execution
// ─────────────────────────────────────────────────────────────

function runSync(argv) {
  return new Promise((resolve) => {
    const child = spawn('bash', [CLI, ...argv], {
      cwd: REPO_ROOT,
      env: { ...process.env, FORCE_COLOR: '0', NO_COLOR: '1', TERM: 'dumb' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    let timedOut = false;
    const t = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, SYNC_TIMEOUT_MS);
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('close', (code) => {
      clearTimeout(t);
      resolve({ exitCode: timedOut ? null : code, output: out.replace(/\x1b\[[0-9;]*m/g, ''), timedOut });
    });
    child.on('error', (e) => { clearTimeout(t); resolve({ exitCode: null, output: String(e), timedOut: false }); });
  });
}

// The wrapper is a constant; every caller-supplied value arrives positionally
// via "$@" and is never interpolated into a shell string.
const WRAPPER = '"$FORGE_CLI" "$@"; code=$?; printf %s "$code" > "$FORGE_EXIT_FILE"; exit $code';

// Local box first, then each peer in the order .env lists them. The coordinator
// is the box running the API, because it owns the schema reconcile and is the
// only agent forge-api can reach from inside a container.
function planSteps(action, svc, tag) {
  const spec = JOB_ACTIONS[action];
  const steps = [{ kind: 'local', argv: spec.argv({ svc, tag }), state: null }];
  if (spec.fanOut) {
    for (const p of peers()) steps.push({ kind: 'peer', peer: p.name, url: p.url, state: null });
  }
  return steps;
}

function startJob({ action, svc, tag }) {
  const id = randomUUID();
  mkdirSync(jobDir(id), { recursive: true });
  const meta = {
    id, action, svc: svc ?? null, tag: tag ?? null,
    steps: planSteps(action, svc, tag),
    state: 'running', exitCode: null,
    startedAt: new Date().toISOString(), endedAt: null,
    needsApproval: null, reason: null, partial: null,
  };
  writeMeta(meta);
  writeMarker(meta);
  supervise(id);
  prune();
  return meta;
}

// ─────────────────────────────────────────────────────────────
// HTTP
// ─────────────────────────────────────────────────────────────

const sha = (s) => createHash('sha256').update(s, 'utf8').digest();
const authorized = (req) => {
  const got = req.headers['x-forge-agent-token'];
  return typeof got === 'string' && timingSafeEqual(sha(got), sha(TOKEN));
};

function json(res, code, body) {
  const buf = Buffer.from(JSON.stringify(body));
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': buf.length });
  res.end(buf);
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', (c) => { data += c; if (data.length > 65536) req.destroy(); });
    req.on('end', () => { try { resolve(data ? JSON.parse(data) : {}); } catch { resolve({}); } });
    req.on('error', () => resolve({}));
  });
}

function collectDocker(args, timeoutMs = 15000) {
  return new Promise((resolve) => {
    const child = spawn('docker', args, { cwd: REPO_ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
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
  const raw = await collectDocker(['ps', '-a', '--format', '{{json .}}']);
  const containers = raw.split('\n').filter(Boolean).flatMap((l) => {
    try {
      const c = JSON.parse(l);
      return STACK_CONTAINERS.has(c.Names)
        ? [{ name: c.Names, image: c.Image, status: c.Status, ports: c.Ports ?? '' }]
        : [];
    } catch { return []; }
  });
  const running = currentJob();
  return {
    agentVersion: AGENT_VERSION,
    peers: peers().map((p) => ({ name: p.name, url: p.url })),
    state,
    containers,
    running: running ? { id: running.id, action: running.action, startedAt: running.startedAt } : null,
  };
}

function publicJob(meta) {
  const { id, action, svc, tag, state, exitCode, startedAt, endedAt, needsApproval, reason, partial } = meta;
  const steps = (meta.steps ?? []).map((s) => ({
    box: s.peer ?? 'local',
    state: s.state ?? 'pending',
    exitCode: s.exitCode ?? null,
    reason: s.reason ?? null,
  }));
  let logSize = 0;
  try { logSize = statSync(logPath(id)).size; } catch { /* not yet written */ }
  return { id, action, svc, tag, state, exitCode, startedAt, endedAt, needsApproval, reason, partial, steps, logSize };
}

function validateJobRequest(body) {
  const spec = JOB_ACTIONS[body.action];
  if (!spec) return { error: 'unknown action' };
  if (spec.confirm && body.confirm !== spec.confirm) {
    return { error: `confirmation word required: ${spec.confirm}` };
  }
  const needs = spec.needs ?? [];
  const svc = body.svc ?? null;
  const tag = body.tag ?? null;
  if ((needs.includes('svc') || svc !== null) && !SERVICE_IDS.includes(svc)) {
    return { error: `svc must be one of: ${SERVICE_IDS.join(', ')}` };
  }
  if (needs.includes('tag') && (typeof tag !== 'string' || !TAG_RE.test(tag))) {
    return { error: 'tag must be X.Y.Z, X.Y.Z-suffix, or main-<7hex>' };
  }
  return { action: body.action, svc, tag };
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const path = url.pathname;

  if (req.method === 'GET' && path === '/health') {
    return json(res, 200, { ok: true, agentVersion: AGENT_VERSION, repoRoot: REPO_ROOT });
  }
  if (!authorized(req)) return json(res, 401, { error: 'bad token' });

  if (req.method === 'GET' && path === '/state') {
    return json(res, 200, await stateSnapshot());
  }

  if (req.method === 'POST' && path === '/actions') {
    const body = await readBody(req);
    const argv = SYNC_ACTIONS[body.action];
    if (!argv) return json(res, 400, { error: 'unknown action' });
    const result = await runSync(argv);
    return json(res, 200, { action: body.action, ...result });
  }

  if (req.method === 'POST' && path === '/jobs') {
    const body = await readBody(req);
    const parsed = validateJobRequest(body);
    if (parsed.error) return json(res, 400, { error: parsed.error });
    const busy = currentJob();
    if (busy) return json(res, 409, { error: `busy: ${busy.action} still running`, jobId: busy.id });
    return json(res, 202, publicJob(startJob(parsed)));
  }

  if (req.method === 'GET' && path === '/jobs') {
    return json(res, 200, { jobs: listJobs().map(publicJob) });
  }

  if (req.method === 'GET' && path === '/jobs/current') {
    const cur = currentJob();
    return json(res, 200, cur ? publicJob(cur) : null);
  }

  const jobMatch = path.match(/^\/jobs\/([0-9a-f-]{36})(\/log)?$/);
  if (req.method === 'GET' && jobMatch) {
    const meta = readMeta(jobMatch[1]);
    if (!meta) return json(res, 404, { error: 'no such job' });
    if (!jobMatch[2]) return json(res, 200, publicJob(meta));

    const offset = Math.max(0, Number(url.searchParams.get('offset') ?? 0) || 0);
    let size = 0;
    try { size = statSync(logPath(meta.id)).size; } catch { /* not yet written */ }
    res.writeHead(200, {
      'content-type': 'text/plain; charset=utf-8',
      'x-forge-log-offset': String(size),
      'x-accel-buffering': 'no',
    });
    if (offset >= size) return res.end();
    return createReadStream(logPath(meta.id), { start: offset, end: size - 1 })
      .on('error', () => res.end())
      .pipe(res);
  }

  return json(res, 404, { error: 'not found' });
});

// Pick any job a previous process left running back up before accepting work.
for (const meta of listJobs()) if (meta.state === 'running') supervise(meta.id);

server.listen(PORT, BIND, () => {
  console.log(`forge-agent ${AGENT_VERSION} listening on ${BIND}:${PORT} (repo: ${REPO_ROOT}, jobs: ${JOBS_DIR})`);
});
