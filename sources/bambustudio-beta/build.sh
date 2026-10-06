#!/bin/sh
# Build bambustudio-beta_<VERSION>_arm64.deb from source (bambulab/BambuStudio
# pre-release tag), smoke test it, copy it into ../../repo/ and reindex.
#
# Upstream only ships x86_64 AppImages, so this is a real source build with
# upstream's own CMake (deps/ then the app), installed with -DSLIC3R_FHS=ON
# into a staging root and wrapped in a .deb. The package is deliberately
# named bambustudio-beta so it tracks pre-release tags and can sit next to
# the Flathub stable build (com.bambulab.BambuStudio).
#
# Needs: the apt packages listed in DEPS below (roughly upstream's
# linux.d/debian minus libfuse2), ~15 GB disk under build/, and patience:
# deps take ~1 h and the app ~40 min on a 12-core M-series Mac under Asahi.
# build/src is kept between runs so a rebuild only recompiles what changed.
#
# To bump to a NEW upstream beta, see UPDATING.md.
set -eu

VERSION=02.08.03.66
UPSTREAM_COMMIT=1b22065a91bc342e53a7520b0614aad823e7fa05
UPSTREAM=https://github.com/bambulab/BambuStudio.git
PKG=bambustudio-beta

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
HERE=$PWD
JOBS=${JOBS:-$(nproc)}

DEPS="autoconf build-essential ninja-build cmake extra-cmake-modules file gettext git wget
libgstreamerd-3-dev libsecret-1-dev libosmesa6-dev libssl-dev eglexternalplatform-dev
libcurl4-openssl-dev libdbus-1-dev libglew-dev libudev-dev libmspack-dev libgl1-mesa-dev
libgtk-3-dev libxkbcommon-dev libtool libunwind-dev texinfo nasm yasm libx264-dev libbz2-dev
libwebkit2gtk-4.1-dev dpkg-dev fakeroot"
MISSING=""
for p in $DEPS; do dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"; done
[ -z "$MISSING" ] || { echo "missing build dependencies, run: sudo apt install$MISSING" >&2; exit 1; }

# --- fetch upstream at the pinned tag ----------------------------------
mkdir -p build
if [ "$(git -C build/src rev-parse HEAD 2>/dev/null)" != "$UPSTREAM_COMMIT" ]; then
    rm -rf build/src
    git clone -q --depth 1 --branch "v$VERSION" "$UPSTREAM" build/src
    GOT=$(git -C build/src rev-parse HEAD)
    [ "$GOT" = "$UPSTREAM_COMMIT" ] || {
        echo "FAIL: tag v$VERSION is at $GOT, expected $UPSTREAM_COMMIT (tag moved?)" >&2
        exit 1
    }
fi
grep -q "SLIC3R_VERSION \"$VERSION\"" build/src/version.inc \
    || { echo "FAIL: version.inc does not say $VERSION" >&2; exit 1; }

# Patches: upstream fixes merged after the tag (or still open) that GCC 15
# needs. Reset the tree first so re-runs are idempotent.
git -C build/src checkout -q -- .
for p in patches/*.patch; do
    echo "applying $p"; git -C build/src apply "$HERE/$p"
done

# --- build -------------------------------------------------------------
cd build/src
export CMAKE_BUILD_PARALLEL_LEVEL=$JOBS
# deps: upstream's ./BuildLinux.sh -d, minus the interactive checks
cmake -S deps -B deps/build -G Ninja -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DDEP_WX_GTK3=ON
cmake --build deps/build
# app: upstream's ./BuildLinux.sh -s, plus FHS install into /usr
cmake -S . -B build -G Ninja \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_PREFIX_PATH="$PWD/deps/build/destdir/usr/local" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DSLIC3R_STATIC=1 -DSLIC3R_GTK=3 -DSLIC3R_FHS=ON \
    -DCMAKE_BUILD_TYPE=Release -DBBL_RELEASE_TO_PUBLIC=1 -DBBL_INTERNAL_TESTING=0
cmake --build build --target BambuStudio
cd "$HERE"

# --- assemble the .deb -------------------------------------------------
rm -rf build/pkg build/out
mkdir -p build/pkg/DEBIAN build/out
DESTDIR="$HERE/build/pkg" cmake --install build/src/build >/dev/null
# Tell the launcher apart from the Flathub stable entry.
sed -i 's/^Name=.*/Name=Bambu Studio (beta)/' build/pkg/usr/share/applications/BambuStudio.desktop
# Debian-side extras
mkdir -p build/pkg/usr/share/doc/$PKG
printf '%s (%s) local; urgency=low\n\n  * Upstream pre-release v%s built for arm64.\n\n -- %s <%s>  %s\n' \
    "$PKG" "$VERSION" "$VERSION" "$(git config user.name)" "$(git config user.email)" "$(date -R)" \
    | gzip -9n > build/pkg/usr/share/doc/$PKG/changelog.Debian.gz
cp build/src/LICENSE build/pkg/usr/share/doc/$PKG/copyright
find build/pkg -type d -exec chmod 755 {} +
find build/pkg -type f -exec chmod 644 {} +
chmod 755 build/pkg/usr/bin/bambu-studio
strip --strip-unneeded build/pkg/usr/bin/bambu-studio

# Runtime Depends from the binary itself (needs a debian/control to exist)
mkdir -p build/shlibs/debian
printf 'Source: %s\nPackage: %s\nArchitecture: arm64\n' $PKG $PKG > build/shlibs/debian/control
SHLIBS=$(cd build/shlibs && dpkg-shlibdeps -O -e "$HERE/build/pkg/usr/bin/bambu-studio" 2>/dev/null | sed 's/^shlibs:Depends=//')

INSTALLED_SIZE=$(du -sk --exclude=DEBIAN build/pkg | cut -f1)
cat > build/pkg/DEBIAN/control <<EOF
Package: $PKG
Version: $VERSION
Architecture: arm64
Maintainer: $(git config user.name) <$(git config user.email)>
Installed-Size: $INSTALLED_SIZE
Depends: $SHLIBS
Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad, gstreamer1.0-libav
Conflicts: bambustudio
Section: graphics
Priority: optional
Homepage: https://github.com/bambulab/BambuStudio
Description: Bambu Studio 3D printing slicer (pre-release channel)
 Bambu Lab's slicer and printer front end, built from the upstream
 pre-release tag for arm64. Upstream only publishes x86_64 AppImages.
EOF
(cd build/pkg && find usr -type f -exec md5sum {} + > DEBIAN/md5sums)

DEB="${PKG}_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b build/pkg "build/out/$DEB"

# --- smoke tests -------------------------------------------------------
cd build/out
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends | head -8
[ "$(dpkg-deb -f "$DEB" Package)" = $PKG ] || { echo "FAIL: package name" >&2; exit 1; }
[ "$(dpkg-deb -f "$DEB" Architecture)" = arm64 ] || { echo "FAIL: not arm64" >&2; exit 1; }
rm -rf extract && dpkg-deb -x "$DEB" extract
BIN=extract/usr/bin/bambu-studio
file "$BIN" | grep -q 'ARM aarch64' || { echo "FAIL: $BIN is not an aarch64 ELF" >&2; file "$BIN" >&2; exit 1; }
echo "ok: /usr/bin/bambu-studio is an aarch64 ELF"
MISSING=$(ldd "$BIN" | grep 'not found' || true)
[ -z "$MISSING" ] || { echo "FAIL: unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
echo "ok: all shared libraries resolve on this machine"
for f in usr/share/applications/BambuStudio.desktop usr/share/icons/hicolor/128x128/apps/BambuStudio.png \
         usr/share/BambuStudio/profiles/BBL.json usr/share/BambuStudio/web/homepage3/home.html; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
echo "ok: desktop entry, icon and resources present"
(cd extract && md5sum --quiet -c ../../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"
# CLI mode exits without a display; check it reports our version.
"$BIN" --help 2>/dev/null | grep -q "$VERSION" && echo "ok: --help reports $VERSION" \
    || { echo "FAIL: --help does not mention $VERSION" >&2; "$BIN" --help 2>&1 | head -5 >&2; exit 1; }

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/${PKG}_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
