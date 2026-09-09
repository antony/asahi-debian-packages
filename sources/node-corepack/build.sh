#!/bin/sh
# Rebuild the corepack .deb from the source package in this directory,
# run the smoke tests, copy the result into ../../repo/ and reindex.
#
# Needs: dpkg-dev, nodejs >= 22, npm, network access to the npm
# registry (the build fetches corepack's devDependencies).
#
# To bump to a NEW upstream version, see UPDATING.md - that regenerates
# the source package this script builds from.
set -eu

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)

rm -rf build
mkdir build
dpkg-source --no-check -x node-corepack_*.dsc build/src

(cd build/src && dpkg-buildpackage -b -us -uc -d)

cd build
DEB=$(ls corepack_*_all.deb)

# --- smoke tests -----------------------------------------------------
rm -rf extract cphome
dpkg-deb -x "$DEB" extract

UPSTREAM_VERSION=$(dpkg-deb -f "$DEB" Version | sed 's/+ds.*//')
GOT=$(extract/usr/bin/corepack --version)
[ "$GOT" = "$UPSTREAM_VERSION" ] || {
    echo "FAIL: corepack --version printed '$GOT', expected '$UPSTREAM_VERSION'" >&2
    exit 1
}
echo "ok: corepack --version -> $GOT"

# Real-world test: corepack's job is fetching and running package
# managers. pnpm comes from the npm registry; yarn normally comes from
# repo.yarnpkg.com, which restricted networks may block, so force the
# npm registry for it.
export COREPACK_HOME="$PWD/cphome" COREPACK_ENABLE_DOWNLOAD_PROMPT=0
PNPM_V=$(extract/usr/bin/corepack pnpm@10 --version)
echo "ok: pnpm $PNPM_V via corepack"
export COREPACK_NPM_REGISTRY=https://registry.npmjs.org
YARN_V=$(extract/usr/bin/corepack yarn@4 --version)
echo "ok: yarn $YARN_V via corepack"

# --- publish into the repo -------------------------------------------
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB rebuilt, tested and added to repo/"
