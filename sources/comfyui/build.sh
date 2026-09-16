#!/bin/sh
# Build comfyui_<VERSION>_all.deb from ComfyUI's tagged source tarball,
# smoke test it, copy it into ../../repo/ and reindex.
#
# Upstream (https://github.com/comfyanonymous/ComfyUI, GPL-3.0) ships no
# Linux binaries; it is a Python source tree you run inside a virtualenv
# whose dependencies (PyTorch and friends, ~2.5 GB) are not in the Ubuntu
# archive. This package stages the tree, unmodified, in /usr/lib/comfyui
# and adds /usr/bin/comfyui (debian/comfyui), which creates that venv per
# user under ~/.local/share/comfyui on first run and launches main.py
# with --base-directory pointing there, plus --cpu for the CPU torch
# build (Asahi has no PyTorch GPU backend).
#
# Needs: dpkg-dev, fakeroot, curl, python3 (>= 3.12). No root needed.
# COMFYUI_E2E=1 additionally runs the packaged launcher end to end
# (creates a venv in dl/e2e/, ~1 GB download the first time, then cached).
#
# To bump to a NEW upstream version, see UPDATING.md.
set -eu

VERSION=0.36.0
COMMIT=ee71d5c4993f29086b27fde1629a945ae48425bf
TARBALL_SHA256=ab0d2f14e6a20616c6019d7af733aa897507a9a34ed0e88cec9d9c574065e8a1
MAINTAINER="antony <antony@beyonk.com>"

cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
TARBALL="ComfyUI-$VERSION.tar.gz"
URL="https://github.com/comfyanonymous/ComfyUI/archive/refs/tags/v$VERSION.tar.gz"

# --- fetch (cached in dl/, which is gitignored) -------------------------
mkdir -p dl
if [ ! -f "dl/$TARBALL" ]; then
    echo "fetching $URL"
    curl -fL --retry 3 -o "dl/$TARBALL.part" "$URL"
    mv "dl/$TARBALL.part" "dl/$TARBALL"
fi
echo "$TARBALL_SHA256  dl/$TARBALL" | sha256sum -c -
GOT_COMMIT=$(git ls-remote https://github.com/comfyanonymous/ComfyUI.git "refs/tags/v$VERSION" | cut -f1)
[ -z "$GOT_COMMIT" ] || [ "$GOT_COMMIT" = "$COMMIT" ] \
    || { echo "FAIL: tag v$VERSION now points at $GOT_COMMIT, expected $COMMIT" >&2; exit 1; }

# --- assemble the package tree -----------------------------------------
rm -rf build
PKG=build/pkg
mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib" "$PKG/usr/bin" "$PKG/usr/share/applications" "$PKG/usr/share/doc/comfyui"

tar -xzf "dl/$TARBALL" -C build
mv "build/ComfyUI-$VERSION" "$PKG/usr/lib/comfyui"
# Drop CI/test/dev-only files; the runtime tree is untouched.
(cd "$PKG/usr/lib/comfyui" && rm -rf tests tests-unit .ci .github .coderabbit.yaml .spectral.yaml \
    .gitattributes .gitignore pytest.ini CODEOWNERS AGENTS.md CONTRIBUTING.md)

TREE_VER=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$PKG/usr/lib/comfyui/comfyui_version.py")
[ "$TREE_VER" = "$VERSION" ] || { echo "FAIL: comfyui_version.py says '$TREE_VER', expected '$VERSION'" >&2; exit 1; }

install -m 755 debian/comfyui "$PKG/usr/bin/comfyui"
install -m 644 debian/comfyui.desktop "$PKG/usr/share/applications/comfyui.desktop"
install -m 644 debian/README.Debian "$PKG/usr/share/doc/comfyui/README.Debian"

{
    cat <<COPY
ComfyUI is Copyright (C) comfyanonymous and contributors, released under
the GNU General Public License v3.0.
Source: https://github.com/comfyanonymous/ComfyUI (tag v$VERSION, commit $COMMIT)
The Debian packaging (debian/*, the comfyui launcher) is Copyright (C) 2026
$MAINTAINER and is released under the same licence.

Upstream LICENSE follows.

COPY
    cat "$PKG/usr/lib/comfyui/LICENSE"
} > "$PKG/usr/share/doc/comfyui/copyright"

{
    echo "comfyui ($VERSION) local; urgency=medium"
    echo
    echo "  * Upstream source tree v$VERSION staged in /usr/lib/comfyui with a"
    echo "    per-user virtualenv launcher, /usr/bin/comfyui."
    echo
    echo " -- $MAINTAINER  $(date -R)"
} | gzip -9n > "$PKG/usr/share/doc/comfyui/changelog.gz"

find "$PKG" -type d -exec chmod 755 {} +
find "$PKG" -type f -exec chmod 644 {} +
chmod 755 "$PKG/usr/bin/comfyui"

# --- control files -----------------------------------------------------
install -m 755 debian/postinst debian/prerm "$PKG/DEBIAN/"
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
sed -e "s/@VERSION@/$VERSION/" \
    -e "s/@MAINTAINER@/$MAINTAINER/" \
    -e "s/@INSTALLED_SIZE@/$INSTALLED_SIZE/" \
    debian/control.in > "$PKG/DEBIAN/control"
(cd "$PKG" && find . -type f ! -path './DEBIAN/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' md5sum > DEBIAN/md5sums)

DEB="comfyui_${VERSION}_all.deb"
fakeroot dpkg-deb --root-owner-group -Zxz -b "$PKG" "build/$DEB"

# --- smoke tests -------------------------------------------------------
cd build
echo "--- control:"; dpkg-deb -f "$DEB" Package Version Architecture Depends Recommends
ARCH=$(dpkg-deb -f "$DEB" Architecture)
[ "$ARCH" = all ] || { echo "FAIL: Architecture is $ARCH" >&2; exit 1; }

rm -rf extract
dpkg-deb -x "$DEB" extract
for f in usr/lib/comfyui/main.py usr/lib/comfyui/requirements.txt usr/lib/comfyui/comfyui_version.py \
         usr/lib/comfyui/models/checkpoints usr/lib/comfyui/custom_nodes/websocket_image_save.py \
         usr/bin/comfyui usr/share/applications/comfyui.desktop \
         usr/share/doc/comfyui/copyright usr/share/doc/comfyui/README.Debian usr/share/doc/comfyui/changelog.gz; do
    [ -e "extract/$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
[ -x extract/usr/bin/comfyui ] || { echo "FAIL: launcher not executable" >&2; exit 1; }
echo "ok: expected files present"
(cd extract && md5sum -c --quiet ../pkg/DEBIAN/md5sums) && echo "ok: md5sums verify"

sh -n extract/usr/bin/comfyui pkg/DEBIAN/postinst pkg/DEBIAN/prerm && echo "ok: shell scripts parse"
# Every .py must compile under the system python3 (what the venv uses).
python3 -m compileall -q extract/usr/lib/comfyui > compile.log 2>&1 \
    || { echo "FAIL: byte-compilation errors:" >&2; cat compile.log >&2; exit 1; }
find extract/usr/lib/comfyui -name __pycache__ -type d -prune -exec rm -rf {} +
echo "ok: $(find extract/usr/lib/comfyui -name '*.py' | wc -l) .py files compile with $(python3 --version)"

# Launcher refuses to run as root.
if command -v fakeroot >/dev/null; then
    if HOME="$PWD" fakeroot sh extract/usr/bin/comfyui --help >/dev/null 2>&1; then
        echo "FAIL: launcher ran as (fake)root" >&2; exit 1
    fi
    echo "ok: launcher refuses to run as root"
fi

# Optional end to end: real venv (cached in dl/e2e), real ComfyUI startup.
if [ -n "${COMFYUI_E2E:-}" ]; then
    E2E="$PWD/../dl/e2e"; mkdir -p "$E2E"
    rm -rf "$E2E/models" "$E2E/custom_nodes" "$E2E/input" "$E2E/user" "$E2E/temp"
    COMFYUI_APP="$PWD/extract/usr/lib/comfyui" COMFYUI_HOME="$E2E" \
        sh extract/usr/bin/comfyui --quick-test-for-ci > e2e.log 2>&1 \
        || { echo "FAIL: launcher --quick-test-for-ci exited non-zero:" >&2; tail -40 e2e.log >&2; exit 1; }
    for d in models/checkpoints custom_nodes/websocket_image_save.py input/example.png user/comfyui.db; do
        [ -e "$E2E/$d" ] || { echo "FAIL: launcher did not create $d" >&2; exit 1; }
    done
    grep -q 'Torch not compiled with CUDA' e2e.log && { echo "FAIL: --cpu not applied" >&2; exit 1; }
    echo "ok: launcher set up a venv, seeded $E2E and ComfyUI $VERSION started (torch $("$E2E/venv/bin/python" -c 'import torch; print(torch.__version__)'))"
fi

# --- publish into the repo ---------------------------------------------
rm -f "$ROOT"/repo/comfyui_*_all.deb
cp "$DEB" "$ROOT/repo/"
"$ROOT/update-index.sh"
echo "done: $DEB built, tested and added to repo/"
