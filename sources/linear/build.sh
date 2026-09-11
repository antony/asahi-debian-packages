#!/bin/sh
# Build linear_<VERSION>_arm64.deb from source (zacharyftw/linear-linux, a
# Tauri v2 wrapper around linear.app), smoke test it, copy it into
# ../../repo/ and reindex.
#
# Upstream only releases an amd64 .deb, so this is a real source build,
# not a repack. Upstream is not modified; tauri.overlay.json is merged
# into its tauri.conf.json at build time purely to fill in .deb metadata
# (maintainer, description, section, desktop category).
#
# Needs: rust toolchain in ~/.cargo (rustup), node >= 20 + corepack (for
# the Tauri CLI), dpkg-dev, and these Ubuntu packages:
#   libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev
#   libayatana-appindicator3-dev libssl-dev
# First build compiles ~280 crates (10-15 min on an M-series Mac under
# Asahi); build/target is kept between runs so rebuilds are quick.
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=0.2.3
UPSTREAM_COMMIT=c728b3afb411ecbadb22085c2aab933deac26d41
UPSTREAM=https://github.com/zacharyftw/linear-linux.git

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
HERE=$PWD
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="$HERE/build/target"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export COREPACK_HOME="${COREPACK_HOME:-$HOME/.cache/corepack}"

command -v cargo >/dev/null || { echo "cargo not found; install rust via https://rustup.rs" >&2; exit 1; }
for p in libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev libayatana-appindicator3-dev libssl-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || { echo "missing build dependency: $p (sudo apt install $p)" >&2; exit 1; }
done

# --- fetch upstream at the pinned tag ----------------------------------
rm -rf build/src build/out
mkdir -p build
git clone -q --depth 1 --branch "v$VERSION" "$UPSTREAM" build/src
GOT=$(git -C build/src rev-parse HEAD)
[ "$GOT" = "$UPSTREAM_COMMIT" ] || {
    echo "FAIL: tag v$VERSION is at $GOT, expected $UPSTREAM_COMMIT (tag moved?)" >&2
    exit 1
}
CONF_V=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' build/src/src-tauri/tauri.conf.json)
[ "$CONF_V" = "$VERSION" ] || { echo "FAIL: tauri.conf.json says $CONF_V, expected $VERSION" >&2; exit 1; }

# --- build -------------------------------------------------------------
cd build/src
corepack npm@11 install --no-audit --no-fund --loglevel=error
./node_modules/.bin/tauri build --bundles deb --config "$HERE/tauri.overlay.json"
cd "$HERE"

mkdir -p build/out
DEB_SRC=$(ls "$CARGO_TARGET_DIR"/release/bundle/deb/*_"$VERSION"_arm64.deb)
# Tauri names the file after productName ("Linear_..."); use the Debian
# convention <package>_<version>_<arch>.deb so the repo is consistent.
DEB="linear_${VERSION}_arm64.deb"
cp "$DEB_SRC" "build/out/$DEB"

# --- smoke tests -------------------------------------------------------
cd build/out
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Maintainer Depends Description | head -8

[ "$(dpkg-deb -f "$DEB" Package)" = linear ] || { echo "FAIL: package name" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Architecture)" = arm64 ] || { echo "FAIL: not arm64" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Version)" = "$VERSION" ] || { echo "FAIL: version" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
BIN=extract/usr/bin/linear-linux
file "$BIN" | grep -q 'ARM aarch64' || { echo "FAIL: $BIN is not an aarch64 ELF" >&2; file "$BIN" >&2; exit 1; }
echo "ok: /usr/bin/linear-linux is an aarch64 ELF"
MISSING=$(ldd "$BIN" | grep 'not found' || true)
[ -z "$MISSING" ] || { echo "FAIL: unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
echo "ok: all shared libraries resolve on this machine"
for f in usr/share/applications/Linear.desktop usr/share/icons/hicolor/128x128/apps/linear-linux.png; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
grep -q '^Categories=.*Office' extract/usr/share/applications/Linear.desktop \
    && echo "ok: desktop entry has a category" \
    || { echo "FAIL: desktop entry Categories not set (overlay not applied?)" >&2; exit 1; }

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/linear_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
