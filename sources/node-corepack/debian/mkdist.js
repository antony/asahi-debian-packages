// Generate the dist/*.js entry scripts, mirroring upstream mkshims.ts
// (without the Windows cmd-shim shims, which a Debian package does not
// need). The binary names are derived from config.json, the same data
// upstream's Engine.getBinariesFor() reads.
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const distDir = path.join(root, 'dist');
const config = require(path.join(root, 'config.json'));

fs.mkdirSync(distDir, {recursive: true});

function writeEntry(name, downloadPrompt, runMainArgs) {
  const entryPath = path.join(distDir, `${name}.js`);
  fs.writeFileSync(entryPath, [
    `#!/usr/bin/env node`,
    `process.env.COREPACK_ENABLE_DOWNLOAD_PROMPT??='${downloadPrompt}';`,
    `require('module').enableCompileCache?.();`,
    `require('./lib/corepack.cjs').runMain(${runMainArgs});`,
    ``,
  ].join('\n'));
  fs.chmodSync(entryPath, 0o755);
}

writeEntry('corepack', '0', 'process.argv.slice(2)');

const binaries = new Set();
for (const definition of Object.values(config.definitions)) {
  for (const range of Object.values(definition.ranges)) {
    const bins = Array.isArray(range.bin)
      ? range.bin
      : Object.keys(range.bin);
    for (const bin of bins)
      binaries.add(bin);
  }
}

for (const bin of binaries)
  writeEntry(bin, '1', `['${bin}', ...process.argv.slice(2)]`);

console.log(`generated entry scripts: corepack, ${[...binaries].join(', ')}`);
