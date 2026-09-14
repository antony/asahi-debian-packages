#!/bin/sh
# Build obn_<VERSION>_arm64.deb from open-bamboo-networking's official
# Linux aarch64 release tarball, smoke test it, copy it into ../../repo/
# and reindex.
#
# Upstream (https://github.com/ClusterM/open-bamboo-networking) ships no
# .deb at all, just per-platform tarballs with an interactive install.sh
# that copies the plugin into the user's slicer config directory. A .deb
# can't do that per-user step as root, so this package stages the whole
# tarball, unmodified, in /usr/lib/obn and adds /usr/bin/obn-install,
# which runs upstream's install.sh from there. That keeps the install
# exactly as the upstream README describes it.
#
# Needs: dpkg-dev, fakeroot, curl, python3 (install.sh uses it to patch
# the slicer conf, exercised by the smoke test). No root needed.
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=2.1.0
TARBALL_SHA256=6f3c6921e5130efd922420f9162d642fc2b26c5a9de76d256c34a8ff35dde17a
LICENSE_SHA256=925d377f71d9e33f766e9752839b95caf65f5da400a26fa8bee1393c35b9ec9a
MAINTAINER="antony <antony@beyonk.com>"

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
TARBALL="obn-linux-aarch64.tar.gz"
URL="https://github.com/ClusterM/open-bamboo-networking/releases/download/v$VERSION/$TARBALL"
LICENSE_URL="https://raw.githubusercontent.com/ClusterM/open-bamboo-networking/v$VERSION/LICENSE"

# --- fetch (cached in dl/, which is gitignored) -------------------------
# Upstream reuses the tarball name across releases, so cache it per version.
mkdir -p dl
if [ ! -f "dl/obn-$VERSION-linux-aarch64.tar.gz" ]; then
    echo "fetching $URL"
    curl -fL --retry 3 -o "dl/$TARBALL.part" "$URL"
    mv "dl/$TARBALL.part" "dl/obn-$VERSION-linux-aarch64.tar.gz"
fi
echo "$TARBALL_SHA256  dl/obn-$VERSION-linux-aarch64.tar.gz" | sha256sum -c -
if [ ! -f "dl/LICENSE-v$VERSION" ]; then
    curl -fL --retry 3 -o "dl/LICENSE-v$VERSION.part" "$LICENSE_URL"
    mv "dl/LICENSE-v$VERSION.part" "dl/LICENSE-v$VERSION"
fi
echo "$LICENSE_SHA256  dl/LICENSE-v$VERSION" | sha256sum -c -

# --- assemble the package tree -----------------------------------------
rm -rf build
PKG=build/pkg
mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib" "$PKG/usr/bin" "$PKG/usr/share/doc/obn"

tar -xzf "dl/obn-$VERSION-linux-aarch64.tar.gz" -C build
mv build/obn-linux-aarch64 "$PKG/usr/lib/obn"

# The tarball's VERSION file must agree with what we think we packaged.
TB_VER=$(tr -d '[:space:]' < "$PKG/usr/lib/obn/VERSION")
[ "$TB_VER" = "v$VERSION" ] || { echo "FAIL: tarball VERSION is '$TB_VER', expected 'v$VERSION'" >&2; exit 1; }

install -m 755 debian/obn-install "$PKG/usr/bin/obn-install"
install -m 644 debian/README.Debian "$PKG/usr/share/doc/obn/README.Debian"

# copyright: short header plus upstream's LICENSE (AGPL-3.0-or-later) verbatim.
{
    cat <<COPY
open-bamboo-networking is Copyright (C) 2026 Alexey Cluster and contributors,
released under the GNU Affero General Public License v3.0 or later.
Source: https://github.com/ClusterM/open-bamboo-networking (tag v$VERSION)
The Debian packaging (debian/*, obn-install) is Copyright (C) 2026 $MAINTAINER
and is released under the same licence.

Upstream LICENSE follows.

COPY
    cat "dl/LICENSE-v$VERSION"
} > "$PKG/usr/share/doc/obn/copyright"

{
    echo "obn ($VERSION) local; urgency=medium"
    echo
    echo "  * Repack of upstream's obn-linux-aarch64.tar.gz v$VERSION, staged in"
    echo "    /usr/lib/obn with an obn-install wrapper around upstream's install.sh."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$PKG/usr/share/doc/obn/changelog.gz"

# Normalise modes: dirs 755, files 644, the two scripts 755.
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
chmod 755 "$PKG/usr/lib/obn/install.sh" "$PKG/usr/bin/obn-install"

# --- control files -----------------------------------------------------
install -m 755 debian/postinst "$PKG/DEBIAN/"
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@MAINTAINER@/$MAINTAINER/" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/" \
    debian/control.in > "$PKG/DEBIAN/control"
(cd "$PKG" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' md5sum > DEBIAN/md5sums)

DEB="obn_${VERSION}_arm64.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/$DEB"

# --- smoke tests -------------------------------------------------------
cd build
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends

ARCH=$(dpkg-deb -f "$DEB" Architecture)
[ "$ARCH" = arm64 ] || { echo "FAIL: Architecture is $ARCH" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
LIBS=$(find extract/usr/lib/obn/lib -name '*.so' | sort)
N=0
for so in $LIBS; do
    file "$so" | grep -q 'ARM aarch64' || { echo "FAIL: $so is not an aarch64 ELF" >&2; file "$so" >&2; exit 1; }
    MISSING=$(ldd "$so" 2>/dev/null | grep 'not found' || true)
    [ -z "$MISSING" ] || { echo "FAIL: $so has unresolved shared libraries:" >&2; echo "$MISSING" >&2; exit 1; }
    N=$((N + 1))
done
echo "ok: $N shared libraries are aarch64 ELF and resolve on this machine"
echo "ok: ABI builds shipped: $(ls extract/usr/lib/obn/lib | sed 's/^v//' | tr '\n' ' ')"

for f in usr/lib/obn/install.sh usr/lib/obn/VERSION usr/bin/obn-install \
         usr/share/doc/obn/copyright usr/share/doc/obn/README.Debian usr/share/doc/obn/changelog.gz; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
[ -x extract/usr/lib/obn/install.sh ] || { echo "FAIL: install.sh not executable" >&2; exit 1; }
echo "ok: expected files present"

(cd extract && md5sum -c --quiet ../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"

# End to end: run the packaged obn-install against throwaway slicer config
# dirs in a fake HOME and check it does what the upstream README says
# (copies the ABI-matched libs into <config>/plugins, drops the OTA
# manifest, patches the slicer conf). Nothing outside build/ is touched.
OBN_DIR="$PWD/extract/usr/lib/obn"; export OBN_DIR
FAKE="$PWD/fakehome"; rm -rf "$FAKE"

# Bambu Studio, native config dir, slicer version 02.08.03.x
mkdir -p "$FAKE/.config/BambuStudio"
printf '{\n    "app": {\n        "version": "02.08.03.50",\n        "installed_networking": "0"\n    }\n}\n# MD5 checksum 00000000000000000000000000000000\n' \
    > "$FAKE/.config/BambuStudio/BambuStudio.conf"
printf '1\n\n' | HOME="$FAKE" sh extract/usr/bin/obn-install > install-bambu.log 2>&1 \
    || { echo "FAIL: obn-install (Bambu Studio) exited non-zero:" >&2; cat install-bambu.log >&2; exit 1; }
BS="$FAKE/.config/BambuStudio"
cmp -s "$BS/plugins/libbambu_networking.so" extract/usr/lib/obn/lib/v02.08.03/libbambu_networking.so \
    || { echo "FAIL: plugins/libbambu_networking.so is not the v02.08.03 build" >&2; cat install-bambu.log >&2; exit 1; }
for f in plugins/libBambuSource.so plugins/liblive555.so ota/plugins/network_plugins.json BambuStudio.conf.obn-bak; do
    [ -f "$BS/$f" ] || { echo "FAIL: installer did not create $f" >&2; cat install-bambu.log >&2; exit 1; }
done
grep -q '"installed_networking": "1"' "$BS/BambuStudio.conf" && grep -q '"update_network_plugin": "false"' "$BS/BambuStudio.conf" \
    || { echo "FAIL: BambuStudio.conf not patched" >&2; cat "$BS/BambuStudio.conf" >&2; exit 1; }
grep -q '"version": "02.08.03.99"' "$BS/ota/plugins/network_plugins.json" \
    || { echo "FAIL: OTA manifest is not the 02.08.03 one" >&2; exit 1; }
echo "ok: obn-install installs the ABI-matched plugin into a Bambu Studio config dir and patches the conf"

# Orca Slicer: fixed 02.03.00 ABI, versioned file name
mkdir -p "$FAKE/.config/OrcaSlicer"
printf '{\n    "app": {\n        "network_plugin_version": "02.03.00.99",\n        "network_plugin_skipped_versions": "02.03.00.99"\n    }\n}\n' \
    > "$FAKE/.config/OrcaSlicer/OrcaSlicer.conf"
printf '2\n\n' | HOME="$FAKE" sh extract/usr/bin/obn-install > install-orca.log 2>&1 \
    || { echo "FAIL: obn-install (Orca) exited non-zero:" >&2; cat install-orca.log >&2; exit 1; }
OS_DIR="$FAKE/.config/OrcaSlicer"
cmp -s "$OS_DIR/plugins/libbambu_networking_02.03.00.99.so" extract/usr/lib/obn/lib/v02.03.00/libbambu_networking.so \
    || { echo "FAIL: Orca plugin missing or wrong build" >&2; cat install-orca.log >&2; exit 1; }
grep -q '"installed_networking": "true"' "$OS_DIR/OrcaSlicer.conf" \
    && grep -q '"network_plugin_remind_later": "true"' "$OS_DIR/OrcaSlicer.conf" \
    && ! grep -q '"network_plugin_skipped_versions": "02.03.00.99"' "$OS_DIR/OrcaSlicer.conf" \
    || { echo "FAIL: OrcaSlicer.conf not patched" >&2; cat "$OS_DIR/OrcaSlicer.conf" >&2; exit 1; }
echo "ok: obn-install installs the 02.03.00 plugin for Orca Slicer and patches its conf"

# Refuses to run as root (it would install into /root/.config).
if [ "$(id -u)" -ne 0 ] && command -v fakeroot >/dev/null; then
    if HOME="$FAKE" fakeroot sh extract/usr/bin/obn-install </dev/null >/dev/null 2>&1; then
        echo "FAIL: obn-install ran as (fake)root" >&2; exit 1
    fi
    echo "ok: obn-install refuses to run as root"
fi

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/obn_*_arm64.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
