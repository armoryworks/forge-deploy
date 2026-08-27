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
// Otherwise the first argument not starting with "-" is the target directory
// (default ./forge-deploy). Every argument starting with "-" is passed
// through to setup.sh untouched (--source, --lan, --public, --ssl, ...),
// except --fetch-only, which downloads the tree and stops. Re-running in an
// existing directory refreshes the tracked files and preserves .env,
// docker-compose.override.yml, and volumes.

import { spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, chmodSync, rmSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const PKG_VERSION = JSON.parse(
  readFileSync(join(dirname(dirname(fileURLToPath(import.meta.url))), 'package.json'), 'utf8'),
).version;

const DEFAULT_TREE_TAG = 'v0.8.0';

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
const targetDir = resolve(dirArg ?? (subcommand ? '/opt/forge-deploy' : 'forge-deploy'));

function fail(message) {
  console.error(`forge-deploy: ${message}`);
  process.exit(1);
}

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
  const deployCli = join(targetDir, 'scripts', 'forge-deploy');
  if (!existsSync(deployCli)) fail('scripts/forge-deploy missing after extraction');
  if (subcommand === 'upgrade' && !existsSync(join(targetDir, '.env'))) {
    fail(
      `${targetDir} has no .env — this box was never set up.\n` +
      `  First-time install: npx @armoryworks/forge-deploy ${targetDir}\n` +
      `  Half-finished install: npx @armoryworks/forge-deploy recover ${targetDir}`,
    );
  }
  chmodSync(deployCli, 0o755);
  // The deploy CLI needs jq; install it (one sudo) instead of dying on a
  // preflight message the operator has to decode.
  const ensure = spawnSync('bash', [join(targetDir, 'scripts', 'ensure-deps.sh')], {
    cwd: targetDir, stdio: 'inherit',
  });
  if (ensure.status !== 0) fail('prerequisites missing (see message above)');
  const deployArgs = subcommand === 'recover'
    ? ['--recover', ...setupArgs]
    : (upgradeTag ? [upgradeTag, ...setupArgs] : ['--update', ...setupArgs]);
  console.log(`Running scripts/forge-deploy ${deployArgs.join(' ')} ...`);
  const run = spawnSync('bash', [deployCli, ...deployArgs], { cwd: targetDir, stdio: 'inherit' });
  process.exit(run.status ?? 1);
}

// A configured box has nothing to install — hand it the guided console. This
// is what makes `npx @armoryworks/forge-deploy` the one command to remember.
if (process.platform !== 'win32' && existsSync(join(targetDir, '.env'))) {
  const deployCli = join(targetDir, 'scripts', 'forge-deploy');
  if (existsSync(deployCli)) {
    chmodSync(deployCli, 0o755);
    const ensure = spawnSync('bash', [join(targetDir, 'scripts', 'ensure-deps.sh')], {
      cwd: targetDir, stdio: 'inherit',
    });
    if (ensure.status !== 0) fail('prerequisites missing (see message above)');
    const console_ = spawnSync('bash', [deployCli, ...setupArgs], { cwd: targetDir, stdio: 'inherit' });
    process.exit(console_.status ?? 1);
  }
}

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
