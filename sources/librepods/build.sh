#!/bin/sh
# Build librepods_<VERSION>_arm64.deb from source (librepods-org/librepods,
# the Rust/iced rewrite of the Linux client in linux-rust/), smoke test it,
# copy it into ../../repo/ and reindex.
#
# Upstream only releases an x86_64 AppImage and bare binary (release tag
# linux-v0.1.0), so this is a real source build with upstream's own
# `cargo build --release`. Upstream is not modified; the package layout
# (binary, desktop file, icon, metainfo) mirrors upstream's Justfile and
# flatpak manifest.
#
# Needs: rust toolchain in ~/.cargo (rustup), dpkg-dev, fakeroot, git,
# and these Ubuntu packages:
#   pkg-config libdbus-1-dev libpulse0
# (libpulse-dev is optional: libpulse-sys falls back to linking
# libpulse.so.0 by soname when pkg-config can't find libpulse.pc.)
# First build compiles ~400 crates (iced/wgpu are big; 10-20 min on an
# M-series Mac under Asahi). build/target is kept between runs.
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=0.1.0
TAG="linux-v$VERSION"
UPSTREAM_COMMIT=a01e16792a73deb34c5bd0c4aa019c496642ee71
UPSTREAM=https://github.com/librepods-org/librepods.git
MAINTAINER="antony <antony@beyonk.com>"
APPID=me.kavishdevar.librepods

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
HERE=$PWD
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="$HERE/build/target"

command -v cargo >/dev/null || { echo "cargo not found; install rust via https://rustup.rs" >&2; exit 1; }
for p in pkg-config libdbus-1-dev libpulse0; do
    dpkg -s "$p" >/dev/null 2>&1 || { echo "missing build dependency: $p (sudo apt install $p)" >&2; exit 1; }
done

# --- fetch upstream at the pinned tag ----------------------------------
# Keep an existing clone if it is already at the right commit (saves a
# clone on rebuilds); otherwise fetch fresh.
mkdir -p build
if [ "$(git -C build/src rev-parse HEAD 2>/dev/null || true)" != "$UPSTREAM_COMMIT" ]; then
    rm -rf build/src
    git clone -q --depth 1 --branch "$TAG" "$UPSTREAM" build/src
fi
GOT=$(git -C build/src rev-parse HEAD)
[ "$GOT" = "$UPSTREAM_COMMIT" ] || {
    echo "FAIL: tag $TAG is at $GOT, expected $UPSTREAM_COMMIT (tag moved?)" >&2
    exit 1
}
SRC="$HERE/build/src/linux-rust"
CARGO_V=$(sed -n 's/^version *= *"\([^"]*\)".*/\1/p' "$SRC/Cargo.toml" | head -1)
[ "$CARGO_V" = "$VERSION" ] || { echo "FAIL: Cargo.toml says $CARGO_V, expected $VERSION" >&2; exit 1; }

# --- build -------------------------------------------------------------
(cd "$SRC" && cargo build --release --locked)
BIN="$CARGO_TARGET_DIR/release/librepods"
[ -x "$BIN" ] || { echo "FAIL: $BIN not produced" >&2; exit 1; }

# --- assemble the package tree -----------------------------------------
rm -rf build/pkg build/out build/shlibdeps
PKG=build/pkg
mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/share/applications" \
    "$PKG/usr/share/icons/hicolor/256x256/apps" "$PKG/usr/share/metainfo" \
    "$PKG/usr/share/doc/librepods"

install -m 755 "$BIN" "$PKG/usr/bin/librepods"
install -m 644 "$SRC/assets/$APPID.desktop" "$PKG/usr/share/applications/$APPID.desktop"
install -m 644 "$SRC/assets/icon.png" "$PKG/usr/share/icons/hicolor/256x256/apps/$APPID.png"
install -m 644 "$SRC/flatpak/$APPID.metainfo.xml" "$PKG/usr/share/metainfo/$APPID.metainfo.xml"
install -m 644 debian/README.Debian "$PKG/usr/share/doc/librepods/README.Debian"

# copyright: short header plus upstream's LICENSE (AGPL-3.0) verbatim.
{
    cat <<COPY
LibrePods is Copyright (C) Kavish Devar and contributors, released under
the GNU Affero General Public License v3.0.
Source: https://github.com/librepods-org/librepods (tag $TAG, linux-rust/)
The Debian packaging (build.sh, debian/*) is Copyright (C) 2026 $MAINTAINER
and is released under the same licence.

Upstream LICENSE follows.

COPY
    cat "$HERE/build/src/LICENSE"
} > "$PKG/usr/share/doc/librepods/copyright"

{
    echo "librepods ($VERSION) local; urgency=medium"
    echo
    echo "  * Build of upstream linux-rust at tag $TAG ($UPSTREAM_COMMIT) for arm64."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$PKG/usr/share/doc/librepods/changelog.gz"

find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
chmod 755 "$PKG/usr/bin/librepods"

# --- control files -----------------------------------------------------
# Let dpkg-shlibdeps work out the versioned library Depends from the
# binary's DT_NEEDED entries (it needs a debian/control in the cwd).
mkdir -p build/shlibdeps/debian
printf 'Source: librepods\n\nPackage: librepods\nArchitecture: arm64\n' > build/shlibdeps/debian/control
SHLIBS=$(cd build/shlibdeps && dpkg-shlibdeps -O "$HERE/$PKG/usr/bin/librepods" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$SHLIBS" ] || { echo "FAIL: dpkg-shlibdeps produced no Depends" >&2; exit 1; }
echo "shlibs: $SHLIBS"

INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@MAINTAINER@/$MAINTAINER/" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/" \
    -e "s/@SHLIBS_DEPENDS@/$SHLIBS/" \
    debian/control.in > "$PKG/DEBIAN/control"
(cd "$PKG" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' md5sum > DEBIAN/md5sums)

mkdir -p build/out
DEB="librepods_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/out/$DEB"

# --- smoke tests -------------------------------------------------------
cd build/out
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends Recommends

[ "$(dpkg-deb -f "$DEB" Package)" = librepods ] || { echo "FAIL: package name" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Architecture)" = arm64 ] || { echo "FAIL: not arm64" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Version)" = "$VERSION" ] || { echo "FAIL: version" >&2; exit 1; }
dpkg-deb -f "$DEB" Depends | grep -q 'libpulse0' || { echo "FAIL: Depends lacks libpulse0" >&2; exit 1; }
dpkg-deb -f "$DEB" Depends | grep -q 'libdbus-1-3' || { echo "FAIL: Depends lacks libdbus-1-3" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
XBIN=extract/usr/bin/librepods
file "$XBIN" | grep -q 'ARM aarch64' || { echo "FAIL: $XBIN is not an aarch64 ELF" >&2; file "$XBIN" >&2; exit 1; }
echo "ok: /usr/bin/librepods is an aarch64 ELF"
MISSING=$(ldd "$XBIN" | grep 'not found' || true)
[ -z "$MISSING" ] || { echo "FAIL: unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
echo "ok: all shared libraries resolve on this machine"

for f in usr/share/applications/$APPID.desktop usr/share/icons/hicolor/256x256/apps/$APPID.png \
         usr/share/metainfo/$APPID.metainfo.xml usr/share/doc/librepods/copyright \
         usr/share/doc/librepods/changelog.gz usr/share/doc/librepods/README.Debian; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
grep -q '^Exec=librepods$' "extract/usr/share/applications/$APPID.desktop" || { echo "FAIL: desktop Exec changed" >&2; exit 1; }
echo "ok: expected files present"
(cd extract && md5sum -c --quiet ../../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"

# clap parses --help and exits before any Bluetooth, D-Bus or GUI is
# touched, so this is a safe end-to-end run of the packaged binary.
HELP=$("$XBIN" --help 2>&1) || { echo "FAIL: librepods --help exited non-zero:" >&2; echo "$HELP" >&2; exit 1; }
echo "$HELP" | grep -q -- '--no-tray' || { echo "FAIL: --help output unexpected:" >&2; echo "$HELP" >&2; exit 1; }
echo "ok: librepods --help runs and lists the expected flags"

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/librepods_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
