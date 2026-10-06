#!/bin/sh
# Build eposnow-till_<VERSION>_arm64.deb: the Epos Now web till in a
# pinned Electron, smoke test it, copy it into ../../repo/ and reindex.
#
# Epos Now ship a Windows .NET till (POSInstall_*.exe) and a Mac app
# (EposNow_Till_Mac_*.dmg). The Mac app is only an Electron 25 window
# onto https://www.eposnowhq.com, pinned to Chromium 114 because the
# till still needs WebSQL (removed in Chrome 119). This does the same
# with the official Electron arm64 Linux release and our own main.js -
# no Epos Now code is shipped.
#
# Needs: dpkg-dev, curl, unzip, fakeroot. No root needed.
#
# To bump, see UPDATING.md.
set -eu

VERSION=1.0.1
ELECTRON_VERSION=25.9.8
ELECTRON_SHA256=e1a0e898410569fbc9b1611b55f99d7ca0d50d1e8dad0450e6a0959ad9b3ed93
MAINTAINER="antony <antony@beyonk.com>"

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
ZIP="electron-v$ELECTRON_VERSION-linux-arm64.zip"
URL="https://github.com/electron/electron/releases/download/v$ELECTRON_VERSION/$ZIP"

# --- fetch (cached in dl/, which is gitignored) -------------------------
mkdir -p dl
if [ ! -f "dl/$ZIP" ]; then
    echo "fetching $URL"
    curl -fL --retry 3 -o "dl/$ZIP.part" "$URL"
    mv "dl/$ZIP.part" "dl/$ZIP"
fi
echo "$ELECTRON_SHA256  dl/$ZIP" | sha256sum -c -

# --- assemble the package tree -----------------------------------------
rm -rf build
PKG=build/pkg
APP=$PKG/opt/eposnow-till
mkdir -p "$APP/resources/app" "$PKG/DEBIAN" "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/512x512/apps" "$PKG/usr/share/doc/eposnow-till"

unzip -q "dl/$ZIP" -d "$APP"
mv "$APP/electron" "$APP/eposnow-till"
rm "$APP/resources/default_app.asar"
mv "$APP/LICENSE" "$APP/LICENSES.chromium.html" "$PKG/usr/share/doc/eposnow-till/"

install -m 644 debian/main.js "$APP/resources/app/"
sed "s/@VERSION@/$VERSION/" debian/package.json > "$APP/resources/app/package.json"
install -m 644 debian/apparmor-profile "$APP/resources/apparmor-profile"
install -m 644 debian/eposnow-till.desktop "$PKG/usr/share/applications/"
install -m 644 debian/icon.png "$PKG/usr/share/icons/hicolor/512x512/apps/eposnow-till.png"

{
    echo "eposnow-till ($VERSION) local; urgency=medium"
    echo
    echo "  * Epos Now web till in Electron $ELECTRON_VERSION (arm64)."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$PKG/usr/share/doc/eposnow-till/changelog.gz"

find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
for f in eposnow-till chrome-sandbox chrome_crashpad_handler \
         libEGL.so libGLESv2.so libffmpeg.so libvk_swiftshader.so libvulkan.so.1; do
    chmod 755 "$APP/$f"
done

# --- control files -----------------------------------------------------
install -m 755 debian/postinst debian/postrm "$PKG/DEBIAN/"
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@MAINTAINER@/$MAINTAINER/" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/" \
    debian/control.in > "$PKG/DEBIAN/control"
(cd "$PKG" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' md5sum > DEBIAN/md5sums)

DEB="eposnow-till_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/$DEB"

# --- smoke tests -------------------------------------------------------
cd build
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends

ARCH=$(dpkg-deb -f "$DEB" Architecture)
[ "$ARCH" = arm64 ] || { echo "FAIL: Architecture is $ARCH" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
BIN=extract/opt/eposnow-till/eposnow-till
file "$BIN" | grep -q 'ARM aarch64' || { echo "FAIL: $BIN is not an aarch64 ELF" >&2; exit 1; }
echo "ok: eposnow-till is an aarch64 ELF"

MISSING=$(ldd "$BIN" | grep 'not found' || true)
[ -z "$MISSING" ] || { echo "FAIL: unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
echo "ok: all shared libraries resolve on this machine"

for f in opt/eposnow-till/resources/app/main.js opt/eposnow-till/resources/app/package.json \
         opt/eposnow-till/resources/apparmor-profile opt/eposnow-till/chrome-sandbox \
         usr/share/applications/eposnow-till.desktop \
         usr/share/icons/hicolor/512x512/apps/eposnow-till.png; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
echo "ok: expected files present"

(cd extract && md5sum -c --quiet ../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"

# Run as plain Node: proves the binary loads without opening a window.
# (--version would launch the app: only Electron's default_app handles it.)
GOT=$(ELECTRON_RUN_AS_NODE=1 timeout 20 "$BIN" -p process.versions.electron)
[ "$GOT" = "$ELECTRON_VERSION" ] || { echo "FAIL: --version said '$GOT'" >&2; exit 1; }
echo "ok: runs, reports $GOT"

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/eposnow-till_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
echo "note: this .deb is ~70 MB and is gitignored; only sources/ and the index are committed."
