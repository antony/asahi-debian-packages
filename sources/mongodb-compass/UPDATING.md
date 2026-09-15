# Updating mongodb-compass to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Read the gotchas at the bottom before improvising.

## What this package is

- Upstream: https://github.com/mongodb-js/compass, SSPL-1.0. MongoDB
  Compass, the official MongoDB GUI (Electron). Releases are tagged
  `v<VERSION>`; the GitHub release only carries Linux **x86-64** assets
  (`mongodb-compass_<V>_amd64.deb`, `.rpm`, tarballs). There is no arm64
  Linux build anywhere upstream, so this is a **source build**, not a
  repack.
- `build.sh` runs upstream's own pipeline on the arm64 host:
  `npm run bootstrap` (npm install + compile the ~60-package monorepo)
  then `HADRON_DISTRIBUTION=compass HADRON_SKIP_INSTALLER=true
  npm run package-compass` (webpack production bundle, electron-packager
  with Electron downloaded for linux-arm64, `@electron/rebuild` of the
  native modules against that Electron, asar). Output is the packaged
  app dir `packages/compass/dist/MongoDB Compass-linux-arm64/`.
- The installer step is skipped on purpose: `packages/hadron-build/src/lib/target.ts`
  sets `debianArch = this.arch === 'x64' ? 'amd64' : 'i386'`, so on an
  arm64 host electron-installer-debian would produce a .deb stamped
  `Architecture: i386`. `build.sh` assembles the .deb itself with the same
  layout as upstream's amd64 package: app in `/usr/lib/mongodb-compass/`,
  `/usr/bin/mongodb-compass` symlink to `MongoDB Compass`, desktop entry
  (`debian/mongodb-compass.desktop`, copied verbatim from the amd64 .deb),
  pixmap from `packages/compass/app-icons/linux/mongodb-compass-logo-stable.png`
  (byte-identical to upstream's pixmap), copyright = upstream LICENSE,
  `Depends`/`Recommends`/`Suggests` in `debian/control.in` copied verbatim
  from the amd64 .deb's control file. Upstream ships no maintainer scripts.
- `chrome-sandbox` is setuid 4755, as upstream ships it.
- Version string is upstream's (`1.50.0` for tag `v1.50.0`).
- Node is not taken from the system: upstream's root `package.json` has
  `engines.node >= 24.15` with `engine-strict=true` in `.npmrc`, and the
  system node is 22. `build.sh` downloads a pinned Node linux-arm64
  tarball into `dl/` and unpacks it under `build/`.
- The `.deb` is ~130 MB, so it is **gitignored** (`repo/mongodb-compass_*.deb`)
  and must be rebuilt with `build.sh` after a fresh clone.

## Prerequisites

`git`, `curl`, `fakeroot`, `dpkg-dev`, `python3`, `make`, `g++`,
`libkrb5-dev` (the `kerberos` module is force-rebuilt from source on
Linux by upstream's pipeline). ~6 GB free under `sources/mongodb-compass/build/`.
Network: github.com, registry.npmjs.org, nodejs.org (Node tarball and
headers), github.com/electron (Electron zip + headers, cached in
`~/.cache/electron`), downloads.mongodb.com (crypt_shared library),
plus whatever `scripts/download-fonts.js` fetches. No root.

## Step 1 - find the new version and its commit

```sh
V=$(curl -sS https://api.github.com/repos/mongodb-js/compass/releases/latest \
    | grep -o '"tag_name": *"v[^"]*"' | grep -o '[0-9][0-9.]*')
echo "$V"
git ls-remote https://github.com/mongodb-js/compass.git "refs/tags/v$V^{}" "refs/tags/v$V"
```

Take the commit the tag points at (the `^{}` line if present, else the
plain tag line).

Then check the Electron version upstream pins for that tag:

```sh
curl -sSL "https://raw.githubusercontent.com/mongodb-js/compass/v$V/package-lock.json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["packages"]["node_modules/electron"]["version"])'
```

And the Node requirement:

```sh
curl -sSL "https://raw.githubusercontent.com/mongodb-js/compass/v$V/package.json" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["engines"])'
```

If the current `NODE_VERSION` in `build.sh` no longer satisfies it, pick
the newest release of the required major from
https://nodejs.org/dist/index.json and get its sha256:

```sh
curl -s https://nodejs.org/dist/v<N>/SHASUMS256.txt | grep linux-arm64.tar.xz
```

## Step 2 - bump build.sh

Edit the constants at the top of `build.sh`:

```sh
VERSION=<V>
UPSTREAM_COMMIT=<commit the tag points at>
ELECTRON_VERSION=<from package-lock.json>
NODE_VERSION=<only if engines changed>
NODE_SHA256=<matching sha256>
```

## Step 3 - check whether upstream changed what we mirror

```sh
curl -sSL -o /tmp/compass_amd64.deb \
  "https://github.com/mongodb-js/compass/releases/download/v$V/mongodb-compass_${V}_amd64.deb"
dpkg-deb -f /tmp/compass_amd64.deb Depends Recommends Suggests Section
dpkg-deb --fsys-tarfile /tmp/compass_amd64.deb | tar -xO ./usr/share/applications/mongodb-compass.desktop \
  | diff - sources/mongodb-compass/debian/mongodb-compass.desktop
dpkg-deb -c /tmp/compass_amd64.deb | grep -E 'DEBIAN|postinst|chrome-sandbox'
```

- Depends changed: update `debian/control.in`.
- Desktop file changed: replace `debian/mongodb-compass.desktop`.
- Upstream started shipping maintainer scripts (`dpkg-deb -e` to see):
  copy them into `debian/` and install them into `DEBIAN/` in `build.sh`.
- Native module list changed (`config.hadron.rebuild.onlyModules` in
  `packages/compass/package.json`, or the `unpack` globs): update the
  `for m in ...` smoke test in `build.sh`.

## Step 4 - build and test

```sh
./sources/mongodb-compass/build.sh 2>&1 | tee sources/mongodb-compass/build/build.log
apt-get -s install ./repo/mongodb-compass_<V>_arm64.deb
```

`build.sh` verifies the Node tarball checksum, that the tag is at the
pinned commit and that `package-lock.json` pins the expected Electron,
runs bootstrap and package-compass, assembles the .deb, then checks:
Architecture arm64, every `.so`/`.node`/binary is an aarch64 ELF that
resolves, the five native modules and the `mongo_crypt_v1` shared library
are present, the Electron `version` file matches, `app.asar` is
`mongodb-compass <V>` with its `main` entry present, expected files and
the `/usr/bin` symlink exist, `chrome-sandbox` is 4755, md5sums verify.
It copies the .deb into `repo/` and reindexes.

Then for real (the GUI can't be launched from build.sh):

```sh
sudo apt update && sudo apt install mongodb-compass
mongodb-compass
```

Connect to a database, open a collection, and open the embedded mongosh
tab (that exercises the worker-thread runtime and native modules).

## Step 5 - commit

Commit `sources/mongodb-compass/build.sh` (and anything changed in
`debian/`), plus `repo/Packages`, `repo/Packages.gz`, `repo/Release`.
The `.deb` itself is gitignored. Update the version in the README table.

## Gotchas

- **Don't let hadron-build create the .deb.** See above: it would be
  `Architecture: i386`. Keep `HADRON_SKIP_INSTALLER=true`. That also skips
  the rpm (no `rpmbuild` here anyway) and the tarballs, which we don't need.
- **`npm run bootstrap` is the slow part** and needs the network for the
  whole time (npm, Node headers for node-gyp, Electron zip). The Electron
  zip is cached in `~/.cache/electron`; everything else is redone from
  scratch each run because `build/src` is re-cloned.
- **Native modules are rebuilt from source on Linux by design**:
  `scripts/electron-rebuild.js` and hadron-build's `installDependencies`
  pass a fake `prebuild-tag-prefix` so prebuilt binaries can't be
  downloaded, to match the host glibc. `kerberos` therefore needs
  `libkrb5-dev`. `mongodb-client-encryption` is rebuilt without that flag
  and uses its N-API prebuild for linux-arm64.
- **crypt_shared** (`mongo_crypt_v1.*.so`, ~95 MB inside the bundle) is
  downloaded by `packages/compass/scripts/download-csfle.js` via
  `@mongodb-js/mongodb-downloader` for the host arch, distro `rhel8`,
  version pinned in that script. The linux-aarch64 rhel8 enterprise build
  exists on downloads.mongodb.com. If the smoke test says it is missing,
  check that script's pinned version still has an aarch64 artefact.
- **The two webpack-hashed `.node` files** in
  `app.asar.unpacked/build/` are `ssh2`'s `sshcrypto.node` and
  `cpufeatures.node` (SSH tunnel support), bundled by webpack's node-loader.
  They are built against the *host Node* at `npm install` time, not
  Electron; upstream's amd64 build is the same, and ssh2 falls back to
  pure JS if they fail to load. Not a packaging bug.
- **`interruptor`, `kerberos`, `os-dns-native`, `native-machine-id`
  ship a second copy** under `bin/linux-arm64-<abi>/`; that is
  hadron-build's convention, mirrored from the amd64 package.
- **File name with a space.** The binary is `MongoDB Compass`; the
  smoke test uses `find -exec` rather than a `while read` loop for that
  reason (and because `read -d` isn't POSIX sh).
