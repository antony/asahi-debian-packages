#!/bin/sh
# Build mongodb-compass_<VERSION>_arm64.deb from source (mongodb-js/compass),
# smoke test it, copy it into ../../repo/ and reindex.
#
# Upstream only ships Linux builds for x86-64 (.deb, .rpm, tarballs), so
# this is a real source build on the arm64 host, not a repack. It uses
# upstream's own pipeline unmodified: `npm run bootstrap` (install +
# compile the monorepo) and `npm run package-compass` (webpack production
# bundle, electron-packager, native-module rebuild against Electron).
# Only the *installer* step is skipped (HADRON_SKIP_INSTALLER=true),
# because upstream's hadron-build hardcodes the Debian architecture as
# amd64-or-i386 and would stamp the .deb "i386" on this machine. The .deb
# is assembled here instead, mirroring the layout, desktop entry and
# Depends of upstream's amd64 package.
#
# Needs: git, curl, fakeroot, dpkg-dev, python3, make, g++, libkrb5-dev
# (kerberos is force-rebuilt from source on Linux), ~6 GB of disk under
# build/ and network access to github.com, registry.npmjs.org,
# nodejs.org, electronjs.org, downloads.mongodb.com. No root needed.
# Node 24 is downloaded into build/ (upstream requires >= 24.15; the
# system node is 22). First build takes a good while - the monorepo has
# ~60 packages to compile before Compass itself is bundled.
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=1.50.0
UPSTREAM_COMMIT=99b3f452dcc18d49e1ea9936d1dad67fd293cba0
UPSTREAM=https://github.com/mongodb-js/compass.git
# Electron version pinned by upstream's package-lock.json for this tag;
# checked against what ends up in the package.
ELECTRON_VERSION=43.4.1
NODE_VERSION=24.21.0
NODE_SHA256=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2
MAINTAINER="antony <antony@beyonk.com>"

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
HERE=$PWD

for t in git curl fakeroot dpkg-deb python3 make g++; do
    command -v "$t" >/dev/null || { echo "missing build tool: $t" >&2; exit 1; }
done
dpkg -s libkrb5-dev >/dev/null 2>&1 || { echo "missing build dependency: libkrb5-dev (sudo apt install libkrb5-dev)" >&2; exit 1; }

# --- node toolchain (cached in dl/, unpacked into build/) --------------
mkdir -p dl build
NODE_TGZ="node-v$NODE_VERSION-linux-arm64.tar.xz"
if [ ! -f "dl/$NODE_TGZ" ]; then
    echo "fetching node v$NODE_VERSION"
    curl -fL --retry 3 -o "dl/$NODE_TGZ.part" "https://nodejs.org/dist/v$NODE_VERSION/$NODE_TGZ"
    mv "dl/$NODE_TGZ.part" "dl/$NODE_TGZ"
fi
echo "$NODE_SHA256  dl/$NODE_TGZ" | sha256sum -c -
if [ ! -x "build/node-v$NODE_VERSION-linux-arm64/bin/node" ]; then
    rm -rf "build/node-v$NODE_VERSION-linux-arm64"
    tar -xJf "dl/$NODE_TGZ" -C build
fi
export PATH="$HERE/build/node-v$NODE_VERSION-linux-arm64/bin:$PATH"
echo "using $(node --version) / npm $(npm --version)"

# --- fetch upstream at the pinned tag ----------------------------------
rm -rf build/src build/pkg build/out
git clone -q --depth 1 --branch "v$VERSION" "$UPSTREAM" build/src
GOT=$(git -C build/src rev-parse HEAD)
[ "$GOT" = "$UPSTREAM_COMMIT" ] || {
    echo "FAIL: tag v$VERSION is at $GOT, expected $UPSTREAM_COMMIT (tag moved?)" >&2
    exit 1
}
PKG_V=$(node -p "require('$HERE/build/src/packages/compass/package.json').version")
[ "$PKG_V" = "$VERSION" ] || { echo "FAIL: packages/compass/package.json says $PKG_V, expected $VERSION" >&2; exit 1; }
LOCK_E=$(node -p "require('$HERE/build/src/package-lock.json').packages['node_modules/electron'].version")
[ "$LOCK_E" = "$ELECTRON_VERSION" ] || { echo "FAIL: package-lock pins electron $LOCK_E, expected $ELECTRON_VERSION" >&2; exit 1; }

# --- build with upstream's pipeline ------------------------------------
cd build/src
export HUSKY=0
export PUPPETEER_SKIP_DOWNLOAD=1
export npm_config_fund=false
export npm_config_audit=false
export npm_config_update_notifier=false
# Force the same nproc-bounded parallelism node-gyp would pick anyway,
# and keep Electron's download cache out of build/ so bumps reuse it.
export ELECTRON_CACHE="${ELECTRON_CACHE:-$HOME/.cache/electron}"

echo "=== npm run bootstrap (install + compile monorepo)"
npm run bootstrap

echo "=== npm run package-compass (webpack + electron-packager + native rebuild)"
HADRON_DISTRIBUTION=compass HADRON_SKIP_INSTALLER=true npm run package-compass
cd "$HERE"

APP="build/src/packages/compass/dist/MongoDB Compass-linux-arm64"
[ -d "$APP" ] || { echo "FAIL: packaged app dir not found at $APP" >&2; ls build/src/packages/compass/dist >&2 || true; exit 1; }

# --- assemble the package tree -----------------------------------------
# Same layout as upstream's amd64 .deb (electron-installer-debian):
#   /usr/lib/mongodb-compass/         the packaged app
#   /usr/bin/mongodb-compass          -> ../lib/mongodb-compass/MongoDB Compass
#   /usr/share/applications, pixmaps, doc/mongodb-compass/copyright
PKG=build/pkg
mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib" "$PKG/usr/bin" \
         "$PKG/usr/share/applications" "$PKG/usr/share/pixmaps" "$PKG/usr/share/doc/mongodb-compass"
cp -a "$APP" "$PKG/usr/lib/mongodb-compass"
ln -s "../lib/mongodb-compass/MongoDB Compass" "$PKG/usr/bin/mongodb-compass"
install -m 644 debian/mongodb-compass.desktop "$PKG/usr/share/applications/mongodb-compass.desktop"
install -m 644 build/src/packages/compass/app-icons/linux/mongodb-compass-logo-stable.png \
    "$PKG/usr/share/pixmaps/mongodb-compass.png"

# copyright: upstream's LICENSE (SSPL-1.0) verbatim, as in the amd64 .deb.
{
    cat <<COPY
MongoDB Compass is Copyright (C) MongoDB, Inc., released under the Server
Side Public License v1 (SSPL-1.0). Source: https://github.com/mongodb-js/compass
(tag v$VERSION, commit $UPSTREAM_COMMIT). Third-party notices are in
/usr/lib/mongodb-compass/THIRD-PARTY-NOTICES.md and LICENSES.chromium.html.
The Debian packaging (debian/*) is Copyright (C) 2026 $MAINTAINER.

Upstream LICENSE follows.

COPY
    cat build/src/LICENSE
} > "$PKG/usr/share/doc/mongodb-compass/copyright"

{
    echo "mongodb-compass ($VERSION) local; urgency=medium"
    echo
    echo "  * Build of mongodb-js/compass v$VERSION ($UPSTREAM_COMMIT) for arm64 with"
    echo "    upstream's hadron-build pipeline; .deb assembled to match the amd64 one."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$PKG/usr/share/doc/mongodb-compass/changelog.gz"

# Normalise modes: dirs 755, files 644, executables 755, chrome-sandbox
# setuid 4755 exactly as upstream ships it (Electron's SUID sandbox helper,
# needed where unprivileged user namespaces are restricted).
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
chmod 755 "$PKG/usr/lib/mongodb-compass/MongoDB Compass" \
          "$PKG/usr/lib/mongodb-compass/chrome_crashpad_handler"
find "$PKG/usr/lib/mongodb-compass" -name '*.so*' -exec chmod 755 {} +
chmod 4755 "$PKG/usr/lib/mongodb-compass/chrome-sandbox"

# --- control files -----------------------------------------------------
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@MAINTAINER@/$MAINTAINER/" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/" \
    debian/control.in > "$PKG/DEBIAN/control"
(cd "$PKG" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' md5sum > DEBIAN/md5sums)

mkdir -p build/out
DEB="mongodb-compass_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/out/$DEB"

# --- smoke tests -------------------------------------------------------
cd build/out
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends

[ "$(dpkg-deb -f "$DEB" Package)" = mongodb-compass ] || { echo "FAIL: package name" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Architecture)" = arm64 ] || { echo "FAIL: not arm64" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Version)" = "$VERSION" ] || { echo "FAIL: version" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
LIB=extract/usr/lib/mongodb-compass

# Every ELF in the package must be aarch64 and resolve on this machine.
# (find -exec rather than a while-read loop: the main binary has a space
# in its name and this is POSIX sh.)
find "$LIB" -type f \( -name '*.so*' -o -name '*.node' -o -name 'MongoDB Compass' -o -name 'chrome-sandbox' -o -name 'chrome_crashpad_handler' \) \
    -exec sh -c '
    for f do
        file "$f" | grep -q "ARM aarch64" || { echo "FAIL: $f is not an aarch64 ELF:" >&2; file "$f" >&2; exit 1; }
        MISSING=$(ldd "$f" 2>/dev/null | grep "not found" || true)
        [ -z "$MISSING" ] || { echo "FAIL: $f has unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
    done' sh {} +
N=$(find "$LIB" -type f \( -name '*.so*' -o -name '*.node' \) | wc -l)
echo "ok: main binary, sandbox helpers and $N .so/.node files are aarch64 ELF and resolve"

# The native modules Compass needs must be present, built for arm64.
for m in kerberos/build/Release/kerberos.node \
         mongodb-client-encryption/build/Release/mongocrypt.node \
         os-dns-native/build/Release/os_dns_native.node \
         native-machine-id/build/Release/native_machine_id.node \
         interruptor/build/Release/interruptor.node; do
    [ -f "$LIB/resources/app.asar.unpacked/node_modules/$m" ] || { echo "FAIL: missing native module $m" >&2; exit 1; }
done
ls "$LIB"/resources/app.asar.unpacked/build/assets/mongo_crypt_v1.*.so >/dev/null 2>&1 \
    || { echo "FAIL: crypt_shared library (mongo_crypt_v1.*.so) missing from bundle" >&2; exit 1; }
echo "ok: kerberos, mongodb-client-encryption, os-dns-native, native-machine-id, interruptor and crypt_shared present"

GOT_E=$(cat "$LIB/version")
[ "$GOT_E" = "$ELECTRON_VERSION" ] || { echo "FAIL: packaged Electron is $GOT_E, expected $ELECTRON_VERSION" >&2; exit 1; }
echo "ok: Electron $GOT_E"

# The bundled app.asar must be Compass at this version with its entry point.
ASAR="$HERE/build/src/node_modules/.bin/asar"
"$ASAR" extract-file "$LIB/resources/app.asar" package.json
ASAR_V=$(node -p "require('./package.json').version"); ASAR_N=$(node -p "require('./package.json').name")
ASAR_MAIN=$(node -p "require('./package.json').main")
[ "$ASAR_N" = mongodb-compass ] && [ "$ASAR_V" = "$VERSION" ] || { echo "FAIL: app.asar is $ASAR_N $ASAR_V" >&2; exit 1; }
"$ASAR" list "$LIB/resources/app.asar" | grep -qx "/$ASAR_MAIN" || { echo "FAIL: app.asar lacks its main entry $ASAR_MAIN" >&2; exit 1; }
rm -f package.json
echo "ok: app.asar is mongodb-compass $ASAR_V (main: $ASAR_MAIN)"

for f in usr/bin/mongodb-compass usr/share/applications/mongodb-compass.desktop usr/share/pixmaps/mongodb-compass.png \
         usr/share/doc/mongodb-compass/copyright usr/share/doc/mongodb-compass/changelog.gz \
         usr/lib/mongodb-compass/LICENSE usr/lib/mongodb-compass/THIRD-PARTY-NOTICES.md \
         usr/lib/mongodb-compass/resources/app.asar usr/lib/mongodb-compass/chrome-sandbox; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
[ "$(readlink extract/usr/bin/mongodb-compass)" = "../lib/mongodb-compass/MongoDB Compass" ] || { echo "FAIL: /usr/bin symlink target" >&2; exit 1; }
[ "$(stat -c %a "$LIB/chrome-sandbox")" = 4755 ] || { echo "FAIL: chrome-sandbox is not setuid 4755" >&2; exit 1; }
echo "ok: expected files present, chrome-sandbox is 4755"

(cd extract && md5sum -c --quiet ../../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/mongodb-compass_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
