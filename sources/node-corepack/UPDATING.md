# Updating node-corepack to a new upstream release

Step-by-step instructions for bumping this package. Written so an AI
assistant (or a human in a hurry) can do the whole update without
re-deriving anything. Follow them in order; the gotchas section at the
bottom explains the non-obvious choices - read it before improvising.

## What this package is

- Upstream: https://github.com/nodejs/corepack (MIT).
- Debian-style source package `node-corepack` producing one
  arch-independent binary package, also `node-corepack`. (Debian's own
  node-corepack source builds a binary package named `corepack`; ours
  is named node-corepack so it can never clash with the archive's, and
  it Conflicts/Replaces/Provides `corepack` since it ships the same
  files.)
- The orig tarball is a `+ds` repack: upstream's git tag minus
  `tests/nocks.db` (a ~57 MB binary HTTP-fixture database used only by
  the test suite).
- `debian/rules` is a standalone makefile (no debhelper). It fetches
  upstream's devDependencies from the npm registry at build time,
  bundles `sources/_lib.ts` with esbuild exactly like upstream's
  `build:bundle` script, and generates the `dist/*.js` entry scripts
  with `debian/mkdist.js` (a port of upstream's `mkshims.ts` minus the
  Windows shims).

## Prerequisites

`dpkg-dev`, `nodejs >= 22`, `npm`, network access to
registry.npmjs.org and github.com. Nothing else - no debhelper.

## Step 1 - find the new version

```sh
curl -sS https://registry.npmjs.org/corepack/latest | grep -o '"version":"[^"]*"'
```

Call the new version `$V` below (e.g. `0.37.0`).

## Step 2 - fetch and repack the upstream source

```sh
WORK=$(mktemp -d)
git clone --depth 1 --branch "v$V" https://github.com/nodejs/corepack.git "$WORK/git"
git -C "$WORK/git" archive --format=tar --prefix="node-corepack-$V+ds/" "v$V" \
  | tar x -C "$WORK"
rm "$WORK/node-corepack-$V+ds/tests/nocks.db"
tar -C "$WORK" -cJf "$WORK/node-corepack_$V+ds.orig.tar.xz" "node-corepack-$V+ds"
```

If `tests/nocks.db` moved or was renamed, update `Files-Excluded` in
`debian/copyright` to match. If new large binary blobs appeared
(anything over ~1 MB: `find . -size +1M`), exclude those too and note
them in the changelog.

## Step 3 - check upstream build changes

Diff what matters before copying the packaging in:

1. **`package.json` -> `scripts.build:bundle`** - if the esbuild
   invocation changed (new `--target`, new flags), mirror the change in
   the `build-indep` recipe in `debian/rules`.
2. **`package.json` -> `devDependencies`** - the `BUILD_DEPS` list in
   `debian/rules` pins the same packages at the same majors. Sync any
   major-version bumps, additions or removals. Only packages that end
   up in the bundle matter (plus esbuild itself); typescript/eslint/
   vitest/@types/* are NOT needed.
3. **`.yarn/patches/`** - debian/rules applies
   `.yarn/patches/clipanion-npm-*.patch` to the npm-fetched clipanion.
   If upstream added patches for other packages, apply those in
   `debian/rules` the same way; if the clipanion patch is gone, remove
   that step.
4. **`mkshims.ts`** - `debian/mkdist.js` replicates the entry-script
   text it writes (the `#!/usr/bin/env node` + `runMain` scripts) and
   derives binary names from `config.json`. If mkshims changed the
   script contents, update `debian/mkdist.js` to match.
5. **`engines.node`** - if the minimum Node major rose, bump the
   `nodejs (>= X)` Depends/Build-Depends in `debian/control` and the
   `--target=nodeX.Y.Z` in `debian/rules`.

## Step 4 - assemble and build

```sh
cp -r sources/node-corepack/debian "$WORK/node-corepack-$V+ds/"
```

Add a new entry at the TOP of `$WORK/node-corepack-$V+ds/debian/changelog`:

```
node-corepack ($V+ds-1) unstable; urgency=medium

  * New upstream release $V.
  * <note anything you changed in step 3>

 -- Antony <antony@beyonk.com>  <output of: date -R>
```

Then build:

```sh
cd "$WORK"
dpkg-source -b "node-corepack-$V+ds"
cd "node-corepack-$V+ds"
dpkg-buildpackage -b -us -uc -d
```

## Step 5 - test (all three must pass)

```sh
cd "$WORK"
dpkg-deb -x "node-corepack_$V+ds-1_all.deb" extract

extract/usr/bin/corepack --version           # must print $V

export COREPACK_HOME="$WORK/cphome" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
extract/usr/bin/corepack pnpm@10 --version   # must print a pnpm version

COREPACK_NPM_REGISTRY=https://registry.npmjs.org \
  extract/usr/bin/corepack yarn@4 --version  # must print a yarn version
# (use yarn@4, not yarn@stable: the "stable" tag only exists on
# repo.yarnpkg.com, not on the npm registry fallback)
```

Also eyeball `dpkg-deb -I` (Depends, Version) and `dpkg-deb -c`
(expect /usr/bin/corepack symlink, dist/lib/corepack.cjs, the six
entry scripts, package.json, docs).

## Step 6 - publish into this repository

```sh
cd <this repo checkout>
rm sources/node-corepack/node-corepack_*        # old source package files
cp "$WORK"/node-corepack_$V+ds{.orig.tar.xz,-1.dsc,-1.debian.tar.xz} sources/node-corepack/
rm -rf sources/node-corepack/debian
cp -r "$WORK/node-corepack-$V+ds/debian" sources/node-corepack/
rm repo/node-corepack_*_all.deb                      # or keep old versions if wanted
cp "$WORK/node-corepack_$V+ds-1_all.deb" repo/
./update-index.sh
```

Sanity-check the packaging is self-consistent by rebuilding from what
you just committed: `./sources/node-corepack/build.sh` (it rebuilds
from the .dsc, re-runs the step 5 tests, and reindexes). Then update
the version in the top-level README's package table, and commit
everything: the source package files, debian/, the .deb, and
repo/Packages, Packages.gz, Release.

## Gotchas (learned the hard way - don't rediscover these)

- **npm crashes on corepack's package.json.** corepack's
  devDependencies use yarn's `patch:` protocol, which makes npm's
  resolver throw `Cannot read properties of null (reading 'edgesOut')`
  if it treats the corepack tree as the project root. That's why
  debian/rules installs build deps in `build-deps/` with its own
  package.json. Never run `npm install` inside the corepack source
  tree itself.
- **POSIX sh does not glob redirections.** `patch < file-*.patch`
  fails under dash; that's why debian/rules uses
  `cat .yarn/patches/... | patch`.
- **The clipanion patch filename contains a content hash** and changes
  whenever upstream regenerates it - hence the glob.
- **The test suite cannot run**: it needs the excluded
  `tests/nocks.db` and network fixtures. The step 5 smoke tests are
  the replacement; don't try to wire up vitest.
- **repo.yarnpkg.com may be blocked** on restricted networks (it was
  in the environment this package was first built in). A yarn-fetch
  failure with HTTP 403 from there is a network policy issue, not a
  package bug - use `COREPACK_NPM_REGISTRY=https://registry.npmjs.org`
  as in step 5.
- **Debian's own infrastructure may be unreachable** (it was:
  deb.debian.org, salsa, packages.debian.org all 403'd). This
  packaging is independent of the js-team's; do not assume version
  numbers or patches from Debian proper apply here.
- **This source package must not be uploaded to the Debian archive**:
  it downloads devDependencies at build time, which archive builds
  forbid. It is for this repo only.
