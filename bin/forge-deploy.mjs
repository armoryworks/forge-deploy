#!/usr/bin/env node
// Bootstrapper for the Forge deploy tree. The npm package is intentionally a
// thin pointer: it downloads the current `main` of armoryworks/forge-deploy
// from GitHub into a target directory, then hands off to setup.sh (or
// setup.ps1 on Windows). Republish only when THIS file or package.json
// changes — the deploy tree itself always comes from GitHub at run time.
//
// Usage:
//   npx @armoryworks/forge-deploy [target-dir] [--fetch-only] [setup flags...]
//
// The first argument not starting with "-" is the target directory (default
// ./forge-deploy). Every argument starting with "-" is passed through to
// setup.sh untouched (--source, --lan, --public, --ssl, ...), except
// --fetch-only, which downloads the tree and stops. Re-running in an
// existing directory refreshes the tracked files and preserves .env,
// docker-compose.override.yml, and volumes.

import { spawnSync } from 'node:child_process';
import { createWriteStream, existsSync, mkdirSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const TARBALL_URL = 'https://codeload.github.com/armoryworks/forge-deploy/tar.gz/refs/heads/main';

const args = process.argv.slice(2);
const setupArgs = args.filter((a) => a.startsWith('-') && a !== '--fetch-only');
const fetchOnly = args.includes('--fetch-only');
const dirArg = args.find((a) => !a.startsWith('-'));
const targetDir = resolve(dirArg ?? 'forge-deploy');

function fail(message) {
  console.error(`forge-deploy: ${message}`);
  process.exit(1);
}

console.log(`Fetching forge-deploy (main) into ${targetDir} ...`);

const response = await fetch(TARBALL_URL);
if (!response.ok) fail(`download failed: HTTP ${response.status} from ${TARBALL_URL}`);

const tarball = join(tmpdir(), `forge-deploy-${process.pid}.tar.gz`);
await pipeline(Readable.fromWeb(response.body), createWriteStream(tarball));

mkdirSync(targetDir, { recursive: true });
// bsdtar ships with Windows 10+; GNU tar everywhere else — both accept this.
const tar = spawnSync('tar', ['-xzf', tarball, '--strip-components=1', '-C', targetDir], {
  stdio: 'inherit',
});
rmSync(tarball, { force: true });
if (tar.status !== 0) fail('extraction failed — is tar available on PATH?');

if (fetchOnly) {
  console.log(`Done. Next: cd ${targetDir} && ./setup.sh`);
  process.exit(0);
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
