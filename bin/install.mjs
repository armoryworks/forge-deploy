#!/usr/bin/env node
// Bootstrapper for the Forge deploy tree. The npm package is a thin pointer:
// it downloads a PINNED RELEASE of armoryworks/forge-deploy from GitHub into a
// target directory, then hands off to setup.sh (or setup.ps1 on Windows).
// Republish only when this file or package.json changes.
//
// The tree ref is pinned, not `main`: a client running `upgrade` must get the
// tree that was tested with this bootstrapper, never whatever landed on main
// minutes earlier. FORGE_DEPLOY_REF overrides it for development.
//
// Usage:
//   npx @armoryworks/forge-deploy [target-dir] [--fetch-only] [setup flags...]
//   npx @armoryworks/forge-deploy upgrade [tag] [target-dir]
//   npx @armoryworks/forge-deploy recover [target-dir]
//
// `upgrade` refreshes the deploy tree, then hands off to the gated deploy path
// (scripts/forge-deploy <tag>, or --update when no tag is given): backup ->
// schema reconcile -> swap -> health gate -> auto-rollback.
//
// `recover` refreshes the tree, then runs the doctor (scripts/forge-deploy
// --recover): detect common failure modes and an incomplete setup, then
// fix-and-resume in place. Unlike `upgrade` it does NOT require a configured
// box — a half-finished install is exactly what it is for.
//
// With no arguments at all on a box that already runs Forge, the tree is
// located (state file, then the conventional directories) and the guided
// console opens on it in place — no download, no fresh-install wizard beside
// an existing install. FORGE_DEPLOY_DIR names the tree when it is somewhere
// else entirely.
//
// Otherwise the first argument not starting with "-" is the target directory
// (default ./forge-deploy). Every argument starting with "-" is passed
// through to setup.sh untouched (--source, --lan, --public, --ssl, ...),
// except --fetch-only, which downloads the tree and stops. Re-running in an
// existing directory refreshes the tracked files and preserves .env,
// docker-compose.override.yml, and volumes.

import { spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, chmodSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const PKG_VERSION = JSON.parse(
  readFileSync(join(dirname(dirname(fileURLToPath(import.meta.url))), 'package.json'), 'utf8'),
).version;

const DEFAULT_TREE_TAG = 'v0.8.1';

// Accept `v0.7.0`, `tags/v0.7.0`, or `heads/main` (development) alike.
const rawRef = (process.env.FORGE_DEPLOY_REF ?? DEFAULT_TREE_TAG).replace(/^refs\//, '');
const TREE_REF = /^(heads|tags)\//.test(rawRef) ? rawRef : `tags/${rawRef}`;
const TARBALL_URL = `https://codeload.github.com/armoryworks/forge-deploy/tar.gz/refs/${TREE_REF}`;

const args = process.argv.slice(2);
const positionals = args.filter((a) => !a.startsWith('-'));
const subcommand = positionals[0] === 'upgrade' || positionals[0] === 'recover' ? positionals[0] : null;
const setupArgs = args.filter((a) => a.startsWith('-') && a !== '--fetch-only');
const fetchOnly = args.includes('--fetch-only');

const TAG_RE = /^v?\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$/;
let upgradeTag = null;
let dirArg;
if (subcommand) {
  for (const p of positionals.slice(1)) {
    if (subcommand === 'upgrade' && TAG_RE.test(p)) upgradeTag = p;
    else dirArg = p;
  }
} else {
  dirArg = positionals[0];
}

function fail(message) {
  console.error(`forge-deploy: ${message}`);
  process.exit(1);
}

const STATE_FILE = join(process.env.FORGE_STATE_DIR ?? '/etc/forge', 'deploy-state.json');

function makeExecutable(path) {
  try {
    chmodSync(path, 0o755);
  } catch {
    // Root-owned tree, non-root operator: already executable from the install.
  }
}

function isInstall(dir) {
  return existsSync(join(dir, '.env')) && existsSync(join(dir, 'scripts', 'forge-deploy'));
}

// The deploy CLI records its own root in the state file; the rest of the list
// is where a tree that predates that recording is likely to be.
function findInstall() {
  let recorded = null;
  try {
    const root = JSON.parse(readFileSync(STATE_FILE, 'utf8'))?.box?.repoRoot;
    if (typeof root === 'string' && root) recorded = root;
  } catch {
    // Absent, unreadable, or half-written — fall through to the guesses.
  }
  const seen = new Set();
  for (const candidate of [
    process.env.FORGE_DEPLOY_DIR,
    recorded,
    process.cwd(),
    join(process.cwd(), 'forge-deploy'),
    '/opt/forge-deploy',
    '/opt/forge',
    join(homedir(), 'forge-deploy'),
  ]) {
    if (!candidate) continue;
    const dir = resolve(candidate);
    if (seen.has(dir)) continue;
    seen.add(dir);
    if (isInstall(dir)) return dir;
  }
  return null;
}

// The CLI's own default root is /opt/forge-deploy; naming the tree it was
// launched from is what keeps it off another install's .env and compose files.
function runTree(dir, cliArgs) {
  const deployCli = join(dir, 'scripts', 'forge-deploy');
  if (!existsSync(deployCli)) fail(`${dir} has no scripts/forge-deploy`);
  makeExecutable(deployCli);
  const opts = { cwd: dir, stdio: 'inherit', env: { ...process.env, FORGE_DEPLOY_REPO: dir } };
  const ensure = spawnSync('bash', [join(dir, 'scripts', 'ensure-deps.sh')], opts);
  if (ensure.status !== 0) fail('prerequisites missing (see message above)');
  const run = spawnSync('bash', [deployCli, ...cliArgs], opts);
  process.exit(run.status ?? 1);
}

// A client who runs the bare command from their home directory has to land on
// the box's real install — being handed the first-install wizard for a machine
// that already runs Forge is the worst thing this tool can do. Only the
// no-argument form searches: an explicit directory, a subcommand, or setup
// flags all mean the caller has already said what they want.
const bare = process.platform !== 'win32'
  && !subcommand && dirArg === undefined && setupArgs.length === 0 && !fetchOnly;
const existing = bare ? findInstall() : null;

if (bare && !existing && existsSync(STATE_FILE)) {
  fail(
    'this machine has Forge configured, but its deploy tree is not in any of the\n' +
    '  places I looked (here, ./forge-deploy, /opt/forge-deploy, /opt/forge, ~/forge-deploy).\n' +
    '  Point me at it rather than starting a second install beside it:\n' +
    '    npx @armoryworks/forge-deploy /path/to/forge-deploy\n' +
    '  (or export FORGE_DEPLOY_DIR=/path/to/forge-deploy)',
  );
}

// Nothing to fetch: the tree is already on the box, and re-extracting over a
// root-owned install would fail for exactly the operator the console is for.
// The console offers the installer update itself when this package is behind.
if (existing) runTree(existing, setupArgs);

const targetDir = resolve(
  dirArg ?? (subcommand ? findInstall() ?? '/opt/forge-deploy' : 'forge-deploy'),
);

console.log(`Fetching forge-deploy (${TREE_REF}) into ${targetDir} ...`);

const response = await fetch(TARBALL_URL);
if (!response.ok) {
  if (response.status === 404) {
    fail(
      `the pinned deploy tree ${TREE_REF} does not exist in GitHub (HTTP 404).\n` +
      `  This installer is pinned to a release on purpose and will not fall back to main.\n` +
      `  If you are developing against an unreleased tree: FORGE_DEPLOY_REF=heads/main npx @armoryworks/forge-deploy ...`,
    );
  }
  fail(`download failed: HTTP ${response.status} from ${TARBALL_URL}`);
}

const tarball = join(tmpdir(), `forge-deploy-${process.pid}.tar.gz`);
await pipeline(Readable.fromWeb(response.body), createWriteStream(tarball));

try {
  mkdirSync(targetDir, { recursive: true });
} catch (err) {
  if (err.code === 'EACCES') {
    fail(
      `no permission to create ${targetDir}.\n` +
      `  Create it once with the right owner, then re-run:\n` +
      `    sudo mkdir -p ${targetDir} && sudo chown "$USER": ${targetDir}\n` +
      `  (or pick a directory you own, e.g.: npx @armoryworks/forge-deploy ~/forge-deploy)`,
    );
  }
  throw err;
}
// bsdtar ships with Windows 10+; GNU tar everywhere else — both accept this.
const tar = spawnSync('tar', ['-xzf', tarball, '--strip-components=1', '-C', targetDir], {
  stdio: 'inherit',
});
rmSync(tarball, { force: true });
if (tar.status !== 0) fail('extraction failed — is tar available on PATH?');

// The tree does not otherwise know which npm package delivered it; the console
// compares this against the registry to offer the tool update.
writeFileSync(join(targetDir, '.installer-version'), `${PKG_VERSION}\n`);

if (fetchOnly) {
  console.log(`Done. Next: cd ${targetDir} && ./setup.sh`);
  process.exit(0);
}

if (subcommand) {
  if (!existsSync(join(targetDir, 'scripts', 'forge-deploy'))) {
    fail('scripts/forge-deploy missing after extraction');
  }
  if (subcommand === 'upgrade' && !existsSync(join(targetDir, '.env'))) {
    fail(
      `${targetDir} has no .env — this box was never set up.\n` +
      `  First-time install: npx @armoryworks/forge-deploy ${targetDir}\n` +
      `  Half-finished install: npx @armoryworks/forge-deploy recover ${targetDir}`,
    );
  }
  const deployArgs = subcommand === 'recover'
    ? ['--recover', ...setupArgs]
    : (upgradeTag ? [upgradeTag, ...setupArgs] : ['--update', ...setupArgs]);
  console.log(`Running scripts/forge-deploy ${deployArgs.join(' ')} ...`);
  // runTree also installs jq (one sudo) rather than dying on a preflight
  // message the operator has to decode.
  runTree(targetDir, deployArgs);
}

// A configured box has nothing to install — hand it the guided console. This
// is what makes `npx @armoryworks/forge-deploy` the one command to remember.
if (process.platform !== 'win32' && isInstall(targetDir)) runTree(targetDir, setupArgs);

let result;
if (process.platform === 'win32') {
  result = spawnSync(
    'powershell',
    ['-ExecutionPolicy', 'Bypass', '-File', 'setup.ps1', ...setupArgs],
    { cwd: targetDir, stdio: 'inherit' },
  );
} else {
  const setupSh = join(targetDir, 'setup.sh');
  if (!existsSync(setupSh)) fail('setup.sh missing after extraction');
  chmodSync(setupSh, 0o755);
  result = spawnSync('bash', [setupSh, ...setupArgs], { cwd: targetDir, stdio: 'inherit' });
}

process.exit(result.status ?? 1);
