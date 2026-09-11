#!/bin/sh
# Build obsidian_<VERSION>_arm64.deb from Obsidian's official arm64 Linux
# tarball, smoke test it, copy it into ../../repo/ and reindex.
#
# Upstream (https://github.com/obsidianmd/obsidian-releases) publishes an
# amd64 .deb but only a tarball and AppImage for arm64. This repacks the
# tarball into a .deb that mirrors the amd64 one: /opt/Obsidian, the
# same postinst/postrm, desktop entry, AppArmor profile and icon set.
#
# Needs: dpkg-dev, python3-pil, curl, fakeroot, ~1 GB of disk in build/.
# No root needed.
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=1.13.7
TARBALL_SHA256=98aac34d1f132a35cf506fc3fa196d595dcdeefdebd44b0cc5faaa7a1a210de2
MAINTAINER="antony <antony@beyonk.com>"

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
TARBALL="obsidian-$VERSION-arm64.tar.gz"
URL="https://github.com/obsidianmd/obsidian-releases/releases/download/v$VERSION/$TARBALL"

# --- fetch (cached in dl/, which is gitignored) -------------------------
mkdir -p dl
if [ ! -f "dl/$TARBALL" ]; then
    echo "fetching $URL"
    curl -fL --retry 3 -o "dl/$TARBALL.part" "$URL"
    mv "dl/$TARBALL.part" "dl/$TARBALL"
fi
echo "$TARBALL_SHA256  dl/$TARBALL" | sha256sum -c -

# --- assemble the package tree -----------------------------------------
rm -rf build
mkdir -p build/pkg/opt/Obsidian build/pkg/DEBIAN \
         build/pkg/usr/share/applications build/pkg/usr/share/doc/obsidian
PKG=build/pkg

tar -xzf "dl/$TARBALL" -C build
mv "build/obsidian-$VERSION-arm64"/* "$PKG/opt/Obsidian/"
rmdir "build/obsidian-$VERSION-arm64"

# The tarball lacks the AppArmor profile that the amd64 .deb ships and
# that postinst installs on AppArmor-enabled systems (Ubuntu 24.04+).
install -m 644 debian/apparmor-profile "$PKG/opt/Obsidian/resources/apparmor-profile"

install -m 644 debian/md.obsidian.Obsidian.desktop "$PKG/usr/share/applications/"
./mkicons.py "$PKG/opt/Obsidian/resources/icon.png" "$PKG"

# Debian-style changelog, like upstream's (theirs just says "Package
# created with FPM").
{
    echo "obsidian ($VERSION) local; urgency=medium"
    echo
    echo "  * Repack of upstream's arm64 Linux tarball as a .deb."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$PKG/usr/share/doc/obsidian/changelog.gz"

# Normalise file modes: dirs 755, files 644, executables 755. The tarball
# has group-writable bits that dpkg would otherwise carry into /opt.
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
for f in obsidian obsidian-cli chrome-sandbox chrome_crashpad_handler \
         libEGL.so libGLESv2.so libffmpeg.so libvk_swiftshader.so libvulkan.so.1; do
    chmod 755 "$PKG/opt/Obsidian/$f"
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

DEB="obsidian_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/$DEB"

# --- smoke tests -------------------------------------------------------
cd build
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends

ARCH=$(dpkg-deb -f "$DEB" Architecture)
[ "$ARCH" = arm64 ] || { echo "FAIL: Architecture is $ARCH" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
BIN=extract/opt/Obsidian/obsidian
file "$BIN" | grep -q 'ARM aarch64' || { echo "FAIL: $BIN is not an aarch64 ELF" >&2; file "$BIN" >&2; exit 1; }
echo "ok: /opt/Obsidian/obsidian is an aarch64 ELF"

MISSING=$(ldd "$BIN" | grep 'not found' || true)
[ -z "$MISSING" ] || { echo "FAIL: unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
echo "ok: all shared libraries resolve on this machine"

for f in opt/Obsidian/resources/app.asar opt/Obsidian/resources/obsidian.asar \
         opt/Obsidian/resources/apparmor-profile opt/Obsidian/chrome-sandbox \
         usr/share/applications/md.obsidian.Obsidian.desktop \
         usr/share/icons/hicolor/512x512/apps/obsidian.png \
         usr/share/icons/hicolor/16x16/apps/obsidian.png; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
echo "ok: expected files present"

(cd extract && md5sum -c --quiet ../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/obsidian_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
echo "note: this .deb is ~100 MB and is gitignored; only sources/ and the index are committed."
