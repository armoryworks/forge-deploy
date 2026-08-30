#!/usr/bin/env node
// Launcher shim — deliberately parseable and runnable by old Node.
//
// The implementation uses fetch() and Readable.fromWeb(), which on Node < 18
// fail as a bare ReferenceError with no indication that the Node version is
// the problem. `engines` only makes npm warn. So the version gate has to run
// before that module is ever loaded, which means this file must contain
// nothing newer than dynamic import().
var major = parseInt(process.versions.node.split('.')[0], 10);
if (!(major >= 18)) {
  console.error(
    'forge-deploy: Node.js 18 or newer is required (found v' + process.versions.node + ').\n' +
    '  Install a current Node, then re-run:\n' +
    '    Ubuntu/Debian: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs\n' +
    '    Other systems: https://nodejs.org'
  );
  process.exit(1);
}

import('./install.mjs').catch(function (err) {
  console.error('forge-deploy: ' + ((err && err.stack) || err));
  process.exit(1);
});
