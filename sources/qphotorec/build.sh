#!/bin/sh
# Build qphotorec_<VERSION>_arm64.deb from the upstream testdisk tarball,
# smoke test it, copy it into ../../repo/ and reindex.
#
# Ubuntu's testdisk package is built without Qt, so it has no qphotorec.
# This builds upstream's tarball with its own ./configure && make and
# packages only the Qt GUI (binary, man page, desktop file, icons); the
# CLI tools stay with Ubuntu's testdisk, which we Recommend.
#
# Needs: build-essential, dpkg-dev, fakeroot, pkg-config and
#   qtbase5-dev qttools5-dev-tools libjpeg-dev libext2fs-dev ntfs-3g-dev
#   libewf-dev libncurses-dev uuid-dev zlib1g-dev
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=7.2
TARBALL_SHA256=f8343be20cb4001c5d91a2e3bcd918398f00ae6d8310894a5a9f2feb813c283f
URL=https://www.cgsecurity.org/testdisk-$VERSION.tar.bz2
MAINTAINER="antony <antony@beyonk.com>"

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
HERE=$PWD

for p in pkg-config qtbase5-dev qttools5-dev-tools libjpeg-dev libext2fs-dev ntfs-3g-dev \
         libewf-dev libncurses-dev uuid-dev zlib1g-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || { echo "missing build dependency: $p (sudo apt install $p)" >&2; exit 1; }
done

# --- fetch -------------------------------------------------------------
mkdir -p dl build
TB="dl/testdisk-$VERSION.tar.bz2"
if [ ! -f "$TB" ]; then curl -fL -o "$TB.part" "$URL" && mv "$TB.part" "$TB"; fi
echo "$TARBALL_SHA256  $TB" | sha256sum -c --quiet || { echo "FAIL: sha256 mismatch for $TB" >&2; exit 1; }

# --- build -------------------------------------------------------------
rm -rf build/src
mkdir -p build/src
tar xjf "$TB" -C build/src --strip-components=1
SRC="$HERE/build/src"
(cd "$SRC" && ./configure --prefix=/usr --mandir=/usr/share/man --enable-qt)
grep -q '^QPHOTOREC = qphotorec' "$SRC/src/Makefile" || {
    echo "FAIL: configure disabled Qt; see build/src/config.log" >&2; exit 1; }
make -C "$SRC/src" -j"$(nproc)" qphotorec
make -C "$SRC/man" qphotorec.8
BIN="$SRC/src/qphotorec"
[ -x "$BIN" ] || { echo "FAIL: $BIN not produced" >&2; exit 1; }

# --- assemble the package tree -----------------------------------------
rm -rf build/pkg build/out build/shlibdeps
PKG=build/pkg
DOC="$PKG/usr/share/doc/qphotorec"
mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/share/man/man8" "$PKG/usr/share/applications" \
    "$PKG/usr/share/icons/hicolor/48x48/apps" "$PKG/usr/share/icons/hicolor/scalable/apps" "$DOC"

install -m 755 -s "$BIN" "$PKG/usr/bin/qphotorec"
gzip -9nc "$SRC/man/qphotorec.8" > "$PKG/usr/share/man/man8/qphotorec.8.gz"
install -m 644 "$SRC/linux/qphotorec.desktop" "$PKG/usr/share/applications/"
install -m 644 "$SRC/icons/48x48/apps/qphotorec.png" "$PKG/usr/share/icons/hicolor/48x48/apps/"
install -m 644 "$SRC/icons/scalable/apps/qphotorec.svg" "$PKG/usr/share/icons/hicolor/scalable/apps/"

{
    cat <<COPY
QPhotoRec/TestDisk is Copyright (C) Christophe Grenier <grenier@cgsecurity.org>,
released under the GNU General Public License v2 or later.
Source: $URL
The Debian packaging (build.sh, debian/*) is Copyright (C) 2026 $MAINTAINER
and is released under the same licence.

Upstream COPYING follows.

COPY
    cat "$SRC/COPYING"
} > "$DOC/copyright"

{
    echo "qphotorec ($VERSION) local; urgency=medium"
    echo
    echo "  * Build of upstream testdisk-$VERSION (qphotorec only) for arm64."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$DOC/changelog.gz"

find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
chmod 755 "$PKG/usr/bin/qphotorec"

# --- control files -----------------------------------------------------
mkdir -p build/shlibdeps/debian
printf 'Source: qphotorec\n\nPackage: qphotorec\nArchitecture: arm64\n' > build/shlibdeps/debian/control
SHLIBS=$(cd build/shlibdeps && dpkg-shlibdeps -O "$HERE/$PKG/usr/bin/qphotorec" 2>/dev/null | sed -n 's/^shlibs:Depends=//p')
[ -n "$SHLIBS" ] || { echo "FAIL: dpkg-shlibdeps produced no Depends" >&2; exit 1; }

INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@MAINTAINER@/$MAINTAINER/" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/" \
    -e "s/@SHLIBS_DEPENDS@/$SHLIBS/" \
    debian/control.in > "$PKG/DEBIAN/control"
(cd "$PKG" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' md5sum > DEBIAN/md5sums)

mkdir -p build/out
DEB="qphotorec_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/out/$DEB"

# --- smoke tests -------------------------------------------------------
cd build/out
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends Recommends

[ "$(dpkg-deb -f "$DEB" Architecture)" = arm64 ] || { echo "FAIL: not arm64" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Version)" = "$VERSION" ] || { echo "FAIL: version" >&2; exit 1; }
dpkg-deb -f "$DEB" Depends | grep -q 'libqt5widgets5' || { echo "FAIL: Depends lacks Qt5 widgets" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
XBIN=extract/usr/bin/qphotorec
file "$XBIN" | grep -q 'ARM aarch64' || { echo "FAIL: not an aarch64 ELF" >&2; file "$XBIN" >&2; exit 1; }
echo "ok: /usr/bin/qphotorec is an aarch64 ELF"
MISSING=$(ldd "$XBIN" | grep 'not found' || true)
[ -z "$MISSING" ] || { echo "FAIL: unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
echo "ok: all shared libraries resolve on this machine"
for f in usr/share/man/man8/qphotorec.8.gz usr/share/applications/qphotorec.desktop \
         usr/share/icons/hicolor/48x48/apps/qphotorec.png usr/share/icons/hicolor/scalable/apps/qphotorec.svg \
         usr/share/doc/qphotorec/copyright usr/share/doc/qphotorec/changelog.gz; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
echo "ok: expected files present"
(cd extract && md5sum -c --quiet ../../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"
# --version is handled in main() before QApplication is created, so this
# runs the packaged binary without opening a window. It also reports which
# optional libraries got linked; all four must be present.
V=$("$XBIN" --version) || { echo "FAIL: qphotorec --version exited non-zero" >&2; exit 1; }
echo "$V"
echo "$V" | grep -q "^Version: $VERSION$" || { echo "FAIL: version" >&2; exit 1; }
echo "$V" | grep -E 'ext2fs lib: none|ntfs lib: none|ewf lib: none|libjpeg: none' && {
    echo "FAIL: an optional library was not linked" >&2; exit 1; }
echo "ok: qphotorec --version runs, all optional libraries linked"

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/qphotorec_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
